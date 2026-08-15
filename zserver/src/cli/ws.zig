//! Minimal RFC 6455 WebSocket client for the 1p CLI daemon loop.
//!
//! Covers exactly what the daemon needs: HTTP upgrade handshake with a
//! Bearer token, masked client frames, unmasked server frame reads,
//! ping/pong, and close. zfinal's WebSocket is server-side (never masks
//! outgoing frames), so this client is independent of it.

const std = @import("std");

pub const OpCode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const Frame = struct {
    fin: bool,
    opcode: OpCode,
    payload: []const u8,
};

pub const Error = error{
    HandshakeFailed,
    BadStatus,
    BadAcceptKey,
    ConnectionClosed,
    ProtocolError,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
    TimedOut,
};

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// A connected (post-handshake) WebSocket client. Call deinit() when done.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    closed: bool = false,
    /// Bytes left over from the handshake read (server frames can arrive
    /// glued to the 101 response head). Frame reads drain this first.
    pending: [8192]u8 = undefined,
    pending_len: usize = 0,

    /// Connect and perform the upgrade handshake.
    pub fn connect(allocator: std.mem.Allocator, io: std.Io, host: []const u8, port: u16, path: []const u8, token: []const u8) Error!Client {
        const addr = std.Io.net.IpAddress.parse(host, port) catch return error.HandshakeFailed;
        const stream = addr.connect(io, .{ .mode = .stream }) catch return error.HandshakeFailed;
        errdefer stream.close(io);

        var self = Client{ .allocator = allocator, .io = io, .stream = stream };

        // Sec-WebSocket-Key: base64(16 random bytes)
        var key_bytes: [16]u8 = undefined;
        self.io.randomSecure(&key_bytes) catch return error.HandshakeFailed;
        const key_b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(16));
        defer allocator.free(key_b64);
        _ = std.base64.standard.Encoder.encode(key_b64, &key_bytes);

        const req = try std.fmt.allocPrint(allocator,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}:{d}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "Authorization: Bearer {s}\r\n" ++
                "\r\n",
            .{ path, host, port, key_b64, token },
        );
        defer allocator.free(req);
        try self.writeAll(req);

        // Read response head (until CRLFCRLF), then validate.
        var resp_buf: [8192]u8 = undefined;
        var resp_len: usize = 0;
        while (resp_len < resp_buf.len) {
            var slices = [_][]u8{resp_buf[resp_len..]};
            const n = self.stream.read(self.io, &slices) catch return error.HandshakeFailed;
            if (n == 0) return error.HandshakeFailed;
            resp_len += n;
            if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n") != null) break;
        }
        const head = resp_buf[0..resp_len];
        if (std.mem.indexOf(u8, head, "101") == null) return error.BadStatus;
        const accept_header = findHeader(head, "sec-websocket-accept") orelse return error.HandshakeFailed;

        // Anything after the CRLFCRLF terminator is the start of the
        // WebSocket stream (the server greeting is typically glued to the
        // 101 head) — buffer it so frame reads don't lose it.
        if (std.mem.indexOf(u8, head, "\r\n\r\n")) |term| {
            const leftover = head[term + 4 ..];
            if (leftover.len > 0) {
                const take = @min(leftover.len, self.pending.len);
                @memcpy(self.pending[0..take], leftover[0..take]);
                self.pending_len = take;
            }
        }

        // Expected accept = base64(sha1(key + GUID))
        var sha: [20]u8 = undefined;
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(key_b64);
        hasher.update(WS_GUID);
        hasher.final(&sha);
        const expected = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(sha.len));
        defer allocator.free(expected);
        _ = std.base64.standard.Encoder.encode(expected, &sha);

        if (!std.mem.eql(u8, std.mem.trim(u8, accept_header, &std.ascii.whitespace), expected)) return error.BadAcceptKey;

        return self;
    }

    pub fn deinit(self: *Client) void {
        if (!self.closed) self.stream.close(self.io);
        self.closed = true;
    }

    /// Send a text frame (masked, as required for clients).
    pub fn sendText(self: *Client, text: []const u8) Error!void {
        try self.writeFrame(.text, text);
    }

    /// Send a ping frame.
    pub fn sendPing(self: *Client, payload: []const u8) Error!void {
        try self.writeFrame(.ping, payload);
    }

    /// Send a pong frame (reply to a server ping).
    pub fn sendPong(self: *Client, payload: []const u8) Error!void {
        try self.writeFrame(.pong, payload);
    }

    /// Send a close frame.
    pub fn sendClose(self: *Client) void {
        self.writeFrame(.close, &.{}) catch {};
    }

    /// Send an unmasked-marker-free masked frame.
    fn writeFrame(self: *Client, opcode: OpCode, payload: []const u8) Error!void {
        var mask: [4]u8 = undefined;
        self.io.randomSecure(&mask) catch return error.WriteFailed;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        const b1: u8 = 0x80 | @as(u8, @intCast(@intFromEnum(opcode)));
        out.append(self.allocator, b1) catch return error.WriteFailed;

        const len = payload.len;
        if (len < 126) {
            out.append(self.allocator, 0x80 | @as(u8, @intCast(len))) catch return error.WriteFailed;
        } else if (len < 65536) {
            out.append(self.allocator, 0x80 | 126) catch return error.WriteFailed;
            const n: u16 = @intCast(len);
            out.append(self.allocator, @intCast(n >> 8)) catch return error.WriteFailed;
            out.append(self.allocator, @intCast(n & 0xFF)) catch return error.WriteFailed;
        } else {
            out.append(self.allocator, 0x80 | 127) catch return error.WriteFailed;
            const n: u64 = len;
            var i: u6 = 56;
            while (true) {
                out.append(self.allocator, @intCast((n >> i) & 0xFF)) catch return error.WriteFailed;
                if (i == 0) break;
                i -= 8;
            }
        }
        out.appendSlice(self.allocator, &mask) catch return error.WriteFailed;
        for (payload, 0..) |byte, i| {
            out.append(self.allocator, byte ^ mask[i % 4]) catch return error.WriteFailed;
        }
        try self.writeAll(out.items);
    }

    /// Read one frame from the server (server frames are unmasked).
    pub fn readFrame(self: *Client, buf: []u8) Error!Frame {
        var header: [2]u8 = undefined;
        try self.readExact(&header);
        const fin = (header[0] & 0x80) != 0;
        const opcode: OpCode = @enumFromInt(header[0] & 0x0F);
        const masked = (header[1] & 0x80) != 0;
        if (masked) return error.ProtocolError; // server frames are unmasked
        var len: u64 = header[1] & 0x7F;
        if (len == 126) {
            var ext: [2]u8 = undefined;
            try self.readExact(&ext);
            len = (@as(u64, ext[0]) << 8) | ext[1];
        } else if (len == 127) {
            var ext: [8]u8 = undefined;
            try self.readExact(&ext);
            len = std.mem.readInt(u64, &ext, .big);
        }
        if (len > buf.len) return error.ProtocolError;
        try self.readExact(buf[0..@intCast(len)]);
        return .{ .fin = fin, .opcode = opcode, .payload = buf[0..@intCast(len)] };
    }

    fn writeAll(self: *Client, data: []const u8) Error!void {
        var wbuf: [8192]u8 = undefined;
        var w = self.stream.writer(self.io, &wbuf);
        w.interface.writeAll(data) catch return error.WriteFailed;
        w.interface.flush() catch return error.WriteFailed;
    }

    fn drainPending(self: *Client, buf: []u8) usize {
        if (self.pending_len == 0) return 0;
        const take = @min(self.pending_len, buf.len);
        @memcpy(buf[0..take], self.pending[0..take]);
        const rem = self.pending_len - take;
        if (rem > 0) std.mem.copyForwards(u8, self.pending[0..rem], self.pending[take..self.pending_len]);
        self.pending_len = rem;
        return take;
    }

    fn readExact(self: *Client, buf: []u8) Error!void {
        var off = self.drainPending(buf);
        while (off < buf.len) {
            var slices = [_][]u8{buf[off..]};
            const n = self.stream.read(self.io, &slices) catch return error.ReadFailed;
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
    }

    fn readExactTimeout(self: *Client, buf: []u8, timeout_ms: i64) Error!void {
        var off = self.drainPending(buf);
        while (off < buf.len) {
            var slices = [_][]u8{buf[off..]};
            const res = self.io.operateTimeout(
                .{ .net_read = .{ .socket_handle = self.stream.socket.handle, .data = &slices } },
                .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .real } },
            ) catch |err| switch (err) {
                error.Timeout => return error.TimedOut,
                else => return error.ReadFailed,
            };
            const n = res.net_read catch return error.ReadFailed;
            if (n == 0) return error.ConnectionClosed;
            off += n;
        }
    }

    /// Read one frame with a per-read timeout. Returns null when nothing
    /// arrives within the window (poll-style); partial reads that stall
    /// mid-frame surface as a timeout error (caller reconnects).
    pub fn readFrameTimeout(self: *Client, buf: []u8, timeout_ms: i64) Error!?Frame {
        var header: [2]u8 = undefined;
        self.readExactTimeout(&header, timeout_ms) catch |err| switch (err) {
            error.TimedOut => return null,
            else => return err,
        };
        const fin = (header[0] & 0x80) != 0;
        const opcode: OpCode = @enumFromInt(header[0] & 0x0F);
        const masked = (header[1] & 0x80) != 0;
        if (masked) return error.ProtocolError;
        var len: u64 = header[1] & 0x7F;
        if (len == 126) {
            var ext: [2]u8 = undefined;
            try self.readExactTimeout(&ext, timeout_ms);
            len = (@as(u64, ext[0]) << 8) | ext[1];
        } else if (len == 127) {
            var ext: [8]u8 = undefined;
            try self.readExactTimeout(&ext, timeout_ms);
            len = std.mem.readInt(u64, &ext, .big);
        }
        if (len > buf.len) return error.ProtocolError;
        try self.readExactTimeout(buf[0..@intCast(len)], timeout_ms);
        return .{ .fin = fin, .opcode = opcode, .payload = buf[0..@intCast(len)] };
    }
};

/// Case-insensitive header lookup in an HTTP response head.
fn findHeader(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(hname, name)) return std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
    }
    return null;
}

test "findHeader is case-insensitive" {
    const head = "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: abc\r\n\r\n";
    try std.testing.expectEqualStrings("abc", findHeader(head, "sec-websocket-accept").?);
}
