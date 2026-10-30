//! Daemon module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_daemons`
//! registry) and the no-DB fallbacks for every route. The actual task
//! queue lives in `src/task_queue.zig` and the runtime result stores
//! live in `src/modules/runtime/service.zig`; the daemon service is
//! the bridge between the HTTP surface and those subsystems.
//!
//! All public functions take `*zfinal.Context` and follow the
//! 1-handler-per-route shape; the corresponding `handler.zig` is a
//! thin delegate. SQL helpers and data structs live in `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const auth_lib = @import("../../auth.zig");
const runtime = @import("../runtime/service.zig");
const runtime_model = @import("../runtime/model.zig");
const task_queue = @import("../../task_queue.zig");
const model = @import("model.zig");
const agent_task = @import("agent_task.zig");
const prompt_mod = @import("prompt.zig");
const response = @import("../../common/response.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");

const log = std.log.scoped(.daemon_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_daemons: ?std.StringHashMap(model.DaemonEntry) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

// ──────────────────────────────────────────────────────────────────────
// helpers
// ──────────────────────────────────────────────────────────────────────

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn nowMillis() i64 {
    return std.Io.Timestamp.now(zfinal.io_instance.io, .real).toMilliseconds();
}

fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ seed, ns });
    defer allocator.free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try allocator.alloc(u8, 36);
    const charset = "0123456789abcdef";
    var o: usize = 0;
    for (hash[0..16], 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            hex[o] = '-';
            o += 1;
        }
        hex[o] = charset[b >> 4];
        hex[o + 1] = charset[b & 0x0f];
        o += 2;
    }
    return hex;
}

fn memDup(s: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, s);
}

fn jsonObjectGetString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getWorkspaceId(ctx);
    }

fn memInit() !void {
    if (mem_daemons == null) {
        mem_daemons = std.StringHashMap(model.DaemonEntry).init(memAlloc());
    }
}

// ──────────────────────────────────────────────────────────────────────
// Daemon token minting
// ──────────────────────────────────────────────────────────────────────

/// Mint a daemon credential bound to a workspace. Requires a valid user
/// token (the global auth interceptor stamps user_id) plus workspace
/// membership. The returned token is `1d_<40 hex>` and is stored
/// SHA-256-hashed in daemon_token, so DaemonAuth can verify it in DB
/// mode. This is the missing creation half of the daemon-token lifecycle
/// (Go's GenerateDaemonToken + CreateDaemonToken).
pub fn mintDaemonToken(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const user_id = ctx.attributes.get("user_id") orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.MintDaemonTokenRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.workspace_id.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    }

    // Minting persists to the daemon_token table; refuse in no-DB mode
    // rather than minting a credential that DaemonAuth can never verify.
    if (!deps.hasPool()) {
        ctx.res_status = .service_unavailable;
        try ctx.renderJson(.{ .@"error" = "database_required" });
        return;
    }

    if (!model.userIsWorkspaceMember(user_id, req.workspace_id)) {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = "not a workspace member" });
        return;
    }

    const ttl_days = req.ttl_days orelse 30;
    if (ttl_days < 1 or ttl_days > 365) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "ttl_days must be between 1 and 365" });
        return;
    }

    // 1d_ + 40 random hex chars (matches Go GenerateDaemonToken). The
    // hex part IS the daemon_id — DaemonAuth compares the token's
    // embedded id against the stored daemon_id column.
    var bytes: [20]u8 = undefined;
    try zfinal.io_instance.io.randomSecure(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    const token = try std.fmt.allocPrint(allocator, "1d_{s}", .{hex});
    defer allocator.free(token);
    const daemon_id = token["1d_".len..];

    const token_hash = try auth_lib.hashToken(allocator, token);
    defer allocator.free(token_hash);

    if (!model.insertDaemonToken(req.workspace_id, daemon_id, token_hash, ttl_days, user_id)) {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "failed to store daemon token" });
        return;
    }

    try ctx.renderJson(.{
        .token = token,
        .daemon_id = daemon_id,
        .workspace_id = req.workspace_id,
        .ttl_days = ttl_days,
    });
}

// ──────────────────────────────────────────────────────────────────────
// Daemon registry and heartbeat
// ──────────────────────────────────────────────────────────────────────

