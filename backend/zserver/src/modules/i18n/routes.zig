//! I18n module — route registration.
//!
//! All endpoints are scoped under /api/i18n and protected by the
//! RequireWorkspaceMember interceptor so only authenticated workspace
//! members can read/write translations.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/i18n");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("/locales", handler.listLocales);
    try api.get("/translations", handler.getTranslations);
    try api.post("/translations", handler.setTranslation);
    // Frontend contract uses PUT for translation updates.
    try api.put("/translations", handler.setTranslation);
}
