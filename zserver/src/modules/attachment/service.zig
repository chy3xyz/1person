//! Attachment module — business logic.
//!
//! Owns the per-process state (`g_cfg`, the in-memory `mem_attachments`
//! registry, the on-disk `uploads/` directory and sidecar `.meta.json`
//! files) and exposes the seven HTTP-facing operations: `uploadFile`,
//! `downloadAttachment`, `getAttachmentByID`, `getAttachmentContent`,
//! `deleteAttachment`, `serveUploads`, `listAttachments`. The
//! `handler.zig` is a thin delegate; SQL and data shapes live in
//! `model.zig`.
//!
//! The `listForIssue` / `listForComment` / `setCommentId` helpers and
//! the `AttachmentResponse` type are re-exported (or forwarded) so the
//! `comment` module can import them from a single
//! `../attachment/service.zig` path.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");

// Re-export model types so cross-module consumers can keep importing
// `../attachment/service.zig` for `AttachmentResponse` /
// `listForIssue` / `listForComment` / `setCommentId`.
pub const AttachmentResponse = model.AttachmentResponse;
pub const AttachmentEntry = model.AttachmentEntry;
pub const listForIssue = listForIssueImpl;
pub const listForComment = listForCommentImpl;
pub const setCommentId = setCommentIdImpl;

const log = std.log.scoped(.attachment_service);

/// Read and discard any unconsumed request body before a manual
/// `ctx.req.respond(...)`. zfinal's own `drainUnconsumedBody` is private
/// as of v0.20.9, and leaving a POST body unread trips
/// `std.http.Server.discardBody`'s assertion on keep-alive connections.
fn drainBody(ctx: *zfinal.Context) void {
    if (ctx.getBodyText()) |b| ctx.allocator.free(b) else |_| {}
}

/// Equivalent of `ctx.getFile(field)`: parse the multipart body and return
/// an owned copy of the file uploaded under `field`, or null when absent.
/// Implemented here because zfinal v0.20.9's `getFile` does not compile
/// (it binds the file list to a `const`, then calls the mutating `deinit`).
fn takeUploadedFile(ctx: *zfinal.Context, field: []const u8) !?zfinal.UploadFile {
    var files = try ctx.getFiles();
    defer {
        for (files.items) |*f| f.deinit();
        files.deinit(ctx.allocator);
    }

    for (files.items) |f| {
        if (!std.mem.eql(u8, f.field_name, field)) continue;
        return zfinal.UploadFile{
            .field_name = try ctx.allocator.dupe(u8, f.field_name),
            .filename = try ctx.allocator.dupe(u8, f.filename),
            .content_type = try ctx.allocator.dupe(u8, f.content_type),
            .size = f.size,
            .data = try ctx.allocator.dupe(u8, f.data),
            .allocator = ctx.allocator,
        };
    }
    return null;
}

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_attachments: ?std.StringHashMap(model.AttachmentEntry) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
}

// ──────────────────────────────────────────────────────────────────────
// helpers
// ──────────────────────────────────────────────────────────────────────

fn memInit() !void {
    if (mem_attachments == null) {
        mem_attachments = std.StringHashMap(model.AttachmentEntry).init(model.memAlloc());
    }
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

fn isAdminOrOwner(ctx: *zfinal.Context) bool {
    const role = getWorkspaceRole(ctx) orelse return false;
    return std.mem.eql(u8, role, "admin") or std.mem.eql(u8, role, "owner");
}

fn io() std.Io {
    return zfinal.io_instance.io;
}

fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
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

fn memDup(text: []const u8) ![]const u8 {
    return try model.memAlloc().dupe(u8, text);
}

fn nowString() ![]const u8 {
        return common_mem.nowString();
    }

fn ensureUploadDir() !void {
    try std.Io.Dir.cwd().createDirPath(io(), model.upload_dir);
}

fn uploadFilePath(id: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ model.upload_dir, id });
}

fn metaFilePath(id: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ model.upload_dir, id, model.meta_suffix });
}

