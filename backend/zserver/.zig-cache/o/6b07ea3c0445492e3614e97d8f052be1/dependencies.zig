pub const packages = struct {
    pub const @"../zig_ws/zcli" = struct {
        pub const build_root = "../zig_ws/zcli";
        pub const build_zig = @import("../zig_ws/zcli");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"../zig_ws/zfinal" = struct {
        pub const build_root = "../zig_ws/zfinal";
        pub const build_zig = @import("../zig_ws/zfinal");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zent", "zent-0.31.0-oiur-31tDwD4Xuts2KOkUF9ot6y0zMFA-BOzojMIm17h" },
        };
    };
    pub const @"zent-0.31.0-oiur-31tDwD4Xuts2KOkUF9ot6y0zMFA-BOzojMIm17h" = struct {
        pub const build_root = "zig-pkg/zent-0.31.0-oiur-31tDwD4Xuts2KOkUF9ot6y0zMFA-BOzojMIm17h";
        pub const build_zig = @import("zent-0.31.0-oiur-31tDwD4Xuts2KOkUF9ot6y0zMFA-BOzojMIm17h");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zfinal", "../zig_ws/zfinal" },
    .{ "zcli", "../zig_ws/zcli" },
};
