//! Project module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_projects`)
//! and exposes the seven HTTP-facing operations: `listProjects`,
//! `getProject`, `createProject`, `updateProject`, `deleteProject`,
//! `listResources`, `createResource`. The `handler.zig` is a thin
//! delegate; SQL and data shapes live in `model.zig`.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

const log = std.log.scoped(.project_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_projects: ?std.StringHashMap(model.ProjectEntry) = null;
var mem_project_resources: ?std.StringHashMap(std.ArrayList(model.ResourceEntry)) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memInit() !void {
    if (mem_projects == null) {
        mem_projects = std.StringHashMap(model.ProjectEntry).init(memAlloc());
    }
    if (mem_project_resources == null) {
        mem_project_resources = std.StringHashMap(std.ArrayList(model.ResourceEntry)).init(memAlloc());
    }
}

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return try std.fmt.allocPrint(memAlloc(), "{d}", .{secs});
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

// ──────────────────────────────────────────────────────────────────────
// request DTOs
// ──────────────────────────────────────────────────────────────────────

const ProjectResourcePayload = struct {
    resource_type: []const u8,
    resource_ref: std.json.Value,
    label: ?[]const u8 = null,
    position: ?i32 = null,
};

const CreateProjectRequest = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    status: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    lead_type: ?[]const u8 = null,
    lead_id: ?[]const u8 = null,
    resources: []const ProjectResourcePayload = &.{},
};

const UpdateProjectRequest = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    status: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    lead_type: ?[]const u8 = null,
    lead_id: ?[]const u8 = null,
};

const CreateResourceRequest = struct {
    name: []const u8,
    url: ?[]const u8 = null,
};

// ──────────────────────────────────────────────────────────────────────
// list / get
// ──────────────────────────────────────────────────────────────────────

pub fn listProjects(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const status_filter = ctx.getPara("status") catch null;
    const priority_filter = ctx.getPara("priority") catch null;

    if (deps.hasPool()) {
        const items = try model.dbListProjects(allocator, workspace_id, status_filter, priority_filter);
        defer allocator.free(items);
        try ctx.renderJson(.{ .projects = items, .total = items.len });
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.ProjectResponse) = .empty;
    defer list.deinit(allocator);

    var it = mem_projects.?.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.*;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
        if (status_filter) |s| if (!std.mem.eql(u8, entry.status, s)) continue;
        if (priority_filter) |p| if (!std.mem.eql(u8, entry.priority, p)) continue;
        try list.append(allocator, model.projectResponseFromEntry(entry, 0, 0, 0));
    }
    try ctx.renderJson(.{ .projects = list.items, .total = list.items.len });
}

pub fn getProject(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const project_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "project_id is required" });
        return;
    };

    if (deps.hasPool()) {
        if (try model.dbGetProject(allocator, workspace_id, project_id)) |resp| {
            try ctx.renderJson(resp);
        } else {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "project not found" });
        }
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_projects.?.get(project_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "project not found" });
        return;
    };
    if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "project not found" });
        return;
    }
    try ctx.renderJson(model.projectResponseFromEntry(entry, 0, 0, 0));
}

// ──────────────────────────────────────────────────────────────────────
// create
// ──────────────────────────────────────────────────────────────────────

pub fn createProject(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(CreateProjectRequest);
    defer parsed.deinit();
    const req = parsed.value;

    const title = std.mem.trim(u8, req.title, &std.ascii.whitespace);
    if (title.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "title is required" });
        return;
    }

    const status = if (req.status) |s| s else "planned";
    if (!model.isValidStatus(status)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid status" });
        return;
    }
    const priority = if (req.priority) |p| p else "none";
    if (!model.isValidPriority(priority)) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "invalid priority" });
        return;
    }

    const lead_type = req.lead_type orelse "";
    const lead_id = req.lead_id orelse "";
    if (lead_type.len > 0 or lead_id.len > 0) {
        if (lead_type.len == 0 or lead_id.len == 0 or !model.isValidLeadType(lead_type) or !model.looksLikeUuid(lead_id)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid lead" });
            return;
        }
    }

    _ = req.resources;

    if (deps.hasPool()) {
        if (try model.dbCreateProject(
            allocator,
            workspace_id,
            title,
            req.description orelse "",
            req.icon orelse "",
            status,
            priority,
            lead_type,
            lead_id,
        )) |resp| {
            ctx.res_status = .created;
            try ctx.renderJson(resp);
        } else {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create project" });
        }
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const id = try model.generateId(allocator, title);
    const now = try nowString();
    const entry = model.ProjectEntry{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .title = try memDup(title),
        .description = try memDup(req.description orelse ""),
        .icon = try memDup(req.icon orelse ""),
        .status = try memDup(status),
        .priority = try memDup(priority),
        .lead_type = try memDup(lead_type),
        .lead_id = try memDup(lead_id),
        .created_at = try memDup(now),
        .updated_at = try memDup(now),
    };
    try mem_projects.?.put(entry.id, entry);
    ctx.res_status = .created;
    try ctx.renderJson(model.projectResponseFromEntry(entry, 0, 0, 0));
}

