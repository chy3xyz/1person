# zserver

Zig 0.17 rewrite of the Multica Go server (`server/`).

## Status

This is a functional skeleton that mirrors the Go server's route surface. Most
endpoints are currently stubs returning `501 Not Implemented`; health and
public config are implemented.

## Quick start

```bash
cd zserver
zig build
./zig-out/bin/zserver server --port 8080
```

Run tests:

```bash
zig build test
```

## CLI

Uses `zcli` (cloned into `../zig_ws/zcli`):

```bash
zserver server [--port PORT] [--db-url URL]
zserver version
```

## Web framework

Uses `zfinal` (cloned into `../zig_ws/zfinal`). Two framework bugs were found
and fixed locally:

1. **RouteGroup path parameters** — `parseRoute` stored slices into the
   temporary route string, causing use-after-free for routes registered via
   `RouteGroup`. Fixed by duplicating segment and parameter-name strings.
2. **Missing `patch` on `RouteGroup`** — added `RouteGroup.patch`.

Both fixes are in `../zig_ws/zfinal/src/core/zfinal.zig` and
`../zig_ws/zfinal/src/core/router.zig`.

## Project layout

| File | Purpose |
|------|---------|
| `src/main.zig` | CLI entry point (`zcli`) |
| `src/server.zig` | HTTP server lifecycle (`zfinal`) |
| `src/config.zig` | Environment-based configuration |
| `src/router.zig` | Route registration mirroring Go Chi router |
| `src/middleware.zig` | CORS and request logging interceptors |
| `src/health.zig` | `/health`, `/readyz` handlers |
| `src/handlers/config.zig` | `/api/config` handler |
| `src/handlers/stub.zig` | Generic 501 stub for unimplemented routes |
| `src/router_test.zig` | Regression tests for route matching |

## Configuration

Environment variables (with defaults):

| Variable | Default |
|----------|---------|
| `PORT` | `8080` |
| `DATABASE_URL` | `postgres://multica:multica@localhost:5432/multica?sslmode=disable` |
| `APP_ENV` | `development` |
| `JWT_SECRET` | *(none — warning logged)* |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3000,http://localhost:5173,http://localhost:5174` |

## Next steps

- Replace stub handlers with real implementations
- Add PostgreSQL/SQLite database layer
- Implement JWT authentication middleware
- Add WebSocket support
- Port remaining middleware (request ID, rate limit, panic recovery)
