# Frontend / Backend Layout Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move the monorepo into `frontend/` + `backend/` with a thin root orchestration layer (`make dev`, Docker, CI), without changing product behavior.

**Architecture:** One-shot `git mv` restructure (design A2 + R2). pnpm/turbo workspace root becomes `frontend/`; root `package.json` only forwards. Backend Zig tree moves intact to `backend/zserver`. Shared scripts stay at repo root; domain scripts and docs are split by audience. No compatibility symlinks.

**Tech Stack:** pnpm workspaces, Turborepo, Make, GitHub Actions, Docker, Zig (`zserver`), Playwright

**Design:** @docs/plans/2026-08-27-fe-be-layout-design.md

---

### Task 1: Create shells + move backend trees

**Files:**
- Create: `frontend/.gitkeep`, `backend/.gitkeep` (temporary; remove when dirs nonempty)
- Move: `zserver` → `backend/zserver`
- Move: `deploy` → `backend/deploy`
- Move: `zig_ws` → `backend/zig_ws`

**Step 1: Create directories and git-mv backend**

```bash
mkdir -p frontend backend
git mv zserver backend/zserver
git mv deploy backend/deploy
git mv zig_ws backend/zig_ws
```

**Step 2: Sanity check**

```bash
test -d backend/zserver/src && test -d backend/zserver/migrations
test -d backend/deploy/helm
ls backend/zig_ws
```

Expected: all succeed; root no longer has `zserver/`, `deploy/`, `zig_ws/`.

**Step 3: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(repo): move zserver, deploy, zig_ws under backend/

EOF
)"
```

---

### Task 2: Move frontend trees + workspace files

**Files:**
- Move: `apps` → `frontend/apps`
- Move: `packages` → `frontend/packages`
- Move: `e2e` → `frontend/e2e`
- Move: `pnpm-workspace.yaml` → `frontend/pnpm-workspace.yaml`
- Move: `turbo.json` → `frontend/turbo.json`
- Move: `playwright.config.ts` → `frontend/playwright.config.ts`
- Move: `pnpm-lock.yaml` → `frontend/pnpm-lock.yaml`
- Move: `.npmrc` → `frontend/.npmrc` (if present at root)
- Create: root thin `package.json` (forwarder); move full workspace `package.json` → `frontend/package.json`

**Step 1: git-mv trees and workspace configs**

```bash
git mv apps frontend/apps
git mv packages frontend/packages
git mv e2e frontend/e2e
git mv pnpm-workspace.yaml frontend/pnpm-workspace.yaml
git mv turbo.json frontend/turbo.json
git mv playwright.config.ts frontend/playwright.config.ts
git mv pnpm-lock.yaml frontend/pnpm-lock.yaml
# if exists:
git mv .npmrc frontend/.npmrc
```

**Step 2: Relocate package.json**

```bash
git mv package.json frontend/package.json
```

Create new root `package.json`:

```json
{
  "name": "1person",
  "private": true,
  "scripts": {
    "dev:web": "pnpm --dir frontend run dev:web",
    "dev:docs": "pnpm --dir frontend run dev:docs",
    "dev:desktop": "pnpm --dir frontend run dev:desktop",
    "dev:desktop:staging": "pnpm --dir frontend run dev:desktop:staging",
    "dev:mobile": "pnpm --dir frontend run dev:mobile",
    "dev:mobile:staging": "pnpm --dir frontend run dev:mobile:staging",
    "dev:mobile:prod": "pnpm --dir frontend run dev:mobile:prod",
    "ios:mobile": "pnpm --dir frontend run ios:mobile",
    "ios:mobile:staging": "pnpm --dir frontend run ios:mobile:staging",
    "ios:mobile:prod": "pnpm --dir frontend run ios:mobile:prod",
    "ios:mobile:device": "pnpm --dir frontend run ios:mobile:device",
    "ios:mobile:device:staging": "pnpm --dir frontend run ios:mobile:device:staging",
    "ios:mobile:device:staging:release": "pnpm --dir frontend run ios:mobile:device:staging:release",
    "ios:mobile:device:prod": "pnpm --dir frontend run ios:mobile:device:prod",
    "ios:mobile:device:prod:release": "pnpm --dir frontend run ios:mobile:device:prod:release",
    "build": "pnpm --dir frontend run build",
    "typecheck": "pnpm --dir frontend run typecheck",
    "test": "pnpm --dir frontend run test",
    "lint": "pnpm --dir frontend run lint",
    "clean": "pnpm --dir frontend run clean",
    "ui:add": "pnpm --dir frontend run ui:add",
    "generate:reserved-slugs": "node scripts/generate-reserved-slugs.mjs"
  },
  "packageManager": "pnpm@10.28.2"
}
```

**Step 3: Fix `frontend/package.json` mobile path scripts**

In `frontend/package.json`, change `pnpm -C apps/mobile` paths to stay relative to `frontend/` (already `apps/mobile` — OK). Ensure no references to repo-root-relative `../`.

**Step 4: Fix `frontend/playwright.config.ts`**

Confirm `testDir: "./e2e"` and `import "./e2e/env"` still resolve (they do relative to `frontend/`).

**Step 5: Install from frontend workspace**

```bash
pnpm --dir frontend install
```

Expected: lockfile resolves; no missing workspace packages.

**Step 6: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(repo): move apps, packages, e2e under frontend/

EOF
)"
```

