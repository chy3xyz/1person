# zserver 95% Go-alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement this plan track-by-track. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Zig rewrite `zserver/` to functional parity with the Go backend `server/` on route coverage, auth model, workspace authorization, realtime, and DB/Redis integration, so that existing web/mobile clients can run against it with minimal behavioral differences.

**Architecture:**
1. Extend `zfinal` with reusable infrastructure: a PostgreSQL connection pool, a minimal Redis RESP client, and a WebSocket manager with room/pub-sub support.
2. Rewrite `zserver` middleware to match Go's auth/workspace/rate-limit layers.
3. Implement the critical-path handlers (auth, me, workspaces, invitations, tokens) against real Postgres tables.
4. Build a `/ws` realtime hub that mirrors Go's subscription/auth/event model.
5. Provide safe generic CRUD fallbacks for the remaining product domains so they return valid shapes instead of `501`.
6. Add operational parity: migration readiness, trusted-proxy IP parsing, structured logging, and cookie security.

**Tech Stack:** Zig 0.17, `zfinal`, `zcli`, `libpq`, Redis RESP over TCP, `std.http.Server.WebSocket` upgrade, in-memory maps for optional no-DB smoke testing.

---

## Reference Material

- Go backend root: `server/`
- Zig rewrite root: `zserver/`
- Schema & contracts: See the alignment reference produced by `agent-2` (Go table/column definitions, request/response shapes, SQL).
- Key Go files to mirror:
  - `server/internal/handler/auth.go`
  - `server/internal/handler/user.go`
  - `server/internal/handler/onboarding.go`
  - `server/internal/handler/workspace.go`
  - `server/internal/handler/invitation.go`
  - `server/internal/handler/personal_access_token.go`
  - `server/internal/middleware/auth.go`
  - `server/internal/middleware/workspace.go`
  - `server/internal/middleware/ratelimit.go`
  - `server/internal/realtime/hub.go`
  - `server/internal/realtime/broadcaster.go`
  - `server/pkg/protocol/events.go`
  - `server/pkg/db/queries/*.sql`

---

## File Map

### zfinal additions

| File | Responsibility |
|------|----------------|
| `../zig_ws/zfinal/src/db/pg_pool.zig` | PostgreSQL connection pool: `init/deinit`, `acquire/release`, health check. |
| `../zig_ws/zfinal/src/redis/client.zig` | Minimal Redis client: TCP connect, RESP encode/decode, `GET/SET/DEL/EXPIRE/PUBLISH/SUBSCRIBE/UNSUBSCRIBE`. |
| `../zig_ws/zfinal/src/websocket/manager.zig` | Existing file; extend with room registry, `subscribe/unsubscribe`, `broadcast`, per-connection metadata. |
| `../zig_ws/zfinal/src/core/context.zig` | Add `upgradeWebSocket()` helper if missing. |

### zserver additions/changes

| File | Responsibility |
|------|----------------|
| `zserver/src/db.zig` | Replace single-connection `Db` with pool wrapper; keep `Conn`/`Result` API. |
| `zserver/src/redis.zig` | App-level Redis wrapper + pubsub listener fiber. |
| `zserver/src/config.zig` | Add `redis_url`, `cookie_domain`, `auth_token_ttl`, `rate_limit_auth`, `rate_limit_auth_verify`, `trusted_proxies`. |
| `zserver/src/middleware.zig` | Add cookie auth, CSRF, rate limiting, workspace resolution/role middleware. |
| `zserver/src/middleware/workspace.zig` | Workspace slug/ID resolution and role enforcement. |
| `zserver/src/middleware/ratelimit.zig` | Redis fixed-window rate limiter. |
| `zserver/src/auth.zig` | PAT/task-token/daemon-token validation helpers; cookie signing. |
| `zserver/src/handlers/auth.zig` | Full send-code/verify-code/google/logout with DB + cookies + rate limit. |
| `zserver/src/handlers/user.zig` | Full `/api/me`, onboarding, cloud-waitlist with validation. |
| `zserver/src/handlers/token.zig` | `/api/tokens` CRUD + renew. |
| `zserver/src/handlers/workspace.zig` | Full workspace CRUD + member/role/leave. |
| `zserver/src/handlers/invitation.zig` | `/api/invitations/*` and workspace invitation revocation. |
| `zserver/src/handlers/realtime.zig` | `/ws` hub handler: auth, subscribe, ping/pong, room broadcast. |
| `zserver/src/handlers/crud.zig` | Generic CRUD helpers for product domains. |
| `zserver/src/handlers/*.zig` (new) | One file per product domain with list/get/create/update/delete stubs returning valid shapes. |
| `zserver/src/router.zig` | Wire all implemented handlers; remove stubs where real handlers exist. |
| `zserver/src/server.zig` | Initialize pool, Redis, realtime listener. |
| `zserver/src/health.zig` | Add migration readiness to `/readyz`. |