fn extensionContentType(ext: []const u8) []const u8 {
    const lower = std.ascii.allocLowerString(std.heap.page_allocator, ext) catch return "application/octet-stream";
    defer std.heap.page_allocator.free(lower);
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ ".html", "text/html" },
        .{ ".htm", "text/html" },
        .{ ".css", "text/css" },
        .{ ".js", "application/javascript" },
        .{ ".mjs", "application/javascript" },
        .{ ".json", "application/json" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".svg", "image/svg+xml" },
        .{ ".pdf", "application/pdf" },
        .{ ".zip", "application/zip" },
        .{ ".txt", "text/plain" },
        .{ ".xml", "application/xml" },
        .{ ".ico", "image/x-icon" },
        .{ ".csv", "text/csv" },
        .{ ".yaml", "application/yaml" },
        .{ ".yml", "application/yaml" },
        .{ ".toml", "application/toml" },
        .{ ".md", "text/markdown" },
        .{ ".markdown", "text/markdown" },
    });
    return map.get(lower) orelse "application/octet-stream";
}

fn detectContentType(filename: []const u8, provided: []const u8) []const u8 {
    const ext = std.fs.path.extension(filename);
    if (ext.len > 0) {
        const ct = extensionContentType(ext);
        if (!std.mem.eql(u8, ct, "application/octet-stream")) {
            return ct;
        }
    }
    if (provided.len > 0) return provided;
    return "application/octet-stream";
}

fn normalizeMediaType(ct: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, ct, &std.ascii.whitespace);
    if (std.mem.indexOfScalar(u8, trimmed, ';')) |i| {
        return std.mem.trim(u8, trimmed[0..i], &std.ascii.whitespace);
    }
    return trimmed;
}

fn isInlineContentType(ct: []const u8) bool {
    const media_type = normalizeMediaType(ct);
    const lower = std.ascii.allocLowerString(std.heap.page_allocator, media_type) catch return false;
    defer std.heap.page_allocator.free(lower);
    if (std.mem.eql(u8, lower, "image/svg+xml")) return false;
    return std.mem.startsWith(u8, lower, "image/") or
        std.mem.startsWith(u8, lower, "video/") or
        std.mem.startsWith(u8, lower, "audio/") or
        std.mem.eql(u8, lower, "application/pdf");
}

fn sanitizeFilename(filename: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    for (filename) |c| {
        if (c < 0x20 or c == 0x7f or c == '"' or c == ';' or c == '\\' or c == 0x00) {
            try buf.append(allocator, '_');
        } else {
            try buf.append(allocator, c);
        }
    }
    return try buf.toOwnedSlice(allocator);
}

fn contentDisposition(ct: []const u8, filename: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const disposition = if (isInlineContentType(ct)) "inline" else "attachment";
    const safe = try sanitizeFilename(filename, allocator);
    defer allocator.free(safe);
    return try std.fmt.allocPrint(allocator, "{s}; filename=\"{s}\"", .{ disposition, safe });
}

fn isTextPreviewable(content_type: []const u8, filename: []const u8) bool {
    const ct = blk: {
        const lower = std.ascii.allocLowerString(std.heap.page_allocator, content_type) catch break :blk content_type;
        defer std.heap.page_allocator.free(lower);
        break :blk normalizeMediaType(lower);
    };
    if (std.mem.startsWith(u8, ct, "text/")) return true;
    const text_types = [_][]const u8{
        "application/json",       "application/javascript",
        "application/xml",        "application/x-yaml",
        "application/yaml",       "application/toml",
        "application/x-sh",       "application/x-httpd-php",
    };
    for (text_types) |t| {
        if (std.mem.eql(u8, ct, t)) return true;
    }

    const ext = std.ascii.allocLowerString(std.heap.page_allocator, std.fs.path.extension(filename)) catch return false;
    defer std.heap.page_allocator.free(ext);
    const text_exts = [_][]const u8{
        ".md", ".markdown", ".txt", ".log", ".csv", ".tsv", ".html", ".htm",
        ".json", ".xml", ".yml", ".yaml", ".toml", ".ini", ".conf", ".sh",
        ".bash", ".zsh", ".py", ".rb", ".go", ".rs", ".ts", ".tsx", ".js",
        ".jsx", ".mjs", ".cjs", ".css", ".scss", ".sass", ".less", ".sql",
        ".java", ".kt", ".swift", ".c", ".cc", ".cpp", ".h", ".hpp", ".cs",
        ".php", ".lua", ".vim", ".dockerfile", ".makefile", ".gitignore",
    };
    for (text_exts) |e| {
        if (std.mem.eql(u8, ext, e)) return true;
    }

    const base = std.ascii.allocLowerString(std.heap.page_allocator, std.fs.path.basename(filename)) catch return false;
    defer std.heap.page_allocator.free(base);
    return std.mem.eql(u8, base, "dockerfile") or std.mem.eql(u8, base, "makefile") or std.mem.eql(u8, base, ".env");
}

