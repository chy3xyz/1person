//! Pin module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (DB row + API response), validation helpers, and
//! escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic + in-memory fallback for the no-DB smoke path.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
    return deps.acquire() catch null;
}

/// `pinned_item` row.
pub const PinEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    user_id: []const u8,
    item_type: []const u8,
    item_id: []const u8,
    position: f64,
    created_at: []const u8,
};

/// API response shape.
pub const PinResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    user_id: []const u8,
    item_type: []const u8,
    item_id: []const u8,
    position: f64,
    created_at: []const u8,
};

/// Convert a `PinEntry` to a `PinResponse`.
pub fn pinResponseFromEntry(entry: PinEntry) PinResponse {
    return PinResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .user_id = entry.user_id,
        .item_type = entry.item_type,
        .item_id = entry.item_id,
        .position = entry.position,
        .created_at = entry.created_at,
    };
}

/// Convert a row from a `SELECT id, workspace_id, user_id, item_type, item_id, position, created_at FROM pinned_item ...` query.
pub fn pinResponseFromRow(res: *zfinal.ResultSet, row: usize) PinResponse {
    const r = &res.rows.items[row];
    return PinResponse{
        .id = r.getText(0) orelse "",
        .workspace_id = r.getText(1) orelse "",
        .user_id = r.getText(2) orelse "",
        .item_type = r.getText(3) orelse "",
        .item_id = r.getText(4) orelse "",
        .position = std.fmt.parseFloat(f64, r.getText(5) orelse "0") catch 0,
        .created_at = r.getText(6) orelse "",
    };
}

/// `item_type` is restricted to `"issue"` or `"project"`.
pub fn validateItemType(t: []const u8) bool {
    return std.mem.eql(u8, t, "issue") or std.mem.eql(u8, t, "project");
}

/// Generate a stable pseudo-UUID for the in-memory store. Mirrors the
/// algorithm used by the legacy `src/handlers/pin.zig`.
pub fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ seed, ns });
    defer allocator.free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try allocator.alloc(u8, 32);
    const charset = "0123456789abcdef";
    for (hash[0..16], 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

/// Lightweight UUID-shape check; the DB still enforces the canonical
/// 36-character form on insert.
pub fn looksLikeUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    var i: usize = 0;
    while (i < 36) : (i += 1) {
        const c = s[i];
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isAlphanumeric(c)) {
            return false;
        }
    }
    return true;
}

/// `SELECT 1 FROM <table> WHERE id = $1 AND workspace_id = $2` — verifies
/// that the item a caller wants to pin actually exists.
pub fn dbItemExists(allocator: std.mem.Allocator, item_type: []const u8, item_id: []const u8, workspace_id: []const u8) !bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    const table = if (std.mem.eql(u8, item_type, "issue")) "issue" else "project";
    const query = try std.fmt.allocPrintSentinel(
        allocator,
        "SELECT 1 FROM {s} WHERE id = $1::uuid AND workspace_id = $2::uuid",
        .{table},
        0,
    );
    defer allocator.free(query);
    var rs = try db.queryParams(query, &[_]SqlParam{
        .{ .text = item_id },
        .{ .text = workspace_id },
    });
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `SELECT COALESCE(MAX(position), 0) FROM pinned_item WHERE workspace_id = $1 AND user_id = $2`.
pub fn dbMaxPosition(workspace_id: []const u8, user_id: []const u8) f64 {
    const db = borrowDb() orelse return 0;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT COALESCE(MAX(position), 0) FROM pinned_item WHERE workspace_id = $1::uuid AND user_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = user_id },
        },
    ) catch return 0;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return 0;
    return std.fmt.parseFloat(f64, rs.rows.items[0].getText(0) orelse "0") catch 0;
}

