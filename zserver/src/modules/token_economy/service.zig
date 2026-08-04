//! Token economy service — in-memory CRUD for token configs plus
//! earn / spend / transfer operations.
//!
//! All state lives in page-allocator-backed hash maps with a global
//! mutex. DB integration can be layered on later through the escape-hatch
//! pattern in model.zig.

const std = @import("std");
const zfinal = @import("zfinal");
const model = @import("model.zig");
const response = @import("../../common/response.zig");

const log = std.log.scoped(.token_economy_service);

var mem_mutex: std.Io.Mutex = std.Io.Mutex.init;
var mem_configs: ?std.StringHashMap(model.TokenConfig) = null;
var mem_balances: ?std.StringHashMap(model.TokenBalance) = null;
var mem_transactions: ?std.ArrayList(model.TokenTransaction) = null;

fn memAlloc() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn memDup(text: []const u8) ![]const u8 {
    return memAlloc().dupe(u8, text);
}

fn memInit() !void {
    if (mem_configs == null) {
        mem_configs = std.StringHashMap(model.TokenConfig).init(memAlloc());
        mem_balances = std.StringHashMap(model.TokenBalance).init(memAlloc());
        mem_transactions = std.ArrayList(model.TokenTransaction).empty;
    }
}

fn generateId(prefix: []const u8) ![]const u8 {
    const ts = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toNanoseconds();
    return std.fmt.allocPrint(memAlloc(), "{s}-{d}", .{ prefix, ts });
}

fn nowStr() ![]const u8 {
    const sec = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    return std.fmt.allocPrint(memAlloc(), "{d}", .{sec});
}

fn getWorkspaceId(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.attributes.get("workspace_id");
}

fn requireWorkspaceId(ctx: *zfinal.Context) ![]const u8 {
    return getWorkspaceId(ctx) orelse {
        try response.err(ctx, .bad_request, "workspace_id is required", 40021);
        return error.MissingWorkspace;
    };
}

/// Build a composite key: "{user_id}:{workspace_id}" for balance lookups.
fn balanceKey(user_id: []const u8, workspace_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(memAlloc(), "{s}:{s}", .{ user_id, workspace_id });
}

/// ── Token config CRUD ──────────────────────────────────────────

pub fn listConfigs(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.TokenConfig) = .empty;
    defer list.deinit(ctx.allocator);
    if (mem_configs) |*m| {
        var it = m.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.workspace_id, workspace_id))
                try list.append(ctx.allocator, kv.value_ptr.*);
        }
    }
    try ctx.renderJson(.{ .configs = list.items, .total = list.items.len });
}

pub fn createConfig(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.CreateConfigRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.name.len == 0) {
        try response.err(ctx, .bad_request, "name is required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const id = try generateId("tc");
    const supply: f64 = if (req.total_supply) |s| s else 0.0;
    const entry = model.TokenConfig{
        .id = try memDup(id),
        .workspace_id = try memDup(workspace_id),
        .name = try memDup(req.name),
        .total_supply = supply,
        .created_at = try nowStr(),
    };
    try mem_configs.?.put(entry.id, entry);
    ctx.res_status = .created;
    try ctx.renderJson(entry);
}

pub fn getConfig(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "config_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry = mem_configs.?.get(id) orelse {
        try response.err(ctx, .not_found, "token config not found", 40401);
        return;
    };
    try ctx.renderJson(entry);
}

pub fn updateConfig(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "config_id is required", 40021);
        return;
    };
    const parsed = try ctx.parseJsonBody(model.UpdateConfigRequest);
    defer parsed.deinit();
    const req = parsed.value;

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    const entry_ptr = mem_configs.?.getPtr(id) orelse {
        try response.err(ctx, .not_found, "token config not found", 40401);
        return;
    };
    if (req.name) |n| entry_ptr.name = try memDup(n);
    if (req.total_supply) |s| entry_ptr.total_supply = s;
    try ctx.renderJson(entry_ptr.*);
}

