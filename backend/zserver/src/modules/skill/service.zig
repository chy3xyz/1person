//! Skill module — business logic.
//!
//! Owns the per-process state (`g_cfg` and the in-memory skill/file
//! maps living in `model.zig`) and exposes the eleven HTTP-facing
//! operations: `listSkills`, `searchSkills`, `createSkill`,
//! `getSkill`, `updateSkill`, `deleteSkill`, `importSkill`,
//! `listSkillFiles`, `upsertSkillFile`, `deleteSkillFile`, plus the
//! `dbCreateImportedSkill` / `memCreateImportedSkill` /
//! `createImportedSkill` helpers that `importSkill` chains. The
//! `handler.zig` is a thin delegate; SQL and data shapes live in
//! `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const response_lib = @import("../../common/response.zig");
const common_ctx = @import("../../common/ctx.zig");

const log = std.log.scoped(.skill_service);

var g_cfg: ?*const Config = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getWorkspaceId(ctx);
    }

fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getUserId(ctx);
    }

fn getWorkspaceRole(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_role");
}

fn requireAdmin(ctx: *zfinal.Context) !bool {
    const role = getWorkspaceRole(ctx) orelse "";
    if (std.mem.eql(u8, role, "owner") or std.mem.eql(u8, role, "admin")) return true;
    ctx.res_status = .forbidden;
    try ctx.renderJson(.{ .@"error" = "insufficient permissions" });
    return false;
}

fn canManageSkill(user_id: []const u8, role: []const u8, created_by: []const u8) bool {
    if (std.mem.eql(u8, role, "owner") or std.mem.eql(u8, role, "admin")) return true;
    if (created_by.len > 0 and std.mem.eql(u8, created_by, user_id)) return true;
    return false;
}

fn loadSkill(_: std.mem.Allocator, workspace_id: []const u8, skill_id: []const u8) !?model.SkillEntry {
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const sql =
            \\SELECT id, workspace_id, name, description, content, config, created_by, created_at, updated_at
            \\FROM skill WHERE id = $1::uuid AND workspace_id = $2::uuid
        ;
        var rs = try db.queryParams(sql, &[_]SqlParam{
            .{ .text = skill_id },
            .{ .text = workspace_id },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) return null;
        const id = db.allocator.dupe(u8, rs.rows.items[0].getText(0) orelse "") catch return null;
        const ws_id = db.allocator.dupe(u8, rs.rows.items[0].getText(1) orelse "") catch { db.allocator.free(id); return null; };
        const name = db.allocator.dupe(u8, rs.rows.items[0].getText(2) orelse "") catch { db.allocator.free(id); db.allocator.free(ws_id); return null; };
        const desc = db.allocator.dupe(u8, rs.rows.items[0].getText(3) orelse "") catch { db.allocator.free(id); db.allocator.free(ws_id); db.allocator.free(name); return null; };
        const content = db.allocator.dupe(u8, rs.rows.items[0].getText(4) orelse "") catch { db.allocator.free(id); db.allocator.free(ws_id); db.allocator.free(name); db.allocator.free(desc); return null; };
        const config = db.allocator.dupe(u8, rs.rows.items[0].getText(5) orelse "{}") catch { db.allocator.free(id); db.allocator.free(ws_id); db.allocator.free(name); db.allocator.free(desc); db.allocator.free(content); return null; };
        const created_by = db.allocator.dupe(u8, rs.rows.items[0].getText(6) orelse "") catch { db.allocator.free(id); db.allocator.free(ws_id); db.allocator.free(name); db.allocator.free(desc); db.allocator.free(content); db.allocator.free(config); return null; };
        const created_at = db.allocator.dupe(u8, rs.rows.items[0].getText(7) orelse "") catch { db.allocator.free(id); db.allocator.free(ws_id); db.allocator.free(name); db.allocator.free(desc); db.allocator.free(content); db.allocator.free(config); db.allocator.free(created_by); return null; };
        const updated_at = db.allocator.dupe(u8, rs.rows.items[0].getText(8) orelse "") catch { db.allocator.free(id); db.allocator.free(ws_id); db.allocator.free(name); db.allocator.free(desc); db.allocator.free(content); db.allocator.free(config); db.allocator.free(created_by); db.allocator.free(created_at); return null; };
        return model.SkillEntry{
            .id = id,
            .workspace_id = ws_id,
            .name = name,
            .description = desc,
            .content = content,
            .config = config,
            .created_by = created_by,
            .created_at = created_at,
            .updated_at = updated_at,
        };
    } else {
        try model.memInit();
        const entry = model.mem_skills.?.get(skill_id) orelse return null;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) return null;
        return entry;
    }
}

// ──────────────────────────────────────────────────────────────────────
// list / search
// ──────────────────────────────────────────────────────────────────────

pub fn listSkills(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const sql =
            \\SELECT id, workspace_id, name, description, config, created_by, created_at, updated_at
            \\FROM skill WHERE workspace_id = $1::uuid ORDER BY name ASC
        ;
        var rs = try db.queryParams(sql, &[_]SqlParam{.{ .text = workspace_id }});
        defer rs.deinit();
        var list: std.ArrayList(model.SkillSummaryResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try list.append(allocator, try model.skillSummaryFromRow(allocator, &rs, i));
        }
        try ctx.renderJson(list.items);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.SkillSummaryResponse) = .empty;
        defer list.deinit(allocator);
        var it = model.mem_skills.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            try list.append(allocator, try model.skillSummaryFromEntry(allocator, entry));
        }
        try ctx.renderJson(list.items);
    }
}

