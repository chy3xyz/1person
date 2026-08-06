//! Cloud runtime service — in-memory state machine for cloud node
//! lifecycle. Mirrors the Go server's `cloud_runtime_handler` set.
//!
//! The no-DB path treats every transition (start / stop / reboot)
//! as an atomic status change and never spawns a real provider
//! (AWS / Fly / GCP). The DB path is a stub.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

pub const CloudNodeEntry = model.CloudNodeEntry;
pub const CloudNodeResponse = model.CloudNodeResponse;
pub const ExecResponse = model.ExecResponse;
pub const NodeStatusResponse = model.NodeStatusResponse;

const log = std.log.scoped(.cloud_runtime_service);

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_cloud_nodes: ?std.StringHashMap(model.CloudNodeEntry) = null;

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memDup(text: []const u8) ![]const u8 {
    return memAlloc().dupe(u8, text);
}

fn memInit() !void {
    if (mem_cloud_nodes == null) {
        mem_cloud_nodes = std.StringHashMap(model.CloudNodeEntry).init(memAlloc());
    }
}

fn nowString() ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return std.fmt.allocPrint(memAlloc(), "{d}", .{ts});
}

fn generateId(prefix: []const u8) ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return std.fmt.allocPrint(memAlloc(), "{s}-{d}", .{ prefix, ts });
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id") orelse
        ctx.attributes.get("X-Workspace-Id") orelse
        null;
}

fn requireWorkspaceId(ctx: *zfinal.Context) ![]const u8 {
    return getWorkspaceId(ctx) orelse {
        try response.err(ctx, .bad_request, "workspace_id is required", 40021);
        return error.MissingWorkspace;
    };
}

fn findNodePtr(node_id: []const u8) ?*model.CloudNodeEntry {
    return if (mem_cloud_nodes) |*m| m.getPtr(node_id) else null;
}

fn updateStatus(node: *model.CloudNodeEntry, new_status: []const u8) !void {
    node.status = try memDup(new_status);
    node.last_action_at = try nowString();
    node.updated_at = node.last_action_at;
}

/// `GET /api/cloud-runtime/nodes` — list nodes owned by the
/// current workspace.
pub fn listCloudNodes(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    var list: std.ArrayList(model.CloudNodeResponse) = .empty;
    defer list.deinit(allocator);
    if (mem_cloud_nodes) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.workspace_id, workspace_id)) {
                try list.append(allocator, model.cloudNodeResponseFromEntry(kv.value_ptr.*));
            }
        }
    }
    try ctx.renderJson(.{ .nodes = list.items, .total = list.items.len });
}

/// `POST /api/cloud-runtime/nodes` — provision a new node. The
/// Go server's `provision` endpoint is folded into this for
/// no-DB convenience.
pub fn createCloudNode(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.CreateNodeRequest);
    defer parsed.deinit();
    const req = parsed.value;
    if (req.name.len == 0) {
        try response.err(ctx, .bad_request, "name is required", 40021);
        return;
    }
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const id = try generateId("node");
    const now = try nowString();
    const entry = model.CloudNodeEntry{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(req.name),
        .region = try memDup(req.region),
        .size = try memDup(req.size),
        .status = try memDup("provisioning"),
        .created_at = try memDup(now),
        .updated_at = try memDup(now),
        .last_action_at = try memDup(now),
    };
    try mem_cloud_nodes.?.put(entry.id, entry);
    ctx.res_status = .created;
    try ctx.renderJson(model.cloudNodeResponseFromEntry(entry));
}

/// `DELETE /api/cloud-runtime/nodes` — remove a node by
/// `{instance_id}` in the body (frontend contract). 204 on success,
/// 404 when the node is not owned by this workspace.
///
/// NOTE: zfinal's `parseJsonBody` does not preserve the request body
/// for DELETE (the same limitation noted on issue `removeSubscriber`),
/// so we read the raw body here and fall back to `?instance_id=`.
pub fn deleteCloudNode(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);

    var instance_id: []const u8 = "";
    if (response.queryParam(ctx, "instance_id")) |q| instance_id = q;
    if (instance_id.len == 0) {
        if (ctx.getBodyText()) |raw| {
            defer ctx.allocator.free(raw);
            const parsed = std.json.parseFromSliceLeaky(struct { instance_id: []const u8 = "" }, ctx.allocator, raw, .{}) catch null;
            if (parsed) |p| {
                if (p.instance_id.len > 0) instance_id = p.instance_id;
            }
        } else |_| {}
    }
    if (instance_id.len == 0) {
        try response.err(ctx, .bad_request, "instance_id is required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const node = mem_cloud_nodes.?.get(instance_id) orelse {
        try response.err(ctx, .not_found, "node not found", 40401);
        return;
    };
    if (!std.mem.eql(u8, node.workspace_id, workspace_id)) {
        try response.err(ctx, .not_found, "node not found", 40401);
        return;
    }
    _ = mem_cloud_nodes.?.fetchRemove(instance_id);
    try response.okNoContent(ctx);
}

pub fn startCloudNode(ctx: *zfinal.Context) !void {
    const node_id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "node_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const node = findNodePtr(node_id) orelse {
        try response.err(ctx, .not_found, "node not found", 40401);
        return;
    };
    try updateStatus(node, "running");
    try ctx.renderJson(.{ .id = node.id, .status = node.status, .last_action_at = node.last_action_at });
}

pub fn stopCloudNode(ctx: *zfinal.Context) !void {
    const node_id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "node_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const node = findNodePtr(node_id) orelse {
        try response.err(ctx, .not_found, "node not found", 40401);
        return;
    };
    try updateStatus(node, "stopped");
    try ctx.renderJson(.{ .id = node.id, .status = node.status, .last_action_at = node.last_action_at });
}

pub fn rebootCloudNode(ctx: *zfinal.Context) !void {
    const node_id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "node_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const node = findNodePtr(node_id) orelse {
        try response.err(ctx, .not_found, "node not found", 40401);
        return;
    };
    // Real implementations first transition to rebooting then back
    // to running; the no-DB stub collapses to `rebooting`.
    try updateStatus(node, "rebooting");
    try ctx.renderJson(.{ .id = node.id, .status = node.status, .last_action_at = node.last_action_at });
}

pub fn execOnCloudNode(ctx: *zfinal.Context) !void {
    const node_id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "node_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const node = findNodePtr(node_id) orelse {
        try response.err(ctx, .not_found, "node not found", 40401);
        return;
    };
    // The Go server runs the command on the live node; the no-DB
    // path validates the request and returns a deterministic stub.
    const parsed = try ctx.parseJsonBody(model.ExecRequest);
    defer parsed.deinit();
    if (parsed.value.command.len == 0) {
        try response.err(ctx, .bad_request, "command is required", 40021);
        return;
    }
    node.last_action_at = try nowString();
    try ctx.renderJson(model.ExecResponse{
        .output = try memDup("executed"),
        .exit_code = 0,
    });
}

pub fn getCloudNodeStatus(ctx: *zfinal.Context) !void {
    const node_id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "node_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const node = findNodePtr(node_id) orelse {
        try response.err(ctx, .not_found, "node not found", 40401);
        return;
    };
    try ctx.renderJson(model.NodeStatusResponse{
        .id = node.id,
        .status = node.status,
        .last_action_at = node.last_action_at,
    });
}
