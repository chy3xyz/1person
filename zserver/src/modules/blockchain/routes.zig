//! Blockchain module — route registration.
//!
//! All blockchain endpoints are workspace-scoped and require the
//! `RequireWorkspaceMember` interceptor. Routes are mounted under
//! `/api/blockchain`.

const zfinal = @import("zfinal");
const handler = @import("handler.zig");
const workspace_mw = @import("../../middleware/workspace.zig");

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/blockchain");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Chain configs
    // Frontend contract: /api/blockchain/chains maps to config CRUD.
    try api.get("/chains", handler.listConfigs);
    try api.post("/chains", handler.createConfig);
    try api.get("/chains/:id", handler.getConfig);
    try api.delete("/chains/:id", handler.deleteConfig);
    try api.post("/wallets/:wallet_id/transactions", handler.sendTransaction);

    try api.get("/configs", handler.listConfigs);
    try api.post("/configs", handler.createConfig);
    try api.get("/configs/:id", handler.getConfig);
    try api.patch("/configs/:id", handler.updateConfig);
    try api.delete("/configs/:id", handler.deleteConfig);

    // Wallets
    try api.get("/wallets", handler.listWallets);
    try api.post("/wallets", handler.createWallet);
    try api.get("/wallets/:id", handler.getWallet);
    try api.patch("/wallets/:id", handler.updateWallet);
    try api.delete("/wallets/:id", handler.deleteWallet);

    // Balance
    try api.get("/wallets/:wallet_id/balance", handler.getBalance);

    // Transactions
    try api.post("/transactions", handler.sendTransaction);
    try api.get("/transactions", handler.listTransactions);
    try api.get("/transactions/:id", handler.getTransaction);
}
