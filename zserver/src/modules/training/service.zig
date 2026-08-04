//! Training service — in-memory CRUD for courses/lessons plus
//! enrollment, lesson-completion, and course-completion (certificate).
//!
//! Operates in no-DB mode using a page-allocator-backed StringHashMap.
//! All per-workspace scoping is enforced on read/write.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

pub const Course = model.Course;
pub const Lesson = model.Lesson;
pub const Enrollment = model.Enrollment;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_courses: ?std.StringHashMap(model.Course) = null;
var mem_lessons: ?std.StringHashMap(model.Lesson) = null;
var mem_enrollments: ?std.StringHashMap(model.Enrollment) = null;
// enrollment key = "{user_id}:{course_id}"

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memDup(text: []const u8) ![]const u8 {
    return memAlloc().dupe(u8, text);
}

fn memInit() !void {
    if (mem_courses == null) {
        mem_courses = std.StringHashMap(model.Course).init(memAlloc());
        mem_lessons = std.StringHashMap(model.Lesson).init(memAlloc());
        mem_enrollments = std.StringHashMap(model.Enrollment).init(memAlloc());
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

fn enrollmentKey(user_id: []const u8, course_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(memAlloc(), "{s}:{s}", .{ user_id, course_id });
}

fn dupStrSlice(slice: []const []const u8) ![]const []const u8 {
    const out = try memAlloc().alloc([]const u8, slice.len);
    for (slice, 0..) |s, i| {
        out[i] = try memDup(s);
    }
    return out;
}

/// Append an item to a string slice. Returns a new slice.
fn appendStr(slice: []const []const u8, item: []const u8) ![]const []const u8 {
    const out = try memAlloc().alloc([]const u8, slice.len + 1);
    for (slice, 0..) |s, i| {
        out[i] = s;
    }
    out[slice.len] = try memDup(item);
    return out;
}

fn containsStr(slice: []const []const u8, needle: []const u8) bool {
    for (slice) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// ── Course CRUD ──────────────────────────────────────────────────

pub fn listCourses(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.Course) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_courses) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.workspace_id, workspace_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try response.ok(ctx, .{ .courses = list.items, .total = list.items.len });
}

pub fn createCourse(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.CreateCourseRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (!model.validateCourseName(req.name)) {
        try response.err(ctx, .bad_request, "name is required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const id = try generateId("crs");
    const entry = model.Course{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(req.name),
        .created_at = try nowStr(),
    };
    try mem_courses.?.put(entry.id, entry);
    ctx.res_status = .created;
    try response.ok(ctx, entry);
}

pub fn getCourse(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "course_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry = mem_courses.?.get(id) orelse {
        try response.err(ctx, .not_found, "course not found", 40401);
        return;
    };
    try response.ok(ctx, entry);
}

pub fn updateCourse(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "course_id is required", 40021);
        return;
    };
    const parsed = try ctx.parseJsonBody(model.UpdateCourseRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry_ptr = mem_courses.?.getPtr(id) orelse {
        try response.err(ctx, .not_found, "course not found", 40401);
        return;
    };
    if (req.name) |n| entry_ptr.name = try memDup(n);
    try response.ok(ctx, entry_ptr.*);
}

pub fn deleteCourse(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "course_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    _ = mem_courses.?.fetchRemove(id) orelse {
        try response.err(ctx, .not_found, "course not found", 40401);
        return;
    };
    try response.okNoContent(ctx);
}

/// ── Lesson CRUD ──────────────────────────────────────────────────

pub fn listLessons(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const course_id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "course_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.Lesson) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_lessons) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.course_id, course_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try response.ok(ctx, .{ .lessons = list.items, .total = list.items.len });
}

pub fn createLesson(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const course_id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "course_id is required", 40021);
        return;
    };
    const parsed = try ctx.parseJsonBody(model.CreateLessonRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (!model.validateLesson(req.title, req.content)) {
        try response.err(ctx, .bad_request, "title and content are required", 40022);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    // Verify course exists
    _ = mem_courses.?.get(course_id) orelse {
        try response.err(ctx, .not_found, "course not found", 40401);
        return;
    };

    const id = try generateId("lsn");
    const entry = model.Lesson{
        .id = try memDup(id),
        .course_id = try memDup(course_id),
        .title = try memDup(req.title),
        .content = try memDup(req.content),
        .quiz = if (req.quiz) |q| try memDup(q) else null,
    };
    try mem_lessons.?.put(entry.id, entry);
    ctx.res_status = .created;
    try response.ok(ctx, entry);
}

pub fn getLesson(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "lesson_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry = mem_lessons.?.get(id) orelse {
        try response.err(ctx, .not_found, "lesson not found", 40402);
        return;
    };
    try response.ok(ctx, entry);
}

