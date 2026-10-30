//! Local agent execution — running an agent task with the CLI on PATH.
//!
//! The daemon owns the machine, so the daemon is the side that runs the
//! agent: the server hands over a rendered prompt plus the agent's
//! configuration, and the daemon drives the local CLI (opencode / claude
//! / codex) and reports the answer back.
//!
//! The CLI is invoked non-interactively and its output is parsed for the
//! answer text. Each CLI reports its answer differently — opencode emits
//! newline-delimited events, claude emits one JSON object, codex prints
//! plain text — so each has its own extractor.

const std = @import("std");
const out = @import("out.zig");

/// The local agent CLIs this daemon knows how to drive.
///
/// The declaration order is the preference order — the first CLI that is
/// actually runnable wins. `opencode` comes first because it produces an
/// answer without a paid subscription; `claude` and `codex` follow.
pub const Provider = enum {
    opencode,
    claude,
    codex,

    pub fn name(self: Provider) []const u8 {
        return switch (self) {
            .opencode => "opencode",
            .claude => "claude",
            .codex => "codex",
        };
    }

    /// Resolve a provider name the server reported.
    pub fn fromName(raw: []const u8) ?Provider {
        if (std.mem.eql(u8, raw, "opencode")) return .opencode;
        if (std.mem.eql(u8, raw, "claude")) return .claude;
        if (std.mem.eql(u8, raw, "codex")) return .codex;
        return null;
    }
};

/// How much of the CLI's output to keep. A runaway CLI must not be able
/// to exhaust the daemon's memory.
const max_output_bytes: usize = 4 * 1024 * 1024;

/// The inputs of one agent run.
pub const RunRequest = struct {
    /// The rendered prompt, ready for the CLI.
    prompt: []const u8,
    /// The model to run on. Empty means "the CLI's default".
    model: []const u8 = "",
    /// Extra arguments appended to the CLI's own arguments.
    custom_args: []const []const u8 = &.{},
    /// Environment overrides for the CLI process.
    custom_env: ?std.json.Value = null,
    /// The daemon's own environment — the base the overrides apply to.
    base_env: ?*const std.process.Environ.Map = null,
    /// The directory the CLI runs in. Empty means "inherit the daemon's".
    ///
    /// The agent runs in a directory of its own: this fork's agent
    /// execution is text-only, so the agent has no business in the
    /// repository — and an empty directory is the cheapest way to make
    /// sure it cannot touch anything.
    work_dir: []const u8 = "",
    /// How long the CLI may run before the task fails.
    timeout_ms: u64 = default_timeout_ms,
};

/// How long an agent run may take before it is abandoned.
///
/// Without this a runaway agent (one that keeps exploring the machine)
/// would hold the task forever: the daemon is single-threaded, so the
/// next task would never be claimed.
pub const default_timeout_ms: u64 = 5 * 60 * 1000;

/// The outcome of one agent run.
///
/// The caller owns `output` and `failure`: both are allocated by the
/// run and must be freed by whoever received the outcome. A failed run
/// has an empty `output` and a non-null `failure`.
pub const RunOutcome = struct {
    /// The agent's answer, as plain text. Empty when the run failed.
    output: []const u8,
    /// The CLI's exit status, for the record.
    exit_code: ?u8,
    /// Why the run failed, when it did.
    ///
    /// A failed run is not an answer — reporting one as an answer would
    /// tell the user the agent produced that text, which it did not.
    failure: ?[]const u8 = null,
};

/// Find the agent CLI this machine can actually run.
///
/// Presence on PATH is not enough — the CLI has to run — so each
/// candidate is probed with `--version`. The first one that answers wins.
pub fn detectProvider(allocator: std.mem.Allocator, io: std.Io) ?Provider {
    for ([_]Provider{ .opencode, .claude, .codex }) |p| {
        if (probe(allocator, io, p)) {
            out.printOut("agent provider detected: {s}\n", .{p.name()});
            return p;
        }
    }
    return null;
}

fn probe(allocator: std.mem.Allocator, io: std.Io, p: Provider) bool {
    const argv = [_][]const u8{ p.name(), "--version" };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term.success();
}

