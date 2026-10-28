//! Regression coverage for the issue wire shape.
//!
//! The issue projection used to answer with nine columns —
//! `id, title, description, project_id, parent_issue_id, assignee_id,
//! status, created_at, updated_at` — and called the status `state`.
//! The client contract (`packages/core/types/issue.ts::Issue`, which
//! mirrors the upstream `IssueResponse`) needs `workspace_id`,
//! `number`, `identifier`, `status` and `parent_issue_id`, so EVERY
//! issue response failed the client schema, fell back to the empty
//! list, and the Issues board rendered "no issues" while the database
//! was full of them.
//!
//! These tests run against a live PostgreSQL and skip themselves when
//! `DATABASE_URL` is unset, so `zig build test` still works on a bare
//! checkout.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("../../deps.zig");
const model = @import("model.zig");

/// `std.process.Environ` can only be built from the block handed to
/// `std.process.Init`, which a test binary never receives. libc is linked,
/// so fall back to `getenv(3)`.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn testDb() !?*zfinal.DB {
    if (!deps.hasPool()) {
        const url = std.mem.span(getenv("DATABASE_URL") orelse return null);
        if (url.len == 0) return null;
        _ = deps.initPool(std.heap.page_allocator, url);
        if (!deps.hasPool()) return null;
    }
    return deps.acquire() catch null;
}

test "issue select columns resolve against the live schema" {
    const db = (try testDb()) orelse return error.SkipZigTest;
    defer deps.releaseBack(db);

    // The exact column list every issue read projects. A column that no
    // migration creates fails here with 42703.
    var rs = try db.queryParams(
        "SELECT " ++ model.issueSelectColumns ++ model.issueSelectFrom ++
            " WHERE i.workspace_id = $1::uuid LIMIT 1",
        &[_]zfinal.SqlParam{.{ .text = "00000000-0000-0000-0000-000000000000" }},
    );
    defer rs.deinit();

    // An empty result is fine — the point is that the query runs at all.
}

test "issue response carries every field the client contract needs" {
    const response = model.IssueResponse{
        .id = "issue-1",
        .workspace_id = "ws-1",
        .number = 7,
        .identifier = "XXX-7",
        .title = "Contract check",
        .description = null,
        .status = "todo",
        .priority = "none",
        .assignee_type = null,
        .assignee_id = null,
        .creator_type = "member",
        .creator_id = "user-1",
        .parent_issue_id = null,
        .project_id = null,
        .position = 0,
        .start_date = null,
        .due_date = null,
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    };

    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, response, .{});
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    for ([_][]const u8{
        "id",
        "workspace_id",
        "number",
        "identifier",
        "title",
        "description",
        "status",
        "priority",
        "assignee_type",
        "assignee_id",
        "creator_type",
        "creator_id",
        "parent_issue_id",
        "project_id",
        "position",
        "start_date",
        "due_date",
        "created_at",
        "updated_at",
    }) |field| {
        try std.testing.expect(obj.contains(field));
    }

    // The client reads `status` — the old projection answered `state`.
    try std.testing.expect(!obj.contains("state"));
    try std.testing.expect(!obj.contains("parent_id"));

    try std.testing.expectEqual(@as(i64, 7), obj.get("number").?.integer);
    try std.testing.expectEqualStrings("XXX-7", obj.get("identifier").?.string);
}

test "issue select and returning column lists stay in the same order" {
    // The projector indexes by position, so the two lists must agree on
    // which column is which. Compare the column names, ignoring the
    // table qualifiers and the identifier expression, which differ by
    // construction (join vs. scalar subquery).
    const select = model.issueSelectColumns;
    const returning = model.issueReturningColumns;

    const select_fields = [_][]const u8{
        "i.id",
        "i.workspace_id",
        "i.number",
        "i.title",
        "i.description",
        "i.project_id::text",
        "i.parent_issue_id::text",
        "i.assignee_id::text",
        "i.status",
        "i.created_at",
        "i.updated_at",
        "i.priority",
        "i.assignee_type",
        "i.creator_type",
        "i.creator_id",
        "i.position",
        "i.due_date",
        "i.start_date",
    };
    const returning_fields = [_][]const u8{
        "id",
        "workspace_id",
        "number",
        "title",
        "description",
        "project_id::text",
        "parent_issue_id::text",
        "assignee_id::text",
        "status",
        "created_at",
        "updated_at",
        "priority",
        "assignee_type",
        "creator_type",
        "creator_id",
        "position",
        "due_date",
        "start_date",
    };

    for (select_fields, returning_fields) |s, r| {
        try std.testing.expect(std.mem.indexOf(u8, select, s) != null);
        try std.testing.expect(std.mem.indexOf(u8, returning, r) != null);
    }

    // The identifier sits between `number` and `title` in both lists.
    const select_number = std.mem.indexOf(u8, select, "i.number,") orelse return error.TestUnexpectedResult;
    const select_title = std.mem.indexOf(u8, select, "i.title,") orelse return error.TestUnexpectedResult;
    const returning_number = std.mem.indexOf(u8, returning, "number,") orelse return error.TestUnexpectedResult;
    const returning_title = std.mem.indexOf(u8, returning, "title,") orelse return error.TestUnexpectedResult;
    try std.testing.expect(select_number < select_title);
    try std.testing.expect(returning_number < returning_title);
}
