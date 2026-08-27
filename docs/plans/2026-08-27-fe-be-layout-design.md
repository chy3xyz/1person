# Frontend / Backend Monorepo Layout — Design

> Approved via brainstorming (2026-08-27). Approach: **A2 directory shape + R2 root orchestration + one-shot `git mv`**.

## Goal

Reorganize the monorepo so frontend and backend are clearly separated under `frontend/` and `backend/`, while keeping a single root `make dev` / Docker / CI entrypoint.

## Non-goals

- Splitting into two git repositories
- Splitting `packages/core/api/client.ts` / `schemas.ts` (follow-up)
- Changing API contracts or runtime behavior
- Leaving compatibility symlinks at old paths

## Target tree

```
1person/
├── frontend/
│   ├── apps/                 # web, desktop, mobile, docs site
│   ├── packages/             # core, ui, views, tsconfig, eslint-config
│   ├── e2e/
│   ├── docs/                 # product / frontend docs
│   ├── scripts/              # frontend-domain scripts
│   ├── package.json          # workspace root for pnpm/turbo
│   ├── pnpm-workspace.yaml
│   ├── turbo.json
│   └── playwright.config.ts
├── backend/
│   ├── zserver/              # Zig backend + migrations (moved intact)
│   ├── docs/                 # backend / daemon / RFC docs
│   ├── scripts/              # install, selfhost tests, router gen helpers
│   ├── deploy/               # helm
│   └── zig_ws/               # zcli / zfinal
└── (root = R2 orchestration)
    ├── Makefile
    ├── scripts/              # shared only: dev, ensure-postgres, check, local-env, init-worktree
    ├── docker/, docker-compose*, Dockerfile*
    ├── .github/
    ├── package.json          # thin forwarder to frontend/
    ├── README*, CONTRIBUTING, SELF_HOSTING*, CLAUDE.md, AGENTS.md, CLI_*.md
    └── archive/docs-unrelated/   # non-1person docs (reversible)
```

## Ownership rules

| Rule | Meaning |
|------|---------|
| Frontend runnable | Everything under `frontend/` |
| Backend runnable | Everything under `backend/` (`zserver` not split) |
| Root orchestrates | No business code; Makefile + docker + CI + shared env |
| Docs by audience | Product/UX → `frontend/docs`; protocol/daemon/RFC → `backend/docs` |
| Unrelated docs | Do not enter FE/BE docs; archive under `archive/docs-unrelated/` |

## Migration strategy

One PR, ordered steps with `git mv` throughout (preserve history). No half-migrated `main`.

1. Create `frontend/` / `backend/` shells
2. Move backend trees (`zserver`, `deploy`, `zig_ws`)
3. Move frontend trees (`apps`, `packages`, `e2e`) + workspace files into `frontend/`
4. Split scripts (shared stay at root; domain scripts move)
5. Triage docs
6. Rewrite path references (Makefile, CI, Docker, generators, CLAUDE/AGENTS/README)
7. Verify: typecheck, unit tests, zig tests, CI paths, smoke e2e

## Cross-cutting tool: reserved-slugs

`generate-reserved-slugs` spans backend JSON → frontend TS. Keep it at **root** `scripts/` (shared contract tooling), with paths updated to:

- `backend/zserver/src/modules/workspace/reserved_slugs.json`
- `frontend/packages/core/paths/reserved-slugs.ts`

Root `package.json` script: `node scripts/generate-reserved-slugs.mjs` (unchanged command name).

## Docs triage

**→ `frontend/docs/`:** PRD, product-overview, onboarding-*, design, docs-outline, docs-rewrite-plan, quickstart, analytics, agent-quick-create-plan, README (docs index)

**→ `backend/docs/`:** zig-daemon-plan, timezone-architecture-rfc, deployment, common-infrastructure, codex-sandbox-troubleshooting, common-gaps

**→ root:** README*, CONTRIBUTING, SELF_HOSTING*, CLI_*, CLAUDE.md, AGENTS.md

**→ `archive/docs-unrelated/`:** meme-coin-*, us-insurance-*, green-points-*, cross-border-*, healing-economy-*, lifepp-*, meaningful-consumption-*, geo-auto-delivery, idea-to-revenue, opc-ai-training, one-person-factory, theory-to-ecosystem

**→ plans:** `docs/superpowers/plans/*` → `backend/docs/plans/` or `frontend/docs/plans/` by topic; this design + implementation plan stay under root `docs/plans/` until the move, then prefer `frontend/docs/plans/` for FE layout work (or keep root `docs/plans/` as shared planning — implementer chooses one and updates links once).

## Risks & rollback

- Missed CI/Docker paths → fix via checklist; require ci + zserver-ci green
- Worktree/env scripts assume old paths → update with Makefile
- External personal scripts break → document migration table in PR; no symlinks
- Rollback: revert merge commit if needed; never land half-moved tree on main

## Success criteria

1. Root has no `apps/`, `packages/`, `e2e/`, `zserver/`, `deploy/`, `zig_ws/`
2. Root `make dev` (or documented equivalent) still boots FE + BE
3. `pnpm --dir frontend typecheck` and `pnpm --dir frontend test` pass
4. `cd backend/zserver && zig build test` passes
5. CI workflows use new paths (ci + zserver-ci at minimum)
6. CLAUDE.md / AGENTS.md / README* describe the new tree
7. Unrelated product docs are not under `frontend/docs` or `backend/docs`

## Follow-ups (out of scope)

- Split monolithic `frontend/packages/core/api/{client,schemas}.ts` by domain
- Clean leftover commerce e2e scripts (`commission_e2e`, `community_ops_e2e`) beyond archival
