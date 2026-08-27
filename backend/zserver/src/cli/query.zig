//! Read-only query commands (M4): workspaces / agents / issues listing.

const std = @import("std");
const api = @import("api.zig");
const config_store = @import("config_store.zig");
const out = @import("out.zig");

pub const QueryOptions = struct {
    path: []const u8,
    workspace_id: ?[]const u8 = null,
};

fn loadClient(allocator: std.mem.Allocator, io: std.Io, opts: QueryOptions) !struct { client: api.Client, token: []const u8, cfg: config_store.ConfigFile } {
    var cfg = try config_store.load(allocator, io, opts.path);
    errdefer cfg.deinit();
    if (cfg.server_url.len == 0 or cfg.token.len == 0) {
        out.printErr("not logged in — run \"1p login\" first (config: {s})\n", .{opts.path});
        return error.NotLoggedIn;
    }
    const client = try api.Client.init(allocator, cfg.server_url);
    return .{ .client = client, .token = cfg.token, .cfg = cfg };
}

/// Print one line per item from a JSON array root (or {issues: [...]}).
fn printItems(allocator: std.mem.Allocator, resp: *const api.Response, id_key: []const u8, name_key: []const u8) void {
    var arr: ?std.json.Array = null;
    if (resp.parsed.value == .array) {
        arr = resp.parsed.value.array;
    } else if (resp.parsed.value == .object) {
        if (resp.parsed.value.object.get("issues")) |v| {
            if (v == .array) arr = v.array;
        }
    }
    const list = arr orelse {
        out.printOut("(no items)\n", .{});
        return;
    };
    for (list.items) |item| {
        if (item != .object) continue;
        const id = strField(item, id_key) orelse "?";
        const name = strField(item, name_key) orelse "";
        out.printOut("{s}\t{s}\n", .{ id, name });
    }
    _ = allocator;
}

fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f != .string) return null;
    return f.string;
}

pub fn listWorkspaces(allocator: std.mem.Allocator, io: std.Io, opts: QueryOptions) !void {
    var ctx = try loadClient(allocator, io, opts);
    defer ctx.client.deinit();
    defer ctx.cfg.deinit();

    var resp = try ctx.client.getJson(allocator, "/api/workspaces", ctx.token, null);
    defer resp.deinit();
    if (!resp.ok()) {
        out.printErr("workspaces failed (HTTP {d}): {s}\n", .{ resp.status, resp.getString("error") orelse "unknown" });
        return;
    }
    printItems(allocator, &resp, "id", "name");
}

pub fn listAgents(allocator: std.mem.Allocator, io: std.Io, opts: QueryOptions) !void {
    const ws_id = opts.workspace_id orelse {
        out.printErr("--workspace_id is required\n", .{});
        return error.WorkspaceRequired;
    };
    var ctx = try loadClient(allocator, io, opts);
    defer ctx.client.deinit();
    defer ctx.cfg.deinit();

    var resp = try ctx.client.getJson(allocator, "/api/agents", ctx.token, ws_id);
    defer resp.deinit();
    if (!resp.ok()) {
        out.printErr("agents failed (HTTP {d}): {s}\n", .{ resp.status, resp.getString("error") orelse "unknown" });
        return;
    }
    printItems(allocator, &resp, "id", "name");
}

pub fn listIssues(allocator: std.mem.Allocator, io: std.Io, opts: QueryOptions) !void {
    const ws_id = opts.workspace_id orelse {
        out.printErr("--workspace_id is required\n", .{});
        return error.WorkspaceRequired;
    };
    var ctx = try loadClient(allocator, io, opts);
    defer ctx.client.deinit();
    defer ctx.cfg.deinit();

    var resp = try ctx.client.getJson(allocator, "/api/issues", ctx.token, ws_id);
    defer resp.deinit();
    if (!resp.ok()) {
        out.printErr("issues failed (HTTP {d}): {s}\n", .{ resp.status, resp.getString("error") orelse "unknown" });
        return;
    }
    printItems(allocator, &resp, "id", "title");
}