---

## Track A: zfinal Infrastructure

### Task A1: PostgreSQL connection pool in zfinal

**Files:**
- Create: `../zig_ws/zfinal/src/db/pg_pool.zig`
- Modify: `../zig_ws/zfinal/src/main.zig`

- [ ] **Step 1: Design the pool API**

```zig
const std = @import("std");
const Conn = @import("../db.zig").Conn; // re-export from zserver if needed

pub const PgPool = struct {
    allocator: std.mem.Allocator,
    conninfo: [:0]const u8,
    min: usize,
    max: usize,
    conns: std.ArrayList(*Conn),
    available: std.ArrayList(*Conn),
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,

    pub fn init(allocator, conninfo, min, max) !PgPool;
    pub fn deinit(self: *PgPool) void;
    pub fn acquire(self: *PgPool) !*Conn;
    pub fn release(self: *PgPool, conn: *Conn) void;
    pub fn healthCheck(self: *PgPool) bool;
};
```

- [ ] **Step 2: Implement acquire/release with blocking wait when exhausted**

Use `std.Io.Mutex` + `std.Io.Condition`. On acquire, return an available connection or create one up to `max`. On release, push back and signal.

- [ ] **Step 3: Export `PgPool` from `zfinal/src/main.zig`**

```zig
pub const PgPool = @import("db/pg_pool.zig").PgPool;
```

- [ ] **Step 4: Add unit test** (compile-only is acceptable for this Zig version)

```bash
cd ../zig_ws/zfinal && zig build test
```

---

### Task A2: Minimal Redis RESP client in zfinal

**Files:**
- Create: `../zig_ws/zfinal/src/redis/client.zig`
- Modify: `../zig_ws/zfinal/src/main.zig`

- [ ] **Step 1: Define the client API**

```zig
pub const RedisClient = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    read_buf: [4096]u8,

    pub fn connect(allocator, host, port) !RedisClient;
    pub fn deinit(self: *RedisClient) void;
    pub fn get(self: *RedisClient, key) !?[]const u8;
    pub fn set(self: *RedisClient, key, value, ttl_seconds: ?u32) !void;
    pub fn del(self: *RedisClient, key) !void;
    pub fn publish(self: *RedisClient, channel, message) !void;
    pub fn subscribe(self: *RedisClient, channel) !void;
    pub fn unsubscribe(self: *RedisClient, channel) !void;
    pub fn readResponse(self: *RedisClient) !Value; // RESP Value enum
};
```

- [ ] **Step 2: Implement RESP encoder/decoder for `+`, `-`, `:`, `$`, `*`, arrays, bulk strings**

- [ ] **Step 3: Export `RedisClient` from `zfinal/src/main.zig`**

```zig
pub const RedisClient = @import("redis/client.zig").RedisClient;
```

---

### Task A3: Extend zfinal WebSocket manager with rooms

**Files:**
- Modify: `../zig_ws/zfinal/src/websocket/manager.zig`
- Modify: `../zig_ws/zfinal/src/core/context.zig` (optional helper)

- [ ] **Step 1: Add per-connection metadata and room registry**

```zig
pub const Connection = struct {
    ws: WebSocket,
    rooms: std.StringHashMap(void),
    user_id: ?[]const u8,
};

pub fn register(self: *WebSocketManager, ws: *WebSocket) !*Connection;
pub fn subscribe(conn: *Connection, room: []const u8) !void;
pub fn unsubscribe(conn: *Connection, room: []const u8) !void;
pub fn broadcast(self: *WebSocketManager, room: []const u8, message: []const u8) !void;
pub fn broadcastAll(self: *WebSocketManager, message: []const u8) !void;
```

- [ ] **Step 2: Keep thread-safe with `std.Io.Mutex`**

---

## Track B: zserver Core Integration

### Task B1: Replace per-request DB with pool

**Files:**
- Modify: `zserver/src/db.zig`
- Modify: `zserver/src/server.zig`
- Modify: `zserver/src/router.zig`
- Modify all handlers to accept `*zfinal.PgPool` instead of `?*db.Db`

- [ ] **Step 1: Change `db.zig` `Db` struct to wrap `zfinal.PgPool`**

