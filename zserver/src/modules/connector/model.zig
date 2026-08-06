//! Connector module — data layer.
//!
//! No DB: the module keeps an in-memory store shared with `service.zig`.
//! Two data structs: `ConnectorConfig` for external API configurations
//! and `ApiCallLog` for recording simulated API calls.

const std = @import("std");
const zfinal = @import("zfinal");

/// Connector configuration for an external API integration.
pub const ConnectorConfig = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    base_url: []const u8,
    auth_type: AuthType,
    auth_value: []const u8,
    timeout_ms: u32,
    max_retries: u8,
};

/// Supported authentication types.
pub const AuthType = enum {
    none,
    bearer,
    api_key,
    basic,

    pub fn fromString(s: []const u8) ?AuthType {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "bearer")) return .bearer;
        if (std.mem.eql(u8, s, "api_key")) return .api_key;
        if (std.mem.eql(u8, s, "basic")) return .basic;
        return null;
    }

    pub fn toString(self: AuthType) []const u8 {
        return switch (self) {
            .none => "none",
            .bearer => "bearer",
            .api_key => "api_key",
            .basic => "basic",
        };
    }
};

/// Log entry for an API call made through a connector.
pub const ApiCallLog = struct {
    id: []const u8,
    config_id: []const u8,
    method: []const u8,
    path: []const u8,
    status_code: u16,
    duration_ms: u64,
    created_at: []const u8,
};

/// API response shape for a ConnectorConfig.
pub const ConnectorConfigResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    base_url: []const u8,
    auth_type: []const u8,
    timeout_ms: u32,
    max_retries: u8,
};

/// Convert a ConnectorConfig to a ConnectorConfigResponse.
pub fn configResponseFromConfig(cfg: ConnectorConfig) ConnectorConfigResponse {
    return ConnectorConfigResponse{
        .id = cfg.id,
        .workspace_id = cfg.workspace_id,
        .name = cfg.name,
        .base_url = cfg.base_url,
        .auth_type = cfg.auth_type.toString(),
        .timeout_ms = cfg.timeout_ms,
        .max_retries = cfg.max_retries,
    };
}

/// API response shape for an ApiCallLog.
pub const ApiCallLogResponse = struct {
    id: []const u8,
    config_id: []const u8,
    method: []const u8,
    path: []const u8,
    status_code: u16,
    duration_ms: u64,
    created_at: []const u8,
};

/// Convert an ApiCallLog to an ApiCallLogResponse.
pub fn logResponseFromLog(log: ApiCallLog) ApiCallLogResponse {
    return ApiCallLogResponse{
        .id = log.id,
        .config_id = log.config_id,
        .method = log.method,
        .path = log.path,
        .status_code = log.status_code,
        .duration_ms = log.duration_ms,
        .created_at = log.created_at,
    };
}

/// Generate a stable pseudo-UUID for the in-memory store.
pub fn generateId(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const ns = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    const payload = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ seed, ns });
    defer allocator.free(payload);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    const hex = try allocator.alloc(u8, 36);
    const charset = "0123456789abcdef";
    var o: usize = 0;
    for (hash[0..16], 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            hex[o] = '-';
            o += 1;
        }
        hex[o] = charset[b >> 4];
        hex[o + 1] = charset[b & 0x0f];
        o += 2;
    }
    return hex;
}
