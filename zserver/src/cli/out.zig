//! CLI output + stdin helpers (plain fd writes, no Io plumbing needed).

const std = @import("std");

/// Print to stdout (fd 1), best-effort.
pub fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(std.posix.STDOUT_FILENO, s.ptr, s.len);
}

/// Print to stderr (fd 2), best-effort.
pub fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(std.posix.STDERR_FILENO, s.ptr, s.len);
}

/// Read one line from stdin (fd 0) into buf; strips trailing newline.
/// Returns the used slice. Empty on EOF.
pub fn readLine(buf: []u8) []const u8 {
    var used: usize = 0;
    while (used < buf.len) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[used .. used + 1]) catch break;
        if (n == 0) break;
        if (buf[used] == '\n') break;
        used += 1;
    }
    if (used > 0 and buf[used - 1] == '\r') used -= 1;
    return buf[0..used];
}

/// Prompt on stderr and read a line from stdin.
pub fn prompt(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    printErr(fmt, args);
    return readLine(buf);
}