pub fn daemonRegister(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const parsed = try ctx.parseJsonBody(model.DaemonRegisterRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.runtime_id.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    }

    const daemon_id = try generateId(allocator, req.runtime_id);

    const name = if (req.name) |n| try memDup(n) else try memDup("daemon");

    // The token carries the identity the runtime row must be owned by:
    // the workspace it is bound to and the member who paired the
    // machine. Without them the runtime stays ownerless, and an
    // ownerless runtime is invisible to the picker's "mine" filter and
    // marked locked — the daemon would be running but unusable.
    //
    // A token minted before the owner column existed has no owner; fall
    // back to the workspace owner so an already-paired daemon still
    // becomes usable.
    const token_workspace_id = ctx.attributes.get("daemon_workspace_id") orelse "";
    const token_owner_id = ctx.attributes.get("daemon_owner_id") orelse "";

    if (token_workspace_id.len > 0) {
        // A runtime belongs to exactly one workspace. Refuse to re-point
        // a row that already lives in another workspace — that would let
        // a daemon from workspace B hijack workspace A's machine.
        const existing_ws = try model.runtimeWorkspaceId(allocator, req.runtime_id);
        defer if (existing_ws) |ws| allocator.free(ws);
        if (existing_ws) |ws| {
            if (!std.mem.eql(u8, ws, token_workspace_id)) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "runtime_id belongs to another workspace" });
                return;
            }
        }

        // The token owner is authoritative. Only a token minted before
        // the owner column existed falls back to the workspace owner.
        var owner_buf: ?[]const u8 = null;
        defer if (owner_buf) |b| allocator.free(b);
        const owner_id = if (token_owner_id.len > 0) token_owner_id else blk: {
            const ws_owner = try model.workspaceOwnerId(allocator, token_workspace_id);
            if (ws_owner) |w| {
                owner_buf = w;
                break :blk w;
            }
            break :blk "";
        };

        _ = model.upsertRuntimeForDaemon(
            req.runtime_id,
            token_workspace_id,
            owner_id,
            name,
            if (req.provider) |p| p else "",
        );
    }

    // A registering daemon brings its runtime online (DB mode). Mirrors
    // the Go daemonws handshake, which flips agent_runtime to online on
    // connect so runtime-scoped requests (update/models/local-skills)
    // are accepted while the daemon is serving.
    _ = model.setRuntimeStatus(req.runtime_id, "online");

    // The daemon reports the version of the 1p CLI it runs. It lands on
    // the runtime row's `metadata.cli_version`, which is where both the
    // frontend picker and the server-side quick-create gate read it
    // from. A daemon that reports nothing leaves the key absent, and the
    // gate treats that as "version unknown" — fail closed.
    if (req.cli_version) |version| {
        if (version.len > 0) {
            _ = runtime_model.setRuntimeCliVersion(req.runtime_id, version);
        }
    }

    // The capability list is what makes the persistent agent-task queue
    // reachable for this runtime: a daemon that says it can execute agent
    // tasks is offered them, an older one keeps seeing only the
    // maintenance tasks it understands.
    if (req.capabilities) |caps| {
        if (caps == .array and caps.array.items.len > 0) {
            const caps_json = zfinal.JsonKit.stringify(allocator, caps) catch "";
            defer if (caps_json.len > 0) allocator.free(caps_json);
            if (caps_json.len > 0) {
                _ = model.setRuntimeCapabilities(req.runtime_id, caps_json);
            }
        }
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const runtime_id_dup = try memDup(req.runtime_id);
    try mem_daemons.?.put(daemon_id, model.DaemonEntry{
        .id = try memDup(daemon_id),
        .runtime_id = runtime_id_dup,
        .name = name,
        .last_seen_at = nowMillis(),
    });

    try ctx.renderJson(.{
        .daemon_id = daemon_id,
        .runtime_id = req.runtime_id,
    });
}