pub fn searchSkills(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const q_raw = ctx.getPara("q") catch null;
    const q = if (q_raw) |raw| std.mem.trim(u8, raw, &std.ascii.whitespace) else "";
    if (q.len == 0) {
        try ctx.renderJson(&[_]struct {}{});
        return;
    }

    const pattern_b = try allocator.alloc(u8, q.len + 2);
    defer allocator.free(pattern_b);
    @memcpy(pattern_b[1..][0..q.len], q);
    pattern_b[0] = '%';
    pattern_b[q.len + 1] = '%';

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const sql =
            \\SELECT id, workspace_id, name, description, config, created_by, created_at, updated_at FROM skill
            \\WHERE workspace_id = $1::uuid
            \\  AND (LOWER(name) LIKE LOWER($2) OR LOWER(COALESCE(description, '')) LIKE LOWER($2))
            \\ORDER BY name ASC LIMIT 50
        ;
        var rs = try db.queryParams(sql, &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = pattern_b },
        });
        defer rs.deinit();
        var list: std.ArrayList(model.SkillSummaryResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try list.append(allocator, try model.skillSummaryFromRow(allocator, &rs, i));
        }
        try ctx.renderJson(list.items);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.SkillSummaryResponse) = .empty;
        defer list.deinit(allocator);
        var it = model.mem_skills.?.iterator();
        var count: usize = 0;
        const needle_lc = std.ascii.allocLowerString(allocator, q) catch null;
        defer if (needle_lc) |s| allocator.free(s);
        while (it.next()) |e| : (count += 1) {
            if (count >= 50) break;
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            const needle = needle_lc orelse q;
            const name_lc = std.ascii.allocLowerString(allocator, entry.name) catch continue;
            defer allocator.free(name_lc);
            if (std.mem.indexOf(u8, name_lc, needle) == null) {
                const desc_lc = std.ascii.allocLowerString(allocator, entry.description) catch continue;
                defer allocator.free(desc_lc);
                if (std.mem.indexOf(u8, desc_lc, needle) == null) continue;
            }
            try list.append(allocator, try model.skillSummaryFromEntry(allocator, entry));
        }
        try ctx.renderJson(list.items);
    }
}

// ──────────────────────────────────────────────────────────────────────
// create
// ──────────────────────────────────────────────────────────────────────

pub fn createSkill(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.CreateSkillRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const name = std.mem.trim(u8, req.name, &std.ascii.whitespace);
    if (name.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required" });
        return;
    }

    if (req.files) |files| {
        for (files) |f| {
            if (!model.validateFilePath(f.path)) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "invalid file path" });
                return;
            }
        }
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        const config_json = if (req.config) |v| try std.json.Stringify.valueAlloc(allocator, v, .{}) else "{}";
        defer if (req.config != null) allocator.free(config_json);

        const insert_sql =
            \\INSERT INTO skill (workspace_id, name, description, content, config, created_by)
            \\VALUES ($1::uuid, $2, $3, $4, $5::jsonb, $6::uuid)
            \\RETURNING id, workspace_id, name, description, content, config, created_by, created_at, updated_at
        ;
        var rs = try db.queryParams(insert_sql, &[_]SqlParam{
            .{ .text = workspace_id },
            .{ .text = name },
            .{ .text = model.stringOrEmpty(req.description) },
            .{ .text = model.stringOrEmpty(req.content) },
            .{ .text = config_json },
            .{ .text = user_id },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create skill" });
            return;
        }
        const skill_id = rs.rows.items[0].getText(0) orelse "";

        if (req.files) |files| {
            const insert_file_sql =
                \\INSERT INTO skill_file (skill_id, path, content)
                \\VALUES ($1::uuid, $2, $3)
                \\ON CONFLICT (skill_id, path) DO UPDATE SET content = EXCLUDED.content, updated_at = now()
            ;
            for (files) |f| {
                if (std.mem.eql(u8, f.path, "SKILL.md")) continue;
                try db.execParams(insert_file_sql, &[_]SqlParam{
                    .{ .text = skill_id },
                    .{ .text = f.path },
                    .{ .text = f.content },
                });
            }
        }

        const files = try model.dbFilesForSkill(allocator, db, skill_id);
        defer allocator.free(files);
        const skill_resp = try model.skillResponseFromRow(allocator, &rs, 0);
        ctx.res_status = .created;
        try ctx.renderJson(model.SkillWithFilesResponse{ .skill = skill_resp, .files = files });
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        var it = model.mem_skills.?.iterator();
        while (it.next()) |e| {
            const other = e.value_ptr.*;
            if (std.mem.eql(u8, other.workspace_id, workspace_id) and std.mem.eql(u8, other.name, name)) {
                ctx.res_status = .conflict;
                try ctx.renderJson(.{ .@"error" = "a skill with this name already exists" });
                return;
            }
        }

        const id = try model.generateId(allocator, name);
        const now = try model.nowString();
        const config_json = if (req.config) |v| try std.json.Stringify.valueAlloc(model.memAlloc(), v, .{}) else try model.memAlloc().dupe(u8, "{}");
        const entry = model.SkillEntry{
            .id = try model.memDup(id),
            .workspace_id = try model.memDup(workspace_id),
            .name = try model.memDup(name),
            .description = try model.memDup(model.stringOrEmpty(req.description)),
            .content = try model.memDup(model.stringOrEmpty(req.content)),
            .config = config_json,
            .created_by = try model.memDup(user_id),
            .created_at = try model.memDup(now),
            .updated_at = try model.memDup(now),
        };
        try model.mem_skills.?.put(entry.id, entry);
        try model.mem_skill_files.?.put(try model.memDup(id), std.ArrayList(model.SkillFileEntry).empty);

        if (req.files) |files| {
            var list: std.ArrayList(model.SkillFileEntry) = .empty;
            for (files) |f| {
                if (std.mem.eql(u8, f.path, "SKILL.md")) continue;
                const file_id = try model.generateId(model.memAlloc(), f.path);
                try list.append(model.memAlloc(), model.SkillFileEntry{
                    .id = try model.memDup(file_id),
                    .skill_id = try model.memDup(id),
                    .path = try model.memDup(f.path),
                    .content = try model.memDup(f.content),
                    .created_at = try model.memDup(now),
                    .updated_at = try model.memDup(now),
                });
            }
            try model.mem_skill_files.?.put(try model.memDup(id), list);
        }

        const files = try model.memFilesForSkill(allocator, id);
        defer allocator.free(files);
        const skill_resp = try model.skillResponseFromEntry(allocator, entry);
        ctx.res_status = .created;
        try ctx.renderJson(model.SkillWithFilesResponse{ .skill = skill_resp, .files = files });
    }
}

