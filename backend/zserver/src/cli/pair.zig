//! 1p daemon pair: mint a workspace-bound daemon token (POST /api/daemon/tokens)
//! using the stored session token, and persist it for the workspace.

const std = @import("std");
const api = @import("api.zig");
const config_store = @import("config_store.zig");
const out = @import("out.zig");

pub const PairOptions = struct {
    workspace_id: []const u8,
    path: []const u8,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, opts: PairOptions) !void {
    var cfg = try config_store.load(allocator, io, opts.path);
    defer cfg.deinit();

    if (cfg.server_url.len == 0 or cfg.token.len == 0) {
        out.printErr("not logged in — run \"1p login\" first (config: {s})\n", .{opts.path});
        return error.NotLoggedIn;
    }

    var client = try api.Client.init(allocator, cfg.server_url);
    defer client.deinit();

    const body = try std.fmt.allocPrint(allocator, "{{\"workspace_id\":\"{s}\"}}", .{opts.workspace_id});
    defer allocator.free(body);

    var resp = try client.postJson(allocator, "/api/daemon/tokens", body, cfg.token);
    defer resp.deinit();
    if (!resp.ok()) {
        out.printErr("pair failed (HTTP {d}): {s}\n", .{ resp.status, resp.getString("error") orelse "unknown" });
        return error.PairFailed;
    }
    const token = resp.getString("token") orelse {
        out.printErr("pair response missing token\n", .{});
        return error.PairFailed;
    };
    const daemon_id = resp.getString("daemon_id") orelse "";

    const alloc = cfg.daemon_tokens.allocator;
    if (cfg.daemon_tokens.get(opts.workspace_id)) |old| alloc.free(old);
    try cfg.daemon_tokens.put(try alloc.dupe(u8, opts.workspace_id), try alloc.dupe(u8, token));

    try config_store.save(allocator, io, opts.path, &cfg);
    out.printOut("paired: workspace {s} -> daemon {s} (token stored in {s})\n", .{ opts.workspace_id, daemon_id, opts.path });
}
