//! 1p — Zig CLI client for the 1person platform.
//!
//! M1: config / login / pair / version. M2: daemon loop
//! (register/heartbeat/WS/claim). M3: task execution.
//!
//! Commands are flat: zcli's nested-subcommand parsing is broken
//! (the parent field would need to be command.Result(DaemonCmd), which
//! meta() then rejects), so `daemon pair` is exposed as `pair` and
//! the daemon loop is `daemon`.

const std = @import("std");
const zcli = @import("zcli");
const zfinal = @import("zfinal");
const build_options = @import("build_options");
const config_store = @import("config_store.zig");
const login_mod = @import("login.zig");
const pair_mod = @import("pair.zig");
const daemon_mod = @import("daemon.zig");
const query_mod = @import("query.zig");
const update_mod = @import("update.zig");
const out = @import("out.zig");

const version = build_options.version;
const commit = build_options.commit;

// ── command tree ────────────────────────────────────────────────────

const Root = struct {
    config: ConfigCmd,
    login: LoginCmd,
    pair: PairCmd,
    daemon: DaemonCmd,
    workspaces: ListCmd,
    agents: ListCmd,
    issues: ListCmd,
    update: UpdateCmd,
    version: VersionCmd,

    pub const zcli_options = .{
        .config = .{ .help = "Show the resolved config file (path + summary)" },
        .login = .{ .help = "Log in with an email verification code and store the session token" },
        .pair = .{ .help = "Mint a workspace-bound daemon token and store it" },
        .daemon = .{ .help = "Run the local daemon worker loop (register/heartbeat/WS/claim)" },
        .workspaces = .{ .help = "List workspaces (read-only)" },
        .agents = .{ .help = "List agents in a workspace (read-only)" },
        .issues = .{ .help = "List issues in a workspace (read-only)" },
        .update = .{ .help = "Self-update: download and replace the 1p binary" },
        .version = .{ .help = "Print version information" },
    };
};

const UpdateCmd = struct {
    from: ?[]const u8 = null,
    target: ?[]const u8 = null,

    pub const zcli_options = .{
        .from = .{ .help = "Release base URL (default: GitHub latest download)" },
        .target = .{ .help = "Target binary path (default: current executable)" },
    };
};

const ListCmd = struct {
    workspace_id: ?[]const u8 = null,
    path: ?[]const u8 = null,

    pub const zcli_options = .{
        .workspace_id = .{ .help = "Workspace UUID (required for agents/issues)" },
        .path = .{ .help = "Config file path" },
    };
};

const ConfigCmd = struct {
    path: ?[]const u8 = null,

    pub const zcli_options = .{
        .path = .{ .help = "Config file path (default: ~/.config/1person/config.json)" },
    };
};

const LoginCmd = struct {
    server_url: ?[]const u8 = null,
    email: ?[]const u8 = null,
    code: ?[]const u8 = null,
    path: ?[]const u8 = null,

    pub const zcli_options = .{
        .server_url = .{ .help = "Server base URL (default: http://localhost:8080)" },
        .email = .{ .help = "Email to log in with (prompts if omitted)" },
        .code = .{ .help = "Verification code (prompts if omitted)" },
        .path = .{ .help = "Config file path" },
    };
};

const PairCmd = struct {
    // Optional at the type level (zcli's required-positional path blows the
    // comptime branch quota on this zig build); validated at runtime.
    workspace_id: ?[]const u8 = null,
    path: ?[]const u8 = null,

    pub const zcli_options = .{
        .workspace_id = .{ .help = "Workspace UUID to bind the daemon token to" },
        .path = .{ .help = "Config file path" },
    };
};

const DaemonCmd = struct {
    runtime_id: ?[]const u8 = null,
    workspace_id: ?[]const u8 = null,
    token: ?[]const u8 = null,
    path: ?[]const u8 = null,
    heartbeat_ms: ?u64 = null,
    claim_ms: ?u64 = null,

    pub const zcli_options = .{
        .runtime_id = .{ .help = "Runtime id this daemon services (required)" },
        .workspace_id = .{ .help = "Workspace whose daemon token to use" },
        .token = .{ .help = "Override daemon token (1d_...)" },
        .path = .{ .help = "Config file path" },
        .heartbeat_ms = .{ .help = "Heartbeat interval in ms (default 30000)" },
        .claim_ms = .{ .help = "Claim poll interval in ms (default 15000)" },
    };
};

