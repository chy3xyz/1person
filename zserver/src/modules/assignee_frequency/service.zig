//! Assignee frequency module — business logic.
//!
//! Exposes the single HTTP-facing operation: `getAssigneeFrequency`.
//! With a DB pool it aggregates how often the current user assigns to
//! each target, combining `assignee_changed` activity rows and
//! assignees on issues the user created (mirrors the Go handler). The
//! no-DB fallback returns an empty array.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const model = @import("model.zig");

pub fn init(_: *const anyopaque) void {}

pub fn getAssigneeFrequency(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const user_id = ctx.attributes.get("user_id") orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    const workspace_id = ctx.attributes.get("workspace_id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (deps.hasPool()) {
        const db = deps.acquire() catch {
            try ctx.renderJson(&[_]model.FrequencyEntry{});
            return;
        };
        defer deps.releaseBack(db);

        // Aggregate both sources in memory keyed by "type:id", then
        // render sorted by frequency (descending) — same contract as
        // the Go handler.
        var freq = std.StringHashMap(i64).init(allocator);
        defer freq.deinit();

        // Source 1: assignee_changed activities by this user.
        var rs = try db.queryParams(
            "SELECT details->>'to_type', details->>'to_id', COUNT(*)::bigint " ++
                "FROM activity_log WHERE workspace_id = $1::uuid AND actor_id = $2::uuid " ++
                "AND actor_type = 'member' AND action = 'assignee_changed' " ++
                "AND details->>'to_type' IS NOT NULL AND details->>'to_id' IS NOT NULL " ++
                "GROUP BY 1, 2",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
        );
        defer rs.deinit();
        for (0..rs.rows.items.len) |i| {
            const row = &rs.rows.items[i];
            const a_type = row.getText(0) orelse continue;
            const a_id = row.getText(1) orelse continue;
            const n = std.fmt.parseInt(i64, row.getText(2) orelse "0", 10) catch 0;
            const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ a_type, a_id });
            defer allocator.free(key);
            const gop = try freq.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += n;
        }

        // Source 2: assignees on issues created by this user.
        var rs2 = try db.queryParams(
            "SELECT assignee_type, assignee_id::text, COUNT(*)::bigint " ++
                "FROM issue WHERE workspace_id = $1::uuid AND creator_id = $2::uuid " ++
                "AND creator_type = 'member' AND assignee_type IS NOT NULL " ++
                "AND assignee_id IS NOT NULL GROUP BY 1, 2",
            &[_]SqlParam{ .{ .text = workspace_id }, .{ .text = user_id } },
        );
        defer rs2.deinit();
        for (0..rs2.rows.items.len) |i| {
            const row = &rs2.rows.items[i];
            const a_type = row.getText(0) orelse continue;
            const a_id = row.getText(1) orelse continue;
            const n = std.fmt.parseInt(i64, row.getText(2) orelse "0", 10) catch 0;
            const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ a_type, a_id });
            defer allocator.free(key);
            const gop = try freq.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += n;
        }

        // Emit sorted-by-frequency rows.
        var entries: std.ArrayList(model.FrequencyEntry) = .empty;
        defer entries.deinit(allocator);
        var it = freq.iterator();
        while (it.next()) |kv| {
            const sep = std.mem.indexOfScalar(u8, kv.key_ptr.*, ':') orelse continue;
            try entries.append(allocator, .{
                .assignee_type = try allocator.dupe(u8, kv.key_ptr.*[0..sep]),
                .assignee_id = try allocator.dupe(u8, kv.key_ptr.*[sep + 1 ..]),
                .frequency = kv.value_ptr.*,
            });
        }
        std.mem.sort(model.FrequencyEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: model.FrequencyEntry, b: model.FrequencyEntry) bool {
                return a.frequency > b.frequency;
            }
        }.lessThan);
        try ctx.renderJson(entries.items);
        return;
    }

    try ctx.renderJson(&[_]model.FrequencyEntry{});
}
