//! Wallet module — route registration.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/wallet");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.post("/create", handler.createWallet);
    try api.get("/me", handler.getWallet);
    try api.post("/deposit", handler.deposit);
    try api.post("/withdraw", handler.withdraw);
    try api.post("/reward", handler.addReward);
    try api.get("/transactions", handler.listTransactions);
}
