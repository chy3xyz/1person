//! Local agent execution — running an agent task with the CLI on PATH.
//!
//! The daemon owns the machine, so the daemon is the side that runs the
//! agent: the server hands over a rendered prompt plus the agent's
//! configuration, and the daemon drives the local CLI (opencode / claude
//! / codex / dsh / pi) and reports the answer back.
//!
//! The CLI is invoked non-interactively and its output is parsed for the
//! answer text. Each CLI reports its answer differently — opencode emits
//! newline-delimited events, claude emits one JSON object, codex prints
//! plain text, dsh and pi print plain text too — so each has its own
//! extractor.
//!
//! The CLI does not have to be called after the provider it stands for:
//! dsh installs a Node CLI under its own home directory and never puts
//! it on PATH, and pi installs its launcher under its own directory
//! too. `resolveExecutable` looks for both.

const std = @import("std");
const out = @import("out.zig");
const zfinal = @import("zfinal");

/// The local agent CLIs this daemon knows how to drive.
///
/// The declaration order is the preference order — the first CLI that is
/// actually runnable wins. `opencode` comes first because it produces an
/// answer without a paid subscription; `claude` and `codex` follow, then
/// the two CLIs that need their own account: dsh (DeepSeek Harness) and
/// pi.
pub const Provider = enum {
    opencode,
    claude,
    codex,
    dsh,
    pi,

    pub fn name(self: Provider) []const u8 {
        return switch (self) {
            .opencode => "opencode",
            .claude => "claude",
            .codex => "codex",
            .dsh => "dsh",
            .pi => "pi",
        };
    }

    /// Resolve a provider name the server reported.
    pub fn fromName(raw: []const u8) ?Provider {
        if (std.mem.eql(u8, raw, "opencode")) return .opencode;
        if (std.mem.eql(u8, raw, "claude")) return .claude;
        if (std.mem.eql(u8, raw, "codex")) return .codex;
        if (std.mem.eql(u8, raw, "dsh")) return .dsh;
        if (std.mem.eql(u8, raw, "pi")) return .pi;
        return null;
    }
};

/// The environment variable that names the CLI the daemon should run.
///
/// A machine can have several of these CLIs installed, and the
/// preference order is a product decision — not the user's. The
/// variable is the user's way out of it.
pub const provider_env_var = "ONEPERSON_AGENT_PROVIDER";


/// How much of the CLI's output to keep. A runaway CLI must not be able
/// to exhaust the daemon's memory.
const max_output_bytes: usize = 4 * 1024 * 1024;

/// The opencode agent a 1Person task runs under.
pub const opencode_agent_id = "1p";

/// The opencode profile a 1Person task runs under when it only answers.
///
/// opencode's built-in `plan` agent is the wrong tool for this fork. Its
/// own prompt tells the agent that it may not act until the user
/// switches it to another mode, so a task that asks for a result comes
/// back with "switch me to build mode" instead of the result — the
/// answer depends on the mood of the model, not on the task. So the
/// task needs a profile that answers directly.
///
/// This profile has no tools: the task is answered from the context the
/// server rendered, and the agent has no business on the machine. It is
/// what a task without a working directory gets.
///
/// The profile is written into the task's own working directory rather
/// than into the user's opencode configuration: the daemon owns the
/// machine, and a task must not inherit whatever profile the user
/// happens to have set up.
const openCodeConfigJson =
    \\{
    \\  "$schema": "https://opencode.ai/config.json",
    \\  "agent": {
    \\    "1p": {
    \\      "description": "1Person task agent: answers the task in one reply, without tools.",
    \\      "mode": "primary",
    \\      "prompt": "You are an AI agent working on tasks handed to you by the 1Person platform.\n\nThe platform posts your reply for you: your whole reply is the deliverable. Answer the task directly and completely, in this reply. Do not ask questions, do not propose a plan, do not describe what you would do, and do not hand the work back to the user.\n\nYou have no tools: you cannot read or write files, run commands, or call APIs. Work only from the context you were given.",
    \\      "permission": {
    \\        "read": "deny",
    \\        "edit": "deny",
    \\        "glob": "deny",
    \\        "grep": "deny",
    \\        "list": "deny",
    \\        "bash": "deny",
    \\        "task": "deny",
    \\        "external_directory": "deny",
    \\        "todowrite": "deny",
    \\        "question": "deny",
    \\        "webfetch": "deny",
    \\        "websearch": "deny",
    \\        "lsp": "deny",
    \\        "doom_loop": "deny",
    \\        "skill": "deny"
    \\      }
    \\    }
    \\  }
    \\}
;