pub fn updateLesson(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "lesson_id is required", 40021);
        return;
    };
    const parsed = try ctx.parseJsonBody(model.UpdateLessonRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry_ptr = mem_lessons.?.getPtr(id) orelse {
        try response.err(ctx, .not_found, "lesson not found", 40402);
        return;
    };
    if (req.title) |t| entry_ptr.title = try memDup(t);
    if (req.content) |c| entry_ptr.content = try memDup(c);
    if (req.quiz) |q| entry_ptr.quiz = try memDup(q);
    try response.ok(ctx, entry_ptr.*);
}

pub fn deleteLesson(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "lesson_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    _ = mem_lessons.?.fetchRemove(id) orelse {
        try response.err(ctx, .not_found, "lesson not found", 40402);
        return;
    };
    try response.okNoContent(ctx);
}

/// ── Enrollment ───────────────────────────────────────────────────

pub fn enrollUser(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.EnrollRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.user_id.len == 0 or req.course_id.len == 0) {
        try response.err(ctx, .bad_request, "user_id and course_id are required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    _ = mem_courses.?.get(req.course_id) orelse {
        try response.err(ctx, .not_found, "course not found", 40401);
        return;
    };

    const key = try enrollmentKey(req.user_id, req.course_id);
    if (mem_enrollments.?.contains(key)) {
        try response.err(ctx, .conflict, "user already enrolled", 40901);
        return;
    }

    const empty: []const []const u8 = try memAlloc().alloc([]const u8, 0);
    const entry = model.Enrollment{
        .user_id = try memDup(req.user_id),
        .course_id = try memDup(req.course_id),
        .status = try memDup("enrolled"),
        .completed_lessons = empty,
        .certificate_id = null,
        .created_at = try nowStr(),
    };
    try mem_enrollments.?.put(key, entry);
    ctx.res_status = .created;
    try response.ok(ctx, entry);
}

pub fn completeLesson(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.CompleteLessonRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.user_id.len == 0 or req.lesson_id.len == 0) {
        try response.err(ctx, .bad_request, "user_id and lesson_id are required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const lesson = mem_lessons.?.get(req.lesson_id) orelse {
        try response.err(ctx, .not_found, "lesson not found", 40402);
        return;
    };

    const key = try enrollmentKey(req.user_id, lesson.course_id);
    const entry_ptr = mem_enrollments.?.getPtr(key) orelse {
        try response.err(ctx, .not_found, "enrollment not found", 40403);
        return;
    };

    if (!containsStr(entry_ptr.completed_lessons, req.lesson_id)) {
        entry_ptr.completed_lessons = try appendStr(entry_ptr.completed_lessons, req.lesson_id);
    }

    if (std.mem.eql(u8, entry_ptr.status, "enrolled")) {
        entry_ptr.status = try memDup("in_progress");
    }

    try response.ok(ctx, entry_ptr.*);
}

pub fn completeCourse(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.CompleteCourseRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.user_id.len == 0 or req.course_id.len == 0) {
        try response.err(ctx, .bad_request, "user_id and course_id are required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const key = try enrollmentKey(req.user_id, req.course_id);
    const entry_ptr = mem_enrollments.?.getPtr(key) orelse {
        try response.err(ctx, .not_found, "enrollment not found", 40403);
        return;
    };

    if (std.mem.eql(u8, entry_ptr.status, "completed")) {
        try response.err(ctx, .conflict, "course already completed", 40902);
        return;
    }

    // Check all lessons in the course are completed
    var all_lesson_ids: std.ArrayList([]const u8) = .empty;
    defer all_lesson_ids.deinit(memAlloc());
    if (mem_lessons) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.course_id, req.course_id))
                try all_lesson_ids.append(memAlloc(), kv.value_ptr.id);
        }
    }

    if (all_lesson_ids.items.len == 0) {
        try response.err(ctx, .bad_request, "course has no lessons", 40023);
        return;
    }

    for (all_lesson_ids.items) |lid| {
        if (!containsStr(entry_ptr.completed_lessons, lid)) {
            try response.err(ctx, .bad_request, "not all lessons completed", 40024);
            return;
        }
    }

    // Award certificate
    const cert_id = try generateId("cert");
    entry_ptr.status = try memDup("completed");
    entry_ptr.certificate_id = try memDup(cert_id);

    try response.ok(ctx, .{ .enrollment = entry_ptr.*, .certificate_id = cert_id });
}

pub fn listEnrollments(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.Enrollment) = .empty;
    defer list.deinit(ctx.allocator);

    const filter_user_id = response.queryParam(ctx, "user_id");

    if (mem_enrollments) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (filter_user_id) |uid| {
                if (!std.mem.eql(u8, e.user_id, uid)) continue;
            }
            try list.append(ctx.allocator, e);
        }
    }
    try response.ok(ctx, .{ .enrollments = list.items, .total = list.items.len });
}
