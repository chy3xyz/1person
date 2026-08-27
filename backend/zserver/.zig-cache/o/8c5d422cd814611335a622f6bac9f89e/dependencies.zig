pub const packages = struct {
    pub const @"zcli-0.2.0-CR5cGSiNAACHeulKURcsDqFP7ce0T4In4oInViqE-Ps2" = struct {
        pub const build_root = "zig-pkg/zcli-0.2.0-CR5cGSiNAACHeulKURcsDqFP7ce0T4In4oInViqE-Ps2";
        pub const build_zig = @import("zcli-0.2.0-CR5cGSiNAACHeulKURcsDqFP7ce0T4In4oInViqE-Ps2");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zent-0.31.0-oiur-31tDwD4Xuts2KOkUF9ot6y0zMFA-BOzojMIm17h" = struct {
        pub const build_root = "zig-pkg/zent-0.31.0-oiur-31tDwD4Xuts2KOkUF9ot6y0zMFA-BOzojMIm17h";
        pub const build_zig = @import("zent-0.31.0-oiur-31tDwD4Xuts2KOkUF9ot6y0zMFA-BOzojMIm17h");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zfinal-0.25.0-6AOMdZ3ybACPNWReg6SKD7rtEKi2pK4pJUO2dovIGguq" = struct {
        pub const build_root = "zig-pkg/zfinal-0.25.0-6AOMdZ3ybACPNWReg6SKD7rtEKi2pK4pJUO2dovIGguq";
        pub const build_zig = @import("zfinal-0.25.0-6AOMdZ3ybACPNWReg6SKD7rtEKi2pK4pJUO2dovIGguq");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zent", "zent-0.31.0-oiur-31tDwD4Xuts2KOkUF9ot6y0zMFA-BOzojMIm17h" },
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zfinal", "zfinal-0.25.0-6AOMdZ3ybACPNWReg6SKD7rtEKi2pK4pJUO2dovIGguq" },
    .{ "zcli", "zcli-0.2.0-CR5cGSiNAACHeulKURcsDqFP7ce0T4In4oInViqE-Ps2" },
};
