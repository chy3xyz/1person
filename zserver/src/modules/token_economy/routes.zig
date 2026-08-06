//! Token economy module — route registration.
//!
//! All token-economy endpoints require workspace membership.
//! Routes are mounted under `/api/token-economy` AND the frontend
//! contract `/api/tokens/...`. The `/api/tokens` root and `:id` CRUD
//! are intentionally NOT registered on the alias prefix — they belong
//! to the `token` (PAT) module at `/api/tokens` and would collide
//! (DuplicateRoute).

const zfinal = @import("zfinal");
const workspace_mw = @import("../../middleware/workspace.zig");
const handler = @import("handler.zig");

fn registerOn(app: *zfinal.ZFinal, prefix: []const u8) !void {
    var api = zfinal.RouteGroup.init(app, prefix);
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    // Token operations (non-colliding sub-paths)
    try api.post("/earn", handler.earnTokens);
    try api.post("/spend", handler.spendTokens);
    try api.post("/transfer", handler.transferTokens);
    try api.get("/balance", handler.getBalance);
    try api.get("/transactions", handler.listTransactions);
}

/// Full registration: config CRUD on the canonical prefix only.
fn registerConfigRoutes(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/token-economy");
    defer api.deinit();
    try api.addInterceptor(workspace_mw.RequireWorkspaceMember);

    try api.get("", handler.listConfigs);
    try api.post("", handler.createConfig);
    try api.get("/", handler.listConfigs);
    try api.post("/", handler.createConfig);
    try api.get("/:id", handler.getConfig);
    try api.put("/:id", handler.updateConfig);
    try api.delete("/:id", handler.deleteConfig);
}

pub fn register(app: *zfinal.ZFinal) !void {
    try registerConfigRoutes(app);
    // Frontend contract: /api/tokens/balance|earn|spend|transfer|transactions
    try registerOn(app, "/api/tokens");
    // Older callers / e2e keep the token operations under the canonical prefix too.
    try registerOn(app, "/api/token-economy");
}
