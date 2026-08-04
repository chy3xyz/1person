//! Standard JSON response shapes shared by every handler.
//!
//! Mirrors the helpers in `zfinal/examples/ruoyi-gen/src/common/response.zig`.
//! Adopt uniformly across `src/modules/<name>/handler.zig` so error /
//! success envelopes look the same to every client.

const std = @import("std");
const zfinal = @import("zfinal");

/// Send a uniform error response and set the HTTP status. Always
/// follows the shape `{"error": msg, "code": code}`. The caller is
/// expected to `return` immediately after.
pub fn err(ctx: *zfinal.Context, status: std.http.Status, msg: []const u8, code: i32) !void {
    ctx.res_status = status;
    try ctx.renderJson(.{ .@"error" = msg, .code = code });
}

/// Send a success response with a data payload under the `data` key.
/// Shape: `{"data": …}`. Use this for list / single-item / mutation
/// responses so the client can `body.data` uniformly.
pub fn ok(ctx: *zfinal.Context, data: anytype) !void {
    try ctx.renderJson(.{ .data = data });
}

/// Send a no-content success response (e.g. DELETE). Sets the status
/// to `.no_content` and renders `{}`.
pub fn okNoContent(ctx: *zfinal.Context) !void {
    ctx.res_status = .no_content;
    try ctx.renderJson(.{});
}

/// Parse an integer path parameter (`:id` etc.). On failure, writes a
/// 400 error envelope and returns an error the caller should propagate.
pub fn parseIntId(ctx: *zfinal.Context, param_name: []const u8) !i64 {
    const str = ctx.getPathParam(param_name) orelse {
        try err(ctx, .bad_request, "missing path parameter", 40001);
        return error.MissingPathParam;
    };
    const n = std.fmt.parseInt(i64, str, 10) catch {
        try err(ctx, .bad_request, "invalid path parameter", 40002);
        return error.InvalidPathParam;
    };
    return n;
}

/// Parse a UUID-style string path parameter (any opaque string).
/// Returns the borrowed slice; the caller does NOT need to free it.
pub fn parseStringId(ctx: *zfinal.Context, param_name: []const u8) ![]const u8 {
    var str = ctx.getPathParam(param_name) orelse {
        try err(ctx, .bad_request, "missing path parameter", 40001);
        return error.MissingPathParam;
    };
    // Some route patterns (/:id/timeline, /:id/comments/trigger-preview)
    // include trailing path chars in the extracted param.  Strip
    // everything from the first '/' onward.
    if (std.mem.indexOfScalar(u8, str, '/')) |pos| {
        str = str[0..pos];
    }
    if (str.len == 0) {
        try err(ctx, .bad_request, "invalid path parameter", 40002);
        return error.InvalidPathParam;
    }
    return str;
}

/// Read a `?key=…` query param. Returns `null` when missing or empty.
pub fn queryParam(ctx: *zfinal.Context, key: []const u8) ?[]const u8 {
    const v = ctx.getPara(key) catch return null;
    if (v) |s| {
        if (s.len == 0) return null;
        return s;
    }
    return null;
}

/// Read a required `?key=…` query param. On failure, writes a 400
/// error envelope and returns an error.
pub fn requireQuery(ctx: *zfinal.Context, key: []const u8) ![]const u8 {
    const v = queryParam(ctx, key) orelse {
        try err(ctx, .bad_request, "missing query parameter", 40003);
        return error.MissingQueryParam;
    };
    return v;
}

/// Convenience: `ctx.req_status = .ok; try ctx.renderJson(.{ … });`
pub fn render(ctx: *zfinal.Context, comptime shape: anytype) !void {
    try ctx.renderJson(shape);
}
