//! Lark module — business logic.
//!
//! Owns the in-memory `mem_bindings` map. `redeemLarkBinding` flips
//! the matching entry's `redeemed` flag (DB or memory). The legacy
//! handler had a `g_cfg` global but never read it; that was dropped
//! during migration (no `init(cfg)` to preserve).
//!
//! `handler.zig` is a thin delegate.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("../../deps.zig");
const SqlParam = zfinal.SqlParam;
const model = @import("model.zig");
const common_mem = @import("../../common/mem.zig");

const log = std.log.scoped(.lark_service);

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_bindings: ?std.StringHashMap(model.BindingEntry) = null;

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn memInit() !void {
    if (mem_bindings == null) {
        mem_bindings = std.StringHashMap(model.BindingEntry).init(memAlloc());
    }
}

pub fn redeemLarkBinding(ctx: *zfinal.Context) !void {
    const RedeemRequest = struct {
        code: []const u8,
    };

    const parsed = try ctx.parseJsonBody(RedeemRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const code = std.mem.trim(u8, req.code, &std.ascii.whitespace);
    if (code.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "code is required" });
        return;
    }

    if (deps.acquire() catch null) |db| {
        defer deps.releaseBack(db);
        var rs = db.queryParams(
            "UPDATE lark_binding SET redeemed = true, redeemed_at = now() " ++
                "WHERE code = $1 AND redeemed = false RETURNING workspace_id, tenant_key, tenant_name",
            &[_]SqlParam{.{ .text = code }},
        ) catch {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invalid or already redeemed code" });
            return;
        };
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invalid or already redeemed code" });
            return;
        }
        try ctx.renderJson(.{
            .success = true,
            .workspace_id = rs.rows.items[0].getText(0) orelse "",
            .tenant_key = rs.rows.items[0].getText(1) orelse "",
            .tenant_name = rs.rows.items[0].getText(2) orelse "",
        });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_bindings.?.getPtr(code) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "invalid or already redeemed code" });
            return;
        };
        if (entry_ptr.redeemed) {
            ctx.res_status = .conflict;
            try ctx.renderJson(.{ .@"error" = "code already redeemed" });
            return;
        }
        entry_ptr.redeemed = true;
        try ctx.renderJson(.{
            .success = true,
            .workspace_id = entry_ptr.workspace_id,
            .tenant_key = entry_ptr.tenant_key,
            .tenant_name = entry_ptr.tenant_name,
        });
    }
}