/// The opencode profile a 1Person task runs under when it edits code.
///
/// This is the profile for a task that has a working directory: the agent
/// reads the repository, changes it, runs the project's own checks, and
/// leaves the result in the working tree for the platform to deliver.
///
/// Two permissions are deliberately withheld even here:
///
/// - `external_directory`: the agent stays inside the working directory it
///   was given. The worktree it works in is already outside the user's
///   working copy — that is the whole point of the isolation — and this
///   keeps it from wandering into the rest of the machine.
/// - `question`: the agent cannot ask the user anything. A question with
///   nobody to answer it is a task that hangs until it times out, and a
///   timed-out task delivers nothing.
const openCodeCodingConfigJson =
    \\{
    \\  "$schema": "https://opencode.ai/config.json",
    \\  "agent": {
    \\    "1p": {
    \\      "description": "1Person coding agent: works in the task's own checkout and leaves the change there.",
    \\      "mode": "primary",
    \\      "prompt": "You are an AI coding agent working on a task handed to you by the 1Person platform.\n\nYou are working in a private git checkout that the platform prepared for this task. Read the code, make the change the task asks for, and verify it with the project's own tests or checks when they exist and are quick to run.\n\nDo not commit: the platform commits your work for you and delivers it on a branch. Do not switch branches, do not rebase, and do not touch anything outside this checkout.\n\nWhen you are done, reply with what you changed and how you verified it. That reply is posted for you, so state the result rather than narrating the steps.",
    \\      "permission": {
    \\        "read": "allow",
    \\        "edit": "allow",
    \\        "glob": "allow",
    \\        "grep": "allow",
    \\        "list": "allow",
    \\        "bash": "allow",
    \\        "todowrite": "allow",
    \\        "task": "deny",
    \\        "external_directory": "deny",
    \\        "question": "deny",
    \\        "webfetch": "deny",
    \\        "websearch": "deny",
    \\        "lsp": "deny",
    \\        "doom_loop": "deny",
    \\        "skill": "deny"
    \\      }
    \\    }
    \\  }
    \\}
;

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
    /// Whether the CLI may run against a private server instead of the
    /// shared background service.
    ///
    /// This matters for opencode: the shared service keeps one project
    /// per directory, and a run that lands in a directory the service
    /// already knows about gets THAT project's configuration — not the
    /// one next to the task. A private server per run keeps the run's
    /// configuration the run's own.
    use_standalone: bool = false,
    /// The daemon's own environment — the base the overrides apply to.
    base_env: ?*const std.process.Environ.Map = null,
    /// The directory the CLI runs in. Empty means "inherit the daemon's".
    ///
    /// The agent runs in a directory of its own. For a task that only
    /// answers, that directory is empty — the agent has nothing to act on.
    /// For a task that edits code, it is a private git worktree of the
    /// user's repository.
    work_dir: []const u8 = "",
    /// Whether the agent may change files in its working directory.
    ///
    /// A task without a working directory answers from the context the
    /// server rendered, and the agent gets no tools at all — it has
    /// nothing to act on, and a tool-enabled agent pointed at an empty
    /// directory only wanders.
    can_edit: bool = false,
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
    /// The platform's opencode profile, so the caller can put the user's
    /// own file back and keep the profile out of the delivery.
    ///
    /// Null when the run never got as far as writing one.
    profile: ?ProfileBackup = null,
};

/// Find the agent CLI this machine can actually run.
///
/// Presence on PATH is not enough — the CLI has to run — so each
/// candidate is probed with `--version`. The first one that answers wins.
///
/// `ONEPERSON_AGENT_PROVIDER` names the CLI to use. Without it the
/// preference order decides, and that order is the product's, not the
/// user's: a machine with several of these CLIs installed would get the
/// first runnable one rather than the one the user meant.
pub fn detectProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
) ?Provider {
    if (forcedProvider(env)) |wanted| {
        if (probe(allocator, io, env, wanted)) {
            out.printOut("agent provider detected: {s} (named by {s})\n", .{ wanted.name(), provider_env_var });
            return wanted;
        }
        out.printErr(
            "agent provider {s} was named by {s}, but its CLI does not run here — falling back to detection\n",
            .{ wanted.name(), provider_env_var },
        );
    }
    for ([_]Provider{ .opencode, .claude, .codex, .dsh, .pi }) |p| {
        if (probe(allocator, io, env, p)) {
            out.printOut("agent provider detected: {s}\n", .{p.name()});
            return p;
        }
    }
    return null;
}

/// The provider the environment asks for, if it names one we know.
fn forcedProvider(env: ?*const std.process.Environ.Map) ?Provider {
    const env_map = env orelse return null;
    const raw = env_map.get(provider_env_var) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return Provider.fromName(trimmed);
}

fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    p: Provider,
) bool {
    const exe = resolveExecutable(allocator, io, env, p) catch return false;
    defer allocator.free(exe);
    const argv = [_][]const u8{ exe, "--version" };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term.success();
}

/// The command that runs this provider's CLI.
///
/// The provider's name is what the server and the user see; the
/// executable does not have to be called that. dsh installs a Node CLI
/// under its own home directory (`$DSH_HOME`, `~/.dsh` by default) and
/// never puts it on PATH, and pi installs its launcher under
/// `$PI_CODING_AGENT_DIR` (`~/.pi/agent` by default) — so the bare name
/// finds neither of them unless the user linked them by hand.
///
/// The caller owns the returned string.
pub fn resolveExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    p: Provider,
) ![]const u8 {
    // The name on PATH. The OS resolves it when the child is spawned,
    // and a CLI the user linked by hand is found here.
    if (try findOnPath(allocator, io, env, p.name())) |full| return full;

    switch (p) {
        .dsh => if (try findDsh(allocator, io, env)) |full| return full,
        .pi => if (try findPi(allocator, io, env)) |full| return full,
        else => {},
    }

    // Nothing found: the bare name is still the best guess. The OS
    // resolves it against PATH when the child is spawned, and reporting
    // "no CLI" for a CLI that is there would be worse.
    return allocator.dupe(u8, p.name());
}

