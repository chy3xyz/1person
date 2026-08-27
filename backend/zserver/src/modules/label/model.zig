//! Label module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (DB row + API response), validation helpers, and
//! escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic + in-memory fallback for the no-DB smoke path.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const common_mem = @import("../../common/mem.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
    }

/// `issue_label` row.
pub const LabelEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    color: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// API response shape.
pub const LabelResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    color: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Convert a `LabelEntry` (in-memory or DB row) to a `LabelResponse`.
pub fn labelResponseFromEntry(entry: LabelEntry) LabelResponse {
    return LabelResponse{
        .id = entry.id,
        .workspace_id = entry.workspace_id,
        .name = entry.name,
        .color = entry.color,
        .created_at = entry.created_at,
        .updated_at = entry.updated_at,
    };
}

/// Convert a row from a `SELECT id, workspace_id, name, color, created_at, updated_at FROM issue_label` query.
/// The returned `LabelResponse` borrows from the result set — ONLY use this while the result set is alive.
pub fn labelResponseFromRow(res: *zfinal.ResultSet, row: usize) LabelResponse {
    const r = &res.rows.items[row];
    return LabelResponse{
        .id = r.getText(0) orelse "",
        .workspace_id = r.getText(1) orelse "",
        .name = r.getText(2) orelse "",
        .color = r.getText(3) orelse "",
        .created_at = r.getText(4) orelse "",
        .updated_at = r.getText(5) orelse "",
    };
}

/// Dupe every text field from a single result-set row into `allocator`,
/// returning a `LabelResponse` whose lifetime is independent of the
/// result set. Callers that `defer rs.deinit()` before returning MUST
/// use this instead of the raw `labelResponseFromRow`.
pub fn labelResponseFromRowDuped(allocator: std.mem.Allocator, res: *zfinal.ResultSet, row: usize) ?LabelResponse {
    const r = &res.rows.items[row];
    const dup_id = allocator.dupe(u8, r.getText(0) orelse "") catch return null;
    errdefer allocator.free(dup_id);
    const dup_ws = allocator.dupe(u8, r.getText(1) orelse "") catch return null;
    errdefer allocator.free(dup_ws);
    const dup_name = allocator.dupe(u8, r.getText(2) orelse "") catch return null;
    errdefer allocator.free(dup_name);
    const dup_color = allocator.dupe(u8, r.getText(3) orelse "") catch return null;
    errdefer allocator.free(dup_color);
    const dup_ca = allocator.dupe(u8, r.getText(4) orelse "") catch return null;
    errdefer allocator.free(dup_ca);
    const dup_ua = allocator.dupe(u8, r.getText(5) orelse "") catch return null;
    return LabelResponse{
        .id = dup_id,
        .workspace_id = dup_ws,
        .name = dup_name,
        .color = dup_color,
        .created_at = dup_ca,
        .updated_at = dup_ua,
    };
}

/// Free all heap-allocated strings inside a `LabelResponse` returned by
/// `labelResponseFromRowDuped`. Safe to call on zeroed/default structs.
pub fn freeLabelResponse(allocator: std.mem.Allocator, resp: LabelResponse) void {
    allocator.free(@constCast(resp.id));
    allocator.free(@constCast(resp.workspace_id));
    allocator.free(@constCast(resp.name));
    allocator.free(@constCast(resp.color));
    allocator.free(@constCast(resp.created_at));
    allocator.free(@constCast(resp.updated_at));
}

/// Validate a label name. Returns the trimmed name on success or
/// `null` when the name is empty / too long.
pub fn validateName(name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (trimmed.len > 32) return null;
    return trimmed;
}

fn isValidHexChar(c: u8) bool {
    return std.ascii.isHex(c);
}

pub fn isValidHexColor(c: []const u8) bool {
    if (c.len != 6 and c.len != 7) return false;
    var start: usize = 0;
    if (c.len == 7) {
        if (c[0] != '#') return false;
        start = 1;
    }
    for (c[start..]) |ch| {
        if (!isValidHexChar(ch)) return false;
    }
    return true;
}

/// Normalise to a lower-case `#rrggbb` form. Caller-allocated result.
/// Returns `error.InvalidColor` when the input isn't a valid hex.
pub fn normalizeColor(allocator: std.mem.Allocator, c: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, c, &std.ascii.whitespace);
    if (!isValidHexColor(trimmed)) return error.InvalidColor;
    if (trimmed.len == 6) {
        return try std.fmt.allocPrint(allocator, "#{s}", .{trimmed});
    }
    var buf: [7]u8 = undefined;
    return try allocator.dupe(u8, std.ascii.lowerString(&buf, trimmed));
}

/// Generate a stable pseudo-UUID for the in-memory store. Mirrors the
/// algorithm used by the legacy `src/handlers/label.zig`.
pub fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
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

