//! Regression coverage for the workspace settings/repos JSON lifetime.
//!
//! `WorkspaceResponse.settings` / `.repos` are `std.json.Value` slices
//! that point INTO an arena owned by a `std.json.Parsed` held by the
//! caller. Two bugs lived here, both silent until the serializer walked
//! a non-empty slice and then segfaulted the whole process:
//!
//!   1. `defer` declared inside the row loop is BLOCK-scoped, so it freed
//!      the arena every iteration while the accumulated list still
//!      referenced it.
//!   2. A single holder pair shared across iterations gets overwritten by
//!      row N+1, freeing the arena row N's response still points into.
//!
//! Bug #2 only reproduces with more than one row, which is why these use
//! a two-row fixture rather than a single value.

const std = @import("std");
const testing = std.testing;
const model = @import("model.zig");

const Value = std.json.Value;
const Parsed = std.json.Parsed(Value);

// Pins the invariant both fixed call sites depend on: a value returned
// by parseJsonValue stays readable for as long as its own holder is
// alive, and parsing into a DIFFERENT holder doesn't disturb it. The
// shared-holder implementation freed the previous arena here, which is
// the mechanism behind bug #2.
test "parseJsonValue: two independent holders coexist" {
    const allocator = testing.allocator;

    var first: ?Parsed = null;
    defer if (first) |*p| p.deinit();
    var second: ?Parsed = null;
    defer if (second) |*p| p.deinit();

    const a = try model.parseJsonValue(
        allocator,
        "{\"marker\":\"alpha\",\"payload\":\"aaaaaaaaaaaaaaaaaaaaaaaa\"}",
        &first,
    );
    const b = try model.parseJsonValue(
        allocator,
        "{\"marker\":\"beta\",\"payload\":\"bbbbbbbbbbbbbbbbbbbbbbbb\"}",
        &second,
    );

    // Both still hold their OWN marker — not the other's, not garbage.
    try testing.expectEqualStrings("alpha", a.?.object.get("marker").?.string);
    try testing.expectEqualStrings("beta", b.?.object.get("marker").?.string);
}

// Serializing a value whose sibling holder was parsed afterwards must
// still produce the original content. Under the shared-holder bug the
// first row's arena was gone by the time renderJson ran, and this is
// where it read freed memory.
test "parseJsonValue: a value survives its sibling being parsed later" {
    const allocator = testing.allocator;

    // One holder per VALUE, not per row: parseJsonValue stores a single
    // Parsed and would clobber (and leak) the first if both settings and
    // repos shared a slot — which is why service.zig keeps two lists.
    var row0_settings: ?Parsed = null;
    defer if (row0_settings) |*p| p.deinit();
    var row0_repos: ?Parsed = null;
    defer if (row0_repos) |*p| p.deinit();
    var row1_settings: ?Parsed = null;
    defer if (row1_settings) |*p| p.deinit();
    var row1_repos: ?Parsed = null;
    defer if (row1_repos) |*p| p.deinit();

    const settings0 = try model.parseJsonValue(
        allocator,
        "{\"theme\":\"dark\",\"nested\":{\"a\":1}}",
        &row0_settings,
    );
    const repos0 = try model.parseJsonValue(
        allocator,
        "[{\"url\":\"https://github.com/a/one\",\"description\":\"first row repo\"}]",
        &row0_repos,
    );

    // Second row parses into its own holders — the buggy version shared
    // one holder across rows and freed it here.
    _ = try model.parseJsonValue(
        allocator,
        "{\"theme\":\"light\",\"nested\":{\"a\":9}}",
        &row1_settings,
    );
    _ = try model.parseJsonValue(
        allocator,
        "[{\"url\":\"https://github.com/b/two\"},{\"url\":\"https://github.com/c/three\"}]",
        &row1_repos,
    );

    // Round-trip row 0 through the serializer: this is the exact call
    // renderJson makes, and the exact place the segfault happened.
    const text = try std.json.Stringify.valueAlloc(allocator, repos0, .{});
    defer allocator.free(text);

    const back = try std.json.parseFromSlice(Value, allocator, text, .{});
    defer back.deinit();

    const arr = back.value.array;
    try testing.expectEqual(@as(usize, 1), arr.items.len);
    try testing.expectEqualStrings(
        "https://github.com/a/one",
        arr.items[0].object.get("url").?.string,
    );
    try testing.expectEqualStrings(
        "first row repo",
        arr.items[0].object.get("description").?.string,
    );

    // Row 0's settings must be intact too.
    try testing.expectEqualStrings(
        "dark",
        settings0.?.object.get("theme").?.string,
    );
}