---

### Task 3: Split scripts

**Files:**
- Keep at root `scripts/`: `dev.sh`, `ensure-postgres.sh`, `check.sh`, `local-env.sh`, `init-worktree-env.sh`
- Keep at root (cross-cutting): `generate-reserved-slugs.mjs`
- Move to `frontend/scripts/`: `screenshot-pr-cards.mjs`
- Move to `backend/scripts/`: `install.sh`, `install.ps1`, `install.test.sh`, `selfhost-config.test.sh`, `_tmp_gen_router.sh`
- Move to `archive/scripts-unrelated/` (or delete): `commission_e2e.sh`, `community_ops_e2e.sh`

**Step 1: Create dirs and move**

```bash
mkdir -p frontend/scripts backend/scripts archive/scripts-unrelated
git mv scripts/screenshot-pr-cards.mjs frontend/scripts/
git mv scripts/install.sh scripts/install.ps1 scripts/install.test.sh scripts/selfhost-config.test.sh scripts/_tmp_gen_router.sh backend/scripts/
git mv scripts/commission_e2e.sh scripts/community_ops_e2e.sh archive/scripts-unrelated/
```

**Step 2: Update `scripts/generate-reserved-slugs.mjs` paths**

```javascript
const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const jsonPath = resolve(repoRoot, "backend/zserver/src/modules/workspace/reserved_slugs.json");
const tsPath = resolve(repoRoot, "frontend/packages/core/paths/reserved-slugs.ts");
```

Update generated-file header comments to mention `backend/zserver/...` (drop obsolete "Go backend" wording if still present).

**Step 3: Fix `_tmp_gen_router.sh`**

Replace hardcoded absolute path with:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/../zserver"
```

**Step 4: Update root `scripts/dev.sh` and `scripts/check.sh`**

Replace every `cd zserver` / `zserver/` with `cd backend/zserver` / `backend/zserver/`.

Replace `pnpm install` / `pnpm dev:web` to use frontend workspace:

```bash
pnpm --dir frontend install
# ...
pnpm --dir frontend run dev:web
```

Remove obsolete `go` prerequisite check in `dev.sh` if still present (backend is Zig-only).

**Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(repo): split scripts into root, frontend, and backend

EOF
)"
```

---

### Task 4: Triage docs

**Files:** see design § Docs triage

**Step 1: Create doc dirs and archive**

```bash
mkdir -p frontend/docs backend/docs archive/docs-unrelated docs/plans
```

**Step 2: Move frontend docs**

```bash
git mv docs/PRD.md docs/product-overview.md docs/onboarding-refactor-plan.md \
  docs/design.md docs/docs-outline.md docs/docs-rewrite-plan.md \
  docs/quickstart.md docs/analytics.md docs/agent-quick-create-plan.md \
  docs/README.md frontend/docs/
```

(If some files missing, skip those names.)

**Step 3: Move backend docs**

```bash
git mv docs/zig-daemon-plan.md docs/timezone-architecture-rfc.md \
  docs/deployment.md docs/common-infrastructure.md \
  docs/codex-sandbox-troubleshooting.md docs/common-gaps.md \
  backend/docs/
```

**Step 4: Archive unrelated**