// ──────────────────────────────────────────────────────────────────────
// update
// ──────────────────────────────────────────────────────────────────────

pub fn updateProject(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const project_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "project_id is required" });
        return;
    };

    const parsed = try ctx.parseJsonBody(UpdateProjectRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.title) |t| {
        if (std.mem.trim(u8, t, &std.ascii.whitespace).len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "title is required" });
            return;
        }
    }
    if (req.status) |s| {
        if (!model.isValidStatus(s)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid status" });
            return;
        }
    }
    if (req.priority) |p| {
        if (!model.isValidPriority(p)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid priority" });
            return;
        }
    }

    const lead_type = req.lead_type orelse "";
    const lead_id = req.lead_id orelse "";
    if (lead_type.len > 0 or lead_id.len > 0) {
        if (lead_type.len == 0 or lead_id.len == 0 or !model.isValidLeadType(lead_type) or !model.looksLikeUuid(lead_id)) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "invalid lead" });
            return;
        }
    }

    if (deps.hasPool()) {
        if (try model.dbUpdateProject(
            allocator,
            project_id,
            workspace_id,
            req.title orelse "",
            req.description orelse "",
            req.icon orelse "",
            req.status orelse "",
            req.priority orelse "",
            lead_type,
            lead_id,
        )) |resp| {
            try ctx.renderJson(resp);
        } else {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "project not found" });
        }
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const entry = mem_projects.?.getPtr(project_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "project not found" });
        return;
    };
    if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "project not found" });
        return;
    }
    if (req.title) |t| entry.title = try memDup(std.mem.trim(u8, t, &std.ascii.whitespace));
    if (req.description) |d| entry.description = try memDup(d);
    if (req.icon) |ic| entry.icon = try memDup(ic);
    if (req.status) |s| entry.status = try memDup(s);
    if (req.priority) |p| entry.priority = try memDup(p);
    if (req.lead_type) |t| entry.lead_type = try memDup(t);
    if (req.lead_id) |id| entry.lead_id = try memDup(id);
    entry.updated_at = try nowString();
    try ctx.renderJson(model.projectResponseFromEntry(entry.*, 0, 0, 0));
}

// ──────────────────────────────────────────────────────────────────────
// delete
// ──────────────────────────────────────────────────────────────────────

pub fn deleteProject(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const project_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "project_id is required" });
        return;
    };

    if (deps.hasPool()) {
        model.dbDeleteProject(project_id, workspace_id);
        try response.okNoContent(ctx);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    if (mem_projects.?.fetchRemove(project_id)) |kv| {
        const entry = kv.value;
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            try mem_projects.?.put(entry.id, entry);
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "project not found" });
            return;
        }
        // Cascade: drop any project resources.
        _ = mem_project_resources.?.fetchRemove(project_id);
    }
    try response.okNoContent(ctx);
}

// ──────────────────────────────────────────────────────────────────────
// resources (sub-resource, in-memory only)
// ──────────────────────────────────────────────────────────────────────

