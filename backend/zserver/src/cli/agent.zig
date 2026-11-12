//! Agent configuration commands.
//!
//! An agent's local repository lives in its `runtime_config` — the bag of
//! free-form settings the agent row already carries. This command sets the
//! one key the platform reads (`local_path`), so an agent can be pointed at
//! the repository it works in without a database edit.

const std = @import("std");
const api = @import("api.zig");
const config_store = @import("config_store.zig");
const out = @import("out.zig");
const worktree = @import("worktree.zig");

pub const AgentOptions = struct {
    path: []const u8,
    workspace_id: []const u8,
    agent_id: []const u8,
    /// The repository the agent works in. Empty clears the binding.
    local_path: ?[]const u8,
};

/// Point an agent at a local repository (or clear the binding).
///
/// The path must be absolute: it names a directory on the machine that runs
/// the agent's daemon, and a relative one would be resolved against the
/// daemon's own working directory. The platform cannot check a path it does
/// not own — the daemon verifies the directory is a git repository before it
/// uses it.
pub fn setLocalPath(allocator: std.mem.Allocator, io: std.Io, opts: AgentOptions) !void {
    var cfg = try config_store.load(allocator, io, opts.path);
    defer cfg.deinit();
    if (cfg.server_url.len == 0 or cfg.token.len == 0) {
        out.printErr("not logged in — run \"1p login\" first (config: {s})\n", .{opts.path});
        return error.NotLoggedIn;
    }

    var client = try api.Client.init(allocator, cfg.server_url);
    defer client.deinit();

    // The agent's existing runtime_config is preserved: it is the agent's
    // own settings bag, and the platform only owns one key in it.
    const agent_path = try std.fmt.allocPrint(allocator, "/api/agents/{s}", .{opts.agent_id});
    defer allocator.free(agent_path);

    var current = try client.getJson(allocator, agent_path, cfg.token, opts.workspace_id);
    defer current.deinit();
    if (!current.ok()) {
        out.printErr("agent lookup failed (HTTP {d}): {s}\n", .{ current.status, current.getString("error") orelse "unknown" });
        return error.AgentLookupFailed;
    }

    var config: std.json.ObjectMap = .empty;
    defer config.deinit(allocator);

    if (current.parsed.value == .object) {
        if (current.parsed.value.object.get("runtime_config")) |existing| {
            if (existing == .object) {
                var it = existing.object.iterator();
                while (it.next()) |entry| {
                    try config.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }
    }

    if (opts.local_path) |p| {
        const trimmed = std.mem.trim(u8, p, " \t\r\n");
        if (trimmed.len == 0) {
            out.printErr("--local_path must not be empty (pass an empty string to clear the binding)\n", .{});
            return error.InvalidPath;
        }
        // A relative path is resolved against whatever directory the daemon
        // happens to run in, so the agent would work in a repository the user
        // never named. The binding is rejected here instead of quietly
        // pointing somewhere else later.
        worktree.validateLocalPath(trimmed) catch {
            out.printErr("--local_path must be an absolute path (it names a directory on the machine that runs the daemon)\n", .{});
            return error.InvalidPath;
        };
        try config.put(allocator, "local_path", .{ .string = trimmed });
    } else {
        _ = config.orderedRemove("local_path");
    }

    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .runtime_config = std.json.Value{ .object = config },
    }, .{});
    defer allocator.free(body);

    var updated = try client.putJson(allocator, agent_path, body, cfg.token, opts.workspace_id);
    defer updated.deinit();
    if (!updated.ok()) {
        out.printErr("agent update failed (HTTP {d}): {s}\n", .{ updated.status, updated.getString("error") orelse "unknown" });
        return error.AgentUpdateFailed;
    }

    if (opts.local_path) |p| {
        out.printOut("agent {s} now works in {s}\n", .{ opts.agent_id, p });
    } else {
        out.printOut("agent {s} no longer has a working directory\n", .{opts.agent_id});
    }
}