fn readFileBytes(path: []const u8, allocator: std.mem.Allocator, max_size: usize) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io(), path, .{});
    defer file.close(io());
    const stat = try file.stat(io());
    if (stat.size > max_size) return error.FileTooLarge;
    const size: usize = @intCast(stat.size);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var read_buf: [4096]u8 = undefined;
    var rdr = file.reader(io(), &read_buf);
    var offset: usize = 0;
    while (offset < size) {
        const n = rdr.interface.readSliceShort(buf[offset..]) catch |err| {
            allocator.free(buf);
            return err;
        };
        if (n == 0) {
            allocator.free(buf);
            return error.UnexpectedEOF;
        }
        offset += n;
    }
    return buf;
}

fn buildPublicURL(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const cfg = g_cfg orelse return try allocator.dupe(u8, path);
    if (cfg.public_url.len == 0) return try allocator.dupe(u8, path);
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ cfg.public_url, path });
}

fn buildAttachmentURL(id: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/uploads/{s}", .{id});
    defer allocator.free(path);
    return try buildPublicURL(path, allocator);
}

fn buildDownloadURL(id: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/api/attachments/{s}/download", .{id});
    defer allocator.free(path);
    return try buildPublicURL(path, allocator);
}

fn buildMarkdownURL(id: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return try buildDownloadURL(id, allocator);
}

fn writeLocalMeta(id: []const u8, workspace_id: []const u8, filename: []const u8, content_type: []const u8) !void {
    const path = try metaFilePath(id, std.heap.page_allocator);
    defer std.heap.page_allocator.free(path);
    const meta = model.LocalMeta{
        .workspace_id = workspace_id,
        .filename = filename,
        .content_type = content_type,
    };
    const json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, meta, .{});
    defer std.heap.page_allocator.free(json);
    const file = try std.Io.Dir.cwd().createFile(io(), path, .{});
    defer file.close(io());
    var write_buf: [4096]u8 = undefined;
    var wtr = file.writer(io(), &write_buf);
    try wtr.interface.writeAll(json);
    try wtr.flush();
}

fn readLocalMeta(id: []const u8, allocator: std.mem.Allocator) !?model.LocalMeta {
    const path = try metaFilePath(id, allocator);
    defer allocator.free(path);
    const file = std.Io.Dir.cwd().openFile(io(), path, .{}) catch return null;
    defer file.close(io());
    const stat = try file.stat(io());
    const size: usize = @intCast(stat.size);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    var read_buf: [4096]u8 = undefined;
    var rdr = file.reader(io(), &read_buf);
    var offset: usize = 0;
    while (offset < size) {
        const n = rdr.interface.readSliceShort(buf[offset..]) catch break;
        if (n == 0) break;
        offset += n;
    }
    if (offset != size) return null;
    const parsed = std.json.parseFromSlice(model.LocalMeta, allocator, buf, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    return model.LocalMeta{
        .workspace_id = try allocator.dupe(u8, parsed.value.workspace_id),
        .filename = try allocator.dupe(u8, parsed.value.filename),
        .content_type = try allocator.dupe(u8, parsed.value.content_type),
    };
}

fn uuidFromString(s: []const u8) ?[]const u8 {
    // Accept either a 32-char hex UUID or a standard 36-char hyphenated UUID.
    if (s.len == 32) {
        for (s) |c| {
            if (!std.ascii.isHex(c)) return null;
        }
        return s;
    }
    if (s.len == 36) {
        var buf: [32]u8 = undefined;
        var i: usize = 0;
        for (s) |c| {
            if (c == '-') continue;
            if (!std.ascii.isHex(c)) return null;
            buf[i] = c;
            i += 1;
        }
        return std.heap.page_allocator.dupe(u8, &buf) catch return null;
    }
    return null;
}

fn resolveActor(user_id: []const u8) struct { uploader_type: []const u8, uploader_id: []const u8 } {
    return .{ .uploader_type = "member", .uploader_id = user_id };
}

// ──────────────────────────────────────────────────────────────────────
// Cross-module helpers (used by the `comment` module)
// ──────────────────────────────────────────────────────────────────────

pub fn listForIssueImpl(allocator: std.mem.Allocator, workspace_id: []const u8, issue_id: []const u8, out: *std.ArrayList(model.AttachmentResponse)) !void {
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id, workspace_id, issue_id, comment_id, chat_session_id, chat_message_id, " ++
                "uploader_type, uploader_id, filename, url, content_type, size_bytes, created_at " ++
                "FROM attachment WHERE issue_id = $1::uuid AND workspace_id = $2::uuid ORDER BY created_at DESC",
            &[_]SqlParam{ .{ .text = issue_id }, .{ .text = workspace_id } },
        );
        defer rs.deinit();
        for (0..rs.rows.items.len) |i| {
            try out.append(allocator, model.attachmentResponseFromRow(&rs, i));
        }
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var it = mem_attachments.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, entry.issue_id, issue_id)) continue;
            try out.append(allocator, model.attachmentResponseFromEntry(entry));
        }
    }
}