// Null / empty inputs must leave the holder untouched so a caller can
// reuse the slot without leaking or double-freeing.
test "parseJsonValue: null and empty text leave the holder alone" {
    const allocator = testing.allocator;
    var holder: ?Parsed = null;
    defer if (holder) |*p| p.deinit();

    try testing.expectEqual(@as(?Value, null), try model.parseJsonValue(allocator, null, &holder));
    try testing.expectEqual(@as(?Value, null), try model.parseJsonValue(allocator, "", &holder));
    try testing.expect(holder == null);

    const v = try model.parseJsonValue(allocator, "{\"ok\":true}", &holder);
    try testing.expect(v != null);

    // A later null parse into a DIFFERENT slot must not disturb this one.
    var other: ?Parsed = null;
    defer if (other) |*p| p.deinit();
    try testing.expectEqual(@as(?Value, null), try model.parseJsonValue(allocator, null, &other));

    try testing.expect(v.?.object.get("ok").?.bool);
}

// Two rows, two holder pairs — the shape service.zig now uses. Asserts
// each row's JSON stays addressable and distinct right up to the point
// where the response is serialized.
test "parseJsonValue: per-row holders keep both rows addressable" {
    const allocator = testing.allocator;

    const settings_text = [_][]const u8{
        "{\"theme\":\"dark\",\"nested\":{\"a\":1,\"b\":[2,3]}}",
        "{\"theme\":\"light\",\"nested\":{\"a\":9,\"b\":[8,7]}}",
    };
    const repos_text = [_][]const u8{
        "[{\"url\":\"https://github.com/a/one\",\"description\":\"first row repo\"}]",
        "[{\"url\":\"https://github.com/b/two\"},{\"url\":\"https://github.com/c/three\"}]",
    };

    // `?Parsed` (not bare `Parsed`) — parseJsonValue takes `*?Parsed`, so
    // each slot must be an optional to match the callee's signature.
    var settings_holders: std.ArrayList(?Parsed) = .empty;
    defer {
        for (settings_holders.items) |*p| if (p.*) |*inner| inner.deinit();
        settings_holders.deinit(allocator);
    }
    var repos_holders: std.ArrayList(?Parsed) = .empty;
    defer {
        for (repos_holders.items) |*p| if (p.*) |*inner| inner.deinit();
        repos_holders.deinit(allocator);
    }

    const Borrowed = struct { settings: ?Value, repos: ?Value };
    var list: std.ArrayList(Borrowed) = .empty;
    defer list.deinit(allocator);

    for (settings_text, repos_text) |st, rt| {
        // `undefined` (not null) — ArrayList(Parsed) holds the Parsed by
        // value, so the slot needs a typed placeholder. parseJsonValue
        // overwrites it on the very next line.
        try settings_holders.append(allocator, undefined);
        try repos_holders.append(allocator, undefined);
        const last = settings_holders.items.len - 1;
        try list.append(allocator, .{
            .settings = try model.parseJsonValue(allocator, st, &settings_holders.items[last]),
            .repos = try model.parseJsonValue(allocator, rt, &repos_holders.items[last]),
        });
    }

    try testing.expectEqual(@as(usize, 2), list.items.len);

    // Row-specific sentinels prove we're reading row N's arena, not
    // row N+1's or freed memory that happens to look plausible.
    try testing.expectEqualStrings(
        "dark",
        list.items[0].settings.?.object.get("theme").?.string,
    );
    try testing.expectEqualStrings(
        "light",
        list.items[1].settings.?.object.get("theme").?.string,
    );
    try testing.expectEqual(
        @as(usize, 1),
        list.items[0].repos.?.array.items.len,
    );
    try testing.expectEqual(
        @as(usize, 2),
        list.items[1].repos.?.array.items.len,
    );

    // Finally serialize both, the way renderJson does after the loop.
    for (list.items) |entry| {
        const text = try std.json.Stringify.valueAlloc(allocator, entry.repos, .{});
        defer allocator.free(text);
        try testing.expect(text.len > 0);
    }
}