// ──────────────────────────────────────────────────────────────────────
// get / update / delete
// ──────────────────────────────────────────────────────────────────────

pub fn getSkill(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const skill_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "skill_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const sql =
            \\SELECT id, workspace_id, name, description, content, config, created_by, created_at, updated_at
            \\FROM skill WHERE id = $1::uuid AND workspace_id = $2::uuid
        ;
        var rs = try db.queryParams(sql, &[_]SqlParam{
            .{ .text = skill_id },
            .{ .text = workspace_id },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        }
        const files = try model.dbFilesForSkill(allocator, db, skill_id);
        defer allocator.free(files);
        const skill_resp = try model.skillResponseFromRow(allocator, &rs, 0);
        try ctx.renderJson(model.SkillWithFilesResponse{ .skill = skill_resp, .files = files });
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const entry = model.mem_skills.?.get(skill_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        }
        const files = try model.memFilesForSkill(allocator, skill_id);
        defer allocator.free(files);
        const skill_resp = try model.skillResponseFromEntry(allocator, entry);
        try ctx.renderJson(model.SkillWithFilesResponse{ .skill = skill_resp, .files = files });
    }
}

pub fn updateSkill(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const skill_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "skill_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse "";

    const existing = (try loadSkill(allocator, workspace_id, skill_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "skill not found" });
        return;
    };
    if (!canManageSkill(user_id, getWorkspaceRole(ctx) orelse "", existing.created_by)) {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = "only the skill creator can manage this skill" });
        return;
    }

    const parsed = try ctx.parseJsonBody(model.UpdateSkillRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.name) |n| {
        if (std.mem.trim(u8, n, &std.ascii.whitespace).len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "name is required" });
            return;
        }
    }

    if (req.files) |files| {
        for (files) |f| {
            if (!model.validateFilePath(f.path)) {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "invalid file path" });
                return;
            }
        }
    }

    const name = req.name orelse existing.name;

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);

        const config_json = if (req.config) |v| try std.json.Stringify.valueAlloc(allocator, v, .{}) else existing.config;
        defer if (req.config != null) allocator.free(config_json);

        const update_sql =
            \\UPDATE skill SET name = $3, description = $4, content = $5, config = $6::jsonb, updated_at = now()
            \\WHERE id = $1::uuid AND workspace_id = $2::uuid
            \\RETURNING id, workspace_id, name, description, content, config, created_by, created_at, updated_at
        ;
        var rs = try db.queryParams(update_sql, &[_]SqlParam{
            .{ .text = skill_id },
            .{ .text = workspace_id },
            .{ .text = name },
            .{ .text = req.description orelse existing.description },
            .{ .text = req.content orelse existing.content },
            .{ .text = config_json },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        }

        if (req.files) |files| {
            const delete_files_sql =
                \\DELETE FROM skill_file WHERE skill_id = $1::uuid
            ;
            try db.execParams(delete_files_sql, &[_]SqlParam{.{ .text = skill_id }});
            const insert_file_sql =
                \\INSERT INTO skill_file (skill_id, path, content)
                \\VALUES ($1::uuid, $2, $3)
                \\ON CONFLICT (skill_id, path) DO UPDATE SET content = EXCLUDED.content, updated_at = now()
            ;
            for (files) |f| {
                if (std.mem.eql(u8, f.path, "SKILL.md")) continue;
                try db.execParams(insert_file_sql, &[_]SqlParam{
                    .{ .text = skill_id },
                    .{ .text = f.path },
                    .{ .text = f.content },
                });
            }
        }

        const files = try model.dbFilesForSkill(allocator, db, skill_id);
        defer allocator.free(files);
        const skill_resp = try model.skillResponseFromRow(allocator, &rs, 0);
        try ctx.renderJson(model.SkillWithFilesResponse{ .skill = skill_resp, .files = files });
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const entry = model.mem_skills.?.getPtr(skill_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        };

        if (req.name) |n| {
            const trimmed = std.mem.trim(u8, n, &std.ascii.whitespace);
            var it = model.mem_skills.?.iterator();
            while (it.next()) |e| {
                const other = e.value_ptr.*;
                if (std.mem.eql(u8, other.id, skill_id)) continue;
                if (std.mem.eql(u8, other.workspace_id, workspace_id) and std.mem.eql(u8, other.name, trimmed)) {
                    ctx.res_status = .conflict;
                    try ctx.renderJson(.{ .@"error" = "a skill with this name already exists" });
                    return;
                }
            }
            entry.name = try model.memDup(trimmed);
        }
        if (req.description) |d| entry.description = try model.memDup(d);
        if (req.content) |c| entry.content = try model.memDup(c);
        if (req.config) |v| entry.config = try std.json.Stringify.valueAlloc(model.memAlloc(), v, .{});
        entry.updated_at = try model.nowString();

        if (req.files) |files| {
            var list: std.ArrayList(model.SkillFileEntry) = .empty;
            for (files) |f| {
                if (std.mem.eql(u8, f.path, "SKILL.md")) continue;
                const file_id = try model.generateId(model.memAlloc(), f.path);
                try list.append(model.memAlloc(), model.SkillFileEntry{
                    .id = try model.memDup(file_id),
                    .skill_id = try model.memDup(skill_id),
                    .path = try model.memDup(f.path),
                    .content = try model.memDup(f.content),
                    .created_at = try model.memDup(try model.nowString()),
                    .updated_at = try model.memDup(try model.nowString()),
                });
            }
            if (model.mem_skill_files.?.getPtr(skill_id)) |old| {
                for (old.items) |f| {
                    model.memAlloc().free(f.id);
                    model.memAlloc().free(f.skill_id);
                    model.memAlloc().free(f.path);
                    model.memAlloc().free(f.content);
                    model.memAlloc().free(f.created_at);
                    model.memAlloc().free(f.updated_at);
                }
                old.deinit(model.memAlloc());
            }
            try model.mem_skill_files.?.put(try model.memDup(skill_id), list);
        }

        const files = try model.memFilesForSkill(allocator, skill_id);
        defer allocator.free(files);
        const skill_resp = try model.skillResponseFromEntry(allocator, entry.*);
        try ctx.renderJson(model.SkillWithFilesResponse{ .skill = skill_resp, .files = files });
    }
}