const VersionCmd = struct {};

// ── dispatch ────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    // zcli's comptime meta() (FieldEnum generation via std.simd.iota) blows
    // the default 1000-branch quota on this Zig 0.17-dev build for command
    // trees with 4 subcommands. Raise it for the comptime scope of main.
    @setEvalBranchQuota(20000);

    zfinal.io_instance.init(init);
    const allocator = init.gpa;
    const io = zfinal.io_instance.io;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |arg| try args.append(allocator, arg);

    const parsed = zcli.parse(Root, args.items, allocator) catch |err| {
        out.printErr("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer zcli.free(Root, &parsed, allocator);

    switch (parsed.active) {
        .config => {
            const cmd = parsed.value.config;
            const path = try config_store.resolvePath(allocator, init.environ_map, cmd.path);
            defer allocator.free(path);
            var cfg = try config_store.load(allocator, io, path);
            defer cfg.deinit();
            out.printOut("config: {s}\n", .{path});
            out.printOut("server_url: {s}\n", .{if (cfg.server_url.len > 0) cfg.server_url else "(not set)"});
            out.printOut("token: {s}\n", .{if (cfg.token.len > 0) "(set)" else "(not set)"});
            out.printOut("daemon_tokens: {d}\n", .{cfg.daemon_tokens.count()});
        },
        .login => {
            const cmd = parsed.value.login;
            const path = try config_store.resolvePath(allocator, init.environ_map, cmd.path);
            defer allocator.free(path);
            try login_mod.run(allocator, io, .{
                .server_url = cmd.server_url,
                .email = cmd.email,
                .code = cmd.code,
                .path = path,
            });
        },
        .pair => {
            const cmd = parsed.value.pair;
            const workspace_id = cmd.workspace_id orelse {
                out.printErr("error: --workspace_id is required\n", .{});
                std.process.exit(1);
            };
            const path = try config_store.resolvePath(allocator, init.environ_map, cmd.path);
            defer allocator.free(path);
            try pair_mod.run(allocator, io, .{ .workspace_id = workspace_id, .path = path });
        },
        .daemon => {
            const cmd = parsed.value.daemon;
            const runtime_id = cmd.runtime_id orelse {
                out.printErr("error: --runtime_id is required\n", .{});
                std.process.exit(1);
            };
            const path = try config_store.resolvePath(allocator, init.environ_map, cmd.path);
            defer allocator.free(path);
            try daemon_mod.run(allocator, io, .{
                .runtime_id = runtime_id,
                .workspace_id = cmd.workspace_id,
                .token = cmd.token,
                .path = path,
                .heartbeat_interval_ms = cmd.heartbeat_ms orelse 30000,
                .claim_interval_ms = cmd.claim_ms orelse 15000,
            });
        },
        .workspaces => {
            const cmd = parsed.value.workspaces;
            const path = try config_store.resolvePath(allocator, init.environ_map, cmd.path);
            defer allocator.free(path);
            try query_mod.listWorkspaces(allocator, io, .{ .path = path });
        },
        .agents => {
            const cmd = parsed.value.agents;
            const path = try config_store.resolvePath(allocator, init.environ_map, cmd.path);
            defer allocator.free(path);
            try query_mod.listAgents(allocator, io, .{ .path = path, .workspace_id = cmd.workspace_id });
        },
        .issues => {
            const cmd = parsed.value.issues;
            const path = try config_store.resolvePath(allocator, init.environ_map, cmd.path);
            defer allocator.free(path);
            try query_mod.listIssues(allocator, io, .{ .path = path, .workspace_id = cmd.workspace_id });
        },
        .update => {
            const cmd = parsed.value.update;
            try update_mod.run(allocator, io, .{ .from = cmd.from, .target = cmd.target });
        },
        .version => {
            out.printOut("1p {s} (commit: {s})\n", .{ version, commit });
        },
    }
}