/// The first executable file named `name` on PATH.
fn findOnPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    name: []const u8,
) !?[]const u8 {
    const env_map = env orelse return null;
    const path = env_map.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fs.path.join(allocator, &.{ dir, name });
        if (isExecutableFile(io, full)) return full;
        allocator.free(full);
    }
    return null;
}

/// The dsh CLI under the user's own dsh home.
///
/// dsh keeps its profiles under `$DSH_HOME` (`~/.dsh` by default) and
/// installs the CLI into the profiles' shared `node_modules`. A profile
/// may carry a newer copy of its own, so the profiles are searched too.
fn findDsh(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
) !?[]const u8 {
    const env_map = env orelse return null;
    const home = env_map.get("DSH_HOME") orelse blk: {
        const user_home = env_map.get("HOME") orelse return null;
        break :blk try std.fs.path.join(allocator, &.{ user_home, ".dsh" });
    };
    defer allocator.free(home);

    const profiles = try std.fs.path.join(allocator, &.{ home, "profiles" });
    defer allocator.free(profiles);

    const shared = try std.fs.path.join(allocator, &.{
        profiles, "node_modules", "@deepseek-ai", "dsh", "lib", "bin.js",
    });
    defer allocator.free(shared);
    if (isExecutableFile(io, shared)) return try allocator.dupe(u8, shared);

    var dir = std.Io.Dir.cwd().openDir(io, profiles, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const candidate = try std.fs.path.join(allocator, &.{
            profiles, entry.name, "node_modules", "@deepseek-ai", "dsh", "lib", "bin.js",
        });
        defer allocator.free(candidate);
        if (isExecutableFile(io, candidate)) return try allocator.dupe(u8, candidate);
    }
    return null;
}

/// The pi launcher under the user's own pi directory.
fn findPi(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
) !?[]const u8 {
    const env_map = env orelse return null;
    const dir = env_map.get("PI_CODING_AGENT_DIR") orelse blk: {
        const user_home = env_map.get("HOME") orelse return null;
        break :blk try std.fs.path.join(allocator, &.{ user_home, ".pi", "agent" });
    };
    defer allocator.free(dir);

    const launcher = try std.fs.path.join(allocator, &.{ dir, "bin", "pi" });
    defer allocator.free(launcher);
    if (isExecutableFile(io, launcher)) return try allocator.dupe(u8, launcher);
    return null;
}

/// Whether the path is a file that can be executed.
///
/// A directory counts as executable too, so the kind is checked as well:
/// a directory that happens to share a CLI's name would otherwise be
/// picked up and the CLI would never run.
fn isExecutableFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (stat.kind != .file) return false;
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}


/// Whether the installed CLI can run against a private server.
///
/// opencode's shared background service resolves a run's project from
/// the directory the run happens in, but it remembers that project per
/// directory — and a run that lands in a directory the service already
/// knows about is served the remembered project's configuration. The
/// profile 1Person writes next to the task is then ignored, and the run
/// dies with "agent not found". A private server per run keeps the
/// run's configuration the run's own.
///
/// The flag is optional in the CLI, so it is probed rather than assumed:
/// an older opencode does not know it and would fail on the flag.
pub fn supportsStandalone(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    p: Provider,
) bool {
    const exe = resolveExecutable(allocator, io, env, p) catch return false;
    defer allocator.free(exe);
    const argv = [_][]const u8{ exe, "run", "--help" };
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return false;
    return std.mem.indexOf(u8, result.stdout, "--standalone") != null;
}

/// The platform's own opencode profile, and the user's file it replaced.
///
/// The profile has to live inside the working directory — opencode reads
/// its project configuration from the directory it runs in, and no
/// environment variable reaches it — so it can land on top of a file the
/// user's own repository carries. The original content is kept so it can
/// be put back afterwards: the profile is the platform's configuration, not
/// the user's work, and it must not end up in the commit the task
/// delivers.
pub const ProfileBackup = struct {
    /// Where the profile was written.
    path: []const u8,
    /// The user's own file, when there was one. Null means the platform
    /// created the file and may remove it again.
    original: ?[]const u8,

    pub fn deinit(self: ProfileBackup, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.original) |o| allocator.free(o);
    }
};