/// Run one agent task with the local CLI.
///
/// The caller owns `outcome.output`. On a non-zero exit the CLI's stderr
/// is returned as the output — a failed run has to say why, and the CLI
/// is the only one that knows.
pub fn runAgent(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    req: RunRequest,
) !RunOutcome {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, provider.name());
    switch (provider) {
        .opencode => {
            try argv.append(allocator, "run");
            try argv.append(allocator, "--format");
            try argv.append(allocator, "json");
            // The agent has to be able to act on the task, not stop at
            // every permission prompt.
            try argv.append(allocator, "--auto");
            // `plan` is opencode's tool-free mode. This fork's agent
            // execution is text-only — the answer is posted by the
            // server, not by the agent — so the agent must not go
            // looking around the machine on its own. Without this the
            // agent treats the issue as a coding task and starts
            // exploring the file system instead of answering.
            try argv.append(allocator, "--agent");
            try argv.append(allocator, "plan");
            if (req.model.len > 0) {
                try argv.append(allocator, "--model");
                try argv.append(allocator, req.model);
            }
            for (req.custom_args) |a| try argv.append(allocator, a);
            // `--` so a prompt that starts with a dash is read as the
            // prompt and not as a flag.
            try argv.append(allocator, "--");
            try argv.append(allocator, req.prompt);
        },
        .claude => {
            try argv.append(allocator, "-p");
            try argv.append(allocator, req.prompt);
            try argv.append(allocator, "--output-format");
            try argv.append(allocator, "json");
            // No tools: the agent answers, it does not act on the
            // machine.
            try argv.append(allocator, "--tools");
            try argv.append(allocator, "");
            for (req.custom_args) |a| try argv.append(allocator, a);
        },
        .codex => {
            try argv.append(allocator, "exec");
            try argv.append(allocator, "--skip-git-repo-check");
            // codex sandboxes writes by default; reads are still
            // possible, so the agent runs in its own empty directory.
            try argv.append(allocator, "--sandbox");
            try argv.append(allocator, "read-only");
            for (req.custom_args) |a| try argv.append(allocator, a);
            try argv.append(allocator, req.prompt);
        },
    }

    // The child gets the daemon's environment plus the agent's overrides.
    var env: ?std.process.Environ.Map = null;
    defer if (env) |*e| e.deinit();
    if (try buildEnv(allocator, req)) |e| env = e;

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
        .environ_map = if (env) |*e| e else null,
        .cwd = if (req.work_dir.len > 0) .{ .path = req.work_dir } else .inherit,
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(@intCast(req.timeout_ms)), .clock = .real } },
    }) catch |err| {
        out.printErr("agent run failed to start ({s})\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };

    if (!result.term.success()) {
        // The reason lives wherever the CLI put it. opencode reports
        // errors as a JSON event on stdout and leaves stderr empty, so
        // stderr alone would only ever produce a useless fallback.
        //
        // The reason is owned by the caller — the same contract as
        // `output` — so it must outlive this call.
        const reason = try describeFailure(allocator, provider, result.stdout, result.stderr);
        out.printErr("agent run failed (exit={?d}): {s}\n", .{ exit_code, reason });
        return RunOutcome{
            .output = "",
            .exit_code = exit_code,
            .failure = reason,
        };
    }

    const answer = try extractAnswer(allocator, provider, result.stdout);
    return RunOutcome{ .output = answer, .exit_code = exit_code };
}

/// Explain why an agent run failed, in one line.
///
/// Each CLI reports failure differently: opencode emits a JSON error
/// event on stdout, claude emits one JSON object, codex prints plain
/// text. The reason is looked up in that order and only falls back to a
/// generic sentence when the CLI said nothing usable.
///
/// The caller owns the returned string.
fn describeFailure(
    allocator: std.mem.Allocator,
    provider: Provider,
    stdout: []const u8,
    stderr: []const u8,
) ![]const u8 {
    switch (provider) {
        .opencode => {
            if (try openCodeErrorMessage(allocator, stdout)) |msg| return msg;
        },
        .claude => {
            if (try claudeErrorMessage(allocator, stdout)) |msg| return msg;
        },
        .codex => {},
    }
    if (firstLine(stderr).len > 0) return allocator.dupe(u8, firstLine(stderr));
    if (firstLine(stdout).len > 0) return allocator.dupe(u8, firstLine(stdout));
    return allocator.dupe(u8, "the agent CLI exited with an error");
}

/// Pull the message out of an opencode error event.
///
/// opencode reports failures as `{"type":"error","error":{...}}` on
/// stdout — the shape of the event, not the exit code, is what says
/// whether the run produced an answer.
fn openCodeErrorMessage(allocator: std.mem.Allocator, stdout: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) continue;
        const event_type = root.object.get("type") orelse continue;
        if (event_type != .string or !std.mem.eql(u8, event_type.string, "error")) continue;
        const err = root.object.get("error") orelse continue;
        if (err != .object) continue;
        const message = err.object.get("message") orelse continue;
        if (message != .string) continue;
        const trimmed_msg = std.mem.trim(u8, message.string, " \t\r\n");
        if (trimmed_msg.len > 0) return try allocator.dupe(u8, trimmed_msg);
    }
    return null;
}

