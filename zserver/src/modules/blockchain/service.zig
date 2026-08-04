//! Blockchain module — business logic.
//!
//! In-memory only (no DB). Stores chain configs, wallets, and
//! transactions in `std.StringHashMap`s protected by a mutex.
//! `sendTransaction` generates a mock tx_hash and marks the tx as
//! confirmed immediately. `getBalance` returns a mock 1.5 ETH.

const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("../../config.zig").Config;
const deps = @import("../../deps.zig");
const model = @import("model.zig");
const response = @import("../../common/response.zig");
const validation = @import("../../common/validation.zig");

const log = std.log.scoped(.blockchain_service);

var g_cfg: ?*const Config = null;

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_configs: ?std.StringHashMap(model.ChainConfig) = null;
var mem_wallets: ?std.StringHashMap(model.Wallet) = null;
var mem_transactions: ?std.StringHashMap(model.Transaction) = null;

pub fn init(cfg: *const Config) void {
    g_cfg = cfg;
    _ = g_cfg;
}

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn ensureMaps() !void {
    if (mem_configs == null) mem_configs = std.StringHashMap(model.ChainConfig).init(memAlloc());
    if (mem_wallets == null) mem_wallets = std.StringHashMap(model.Wallet).init(memAlloc());
    if (mem_transactions == null) mem_transactions = std.StringHashMap(model.Transaction).init(memAlloc());
}

fn workspaceId(ctx: *zfinal.Context) []const u8 {
    return ctx.attributes.get("workspace_id") orelse "";
}

fn memDup(text: []const u8) ![]const u8 {
    return try memAlloc().dupe(u8, text);
}

// ──────────────────────────────────────────────────────────────────────
// Chain configs CRUD
// ──────────────────────────────────────────────────────────────────────

pub fn listConfigs(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    var list: std.ArrayList(model.ChainConfig) = .empty;
    defer list.deinit(allocator);

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    var it = mem_configs.?.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.workspace_id, ws)) {
            try list.append(allocator, model.ChainConfig{
                .id = entry.value_ptr.id,
                .workspace_id = entry.value_ptr.workspace_id,
                .name = entry.value_ptr.name,
                .rpc_url = entry.value_ptr.rpc_url,
                .chain_id = entry.value_ptr.chain_id,
            });
        }
    }

    try ctx.renderJson(.{ .data = list.items });
}

pub fn createConfig(ctx: *zfinal.Context) !void {
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const parsed = try validation.validateJson(model.CreateConfigRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;

    const name = std.mem.trim(u8, req.name, &std.ascii.whitespace);
    const rpc_url = std.mem.trim(u8, req.rpc_url, &std.ascii.whitespace);

    if (name.len == 0 or rpc_url.len == 0) {
        return response.err(ctx, .bad_request, "name and rpc_url are required", 40020);
    }

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    const id = try model.generateId(memAlloc(), "cfg");
    const cfg = model.ChainConfig{
        .id = id,
        .workspace_id = try memDup(ws),
        .name = try memDup(name),
        .rpc_url = try memDup(rpc_url),
        .chain_id = req.chain_id,
    };
    try mem_configs.?.put(id, cfg);

    ctx.res_status = .created;
    try ctx.renderJson(.{ .data = cfg });
}

pub fn getConfig(ctx: *zfinal.Context) !void {
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const id = try response.parseStringId(ctx, "id");

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    const cfg = mem_configs.?.get(id) orelse {
        return response.err(ctx, .not_found, "config not found", 40401);
    };
    if (!std.mem.eql(u8, cfg.workspace_id, ws)) {
        return response.err(ctx, .not_found, "config not found", 40401);
    }
    try ctx.renderJson(.{ .data = cfg });
}

pub fn updateConfig(ctx: *zfinal.Context) !void {
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const id = try response.parseStringId(ctx, "id");

    const parsed = try validation.validateJson(struct {
        name: []const u8 = "",
        rpc_url: []const u8 = "",
        chain_id: ?i64 = null,
    }, ctx);
    defer parsed.deinit();
    const req = parsed.value;

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    const entry = mem_configs.?.getPtr(id) orelse {
        return response.err(ctx, .not_found, "config not found", 40401);
    };
    if (!std.mem.eql(u8, entry.workspace_id, ws)) {
        return response.err(ctx, .not_found, "config not found", 40401);
    }

    if (req.name.len > 0) {
        const trimmed = std.mem.trim(u8, req.name, &std.ascii.whitespace);
        if (trimmed.len > 0) entry.name = try memDup(trimmed);
    }
    if (req.rpc_url.len > 0) {
        const trimmed = std.mem.trim(u8, req.rpc_url, &std.ascii.whitespace);
        if (trimmed.len > 0) entry.rpc_url = try memDup(trimmed);
    }
    if (req.chain_id) |cid| {
        entry.chain_id = cid;
    }

    try ctx.renderJson(.{ .data = entry.* });
}

pub fn deleteConfig(ctx: *zfinal.Context) !void {
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const id = try response.parseStringId(ctx, "id");

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    const cfg = mem_configs.?.get(id) orelse return response.okNoContent(ctx);
    if (!std.mem.eql(u8, cfg.workspace_id, ws)) return response.okNoContent(ctx);
    _ = mem_configs.?.remove(id);
    return response.okNoContent(ctx);
}

// ──────────────────────────────────────────────────────────────────────
// Wallets CRUD
// ──────────────────────────────────────────────────────────────────────

pub fn listWallets(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    var list: std.ArrayList(model.Wallet) = .empty;
    defer list.deinit(allocator);

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    var it = mem_wallets.?.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.workspace_id, ws)) {
            try list.append(allocator, model.Wallet{
                .id = entry.value_ptr.id,
                .workspace_id = entry.value_ptr.workspace_id,
                .address = entry.value_ptr.address,
                .private_key_encrypted = entry.value_ptr.private_key_encrypted,
                .chain = entry.value_ptr.chain,
            });
        }
    }

    try ctx.renderJson(.{ .data = list.items });
}

