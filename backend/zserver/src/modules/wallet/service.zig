//! Wallet service — in-memory no-DB business logic.
//!
//! Owns the in-memory wallet and transaction stores. All operations
//! are scoped to a workspace (via the RequireWorkspaceMember interceptor)
//! and a user (derived from the auth context).

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");
const common_mem = @import("../../common/mem.zig");
const common_ctx = @import("../../common/ctx.zig");

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;

var mem_wallets: ?std.StringHashMap(model.Wallet) = null;
var mem_transactions: ?std.StringHashMap(std.ArrayList(model.Transaction)) = null;

fn memAlloc() std.mem.Allocator {
        return common_mem.memAlloc();
    }

fn memDup(text: []const u8) ![]const u8 {
        return common_mem.memDup(text);
    }

fn memInit() !void {
    if (mem_wallets == null) {
        mem_wallets = std.StringHashMap(model.Wallet).init(memAlloc());
        mem_transactions = std.StringHashMap(std.ArrayList(model.Transaction)).init(memAlloc());
    }
}

fn generateId() ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    return std.fmt.allocPrint(memAlloc(), "{d}", .{ts});
}

fn nowStr() ![]const u8 {
    const sec = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return std.fmt.allocPrint(memAlloc(), "{d}", .{sec});
}

fn getUserId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getUserId(ctx);
    }

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
        return common_ctx.getWorkspaceId(ctx);
    }

fn requireUserId(ctx: *zfinal.Context) ![]const u8 {
    return getUserId(ctx) orelse {
        try response.err(ctx, .unauthorized, "user_id is required", 40101);
        return error.MissingUser;
    };
}

fn requireWorkspaceId(ctx: *zfinal.Context) ![]const u8 {
    return getWorkspaceId(ctx) orelse {
        try response.err(ctx, .bad_request, "workspace_id is required", 40021);
        return error.MissingWorkspace;
    };
}

/// Find the wallet for the current user + workspace combination.
fn findWallet(ctx: *zfinal.Context) !?model.Wallet {
    const user_id = try requireUserId(ctx);
    const workspace_id = try requireWorkspaceId(ctx);
    if (mem_wallets) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            const w = kv.value_ptr.*;
            if (std.mem.eql(u8, w.user_id, user_id) and std.mem.eql(u8, w.workspace_id, workspace_id)) {
                return w;
            }
        }
    }
    return null;
}

fn ensureWallet(ctx: *zfinal.Context) !model.Wallet {
    if (try findWallet(ctx)) |w| return w;

    const user_id = try requireUserId(ctx);
    const workspace_id = try requireWorkspaceId(ctx);
    const id = try generateId();

    const wallet = model.Wallet{
        .id = try memDup(id),
        .user_id = try memDup(user_id),
        .workspace_id = try memDup(workspace_id),
        .balance_fiat = 0.0,
        .balance_reward = 0.0,
    };
    try mem_wallets.?.put(wallet.id, wallet);
    return wallet;
}

fn appendTransaction(wallet_id: []const u8, amount: f64, typ: []const u8, status: []const u8) !model.Transaction {
    const id = try generateId();
    const txn = model.Transaction{
        .id = try memDup(id),
        .wallet_id = try memDup(wallet_id),
        .amount = amount,
        .type = try memDup(typ),
        .status = try memDup(status),
        .created_at = try nowStr(),
    };

    const txns = mem_transactions.?.getPtr(wallet_id);
    if (txns) |list| {
        try list.append(memAlloc(), txn);
    } else {
        var list: std.ArrayList(model.Transaction) = .empty;
        try list.append(memAlloc(), txn);
        try mem_transactions.?.put(try memDup(wallet_id), list);
    }
    return txn;
}

// ── Public API ────────────────────────────────────────────────────

pub fn createWallet(ctx: *zfinal.Context) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    if (try findWallet(ctx)) |w| {
        ctx.res_status = .ok;
        try ctx.renderJson(.{ .wallet = w });
        return;
    }

    const wallet = try ensureWallet(ctx);
    ctx.res_status = .created;
    try ctx.renderJson(.{ .wallet = wallet });
}

pub fn getWallet(ctx: *zfinal.Context) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const wallet = try ensureWallet(ctx);
    try ctx.renderJson(.{ .wallet = wallet });
}

pub fn deposit(ctx: *zfinal.Context) !void {
    const parsed = try ctx.parseJsonBody(model.AmountRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.amount <= 0) {
        try response.err(ctx, .bad_request, "amount must be positive", 40022);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const wallet = try ensureWallet(ctx);
    const ptr = mem_wallets.?.getPtr(wallet.id) orelse return error.WalletNotFound;
    ptr.balance_fiat += req.amount;

    const txn = try appendTransaction(wallet.id, req.amount, "deposit", "completed");
    try ctx.renderJson(.{ .wallet = ptr.*, .transaction = txn });
}

pub fn withdraw(ctx: *zfinal.Context) !void {
    const parsed = try ctx.parseJsonBody(model.AmountRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.amount <= 0) {
        try response.err(ctx, .bad_request, "amount must be positive", 40022);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const wallet = try ensureWallet(ctx);
    const ptr = mem_wallets.?.getPtr(wallet.id) orelse return error.WalletNotFound;
    if (ptr.balance_fiat < req.amount) {
        try response.err(ctx, .bad_request, "insufficient fiat balance", 40023);
        return;
    }
    ptr.balance_fiat -= req.amount;

    const txn = try appendTransaction(wallet.id, req.amount, "withdraw", "completed");
    try ctx.renderJson(.{ .wallet = ptr.*, .transaction = txn });
}

pub fn addReward(ctx: *zfinal.Context) !void {
    const parsed = try ctx.parseJsonBody(model.AmountRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.amount <= 0) {
        try response.err(ctx, .bad_request, "amount must be positive", 40022);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const wallet = try ensureWallet(ctx);
    const ptr = mem_wallets.?.getPtr(wallet.id) orelse return error.WalletNotFound;
    ptr.balance_reward += req.amount;

    const txn = try appendTransaction(wallet.id, req.amount, "reward", "completed");
    try ctx.renderJson(.{ .wallet = ptr.*, .transaction = txn });
}

pub fn listTransactions(ctx: *zfinal.Context) !void {
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const wallet = try ensureWallet(ctx);
    const txns = mem_transactions.?.get(wallet.id);
    const items = if (txns) |list| list.items else &[_]model.Transaction{};

    var out: std.ArrayList(model.Transaction) = .empty;
    defer out.deinit(ctx.allocator);
    for (items) |t| try out.append(ctx.allocator, t);

    try ctx.renderJson(.{ .transactions = out.items, .total = out.items.len });
}
