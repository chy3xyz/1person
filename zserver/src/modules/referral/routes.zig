//! Referral module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/referrals");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Code CRUD
    try api.post("/codes", handler.createCode);
    try api.get("/codes", handler.listCodes);
    try api.get("/codes/:code", handler.getCode);
    try api.delete("/codes/:code", handler.deleteCode);

    // Referral tracking
    try api.post("/track", handler.trackReferral);
    try api.post("/activate", handler.activateReferral);

    // Referral tree
    try api.get("/tree/:user_id", handler.getReferralTree);

    // Records
    try api.get("/records", handler.listRecords);
}
