# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Conventions reference

The single source of truth for **code naming, the i18n translation glossary, and the Chinese voice guide** is the docs site:

- **`frontend/apps/docs/content/docs/developers/conventions.mdx`** (English)
- **`frontend/apps/docs/content/docs/developers/conventions.zh.mdx`** (Chinese)

Read that page before:

- Writing or editing translations (`frontend/packages/views/locales/`)
- Naming a new route, package, file, DB column, or TS type
- Writing Chinese product copy (UI strings, error messages, docs)

The legacy `frontend/packages/views/locales/glossary.md` is now a stub redirecting to the docs page; do not rely on it.

## Project Context

1Person is an AI-native task management platform — like Linear, but with AI agents as first-class citizens.

- Agents can be assigned issues, create issues, comment, and change status
- Supports local (daemon) and cloud agent runtimes
- Built for 2-10 person AI-native teams

## Architecture

**Monorepo layout:** root Makefile and shared `scripts/`; `frontend/` (pnpm workspaces + Turborepo); `backend/zserver/` (Zig, zfinal). Shared packages live under `frontend/packages/`.

- `backend/zserver/` — Zig backend (zfinal framework; canonical backend; migrations live in backend/zserver/migrations/)
- `frontend/apps/web/` — Next.js frontend (App Router)
- `frontend/apps/desktop/` — Electron desktop app (electron-vite)
- `frontend/apps/mobile/` — Expo / React Native iOS app. See `frontend/apps/mobile/CLAUDE.md`.
- `frontend/packages/core/` — Headless business logic (zero react-dom)
- `frontend/packages/ui/` — Atomic UI components (zero business logic)
- `frontend/packages/views/` — Shared business pages/components (zero next/* imports, zero react-router imports)
- `frontend/packages/tsconfig/` — Shared TypeScript configuration

What lives where for sharing purposes is documented in *Sharing Principles* below — read it once.

### Key Architectural Decisions

**Internal Packages pattern** — all shared packages export raw `.ts`/`.tsx` files (no pre-compilation). The consuming app's bundler compiles them directly. This gives zero-config HMR and instant go-to-definition.

**Dependency direction:** `views/ → core/ + ui/`. Core and UI are independent of each other. No package imports from `next/*`, `react-router-dom`, or app-specific code.

**Platform bridge:** `frontend/packages/core/platform/` provides `CoreProvider` — initializes API client, auth/workspace stores, WS connection, and QueryClient. Each app wraps its root with `<CoreProvider>` and provides its own `NavigationAdapter` for routing.

**pnpm catalog** — `frontend/pnpm-workspace.yaml` defines `catalog:` for version pinning. All shared deps use `catalog:` references to guarantee a single version across all packages. When adding new shared deps (including test deps), add to catalog first.

### State Management

The architecture relies on a strict split between server state and client state. Mixing them is the most common way to break it.

- **TanStack Query owns all server state.** Issues, users, workspaces, inbox — anything fetched from the API lives in the Query cache. WS events keep it fresh via invalidation; no polling, no `staleTime` workarounds.
- **Zustand owns all client state.** UI selections, filters, drafts, modal state, navigation history. Stores live in `frontend/packages/core/` (never in `frontend/packages/views/`) so they're shared.
- **React Context** is reserved for cross-cutting platform plumbing — `WorkspaceIdProvider`, `NavigationProvider`. Don't reach for it for general state.
- **Auth and workspace stores are the only stores allowed to call `api.*` directly**, because they manage critical state that must exist before queries can run. They're created via factory + injected dependencies, registered by the platform layer.

**Hard rules — these are how the architecture stays coherent:**

- **Never duplicate server data into Zustand.** If it came from the API, it belongs in the Query cache. Copying it into a store creates two sources of truth and they will drift.
- **Workspace-scoped queries must key on `wsId`.** This is what makes workspace switching automatic — the cache key changes, the right data appears, no manual invalidation needed.
- **Mutations are optimistic by default.** Apply the change locally, send the request, roll back on failure, invalidate on settle. The user shouldn't wait for the server.
- **WS events invalidate queries — they never write to stores directly.** This keeps the cache as the single source of truth and avoids race conditions.
- **Persist what's worth preserving across restarts** (user preferences, drafts, tab layout). **Don't persist ephemeral UI state** (modal open/close, transient selections) or server data.

**Common Zustand footguns to avoid:**

- Selectors must return stable references. Returning a freshly built object or array on every call (e.g. `s => ({ a: s.a, b: s.b })` or `s => s.items.map(...)`) triggers infinite re-renders. Either select primitives separately or use shallow comparison.
- Hooks that need workspace context should accept `wsId` as a parameter, not call `useWorkspaceId()` internally — this lets them work outside the `WorkspaceIdProvider` (e.g. in a sidebar that renders before workspace is loaded).

## Sharing Principles

The monorepo splits into two share zones:

- **Web and desktop** share business logic, components, hooks, stores, and views through `frontend/packages/core/`, `frontend/packages/ui/`, and `frontend/packages/views/`. Existing model — keep using it.
- **Mobile (`frontend/apps/mobile/`) is independent.** It shares only **types and pure functions** from `@1person/core/`, with `import type` for types (zero runtime coupling). UI, state, hooks, providers, i18n, React version, build pipeline, release cadence — all mobile-owned.

Mobile is locked to the React version that Expo SDK / React Native ships (which lags React main by 6-12 months). Coupling mobile to the root `catalog:` React would block mobile from upgrading on its own schedule.

See `frontend/apps/mobile/CLAUDE.md` for the mobile rules and tech-stack baseline.

## Commands

```bash
# One-command dev (auto-setup + start everything)
make dev              # Auto-creates env, installs deps, starts DB, migrates, launches app

# Explicit setup & run (if you prefer separate steps)
make setup            # First-time: ensure shared DB, create app DB, migrate
make start            # Start backend + frontend together
make stop             # Stop app processes for the current checkout
make db-down          # Stop the shared PostgreSQL container

# Frontend (all commands go through Turborepo)
pnpm --dir frontend install
pnpm --dir frontend dev:web          # Next.js dev server (port 3000)
pnpm --dir frontend dev:desktop      # Electron dev (electron-vite, HMR)
pnpm --dir frontend build            # Build all frontend apps
pnpm --dir frontend typecheck        # TypeScript check (all packages + apps via turbo)
pnpm --dir frontend lint             # ESLint
pnpm --dir frontend test             # TS tests (Vitest, all packages + apps via turbo)

# Backend (zserver — Zig)
make server           # Run zserver only (port 8080)
make daemon           # Restart the local agent daemon via the Zig 1p CLI
make build            # Build zserver + the Zig 1p CLI
make cli ARGS="..."   # Run the Zig 1p CLI (e.g. make cli ARGS="config")
make test             # zserver (Zig) unit tests
make migrate-up       # Apply database migrations (zserver migrate)
make migrate-down     # Rollback not supported by zserver; use make db-reset

# Run a single TS test (works for any package with a test script)
pnpm --dir frontend --filter @1person/views exec vitest run auth/login-page.test.tsx
pnpm --dir frontend --filter @1person/core exec vitest run runtimes/version.test.ts
pnpm --dir frontend --filter @1person/web exec vitest run app/\(auth\)/login/page.test.tsx

# Run a single zserver (Zig) test / unit tests
cd backend/zserver && zig build test

# Run a single E2E test (requires backend + frontend running)
pnpm --dir frontend exec playwright test e2e/tests/specific-test.spec.ts

# Mobile (Expo) — two environments only: dev and staging
pnpm --dir frontend dev:mobile                  # Metro, dev env       (reads frontend/apps/mobile/.env.development.local)
pnpm --dir frontend dev:mobile:staging          # Metro, staging env   (reads frontend/apps/mobile/.env.staging)
pnpm --dir frontend ios:mobile                  # Native build + install dev-client to iOS Simulator, dev env
pnpm --dir frontend ios:mobile:staging          # Native build + install dev-client to iOS Simulator, staging env
pnpm --dir frontend ios:mobile:device           # Native build + install dev-client to USB iPhone, dev env
pnpm --dir frontend ios:mobile:device:staging   # Native build + install dev-client to USB iPhone, staging env
# Daily flow: run `pnpm --dir frontend dev:mobile:staging` (or :dev). Only re-run `ios:mobile*` when
# native code or any expo-*/react-native-* dependency changes (lockfile drift counts).

# Desktop build & package
pnpm --dir frontend --filter @1person/desktop build      # Compile TS → JS (reads .env.production)
pnpm --dir frontend --filter @1person/desktop package    # Package into .app/.dmg/.exe (current platform only)

# shadcn — config lives in frontend/packages/ui/components.json (Base UI variant, base-nova style)
pnpm --dir frontend ui:add badge                # Adds component to frontend/packages/ui/components/ui/

# Infrastructure
make db-up            # Start shared PostgreSQL (pgvector/pg17 image)
make db-down          # Stop shared PostgreSQL
make db-reset         # Drop + recreate current env's DB, then re-run migrations (local only; stop backend first)
```

### CI Requirements

CI runs on Node 22 with a `pgvector/pgvector:pg17` PostgreSQL service. zserver (Zig 0.17) is built via `zserver-ci.yml` / `migrate.yml`. See `.github/workflows/ci.yml`.

### Worktree Support

All checkouts share one PostgreSQL container. Isolation is at the database level — each worktree gets its own DB name and unique ports via `.env.worktree`. Main checkouts use `.env`.

`make dev` auto-detects worktrees and handles everything. For explicit control:

```bash
make worktree-env       # Generate .env.worktree with unique DB/ports
make setup-worktree     # Setup using .env.worktree
make start-worktree     # Start using .env.worktree
```

## Coding Rules

- TypeScript strict mode is enabled; keep types explicit.
- Zig code follows the zserver conventions (zfinal framework idioms, standard library style).
- Keep comments in code **English only**.
- Prefer existing patterns/components over introducing parallel abstractions.
- Unless the user explicitly asks for backwards compatibility, do **not** add compatibility layers, fallback paths, dual-write logic, legacy adapters, or temporary shims **for internal, non-boundary code** (a function calling another function in the same package, a component reading its own state, a store helper, etc.).
- This rule does **not** apply at API boundaries: the desktop app cannot assume the backend it talks to has the same shape as the one it was built against (older desktop installs will outlive any given server build). API response handling must follow the rules in **API Response Compatibility** below — that is a defensive boundary, not a legacy shim.
- If a flow or API is being replaced and the product is not yet live, prefer removing the old path instead of preserving both old and new behavior.
- Avoid broad refactors unless required by the task.
- New global (pre-workspace) routes MUST use a single word (`/login`, `/inbox`) or a `/{noun}/{verb}` pair (`/workspaces/new`). NEVER add hyphenated word-group root routes (`/new-workspace`, `/create-team`) — they collide with common user workspace names and force endless reserved-slug audits. Reserving the noun (`workspaces`) automatically protects the entire `/workspaces/*` subtree.
- The reserved-slug list lives in **one** place: `backend/zserver/src/modules/workspace/reserved_slugs.json` (embedded by the Zig backend). `frontend/packages/core/paths/reserved-slugs.ts` is generated from it by `pnpm --dir frontend generate:reserved-slugs`. Edit the JSON, run the generator, commit both. CI re-runs the generator and fails on any drift, so a stale TS file cannot land.
- When you change a CLI command or flag, an API request/response field, or product behavior that a built-in skill documents (`backend/zserver/src/modules/skill/builtin_skills/*`), update that skill's `SKILL.md` **and** its `references/*-source-map.md` in the same PR. The built-in skills are source-traced contracts shipped to agents — if the code moves and the skill doesn't, it silently teaches stale behavior.

### API Response Compatibility

The desktop app installed on a user's machine is older than any backend it talks to: a user on 0.2.26 will hit a server running 0.3.x, then 0.4.x, then beyond. Every response shape is a contract that **will** drift, and the frontend must survive drift without white-screening. Three concrete incidents already happened from violating this — #2143, #2147, #2192.

When writing code that consumes an API response, follow these rules:

- **Parse, don't cast.** Untyped JSON crossing the network is not `T`. Use `parseWithFallback` in `frontend/packages/core/api/schema.ts` with a `zod` schema and an explicit fallback. On validation failure it logs a warning and returns the fallback; it never throws into the UI.
- **No bare `as` casts on response bodies.** Every endpoint method whose response is consumed by UI logic must run through a schema before returning.
- **Optional-chain and default everywhere downstream.** Treat every field as possibly missing. Use explicit boolean checks (`=== true`) over truthy/falsy negation, which silently treats `undefined` and `null` as `false`.
- **Don't pin a UI affordance to a single backend field.** If a button or indicator depends on exactly one boolean from the server, a backend bug deletes it. Combine signals (cursor presence, page length, etc.) so the affordance stays available in the worst case.
- **Enum drift downgrades, not crashes.** A new server-side enum value should render a generic fallback. `switch` statements on server-driven strings must have a `default` branch.
- **When you add or change an endpoint:** add the schema in the same PR, and write at least one test that feeds a malformed response through it (missing field, wrong type, `null` array). The test fails closed if a future change breaks the contract.

This is not premature defense — it is the *only* defense for an installed-app architecture. CSR-only browser apps can ship a fix in minutes; an Electron build sitting on a developer's laptop cannot.

### Backend Handler Conventions (zserver)

Handlers live in `backend/zserver/src/modules/<domain>/handler.zig` and delegate to
`service.zig` (business logic) + `model.zig` (DB access). Core rules:

- Path params are parsed via `response.parseStringId(ctx, "id")`; resource
  lookups go through the domain model (never trust raw URL strings).
- Workspace context comes from the `X-Workspace-ID` / `X-Workspace-Slug`
  headers via `requireWorkspaceId(ctx)` + the workspace middleware.
- Auth is enforced by interceptors (e.g. `RequireWorkspaceMember`) attached
  at route registration in `routes.zig`.
- Write handlers that mutate state MUST publish the matching realtime event
  (e.g. `publishIssueEvent(..., "issue:updated", ...)`) in BOTH the DB and
  in-memory paths — a missing publish silently breaks realtime clients.
- Rate limiting: Redis-backed when `REDIS_URL` is set; the in-memory
  fallback is mutex-protected — never touch the fallback map without the lock.

### Dependency Declaration Rule

Every workspace (`frontend/apps/` and `frontend/packages/` directories) must explicitly declare all directly imported external packages in its own `package.json`. Relying on pnpm hoist to resolve undeclared imports (phantom deps) is prohibited — it causes production build failures when pnpm creates peer-dep variants.

- Use `"pkg": "catalog:"` to reference the shared version from `frontend/pnpm-workspace.yaml`.
- CI enforces this via `eslint-plugin-import-x/no-extraneous-dependencies`.
- Exception: `frontend/apps/mobile/` uses pinned versions (not `catalog:`) for packages tied to its own React/Expo version.

### Package Boundary Rules

These are hard constraints. Violating them breaks the cross-platform architecture:

- `frontend/packages/core/` — zero react-dom, zero localStorage (use StorageAdapter), zero process.env, zero UI libraries. **Shared Zustand stores live here**, even view-related ones (filters, view modes) — stores are pure state, not UI.
- `frontend/packages/ui/` — zero `@1person/core` imports (pure UI, no business logic).
- `frontend/packages/views/` — zero `next/*` imports, zero `react-router-dom` imports, zero stores. Use `NavigationAdapter` for all routing.
- `frontend/apps/web/platform/` — the only place for Next.js APIs (`next/navigation`).
- `frontend/apps/desktop/src/renderer/src/platform/` — the only place for react-router-dom navigation wiring.

### The No-Duplication Rule (web + desktop)

**If the same logic exists in both web and desktop, it must be extracted to a shared package.**

This applies to everything between web and desktop: components, hooks, guards, providers, utility functions. The decision process:

1. Does this code depend on Next.js or Electron APIs? → Keep in the respective app.
2. Does it depend on `react-router-dom` or `next/navigation`? → Keep in app's `platform/` layer.
3. Everything else → belongs in `frontend/packages/core/` (headless logic) or `frontend/packages/views/` (UI components).

When the two apps need different behavior for the same concept (e.g., different loading UI), extract the shared logic into a component with props/slots for the differences. Don't duplicate the logic.

### Cross-Platform Development Rules (web + desktop)

When adding a new page or feature for web/desktop:

1. **New page component** → add to `frontend/packages/views/<domain>/`. Never import from `next/*` or `react-router-dom`.
2. **Wire it in both apps** → add a route in `frontend/apps/web/app/` (Next.js page file) AND in the desktop router. **Exception**: pre-workspace transition flows (create workspace, accept invite) are NOT routes on desktop — they're `WindowOverlay` state. See *Desktop-specific Rules → Route categories*.
3. **Navigation** → use `useNavigation().push()` or `<AppLink>`. Never use framework-specific link/router APIs in shared code.
4. **Shared guards/providers** → use `DashboardGuard` from `frontend/packages/views/layout/`. Don't create separate guard logic per app.
5. **Platform-specific UI** → if a feature is web-only or desktop-only, keep it in the respective app. Use props slots (`extra`, `topSlot`) on shared layout components to inject platform-specific UI.
6. **New hooks that need workspace context** → accept `wsId` as parameter instead of reading from `useWorkspaceId()` Context, so they work both inside and outside `WorkspaceIdProvider`.

### CSS Architecture (web + desktop)

Web and desktop share the same CSS foundation from `frontend/packages/ui/styles/`.

- **Design tokens** → use semantic tokens (`bg-background`, `text-muted-foreground`). Never use hardcoded Tailwind colors (`text-red-500`, `bg-gray-100`).
- **Shared styles** → `frontend/packages/ui/styles/`. Never duplicate scrollbar styling, keyframes, or base layer rules in app CSS.
- **`@source` directives** → both apps scan shared packages so Tailwind sees all class names.

## Mobile-specific Rules

Rules for `frontend/apps/mobile/` live in `frontend/apps/mobile/CLAUDE.md`. Read it before touching anything in `frontend/apps/mobile/` — it covers what may be imported from `@1person/core/`, the React version policy, the build/release pipeline, and the locked tech-stack baseline.

## Desktop-specific Rules

These rules apply to `frontend/apps/desktop/` only. Web has different constraints (URL bar, SSR, no tabs) and doesn't share these concerns. Every rule in this section was added after a concrete bug — treat them as enforced, not suggestions.

### Route categories

Every path in the desktop app falls into exactly one category. Choosing the wrong one reproduces bugs we've already fixed.

- **Session routes** — workspace-scoped pages (`/:slug/issues`, `/:slug/settings`). Rendered by the per-tab memory router under `WorkspaceRouteLayout`. These are legitimate tab destinations.
- **Transition flows** — pre-workspace / one-shot actions (create workspace, accept invite). **NOT routes.** They live as `WindowOverlay` state, dispatched when the navigation adapter sees `push('/workspaces/new')` or `push('/invite/<id>')`. The shared view (`NewWorkspacePage`, `InvitePage`) is the content; the overlay wrapper supplies platform chrome.
- **Error / stale states** — "workspace not available", tabs pointing at a revoked workspace. **NOT pages.** `WorkspaceRouteLayout` auto-heals by dropping the stale tab group from the store; the user never lands on an explicit error screen. Web keeps `NoAccessPage` (shareable URL makes the error state meaningful); desktop has no URL bar so stale = heal silently.

**Adding a new pre-workspace flow on desktop**: register a new `WindowOverlay` type in `stores/window-overlay-store.ts`. Do NOT add it to `routes.tsx`. If a shared view needs the flow on both platforms, add the route on web (`frontend/apps/web/app/(auth)/...`) AND the overlay type on desktop — the shared view component is identical.

### Workspace context

`setCurrentWorkspace(slug, uuid)` from `@1person/core/platform` is the single source of truth for the active workspace. `WorkspaceRouteLayout` sets it on mount; unmount does NOT clear it. Code that leaves workspace context (leave/delete workspace, force-navigate to overlay) must call `setCurrentWorkspace(null, null)` explicitly.

### Workspace destructive operations

Leave / Delete workspace flows must follow this order, otherwise concurrent refetches race and the renderer hard-reloads:

1. Read destination from cached workspace list.
2. `setCurrentWorkspace(null, null)`.
3. `navigation.push(destination)`.
4. THEN `await mutation.mutateAsync(workspaceId)`.

### Tab isolation

Tabs are grouped per workspace in `stores/tab-store.ts`. The TabBar shows only the active workspace's tabs; cross-workspace tab leakage is impossible by construction (no flat global tabs array).

Cross-workspace `push(path)` is detected by the navigation adapter (`platform/navigation.tsx`) and translated into `switchWorkspace(slug, targetPath)` — NOT a navigation within the current tab's router. Don't bypass the adapter; always go through `useNavigation()` from shared code.

### Drag region (macOS)

Every full-window desktop view (anything outside the dashboard shell) must mount `<DragStrip />` from `@1person/views/platform` as the first flex child of the page root, otherwise users can't drag the window. Interactive UI inside the top 48px needs `WebkitAppRegion: "no-drag"` to stay clickable.

## UI/UX Rules

- Prefer shadcn components over custom implementations. Install via `pnpm --dir frontend ui:add <component>` from project root — adds to `frontend/packages/ui/components/ui/`. All components use Base UI primitives (`@base-ui/react`), not Radix.
- Use shadcn design tokens for styling. Avoid hardcoded color values.
- Do not introduce extra state (useState, context, reducers) unless explicitly required by the design.
- Pay close attention to **overflow** (truncate long text, scrollable containers), **alignment**, and **spacing** consistency.
- **If a component is identical between web and desktop, it belongs in a shared package.** Do not copy-paste between apps.

## Testing Rules

### Where to write tests

Tests follow the code, not the app. This is the most important testing principle in this monorepo:

| What you're testing | Where the test lives | Why |
|---|---|---|
| Shared business logic (stores, queries, hooks) | `frontend/packages/core/*.test.ts` | No DOM needed, pure logic |
| Shared UI components (pages, forms, modals) | `frontend/packages/views/*.test.tsx` | jsdom, no framework mocks |
| Platform-specific wiring (cookies, redirects, searchParams) | `frontend/apps/web/*.test.tsx` or `frontend/apps/desktop/` | Needs framework-specific mocks |
| End-to-end user flows | `frontend/e2e/*.spec.ts` | Real browser, real backend |

**Never test shared component behavior in an app's test file.** If a test requires mocking `next/navigation` or `react-router-dom` to test a component from `@1person/views`, the test is in the wrong place — move it to `frontend/packages/views/` and mock `@1person/core` instead.

### Test infrastructure

- `frontend/packages/core/` — Vitest, Node environment (no DOM)
- `frontend/packages/views/` — Vitest, jsdom environment, `@testing-library/react`
- `frontend/apps/web/` — Vitest, jsdom environment, framework-specific mocks
- `frontend/e2e/` — Playwright
- `backend/zserver/` — Zig unit tests (`zig build test`)

All test deps are in the pnpm catalog for unified versioning.

### Mocking conventions

- Mock `@1person/core` stores with `vi.hoisted()` + `Object.assign(selectorFn, { getState })` pattern (Zustand stores are both callable and have `.getState()`).
- Mock `@1person/core/api` for API calls.
- In `frontend/packages/views/` tests: never mock `next/*` or `react-router-dom` — those don't exist here.
- In `frontend/apps/web/` tests: mock framework-specific APIs only for platform-specific behavior.

### TDD workflow

1. Write failing test in the **correct package** first.
2. Write implementation.
3. Run `pnpm --dir frontend test` (Turborepo discovers all packages).
4. Green → done.

### zserver (Zig) tests

Run with `cd backend/zserver && zig build test`. Tests live in `src/**/*_test.zig`
next to the code they exercise; DB-backed tests create their own fixture
data in the target database.

### E2E tests

E2E tests should be self-contained. Use the `TestApiClient` fixture for data setup/teardown:

```typescript
import { loginAsDefault, createTestApi } from "./helpers";
import type { TestApiClient } from "./fixtures";

let api: TestApiClient;

test.beforeEach(async ({ page }) => {
  api = await createTestApi();
  await loginAsDefault(page);
});

test.afterEach(async () => {
  await api.cleanup();
});

test("example", async ({ page }) => {
  const issue = await api.createIssue("Test Issue");
  await page.goto(`/issues/${issue.id}`);
});
```

## Commit Rules

- Use atomic commits grouped by logical intent.
- Conventional format: `feat(scope)`, `fix(scope)`, `refactor(scope)`, `docs`, `test(scope)`, `chore(scope)`.

## Minimum Pre-Push Checks

```bash
make check    # Runs all checks: typecheck, unit tests, zserver tests, E2E
```

Run verification only when the user explicitly asks for it.

For targeted checks when requested:
```bash
pnpm --dir frontend typecheck        # TypeScript type errors only
pnpm --dir frontend test             # TS unit tests only (Vitest, all packages)
make test             # zserver (Zig) tests only
pnpm --dir frontend exec playwright test   # E2E only (requires backend + frontend running)
```

## AI Agent Verification Loop

After writing or modifying code, always run the full verification pipeline:

```bash
make check
```

**Workflow:**
- Write code to satisfy the requirement
- Run `make check`
- If any step fails, read the error output, fix the code, and re-run
- Repeat until all checks pass
- Only then consider the task complete

**Quick iteration:** If you know only TypeScript or Go is affected, run individual checks first for faster feedback, then finish with a full `make check` before marking work complete.

## CLI Release

**Prerequisite:** A CLI release must accompany every Production deployment.

1. Create a tag on the `main` branch: `git tag v0.x.x`
2. Push the tag: `git push origin v0.x.x`
3. GitHub Actions automatically triggers `release.yml`: builds zserver + the Zig `1p` CLI and publishes the CLI to GitHub Releases + Homebrew tap

By default, bump the patch version each release (e.g. `v0.1.12` → `v0.1.13`), unless the user specifies a specific version.

## Multi-tenancy

All queries filter by `workspace_id`. Membership checks gate access. `X-Workspace-ID` header routes requests to the correct workspace.

## Agent Assignees

Assignees are polymorphic — can be a member or an agent. `assignee_type` + `assignee_id` on issues. Agents render with distinct styling (purple background, robot icon).