const UpdateResourceRequest = struct {
    name: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

fn findResourcePtr(project_id: []const u8, resource_id: []const u8) ?*model.ResourceEntry {
    const list_ptr = mem_project_resources.?.getPtr(project_id) orelse return null;
    for (list_ptr.items) |*r| if (std.mem.eql(u8, r.id, resource_id)) return r;
    return null;
}

pub fn listResources(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const project_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "project_id is required" });
        return;
    };
    if (deps.hasPool()) {
        const items = try model.dbListResources(allocator, project_id);
        defer allocator.free(items);
        try ctx.renderJson(.{ .resources = items, .total = items.len });
        return;
    }
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    if (mem_projects.?.get(project_id) == null) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "project not found" });
        return;
    }
    _ = workspace_id;
    var list: std.ArrayList(model.ResourceResponse) = .empty;
    defer list.deinit(allocator);
    if (mem_project_resources.?.get(project_id)) |items| {
        for (items.items) |r| try list.append(allocator, model.resourceResponseFromEntry(r));
    }
    try ctx.renderJson(.{ .resources = list.items, .total = list.items.len });
}

pub fn createResource(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const project_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "project_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(CreateResourceRequest);
    defer parsed.deinit();
    const req = parsed.value;
    const name = std.mem.trim(u8, req.name, &std.ascii.whitespace);
    if (name.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "name is required" });
        return;
    }
    if (deps.hasPool()) {
        if (try model.dbCreateResource(allocator, project_id, workspace_id, name, req.url orelse "")) |resp| {
            ctx.res_status = .created;
            try ctx.renderJson(resp);
        } else {
            ctx.res_status = .internal_server_error;
            try ctx.renderJson(.{ .@"error" = "failed to create resource" });
        }
        return;
    }
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    if (mem_projects.?.get(project_id) == null) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "project not found" });
        return;
    }
    const id = try model.generateId(memAlloc(), name);
    const now = try nowString();
    const entry = model.ResourceEntry{
        .id = try memDup(id),
        .project_id = try memDup(project_id),
        .name = try memDup(name),
        .url = try memDup(req.url orelse ""),
        .created_at = try memDup(now),
        .updated_at = try memDup(now),
    };
    // Append to the project's resource list, creating the bucket on
    // first use. The bucket key must outlive the request, so we
    // memDup it before insertion.
    const stable_pid = try memDup(project_id);
    errdefer memAlloc().free(stable_pid);
    const gop = try mem_project_resources.?.getOrPut(stable_pid);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(memAlloc(), entry);
    ctx.res_status = .created;
    try ctx.renderJson(model.resourceResponseFromEntry(entry));
}

pub fn updateResource(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const project_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "project_id is required" });
        return;
    };
    const resource_id = ctx.getPathParam("resourceId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "resource_id is required" });
        return;
    };
    const parsed = try ctx.parseJsonBody(UpdateResourceRequest);
    defer parsed.deinit();
    const req = parsed.value;
    if (deps.hasPool()) {
        if (try model.dbUpdateResource(allocator, resource_id, req.name orelse "", req.url orelse "")) |resp| {
            try ctx.renderJson(resp);
        } else {
            try response.err(ctx, .not_found, "resource not found", 40401);
        }
        return;
    }
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    if (mem_projects.?.get(project_id) == null) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "project not found" });
        return;
    }
    _ = workspace_id;
    const entry = findResourcePtr(project_id, resource_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "resource not found" });
        return;
    };
    if (req.name) |n| {
        const trimmed = std.mem.trim(u8, n, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "name cannot be empty" });
            return;
        }
        entry.name = try memDup(trimmed);
    }
    if (req.url) |u| entry.url = try memDup(u);
    entry.updated_at = try nowString();
    try ctx.renderJson(model.resourceResponseFromEntry(entry.*));
}

pub fn deleteResource(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const project_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "project_id is required" });
        return;
    };
    const resource_id = ctx.getPathParam("resourceId") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "resource_id is required" });
        return;
    };
    _ = workspace_id;
    if (deps.hasPool()) {
        model.dbDeleteResource(resource_id);
        try response.okNoContent(ctx);
        return;
    }
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    if (mem_projects.?.get(project_id) == null) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "project not found" });
        return;
    }
    const list_ptr = mem_project_resources.?.getPtr(project_id) orelse {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "resource not found" });
        return;
    };
    for (list_ptr.items, 0..) |r, i| {
        if (std.mem.eql(u8, r.id, resource_id)) {
            _ = list_ptr.orderedRemove(i);
            try response.okNoContent(ctx);
            return;
        }
    }
    ctx.res_status = .not_found;
    try ctx.renderJson(.{ .@"error" = "resource not found" });
}