pub fn daemonDeregister(ctx: *zfinal.Context) !void {
    // The daemon id is carried by the `1d_<id>` token, not by a
    // path param (Go's `/api/daemon/deregister` is a single endpoint
    // shared by every daemon).
    const daemon_id = ctx.attributes.get("daemon_id") orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "daemon_token_required" });
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    // Flip the runtime offline when the last serving daemon deregisters.
    if (mem_daemons.?.getPtr(daemon_id)) |entry| {
        _ = model.setRuntimeStatus(entry.runtime_id, "offline");
    }
    _ = mem_daemons.?.remove(daemon_id);
    try response.okNoContent(ctx);
}

pub fn daemonHeartbeat(ctx: *zfinal.Context) !void {
    const daemon_id = ctx.attributes.get("daemon_id") orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "daemon_token_required" });
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    if (mem_daemons.?.getPtr(daemon_id)) |entry| {
        entry.last_seen_at = nowMillis();
    }
    try ctx.renderJson(.{ .ok = true });
}

pub fn daemonWebSocket(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;

    const upgrade = ctx.getHeader("upgrade") orelse "";
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_websocket_upgrade" });
        return;
    }
    const sec_key = ctx.getHeader("sec-websocket-key") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing_sec_websocket_key" });
        return;
    };

    // Daemon authentication: `Bearer 1d_<daemon_id>`. The global
    // AuthInterceptor only marks `1d_` tokens; the daemon id is
    // resolved here (mirrors the Go daemonws handshake, which derives
    // the identity from the daemon token before upgrading).
    const token = @import("../../auth.zig").tokenFromRequest(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "missing_token" });
        return;
    };
    const daemon_id = @import("../../auth.zig").daemonIdFromToken(token) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "invalid_token" });
        return;
    };
    const daemon_id_copy = try allocator.dupe(u8, daemon_id);
    defer allocator.free(daemon_id_copy);

    var ws = try ctx.req.respondWebSocket(.{ .key = sec_key });

    const greeting = try std.fmt.allocPrint(allocator, "{{\"type\":\"daemon:connected\",\"daemon_id\":\"{s}\"}}", .{daemon_id});
    defer allocator.free(greeting);
    ws.writeMessage(greeting, .text) catch return;

    // The daemon declares the runtimes it services via `?runtime_ids=a,b`
    // (same contract as the Go daemonws handshake). Register the
    // connection so task enqueues can push `daemon:task_available`.
    var runtime_ids: std.ArrayList([]const u8) = .empty;
    defer runtime_ids.deinit(allocator);
    if (try ctx.getPara("runtime_ids")) |raw| {
        if (raw.len > 0) {
            var it = std.mem.splitScalar(u8, raw, ',');
            while (it.next()) |rid| {
                const trimmed = std.mem.trim(u8, rid, &std.ascii.whitespace);
                if (trimmed.len > 0) try runtime_ids.append(allocator, trimmed);
            }
        }
    }
    const daemon_notify = @import("../../daemon_notify.zig");
    daemon_notify.register(runtime_ids.items, &ws);
    defer daemon_notify.unregister(runtime_ids.items, &ws);

    // Frame loop: answer `daemon:heartbeat` with `daemon:heartbeat_ack`
    // and treat any text frame as liveness. Mirrors the subset of the
    // Go daemonws protocol that zserver supports (task push is not
    // wired yet — daemons poll claim via HTTP instead).
    while (true) {
        const msg = ws.readSmallMessage() catch break;
        switch (msg.opcode) {
            .text, .binary => {
                const text = allocator.dupe(u8, msg.data) catch continue;
                defer allocator.free(text);
                // {"type":"daemon:heartbeat", ...} → ack
                if (std.mem.indexOf(u8, text, "daemon:heartbeat") != null) {
                    const ack = "{\"type\":\"daemon:heartbeat_ack\"}";
                    ws.writeMessage(ack, .text) catch break;
                }
                // Keep the daemon's in-memory last_seen_at fresh.
                try mem_mutex.lock(zfinal.io_instance.io);
                if (mem_daemons) |*m| {
                    if (m.getPtr(daemon_id_copy)) |entry| entry.last_seen_at = nowMillis();
                }
                mem_mutex.unlock(zfinal.io_instance.io);
            },
            .ping => ws.writeMessage(msg.data, .pong) catch break,
            else => break,
        }
    }
}

// ──────────────────────────────────────────────────────────────────────
// Workspace repos
// ──────────────────────────────────────────────────────────────────────