```zig
pub const Db = struct {
    pool: *zfinal.PgPool,
    pub fn connect(self: *Db) !Conn {
        return Conn{ .pg = try self.pool.acquire(), .allocator = ??? };
    }
    pub fn release(self: *Db, conn: *Conn) void {
        self.pool.release(conn.pg);
    }
};
```

- [ ] **Step 2: Update `server.zig` to initialize the pool when DB URL works**

```zig
var pool = zfinal.PgPool.init(allocator, cfg.db_url, 2, 10) catch |err| {
    log.warn("DB pool unavailable: {}", .{err});
    break :blk null;
};
defer if (pool) |*p| p.deinit();
```

- [ ] **Step 3: Pass pool pointer to handlers via `init()`**

---

### Task B2: Workspace middleware

**Files:**
- Create: `zserver/src/middleware/workspace.zig`
- Modify: `zserver/src/router.zig`

- [ ] **Step 1: Implement workspace resolution priority**

Priority:
1. `X-Workspace-ID` header
2. `?workspace_id=<uuid>` query
3. `X-Workspace-Slug` header
4. `?workspace_slug=<slug>` query
5. URL path param `:id` for `/api/workspaces/:id/*`

- [ ] **Step 2: Implement role middleware as zfinal interceptors**

```zig
pub fn requireWorkspaceMember(ctx: *zfinal.Context) !bool;
pub fn requireWorkspaceRole(min_role: []const u8) zfinal.Interceptor;
```

Store resolved workspace id and member role in `ctx.attributes` with allocated keys.

- [ ] **Step 3: Add `/api/workspaces/*` route group with role interceptors**

---

### Task B3: Cookie + CSRF + rate-limit middleware

**Files:**
- Modify: `zserver/src/middleware.zig`
- Create: `zserver/src/middleware/ratelimit.zig`
- Modify: `zserver/src/auth.zig`

- [ ] **Step 1: Add cookie parsing helpers**

Read `Cookie` header, parse `1person_auth` and `1person_csrf`.

- [ ] **Step 2: Add cookie signing/validation**

`1person_auth`: JWT or PAT token. `1person_csrf`: `nonce.hmac(nonce, authToken)`.

- [ ] **Step 3: Update `AuthInterceptor` to try cookie before bearer and enforce CSRF for state-changing methods**

- [ ] **Step 4: Implement Redis-backed fixed-window rate limiter**

Key format: `mul:ratelimit:<path>:<ip>` where path has `/` replaced with `:` and IP honors `ONEPERSON_TRUSTED_PROXIES`.

---

## Track C: Auth & User Handlers

### Task C1: Verification code DB flow

**Files:**
- Modify: `zserver/src/handlers/auth.zig`

- [ ] **Step 1: Replace in-memory code map with `verification_code` table operations**

Use SQL:
```sql
INSERT INTO verification_code (email, code, expires_at) VALUES ($1, $2, $3) RETURNING id;
SELECT * FROM verification_code WHERE email = $1 AND used = FALSE AND expires_at > now() AND attempts < 5 ORDER BY created_at DESC LIMIT 1;
UPDATE verification_code SET attempts = attempts + 1 WHERE id = $1;
UPDATE verification_code SET used = TRUE WHERE id = $1;
```

- [ ] **Step 2: Add dev override code support**

If `DEV_AUTH_CODE` env is set, allow that code to verify any email (idempotent, mark used).

- [ ] **Step 3: Return Go-compatible `{"message":"Verification code sent"}`**

---

### Task C2: Full login/logout with cookies

**Files:**
- Modify: `zserver/src/handlers/auth.zig`
- Modify: `zserver/src/auth.zig`

- [ ] **Step 1: Build `LoginResponse` with full `UserResponse`**

```zig
const UserResponse = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    avatar_url: ?[]const u8,
    language: ?[]const u8,
    timezone: ?[]const u8,
    onboarded_at: ?[]const u8,
    onboarding_questionnaire: std.json.Value,
    starter_content_state: ?[]const u8,
    profile_description: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};
```

- [ ] **Step 2: Set `1person_auth` and `1person_csrf` cookies on verify-code success**

- [ ] **Step 3: Implement `/auth/logout` clearing cookies and returning `{"message":"logged out"}`**

---

### Task C3: `/api/me` and onboarding

**Files:**
- Modify: `zserver/src/handlers/user.zig`

- [ ] **Step 1: Return `UserResponse` with all fields from `user` table**

- [ ] **Step 2: Validate `language` ∈ {en, zh-Hans, ko, ja}, `timezone` is valid IANA, `profile_description` ≤ 2000 runes**

- [ ] **Step 3: Implement onboarding endpoints**