pub fn createWallet(ctx: *zfinal.Context) !void {
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const parsed = try validation.validateJson(model.CreateWalletRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;

    const address = std.mem.trim(u8, req.address, &std.ascii.whitespace);
    const pk = std.mem.trim(u8, req.private_key_encrypted, &std.ascii.whitespace);
    const chain = if (req.chain) |c| std.mem.trim(u8, c, &std.ascii.whitespace) else "";

    if (address.len == 0) {
        return response.err(ctx, .bad_request, "address is required", 40020);
    }

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    const id = try model.generateId(memAlloc(), "wal");
    const wallet = model.Wallet{
        .id = id,
        .workspace_id = try memDup(ws),
        .address = try memDup(address),
        .private_key_encrypted = try memDup(pk),
        .chain = try memDup(chain),
    };
    try mem_wallets.?.put(id, wallet);

    ctx.res_status = .created;
    try ctx.renderJson(.{ .data = wallet });
}

pub fn getWallet(ctx: *zfinal.Context) !void {
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const id = try response.parseStringId(ctx, "id");

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    const w = mem_wallets.?.get(id) orelse {
        return response.err(ctx, .not_found, "wallet not found", 40402);
    };
    if (!std.mem.eql(u8, w.workspace_id, ws)) {
        return response.err(ctx, .not_found, "wallet not found", 40402);
    }
    try ctx.renderJson(.{ .data = w });
}

pub fn updateWallet(ctx: *zfinal.Context) !void {
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const id = try response.parseStringId(ctx, "id");

    const parsed = try validation.validateJson(struct {
        address: []const u8 = "",
        private_key_encrypted: []const u8 = "",
        chain: []const u8 = "",
    }, ctx);
    defer parsed.deinit();
    const req = parsed.value;

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    const entry = mem_wallets.?.getPtr(id) orelse {
        return response.err(ctx, .not_found, "wallet not found", 40402);
    };
    if (!std.mem.eql(u8, entry.workspace_id, ws)) {
        return response.err(ctx, .not_found, "wallet not found", 40402);
    }

    if (req.address.len > 0) {
        const trimmed = std.mem.trim(u8, req.address, &std.ascii.whitespace);
        if (trimmed.len > 0) entry.address = try memDup(trimmed);
    }
    if (req.private_key_encrypted.len > 0) {
        const trimmed = std.mem.trim(u8, req.private_key_encrypted, &std.ascii.whitespace);
        if (trimmed.len > 0) entry.private_key_encrypted = try memDup(trimmed);
    }
    if (req.chain.len > 0) {
        const trimmed = std.mem.trim(u8, req.chain, &std.ascii.whitespace);
        entry.chain = try memDup(trimmed);
    }

    try ctx.renderJson(.{ .data = entry.* });
}

pub fn deleteWallet(ctx: *zfinal.Context) !void {
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const id = try response.parseStringId(ctx, "id");

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    const w = mem_wallets.?.get(id) orelse return response.okNoContent(ctx);
    if (!std.mem.eql(u8, w.workspace_id, ws)) return response.okNoContent(ctx);
    _ = mem_wallets.?.remove(id);
    return response.okNoContent(ctx);
}

// ──────────────────────────────────────────────────────────────────────
// Transactions — send (fake) + list
// ──────────────────────────────────────────────────────────────────────

pub fn sendTransaction(ctx: *zfinal.Context) !void {
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const parsed = try validation.validateJson(model.SendTxRequest, ctx);
    defer parsed.deinit();
    const req = parsed.value;

    const wallet_id = std.mem.trim(u8, req.wallet_id, &std.ascii.whitespace);
    const method = std.mem.trim(u8, req.method, &std.ascii.whitespace);

    if (wallet_id.len == 0 or method.len == 0) {
        return response.err(ctx, .bad_request, "wallet_id and method are required", 40020);
    }

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    // Verify wallet exists and belongs to workspace
    const wallet = mem_wallets.?.get(wallet_id) orelse {
        return response.err(ctx, .not_found, "wallet not found", 40402);
    };
    if (!std.mem.eql(u8, wallet.workspace_id, ws)) {
        return response.err(ctx, .not_found, "wallet not found", 40402);
    }

    const tx_id = try model.generateId(memAlloc(), "tx");
    const tx_hash = try model.generateTxHash(memAlloc());
    const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    const created_at = try model.rfc3339(memAlloc(), now);

    const tx = model.Transaction{
        .id = tx_id,
        .wallet_id = try memDup(wallet_id),
        .tx_hash = tx_hash,
        .method = try memDup(method),
        .params_json = try memDup(req.params_json),
        .status = .confirmed,
        .created_at = created_at,
    };
    try mem_transactions.?.put(tx_id, tx);

    // Render status as string for JSON
    const status_str: []const u8 = "confirmed";

    ctx.res_status = .created;
    try ctx.renderJson(.{
        .data = .{
            .id = tx.id,
            .wallet_id = tx.wallet_id,
            .tx_hash = tx.tx_hash,
            .method = tx.method,
            .params_json = tx.params_json,
            .status = status_str,
            .created_at = tx.created_at,
        },
    });
}

pub fn listTransactions(ctx: *zfinal.Context) !void {
    const allocator = ctx.allocator;
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const TxItem = struct {
        id: []const u8,
        wallet_id: []const u8,
        tx_hash: []const u8,
        method: []const u8,
        params_json: []const u8,
        status: []const u8,
        created_at: []const u8,
    };
    var list: std.ArrayList(TxItem) = .empty;
    defer list.deinit(allocator);

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    // Build a set of workspace-owned wallet IDs for fast lookup.
    var ws_wallets = std.StringHashMap(void).init(memAlloc());
    defer ws_wallets.deinit();
    {
        var it = mem_wallets.?.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.workspace_id, ws)) {
                try ws_wallets.put(entry.value_ptr.id, {});
            }
        }
    }

    const statusStrings = [3][]const u8{ "pending", "confirmed", "failed" };
    var it = mem_transactions.?.iterator();
    while (it.next()) |entry| {
        const tx = entry.value_ptr;
        if (ws_wallets.contains(tx.wallet_id)) {
            try list.append(allocator, .{
                .id = tx.id,
                .wallet_id = tx.wallet_id,
                .tx_hash = tx.tx_hash,
                .method = tx.method,
                .params_json = tx.params_json,
                .status = statusStrings[@intFromEnum(tx.status)],
                .created_at = tx.created_at,
            });
        }
    }

    try ctx.renderJson(.{ .data = list.items });
}

