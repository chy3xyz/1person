# Documentation

1Person docs serve two audiences: people **using** the product, and people **working on** the codebase. Prefer the nearest README in each tree.

## Published docs

| Location | What it is |
|----------|------------|
| [www.1person.xyz/docs](https://www.1person.xyz/docs) | Canonical user-facing documentation site (English, 简体中文, 日本語, 한국어) |
| [`frontend/apps/docs/`](../frontend/apps/docs/) | Source of the docs site (SolidStart + MDX, content under `content/docs/`) |

## Repository docs by tree

| Location | Audience | Contents |
|----------|----------|----------|
| [`frontend/docs/`](../frontend/docs/) | Product, design, frontend engineering | PRD, design, onboarding/agent plans, analytics |
| [`backend/docs/`](../backend/docs/) | Backend / daemon / ops | deployment, zig-daemon, timezone RFC, infra notes |
| [`docs/plans/`](plans/) | Cross-cutting engineering plans | Layout design & implementation plans |
| [`archive/`](../archive/) | Not product docs | Unrelated product notes & legacy scripts (kept for history) |

## Root-level guides

| Doc | What it covers |
|-----|----------------|
| [README.md](../README.md) · [README.zh-CN.md](../README.zh-CN.md) | Project overview, features, quick start (English / 中文) |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Contribution workflow, worktree support, testing, troubleshooting |
| [CLI_AND_DAEMON.md](../CLI_AND_DAEMON.md) | `1person` CLI and daemon reference |
| [CLI_INSTALL.md](../CLI_INSTALL.md) | Agent-oriented CLI installation walkthrough |
| [SELF_HOSTING.md](../SELF_HOSTING.md) | Self-hosting quick start (Docker Compose) |
| [SELF_HOSTING_ADVANCED.md](../SELF_HOSTING_ADVANCED.md) | Advanced self-hosting (Helm, multi-instance, telemetry) |
| [SELF_HOSTING_AI.md](../SELF_HOSTING_AI.md) | AI-assisted self-hosting notes |
| [CLAUDE.md](../CLAUDE.md) | Engineering guide: architecture, conventions, commands |
| [AGENTS.md](../AGENTS.md) | Agent entrypoint / pointer document |

**Agent / contributor entrypoints (repo root):** `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, `README.md`.