- `PATCH /api/me/onboarding` → patch `onboarding_questionnaire`.
- `POST /api/me/onboarding/complete` → set `onboarded_at = COALESCE(onboarded_at, now())`.
- `POST /api/me/onboarding/cloud-waitlist` → update `cloud_waitlist_email`, `cloud_waitlist_reason`.

---

### Task C4: Personal access tokens

**Files:**
- Create: `zserver/src/handlers/token.zig`
- Modify: `zserver/src/router.zig`
- Modify: `zserver/src/middleware.zig`

- [ ] **Step 1: Generate `1p_` tokens**

Prefix + random suffix; store `token_hash` and `token_prefix`.

- [ ] **Step 2: Implement `/api/tokens` CRUD + renew**

- `GET /api/tokens` → list non-revoked tokens for user.
- `POST /api/tokens` → create, return raw token once.
- `POST /api/tokens/current/renew` → extend expiry by 90 days if within 7 days.
- `DELETE /api/tokens/:id` → revoke.

- [ ] **Step 3: Update auth middleware to validate `1p_` PATs**

---

## Track D: Workspace, Members, Invitations

### Task D1: Full workspace CRUD

**Files:**
- Modify: `zserver/src/handlers/workspace.zig`

- [ ] **Step 1: Use workspace middleware for access control**

Remove inline `requireAccess`; rely on interceptor setting `workspace_id`/`workspace_role`.

- [ ] **Step 2: Add reserved-slug check and slug uniqueness conflict handling**

- [ ] **Step 3: Match Go response shape exactly**

Empty `settings` → `{}`, empty `repos` → `[]`, empty `description`/`context`/`avatar_url` → JSON `null`.

---

### Task D2: Member management

**Files:**
- Modify: `zserver/src/handlers/workspace.zig`

- [ ] **Step 1: `POST /api/workspaces/:id/members` creates an invitation**

If invitee already has a user record, set `invitee_user_id`; otherwise `NULL`.

- [ ] **Step 2: `PATCH /api/workspaces/:id/members/:memberId` updates role**

Enforce owner rules and at-least-one-owner guard.

- [ ] **Step 3: `DELETE /api/workspaces/:id/members/:memberId` removes member**

Trigger revocation cascade (runtimes, agents, tasks, daemon tokens) — implement as best-effort deletions/updates.

- [ ] **Step 4: `POST /api/workspaces/:id/leave`**

Same cascade as delete.

---

### Task D3: Invitations endpoints

**Files:**
- Create: `zserver/src/handlers/invitation.zig`
- Modify: `zserver/src/router.zig`

- [ ] **Step 1: `GET /api/invitations`**

List pending invitations for current user with `workspace_name`, `inviter_name`, `inviter_email`.

- [ ] **Step 2: `GET /api/invitations/:id`**

Must belong to current user by email or `invitee_user_id`.

- [ ] **Step 3: `POST /api/invitations/:id/accept`**

Creates member, sets invitation `accepted`, idempotently marks user onboarded.

- [ ] **Step 4: `POST /api/invitations/:id/decline`**

Sets `declined`, returns `204`.

- [ ] **Step 5: `DELETE /api/workspaces/:id/invitations/:invitationId`**

Requires owner/admin, deletes pending invitation, returns `204`.

---

## Track E: Realtime Hub

### Task E1: `/ws` auth and subscriptions

**Files:**
- Modify: `zserver/src/handlers/realtime.zig`
- Modify: `zserver/src/redis.zig`

- [ ] **Step 1: After handshake, wait for auth frame or validate cookie/query token**

```json
{"type":"auth","payload":{"token":"..."}}
```

Reply `{"type":"auth_ack"}` or `{"error":"..."}` and close.

- [ ] **Step 2: Handle `subscribe`/`unsubscribe` frames**

Authorize scopes:
- `workspace` / `user`: must match own identity.
- `task` / `chat`: check task/chat session belongs to workspace and caller has access.

Reply `subscribe_ack` or `subscribe_error`.

- [ ] **Step 3: Handle `ping` → `{"type":"pong"}`**

---

### Task E2: Redis pub-sub relay

**Files:**
- Modify: `zserver/src/redis.zig`
- Modify: `zserver/src/server.zig`

- [ ] **Step 1: On server start, spawn a fiber that subscribes to Redis channel `mul:events:broadcast`**

- [ ] **Step 2: On incoming Redis message, parse `{room, payload}` and broadcast to local room subscribers**

- [ ] **Step 3: When server generates events, publish them to Redis**