/// Write the opencode profile into the task's working directory.
///
/// For a task that only answers, the profile sits at the top of the
/// directory. For a task that edits code, it goes into `.opencode/` — a
/// directory the platform owns, so the user's own opencode configuration at
/// the top of their repository is never overwritten.
///
/// The caller owns the returned backup.
pub fn prepareOpenCodeWorkspace(
    io: std.Io,
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    can_edit: bool,
) !ProfileBackup {
    const config = if (can_edit) openCodeCodingConfigJson else openCodeConfigJson;

    // The directory that holds the profile is allocated only for a task
    // that edits code, and it has to stay alive until the profile's path
    // is built from it — so it is released by the function, not by the
    // block that creates it.
    var owned_dir: ?[]const u8 = null;
    defer if (owned_dir) |d| allocator.free(d);

    const dir_path = if (can_edit) blk: {
        const joined = try std.fs.path.join(allocator, &.{ work_dir, ".opencode" });
        owned_dir = joined;
        try std.Io.Dir.cwd().createDirPath(io, joined);
        break :blk joined;
    } else work_dir;

    const path = try std.fs.path.join(allocator, &.{ dir_path, "opencode.json" });
    errdefer allocator.free(path);

    // The user's own file, if the repository carries one, is kept: the
    // platform's profile replaces it only for the length of the run.
    const original = readFileIfPresent(io, allocator, path);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var wtr = file.writer(io, &write_buf);
    try wtr.interface.writeAll(config);
    try wtr.flush();

    return .{ .path = path, .original = original };
}

/// Read a file, or report that it is not there.
fn readFileIfPresent(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch null;
}

/// Put the user's own file back and remove the platform's profile.
///
/// The profile is the platform's configuration, not the agent's work: it
/// must not end up in the commit the task delivers. A file the user's
/// repository already carried is restored byte for byte, so the delivery
/// cannot delete it.
///
/// The backup's memory is not released here — the caller owns it.
pub fn restoreOpenCodeWorkspace(io: std.Io, backup: ProfileBackup) void {
    if (backup.original) |original| {
        var file = std.Io.Dir.cwd().createFile(io, backup.path, .{ .truncate = true }) catch return;
        defer file.close(io);
        var write_buf: [4096]u8 = undefined;
        var wtr = file.writer(io, &write_buf);
        wtr.interface.writeAll(original) catch {};
        wtr.flush() catch {};
    } else {
        std.Io.Dir.cwd().deleteFile(io, backup.path) catch {};
    }

    // The directory that held the profile is removed only when nothing
    // else is in it: the user's own `.opencode/` configuration must
    // survive.
    if (std.fs.path.dirname(backup.path)) |dir| {
        if (std.mem.endsWith(u8, dir, ".opencode")) {
            std.Io.Dir.cwd().deleteDir(io, dir) catch {};
        }
    }
}

/// Put the user's own file back, remove the platform's profile and
/// release the backup's memory.
pub fn cleanupOpenCodeWorkspace(io: std.Io, allocator: std.mem.Allocator, backup: ProfileBackup) void {
    restoreOpenCodeWorkspace(io, backup);
    allocator.free(backup.path);
    if (backup.original) |o| allocator.free(o);
}

