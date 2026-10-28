//! Regression coverage for the Lark installations listing.
//!
//! The endpoint used to answer with a bare JSON array while the client
//! reads an envelope (`{installations, configured, install_supported}`).
//! `listing.installations` was therefore `undefined` on the client and
//! `listing?.installations.find(...)` threw, dropping the whole agent
//! details page into its error boundary.
//!
//! The projection also invented a `tenant_name` column the
//! `lark_installation` table never had (so it was always empty) and
//! dropped the columns the client actually renders (`agent_id`,
//! `bot_open_id`, `installer_user_id`, `status`, `region`,
//! `installed_at`).
//!
//! These tests run against a live PostgreSQL and skip themselves when
//! `DATABASE_URL` is unset, so `zig build test` still works on a bare
//! checkout.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const service = @import("service.zig");

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

test "lark installation columns resolve against the live schema" {
    const db = (try testDb()) orelse return error.SkipZigTest;
    defer deps.releaseBack(db);

    // The exact column list the endpoint selects. A column that no
    // migration creates fails here with 42703 — that is exactly how the
    // invented `tenant_name` column would have been caught.
    var rs = try db.queryParams(
        "SELECT " ++ service.larkInstallationColumns ++
            " FROM lark_installation WHERE workspace_id = $1::uuid LIMIT 1",
        &[_]zfinal.SqlParam{.{ .text = "00000000-0000-0000-0000-000000000000" }},
    );
    defer rs.deinit();

    // An empty result is fine — the point is that the query runs at all.
}

test "lark installation projection carries every column the client renders" {
    const columns = service.larkInstallationColumns;

    const expected = [_][]const u8{
        "id",
        "workspace_id",
        "agent_id",
        "app_id",
        "tenant_key",
        "bot_open_id",
        "installer_user_id",
        "status",
        "region",
        "installed_at",
        "created_at",
        "updated_at",
    };
    for (expected) |column| {
        try std.testing.expect(std.mem.indexOf(u8, columns, column) != null);
    }

    // `tenant_name` is not a column of `lark_installation` and is not
    // part of the wire contract — it must not creep back in.
    try std.testing.expect(std.mem.indexOf(u8, columns, "tenant_name") == null);
}

test "lark installations list renders the client envelope, not a bare array" {
    const response = service.LarkInstallationsListResponse{
        .installations = &[_]model.LarkInstallationResponse{},
        .configured = false,
        .install_supported = false,
    };

    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, response, .{});
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    // A bare array is what crashed the agent details page.
    try std.testing.expect(parsed.value == .object);

    const obj = parsed.value.object;
    try std.testing.expect(obj.contains("installations"));
    try std.testing.expect(obj.contains("configured"));
    try std.testing.expect(obj.contains("install_supported"));
}

test "github installations list renders the client envelope, not a bare array" {
    const response = service.GithubInstallationsListResponse{
        .installations = &[_]model.GithubInstallationResponse{},
        .configured = false,
        .can_manage = false,
    };

    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, response, .{});
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);

    const obj = parsed.value.object;
    try std.testing.expect(obj.contains("installations"));
    try std.testing.expect(obj.contains("configured"));
    try std.testing.expect(obj.contains("can_manage"));
}

test "github installation projection uses the upstream field names" {
    const response = model.GithubInstallationResponse{
        .id = "row-1",
        .workspace_id = "ws-1",
        .installation_id = 4242,
        .account_login = "acme",
        .account_type = "Organization",
        .account_avatar_url = null,
        .created_at = "2026-01-01T00:00:00Z",
    };

    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, response, .{});
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    // The client reads these two; the module used to answer with
    // `account_url` / `repository_selection` instead.
    try std.testing.expect(obj.contains("account_type"));
    try std.testing.expect(obj.contains("account_avatar_url"));
    try std.testing.expect(!obj.contains("account_url"));
    try std.testing.expect(!obj.contains("repository_selection"));

    // `installation_id` is GitHub's numeric id and must be a JSON
    // number, not a string.
    try std.testing.expectEqual(@as(i64, 4242), parsed.value.object.get("installation_id").?.integer);
}

test "github installation columns resolve against the live schema" {
    const db = (try testDb()) orelse return error.SkipZigTest;
    defer deps.releaseBack(db);

    var rs = try db.queryParams(
        "SELECT id, workspace_id, installation_id, account_login, " ++
            "account_type, account_avatar_url, created_at " ++
            "FROM github_installation WHERE workspace_id = $1::uuid LIMIT 1",
        &[_]zfinal.SqlParam{.{ .text = "00000000-0000-0000-0000-000000000000" }},
    );
    defer rs.deinit();
}
