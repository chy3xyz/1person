//! Commission module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

fn registerOn(app: *zfinal.ZFinal, prefix: []const u8) !void {
    var api = zfinal.RouteGroup.init(app, prefix);
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Rule CRUD
    try api.get("/rules", handler.listRules);
    try api.post("/rules", handler.createRule);
    try api.get("/rules/:id", handler.getRule);
    try api.put("/rules/:id", handler.updateRule);
    try api.delete("/rules/:id", handler.deleteRule);

    // Commission calculation & settlement
    try api.post("/calculate", handler.calculateCommission);
    try api.post("/settle", handler.settleCommissions);

    // Records
    try api.get("/records", handler.listRecords);
    try api.get("/records/:id", handler.getRecord);
}

pub fn register(app: *zfinal.ZFinal) !void {
    // Frontend contract uses /api/commission, older callers/e2e use /api/commissions.
    try registerOn(app, "/api/commissions");
    try registerOn(app, "/api/commission");
}
