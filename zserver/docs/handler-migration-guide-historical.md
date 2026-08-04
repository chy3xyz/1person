# Handler Migration Guide — **HISTORICAL** (Step 3 completed)

> **Status:** This document is the historical record of the
> `db.zig`-shim → `zfinal.Model` / `zfinal.SqlParam` migration that
> completed with Step 3. The shim has been **deleted**. New code
> follows the same three patterns described below; consult
> `zserver/AGENTS.md` for the current rules.

The recipe, patterns, and verification contract below were used to
migrate every handler in `src/handlers/` and
`src/middleware/workspace.zig` off the `db.zig` compatibility layer.

## The three patterns

A handler's DB access falls into exactly one of three buckets. Pick the
right one — don't mix.

### Pattern 1 — `zfinal.Model` (int PK, all-primitive fields)

For tables whose schema is `id BIGSERIAL PRIMARY KEY` + a handful of
int / float / bool / string / optional fields. This is what
`zfinal.Model` was designed for.

```zig
const zfinal = @import("zfinal");
const deps = @import("../deps.zig");

const Post = struct {
    title: []const u8,
    body: []const u8,
    author_id: i64,
    published: bool = false,
};
pub const PostModel = zfinal.Model(Post, "posts");

pub fn show(ctx: *zfinal.Context) !void {
    const id = try std.fmt.parseInt(i64, ctx.getPathParam("id").?, 10);
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    const post = try PostModel.findById(db, id, ctx.allocator)
        orelse {
            ctx.res_status = .not_found;
            try ctx.renderJson(.{ .@"error" = "post not found" });
            return;
        };
    defer post.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = post.data });
}
```

### Pattern 2 — `zfinal.ModelWithPK` (string / UUID PK)

`zfinal.Model` assumes a single `id` column. For UUID-PK tables (which
is **every** table in our schema), use `ModelWithPK(T, "table", "pk_col")`.
The PK column name must match a field in `T` and be `[]const u8`.

```zig
pub const IssueModel = zfinal.ModelWithPK(Issue, "issues", "id");

pub fn getIssue(ctx: *zfinal.Context) !void {
    const id = ctx.getPathParam("id").?;
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    const row = try IssueModel.findById(db, id, ctx.allocator) orelse {
        ctx.res_status = .not_found;
        return;
    };
    defer row.deinit(ctx.allocator);
    try ctx.renderJson(.{ .data = row.data });
}
```

### Pattern 3 — Escape hatch: `db.queryParams` with `zfinal.SqlParam`

For tables that mix in `TIMESTAMPTZ`, `JSONB`, `UUID[]`, `INET`, etc.
`zfinal.Model.parseField` only knows int / float / bool / string /
optional, so the ORM can't model them. Use the documented escape hatch:

```zig
const SqlParam = zfinal.SqlParam;

pub fn search(ctx: *zfinal.Context) !void {
    const owner = ctx.getPara("owner") orelse "";
    const db = try deps.acquire();
    defer deps.releaseBack(db);
    var rs = try db.queryParams(
        \\SELECT id, name, metadata, created_at
        \\FROM   projects
        \\WHERE  owner_id = $1 AND deleted_at IS NULL
        \\ORDER  BY created_at DESC
    , &[_]SqlParam{.{ .text = owner }});
    defer rs.deinit();
    var out: std.ArrayList(zfinal.Value) = .empty;
    defer out.deinit(ctx.allocator);
    var it = rs.rows.iterator();
    while (it.next() catch null) |row| {
        const id = row.getText(0) orelse continue;
        const name = row.getText(1) orelse "";
        const metadata = row.getText(2);  // raw JSON string
        const created_at = row.getText(3) orelse "";
        try out.append(ctx.allocator, ...);
    }
    try ctx.renderJson(.{ .data = out.items });
}
```

`zfinal.SqlParam` is a tagged union: `{ .int: i64 }`, `{ .real: f64 }`,
`{ .text: []const u8 }`, `{ .blob: []const u8 }`, `{ .null = {} }`.

## Transactions

`zfinal.DB` has **no** `begin()` / `commit()` / `rollback()` methods
(the `pool.transaction()` helper is dead code). Use raw SQL:

```zig
try db.exec("BEGIN");
errdefer db.exec("ROLLBACK") catch |e| @panic(@errorName(e));
try IssueModel.deleteById(db, id);
try SubtaskModel.deleteWhere(db, "issue_id = $1", &.{.{ .text = id }});
try db.exec("COMMIT");
```

The `errdefer ... @panic` is what `zfinal.Model.update` does internally
on rollback failure — it's a framework convention (`SECURITY.md:67`),
not a stylistic choice.

## No-DB fallback

When `DATABASE_URL` is not set, `deps.pool` is null and `deps.acquire()`
returns `error.PoolNotInitialized`. Every handler **must** keep its
existing in-memory branch (the 12/12 smoke test depends on it):

```zig
pub fn show(ctx: *zfinal.Context) !void {
    const id = ctx.getPathParam("id").?;

    const db = deps.acquire() catch return showFromMemory(ctx, id);
    defer deps.releaseBack(db);

    // ... real DB path
}

fn showFromMemory(ctx: *zfinal.Context, id: []const u8) !void {
    // existing in-memory implementation; unchanged
}
```

## The 13 handlers, ordered by difficulty

| # | File | Pattern | Notes |
|---|---|---|---|
| 1 | `auth.zig` | 2 (UUID users) + 3 (login codes) | Start here; the schema is closest to ORM-friendly |
| 2 | `workspace.zig` | 2 + 3 (members) | List/create/get are trivial; member joins need the escape hatch |
| 3 | `label.zig`, `project.zig`, `pin.zig`, `task.zig` | 2 | Mostly lookup tables |
| 4 | `agent.zig`, `agent_template.zig` | 2 + 3 (JSONB config) | Config column is `JSONB` |
| 5 | `skill.zig` | 2 + 3 (config blob) | Same JSONB story |
| 6 | `autopilot.zig` | 2 + 3 (triggers / runs) | The trigger body is JSONB |
| 7 | `issue.zig` | 2 + 3 (heavy) | 3000 lines; many sub-resources; do last or split into sub-agents |
| 8 | `attachment.zig` | 2 + 3 (file metadata) | The file payload is on disk; only the meta row is SQL |
| 9 | `comment.zig` | 2 + 3 (mentions JSONB) | |
| 10 | `chat.zig`, `inbox.zig` | 2 + 3 (JSONB payloads) | |
| 11 | `runtime.zig`, `daemon.zig` | 2 + 3 (status JSONB) | Daemon in-memory ring buffer stays; only the request store moves to DB |
| 12 | `billing.zig`, `webhook.zig`, `contact.zig`, `lark.zig` | 2 + 3 | Mostly thin CRUD; webhooks keep the in-memory fallback |

Per-handler commit checklist:
1. Remove the file-level `const db = @import("db.zig");` (or change it to `const deps = @import("../deps.zig");`).
2. Replace `if (g_db) |d| { var conn = try d.connect(); ... }` with the no-DB-aware pattern above.
3. Delete the `g_db: ?*db.Db` global.
4. After `zig build && zig build test` is green, run `smoke_test.sh` and a manual `curl` against the endpoints in scope.

When the last handler is converted, delete `src/db.zig` and `db.g_handle`,
update `AGENTS.md` to mark the migration done, and bump this guide to
"historical".