```bash
git mv docs/meme-coin-community.md docs/us-insurance-ai-platform.md \
  docs/green-points-ecommerce.md docs/cross-border-ecommerce.md \
  docs/healing-economy-miniapp.md docs/lifepp-digital-life-community.md \
  docs/meaningful-consumption-community.md docs/geo-auto-delivery.md \
  docs/idea-to-revenue.md docs/opc-ai-training.md \
  docs/one-person-factory.md docs/theory-to-ecosystem.md \
  archive/docs-unrelated/
```

**Step 5: Plans / assets / superpowers**

```bash
# Prefer keeping shared planning at root docs/plans (already has this design)
# Move topic plans:
mkdir -p backend/docs/plans frontend/docs/plans
# If docs/superpowers exists:
git mv docs/superpowers/plans/2026-06-14-zserver-alignment.md backend/docs/plans/ || true
git mv docs/superpowers/plans/2026-06-14-track-f-shapes.md frontend/docs/plans/ || true
# Move remaining docs/assets if any:
git mv docs/assets frontend/docs/assets || true
```

Leave `docs/plans/2026-08-27-fe-be-layout-design.md` and this plan at root `docs/plans/`.

**Step 6: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
docs: split frontend/backend docs and archive unrelated product notes

EOF
)"
```

---

### Task 5: Update Makefile

**Files:**
- Modify: `Makefile`

**Step 1: Add directory vars near top**

```makefile
FRONTEND_DIR := frontend
BACKEND_DIR := backend/zserver
```

**Step 2: Replace all `cd zserver` with `cd $(BACKEND_DIR)`**

Also update echo/help text that mentions `zserver/` paths.

**Step 3: Replace frontend pnpm invocations**

```makefile
pnpm --dir $(FRONTEND_DIR) install
pnpm --dir $(FRONTEND_DIR) run dev:web
# etc.
```

**Step 4: Smoke help**

```bash
make help
```

Expected: help prints; no stale `cd zserver` without `backend/`.

**Step 5: Commit**

```bash
git add Makefile
git commit -m "$(cat <<'EOF'
refactor(make): point targets at frontend/ and backend/zserver

EOF
)"
```

---

### Task 6: Update Docker + compose

**Files:**
- Modify: `Dockerfile`
- Modify: `Dockerfile.web`
- Modify: `docker-compose.yml`, `docker-compose.selfhost.yml`, `docker-compose.selfhost.build.yml` (any path refs)

**Step 1: Dockerfile (backend image)**

Change copies/builds from `zserver/...` → `backend/zserver/...`:

```dockerfile
COPY backend/zserver/scripts/install-zig.sh ./backend/zserver/scripts/install-zig.sh
RUN bash backend/zserver/scripts/install-zig.sh /opt/zig
# ...
RUN bash backend/zserver/scripts/provision-zig-deps.sh
RUN cd backend/zserver && zig build -Doptimize=ReleaseSafe -Dcommit=${COMMIT}
COPY --from=builder /src/backend/zserver/zig-out/bin/zserver ./zserver
COPY --from=builder /src/backend/zserver/migrations ./zserver/migrations
```

(Keep runtime layout as `/app/zserver` binary + migrations if entrypoint expects that — only build context paths change.)

**Step 2: Dockerfile.web**

Either set build context to `frontend/` in compose, or prefix all `COPY` with `frontend/`:

Recommended compose:

```yaml
# build context: ./frontend
```

Then Dockerfile.web stays largely as today (apps/, packages/ relative to frontend context). If context remains repo root, every `COPY` must use `frontend/` prefix and final standalone paths must match Next standalone output under `frontend/apps/web/...`.

**Step 3: Commit**

```bash
git add Dockerfile Dockerfile.web docker-compose*.yml
git commit -m "$(cat <<'EOF'
refactor(docker): update build contexts for frontend/backend layout