/// `SELECT ... FROM pinned_item WHERE workspace_id = $1 AND user_id = $2 ORDER BY position ASC`.
pub fn dbListPins(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8) ![]PinResponse {
    const db = borrowDb() orelse return &[_]PinResponse{};
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT id, workspace_id, user_id, item_type, item_id, position, created_at FROM pinned_item " ++
            "WHERE workspace_id = $1::uuid AND user_id = $2::uuid ORDER BY position ASC",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = user_id },
        },
    );
    defer rs.deinit();
    var list: std.ArrayList(PinResponse) = .empty;
    errdefer {
        for (list.items) |item| {
            db.allocator.free(item.id);
            db.allocator.free(item.workspace_id);
            db.allocator.free(item.user_id);
            db.allocator.free(item.item_type);
            db.allocator.free(item.item_id);
            db.allocator.free(item.created_at);
        }
        list.deinit(allocator);
    }
    for (0..rs.rows.items.len) |i| {
        const r = &rs.rows.items[i];
        const id = db.allocator.dupe(u8, r.getText(0) orelse "") catch return error.OutOfMemory;
        const ws_id = db.allocator.dupe(u8, r.getText(1) orelse "") catch { db.allocator.free(id); return error.OutOfMemory; };
        const uid = db.allocator.dupe(u8, r.getText(2) orelse "") catch {
            db.allocator.free(id);
            db.allocator.free(ws_id);
            return error.OutOfMemory;
        };
        const itype = db.allocator.dupe(u8, r.getText(3) orelse "") catch {
            db.allocator.free(id);
            db.allocator.free(ws_id);
            db.allocator.free(uid);
            return error.OutOfMemory;
        };
        const iid = db.allocator.dupe(u8, r.getText(4) orelse "") catch {
            db.allocator.free(id);
            db.allocator.free(ws_id);
            db.allocator.free(uid);
            db.allocator.free(itype);
            return error.OutOfMemory;
        };
        const position = std.fmt.parseFloat(f64, r.getText(5) orelse "0") catch 0;
        const cat = db.allocator.dupe(u8, r.getText(6) orelse "") catch {
            db.allocator.free(id);
            db.allocator.free(ws_id);
            db.allocator.free(uid);
            db.allocator.free(itype);
            db.allocator.free(iid);
            return error.OutOfMemory;
        };
        list.append(allocator, PinResponse{
            .id = id,
            .workspace_id = ws_id,
            .user_id = uid,
            .item_type = itype,
            .item_id = iid,
            .position = position,
            .created_at = cat,
        }) catch |err| {
            db.allocator.free(id);
            db.allocator.free(ws_id);
            db.allocator.free(uid);
            db.allocator.free(itype);
            db.allocator.free(iid);
            db.allocator.free(cat);
            return err;
        };
    }
    return try list.toOwnedSlice(allocator);
}

/// `INSERT INTO pinned_item ... RETURNING ...`.
pub fn dbCreatePin(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8, item_type: []const u8, item_id: []const u8, position: f64) !?PinResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{position});
    defer allocator.free(pos_str);
    var rs = try db.queryParams(
        "INSERT INTO pinned_item (workspace_id, user_id, item_type, item_id, position) " ++
            "VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5) RETURNING id, workspace_id, user_id, item_type, item_id, position, created_at",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = user_id },
            .{ .text = item_type },
            .{ .text = item_id },
            .{ .text = pos_str },
        },
    );
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const r = &rs.rows.items[0];
    const id = db.allocator.dupe(u8, r.getText(0) orelse "") catch return null;
    const ws_id = db.allocator.dupe(u8, r.getText(1) orelse "") catch { db.allocator.free(id); return null; };
    const uid = db.allocator.dupe(u8, r.getText(2) orelse "") catch {
        db.allocator.free(id);
        db.allocator.free(ws_id);
        return null;
    };
    const itype = db.allocator.dupe(u8, r.getText(3) orelse "") catch {
        db.allocator.free(id);
        db.allocator.free(ws_id);
        db.allocator.free(uid);
        return null;
    };
    const iid = db.allocator.dupe(u8, r.getText(4) orelse "") catch {
        db.allocator.free(id);
        db.allocator.free(ws_id);
        db.allocator.free(uid);
        db.allocator.free(itype);
        return null;
    };
    const pos_val = std.fmt.parseFloat(f64, r.getText(5) orelse "0") catch 0;
    const cat = db.allocator.dupe(u8, r.getText(6) orelse "") catch {
        db.allocator.free(id);
        db.allocator.free(ws_id);
        db.allocator.free(uid);
        db.allocator.free(itype);
        db.allocator.free(iid);
        return null;
    };
    return PinResponse{
        .id = id,
        .workspace_id = ws_id,
        .user_id = uid,
        .item_type = itype,
        .item_id = iid,
        .position = pos_val,
        .created_at = cat,
    };
}

/// `DELETE FROM pinned_item WHERE ...`. The legacy handler doesn't
/// check rowcount; the no-content response is returned unconditionally.
pub fn dbDeletePin(workspace_id: []const u8, user_id: []const u8, item_type: []const u8, item_id: []const u8) void {
    const db = borrowDb() orelse return;
    defer deps.releaseBack(db);
    db.execParams(
        "DELETE FROM pinned_item WHERE workspace_id = $1::uuid AND user_id = $2::uuid AND item_type = $3 AND item_id = $4::uuid",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = user_id },
            .{ .text = item_type },
            .{ .text = item_id },
        },
    ) catch {};
}

/// `UPDATE pinned_item SET position = $1 WHERE id = $2 AND workspace_id = $3 AND user_id = $4`.
pub fn dbReorderPin(allocator: std.mem.Allocator, position: f64, pin_id: []const u8, workspace_id: []const u8, user_id: []const u8) !void {
    const db = borrowDb() orelse return;
    defer deps.releaseBack(db);
    const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{position});
    defer allocator.free(pos_str);
    try db.execParams(
        "UPDATE pinned_item SET position = $1 WHERE id = $2::uuid AND workspace_id = $3::uuid AND user_id = $4::uuid",
        &[_]SqlParam{
            .{ .text = pos_str },
            .{ .text = pin_id },
            .{ .text = workspace_id },
            .{ .text = user_id },
        },
    );
}