pub fn deleteSkill(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const skill_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "skill_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse "";

    const existing = (try loadSkill(allocator, workspace_id, skill_id)) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "skill not found" });
        return;
    };
    if (!canManageSkill(user_id, getWorkspaceRole(ctx) orelse "", existing.created_by)) {
        ctx.res_status = .forbidden;
        try ctx.renderJson(.{ .@"error" = "only the skill creator can manage this skill" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        try db.execParams(
            "DELETE FROM skill WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{
                .{ .text = skill_id },
                .{ .text = workspace_id },
            },
        );
        try response_lib.okNoContent(ctx);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        _ = model.mem_skills.?.fetchRemove(skill_id);
        if (model.mem_skill_files.?.fetchRemove(skill_id)) |kv| {
            var files = kv.value;
            for (files.items) |f| {
                model.memAlloc().free(f.id);
                model.memAlloc().free(f.skill_id);
                model.memAlloc().free(f.path);
                model.memAlloc().free(f.content);
                model.memAlloc().free(f.created_at);
                model.memAlloc().free(f.updated_at);
            }
            files.deinit(model.memAlloc());
        }
        try response_lib.okNoContent(ctx);
    }
}

// ──────────────────────────────────────────────────────────────────────
// skill files
// ──────────────────────────────────────────────────────────────────────

pub fn listSkillFiles(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const skill_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "skill_id is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const check_sql =
            \\SELECT 1 FROM skill WHERE id = $1::uuid AND workspace_id = $2::uuid
        ;
        var check = try db.queryParams(check_sql, &[_]SqlParam{
            .{ .text = skill_id },
            .{ .text = workspace_id },
        });
        defer check.deinit();
        if (check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        }
        const files = try model.dbFilesForSkill(allocator, db, skill_id);
        defer allocator.free(files);
        try ctx.renderJson(files);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);
        const entry = model.mem_skills.?.get(skill_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        }
        const files = try model.memFilesForSkill(allocator, skill_id);
        defer allocator.free(files);
        try ctx.renderJson(files);
    }
}

pub fn upsertSkillFile(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const skill_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "skill_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.UpsertSkillFileRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (!model.validateFilePath(req.path)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid file path" });
        return;
    }

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const check_sql =
            \\SELECT 1 FROM skill WHERE id = $1::uuid AND workspace_id = $2::uuid
        ;
        var check = try db.queryParams(check_sql, &[_]SqlParam{
            .{ .text = skill_id },
            .{ .text = workspace_id },
        });
        defer check.deinit();
        if (check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        }
        const upsert_sql =
            \\INSERT INTO skill_file (skill_id, path, content) VALUES ($1::uuid, $2, $3)
            \\ON CONFLICT (skill_id, path) DO UPDATE SET content = EXCLUDED.content, updated_at = now()
            \\RETURNING id, skill_id, path, content, created_at, updated_at
        ;
        var rs = try db.queryParams(upsert_sql, &[_]SqlParam{
            .{ .text = skill_id },
            .{ .text = req.path },
            .{ .text = req.content },
        });
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to upsert skill file" });
            return;
        }
        try ctx.renderJson(try model.skillFileResponseFromRow(ctx.allocator, &rs, 0));
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const entry = model.mem_skills.?.get(skill_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        }

        var files = model.mem_skill_files.?.get(skill_id) orelse std.ArrayList(model.SkillFileEntry).empty;
        var found = false;
        for (files.items) |*f| {
            if (std.mem.eql(u8, f.path, req.path)) {
                f.content = try model.memDup(req.content);
                f.updated_at = try model.nowString();
                try ctx.renderJson(model.skillFileResponseFromEntry(f.*));
                found = true;
                break;
            }
        }
        if (!found) {
            const file_id = try model.generateId(model.memAlloc(), req.path);
            const now = try model.nowString();
            const file_entry = model.SkillFileEntry{
                .id = try model.memDup(file_id),
                .skill_id = try model.memDup(skill_id),
                .path = try model.memDup(req.path),
                .content = try model.memDup(req.content),
                .created_at = try model.memDup(now),
                .updated_at = try model.memDup(now),
            };
            try files.append(model.memAlloc(), file_entry);
            try model.mem_skill_files.?.put(try model.memDup(skill_id), files);
            try ctx.renderJson(model.skillFileResponseFromEntry(file_entry));
        }
    }
}