pub fn listForCommentImpl(allocator: std.mem.Allocator, workspace_id: []const u8, comment_id: []const u8, out: *std.ArrayList(model.AttachmentResponse)) !void {
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        var rs = try db.queryParams(
            "SELECT id, workspace_id, issue_id, comment_id, chat_session_id, chat_message_id, " ++
                "uploader_type, uploader_id, filename, url, content_type, size_bytes, created_at " ++
                "FROM attachment WHERE comment_id = $1::uuid AND workspace_id = $2::uuid ORDER BY created_at ASC",
            &[_]SqlParam{ .{ .text = comment_id }, .{ .text = workspace_id } },
        );
        defer rs.deinit();
        for (0..rs.rows.items.len) |i| {
            try out.append(allocator, model.attachmentResponseFromRow(&rs, i));
        }
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var it = mem_attachments.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, entry.comment_id, comment_id)) continue;
            try out.append(allocator, model.attachmentResponseFromEntry(entry));
        }
    }
}

pub fn setCommentIdImpl(attachment_id: []const u8, comment_id: []const u8, workspace_id: []const u8, issue_id: []const u8) !void {
    if (model.borrowDb()) |db| {
        defer deps.releaseBack(db);
        try db.execParams(
            "UPDATE attachment SET comment_id = $1::uuid " ++
                "WHERE id = $2::uuid AND workspace_id = $3::uuid AND issue_id = $4::uuid",
            &[_]SqlParam{
                .{ .text = comment_id },
                .{ .text = attachment_id },
                .{ .text = workspace_id },
                .{ .text = issue_id },
            },
        );
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry_ptr = mem_attachments.?.getPtr(attachment_id) orelse return;
        if (!std.mem.eql(u8, entry_ptr.workspace_id, workspace_id)) return;
        if (!std.mem.eql(u8, entry_ptr.issue_id, issue_id)) return;
        entry_ptr.comment_id = try memDup(comment_id);
    }
}

// ──────────────────────────────────────────────────────────────────────
// Handlers
// ──────────────────────────────────────────────────────────────────────

