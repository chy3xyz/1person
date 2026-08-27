# zserver

Zig 0.17 rewrite of the Multica Go server (`server/`, excluded from this repo
— only its `server/migrations/` SQL is kept because `zserver migrate` reads
it).

## Status

Feature-complete against the frontend API surface: **50 business modules**
under `src/modules/<name>/{handler,service,model,routes}.zig`, all wired into
`src/router.zig`. Every route the Next.js frontend (`packages/core/api/client.ts`)
calls resolves; the response envelope (`{data: ...}`) is unwrapped client-side
for Go-compatible shapes.

A Zig CLI client (`1p`, built by `zig build`) covers the M1 milestone:
`config` / `login` / `pair` / `version` — see
`backend/docs/zig-daemon-plan.md` for the roadmap and `scripts/cli_m1_e2e.sh`
for the end-to-end verification.

Modules with intentional in-memory/demo implementations (no DB table or Go
counterpart exists): billing, blockchain, commission, community_ops,
compliance, connector, content_matrix, i18n, notification, pipeline, referral,
scheduler, task_queue_v2, token_economy, training, wallet — these run fully in
no-DB mode and are zserver-specific features.

## Quick start

```bash
# Build + test (zfinal + zcli fetched automatically from build.zig.zon)
# From repo root:
cd backend/zserver
zig build
zig build test                # unit tests

# Run
./zig-out/bin/zserver server --port 8080        # no-DB mode (in-memory state)
DATABASE_URL=postgres://... ./zig-out/bin/zserver migrate
DATABASE_URL=postgres://... ./zig-out/bin/zserver server --port 8080
```

Run tests:

```bash
zig build test                # unit tests
./scripts/smoke_test.sh       # health/auth/workspace checks (DB mode when DATABASE_URL is set, else no-DB)
node scripts/integration.mjs http://127.0.0.1:18099   # frontend call-pattern checks
scripts/<module>_e2e.sh       # 30 per-module e2e suites (no-DB by default; set DATABASE_URL for DB mode)
```

The e2e suites default to deterministic no-DB mode (`DATABASE_URL=""` when
unset). Setting `DATABASE_URL` runs the same suite against real PostgreSQL —
both modes are exercised in CI (`.github/workflows/zserver-ci.yml`).

## CLI

Uses `zcli` (Zig package manager git dep in `build.zig.zon`, commit `3c466ee`):

```bash
zserver server [--port PORT] [--db-url URL]
zserver migrate [--db-url URL]   # DATABASE_URL / MULTICA_DATABASE_URL env also honored
zserver version               # version injected from build.zig.zon (-Dcommit=...)
```

## Web framework

Both framework deps are Zig package manager **git** dependencies in
`build.zig.zon` (no local `zig_ws/` provision):

```zig
.zfinal = .{
    .url = "git+https://github.com/chy3xyz/zfinal?ref=v0.25.0#fa9d4c5…",
    .hash = "zfinal-0.25.0-6AOMdZ3ybACPNWReg6SKD7rtEKi2pK4pJUO2dovIGguq",
},
.zcli = .{
    .url = "git+https://github.com/chy3xyz/zcli#3c466ee…",
    .hash = "zcli-0.2.0-CR5cGSiNAACHeulKURcsDqFP7ce0T4In4oInViqE-Ps2",
},
```

Notable for zserver from zfinal: Context body phase contract (`body_consumed` —
second `getBodyText` panics in Debug), graceful-shutdown drain regression
coverage, and `RedisRateLimiter` / `WsFanout` (already used by our rate-limit
middleware).

## Project layout