pub fn deleteSkillFile(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const skill_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "skill_id is required" });
        return;
    };
    const path = ctx.getPathParam("path") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "path is required" });
        return;
    };

    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        const check_sql =
            \\SELECT 1 FROM skill WHERE id = $1::uuid AND workspace_id = $2::uuid
        ;
        var check = try db.queryParams(check_sql, &[_]SqlParam{
            .{ .text = skill_id },
            .{ .text = workspace_id },
        });
        defer check.deinit();
        if (check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        }
        try db.execParams(
            "DELETE FROM skill_file WHERE skill_id = $1::uuid AND path = $2",
            &[_]SqlParam{
                .{ .text = skill_id },
                .{ .text = path },
            },
        );
        try response_lib.okNoContent(ctx);
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        const entry = model.mem_skills.?.get(skill_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "skill not found" });
            return;
        }

        if (model.mem_skill_files.?.getPtr(skill_id)) |files| {
            var i: usize = 0;
            while (i < files.items.len) : (i += 1) {
                if (std.mem.eql(u8, files.items[i].path, path)) {
                    const f = files.orderedRemove(i);
                    model.memAlloc().free(f.id);
                    model.memAlloc().free(f.skill_id);
                    model.memAlloc().free(f.path);
                    model.memAlloc().free(f.content);
                    model.memAlloc().free(f.created_at);
                    model.memAlloc().free(f.updated_at);
                    break;
                }
            }
        }
        try response_lib.okNoContent(ctx);
    }
}

// ──────────────────────────────────────────────────────────────────────
// import (DB + mem helpers, public for reuse)
// ──────────────────────────────────────────────────────────────────────

pub fn dbCreateImportedSkill(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8, name: []const u8, description: []const u8, content: []const u8, config: std.json.Value, files: []const model.CreateSkillFileRequest) !?model.SkillWithFilesResponse {
    const db = model.borrowDb() orelse return null;
    defer deps.releaseBack(db);
    const config_json = try std.json.Stringify.valueAlloc(allocator, config, .{});
    defer allocator.free(config_json);
    const insert_sql =
        \\INSERT INTO skill (workspace_id, name, description, content, config, created_by)
        \\VALUES ($1::uuid, $2, $3, $4, $5::jsonb, $6::uuid)
        \\RETURNING id, workspace_id, name, description, content, config, created_by, created_at, updated_at
    ;
    var rs = try db.queryParams(insert_sql, &[_]SqlParam{
        .{ .text = workspace_id },
        .{ .text = name },
        .{ .text = description },
        .{ .text = content },
        .{ .text = config_json },
        .{ .text = user_id },
    });
    defer rs.deinit();
    if (rs.rows.items.len == 0) return null;
    const skill_id = rs.rows.items[0].getText(0) orelse "";
    const insert_file_sql =
        \\INSERT INTO skill_file (skill_id, path, content) VALUES ($1::uuid, $2, $3)
    ;
    for (files) |f| {
        if (std.mem.eql(u8, f.path, "SKILL.md")) continue;
        try db.execParams(insert_file_sql, &[_]SqlParam{
            .{ .text = skill_id },
            .{ .text = f.path },
            .{ .text = f.content },
        });
    }
    const skill_resp = try model.skillResponseFromRow(allocator, &rs, 0);
    const out_files = try model.dbFilesForSkill(allocator, db, skill_id);
    return model.SkillWithFilesResponse{ .skill = skill_resp, .files = out_files };
}

pub fn memCreateImportedSkill(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8, name: []const u8, description: []const u8, content: []const u8, config: std.json.Value, files: []const model.CreateSkillFileRequest) !model.SkillWithFilesResponse {
    try model.memInit();
    const id = try model.generateId(allocator, name);
    const now = try model.nowString();
    const config_json = try std.json.Stringify.valueAlloc(model.memAlloc(), config, .{});
    const entry = model.SkillEntry{
        .id = try model.memDup(id),
        .workspace_id = try model.memDup(workspace_id),
        .name = try model.memDup(name),
        .description = try model.memDup(description),
        .content = try model.memDup(content),
        .config = config_json,
        .created_by = try model.memDup(user_id),
        .created_at = try model.memDup(now),
        .updated_at = try model.memDup(now),
    };
    try model.mem_skills.?.put(entry.id, entry);
    try model.mem_skill_files.?.put(try model.memDup(id), std.ArrayList(model.SkillFileEntry).empty);

    var list: std.ArrayList(model.SkillFileEntry) = .empty;
    for (files) |f| {
        if (std.mem.eql(u8, f.path, "SKILL.md")) continue;
        const file_id = try model.generateId(model.memAlloc(), f.path);
        try list.append(model.memAlloc(), model.SkillFileEntry{
            .id = try model.memDup(file_id),
            .skill_id = try model.memDup(id),
            .path = try model.memDup(f.path),
            .content = try model.memDup(f.content),
            .created_at = try model.memDup(now),
            .updated_at = try model.memDup(now),
        });
    }
    if (list.items.len > 0) {
        if (model.mem_skill_files.?.getPtr(id)) |old| {
            for (old.items) |f| {
                model.memAlloc().free(f.id);
                model.memAlloc().free(f.skill_id);
                model.memAlloc().free(f.path);
                model.memAlloc().free(f.content);
                model.memAlloc().free(f.created_at);
                model.memAlloc().free(f.updated_at);
            }
            old.deinit(model.memAlloc());
        }
        try model.mem_skill_files.?.put(try model.memDup(id), list);
    }

    const out_files = try model.memFilesForSkill(allocator, id);
    const skill_resp = try model.skillResponseFromEntry(allocator, entry);
    return model.SkillWithFilesResponse{ .skill = skill_resp, .files = out_files };
}

