const std = @import("std");
const zfinal = @import("zfinal");

test "route param matching" {
    const allocator = std.testing.allocator;
    var router = zfinal.Router.init(allocator);
    defer router.deinit();

    const h = struct {
        fn f(_: *zfinal.Context) !void {}
    }.f;

    try router.addWithMethod("/api/issues/search", .GET, h);
    try router.addWithMethod("/api/issues/", .GET, h);
    try router.addWithMethod("/api/issues/:id", .GET, h);

    try std.testing.expect(router.match("/api/issues/123", .GET) != null);
    try std.testing.expect(router.match("/api/issues/search", .GET) != null);
    try std.testing.expect(router.match("/api/issues/", .GET) != null);
}

test "route group param matching" {
    const allocator = std.testing.allocator;
    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    const h = struct {
        fn f(_: *zfinal.Context) !void {}
    }.f;

    var api = zfinal.RouteGroup.init(&app, "/api/workspaces");
    defer api.deinit();

    try api.get("/", h);
    try api.get("/:id", h);

    try std.testing.expect(app.router.match("/api/workspaces/123", .GET) != null);
    try std.testing.expect(app.router.match("/api/workspaces/", .GET) != null);
}
