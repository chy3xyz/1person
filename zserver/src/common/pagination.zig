//! Pagination helpers shared by every handler.
//!
//! Mirrors the helpers in `zfinal/examples/ruoyi-gen/src/common/pagination.zig`.
//! Parses `?page=`, `?size=` (clamped to a max), and the
//! `?since_seq=` cursor used by the inbox replay endpoint.

const std = @import("std");
const zfinal = @import("zfinal");
const response = @import("response.zig");

pub const DEFAULT_PAGE: u32 = 1;
pub const DEFAULT_SIZE: u32 = 20;
pub const MAX_SIZE: u32 = 200;
pub const DEFAULT_SINCE_SEQ: u64 = 0;

/// Parse `?page=`. Defaults to 1. Returns 1 for non-positive or
/// malformed values. 400 envelope is sent for explicitly invalid input.
pub fn parsePage(ctx: *zfinal.Context) !u32 {
    const raw = (try ctx.getPara("page")) orelse return DEFAULT_PAGE;
    if (raw.len == 0) return DEFAULT_PAGE;
    const n = std.fmt.parseInt(u32, raw, 10) catch {
        try response.err(ctx, .bad_request, "invalid page", 40010);
        return error.InvalidPage;
    };
    if (n == 0) return DEFAULT_PAGE;
    return n;
}

/// Parse `?size=`. Defaults to 20, clamped to `MAX_SIZE`.
pub fn parseSize(ctx: *zfinal.Context) !u32 {
    const raw = (try ctx.getPara("size")) orelse return DEFAULT_SIZE;
    if (raw.len == 0) return DEFAULT_SIZE;
    const n = std.fmt.parseInt(u32, raw, 10) catch {
        try response.err(ctx, .bad_request, "invalid size", 40011);
        return error.InvalidSize;
    };
    if (n == 0) return DEFAULT_SIZE;
    return @min(n, MAX_SIZE);
}

/// Parse `?since_seq=`. Defaults to 0. Used by `listInboxSince`.
pub fn parseSinceSeq(ctx: *zfinal.Context) !u64 {
    const raw = (try ctx.getPara("since_seq")) orelse return DEFAULT_SINCE_SEQ;
    if (raw.len == 0) return DEFAULT_SINCE_SEQ;
    return std.fmt.parseInt(u64, raw, 10) catch {
        try response.err(ctx, .bad_request, "invalid since_seq", 40012);
        return error.InvalidSinceSeq;
    };
}

/// Parse both `page` and `size` in one shot. Returns `(page, size)`.
pub fn parse(ctx: *zfinal.Context) !struct { page: u32, size: u32 } {
    return .{ .page = try parsePage(ctx), .size = try parseSize(ctx) };
}
