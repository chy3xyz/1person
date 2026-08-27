//! Training module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/training");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Course CRUD
    try api.get("/courses", handler.listCourses);
    try api.post("/courses", handler.createCourse);
    try api.get("/courses/:id", handler.getCourse);
    try api.put("/courses/:id", handler.updateCourse);
    try api.delete("/courses/:id", handler.deleteCourse);

    // Lesson CRUD (scoped under course)
    try api.get("/courses/:id/lessons", handler.listLessons);
    try api.post("/courses/:id/lessons", handler.createLesson);
    try api.get("/lessons/:id", handler.getLesson);
    try api.put("/lessons/:id", handler.updateLesson);
    try api.delete("/lessons/:id", handler.deleteLesson);

    // Enrollment
    try api.post("/enroll", handler.enrollUser);
    try api.post("/complete-lesson", handler.completeLesson);
    try api.post("/complete-course", handler.completeCourse);
    try api.get("/enrollments", handler.listEnrollments);
}