pub fn getDaemonWorkspaceRepos(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const raw = model.selectWorkspaceRepos(workspace_id) catch |err| switch (err) {
            error.WorkspaceNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "workspace not found" });
                return;
            },
            else => {
                log.err("getDaemonWorkspaceRepos: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{ .repos = raw });
    } else {
        try ctx.renderJson(.{ .repos = "[]" });
    }
}

// ──────────────────────────────────────────────────────────────────────
// Async runtime result reporting
// ──────────────────────────────────────────────────────────────────────

pub fn reportUpdateResult(ctx: *zfinal.Context) !void {
    const update_id = ctx.getPathParam("updateId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "update_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(std.json.Value);
    defer parsed.deinit();
    const req = parsed.value;

    if (req == .object) {
        if (jsonObjectGetString(req.object, "error")) |err| {
            runtime.updateStoreFail(update_id, err);
        } else {
            const output = jsonObjectGetString(req.object, "output") orelse "ok";
            runtime.updateStoreComplete(update_id, output);
        }
    } else {
        runtime.updateStoreComplete(update_id, "ok");
    }
    try ctx.renderJson(.{ .success = true });
}

pub fn reportModelListResult(ctx: *zfinal.Context) !void {
    const request_id = ctx.getPathParam("requestId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "request_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(std.json.Value);
    defer parsed.deinit();
    const req = parsed.value;

    if (req == .object) {
        if (jsonObjectGetString(req.object, "error")) |err| {
            runtime.modelStoreFail(request_id, err);
        } else {
            const supported = if (req.object.get("supported")) |v| v == .bool and v.bool else false;
            runtime.modelStoreComplete(request_id, &[_]runtime.ModelEntry{}, supported);
        }
    } else {
        runtime.modelStoreComplete(request_id, &[_]runtime.ModelEntry{}, false);
    }
    try ctx.renderJson(.{ .success = true });
}

pub fn reportLocalSkillListResult(ctx: *zfinal.Context) !void {
    const request_id = ctx.getPathParam("requestId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "request_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(std.json.Value);
    defer parsed.deinit();
    const req = parsed.value;

    if (req == .object) {
        if (jsonObjectGetString(req.object, "error")) |err| {
            runtime.localSkillStoreFail(request_id, err);
        } else {
            const supported = if (req.object.get("supported")) |v| v == .bool and v.bool else false;
            runtime.localSkillStoreComplete(request_id, &[_]runtime.RuntimeLocalSkillSummary{}, supported);
        }
    } else {
        runtime.localSkillStoreComplete(request_id, &[_]runtime.RuntimeLocalSkillSummary{}, false);
    }
    try ctx.renderJson(.{ .success = true });
}

pub fn reportLocalSkillImportResult(ctx: *zfinal.Context) !void {
    const request_id = ctx.getPathParam("requestId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "request_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(std.json.Value);
    defer parsed.deinit();
    const req = parsed.value;

    if (req == .object) {
        if (jsonObjectGetString(req.object, "error")) |err| {
            runtime.localImportStoreFail(request_id, err);
        } else {
            runtime.localImportStoreComplete(request_id, std.json.Value{ .null = {} });
        }
    } else {
        runtime.localImportStoreComplete(request_id, std.json.Value{ .null = {} });
    }
    try ctx.renderJson(.{ .success = true });
}

// ──────────────────────────────────────────────────────────────────────
// Task lifecycle
// ──────────────────────────────────────────────────────────────────────

pub fn getTaskStatus(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const row = model.selectTaskStatus(task_id) catch |err| switch (err) {
            error.TaskNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "task not found" });
                return;
            },
            else => {
                log.err("getTaskStatus: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{
            .task_id = task_id,
            .status = row.status,
            .@"error" = row.@"error",
        });
    } else {
        const entry = try task_queue.getStatus(task_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "task not found" });
            return;
        };
        try ctx.renderJson(.{
            .task_id = task_id,
            .status = entry.status,
            .@"error" = entry.@"error",
        });
    }
}

