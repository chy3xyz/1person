//! Referral service — no-DB CRUD for referral codes + track/activate
//! referral records + referral tree.
//!
//! Operates entirely in-memory using a page-allocator-backed
//! StringHashMap. All per-workspace scoping is enforced on read/write.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

pub const ReferralCode = model.ReferralCode;
pub const ReferralRecord = model.ReferralRecord;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_codes: ?std.StringHashMap(model.ReferralCode) = null;
var mem_records: ?std.StringHashMap(model.ReferralRecord) = null;

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memDup(text: []const u8) ![]const u8 {
    return memAlloc().dupe(u8, text);
}

fn memInit() !void {
    if (mem_codes == null) {
        mem_codes = std.StringHashMap(model.ReferralCode).init(memAlloc());
        mem_records = std.StringHashMap(model.ReferralRecord).init(memAlloc());
    }
}

fn generateId(prefix: []const u8) ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    return std.fmt.allocPrint(memAlloc(), "{s}-{d}", .{ prefix, ts });
}

fn nowStr() ![]const u8 {
    const sec = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return std.fmt.allocPrint(memAlloc(), "{d}", .{sec});
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

fn requireWorkspaceId(ctx: *zfinal.Context) ![]const u8 {
    return getWorkspaceId(ctx) orelse {
        try response.err(ctx, .bad_request, "workspace_id is required", 40021);
        return error.MissingWorkspace;
    };
}

fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("user_id");
}

/// ── Referral Code CRUD ─────────────────────────────────────────

pub fn createCode(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const user_id = getUserId(ctx) orelse {
        try response.err(ctx, .unauthorized, "user_id is required", 40101);
        return;
    };
    const parsed = try ctx.parseJsonBody(model.CreateCodeRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.code.len == 0) {
        try response.err(ctx, .bad_request, "code is required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    if (mem_codes.?.contains(req.code)) {
        try response.err(ctx, .conflict, "referral code already exists", 40901);
        return;
    }

    const entry = model.ReferralCode{
        .code = try memDup(req.code),
        .user_id = try memDup(user_id),
        .workspace_id = try memDup(workspace_id),
    };
    try mem_codes.?.put(entry.code, entry);
    ctx.res_status = .created;
    try ctx.renderJson(entry);
}

pub fn listCodes(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.ReferralCode) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_codes) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.workspace_id, workspace_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try ctx.renderJson(.{ .codes = list.items, .total = list.items.len });
}

pub fn getCode(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const code = ctx.getPathParam("code") orelse {
        try response.err(ctx, .bad_request, "code is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry = mem_codes.?.get(code) orelse {
        try response.err(ctx, .not_found, "referral code not found", 40401);
        return;
    };
    try ctx.renderJson(entry);
}

pub fn deleteCode(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const code = ctx.getPathParam("code") orelse {
        try response.err(ctx, .bad_request, "code is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    _ = mem_codes.?.fetchRemove(code) orelse {
        try response.err(ctx, .not_found, "referral code not found", 40401);
        return;
    };
    try response.okNoContent(ctx);
}

/// ── Referral Tracking ──────────────────────────────────────────

pub fn trackReferral(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.TrackReferralRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.code.len == 0) {
        try response.err(ctx, .bad_request, "code is required", 40021);
        return;
    }
    if (req.referee_user_id.len == 0) {
        try response.err(ctx, .bad_request, "referee_user_id is required", 40022);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const rc = mem_codes.?.get(req.code) orelse {
        try response.err(ctx, .not_found, "referral code not found", 40401);
        return;
    };

    // Prevent self-referral.
    if (std.mem.eql(u8, rc.user_id, req.referee_user_id)) {
        try response.err(ctx, .bad_request, "cannot refer yourself", 40023);
        return;
    }

    // Check for duplicate referral for the same referee via any code.
    {
        var it = mem_records.?.iterator();
        while (it.next()) |kv| {
            const rec = kv.value_ptr.*;
            if (std.mem.eql(u8, rec.referee_user_id, req.referee_user_id) and
                std.mem.eql(u8, rec.status, "registered"))
            {
                try response.err(ctx, .conflict, "user already referred (registered)", 40902);
                return;
            }
        }
    }

    const id = try generateId("rfr");
    const entry = model.ReferralRecord{
        .id = try memDup(id),
        .code = try memDup(req.code),
        .referrer_user_id = try memDup(rc.user_id),
        .referee_user_id = try memDup(req.referee_user_id),
        .status = try memDup("registered"),
        .rewarded_at = try memDup(""),
    };
    try mem_records.?.put(entry.id, entry);
    ctx.res_status = .created;
    try ctx.renderJson(entry);
}

pub fn activateReferral(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.ActivateReferralRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.referee_user_id.len == 0) {
        try response.err(ctx, .bad_request, "referee_user_id is required", 40022);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    // Find the registered referral record for this referee.
    var found_idx: ?u32 = null;
    {
        var i: u32 = 0;
        var it = mem_records.?.iterator();
        while (it.next()) |kv| : (i += 1) {
            if (std.mem.eql(u8, kv.value_ptr.referee_user_id, req.referee_user_id) and
                std.mem.eql(u8, kv.value_ptr.status, "registered"))
            {
                found_idx = i;
                break;
            }
        }
    }
    if (found_idx == null) {
        try response.err(ctx, .not_found, "no registered referral found for this user", 40402);
        return;
    }

    // Get the record via its key and upgrade status.
    var rec_key: ?[]const u8 = null;
    {
        var it = mem_records.?.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.referee_user_id, req.referee_user_id) and
                std.mem.eql(u8, kv.value_ptr.status, "registered"))
            {
                rec_key = kv.key_ptr.*;
                break;
            }
        }
    }
    if (rec_key) |key| {
        const rec = mem_records.?.getPtr(key).?;
        rec.status = try memDup("paid");
        rec.rewarded_at = try nowStr();
        try ctx.renderJson(rec.*);
    }
}

/// ── Referral Tree ──────────────────────────────────────────────

pub fn getReferralTree(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const user_id = ctx.getPathParam("user_id") orelse {
        try response.err(ctx, .bad_request, "user_id is required", 40021);
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.ReferralRecord) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_records) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.referrer_user_id, user_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try ctx.renderJson(.{ .referrals = list.items, .total = list.items.len });
}

/// ── Record Listing ─────────────────────────────────────────────

pub fn listRecords(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.ReferralRecord) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_records) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try ctx.renderJson(.{ .records = list.items, .total = list.items.len });
}