pub fn getTransaction(ctx: *zfinal.Context) !void {
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const id = try response.parseStringId(ctx, "id");

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    const tx = mem_transactions.?.get(id) orelse {
        return response.err(ctx, .not_found, "transaction not found", 40403);
    };

    // Verify the wallet belongs to this workspace
    const wallet = mem_wallets.?.get(tx.wallet_id) orelse {
        return response.err(ctx, .not_found, "transaction not found", 40403);
    };
    if (!std.mem.eql(u8, wallet.workspace_id, ws)) {
        return response.err(ctx, .not_found, "transaction not found", 40403);
    }

    const statusStrings = [3][]const u8{ "pending", "confirmed", "failed" };
    try ctx.renderJson(.{
        .data = .{
            .id = tx.id,
            .wallet_id = tx.wallet_id,
            .tx_hash = tx.tx_hash,
            .method = tx.method,
            .params_json = tx.params_json,
            .status = statusStrings[@intFromEnum(tx.status)],
            .created_at = tx.created_at,
        },
    });
}

// ──────────────────────────────────────────────────────────────────────
// Balance — mock
// ──────────────────────────────────────────────────────────────────────

pub fn getBalance(ctx: *zfinal.Context) !void {
    const ws = workspaceId(ctx);
    if (ws.len == 0) return response.err(ctx, .bad_request, "missing workspace_id", 40001);

    const wallet_id = ctx.getPathParam("wallet_id") orelse {
        return response.err(ctx, .bad_request, "missing wallet_id", 40001);
    };

    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    try ensureMaps();

    const wallet = mem_wallets.?.get(wallet_id) orelse {
        return response.err(ctx, .not_found, "wallet not found", 40402);
    };
    if (!std.mem.eql(u8, wallet.workspace_id, ws)) {
        return response.err(ctx, .not_found, "wallet not found", 40402);
    }

    try ctx.renderJson(.{
        .data = .{
            .wallet_id = wallet_id,
            .balance = "1.5",
            .symbol = "ETH",
            .decimals = 18,
        },
    });
}
