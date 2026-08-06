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

Modules with intentional in-memory/demo implementations (no DB table or Go
counterpart exists): billing, blockchain, commission, community_ops,
compliance, connector, content_matrix, i18n, notification, pipeline, referral,
scheduler, task_queue_v2, token_economy, training, wallet — these run fully in
no-DB mode and are zserver-specific features.

## Quick start

```bash
cd zserver
zig build
./zig-out/bin/zserver server --port 8080        # no-DB mode (in-memory state)
DATABASE_URL=postgres://... ./zig-out/bin/zserver migrate
DATABASE_URL=postgres://... ./zig-out/bin/zserver server --port 8080
```

Run tests:

```bash
zig build test                # unit tests
./scripts/smoke_test.sh       # 12 no-DB health/auth/workspace checks
node scripts/integration.mjs http://127.0.0.1:18099   # frontend call-pattern checks
scripts/<module>_e2e.sh       # 30 per-module e2e suites
```

## CLI

Uses `zcli` (cloned into `../zig_ws/zcli`):

```bash
zserver server [--port PORT] [--db-url URL]
zserver migrate [--db-url URL]
zserver version               # version injected from build.zig.zon (-Dcommit=...)
```

## Web framework

Uses `zfinal` (cloned into `../zig_ws/zfinal`, v0.21.x). Two framework fixes
from early zserver work live in the zfinal checkout:

1. **RouteGroup path parameters** — `parseRoute` stored slices into the
   temporary route string, causing use-after-free. Fixed by duplicating
   segment and parameter-name strings.
2. **Missing `patch` on `RouteGroup`** — added `RouteGroup.patch`.

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
