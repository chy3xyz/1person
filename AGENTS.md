# 1person — Repository Guidelines

This file provides guidance to AI agents when working with code in this repository.

> **Single source of truth:** This file is a concise pointer document.
> All authoritative architecture, coding rules, commands, and conventions
> live in **CLAUDE.md** at the project root. Read that file first.

## Quick Reference

### Architecture

Monorepo: `frontend/` (pnpm workspaces + Turborepo) + `backend/zserver/` (Zig).

- `backend/zserver/` — Zig backend (zfinal framework, 50 modules, 39 e2e scripts; canonical backend)
- `frontend/apps/web/` — Next.js frontend (App Router)
- `frontend/apps/desktop/` — Electron desktop app
- `frontend/packages/core/` — Headless business logic (React Query hooks, API client)
- `frontend/packages/ui/` — Atomic UI components (shadcn/Base UI, zero business logic)
- `frontend/packages/views/` — Shared business pages/components
- `frontend/packages/tsconfig/` — Shared TypeScript config

### State Management (critical)

- **React Query** owns all server state (issues, members, agents, inbox, workspace list)
- **Zustand** owns all client state (current workspace selection, view filters, drafts, modals)
- All Zustand stores live in `frontend/packages/core/` — never in `frontend/packages/views/` or app directories
- WS events invalidate React Query — never write directly to stores

### Package Boundaries (hard rules)

- `frontend/packages/core/` — zero react-dom, zero localStorage, zero process.env
- `frontend/packages/ui/` — zero `@1person/core` imports
- `frontend/packages/views/` — zero `next/*`, zero `react-router-dom`, use `NavigationAdapter` for routing
- `frontend/apps/web/platform/` — only place for Next.js APIs

### Commands

```bash
make dev              # Auto-setup + start everything
pnpm --dir frontend typecheck        # TypeScript check
pnpm --dir frontend test             # TS unit tests (Vitest)
make test             # zserver (Zig) tests
make check            # Full verification pipeline
```

See CLAUDE.md for the complete command reference.