/// Build the command line for one agent run.
///
/// `exe` is the command that runs the CLI — see `resolveExecutable`.
/// The caller owns the returned list.
fn buildArgv(
    allocator: std.mem.Allocator,
    exe: []const u8,
    provider: Provider,
    req: RunRequest,
) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);

    try argv.append(allocator, exe);
    switch (provider) {
        .opencode => {
            try argv.append(allocator, "run");
            // A private server, not the shared background service: the
            // service keeps one project per directory, and a run that
            // lands in a directory it already knows about is served
            // THAT project's configuration — so the profile written next
            // to the task is ignored and the run fails with "agent not
            // found". A private server resolves the run's own directory.
            if (req.use_standalone) try argv.append(allocator, "--standalone");
            try argv.append(allocator, "--format");
            try argv.append(allocator, "json");
            // The agent has to be able to act on the task, not stop at
            // every permission prompt.
            try argv.append(allocator, "--auto");
            // The 1Person profile, not opencode's `plan` agent: `plan`
            // refuses to produce a result until the user switches it to
            // another mode, and this fork's agents are text-only — the
            // answer is posted by the server, not by the agent.
            try argv.append(allocator, "--agent");
            try argv.append(allocator, opencode_agent_id);
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
        .dsh => {
            // The headless profile answers one task and exits: the
            // answer goes to stdout, the diagnostics to stderr.
            try argv.append(allocator, "--profile");
            try argv.append(allocator, "headless");
            // A task that only answers must not be able to change
            // anything. A task that edits code stays inside the
            // directory it was given: dsh's sandbox roots at the working
            // directory, so the agent has nowhere else to write.
            try argv.append(allocator, "--permission-mode");
            try argv.append(allocator, if (req.can_edit) "workspace-write" else "read-only");
            // Nobody can answer an approval prompt in a non-interactive
            // run — the presets ask by default, so the policy has to say
            // "never" or the task waits for a user who is not there.
            try argv.append(allocator, "--approval-policy");
            try argv.append(allocator, "never");
            for (req.custom_args) |a| try argv.append(allocator, a);
            // `--` so a task that starts with a dash is read as the task
            // and not as a flag.
            try argv.append(allocator, "--");
            try argv.append(allocator, req.prompt);
        },
        .pi => {
            // `-p` is pi's non-interactive mode: the prompt is processed
            // and the process exits.
            try argv.append(allocator, "-p");
            try argv.append(allocator, "--mode");
            try argv.append(allocator, "text");
            // No session file: the daemon runs one task after another,
            // and a session per task would pile up in the user's own
            // directory.
            try argv.append(allocator, "--no-session");
            // A task that only answers gets no tools: it has nothing to
            // act on, and a tool-enabled agent pointed at an empty
            // directory only wanders. A task that edits code works in
            // the private worktree the platform prepared, so the files
            // in it are the user's own and are trusted.
            if (req.can_edit) {
                try argv.append(allocator, "--approve");
            } else {
                try argv.append(allocator, "--no-tools");
                try argv.append(allocator, "--no-approve");
            }
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
    }
    return argv;
}

/// Run one agent task with the local CLI.
///
/// The caller owns `outcome.output` and `outcome.failure`. On a non-zero
/// exit the CLI's stderr is returned as the output — a failed run has to
/// say why, and the CLI is the only one that knows.
pub fn runAgent(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    req: RunRequest,
) !RunOutcome {
    // The profile backup travels out with the outcome so the caller can
    // put the user's own file back.
    var profile_backup: ?ProfileBackup = null;
    defer if (profile_backup) |*b| b.deinit(allocator);
    // A run that never gets as far as producing an outcome has to put the
    // user's own file back by itself: the platform's profile would
    // otherwise stay in the working directory and be carried into the
    // commit the task delivers.
    errdefer if (profile_backup) |b| restoreOpenCodeWorkspace(io, b);

    if (provider == .opencode) {
        // The profile lives in the task's working directory, so the
        // directory has to exist: an agent without one would run in the
        // daemon's own directory, and would run with no profile at all.
        if (req.work_dir.len == 0) {
            return RunOutcome{
                .output = "",
                .exit_code = null,
                .failure = try allocator.dupe(u8, "the daemon could not prepare a private working directory for the agent"),
            };
        }
        const backup = prepareOpenCodeWorkspace(io, allocator, req.work_dir, req.can_edit) catch |err| {
            return RunOutcome{
                .output = "",
                .exit_code = null,
                .failure = try std.fmt.allocPrint(allocator, "the daemon could not write the agent's opencode profile ({s})", .{@errorName(err)}),
            };
        };
        // The backup travels with the outcome: the caller puts the user's
        // own file back once the run is over.
        profile_backup = backup;
    }

    // The command that runs the CLI. It is not always the provider's
    // name: dsh and pi install themselves outside PATH.
    const exe = resolveExecutable(allocator, io, req.base_env, provider) catch |err| {
        return RunOutcome{
            .output = "",
            .exit_code = null,
            .failure = try std.fmt.allocPrint(allocator, "the daemon could not find the {s} CLI ({s})", .{ provider.name(), @errorName(err) }),
        };
    };
    defer allocator.free(exe);

    var argv = try buildArgv(allocator, exe, provider, req);
    defer argv.deinit(allocator);

    // The child gets the daemon's environment plus the agent's overrides.
    var env: ?std.process.Environ.Map = null;
    defer if (env) |*e| e.deinit();
    if (try buildEnv(allocator, req)) |e| env = e;

    out.printOut("agent run: provider={s} cwd={s}\n", .{ provider.name(), req.work_dir });
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
            .profile = if (profile_backup) |b| blk: {
                // The backup moves to the caller; the local copy is
                // released so it is not freed twice.
                const moved = b;
                profile_backup = null;
                break :blk moved;
            } else null,
        };
    }

    const answer = try extractAnswer(allocator, provider, result.stdout);
    return RunOutcome{
        .output = answer,
        .exit_code = exit_code,
        .profile = if (profile_backup) |b| blk: {
            const moved = b;
            profile_backup = null;
            break :blk moved;
        } else null,
    };
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
        .pi => {
            if (try piErrorMessage(allocator, stderr)) |msg| return msg;
        },
        // dsh explains itself on stderr ("dsh: MISSING_CREDENTIAL: ..."),
        // so the generic fallback below already carries the reason.
        .codex, .dsh => {},
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