pub fn createImportedSkill(allocator: std.mem.Allocator, workspace_id: []const u8, user_id: []const u8, name: []const u8, description: []const u8, content: []const u8, config: std.json.Value, files: []const model.CreateSkillFileRequest) !model.SkillWithFilesResponse {
    if (deps.hasPool()) {
        if (try dbCreateImportedSkill(allocator, workspace_id, user_id, name, description, content, config, files)) |resp| {
            return resp;
        }
    }
    return try memCreateImportedSkill(allocator, workspace_id, user_id, name, description, content, config, files);
}

// ──────────────────────────────────────────────────────────────────────
// fetch helpers (HTTP + frontmatter parser)
// ──────────────────────────────────────────────────────────────────────

fn fetchURL(allocator: std.mem.Allocator, url: []const u8) !?[]u8 {
    const uri = std.Uri.parse(url) catch return null;
    var client = std.http.Client{ .allocator = allocator, .io = zfinal.io_instance.io };
    defer client.deinit();
    var req = try client.request(.GET, uri, .{
        .headers = .{ .user_agent = .{ .override = "multica-zserver/0.1" } },
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    const status_class = response.head.status.class();
    if (status_class != .success) return null;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var transfer_buf: [4096]u8 = undefined;
    const rdr = response.reader(&transfer_buf);
    while (true) {
        const n = rdr.readSliceShort(&transfer_buf) catch break;
        if (n == 0) break;
        try body.appendSlice(allocator, transfer_buf[0..n]);
    }
    return try body.toOwnedSlice(allocator);
}

fn sanitizeSkillText(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    // Remove NUL bytes; invalid UTF-8 is rejected by the JSON renderer later.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == 0) continue;
        try list.append(allocator, raw[i]);
    }
    const cleaned = try list.toOwnedSlice(allocator);
    defer allocator.free(cleaned);
    return allocator.dupe(u8, cleaned);
}

fn parseSkillFrontmatter(content: []const u8) struct { name: []const u8, description: []const u8 } {
    const marker = "---\n";
    if (!std.mem.startsWith(u8, content, marker)) return .{ .name = "", .description = "" };
    const end = std.mem.indexOf(u8, content[marker.len..], marker) orelse return .{ .name = "", .description = "" };
    const frontmatter = content[marker.len .. marker.len + end];
    var name: []const u8 = "";
    var description: []const u8 = "";
    var it = std.mem.splitScalar(u8, frontmatter, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            name = std.mem.trim(u8, trimmed[5..], &std.ascii.whitespace);
        } else if (std.mem.startsWith(u8, trimmed, "description:")) {
            description = std.mem.trim(u8, trimmed[12..], &std.ascii.whitespace);
        }
    }
    return .{ .name = name, .description = description };
}

fn detectImportSource(url: []const u8) ?[]const u8 {
    var buf: [2048]u8 = undefined;
    if (url.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf[0..url.len], url);
    if (std.mem.indexOf(u8, lower, "skills.sh") != null) return "skills_sh";
    if (std.mem.indexOf(u8, lower, "clawhub.ai") != null) return "clawhub";
    if (std.mem.indexOf(u8, lower, "github.com") != null or std.mem.indexOf(u8, lower, "raw.githubusercontent.com") != null) return "github";
    return null;
}

fn fetchGitHubRawURL(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8, ref: []const u8, path: []const u8) !?[]u8 {
    const url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/{s}/{s}", .{ owner, repo, ref, path });
    defer allocator.free(url);
    return try fetchURL(allocator, url);
}