pub fn claimTaskByRuntime(ctx: *zfinal.Context) !void {
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };
    const allocator = ctx.allocator;

    // Agent tasks (chat replies, issue work) live in the persistent
    // `agent_task_queue` and are only offered to a daemon that advertised
    // the `agent_tasks` capability — an older daemon must keep seeing only
    // the maintenance tasks it understands.
    if (model.runtimeSupportsAgentTasks(runtime_id)) {
        const claimed = renderAgentTaskClaim(ctx, allocator, runtime_id) catch |err| blk: {
            log.warn("agent task claim failed: {}", .{err});
            break :blk false;
        };
        if (claimed) return;
    }

    // Maintenance tasks (update / models / local_skills / import) stay in
    // the in-memory queue.
    const task = try task_queue.claim(runtime_id);
    if (task) |t| {
        try ctx.renderJson(.{ .task = .{
            .kind = "maintenance",
            .id = t.id,
            .runtime_id = t.runtime_id,
            .task_type = t.task_type,
            .status = t.status,
            .progress = t.progress,
            .payload = t.payload,
            .@"error" = t.@"error",
            .session_id = t.session_id,
            .work_dir = t.work_dir,
        } });
    } else {
        try ctx.renderJson(.{ .task = null });
    }
}

/// The payload handed to a daemon for one agent task.
///
/// Self-contained on purpose: the daemon runs a local agent CLI, and
/// everything that CLI needs — the rendered prompt, the model, the
/// environment, the provider — travels with the task. The daemon never
/// reads the database.
const AgentTaskPayload = struct {
    kind: []const u8 = "agent",
    id: []const u8,
    agent_id: []const u8,
    runtime_id: []const u8,
    issue_id: ?[]const u8 = null,
    chat_session_id: ?[]const u8 = null,
    provider: []const u8,
    model: []const u8 = "",
    prompt: []const u8,
    custom_env: std.json.Value,
    custom_args: std.json.Value,
    mcp_config: std.json.Value,
};

/// Claim one agent task and render its payload.
///
/// The rendering happens inside this function on purpose: the payload
/// borrows the claimed task's strings and the agent's configuration, and
/// those are released when this function returns — handing the payload
/// to a caller and rendering it there would serialize freed memory.
fn renderAgentTaskClaim(ctx: *zfinal.Context, allocator: std.mem.Allocator, runtime_id: []const u8) !bool {
    const task = (try agent_task.claimAgentTask(allocator, runtime_id)) orelse return false;
    defer task.deinit(allocator);

    const agent_cfg = (try agent_task.selectAgentConfig(allocator, task.agent_id)) orelse {
        _ = agent_task.failAgentTask(task.id, "agent no longer exists", failure_reason_runtime);
        return false;
    };
    defer agent_cfg.deinit(allocator);

    const workspace = (try agent_task.selectWorkspaceInfo(allocator, agent_cfg.workspace_id)) orelse {
        _ = agent_task.failAgentTask(task.id, "workspace no longer exists", failure_reason_runtime);
        return false;
    };
    defer {
        allocator.free(workspace.name);
        allocator.free(workspace.issue_prefix);
    }

    const provider = (try agent_task.selectRuntimeProvider(allocator, task.runtime_id)) orelse "auto";
    defer allocator.free(provider);

    // The prompt is rendered here, on the side that can read the context.
    var prompt_text: []const u8 = "";
    if (task.chat_session_id) |session_id| {
        const history = try agent_task.selectChatHistory(allocator, session_id);
        defer {
            for (history) |turn| {
                allocator.free(turn.role);
                allocator.free(turn.content);
            }
            allocator.free(history);
        }
        prompt_text = try prompt_mod.buildChatPrompt(allocator, .{
            .agent_name = agent_cfg.name,
            .workspace_name = workspace.name,
            .instructions = agent_cfg.instructions,
            .history = history,
            .request = lastUserMessage(history),
        });
    } else if (task.issue_id) |issue_id| {
        const issue_ctx = (try agent_task.selectIssueContext(allocator, issue_id, workspace.issue_prefix)) orelse {
            _ = agent_task.failAgentTask(task.id, "issue no longer exists", failure_reason_runtime);
            return false;
        };
        defer issue_ctx.deinit(allocator);

        const comments = try agent_task.selectIssueComments(allocator, issue_id);
        defer {
            for (comments) |comment| {
                allocator.free(comment.author);
                allocator.free(comment.content);
            }
            allocator.free(comments);
        }
        prompt_text = try prompt_mod.buildIssuePrompt(allocator, .{
            .agent_name = agent_cfg.name,
            .workspace_name = workspace.name,
            .instructions = agent_cfg.instructions,
            .identifier = issue_ctx.identifier,
            .title = issue_ctx.title,
            .description = issue_ctx.description,
            .status = issue_ctx.status,
            .priority = issue_ctx.priority,
            .comments = comments,
        });
    } else {
        _ = agent_task.failAgentTask(task.id, "task has neither a chat session nor an issue", failure_reason_runtime);
        return false;
    }
    defer allocator.free(prompt_text);

    var env_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, allocator, agent_cfg.custom_env, .{}) catch null;
    defer if (env_parsed) |*p| p.deinit();
    var args_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, allocator, agent_cfg.custom_args, .{}) catch null;
    defer if (args_parsed) |*p| p.deinit();
    var mcp_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, allocator, agent_cfg.mcp_config, .{}) catch null;
    defer if (mcp_parsed) |*p| p.deinit();

    try ctx.renderJson(.{ .task = AgentTaskPayload{
        .id = task.id,
        .agent_id = task.agent_id,
        .runtime_id = task.runtime_id,
        .issue_id = task.issue_id,
        .chat_session_id = task.chat_session_id,
        .provider = provider,
        .model = agent_cfg.model,
        .prompt = prompt_text,
        .custom_env = if (env_parsed) |p| p.value else std.json.Value{ .null = {} },
        .custom_args = if (args_parsed) |p| p.value else std.json.Value{ .null = {} },
        .mcp_config = if (mcp_parsed) |p| p.value else std.json.Value{ .null = {} },
    } });
    return true;
}