/// Pull the message out of pi's error line.
///
/// pi reports a refused request as `<code>: {"message": "...", "type":
/// "..."}` on stderr. The JSON carries the sentence a user can act on;
/// the bare status code does not.
fn piErrorMessage(allocator: std.mem.Allocator, stderr: []const u8) !?[]const u8 {
    const line = firstLine(stderr);
    if (line.len == 0) return null;
    const brace = std.mem.indexOfScalar(u8, line, '{') orelse return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line[brace..], .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const message = root.object.get("message") orelse return null;
    if (message != .string) return null;
    const trimmed = std.mem.trim(u8, message.string, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

/// Build the child environment: the daemon's own, plus the agent's
/// overrides, plus a `PWD` that agrees with the child's directory.
///
/// The `PWD` matters more than it looks: opencode resolves the
/// project — and with it the configuration it reads — from `PWD`, not
/// from the process's actual directory. A daemon that changes the
/// child's directory without fixing `PWD` leaves the two disagreeing,
/// and the CLI then looks for its configuration in the daemon's
/// directory and misses the profile written next to the task.
fn buildEnv(allocator: std.mem.Allocator, req: RunRequest) !?std.process.Environ.Map {
    const overrides = req.custom_env;
    const has_overrides = if (overrides) |o| o == .object and o.object.count() > 0 else false;
    const needs_pwd = req.work_dir.len > 0 and req.base_env != null;
    if (!has_overrides and !needs_pwd) return null;

    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    if (req.base_env) |base| try map.putAll(base);

    if (needs_pwd) try map.put("PWD", req.work_dir);

    if (has_overrides) {
        var it = overrides.?.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            try map.put(entry.key_ptr.*, entry.value_ptr.*.string);
        }
    }
    return map;
}

/// Pull the agent's answer out of the CLI's output.
fn extractAnswer(allocator: std.mem.Allocator, provider: Provider, stdout: []const u8) ![]const u8 {
    return switch (provider) {
        .opencode => extractOpenCodeText(allocator, stdout),
        .claude => extractClaudeResult(allocator, stdout),
        // These three print the answer as plain text: codex on stdout,
        // dsh through its headless profile, pi in text mode. dsh puts
        // its diagnostics on stderr, so stdout carries the answer alone.
        .codex => allocator.dupe(u8, std.mem.trim(u8, stdout, " \t\r\n")),
        .dsh => allocator.dupe(u8, std.mem.trim(u8, stdout, " \t\r\n")),
        .pi => allocator.dupe(u8, std.mem.trim(u8, stdout, " \t\r\n")),
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
    try testing.expectEqual(Provider.dsh, Provider.fromName("dsh").?);
    try testing.expectEqual(Provider.pi, Provider.fromName("pi").?);
    try testing.expect(Provider.fromName("auto") == null);
    try testing.expect(Provider.fromName("") == null);
}

test "the environment can name the provider to run" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    try testing.expect(forcedProvider(&env) == null);

    try env.put("ONEPERSON_AGENT_PROVIDER", "pi");
    try testing.expectEqual(Provider.pi, forcedProvider(&env).?);

    // A name nobody knows is not a provider: the daemon falls back to
    // detection rather than refusing to run at all.
    try env.put("ONEPERSON_AGENT_PROVIDER", "nope");
    try testing.expect(forcedProvider(&env) == null);

    // Whitespace around the name is noise from a copy-paste.
    try env.put("ONEPERSON_AGENT_PROVIDER", " dsh\n");
    try testing.expectEqual(Provider.dsh, forcedProvider(&env).?);
}

test "dsh answers one task through the headless profile" {
    var argv = try buildArgv(testing.allocator, "dsh", .dsh, .{ .prompt = "做一件事" });
    defer argv.deinit(testing.allocator);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (argv.items) |a| {
        try joined.appendSlice(testing.allocator, a);
        try joined.append(testing.allocator, ' ');
    }

    try testing.expect(std.mem.indexOf(u8, joined.items, "--profile headless ") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "-- 做一件事 ") != null);
}

test "dsh never asks for approval in a non-interactive run" {
    // The permission presets ask by default, and nobody is there to
    // answer: the run would wait until the task timed out.
    var argv = try buildArgv(testing.allocator, "dsh", .dsh, .{ .prompt = "做一件事" });
    defer argv.deinit(testing.allocator);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (argv.items) |a| {
        try joined.appendSlice(testing.allocator, a);
        try joined.append(testing.allocator, ' ');
    }

    try testing.expect(std.mem.indexOf(u8, joined.items, "--approval-policy never ") != null);
}

test "dsh keeps an editing task inside its own directory" {
    var argv = try buildArgv(testing.allocator, "dsh", .dsh, .{
        .prompt = "做一件事",
        .can_edit = true,
    });
    defer argv.deinit(testing.allocator);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (argv.items) |a| {
        try joined.appendSlice(testing.allocator, a);
        try joined.append(testing.allocator, ' ');
    }

    // The sandbox roots at the working directory, so the agent has
    // nowhere else to write.
    try testing.expect(std.mem.indexOf(u8, joined.items, "--permission-mode workspace-write ") != null);
}

test "a task that only answers gets no write access" {
    var argv = try buildArgv(testing.allocator, "dsh", .dsh, .{ .prompt = "做一件事" });
    defer argv.deinit(testing.allocator);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (argv.items) |a| {
        try joined.appendSlice(testing.allocator, a);
        try joined.append(testing.allocator, ' ');
    }

    try testing.expect(std.mem.indexOf(u8, joined.items, "--permission-mode read-only ") != null);
}

test "pi runs non-interactively and leaves no session behind" {
    var argv = try buildArgv(testing.allocator, "pi", .pi, .{ .prompt = "做一件事" });
    defer argv.deinit(testing.allocator);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (argv.items) |a| {
        try joined.appendSlice(testing.allocator, a);
        try joined.append(testing.allocator, ' ');
    }

    try testing.expect(std.mem.indexOf(u8, joined.items, "-p ") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "--mode text ") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "--no-session ") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "-- 做一件事 ") != null);
}

test "a task that only answers gives pi no tools" {
    var argv = try buildArgv(testing.allocator, "pi", .pi, .{ .prompt = "做一件事" });
    defer argv.deinit(testing.allocator);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (argv.items) |a| {
        try joined.appendSlice(testing.allocator, a);
        try joined.append(testing.allocator, ' ');
    }

    try testing.expect(std.mem.indexOf(u8, joined.items, "--no-tools ") != null);
}