pub fn uploadFile(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    ctx.max_body_size = model.max_upload_size;

    const user_id = getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const maybe_workspace_id = blk: {
        const from_header = ctx.getHeader("X-Workspace-ID");
        if (from_header) |id| {
            if (id.len > 0) break :blk uuidFromString(id);
        }
        const from_query = try ctx.getPara("workspace_id");
        if (from_query) |id| {
            if (id.len > 0) break :blk uuidFromString(id);
        }
        break :blk null;
    };

    var issue_id: ?[]const u8 = null;
    var comment_id: ?[]const u8 = null;
    var chat_session_id: ?[]const u8 = null;

    if (maybe_workspace_id) |workspace_id| {
        if (!model.isWorkspaceMember(user_id, workspace_id)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "not a member of this workspace" });
            return;
        }

        if (try ctx.getPara("issue_id")) |raw| {
            if (raw.len > 0) {
                const parsed = uuidFromString(raw) orelse {
                    ctx.res_status = .bad_request;
                    try ctx.renderJson(.{ .@"error" = "invalid issue_id" });
                    return;
                };
                if (!model.issueExistsInWorkspace(parsed, workspace_id)) {
                    ctx.res_status = .forbidden;
                    try ctx.renderJson(.{ .@"error" = "invalid issue_id" });
                    return;
                }
                issue_id = parsed;
            }
        }
        if (try ctx.getPara("comment_id")) |raw| {
            if (raw.len > 0) {
                const parsed = uuidFromString(raw) orelse {
                    ctx.res_status = .bad_request;
                    try ctx.renderJson(.{ .@"error" = "invalid comment_id" });
                    return;
                };
                if (!model.commentExistsInWorkspace(parsed, workspace_id)) {
                    ctx.res_status = .forbidden;
                    try ctx.renderJson(.{ .@"error" = "invalid comment_id" });
                    return;
                }
                comment_id = parsed;
            }
        }
        if (try ctx.getPara("chat_session_id")) |raw| {
            if (raw.len > 0) {
                const parsed = uuidFromString(raw) orelse {
                    ctx.res_status = .bad_request;
                    try ctx.renderJson(.{ .@"error" = "invalid chat_session_id" });
                    return;
                };
                if (!model.chatSessionForUser(parsed, user_id, workspace_id)) {
                    ctx.res_status = .forbidden;
                    try ctx.renderJson(.{ .@"error" = "invalid chat_session_id" });
                    return;
                }
                chat_session_id = parsed;
            }
        }
    }

    var file = try takeUploadedFile(ctx, "file") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing file field" });
        return;
    };
    defer file.deinit();

    const content_type = detectContentType(file.filename, file.content_type);
    const id = try generateId(allocator, file.filename);

    try ensureUploadDir();
    const dest_path = try uploadFilePath(id, allocator);
    defer allocator.free(dest_path);

    {
        const dest_file = try std.Io.Dir.cwd().createFile(io(), dest_path, .{});
        defer dest_file.close(io());
        var write_buf: [4096]u8 = undefined;
        var wtr = dest_file.writer(io(), &write_buf);
        try wtr.interface.writeAll(file.data);
        try wtr.flush();
    }
    try writeLocalMeta(id, maybe_workspace_id orelse "", file.filename, content_type);

    if (maybe_workspace_id) |workspace_id| {
        const actor = resolveActor(user_id);
        const created_at = try nowString();

        const url = try buildAttachmentURL(id, allocator);
        const download_url = try buildDownloadURL(id, allocator);
        const markdown_url = try buildMarkdownURL(id, allocator);

        if (model.borrowDb()) |d| {
            defer deps.releaseBack(d);

            const size_param = try std.fmt.allocPrint(allocator, "{d}", .{file.size});
            defer allocator.free(size_param);

            var insert_rs = d.queryParams(
                "INSERT INTO attachment (" ++
                    "id, workspace_id, uploader_type, uploader_id, filename, url, content_type, size_bytes, " ++
                    "issue_id, comment_id, chat_session_id" ++
                    ") VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5, $6, $7, $8::bigint, $9::uuid, $10::uuid, $11::uuid) " ++
                    "RETURNING id, workspace_id, issue_id, comment_id, chat_session_id, chat_message_id, " ++
                    "uploader_type, uploader_id, filename, url, content_type, size_bytes, created_at",
                &[_]SqlParam{
                    .{ .text = id },
                    .{ .text = workspace_id },
                    .{ .text = actor.uploader_type },
                    .{ .text = actor.uploader_id },
                    .{ .text = file.filename },
                    .{ .text = url },
                    .{ .text = content_type },
                    .{ .text = size_param },
                    .{ .text = issue_id orelse "" },
                    .{ .text = comment_id orelse "" },
                    .{ .text = chat_session_id orelse "" },
                },
            ) catch |err| {
                log.err("failed to create attachment record: {}", .{err});
                // Upload succeeded but DB failed — still return the link so the file is usable.
                ctx.res_status = .ok;
                try ctx.renderJson(.{
                    .id = "",
                    .url = url,
                    .filename = file.filename,
                });
                return;
            };
            defer insert_rs.deinit();

            var resp = model.attachmentResponseFromRow(&insert_rs, 0);
            resp.download_url = download_url;
            resp.markdown_url = markdown_url;
            try ctx.renderJson(resp);
            return;
        }

        // In-memory fallback: store metadata map entry.
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = model.AttachmentEntry{
            .id = try memDup(id),
            .workspace_id = try memDup(workspace_id),
            .issue_id = if (issue_id) |v| try memDup(v) else "",
            .comment_id = if (comment_id) |v| try memDup(v) else "",
            .chat_session_id = if (chat_session_id) |v| try memDup(v) else "",
            .chat_message_id = "",
            .uploader_type = try memDup(actor.uploader_type),
            .uploader_id = try memDup(actor.uploader_id),
            .filename = try memDup(file.filename),
            .url = try memDup(url),
            .content_type = try memDup(content_type),
            .size_bytes = @intCast(file.size),
            .created_at = created_at,
        };
        try mem_attachments.?.put(entry.id, entry);

        var resp = model.attachmentResponseFromEntry(entry);
        resp.download_url = download_url;
        resp.markdown_url = markdown_url;
        try ctx.renderJson(resp);
        return;
    }

    // No workspace context (e.g. avatar upload) — upload directly.
    var file2 = try takeUploadedFile(ctx, "file") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "missing file field" });
        return;
    };
    defer file2.deinit();
    const id2 = try generateId(allocator, file2.filename);
    const url2 = try buildAttachmentURL(id2, allocator);
    ctx.res_status = .ok;
    try ctx.renderJson(.{
        .id = id2,
        .url = url2,
        .filename = file2.filename,
    });
}