/// Returns `true` when a label with the given name already exists in
/// the workspace. Uses `LOWER(name)` to match the DB unique index.
pub fn dbLabelNameExists(workspace_id: []const u8, name: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT 1 FROM issue_label WHERE workspace_id = $1::uuid AND LOWER(name) = LOWER($2) LIMIT 1",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = name },
        },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}

/// `SELECT ... FROM issue_label WHERE workspace_id = $1 ORDER BY name`.
pub fn dbListLabels(allocator: std.mem.Allocator, workspace_id: []const u8) ![]LabelResponse {
    const db = borrowDb() orelse return &[_]LabelResponse{};
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        "SELECT id, workspace_id, name, color, created_at, updated_at FROM issue_label WHERE workspace_id = $1::uuid ORDER BY name ASC",
        &[_]SqlParam{.{ .text = workspace_id }},
    );
    defer rs.deinit();
    var list: std.ArrayList(LabelResponse) = .empty;
    errdefer {
        for (list.items) |item| freeLabelResponse(allocator, item);
        list.deinit(allocator);
    }
    for (0..rs.rows.items.len) |i| {
        const resp = labelResponseFromRowDuped(allocator, &rs, i) orelse return error.OutOfMemory;
        try list.append(allocator, resp);
    }
    return try list.toOwnedSlice(allocator);
}

/// `SELECT ... FROM issue_label WHERE id = $1 AND workspace_id = $2`.
/// Returns `null` when no row matches.
pub fn dbGetLabel(workspace_id: []const u8, label_id: []const u8) ?LabelResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "SELECT id, workspace_id, name, color, created_at, updated_at FROM issue_label WHERE id = $1::uuid AND workspace_id = $2::uuid",
        &[_]SqlParam{
            .{ .text = label_id },
            .{ .text = workspace_id },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return labelResponseFromRowDuped(db.allocator, &rs, 0);
}

/// In-memory lookup with workspace scope check. Exposed to other
/// modules (notably `issue`) so `attachLabel` can verify the label
/// exists in the current workspace before joining it to an issue.
pub fn memFindLabel(label_id: []const u8, workspace_id: []const u8) ?LabelEntry {
    // `mem_labels` lives in `label/service.zig`; access it through
    // the public accessor the service module exposes (see
    // `label/service.zig::labelStore`). We import lazily to keep
    // the model layer free of service-level dependencies.
    const store = @import("service.zig").labelStore();
    const entry = store.get(label_id) orelse return null;
    if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) return null;
    return entry;
}

/// `INSERT INTO issue_label ... RETURNING ...`.
/// Returns `null` when the insert failed (no row returned).
pub fn dbCreateLabel(workspace_id: []const u8, name: []const u8, color: []const u8) ?LabelResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "INSERT INTO issue_label (workspace_id, name, color) VALUES ($1::uuid, $2, $3) " ++
            "RETURNING id, workspace_id, name, color, created_at, updated_at",
        &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = name },
            .{ .text = color },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return labelResponseFromRowDuped(db.allocator, &rs, 0);
}

/// `UPDATE issue_label SET name = COALESCE(NULLIF($3, ''), name), color = COALESCE(NULLIF($4, ''), color) WHERE id = $1 AND workspace_id = $2 RETURNING ...`.
/// Pass empty strings for fields the caller doesn't want to update.
pub fn dbUpdateLabel(label_id: []const u8, workspace_id: []const u8, name: []const u8, color: []const u8) ?LabelResponse {
    const db = borrowDb() orelse return null;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "UPDATE issue_label SET " ++
            "name = COALESCE(NULLIF($3, ''), name), " ++
            "color = COALESCE(NULLIF($4, ''), color), " ++
            "updated_at = now() " ++
            "WHERE id = $1::uuid AND workspace_id = $2::uuid " ++
            "RETURNING id, workspace_id, name, color, created_at, updated_at",
        &[_]SqlParam{
            .{ .text = label_id },
            .{ .text = workspace_id },
            .{ .text = name },
            .{ .text = color },
        },
    ) catch return null;
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    return labelResponseFromRowDuped(db.allocator, &rs, 0);
}

/// `DELETE FROM issue_label WHERE id = $1 AND workspace_id = $2 RETURNING id`.
/// Returns `true` when a row was deleted, `false` otherwise.
pub fn dbDeleteLabel(label_id: []const u8, workspace_id: []const u8) bool {
    const db = borrowDb() orelse return false;
    defer deps.releaseBack(db);
    var rs = db.queryParams(
        "DELETE FROM issue_label WHERE id = $1::uuid AND workspace_id = $2::uuid RETURNING id",
        &[_]SqlParam{
            .{ .text = label_id },
            .{ .text = workspace_id },
        },
    ) catch return false;
    defer rs.deinit();
    return rs.rows.items.len > 0;
}