/// The newest user turn of a chat transcript — the request that triggered
/// this run.
fn lastUserMessage(history: []const prompt_mod.ChatTurn) []const u8 {
    var i = history.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, history[i].role, "user")) return history[i].content;
    }
    return "";
}

pub fn listPendingTasksByRuntime(ctx: *zfinal.Context) !void {
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };
    const allocator = ctx.allocator;

    const tasks = try task_queue.pending(runtime_id, allocator);
    defer allocator.free(tasks);
    try ctx.renderJson(.{ .tasks = tasks });
}

pub fn startTask(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    try task_queue.start(task_id);
    // The persistent row is the one the frontend polls, so the transition
    // has to land there too — not only in the in-memory queue.
    _ = agent_task.setAgentTaskStatus(task_id, "running");
    try ctx.renderJson(.{ .success = true });
}

pub fn markTaskWaitingLocalDirectory(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    try task_queue.markWaitingLocalDirectory(task_id);
    _ = agent_task.setAgentTaskStatus(task_id, "waiting_local_directory");
    try ctx.renderJson(.{ .success = true });
}

pub fn reportTaskProgress(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(model.TaskProgressRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try task_queue.setProgress(task_id, req.progress orelse 0);
    try ctx.renderJson(.{ .success = true });
}

pub fn completeTask(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    const allocator = ctx.allocator;

    // The daemon reports the agent's answer in the body. An empty body is
    // legitimate — an older daemon sends none — so a body that does not
    // parse is treated as "no answer" rather than a rejected request: the
    // task really is done, and losing that would strand it as running.
    var req = model.TaskCompleteRequest{};
    var parsed: ?std.json.Parsed(model.TaskCompleteRequest) = null;
    const body = ctx.getBodyText() catch "";
    defer if (body.len > 0) allocator.free(body);
    if (body.len > 0) {
        parsed = std.json.parseFromSlice(model.TaskCompleteRequest, allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch null;
    }
    defer if (parsed) |*p| p.deinit();
    if (parsed) |p| req = p.value;

    try task_queue.complete(task_id);

    const output = req.output orelse "";
    const result_json = try buildTaskResultJson(allocator, req.result, output);
    defer allocator.free(result_json);

    _ = agent_task.completeAgentTask(task_id, result_json);

    // Materialize the answer where the user will see it: a chat reply for
    // a chat task, a comment on the issue for an issue task.
    if (output.len > 0) {
        try deliverTaskOutput(allocator, task_id, output);
    }

    try ctx.renderJson(.{ .success = true });
}

/// Store the daemon's result payload on the task row.
///
/// The daemon's own `result` bag wins when it sent one (usage, session
/// id, …); otherwise the visible output is what gets stored.
fn buildTaskResultJson(allocator: std.mem.Allocator, result: ?std.json.Value, output: []const u8) ![]const u8 {
    if (result) |value| {
        if (value == .object) {
            return zfinal.JsonKit.stringify(allocator, value);
        }
    }
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "output", .{ .string = output });
    return zfinal.JsonKit.stringify(allocator, std.json.Value{ .object = obj });
}

/// Deliver the agent's answer to the place the user is looking at.
fn deliverTaskOutput(allocator: std.mem.Allocator, task_id: []const u8, output: []const u8) !void {
    const target = (try agent_task.selectTaskTarget(allocator, task_id)) orelse return;
    defer target.deinit(allocator);

    if (target.chat_session_id) |session_id| {
        const message_id = try agent_task.insertAssistantMessage(allocator, session_id, task_id, output);
        if (message_id) |id| {
            defer allocator.free(id);
            try publishChatReply(allocator, target.workspace_id, session_id, id, output);
        }
        return;
    }
    if (target.issue_id) |issue_id| {
        const comment_id = try agent_task.insertAgentComment(allocator, target.workspace_id, issue_id, target.agent_id, output);
        if (comment_id) |id| allocator.free(id);
    }
}

/// Tell the connected clients that the agent answered.
///
/// Best-effort: the row is already written, so a realtime hiccup must not
/// turn a delivered answer into a failed task.
fn publishChatReply(allocator: std.mem.Allocator, workspace_id: []const u8, session_id: []const u8, message_id: []const u8, content: []const u8) !void {
    const payload = std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"chat_session_id\":\"{s}\",\"role\":\"assistant\",\"content\":{f}}}",
        .{ message_id, session_id, std.json.fmt(content, .{}) },
    ) catch return;
    defer allocator.free(payload);
    const realtime = @import("../realtime/service.zig");
    realtime.publishChatMessage(workspace_id, session_id, payload);
}