pub fn getAttachmentContent(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const attachment_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "attachment_id is required" });
        return;
    };

    var filename: []const u8 = "";
    var content_type: []const u8 = "application/octet-stream";

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "SELECT filename, content_type FROM attachment WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{ .{ .text = attachment_id }, .{ .text = workspace_id } },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        }
        filename = rs.rows.items[0].getText(0) orelse "";
        content_type = rs.rows.items[0].getText(1) orelse "application/octet-stream";
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_attachments.?.get(attachment_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        }
        filename = entry.filename;
        content_type = entry.content_type;
    }

    if (!isTextPreviewable(content_type, filename)) {
        ctx.res_status = .unsupported_media_type;
        try ctx.renderJson(.{ .@"error" = "preview not supported for this file type" });
        return;
    }

    const allocator = ctx.allocator;
    const path = try uploadFilePath(attachment_id, allocator);
    defer allocator.free(path);

    const body = readFileBytes(path, allocator, model.max_preview_size + 1) catch |err| {
        if (err == error.FileTooLarge) {
            ctx.res_status = .payload_too_large;
            try ctx.renderJson(.{ .@"error" = "file too large for inline preview" });
            return;
        }
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "attachment object not found" });
        return;
    };
    defer allocator.free(body);

    if (body.len > model.max_preview_size) {
        ctx.res_status = .payload_too_large;
        try ctx.renderJson(.{ .@"error" = "file too large for inline preview" });
        return;
    }

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" });
    try headers.append(allocator, .{ .name = "X-Original-Content-Type", .value = content_type });
    try headers.append(allocator, .{ .name = "Cache-Control", .value = "no-store" });
    try headers.append(allocator, .{ .name = "X-Content-Type-Options", .value = "nosniff" });

    var header_it = ctx.response_headers.iterator();
    while (header_it.next()) |entry| {
        try headers.append(allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
    }

    drainBody(ctx);
    try ctx.req.respond(body, .{
        .status = .ok,
        .extra_headers = headers.items,
    });
}

pub fn downloadAttachment(ctx: *zfinal.Context) !void {
    const user_id = getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };
    const attachment_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "attachment_id is required" });
        return;
    };

    var workspace_id: []const u8 = "";
    var filename: []const u8 = "";
    var content_type: []const u8 = "application/octet-stream";
    var size_bytes: i64 = 0;

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "SELECT workspace_id, filename, content_type, size_bytes FROM attachment WHERE id = $1::uuid",
            &[_]SqlParam{.{ .text = attachment_id }},
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        }
        workspace_id = rs.rows.items[0].getText(0) orelse "";
        filename = rs.rows.items[0].getText(1) orelse "";
        content_type = rs.rows.items[0].getText(2) orelse "application/octet-stream";
        size_bytes = @intCast(std.fmt.parseInt(i64, rs.rows.items[0].getText(3) orelse "0", 10) catch 0);

        if (workspace_id.len == 0 or !model.isWorkspaceMember(user_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        }
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_attachments.?.get(attachment_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        };
        workspace_id = entry.workspace_id;
        filename = entry.filename;
        content_type = entry.content_type;
        size_bytes = entry.size_bytes;

        if (workspace_id.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        }
        if (!model.isWorkspaceMember(user_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        }
    }

    const allocator = ctx.allocator;
    const path = try uploadFilePath(attachment_id, allocator);
    defer allocator.free(path);

    const body = readFileBytes(path, allocator, model.max_upload_size) catch {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "attachment object not found" });
        return;
    };
    defer allocator.free(body);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "Content-Type", .value = content_type });

    const disp = try contentDisposition(content_type, filename, allocator);
    defer allocator.free(disp);
    try headers.append(allocator, .{ .name = "Content-Disposition", .value = disp });

    if (size_bytes >= 0) {
        const cl = try std.fmt.allocPrint(allocator, "{d}", .{size_bytes});
        defer allocator.free(cl);
        try headers.append(allocator, .{ .name = "Content-Length", .value = cl });
    }

    try headers.append(allocator, .{ .name = "Cache-Control", .value = "no-store" });
    try headers.append(allocator, .{ .name = "X-Content-Type-Options", .value = "nosniff" });

    var header_it = ctx.response_headers.iterator();
    while (header_it.next()) |entry| {
        try headers.append(allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
    }

    drainBody(ctx);
    try ctx.req.respond(body, .{
        .status = .ok,
        .extra_headers = headers.items,
    });
}