| Path | Purpose |
|------|---------|
| `src/main.zig` | CLI entry point (`zcli`) |
| `src/server.zig` | HTTP server lifecycle (`zfinal`); empty `DATABASE_URL` ⇒ no-DB |
| `src/config.zig` | Env-based configuration (random dev JWT secret, production requires `JWT_SECRET`) |
| `src/router.zig` | Module registry (50 modules) + `/ws` |
| `src/middleware.zig` | Auth (JWT / PAT / task-token DB verification), CORS, logging, CSRF |
| `src/middleware/workspace.zig` | Workspace-member gating (`RequireWorkspaceMember`) |
| `src/middleware/daemon_auth.zig` | `mdt_` daemon token handling |
| `src/daemon_notify.zig` | Runtime→daemon WebSocket registry (`daemon:task_available`) |
| `src/task_queue.zig` | In-memory task queue (claim/enqueue + WS notify) |
| `src/health.zig` | `/health`, `/readyz` (migration-version aware) |
| `src/auth.zig` | JWT create/verify, CSRF, token-type detection |
| `src/deps.zig` | Global `zfinal.ConnectionPool` |
| `src/common/` | Shared helpers: `response.zig`, `validation.zig`, `pagination.zig`, `mem.zig`, `ctx.zig` |
| `src/modules/<name>/` | Per-domain `handler` / `service` / `model` / `routes` |
| `scripts/` | 30 per-module e2e suites + smoke + frontend integration |

## Production readiness — known gaps

Hardening status as of the zserver 转正 (promotion) pass:

1. **no-DB mode is dev/test only.** `APP_ENV=production` refuses to boot
   without a working `DATABASE_URL` (no-DB mode degrades auth to format-only
   token checks and grants workspace `owner` to everyone — a fail-open
   bypass that must never run in production). Token verification also fails
   closed (503) if a configured pool can't be acquired.
2. **Daemon (`mdt_`) tokens: DB-verified and mintable.** `DaemonAuthInterceptor`
   verifies `mdt_` tokens against the `daemon_token` table (SHA-256 hash,
   unexpired, matching `daemon_id`) in DB mode, and `POST /api/daemon/tokens`
   (user auth + workspace membership required) mints workspace-bound daemon
   credentials — the `GenerateDaemonToken` + `CreateDaemonToken` counterpart.
   Verified by `scripts/daemon_db_e2e.sh` (login → mint → register → heartbeat,
   plus forged-token 401 and non-member 403 checks). The Zig daemon CLI
   client that consumes these tokens is in progress (see
   `backend/docs/zig-daemon-plan.md`).
3. **Redis WS fanout: publish side only.** `broadcastToRedis` publishes
   events to `ws:<workspace_id>`, but no subscriber exists (zfinal's Redis
   client has no message-read primitive for pub/sub push mode), so
   multi-instance realtime delivery is not supported. Deploy realtime as a
   single instance, or pin WS clients to one instance, until the subscriber
   is implemented.
4. **Rate limiting always applies.** Auth endpoints are rate-limited via
   `zfinal.RedisRateLimiter` (atomic, distributed) when Redis is available,
   and via an in-process fixed-window fallback when it is not — limits are
   never silently skipped.

## Configuration

Environment variables (with defaults):

| Variable | Default |
|----------|---------|
| `PORT` | `8080` |
| `DATABASE_URL` | `postgres://multica:multica@localhost:5432/multica?sslmode=disable`; empty ⇒ no-DB mode |
| `APP_ENV` | `development` (`production` refuses to boot without `JWT_SECRET`) |
| `JWT_SECRET` | random dev secret (generated on boot; production requires it) |
| `MULTICA_DEV_VERIFICATION_CODE` | none — when set to a 6-digit code, `verify-code` accepts it |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | none — `/auth/google` returns 503 without them |
| `RESEND_API_KEY` / `RESEND_FROM_EMAIL` | none / `noreply@1person.app` — email delivery for login codes |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3000,http://localhost:5173,http://localhost:5174` |

## Testing

- `zig build test` — unit tests (37 pass / 19 skip, no DB required)
- `scripts/smoke_test.sh` — no-DB health/auth/workspace flow
- `scripts/integration.mjs` — mirrors frontend client.ts call patterns (30 checks)
- `scripts/*_e2e.sh` — 30 module suites (no-DB, in-memory state)

## Notes

- API response shapes follow the Go server (bare resources); the frontend
  `ApiClient` unwraps the single-key `{data: ...}` envelope zserver also emits.
- `daemon:task_available` WS push is wired (see `src/daemon_notify.zig`);
  daemons can still fall back to HTTP claim.
- Modules with external-service semantics (cloud runtime exec, connector
  calls, blockchain transactions, notification delivery, media file storage)
  keep in-memory/mock implementations — wiring real providers is a product
  decision, not a code gap.