/// Pull the message out of a claude error result.
fn claudeErrorMessage(allocator: std.mem.Allocator, stdout: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const is_error = root.object.get("is_error") orelse return null;
    if (is_error != .bool or !is_error.bool) return null;
    const err = root.object.get("error") orelse return null;
    if (err == .string) {
        const trimmed = std.mem.trim(u8, err.string, " \t\r\n");
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    }
    return null;
}

/// Build the child environment: the daemon's own, plus the agent's
/// overrides.
fn buildEnv(allocator: std.mem.Allocator, req: RunRequest) !?std.process.Environ.Map {
    const overrides = req.custom_env orelse return null;
    if (overrides != .object) return null;
    if (overrides.object.count() == 0) return null;

    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    if (req.base_env) |base| try map.putAll(base);

    var it = overrides.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try map.put(entry.key_ptr.*, entry.value_ptr.*.string);
    }
    return map;
}

/// Pull the agent's answer out of the CLI's output.
fn extractAnswer(allocator: std.mem.Allocator, provider: Provider, stdout: []const u8) ![]const u8 {
    return switch (provider) {
        .opencode => extractOpenCodeText(allocator, stdout),
        .claude => extractClaudeResult(allocator, stdout),
        .codex => allocator.dupe(u8, std.mem.trim(u8, stdout, " \t\r\n")),
    };
}

/// opencode emits newline-delimited events; the answer is the text of the
/// last `text` part.
fn extractOpenCodeText(allocator: std.mem.Allocator, stdout: []const u8) ![]const u8 {
    var answer: []const u8 = "";
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) continue;
        const part = root.object.get("part") orelse continue;
        if (part != .object) continue;
        const part_type = part.object.get("type") orelse continue;
        if (part_type != .string or !std.mem.eql(u8, part_type.string, "text")) continue;
        const text = part.object.get("text") orelse continue;
        if (text != .string) continue;
        if (answer.len > 0) allocator.free(answer);
        answer = try allocator.dupe(u8, text.string);
    }
    if (answer.len == 0) {
        // No text event: fall back to whatever the CLI printed, so a
        // format change shows the user the raw output instead of nothing.
        return allocator.dupe(u8, std.mem.trim(u8, stdout, " \t\r\n"));
    }
    return answer;
}

/// claude emits one JSON object whose `result` field carries the answer.
fn extractClaudeResult(allocator: std.mem.Allocator, stdout: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{}) catch {
        return allocator.dupe(u8, std.mem.trim(u8, stdout, " \t\r\n"));
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root == .object) {
        if (root.object.get("result")) |r| {
            if (r == .string) return allocator.dupe(u8, r.string);
        }
        if (root.object.get("is_error")) |e| {
            if (e == .bool and e.bool) {
                if (root.object.get("error")) |err| {
                    if (err == .string) return allocator.dupe(u8, err.string);
                }
            }
        }
    }
    return allocator.dupe(u8, std.mem.trim(u8, stdout, " \t\r\n"));
}

/// The first non-empty line of a text — used to turn a CLI's error output
/// into a one-line reason.
fn firstLine(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

// ──────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "provider names round-trip" {
    try testing.expectEqual(Provider.opencode, Provider.fromName("opencode").?);
    try testing.expectEqual(Provider.claude, Provider.fromName("claude").?);
    try testing.expectEqual(Provider.codex, Provider.fromName("codex").?);
    try testing.expect(Provider.fromName("auto") == null);
    try testing.expect(Provider.fromName("") == null);
}

test "opencode output: the last text part wins" {
    const stdout =
        \\{"type":"step_start","part":{"type":"step-start"}}
        \\{"type":"text","part":{"type":"text","text":"第一段"}}
        \\{"type":"text","part":{"type":"text","text":"最终答案"}}
    ;
    const answer = try extractOpenCodeText(testing.allocator, stdout);
    defer testing.allocator.free(answer);
    try testing.expectEqualStrings("最终答案", answer);
}

