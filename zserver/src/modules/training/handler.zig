//! Training module — thin HTTP delegates.

const zfinal = @import("zfinal");
const service = @import("service.zig");

// ── Course CRUD ────────────────────────────────────────────────
pub fn listCourses(ctx: *zfinal.Context) !void {
    try service.listCourses(ctx);
}

pub fn createCourse(ctx: *zfinal.Context) !void {
    try service.createCourse(ctx);
}

pub fn getCourse(ctx: *zfinal.Context) !void {
    try service.getCourse(ctx);
}

pub fn updateCourse(ctx: *zfinal.Context) !void {
    try service.updateCourse(ctx);
}

pub fn deleteCourse(ctx: *zfinal.Context) !void {
    try service.deleteCourse(ctx);
}

// ── Lesson CRUD ────────────────────────────────────────────────
pub fn listLessons(ctx: *zfinal.Context) !void {
    try service.listLessons(ctx);
}

pub fn createLesson(ctx: *zfinal.Context) !void {
    try service.createLesson(ctx);
}

pub fn getLesson(ctx: *zfinal.Context) !void {
    try service.getLesson(ctx);
}

pub fn updateLesson(ctx: *zfinal.Context) !void {
    try service.updateLesson(ctx);
}

pub fn deleteLesson(ctx: *zfinal.Context) !void {
    try service.deleteLesson(ctx);
}

// ── Enrollment ─────────────────────────────────────────────────
pub fn enrollUser(ctx: *zfinal.Context) !void {
    try service.enrollUser(ctx);
}

pub fn completeLesson(ctx: *zfinal.Context) !void {
    try service.completeLesson(ctx);
}

pub fn completeCourse(ctx: *zfinal.Context) !void {
    try service.completeCourse(ctx);
}

pub fn listEnrollments(ctx: *zfinal.Context) !void {
    try service.listEnrollments(ctx);
}