pub fn failTask(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    const allocator = ctx.allocator;
    const parsed = try ctx.parseJsonBody(model.TaskFailRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const err_msg = req.@"error" orelse "unknown error";
    try task_queue.fail(task_id, err_msg);
    _ = agent_task.failAgentTask(task_id, err_msg, agent_task.classifyFailure(err_msg));

    // A failed chat task has to leave a visible trace: without it the
    // user's message would simply never be answered, and the pending-task
    // poll would stop reporting the task as running — a silent failure.
    //
    // An issue task gets no comment: upstream treats a failed issue run
    // as something the user reads in the agent's activity view, not as
    // something the agent "said" on the issue.
    deliverTaskFailure(allocator, task_id, err_msg) catch |err| {
        log.warn("deliverTaskFailure: {s}", .{@errorName(err)});
    };

    try ctx.renderJson(.{ .success = true });
}

/// The failure class for a task the server itself could not hand out.
const failure_reason_runtime = agent_task.failure_reason_runtime;

/// Tell the user that a chat task failed.
///
/// The message is the reason the daemon reported — the user needs to
/// know *why* the agent went quiet, not just that it did.
fn deliverTaskFailure(allocator: std.mem.Allocator, task_id: []const u8, err_msg: []const u8) !void {
    const target = (try agent_task.selectTaskTarget(allocator, task_id)) orelse return;
    defer target.deinit(allocator);

    const session_id = target.chat_session_id orelse return;
    const message_id = try agent_task.insertAssistantMessageWithReason(
        allocator,
        session_id,
        task_id,
        err_msg,
        agent_task.classifyFailure(err_msg),
    );
    if (message_id) |id| {
        defer allocator.free(id);
        try publishChatReply(allocator, target.workspace_id, session_id, id, err_msg);
    }
}

pub fn reportTaskUsage(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    _ = task_id;
    const parsed = try ctx.parseJsonBody(model.TaskUsageRequest);
    defer parsed.deinit();
    _ = parsed.value;
    try ctx.renderJson(.{ .success = true });
}

pub fn reportTaskMessages(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(model.TaskMessagesRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const messages = req.messages orelse &[_][]const u8{};
    try task_queue.addMessages(task_id, messages);
    try ctx.renderJson(.{ .success = true });
}

pub fn listTaskMessages(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };
    const allocator = ctx.allocator;

    const messages = try task_queue.listMessages(task_id, allocator);
    defer allocator.free(messages);
    try ctx.renderJson(messages);
}

// ──────────────────────────────────────────────────────────────────────
// GC checks
// ──────────────────────────────────────────────────────────────────────

pub fn getIssueGCCheck(ctx: *zfinal.Context) !void {
    const issue_id = ctx.getPathParam("issueId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "issue_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const row = model.selectIssueGCCheck(issue_id) catch |err| switch (err) {
            error.IssueNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "issue not found" });
                return;
            },
            else => {
                log.err("getIssueGCCheck: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{
            .status = row.status,
            .updated_at = row.updated_at,
        });
    } else {
        try ctx.renderJson(.{ .status = "backlog", .updated_at = null });
    }
}