test "an editing task keeps pi's tools" {
    var argv = try buildArgv(testing.allocator, "pi", .pi, .{
        .prompt = "做一件事",
        .can_edit = true,
    });
    defer argv.deinit(testing.allocator);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (argv.items) |a| {
        try joined.appendSlice(testing.allocator, a);
        try joined.append(testing.allocator, ' ');
    }

    try testing.expect(std.mem.indexOf(u8, joined.items, "--no-tools") == null);
}

test "dsh and pi answer with the text on stdout" {
    const dsh_answer = try extractAnswer(testing.allocator, .dsh, "最终答案\n");
    defer testing.allocator.free(dsh_answer);
    try testing.expectEqualStrings("最终答案", dsh_answer);

    const pi_answer = try extractAnswer(testing.allocator, .pi, "最终答案\n");
    defer testing.allocator.free(pi_answer);
    try testing.expectEqualStrings("最终答案", pi_answer);
}

test "pi's error line becomes a readable reason" {
    // The shape pi prints on stderr when the request is refused.
    const stderr = "403: {\"message\":\"Your current subscription does not have access to Kimi Code right now.\",\"type\":\"permission_denied_error\"}\n";
    const reason = try describeFailure(testing.allocator, .pi, "", stderr);
    defer testing.allocator.free(reason);
    try testing.expectEqualStrings(
        "Your current subscription does not have access to Kimi Code right now.",
        reason,
    );
}

test "dsh's own message is the reason" {
    // dsh explains itself on stderr and says nothing on stdout.
    const stderr = "dsh: MISSING_CREDENTIAL: llm-deepseek: no API key for provider route \"deepseek-official\"\n";
    const reason = try describeFailure(testing.allocator, .dsh, "", stderr);
    defer testing.allocator.free(reason);
    try testing.expectEqualStrings(
        "dsh: MISSING_CREDENTIAL: llm-deepseek: no API key for provider route \"deepseek-official\"",
        reason,
    );
}

test "the dsh CLI is found in the user's own dsh home" {
    // dsh installs itself under its own home directory and never puts
    // it on PATH — a daemon that only looked at PATH would never find
    // it.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".dsh/profiles/node_modules/@deepseek-ai/dsh/lib");
    const cli = ".dsh/profiles/node_modules/@deepseek-ai/dsh/lib/bin.js";
    var file = try tmp.dir.createFile(io, cli, .{});
    file.close(io);
    try tmp.dir.setFilePermissions(io, cli, @enumFromInt(0o755), .{});

    const home = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(home);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", home);
    // An empty PATH: the CLI is nowhere on it.
    try env.put("PATH", "");

    const exe = try resolveExecutable(testing.allocator, io, &env, .dsh);
    defer testing.allocator.free(exe);
    try testing.expect(std.mem.endsWith(u8, exe, ".dsh/profiles/node_modules/@deepseek-ai/dsh/lib/bin.js"));
}

test "the pi launcher is found in the user's own pi directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".pi/agent/bin");
    const cli = ".pi/agent/bin/pi";
    var file = try tmp.dir.createFile(io, cli, .{});
    file.close(io);
    try tmp.dir.setFilePermissions(io, cli, @enumFromInt(0o755), .{});

    const home = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(home);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("PATH", "");

    const exe = try resolveExecutable(testing.allocator, io, &env, .pi);
    defer testing.allocator.free(exe);
    try testing.expect(std.mem.endsWith(u8, exe, ".pi/agent/bin/pi"));
}

test "a file that cannot be executed is not a CLI" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".pi/agent/bin");
    const cli = ".pi/agent/bin/pi";
    var file = try tmp.dir.createFile(io, cli, .{});
    file.close(io);
    // No execute bit: the file is there, but it cannot be run.

    const home = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(home);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("PATH", "");

    // Nothing found: the bare name is still the answer, because the OS
    // resolves it against PATH when the child is spawned.
    const exe = try resolveExecutable(testing.allocator, io, &env, .pi);
    defer testing.allocator.free(exe);
    try testing.expectEqualStrings("pi", exe);
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

test "opencode runs the 1Person profile, not opencode's plan agent" {
    // opencode's `plan` agent refuses to produce a result until the
    // user switches it to another mode, so a task that asks for an
    // answer comes back with "switch me to build mode" instead.
    var argv = try buildArgv(testing.allocator, "opencode", .opencode, .{
        .prompt = "做一件事",
        .model = "opencode/some-model",
    });
    defer argv.deinit(testing.allocator);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (argv.items) |a| {
        try joined.appendSlice(testing.allocator, a);
        try joined.append(testing.allocator, ' ');
    }

    try testing.expect(std.mem.indexOf(u8, joined.items, "--agent 1p ") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "plan") == null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "--model opencode/some-model ") != null);
}

test "opencode runs against a private server when the CLI can do that" {
    // The shared background service remembers one project per directory
    // and serves THAT project's configuration to a run that lands in a
    // directory it already knows — so the profile written next to the
    // task is ignored and the run dies with "agent not found".
    var argv = try buildArgv(testing.allocator, "opencode", .opencode, .{
        .prompt = "做一件事",
        .use_standalone = true,
    });
    defer argv.deinit(testing.allocator);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (argv.items) |a| {
        try joined.appendSlice(testing.allocator, a);
        try joined.append(testing.allocator, ' ');
    }

    try testing.expect(std.mem.indexOf(u8, joined.items, "--standalone ") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "--agent 1p ") != null);
}

