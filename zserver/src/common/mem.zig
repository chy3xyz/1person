//! Shared in-memory storage helpers, extracted from the per-module
//! copies that used to live in every service/model.zig. Import these
//! instead of re-declaring `memAlloc`/`memDup`/`nowString`/`generateId`
//! in new modules.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("../deps.zig");

/// Page allocator used by all in-memory (no-DB fallback) state.
pub fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// Duplicate a string into the shared page allocator.
pub fn memDup(text: []const u8) ![]const u8 {
    return memAlloc().dupe(u8, text);
}

/// Seconds since epoch as a decimal string (the legacy in-memory
/// timestamp format).
pub fn nowString() ![]const u8 {
    const secs = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return std.fmt.allocPrint(memAlloc(), "{d}", .{secs});
}

/// `"<prefix>-<epoch-seconds>"` id generator. NOTE: some modules use a
/// sha256-based `generateId` — do NOT replace those with this one.
pub fn generateId(prefix: []const u8) ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return std.fmt.allocPrint(memAlloc(), "{s}-{d}", .{ prefix, ts });
}

/// Borrow a pooled DB connection, or `null` when the pool is down
/// (no-DB mode). The caller must `deps.releaseBack(db)`.
pub fn borrowDb() ?*zfinal.DB {
    return deps.acquire() catch null;
}