Use `PUBLISH mul:events:broadcast <json>`.

---

## Track F: Generic Product-Domain CRUD

### Task F1: Generic CRUD helper

**Files:**
- Create: `zserver/src/handlers/crud.zig`

- [ ] **Step 1: Build `CrudHandler` struct**

```zig
pub const CrudHandler = struct {
    table: []const u8,
    columns: []const []const u8,
    list_query: []const u8,
    get_query: []const u8,
    create_query: []const u8,
    update_query: []const u8,
    delete_query: []const u8,
    response_shape: type,

    pub fn list(ctx: *zfinal.Context) !void;
    pub fn get(ctx: *zfinal.Context) !void;
    pub fn create(ctx: *zfinal.Context) !void;
    pub fn update(ctx: *zfinal.Context) !void;
    pub fn delete(ctx: *zfinal.Context) !void;
};
```

- [ ] **Step 2: Use JSONB columns via `PQexecParams` with text params**

---

### Task F2: Implement remaining domains

**Files:**
- Create per domain: `zserver/src/handlers/issues.zig`, `projects.zig`, `labels.zig`, `squads.zig`, `agents.zig`, `skills.zig`, `chat.zig`, `inbox.zig`, `autopilots.zig`, `tasks.zig`, `comments.zig`, `attachments.zig`, `runtimes.zig`, `dashboard.zig`, `cloud_billing.zig`
- Modify: `zserver/src/router.zig`

- [ ] **Step 1: For each domain, define minimal request/response structs matching Go**

- [ ] **Step 2: Wire list/get/create/update/delete routes to real handlers**

- [ ] **Step 3: Where exact SQL is trivial, query the table; where business logic is complex, return empty arrays / 404 / deterministic stub that matches shape**

- [ ] **Step 4: Cloud billing proxies to upstream fleet URL via HTTP client when configured, else returns stub**

---

## Track G: Operational Parity

### Task G1: `/readyz` migration check

**Files:**
- Modify: `zserver/src/health.zig`
- Modify: `zserver/src/db.zig`

- [ ] **Step 1: Query `SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1`**

- [ ] **Step 2: Compare against the latest migration file in `server/migrations/` (embed or hardcode)**

- [ ] **Step 3: Return 503 if DB or migration is behind, else 200 `{"status":"ready"}`**

---

### Task G2: Trusted proxies + structured logging

**Files:**
- Modify: `zserver/src/middleware.zig`
- Modify: `zserver/src/config.zig`

- [ ] **Step 1: Parse `ONEPERSON_TRUSTED_PROXIES` and use it for `X-Forwarded-For` IP extraction in rate limiting**

- [ ] **Step 2: Log structured request/response with request ID, user ID, method, path, status, duration**

---

### Task G3: CSP / security headers

**Files:**
- Modify: `zserver/src/middleware.zig`

- [ ] **Step 1: Add security headers interceptor**

Set `Content-Security-Policy`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy`.

---

## Track H: Verification & Migration

### Task H1: Automated smoke test suite

**Files:**
- Create: `zserver/scripts/smoke_test.sh`

- [ ] **Step 1: Script exercises health, config, auth flow, /api/me, workspace CRUD, invitations, /ws echo**

- [ ] **Step 2: Exit non-zero on any mismatch**

---

### Task H2: Unit tests for new modules

**Files:**
- Create/modify tests alongside new `zserver/src/` modules.

- [ ] **Step 1: Test JWT round-trip, cookie signing, slug validation, rate-limit key, room broadcast**

- [ ] **Step 2: Run `zig build test` and ensure all pass**

---

## Acceptance Criteria

- `zig build test` passes.
- `zserver/scripts/smoke_test.sh` passes against a local Postgres + Redis.
- All routes in `zserver/src/router.zig` are wired to real handlers (no `stub.notImplemented` for critical paths; generic stubs acceptable for product domains).
- `/api/me`, `/api/workspaces/*`, `/api/invitations/*`, `/api/tokens/*`, `/auth/*`, `/ws` match Go request/response contracts in the reference summary.
- `/readyz` reflects migration state.
- Cookie + bearer auth both work; CSRF enforced for cookie state-changing requests.
- Rate limiting is Redis-backed.
- WebSocket supports auth, subscribe, and cross-instance broadcast via Redis.

## Execution Order

1. **Track A** (zfinal infra) — unblocks everything else.
2. **Track B** (zserver core integration) — pool, Redis, workspace/auth middleware.
3. **Track C + D** in parallel once B is done.
4. **Track E** after C/D.
5. **Track F** in parallel batches after B.
6. **Track G + H** last.