test "opencode without a private server still uses the 1Person profile" {
    var argv = try buildArgv(testing.allocator, "opencode", .opencode, .{ .prompt = "做一件事" });
    defer argv.deinit(testing.allocator);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (argv.items) |a| {
        try joined.appendSlice(testing.allocator, a);
        try joined.append(testing.allocator, ' ');
    }

    try testing.expect(std.mem.indexOf(u8, joined.items, "--standalone") == null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "--agent 1p ") != null);
}

test "the opencode profile answers directly and has no tools" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, openCodeConfigJson, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expect(root == .object);

    const agent = root.object.get("agent") orelse return error.TestExpectedEqual;
    try testing.expect(agent == .object);
    const profile = agent.object.get(opencode_agent_id) orelse return error.TestExpectedEqual;
    try testing.expect(profile == .object);

    // The profile has to be a primary agent, or it cannot be selected
    // with `--agent`.
    const mode = profile.object.get("mode") orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("primary", mode.string);

    // The prompt has to ask for the answer, not for a plan.
    const prompt = profile.object.get("prompt") orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, prompt.string, "your whole reply is the deliverable") != null);
    try testing.expect(std.mem.indexOf(u8, prompt.string, "do not propose a plan") != null);

    // Every tool has to be denied: the agent answers, it does not act on
    // the machine.
    const permission = profile.object.get("permission") orelse return error.TestExpectedEqual;
    try testing.expect(permission == .object);
    const denied = [_][]const u8{
        "read",   "edit",     "glob",       "grep",        "list",
        "bash",   "task",     "todowrite",  "question",    "webfetch",
        "websearch", "lsp",   "skill",      "external_directory",
    };
    for (denied) |tool| {
        const rule = permission.object.get(tool) orelse return error.TestExpectedEqual;
        try testing.expectEqualStrings("deny", rule.string);
    }
}

/// A temporary directory the profile tests can write into.
fn tempDir() !struct { dir: std.testing.TmpDir, path: []const u8 } {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(zfinal.io_instance.io, &buf);
    return .{ .dir = tmp, .path = buf[0..len] };
}

test "the coding profile is written where the agent will find it" {
    // Regression: the directory that holds the profile was released by a
    // `defer` inside the block that created it, so the path built from
    // it afterwards was built from freed memory and the file could not
    // be created. Every coding task failed before the agent even ran.
    const allocator = testing.allocator;
    const io = zfinal.io_instance.io;

    var tmp = try tempDir();
    defer tmp.dir.cleanup();

    const backup = try prepareOpenCodeWorkspace(io, allocator, tmp.path, true);
    const profile_path = try allocator.dupe(u8, backup.path);
    defer allocator.free(profile_path);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, profile_path, allocator, .limited(64 * 1024));
    defer allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"edit\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"bash\"") != null);

    cleanupOpenCodeWorkspace(io, allocator, backup);

    // The platform's profile is gone again: it is the platform's
    // configuration, not the agent's work, and it must not end up in the
    // commit the task delivers.
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().readFileAlloc(io, profile_path, allocator, .limited(64 * 1024)),
    );
}

test "the answering profile is written at the top of the working directory" {
    const allocator = testing.allocator;
    const io = zfinal.io_instance.io;

    var tmp = try tempDir();
    defer tmp.dir.cleanup();

    const backup = try prepareOpenCodeWorkspace(io, allocator, tmp.path, false);
    defer cleanupOpenCodeWorkspace(io, allocator, backup);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, backup.path, allocator, .limited(64 * 1024));
    defer allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"1p\"") != null);
}

test "the coding profile lets the agent change the code it was given" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, openCodeCodingConfigJson, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try testing.expect(root == .object);

    const agent = root.object.get("agent") orelse return error.TestExpectedEqual;
    try testing.expect(agent == .object);
    const profile = agent.object.get(opencode_agent_id) orelse return error.TestExpectedEqual;
    try testing.expect(profile == .object);

    const mode = profile.object.get("mode") orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("primary", mode.string);

    const permission = profile.object.get("permission") orelse return error.TestExpectedEqual;
    try testing.expect(permission == .object);

    // The tools a coding task needs.
    const allowed = [_][]const u8{ "read", "edit", "glob", "grep", "list", "bash" };
    for (allowed) |tool| {
        const rule = permission.object.get(tool) orelse return error.TestExpectedEqual;
        try testing.expectEqualStrings("allow", rule.string);
    }

    // The two that must stay closed even here: the agent stays inside its
    // checkout, and it cannot ask the user anything (nobody would answer,
    // so the task would hang until it timed out).
    const denied = [_][]const u8{ "external_directory", "question", "webfetch", "websearch" };
    for (denied) |tool| {
        const rule = permission.object.get(tool) orelse return error.TestExpectedEqual;
        try testing.expectEqualStrings("deny", rule.string);
    }

    // The agent must not commit: the platform delivers the work.
    const prompt = profile.object.get("prompt") orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, prompt.string, "Do not commit") != null);
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
