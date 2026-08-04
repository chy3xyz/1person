//! Token economy module — route registration.
//!
//! All token-economy endpoints require workspace membership.
//! Routes are mounted under `/api/token-economy` to avoid collision
//! with the `token` (PAT) module at `/api/tokens`.

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/token-economy");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Config CRUD
    try api.get("", handler.listConfigs);
    try api.post("", handler.createConfig);
    try api.get("/", handler.listConfigs);
    try api.post("/", handler.createConfig);
    try api.get("/:id", handler.getConfig);
    try api.put("/:id", handler.updateConfig);
    try api.delete("/:id", handler.deleteConfig);

    // Token operations
    try api.post("/earn", handler.earnTokens);
    try api.post("/spend", handler.spendTokens);
    try api.post("/transfer", handler.transferTokens);
    try api.get("/balance", handler.getBalance);
    try api.get("/transactions", handler.listTransactions);
}