test "opencode output without a text part falls back to the raw output" {
    const stdout =
        \\{"type":"step_start","part":{"type":"step-start"}}
    ;
    const answer = try extractOpenCodeText(testing.allocator, stdout);
    defer testing.allocator.free(answer);
    try testing.expect(std.mem.indexOf(u8, answer, "step_start") != null);
}

test "claude output: the result field is the answer" {
    const stdout = "{\"result\":\"答案\",\"is_error\":false}";
    const answer = try extractClaudeResult(testing.allocator, stdout);
    defer testing.allocator.free(answer);
    try testing.expectEqualStrings("答案", answer);
}

test "claude output: an error result is reported as the answer" {
    const stdout = "{\"result\":\"boom\",\"is_error\":true,\"error\":\"boom\"}";
    const answer = try extractClaudeResult(testing.allocator, stdout);
    defer testing.allocator.free(answer);
    try testing.expectEqualStrings("boom", answer);
}

test "claude output that is not JSON falls back to the raw text" {
    const answer = try extractClaudeResult(testing.allocator, "plain answer\n");
    defer testing.allocator.free(answer);
    try testing.expectEqualStrings("plain answer", answer);
}

test "firstLine picks the first non-empty line" {
    try testing.expectEqualStrings("second", firstLine("\n  \nsecond\nthird"));
    try testing.expectEqualStrings("", firstLine("   \n\n"));
}

test "opencode error event: the message is the failure reason" {
    // The shape opencode actually emits when the provider refuses the
    // run — the reason lives in stdout, stderr stays empty.
    const stdout =
        \\{"type":"error","timestamp":1793360898785,"sessionID":"ses_x","error":{"type":"provider.free-limit","message":"Free usage limit reached. Connect a provider or subscribe to OpenCode Go to keep going, or switch models.","status":429}}
    ;
    const msg = (try openCodeErrorMessage(testing.allocator, stdout)).?;
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings(
        "Free usage limit reached. Connect a provider or subscribe to OpenCode Go to keep going, or switch models.",
        msg,
    );
}

test "opencode error event: a text event is not an error" {
    const stdout =
        \\{"type":"text","part":{"type":"text","text":"答案"}}
    ;
    try testing.expect((try openCodeErrorMessage(testing.allocator, stdout)) == null);
}

test "describeFailure: the opencode error wins over an empty stderr" {
    const stdout =
        \\{"type":"error","error":{"type":"provider.auth","message":"This model is not available in your country","status":403}}
    ;
    const reason = try describeFailure(testing.allocator, .opencode, stdout, "");
    defer testing.allocator.free(reason);
    try testing.expectEqualStrings(
        "This model is not available in your country",
        reason,
    );
}

test "describeFailure: stderr is used when the CLI said nothing on stdout" {
    const reason = try describeFailure(testing.allocator, .codex, "", "fatal: not a git repository\n");
    defer testing.allocator.free(reason);
    try testing.expectEqualStrings("fatal: not a git repository", reason);
}

test "describeFailure: stdout is the last resort before the generic sentence" {
    const reason = try describeFailure(testing.allocator, .codex, "something went wrong\n", "");
    defer testing.allocator.free(reason);
    try testing.expectEqualStrings("something went wrong", reason);
}

test "describeFailure: with nothing to go on the generic sentence is used" {
    const reason = try describeFailure(testing.allocator, .codex, "", "");
    defer testing.allocator.free(reason);
    try testing.expectEqualStrings("the agent CLI exited with an error", reason);
}

test "claude error result: the message is the failure reason" {
    const stdout = "{\"result\":\"\",\"is_error\":true,\"error\":\"quota exceeded\"}";
    const msg = (try claudeErrorMessage(testing.allocator, stdout)).?;
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("quota exceeded", msg);
}

test "claude: a successful result is not a failure" {
    const stdout = "{\"result\":\"答案\",\"is_error\":false}";
    try testing.expect((try claudeErrorMessage(testing.allocator, stdout)) == null);
}

test "the failure reason outlives the run that produced it" {
    // The reason is owned by the caller of runAgent: it has to survive
    // the call, because the daemon reports it to the server afterwards.
    // A regression here frees it too early and the next use reads freed
    // memory — which is what crashed the daemon before.
    const stdout =
        \\{"type":"error","error":{"type":"provider.free-limit","message":"Free usage limit reached.","status":429}}
    ;
    const reason = try describeFailure(testing.allocator, .opencode, stdout, "");
    defer testing.allocator.free(reason);
    // Touch the string after the producing function returned.
    try testing.expectEqualStrings("Free usage limit reached.", reason);
    try testing.expect(reason.len > 0);
}