pub fn getChatSessionGCCheck(ctx: *zfinal.Context) !void {
    const session_id = ctx.getPathParam("sessionId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const row = model.selectChatSessionGCCheck(session_id) catch |err| switch (err) {
            error.ChatSessionNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "chat session not found" });
                return;
            },
            else => {
                log.err("getChatSessionGCCheck: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{
            .status = row.status,
            .updated_at = row.updated_at,
        });
    } else {
        try ctx.renderJson(.{ .status = "active", .updated_at = null });
    }
}

pub fn getAutopilotRunGCCheck(ctx: *zfinal.Context) !void {
    const run_id = ctx.getPathParam("runId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "run_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const row = model.selectAutopilotRunGCCheck(run_id) catch |err| switch (err) {
            error.AutopilotRunNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "autopilot run not found" });
                return;
            },
            else => {
                log.err("getAutopilotRunGCCheck: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{
            .status = row.status,
            .completed_at = row.completed_at,
        });
    } else {
        try ctx.renderJson(.{ .status = "pending", .completed_at = null });
    }
}

pub fn getTaskGCCheck(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        const status = model.selectTaskGCCheck(task_id) catch |err| switch (err) {
            error.TaskNotFound => {
                ctx.res_status = .not_found;
                try ctx.renderJson(.{ .@"error" = "task not found" });
                return;
            },
            else => {
                log.err("getTaskGCCheck: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            },
        };
        try ctx.renderJson(.{ .status = status });
    } else {
        try ctx.renderJson(.{ .status = "queued" });
    }
}

pub fn recoverOrphanedTasks(ctx: *zfinal.Context) !void {
    const runtime_id = ctx.getPathParam("runtimeId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "runtime_id is required" });
        return;
    };
    const cancelled = try task_queue.cancelByRuntime(runtime_id);
    try ctx.renderJson(.{ .recovered = cancelled });
}

pub fn pinTaskSession(ctx: *zfinal.Context) !void {
    const task_id = ctx.getPathParam("taskId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "task_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.PinTaskSessionRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.session_id == null and req.work_dir == null) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "session_id or work_dir required" });
        return;
    }

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);

        if (req.session_id) |sid| {
            if (req.work_dir) |wd| {
                model.pinSessionAndWorkDir(task_id, sid, wd) catch |err| {
                    log.err("pinTaskSession: {}", .{err});
                    ctx.res_status = .internal_server_error;
                    try ctx.renderJson(.{ .@"error" = "database_error" });
                    return;
                };
            } else {
                model.pinSession(task_id, sid) catch |err| {
                    log.err("pinTaskSession: {}", .{err});
                    ctx.res_status = .internal_server_error;
                    try ctx.renderJson(.{ .@"error" = "database_error" });
                    return;
                };
            }
        } else if (req.work_dir) |wd| {
            model.pinWorkDir(task_id, wd) catch |err| {
                log.err("pinTaskSession: {}", .{err});
                ctx.res_status = .internal_server_error;
                try ctx.renderJson(.{ .@"error" = "database_error" });
                return;
            };
        }
    }
    try response.okNoContent(ctx);
return;
}