fn importFromGitHub(allocator: std.mem.Allocator, url: []const u8) !?model.ImportedSkill {
    const parsed = std.Uri.parse(url) catch return null;
    const path = parsed.path.percent_encoded;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, path, "/"), '/');
    var owner: ?[]const u8 = null;
    var repo: ?[]const u8 = null;
    var ref: []const u8 = "main";
    var skill_path: []const u8 = "";
    if (std.mem.indexOf(u8, url, "raw.githubusercontent.com") != null) {
        owner = parts.next();
        repo = parts.next();
        ref = parts.next() orelse "main";
        skill_path = std.mem.trim(u8, path[owner.?.len + repo.?.len + ref.len + 3 ..], "/");
    } else {
        owner = parts.next();
        repo = parts.next();
        const kind = parts.next();
        if (kind) |k| {
            if (std.mem.eql(u8, k, "tree") or std.mem.eql(u8, k, "blob")) {
                ref = parts.next() orelse "main";
                var rest: std.ArrayList(u8) = .empty;
                defer rest.deinit(allocator);
                while (parts.next()) |p| {
                    if (rest.items.len > 0) try rest.appendSlice(allocator, "/");
                    try rest.appendSlice(allocator, p);
                }
                skill_path = std.mem.trim(u8, rest.items, "/");
            }
        }
    }
    const o = owner orelse return null;
    const r = repo orelse return null;
    const skill_file = if (skill_path.len > 0) try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_path}) else "SKILL.md";
    defer if (skill_path.len > 0) allocator.free(skill_file);
    const raw = (try fetchGitHubRawURL(allocator, o, r, ref, skill_file)) orelse return null;
    defer allocator.free(raw);
    const cleaned = try sanitizeSkillText(allocator, raw);
    const fm = parseSkillFrontmatter(cleaned);
    const name = if (fm.name.len > 0) fm.name else if (skill_path.len > 0) std.fs.path.basename(skill_path) else r;
    var origin = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try origin.put(allocator, "type", .{ .string = "github" });
    try origin.put(allocator, "source_url", .{ .string = url });
    try origin.put(allocator, "owner", .{ .string = o });
    try origin.put(allocator, "repo", .{ .string = r });
    try origin.put(allocator, "ref", .{ .string = ref });
    if (skill_path.len > 0) try origin.put(allocator, "path", .{ .string = skill_path });
    return model.ImportedSkill{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, fm.description),
        .content = cleaned,
        .origin = .{ .object = origin },
    };
}

fn importFromSkillsSh(allocator: std.mem.Allocator, url: []const u8) !?model.ImportedSkill {
    const parsed = std.Uri.parse(url) catch return null;
    const path = parsed.path.percent_encoded;
    const parts = std.mem.splitScalar(u8, std.mem.trim(u8, path, "/"), '/');
    var owner: ?[]const u8 = null;
    var repo: ?[]const u8 = null;
    var skill_name: ?[]const u8 = null;
    var idx: u8 = 0;
    var it = parts;
    while (it.next()) |p| {
        switch (idx) {
            0 => owner = p,
            1 => repo = p,
            2 => skill_name = p,
            else => {},
        }
        idx += 1;
    }
    if (owner == null or repo == null or skill_name == null) return null;
    const o = owner.?;
    const r = repo.?;
    const s = skill_name.?;
    const candidates = [_][]const u8{
        try std.fmt.allocPrint(allocator, "skills/{s}/SKILL.md", .{s}),
        try std.fmt.allocPrint(allocator, ".claude/skills/{s}/SKILL.md", .{s}),
        try std.fmt.allocPrint(allocator, "plugin/skills/{s}/SKILL.md", .{s}),
        try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{s}),
    };
    defer for (candidates) |c| allocator.free(c);
    for (candidates) |candidate| {
        if (try fetchGitHubRawURL(allocator, o, r, "main", candidate)) |raw| {
            defer allocator.free(raw);
            const cleaned = try sanitizeSkillText(allocator, raw);
            const fm = parseSkillFrontmatter(cleaned);
            const name = if (fm.name.len > 0) fm.name else s;
            var origin = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            try origin.put(allocator, "type", .{ .string = "skills_sh" });
            try origin.put(allocator, "source_url", .{ .string = url });
            try origin.put(allocator, "owner", .{ .string = o });
            try origin.put(allocator, "repo", .{ .string = r });
            try origin.put(allocator, "skill", .{ .string = s });
            return model.ImportedSkill{
                .name = try allocator.dupe(u8, name),
                .description = try allocator.dupe(u8, fm.description),
                .content = cleaned,
                .origin = .{ .object = origin },
            };
        }
    }
    return null;
}

fn fetchImportedSkill(allocator: std.mem.Allocator, url: []const u8) !?model.ImportedSkill {
    const source = detectImportSource(url) orelse return null;
    if (std.mem.eql(u8, source, "github")) return try importFromGitHub(allocator, url);
    if (std.mem.eql(u8, source, "skills_sh")) return try importFromSkillsSh(allocator, url);
    return null;
}