EOF
)"
```

---

### Task 7: Update GitHub Actions

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/zserver-ci.yml`
- Modify: `.github/workflows/migrate.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `.github/workflows/desktop-smoke.yml`
- Modify: `.github/workflows/mobile-verify.yml`

**Step 1: zserver-ci.yml**

- Path filters: `backend/zserver/**`
- Install/provision scripts: `backend/zserver/scripts/...`
- Commands: `cd backend/zserver && zig build` / `zig build test`

**Step 2: ci.yml**

- `pnpm install` / turbo: `working-directory: frontend` or `pnpm --dir frontend`
- reserved-slugs generator + diff: still from repo root `node scripts/generate-reserved-slugs.mjs` then diff `frontend/packages/core/paths/reserved-slugs.ts`
- Any `apps/` / `packages/` path filters → `frontend/apps/**`, `frontend/packages/**`

**Step 3: release.yml / desktop-smoke / mobile-verify / migrate**

Update `apps/desktop` → `frontend/apps/desktop`, helm chart path `backend/deploy/...`, zig paths under `backend/zserver`.

**Step 4: Commit**

```bash
git add .github/workflows
git commit -m "$(cat <<'EOF'
ci: update workflow paths for frontend/backend layout

EOF
)"
```

---

### Task 8: Update CLAUDE.md, AGENTS.md, README*, CONTRIBUTING

**Files:**
- Modify: `CLAUDE.md`, `AGENTS.md`, `README.md`, `README.zh-CN.md`, `CONTRIBUTING.md`
- Modify: `frontend/apps/mobile/CLAUDE.md`, `backend/zserver/AGENTS.md` (path examples)
- Grep for stale paths and fix high-signal docs

**Step 1: Search**

```bash
rg -n '(^|[^/])(apps/|packages/|zserver/|e2e/)' \
  CLAUDE.md AGENTS.md README.md README.zh-CN.md CONTRIBUTING.md \
  SELF_HOSTING.md SELF_HOSTING_ADVANCED.md CLI_AND_DAEMON.md CLI_INSTALL.md \
  --glob '!node_modules'
```

**Step 2: Rewrite architecture bullets**

Example:

```markdown
- `frontend/apps/web/` — Next.js frontend
- `frontend/packages/core/` — headless business logic
- `backend/zserver/` — Zig backend (migrations in backend/zserver/migrations/)
```

Update command examples: `pnpm --dir frontend …`, `cd backend/zserver && zig build test`.

**Step 3: Commit**

```bash
git add CLAUDE.md AGENTS.md README.md README.zh-CN.md CONTRIBUTING.md \
  SELF_HOSTING.md SELF_HOSTING_ADVANCED.md CLI_AND_DAEMON.md CLI_INSTALL.md \
  frontend/apps/mobile/CLAUDE.md backend/zserver/AGENTS.md
git commit -m "$(cat <<'EOF'
docs: document frontend/ and backend/ monorepo layout

EOF
)"
```

---

### Task 9: Fix remaining in-repo path references

**Files:** any remaining hits from repo-wide search (exclude `archive/`, `node_modules`, lockfiles)

**Step 1: Broad search**

```bash
rg -l --glob '!**/node_modules/**' --glob '!**/.git/**' --glob '!archive/**' \
  --glob '!frontend/pnpm-lock.yaml' \
  '(^|[^\w./-])zserver/|(^|[^\w./-])apps/web|(^|[^\w./-])packages/core' \
  | head -100
```

**Step 2: Fix generators, skills, built-in skill source maps if they hardcode paths**

Especially:

- `frontend/packages/core` comments referencing `zserver/...` → `backend/zserver/...`
- CI drift check for reserved-slugs
- Any `scripts/` left at root

**Step 3: Re-run reserved-slugs generator**

```bash
node scripts/generate-reserved-slugs.mjs
git diff --exit-code frontend/packages/core/paths/reserved-slugs.ts
```

Expected: no unintended drift (or commit intentional comment-only regen).

**Step 4: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
fix(repo): finish path rewrites after frontend/backend move

EOF
)"
```

---

### Task 10: Verification

**Step 1: Frontend checks**

```bash
pnpm --dir frontend typecheck
pnpm --dir frontend test
```

Expected: pass (same as pre-move, ignoring path-only failures).

**Step 2: Backend checks**

```bash
cd backend/zserver && zig build test
```

Expected: pass.

**Step 3: Root orchestration**

```bash
make help
# If env available:
# make check   # or scripts/check.sh subset
```

**Step 4: Confirm success criteria**

```bash
test ! -e apps && test ! -e packages && test ! -e e2e && test ! -e zserver && test ! -e deploy && test ! -e zig_ws
test -d frontend/apps && test -d frontend/packages && test -d backend/zserver
```

**Step 5: Final commit only if verification fixed stray files; otherwise done**

---

## Execution notes

- Prefer `git mv` always; never delete+re-add trees.
- Do not add symlinks from old paths.
- Keep root `make dev` working end-to-end before merging.
- After merge, announce path migration table in PR body for local scripts.

## Plan complete

Saved to `docs/plans/2026-08-27-fe-be-layout.md`.
