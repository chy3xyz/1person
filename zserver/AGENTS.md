# zserver — Agent Guidelines

This is the zserver-specific overlay on top of the repository-wide
`/AGENTS.md`. It captures the rules that only matter when editing
files under `zserver/`.

## Source layout: zfinal `examples/ruoyi-gen/` convention

```
src/
├── main.zig / server.zig / router.zig / config.zig / deps.zig / pg_url.zig
├── migrate.zig / health.zig / auth.zig (JWT helpers) / redis.zig / util.zig
├── tests.zig
├── middleware/      (workspace.zig, ratelimit.zig)
├── common/          (cross-cutting helpers — placeholder today)
└── modules/         31 per-domain packages, one directory per business
                     module. Each contains:
                     ├── handler.zig  thin HTTP delegate (1 line per route)
                     ├── service.zig  business logic + state + no-DB fallback
                     ├── model.zig    data structs + escape-hatch SQL
                     ├── routes.zig   route registration with interceptors
                     └── (test.zig)   unit tests (optional)
```

The top-level `src/router.zig` is a thin shell that iterates the
module list (via a `comptime fn resolveModule(name) type` that maps
each name to a literal `@import("modules/<name>/routes.zig")`) and
calls `register(app)` on each.

**Adding a new business module**:
1. Create `src/modules/<name>/{handler,service,model,routes}.zig`.
2. Add `<name>` to the `modules` array AND the `resolveModule`
   if-else chain in `src/router.zig`.
3. If the module needs `cfg`-driven config, expose a `pub fn init(cfg)` and call it from `src/router.zig`.

## Data access: use zfinal, not raw libpq

Hard rules (enforced by code review):

1. **Never import `@import("pq")` or call `c.PQ*`.** `zfinal.PgPool`
   / `zfinal.PgConn` are gone. The only DB API is `*zfinal.DB`
   borrowed from `src/deps.zig`.
2. **The DB pool is global.** `pub var pool: ?zfinal.ConnectionPool`
   in `src/deps.zig`. Handlers borrow it with
   `const db = try deps.acquire(); defer deps.releaseBack(db);`.
   Do not pass pool pointers around; do not create per-handler pools.
3. **Transactions are raw SQL.** `db.exec("BEGIN") / "COMMIT" / "ROLLBACK"`. `zfinal.DB` does not expose `begin()`/`commit()`/`rollback()` and `pool.transaction()` is dead code. The `errdefer ... catch |e| @panic(@errorName(e))` pattern on rollback failure is the zfinal convention.
4. **No-DB fallback is mandatory.** Every handler must keep an
   in-memory branch that fires when `deps.pool == null`. The
   `smoke_test.sh` 12/12 suite depends on it. The recommended
   helper is `fn borrowDb() ?*zfinal.DB { return deps.acquire() catch null; }`
   at the top of the file; then `if (borrowDb()) |db| { defer deps.releaseBack(db); … }`.
5. **`zfinal.DB.exec` / `queryParams` / `execParams` all take
   `[:0]const u8` SQL.** Wrap a `[]const u8` with
   `allocator.allocSentinel(u8, sql.len, 0)` + `@memcpy` (or use
   `std.fmt.allocPrintSentinel(allocator, ..., 0)` for dynamic SQL).
6. **The `model.zig` escape-hatch SQL helper pattern** (see `src/modules/auth/model.zig`):
   ```zig
   pub fn borrowDb() ?*zfinal.DB { return deps.acquire() catch null; }
   pub fn someThing() bool {
       const db = borrowDb() orelse return false;
       defer deps.releaseBack(db);
       var rs = db.queryParams("SELECT …", &[_]SqlParam{.{ .text = "…" }}) catch return false;
       defer rs.deinit();
       return rs.rows.items.len > 0;
   }
   ```
   This is the **only** SQL style allowed in new code. `zfinal.Model`
   is available for simple int-PK tables; most of our tables use
   UUID PK + JSONB / `TIMESTAMPTZ` and need the escape hatch.

## Build flags

`build.zig` passes `driver_pg = true` to the zfinal dependency, which
is what turns on the real `PostgresDB` driver and the `zfinal.Model`
ORM. If you add a new zserver module that imports `zfinal`, you get
the driver for free — do not re-implement the libpq glue.

## Quick reference

```bash
cd zserver
zig build                    # Debug build, includes the HTTP server
zig build test               # Unit tests (no DB required)
make ci                      # Docker-up + migrate + build + test (CI)
./scripts/smoke_test.sh      # 12/12 no-DB end-to-end checks
```

To exercise the real DB path locally:

```bash
docker compose up -d postgres
DATABASE_URL=postgres://app:secret@localhost:5432/zserver \
    MULTICA_DEV_VERIFICATION_CODE=000000 JWT_SECRET=test-secret \
    ./zig-out/bin/zserver migrate
DATABASE_URL=... ./zig-out/bin/zserver server --port 18080
```

## Source-layout migration status (Step 4 ✅✅✅)

**All 31 business modules migrated to the new zfinal layout.** The
legacy `src/handlers/` and `src/routes/` directories are deleted.
Every business endpoint now lives under
`src/modules/<name>/{handler,service,model,routes}.zig`.

The historical record of the migration is in
`docs/handler-migration-guide-historical.md` (the old
`HANDLER_MIGRATION_GUIDE.md` moved out of `src/` when `src/handlers/`
was deleted).

**One stub remains**: `src/modules/issue/` is a thin 501 Not
Implemented stub for its 26 endpoints. The `routes.zig` + `handler.zig`
are real; `service.zig` returns `501` with `{"endpoint": "<name>"}`.
The real DB / in-memory logic from the legacy ~3278-line issue
handler can be ported in a follow-up turn without touching
`routes.zig` or `handler.zig`. The 12/12 smoke suite does not
exercise issue endpoints, so the stub does not break CI.