pub fn importSkill(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const user_id = getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const parsed = try ctx.parseJsonBody(model.ImportSkillRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (std.mem.trim(u8, req.url, &std.ascii.whitespace).len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "url is required" });
        return;
    }
    const on_conflict = std.mem.trim(u8, req.on_conflict orelse "fail", &std.ascii.whitespace);
    if (!std.mem.eql(u8, on_conflict, "fail") and !std.mem.eql(u8, on_conflict, "overwrite") and
        !std.mem.eql(u8, on_conflict, "rename") and !std.mem.eql(u8, on_conflict, "skip") and on_conflict.len != 0)
    {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "on_conflict must be one of: fail, overwrite, rename, skip" });
        return;
    }
    const strategy = if (on_conflict.len == 0) "fail" else on_conflict;
    const structured = req.on_conflict != null;

    const imported = (try fetchImportedSkill(allocator, req.url)) orelse {
        ctx.res_status = .bad_gateway;
        try ctx.renderJson(.{ .@"error" = "failed to fetch skill from url" });
        return;
    };

    var config = std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) catch {
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "failed to allocate config" });
        return;
    };
    if (imported.origin == .object) {
        config = imported.origin.object;
    }

    var final_name: []const u8 = imported.name;
    var renamed = false;

    if (deps.hasPool()) {
        if (try model.dbFindSkillIdByName(workspace_id, imported.name)) |existing_id| {
            defer model.memAlloc().free(existing_id);
            if (std.mem.eql(u8, strategy, "skip")) {
                try ctx.renderJson(.{ .status = "skipped", .reason = "a skill with this name already exists" });
                return;
            }
            if (std.mem.eql(u8, strategy, "fail")) {
                ctx.res_status = .conflict;
                try ctx.renderJson(.{ .@"error" = "a skill with this name already exists" });
                return;
            }
            if (std.mem.eql(u8, strategy, "overwrite")) {
                const db_handle = deps.acquire() catch {
                    ctx.res_status = .internal_server_error;
                    try ctx.renderJson(.{ .@"error" = "database_unavailable" });
                    return;
                };
                defer deps.releaseBack(db_handle);
                const config_json = std.json.Stringify.valueAlloc(model.memAlloc(), std.json.Value{ .object = config }, .{}) catch {
                    ctx.res_status = .internal_server_error;
                    try ctx.renderJson(.{ .@"error" = "failed to allocate config" });
                    return;
                };
                const update_sql =
                    \\UPDATE skill SET description = $3, content = $4, config = $5::jsonb, updated_at = now()
                    \\WHERE id = $1::uuid AND workspace_id = $2::uuid
                    \\RETURNING id, workspace_id, name, description, content, config, created_by, created_at, updated_at
                ;
                var rs = db_handle.queryParams(update_sql, &[_]SqlParam{
                    .{ .text = existing_id },
                    .{ .text = workspace_id },
                    .{ .text = imported.description },
                    .{ .text = imported.content },
                    .{ .text = config_json },
                }) catch |err| {
                    log.err("importSkill: overwrite failed: {}", .{err});
                    ctx.res_status = .internal_server_error;
                    try ctx.renderJson(.{ .@"error" = "failed_to_update_skill" });
                    return;
                };
                defer rs.deinit();
                if (rs.rows.items.len == 0) {
                    ctx.res_status = .not_found;
                    try ctx.renderJson(.{ .@"error" = "skill not found" });
                    return;
                }
                const files = try model.dbFilesForSkill(allocator, db_handle, existing_id);
                defer allocator.free(files);
                const skill_resp = try model.skillResponseFromRow(allocator, &rs, 0);
                const resp = model.SkillWithFilesResponse{ .skill = skill_resp, .files = files };
                if (structured) {
                    try ctx.renderJson(.{ .status = "updated", .skill = resp });
                } else {
                    try ctx.renderJson(resp);
                }
                return;
            }
            if (std.mem.eql(u8, strategy, "rename")) {
                var new_name: []const u8 = imported.name;
                var suffix: usize = 1;
                while ((try model.dbFindSkillIdByName(workspace_id, new_name)) != null) : (suffix += 1) {
                    allocator.free(new_name);
                    new_name = std.fmt.allocPrint(allocator, "{s} ({d})", .{ imported.name, suffix }) catch {
                        ctx.res_status = .internal_server_error;
                        try ctx.renderJson(.{ .@"error" = "failed to compute new name" });
                        return;
                    };
                }
                const resp = createImportedSkill(allocator, workspace_id, user_id, new_name, imported.description, imported.content, .{ .object = config }, &[_]model.CreateSkillFileRequest{}) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    ctx.res_status = .internal_server_error;
                    try ctx.renderJson(.{ .@"error" = "failed to create skill" });
                    return;
                };
                if (!std.mem.eql(u8, new_name, imported.name)) allocator.free(new_name);
                ctx.res_status = .created;
                if (structured) {
                    try ctx.renderJson(.{ .status = "renamed", .skill = resp });
                } else {
                    try ctx.renderJson(resp);
                }
                return;
            }
        }
    } else {
        try model.memInit();
        try model.mem_mutex.lock(zfinal.io_instance.io);
        defer model.mem_mutex.unlock(zfinal.io_instance.io);

        if (model.memFindSkillIdByName(workspace_id, imported.name)) |existing_id| {
            if (std.mem.eql(u8, strategy, "skip")) {
                try ctx.renderJson(.{ .status = "skipped", .reason = "a skill with this name already exists" });
                return;
            }
            if (std.mem.eql(u8, strategy, "fail")) {
                ctx.res_status = .conflict;
                try ctx.renderJson(.{ .@"error" = "a skill with this name already exists" });
                return;
            }
            if (std.mem.eql(u8, strategy, "overwrite")) {
                const entry_ptr = model.mem_skills.?.getPtr(existing_id).?;
                entry_ptr.description = try model.memDup(imported.description);
                entry_ptr.content = try model.memDup(imported.content);
                entry_ptr.config = try std.json.Stringify.valueAlloc(model.memAlloc(), std.json.Value{ .object = config }, .{});
                entry_ptr.updated_at = try model.nowString();
                const files = try model.memFilesForSkill(allocator, existing_id);
                defer allocator.free(files);
                const skill_resp = try model.skillResponseFromEntry(allocator, entry_ptr.*);
                const resp = model.SkillWithFilesResponse{ .skill = skill_resp, .files = files };
                if (structured) {
                    try ctx.renderJson(.{ .status = "updated", .skill = resp });
                } else {
                    try ctx.renderJson(resp);
                }
                return;
            }
            final_name = try model.memUniqueSkillName(allocator, workspace_id, imported.name);
            renamed = true;
        }
    }

    const resp = createImportedSkill(allocator, workspace_id, user_id, final_name, imported.description, imported.content, .{ .object = config }, &[_]model.CreateSkillFileRequest{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        ctx.res_status = .internal_server_error;
        try ctx.renderJson(.{ .@"error" = "failed to create skill" });
        return;
    };
    if (renamed) allocator.free(final_name);
    ctx.res_status = .created;
    if (structured) {
        try ctx.renderJson(.{ .status = "created", .skill = resp });
    } else {
        try ctx.renderJson(resp);
    }
}