pub fn serveUploads(ctx: *zfinal.Context) !void {
    const target = ctx.req.head.target;
    const prefix = "/uploads/";
    if (!std.mem.startsWith(u8, target, prefix)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "not found" });
        return;
    }
    const raw_path = target[prefix.len..];
    const query_pos = std.mem.indexOfScalar(u8, raw_path, '?') orelse raw_path.len;
    var file_path_part = raw_path[0..query_pos];

    // Strip leading slashes and reject empty/traversal/meta requests.
    while (file_path_part.len > 0 and file_path_part[0] == '/') {
        file_path_part = file_path_part[1..];
    }
    if (file_path_part.len == 0 or
        std.mem.indexOf(u8, file_path_part, "..") != null or
        std.mem.startsWith(u8, file_path_part, "/") or
        std.mem.endsWith(u8, file_path_part, model.meta_suffix))
    {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "not found" });
        return;
    }

    const allocator = ctx.allocator;
    const disk_path = try std.fs.path.resolve(allocator, &.{ model.upload_dir, file_path_part });
    defer allocator.free(disk_path);

    // Verify containment under uploads directory.
    const upload_dir_abs = std.fs.path.resolve(allocator, &.{model.upload_dir}) catch {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "not found" });
        return;
    };
    defer allocator.free(upload_dir_abs);
    if (!std.mem.startsWith(u8, disk_path, upload_dir_abs) and !std.mem.eql(u8, disk_path, upload_dir_abs)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "not found" });
        return;
    }

    const user_id = getUserId(ctx) orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "unauthorized" });
        return;
    };

    const id = std.fs.path.basename(file_path_part);

    // Resolve the workspace context and verify membership.
    var workspace_id: []const u8 = ctx.attributes.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        if (ctx.getHeader("X-Workspace-ID")) |hid| {
            workspace_id = uuidFromString(hid) orelse hid;
        }
    }
    if (workspace_id.len == 0) {
        if (try ctx.getPara("workspace_id")) |qid| {
            workspace_id = uuidFromString(qid) orelse qid;
        }
    }

    const sidecar = readLocalMeta(id, allocator) catch null;
    if (sidecar) |m| {
        if (workspace_id.len == 0 and m.workspace_id.len > 0) {
            workspace_id = m.workspace_id;
        }
        if (m.workspace_id.len > 0 and !std.mem.eql(u8, workspace_id, m.workspace_id)) {
            allocator.free(m.workspace_id);
            allocator.free(m.filename);
            allocator.free(m.content_type);
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "not found" });
            return;
        }
        allocator.free(m.workspace_id);
        allocator.free(m.filename);
        allocator.free(m.content_type);
    }

    if (workspace_id.len > 0 and !model.isWorkspaceMember(user_id, workspace_id)) {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "not found" });
        return;
    }

    // Read file into memory (local uploads are capped by max_upload_size).
    const body = readFileBytes(disk_path, allocator, model.max_upload_size) catch {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .@"error" = "not found" });
        return;
    };
    defer allocator.free(body);

    // Determine content type from extension, fallback to octet-stream.
    const content_type = extensionContentType(std.fs.path.extension(file_path_part));

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "Content-Type", .value = content_type });

    // If a sidecar exists, use it to set Content-Disposition with the original filename.
    if (readLocalMeta(id, allocator)) |maybe_meta| {
        if (maybe_meta) |meta| {
            defer {
                allocator.free(meta.workspace_id);
                allocator.free(meta.filename);
                allocator.free(meta.content_type);
            }
            const disp = try contentDisposition(content_type, meta.filename, allocator);
            defer allocator.free(disp);
            try headers.append(allocator, .{ .name = "Content-Disposition", .value = disp });
        }
    } else |_| {}

    var header_it = ctx.response_headers.iterator();
    while (header_it.next()) |entry| {
        try headers.append(allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
    }

    drainBody(ctx);
    try ctx.req.respond(body, .{
        .status = .ok,
        .extra_headers = headers.items,
    });
}

