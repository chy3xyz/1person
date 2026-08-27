//! Training module — data layer.
//!
//! Course(id, workspace_id, name, lessons[])
//! Lesson(id, course_id, title, content, quiz)
//! Enrollment(user_id, course_id, status, completed_lessons[], certificate_id)

const std = @import("std");

/// A training course belonging to a workspace.
pub const Course = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    created_at: []const u8,
};

/// A lesson within a course.
pub const Lesson = struct {
    id: []const u8,
    course_id: []const u8,
    title: []const u8,
    content: []const u8,
    quiz: ?[]const u8 = null,
};

/// Enrollment status enum values.
pub const EnrollmentStatus = enum {
    enrolled,
    in_progress,
    completed,
    failed,
};

/// Maps a user to a course, tracking progress.
pub const Enrollment = struct {
    user_id: []const u8,
    course_id: []const u8,
    status: []const u8,
    completed_lessons: []const []const u8,
    certificate_id: ?[]const u8 = null,
    created_at: []const u8,
};

/// JSON request shape for creating a course.
pub const CreateCourseRequest = struct {
    name: []const u8,
};

/// JSON request shape for updating a course.
pub const UpdateCourseRequest = struct {
    name: ?[]const u8 = null,
};

/// JSON request shape for creating a lesson.
pub const CreateLessonRequest = struct {
    title: []const u8,
    content: []const u8,
    quiz: ?[]const u8 = null,
};

/// JSON request shape for updating a lesson.
pub const UpdateLessonRequest = struct {
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
    quiz: ?[]const u8 = null,
};

/// JSON request shape for enrolling a user.
pub const EnrollRequest = struct {
    user_id: []const u8,
    course_id: []const u8,
};

/// JSON request shape for completing a lesson.
pub const CompleteLessonRequest = struct {
    user_id: []const u8,
    lesson_id: []const u8,
};

/// JSON request shape for completing a course.
pub const CompleteCourseRequest = struct {
    user_id: []const u8,
    course_id: []const u8,
};

/// Validate that course name is non-empty.
pub fn validateCourseName(name: []const u8) bool {
    return name.len > 0;
}

/// Validate that lesson title and content are non-empty.
pub fn validateLesson(title: []const u8, content: []const u8) bool {
    return title.len > 0 and content.len > 0;
}
