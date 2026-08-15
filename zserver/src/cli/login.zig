//! 1p login: email verification-code login against the server, then store
//! the session token in the config file.

const std = @import("std");
const api = @import("api.zig");
const config_store = @import("config_store.zig");
const out = @import("out.zig");

pub const LoginOptions = struct {
    server_url: ?[]const u8 = null,
    email: ?[]const u8 = null,
    code: ?[]const u8 = null,
    path: []const u8,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, opts: LoginOptions) !void {
    var cfg = try config_store.load(allocator, io, opts.path);
    defer cfg.deinit();

    const server_url = opts.server_url orelse if (cfg.server_url.len > 0) cfg.server_url else "http://localhost:8080";

    var email_buf: [256]u8 = undefined;
    var code_buf: [32]u8 = undefined;
    const email = if (opts.email) |e| e else out.prompt(&email_buf, "Email: ", .{});
    if (email.len == 0) {
        out.printErr("email is required\n", .{});
        return error.EmailRequired;
    }
    const code = if (opts.code) |c| c else out.prompt(&code_buf, "Verification code: ", .{});
    if (code.len == 0) {
        out.printErr("code is required\n", .{});
        return error.CodeRequired;
    }

    var client = try api.Client.init(allocator, server_url);
    defer client.deinit();

    // 1. send-code
    const send_body = try std.fmt.allocPrint(allocator, "{{\"email\":\"{s}\"}}", .{email});
    defer allocator.free(send_body);
    var send_resp = try client.postJson(allocator, "/auth/send-code", send_body, null);
    defer send_resp.deinit();
    if (!send_resp.ok()) {
        out.printErr("send-code failed (HTTP {d}): {s}\n", .{ send_resp.status, send_resp.getString("error") orelse send_resp.getString("msg") orelse "unknown" });
        return error.SendCodeFailed;
    }

    // 2. verify-code
    const verify_body = try std.fmt.allocPrint(allocator, "{{\"email\":\"{s}\",\"code\":\"{s}\"}}", .{ email, code });
    defer allocator.free(verify_body);
    var verify_resp = try client.postJson(allocator, "/auth/verify-code", verify_body, null);
    defer verify_resp.deinit();
    if (!verify_resp.ok()) {
        out.printErr("verify-code failed (HTTP {d}): {s}\n", .{ verify_resp.status, verify_resp.getString("error") orelse "unknown" });
        return error.VerifyFailed;
    }
    const token = verify_resp.getString("token") orelse {
        out.printErr("verify-code response missing token\n", .{});
        return error.VerifyFailed;
    };

    // 3. persist
    const alloc = cfg.daemon_tokens.allocator;
    alloc.free(cfg.server_url);
    cfg.server_url = try alloc.dupe(u8, server_url);
    alloc.free(cfg.token);
    cfg.token = try alloc.dupe(u8, token);

    try config_store.save(allocator, io, opts.path, &cfg);
    out.printOut("logged in as {s} (server: {s}, config: {s})\n", .{ email, server_url, opts.path });
}
