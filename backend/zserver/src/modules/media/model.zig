//! Media module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (in-memory row shape, request/response DTOs).
//! `service.zig` wraps this with the business logic and the in-memory
//! media store.
//!
//! This module is no-DB only: all storage is in-memory.

const std = @import("std");
const zfinal = @import("zfinal");
const deps = @import("../../deps.zig");
const common_mem = @import("../../common/mem.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
    }

/// Page allocator used by the in-memory store.
pub fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// In-memory `media_asset` row.
pub const MediaAsset = struct {
    id: []const u8,
    workspace_id: []const u8,
    filename: []const u8,
    mime_type: []const u8,
    size_bytes: i64,
    url: []const u8,
    caption: []const u8,
    created_at: []const u8,
};

/// Public API response shape for a media asset.
pub const MediaAssetResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    filename: []const u8,
    mime_type: []const u8,
    size_bytes: i64,
    url: []const u8,
    caption: []const u8,
    created_at: []const u8,
};

/// Convert an in-memory entry to the API response shape.
pub fn responseFromAsset(asset: MediaAsset) MediaAssetResponse {
    return MediaAssetResponse{
        .id = asset.id,
        .workspace_id = asset.workspace_id,
        .filename = asset.filename,
        .mime_type = asset.mime_type,
        .size_bytes = asset.size_bytes,
        .url = asset.url,
        .caption = asset.caption,
        .created_at = asset.created_at,
    };
}

/// Upload request body shape. `filename` is required; all other fields
/// are optional.
pub const UploadRequest = struct {
    filename: []const u8,
    mime_type: []const u8 = "application/octet-stream",
    size_bytes: i64 = 0,
    caption: []const u8 = "",
};
