//! Narrow error sets and diagnostics for zcli.

const std = @import("std");

pub const ParseError = error{
    UnknownFlag,
    MissingFlagValue,
    InvalidFlagValue,
    MissingPositionalArg,
    TooManyPositionalArgs,
    UnknownCommand,
    DuplicateFlag,
    OutOfMemory,
};

pub const Diagnostic = struct {
    err: ParseError,
    flag: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    got: ?[]const u8 = null,

    pub fn init(err: ParseError) Diagnostic {
        return .{ .err = err };
    }

    pub fn with_flag(self: Diagnostic, name: []const u8) Diagnostic {
        var d = self;
        d.flag = name;
        return d;
    }

    pub fn with_expected(self: Diagnostic, text: []const u8) Diagnostic {
        var d = self;
        d.expected = text;
        return d;
    }

    pub fn with_got(self: Diagnostic, text: []const u8) Diagnostic {
        var d = self;
        d.got = text;
        return d;
    }
};

test "diagnostic builder" {
    const d = Diagnostic.init(error.UnknownFlag)
        .with_flag("verboce")
        .with_expected("--verbose")
        .with_got("--verboce");
    try std.testing.expectEqual(error.UnknownFlag, d.err);
    try std.testing.expectEqualStrings("verboce", d.flag.?);
}
