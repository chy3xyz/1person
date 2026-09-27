//! Thin JSON-over-HTTP client for the CLI, wrapping zfinal.HttpClient.
//!
//! Every call returns the parsed response JSON plus the HTTP status; the
//! caller owns the returned heap allocations (call resp.deinit()).

const std = @import("std");
const zfinal = @import("zfinal");
const out = @import("out.zig");
const tls_error = @import("tls_error.zig");

pub const Response = struct {
    status: u16,
    // Owns the parsed JSON (all nested allocations) — deinit frees it all,
    // so no leaky Value juggling.
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Response) void {
        self.parsed.deinit();
    }

    /// Extract a top-level string field, or null.
    pub fn getString(self: *const Response, key: []const u8) ?[]const u8 {
        const root = self.parsed.value;
        if (root != .object) return null;
        const v = root.object.get(key) orelse return null;
        if (v != .string) return null;
        return v.string;
    }

    pub fn ok(self: *const Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

pub const Client = struct {
    http: zfinal.HttpClient,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) !Client {
        return .{ .http = try zfinal.HttpClient.init(allocator, base_url) };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    /// POST a JSON body, optionally with a Bearer token, and parse the response.
    pub fn postJson(self: *Client, allocator: std.mem.Allocator, path: []const u8, body: []const u8, token: ?[]const u8) !Response {
        var headers_buf: [2]std.http.Header = undefined;
        headers_buf[0] = .{ .name = "content-type", .value = "application/json" };
        var headers: []std.http.Header = headers_buf[0..1];
        // Hoisted out of the if-block: a defer inside the block would free
        // the bearer before requestWith reads the header (function-scope
        // defer, not block-scope, is required).
        var bearer: []const u8 = "";
        if (token) |t| {
            bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{t});
            headers_buf[1] = .{ .name = "authorization", .value = bearer };
            headers = headers_buf[0..2];
        }
        defer if (bearer.len > 0) allocator.free(bearer);
        var resp = self.http.requestWith(.POST, path, body, headers) catch |err| {
            out.printErr("request failed: {s}\n", .{@errorName(err)});
            return error.RequestFailed;
        };
        defer resp.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch |err| {
            out.printErr("response is not JSON ({s}): {s}\n", .{ @errorName(err), resp.body });
            return error.InvalidJson;
        };
        return .{ .status = resp.status, .parsed = parsed };
    }

    /// GET with a Bearer token and an optional X-Workspace-ID header.
    pub fn getJson(self: *Client, allocator: std.mem.Allocator, path: []const u8, token: []const u8, workspace_id: ?[]const u8) !Response {
        var headers_buf: [2]std.http.Header = undefined;
        var headers: []std.http.Header = &[_]std.http.Header{};
        if (workspace_id) |ws| {
            headers_buf[0] = .{ .name = "x-workspace-id", .value = ws };
            headers = headers_buf[0..1];
        }
        var bearer: []const u8 = "";
        if (token.len > 0) {
            bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
            if (headers.len > 0) {
                headers_buf[1] = .{ .name = "authorization", .value = bearer };
                headers = headers_buf[0..2];
            } else {
                headers_buf[0] = .{ .name = "authorization", .value = bearer };
                headers = headers_buf[0..1];
            }
        }
        defer if (bearer.len > 0) allocator.free(bearer);
        var resp = self.http.requestWith(.GET, path, null, headers) catch |err| {
            out.printErr("request failed: {s}\n", .{@errorName(err)});
            return error.RequestFailed;
        };
        defer resp.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch |err| {
            out.printErr("response is not JSON ({s}): {s}\n", .{ @errorName(err), resp.body });
            return error.InvalidJson;
        };
        return .{ .status = resp.status, .parsed = parsed };
    }

    /// Raw GET (no JSON parse) — used for self-update downloads. Caller owns
    /// the returned slice (allocator.free). Errors on non-2xx.
    pub fn getRaw(self: *Client, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        var resp = self.http.requestWith(.GET, path, null, &.{}) catch |err| {
            // PATCH (MUL-7466): classify the underlying std.crypto.tls / std.Io
            // fault into something a self-host sysadmin can act on. Without
            // this, a missing private CA surface as "request failed:
            // CertificateIssuerMismatch" with no hint about where the CA bundle
            // is mounted. Parse the host out of base_url for the message;
            // a parser failure falls back to "?" rather than crashing.
            var buf: [512]u8 = undefined;
            const host = extractHost(self.http.base_url) orelse "?";
            out.printErr("request failed: {s}\n", .{tls_error.describeTransportError(err, host, &buf)});
            return error.RequestFailed;
        };
        defer resp.deinit();
        if (resp.status < 200 or resp.status >= 300) return error.HttpStatus;
        return allocator.dupe(u8, resp.body);
    }
};

/// Strip the URL down to its `host[:port]` substring. Tolerates both bare
/// host inputs and the `http://host:port` / `https://host` forms we pass
/// to `Client.init`. Returns `null` if the input is empty (defensive — the
/// printer in `describeTransportError` falls back to "?" anyway).
fn extractHost(url: []const u8) ?[]const u8 {
    if (url.len == 0) return null;
    var s = url;
    // Strip scheme.
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    // Stop at the first path separator or query.
    if (std.mem.indexOfAny(u8, s, "/?")) |i| return s[0..i];
    return s;
}