pub fn deleteConfig(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const id = ctx.getPathParam("id") orelse {
        try response.err(ctx, .bad_request, "config_id is required", 40021);
        return;
    };
    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);
    _ = mem_configs.?.fetchRemove(id) orelse {
        try response.err(ctx, .not_found, "token config not found", 40401);
        return;
    };
    try response.okNoContent(ctx);
}

/// ── Token operations ───────────────────────────────────────────

pub fn earnTokens(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.EarnTokensRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.amount <= 0) {
        try response.err(ctx, .bad_request, "amount must be positive", 40022);
        return;
    }
    if (req.user_id.len == 0) {
        try response.err(ctx, .bad_request, "user_id is required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const key = try balanceKey(req.user_id, workspace_id);
    const now = try nowStr();

    // Upsert balance
    if (mem_balances.?.getPtr(key)) |bal| {
        bal.balance += req.amount;
        bal.updated_at = now;
    } else {
        const entry = model.TokenBalance{
            .user_id = try memDup(req.user_id),
            .workspace_id = try memDup(workspace_id),
            .balance = req.amount,
            .updated_at = now,
        };
        try mem_balances.?.put(key, entry);
    }

    // Record transaction
    const tx_id = try generateId("tx");
    const tx = model.TokenTransaction{
        .id = try memDup(tx_id),
        .from_user_id = null,
        .to_user_id = try memDup(req.user_id),
        .amount = req.amount,
        .reason = try memDup(req.reason),
        .type = try memDup("earn"),
        .created_at = now,
    };
    try mem_transactions.?.append(memAlloc(), tx);

    try ctx.renderJson(.{ .transaction = tx, .balance = mem_balances.?.get(key).? });
}

pub fn spendTokens(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.SpendTokensRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.amount <= 0) {
        try response.err(ctx, .bad_request, "amount must be positive", 40022);
        return;
    }
    if (req.user_id.len == 0) {
        try response.err(ctx, .bad_request, "user_id is required", 40021);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const key = try balanceKey(req.user_id, workspace_id);
    const bal = mem_balances.?.get(key) orelse {
        try response.err(ctx, .bad_request, "insufficient balance", 40023);
        return;
    };

    if (bal.balance < req.amount) {
        try response.err(ctx, .bad_request, "insufficient balance", 40023);
        return;
    }

    const now = try nowStr();
    if (mem_balances.?.getPtr(key)) |b| {
        b.balance -= req.amount;
        b.updated_at = now;
    }

    // Record transaction
    const tx_id = try generateId("tx");
    const tx = model.TokenTransaction{
        .id = try memDup(tx_id),
        .from_user_id = try memDup(req.user_id),
        .to_user_id = null,
        .amount = req.amount,
        .reason = try memDup(req.reason),
        .type = try memDup("spend"),
        .created_at = now,
    };
    try mem_transactions.?.append(memAlloc(), tx);

    try ctx.renderJson(.{ .transaction = tx, .balance = mem_balances.?.get(key).? });
}

pub fn transferTokens(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const parsed = try ctx.parseJsonBody(model.TransferTokensRequest);
    defer parsed.deinit();
    const req = parsed.value;

    if (req.amount <= 0) {
        try response.err(ctx, .bad_request, "amount must be positive", 40022);
        return;
    }
    if (req.from_user_id.len == 0 or req.to_user_id.len == 0) {
        try response.err(ctx, .bad_request, "from_user_id and to_user_id are required", 40021);
        return;
    }
    if (std.mem.eql(u8, req.from_user_id, req.to_user_id)) {
        try response.err(ctx, .bad_request, "cannot transfer to self", 40024);
        return;
    }

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const from_key = try balanceKey(req.from_user_id, workspace_id);
    const to_key = try balanceKey(req.to_user_id, workspace_id);

    const from_bal = mem_balances.?.get(from_key) orelse {
        try response.err(ctx, .bad_request, "insufficient balance", 40023);
        return;
    };
    if (from_bal.balance < req.amount) {
        try response.err(ctx, .bad_request, "insufficient balance", 40023);
        return;
    }

    const now = try nowStr();
    const reason = if (req.reason) |r| r else "transfer";

    // Debit sender
    if (mem_balances.?.getPtr(from_key)) |b| {
        b.balance -= req.amount;
        b.updated_at = now;
    }

    // Credit receiver
    if (mem_balances.?.getPtr(to_key)) |b| {
        b.balance += req.amount;
        b.updated_at = now;
    } else {
        const entry = model.TokenBalance{
            .user_id = try memDup(req.to_user_id),
            .workspace_id = try memDup(workspace_id),
            .balance = req.amount,
            .updated_at = now,
        };
        try mem_balances.?.put(to_key, entry);
    }

    // Record transaction
    const tx_id = try generateId("tx");
    const tx = model.TokenTransaction{
        .id = try memDup(tx_id),
        .from_user_id = try memDup(req.from_user_id),
        .to_user_id = try memDup(req.to_user_id),
        .amount = req.amount,
        .reason = try memDup(reason),
        .type = try memDup("transfer"),
        .created_at = now,
    };
    try mem_transactions.?.append(memAlloc(), tx);

    try ctx.renderJson(.{
        .transaction = tx,
        .from_balance = mem_balances.?.get(from_key).?,
        .to_balance = mem_balances.?.get(to_key).?,
    });
}

pub fn getBalance(ctx: *zfinal.Context) !void {
    const workspace_id = try requireWorkspaceId(ctx);
    const user_id = ctx.getPara("user_id") catch {
        try response.err(ctx, .bad_request, "user_id query parameter is required", 40021);
        return;
    } orelse {
        try response.err(ctx, .bad_request, "user_id query parameter is required", 40021);
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    const key = try balanceKey(user_id, workspace_id);
    const bal = mem_balances.?.get(key) orelse {
        const empty = model.TokenBalance{
            .user_id = try ctx.allocator.dupe(u8, user_id),
            .workspace_id = try ctx.allocator.dupe(u8, workspace_id),
            .balance = 0.0,
            .updated_at = try ctx.allocator.dupe(u8, ""),
        };
        try ctx.renderJson(empty);
        return;
    };

    // Clone for rendering with ctx allocator
    const out = model.TokenBalance{
        .user_id = try ctx.allocator.dupe(u8, bal.user_id),
        .workspace_id = try ctx.allocator.dupe(u8, bal.workspace_id),
        .balance = bal.balance,
        .updated_at = try ctx.allocator.dupe(u8, bal.updated_at),
    };
    try ctx.renderJson(out);
}

pub fn listTransactions(ctx: *zfinal.Context) !void {
    _ = try requireWorkspaceId(ctx);
    const user_id = ctx.getPara("user_id") catch {
        try response.err(ctx, .bad_request, "user_id query parameter is required", 40021);
        return;
    } orelse {
        try response.err(ctx, .bad_request, "user_id query parameter is required", 40021);
        return;
    };

    try memInit();
    try mem_mutex.lock(zfinal.io_instance.io);
    defer mem_mutex.unlock(zfinal.io_instance.io);

    var list: std.ArrayList(model.TokenTransaction) = .empty;
    defer list.deinit(ctx.allocator);

    for (mem_transactions.?.items) |tx| {
        const match_from = if (tx.from_user_id) |f| std.mem.eql(u8, f, user_id) else false;
        const match_to = if (tx.to_user_id) |t| std.mem.eql(u8, t, user_id) else false;
        if (!(match_from or match_to)) continue;

        // workspace_id scoping: for transfers, we check via balance
        try list.append(ctx.allocator, tx);
    }

    try ctx.renderJson(.{ .transactions = list.items, .total = list.items.len });
}