pub fn getAttachmentByID(ctx: *zfinal.Context) !void {
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const attachment_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "attachment_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "SELECT id, workspace_id, issue_id, comment_id, chat_session_id, chat_message_id, " ++
                "uploader_type, uploader_id, filename, url, content_type, size_bytes, created_at " ++
                "FROM attachment WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{ .{ .text = attachment_id }, .{ .text = workspace_id } },
        );
        defer rs.deinit();
        if (rs.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        }
        try ctx.renderJson(model.attachmentResponseFromRow(&rs, 0));
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_attachments.?.get(attachment_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        }
        try ctx.renderJson(model.attachmentResponseFromEntry(entry));
    }
}

pub fn deleteAttachment(ctx: *zfinal.Context) !void {
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
    const attachment_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "attachment_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);

        var check = try d.queryParams(
            "SELECT uploader_type, uploader_id FROM attachment WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{ .{ .text = attachment_id }, .{ .text = workspace_id } },
        );
        defer check.deinit();
        if (check.rows.items.len == 0) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        }
        const uploader_type = check.rows.items[0].getText(0) orelse "";
        const uploader_id = check.rows.items[0].getText(1) orelse "";
        const isUploader = std.mem.eql(u8, uploader_type, "member") and std.mem.eql(u8, uploader_id, user_id);
        if (!isUploader and !isAdminOrOwner(ctx)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "not authorized to delete this attachment" });
            return;
        }

        try d.execParams(
            "DELETE FROM attachment WHERE id = $1::uuid AND workspace_id = $2::uuid",
            &[_]SqlParam{ .{ .text = attachment_id }, .{ .text = workspace_id } },
        );
        ctx.res_status = .no_content;
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        const entry = mem_attachments.?.get(attachment_id) orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        };
        if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "attachment not found" });
            return;
        }
        const isUploader = std.mem.eql(u8, entry.uploader_type, "member") and std.mem.eql(u8, entry.uploader_id, user_id);
        if (!isUploader and !isAdminOrOwner(ctx)) {
            ctx.res_status = .forbidden;
            try ctx.renderJson(.{ .@"error" = "not authorized to delete this attachment" });
            return;
        }
        _ = mem_attachments.?.fetchRemove(attachment_id);
        ctx.res_status = .no_content;
    }
}

pub fn listAttachments(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const workspace_id = getWorkspaceId(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "workspace_id is required" });
        return;
    };
    const issue_id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .@"error" = "issue_id is required" });
        return;
    };

    if (model.borrowDb()) |d| {
        defer deps.releaseBack(d);
        var rs = try d.queryParams(
            "SELECT id, workspace_id, issue_id, comment_id, chat_session_id, chat_message_id, " ++
                "uploader_type, uploader_id, filename, url, content_type, size_bytes, created_at " ++
                "FROM attachment WHERE issue_id = $1::uuid AND workspace_id = $2::uuid ORDER BY created_at DESC",
            &[_]SqlParam{ .{ .text = issue_id }, .{ .text = workspace_id } },
        );
        defer rs.deinit();
        var list: std.ArrayList(model.AttachmentResponse) = .empty;
        defer list.deinit(allocator);
        for (0..rs.rows.items.len) |i| {
            try list.append(allocator, model.attachmentResponseFromRow(&rs, i));
        }
        try ctx.renderJson(.{ .attachments = list.items });
    } else {
        try memInit();
        try mem_mutex.lock(zfinal.io_instance.io);
        defer mem_mutex.unlock(zfinal.io_instance.io);

        var list: std.ArrayList(model.AttachmentResponse) = .empty;
        defer list.deinit(allocator);
        var it = mem_attachments.?.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            if (!std.mem.eql(u8, entry.issue_id, issue_id)) continue;
            try list.append(allocator, model.attachmentResponseFromEntry(entry));
        }
        try ctx.renderJson(.{ .attachments = list.items });
    }
}
