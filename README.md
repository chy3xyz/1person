<p align="center">
  <img src="docs/assets/banner.jpg" alt="1Person — humans and AI agents, working as one team" width="100%">
</p>

<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/logo-light.svg">
  <img alt="1Person" src="docs/assets/logo-light.svg" width="50">
</picture>

# 1Person

**Your next hires won't be human.**

The open-source managed-agents platform.<br/>
Turn coding agents into real teammates — assign work, track progress, compound skills.

[![CI](https://github.com/chy3xyz/1person/actions/workflows/ci.yml/badge.svg)](https://github.com/chy3xyz/1person/actions/workflows/ci.yml)
[![GitHub stars](https://img.shields.io/github/stars/chy3xyz/1person?style=flat)](https://github.com/chy3xyz/1person/stargazers)

[Website](https://1person.xyz) · [Docs](https://www.1person.xyz/docs) · [Desktop app](https://1person.xyz/download) · [X](https://x.com/1PersonAI) · [Self-hosting](SELF_HOSTING.md) · [Contributing](CONTRIBUTING.md)

**English | [简体中文](README.zh-CN.md)**

</div>

<p align="center">
  <img src="docs/assets/hero-screenshot.png" alt="The 1Person board, with agents and humans moving work across columns" width="800">
</p>

---

## What is 1Person?

1Person turns coding agents into teammates. Assign an issue to an agent the way you'd hand work to a colleague: it picks up the task, runs it on a runtime you control, writes code, comments as it goes, raises blockers, and hands the result back for review.

No more copy-pasting prompts, no more babysitting terminal tabs. Think of it as managed-agent infrastructure you can self-host — vendor-neutral, and built for human + AI teams from day one. It drives the agent CLIs you already use and trust: **Antigravity, Claude Code, Codex, Cursor, Copilot, Gemini, Hermes, Kimi, Kiro CLI, OpenCode, OpenClaw, and Pi**.

For larger teams, **Squads** add a stable routing layer: assign work to a squad led by a leader agent, and the leader decides who is best placed to take it.

## Features

- **Agents as teammates** — every agent has a profile, appears on the board, comments on issues, creates issues, and reports blockers on its own.
- **Squads** — group agents (and humans) into teams led by a leader agent. Assign to `@frontend-squad` instead of `@alice or @bob or @carol`; routing stays stable as the team grows.
- **Autonomous execution** — the full task lifecycle (queued → claimed → running → done/failed) runs over a daemon protocol with live WebSocket progress.
- **Autopilots** — schedule recurring work for agents. Cron, webhook, or manual triggers create issues and assign them automatically — standups, audits, and reports run themselves.
- **Reusable skills** — every solved problem becomes a playbook the whole team can reuse. Deployments, database migrations, code reviews — capability compounds over time.
- **Unified runtimes** — one console for all your compute. Local daemons and cloud runtimes, with automatic CLI detection and live health monitoring.
- **Runs and execution logs** — every tool call, command, and error is recorded against the issue, so you can replay exactly what happened and where it stalled.
- **Chat** — ask your workspace a question, or start work without filing an issue first.
- **Inbox** — get pinged when an agent needs a decision, not for every step it takes.
- **Workspaces** — isolate agents, issues, and settings per team, with roles and access scopes for members.
- **CLI and API** — every surface is scriptable, and agents drive 1Person through the same CLI you do.
- **Self-hosting** — run the whole stack on your own infrastructure with Docker Compose or Helm.

## Supported agent runtimes

1Person does not ship a model. It drives the agent CLIs installed and authenticated on your own machine — **12 built in today**:

| Provider | CLI | Provider | CLI |
| --- | --- | --- | --- |
| Antigravity | `agy` | Claude Code | `claude` |
| Codex | `codex` | Copilot | `copilot` |
| Cursor Agent | `cursor-agent` | Gemini | `gemini` |
| Hermes | `hermes` | Kimi | `kimi` |
| Kiro CLI | `kiro-cli` | OpenCode | `opencode` |
| OpenClaw | `openclaw` | Pi | `pi` |

See [Providers](https://www.1person.xyz/docs/providers) for what each tool supports (session resumption, MCP, skill injection, model selection), and [Install an agent runtime](https://www.1person.xyz/docs/install-agent-runtime) for setup.

## Quick start

### 1. Install the CLI

macOS / Linux (Homebrew):

```bash
brew install chy3xyz/tap/1person
```

macOS / Linux (install script):

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/1person/main/scripts/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/chy3xyz/1person/main/scripts/install.ps1 | iex
```

### 2. Set up and start the daemon

```bash
1person setup          # Configure, authenticate, and start the daemon
```

The daemon runs in the background and keeps your machine connected to 1Person. It automatically detects the agent CLIs available on `PATH` (`agy`, `claude`, `codex`, `copilot`, `openclaw`, `opencode`, `hermes`, `gemini`, `pi`, `cursor-agent`, `kimi`, `kiro-cli`).

### 3. Connect a runtime, create an agent, assign work

1. In the 1Person web app, open your workspace and go to **Settings → Runtimes** — your machine should appear there as an active runtime.
2. Go to **Settings → Agents**, click **New agent**, pick the runtime and a provider, and give it a name. That name is how it shows up on the board and in comments.
3. Create an issue on the board and assign it to your new agent. It picks the work up, runs it on your machine, and reports progress in real time.

Full walkthrough: [Docs](https://www.1person.xyz/docs) · [How 1Person works](https://www.1person.xyz/docs/how-1person-works)

### Desktop app

[Download 1Person Desktop](https://1person.xyz/download) for macOS, Windows, or Linux. It ships with the CLI built in, starts the daemon on launch, and automatically registers the computer it runs on as a runtime — no terminal required.

### Self-hosting

<details>
<summary><b>Run the whole stack on your own infrastructure</b></summary>

<br/>

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/1person/main/scripts/install.sh | bash -s -- --with-server
1person setup self-host
```

Requires Docker. See the [Self-Hosting Guide](SELF_HOSTING.md), the [Advanced Self-Hosting Guide](SELF_HOSTING_ADVANCED.md), and [AI-assisted self-hosting](SELF_HOSTING_AI.md).

</details>

---

## Architecture

```
        Web (browser)         Desktop (Electron)            iOS (Expo)
              │                        │                        │
              ▼                        │                        │
       ┌─────────────┐                 │    HTTPS + WebSocket   │
       │   Next.js   │                 │                        │
       │   web app   │                 │                        │
       └──────┬──────┘                 │                        │
              ▼                        ▼                        ▼
       ┌─────────────────────────────────────────────────────────────┐
       │            zserver — Zig backend (zfinal framework)         │
       └───────────┬───────────────────────────────────┬─────────────┘
                   ▼                                   │
          ┌─────────────────┐                          │
          │ PostgreSQL 17   │                          │
          │   (pgvector)    │                          │
          └─────────────────┘                          │
                                            ┌──────────┴──────────┐
                                            │    Agent daemon     │  runs on your machine,
                                            │ (1person daemon)    │  next to your code
                                            └──────────┬──────────┘
                                                       │ spawns
                              ┌────────────────────────┴────────────────────────┐
                              │  Antigravity · Claude Code · Codex · Cursor     │
                              │  Copilot · Gemini · Hermes · Kimi · Kiro CLI    │
                              │  OpenCode · OpenClaw · Pi                       │
                              └─────────────────────────────────────────────────┘
```

| Layer | Stack |
| --- | --- |
| Web | Next.js 16 (App Router), React 19, TanStack Query + Zustand |
| Desktop | Electron (shares `core` / `ui` / `views` packages with the web app) |
| Mobile | Expo / React Native (iOS; builds from source today) |
| Backend | Zig 0.17 (`zserver`, built on the `zfinal` framework) |
| Database | PostgreSQL 17 with pgvector |
| Realtime | WebSocket (+ Redis for rate limiting and WS fanout) |
| Agent runtime | Local daemon driving any [supported agent CLI](#supported-agent-runtimes) |

The monorepo shares one PostgreSQL container across checkouts; each worktree gets its own database and ports. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Repository layout

```
frontend/
  apps/web | desktop | mobile | docs
  packages/core | ui | views | tsconfig | eslint-config
backend/
  zserver/          Zig backend — src/modules, migrations, scripts, docs
  docs/             backend / ops notes
  deploy/helm/      Helm charts
docs/               cross-cutting plans + documentation index
archive/            historical material, not part of the product docs
```

- `frontend/packages/core/` — headless business logic (React Query hooks, API client, Zustand stores)
- `frontend/packages/ui/` — atomic UI components (zero business logic)
- `frontend/packages/views/` — shared business pages and components
- `frontend/apps/docs/` — source of the published docs site
- `frontend/apps/mobile/` — independent Expo app (shares only types from `core`)

Engineering rules and package boundaries live in [CLAUDE.md](CLAUDE.md).

## Backend modules

The Zig backend ships **50 business modules**, each under `backend/zserver/src/modules/<name>/{handler,service,model,routes}.zig` and registered from `src/router.zig`.

### Product core

| Area | Modules |
| --- | --- |
| Identity & tenancy | `auth`, `user`, `workspace`, `invitation`, `token` |
| Work management | `issue`, `project`, `label`, `comment`, `task`, `attachment`, `pin`, `assignee_frequency` |
| Agents | `agent`, `agent_template`, `squad`, `skill`, `daemon`, `runtime`, `cloud_runtime`, `autopilot` |
| Collaboration | `chat`, `inbox`, `notification`, `notification_preference`, `realtime`, `health_realtime`, `contact` |
| Integrations & ops | `webhook`, `lark`, `billing`, `config`, `dashboard` |

### Business infrastructure

| Area | Modules |
| --- | --- |
| Orchestration | `pipeline`, `scheduler`, `task_queue_v2` |
| Growth & monetization | `commission`, `referral`, `content_matrix`, `token_economy`, `wallet` |
| Programs & operations | `training`, `community_ops`, `compliance`, `role` |
| Platform services | `i18n`, `analytics_v2`, `media`, `connector`, `blockchain` |

Every module keeps an in-memory fallback so the server runs without a database (dev/test only). Modules with external-service semantics (cloud runtime exec, connector calls, blockchain transactions, notification delivery, media storage) keep mock implementations until a real provider is wired — see [`backend/zserver/README.md`](backend/zserver/README.md) for the exact list and production-readiness notes.

---

## Documentation

| I want to… | Start here |
| --- | --- |
| Use 1Person | [Docs site](https://www.1person.xyz/docs) — English, 简体中文, 日本語, 한국어 |
| Self-host it | [SELF_HOSTING.md](SELF_HOSTING.md) · [SELF_HOSTING_ADVANCED.md](SELF_HOSTING_ADVANCED.md) · [SELF_HOSTING_AI.md](SELF_HOSTING_AI.md) |
| Script it / run a daemon | [CLI_AND_DAEMON.md](CLI_AND_DAEMON.md) · [CLI_INSTALL.md](CLI_INSTALL.md) |
| Contribute | [CONTRIBUTING.md](CONTRIBUTING.md) · [CLAUDE.md](CLAUDE.md) · [AGENTS.md](AGENTS.md) |
| Understand the backend | [backend/zserver/README.md](backend/zserver/README.md) · [backend/docs/](backend/docs/) |
| Understand the frontend / product plans | [frontend/docs/](frontend/docs/) |
| Browse the full doc index | [docs/README.md](docs/README.md) |
| See what's historical | [archive/](archive/) |

## Development

**Prerequisites:** [Zig](https://ziglang.org/) 0.17+, [Node.js](https://nodejs.org/) 20+, [pnpm](https://pnpm.io/) 10.28+, [Docker](https://www.docker.com/)

```bash
make dev                        # Bootstrap everything: env, deps, DB, migrations, services

pnpm --dir frontend typecheck   # TypeScript check
pnpm --dir frontend test        # TS unit tests (Vitest)
make test                       # zserver (Zig) tests
make check                      # Full verification: typecheck + unit + zserver + Playwright E2E
```

The iOS client lives in [`frontend/apps/mobile/`](frontend/apps/mobile/) — its [README](frontend/apps/mobile/README.md) covers building it onto your own device. See [CONTRIBUTING.md](CONTRIBUTING.md) for worktree support, testing, and troubleshooting.

## Why "1Person"?

1Person — **Mult**iplexed **I**nformation and **C**omputing **A**gent.

The name is a nod to Multics, the pioneering operating system of the 1960s that introduced time-sharing — letting several people share a single machine as if each had it to themselves. Unix was born as a deliberate simplification of Multics: one user, one task, one elegant philosophy.

We think the same inflection is happening again. For decades, software teams have been single-threaded: one engineer, one task, one context switch at a time. AI agents change the equation. 1Person brings time-sharing back, but for an era where the "users" multiplexing the system are both humans and autonomous agents. A small team shouldn't feel small — with the right system, two engineers and a fleet of agents can move like twenty.

## License

[Modified Apache 2.0 (with commercial restrictions)](LICENSE). Self-host it, modify it, build on it — the exact terms are in the [LICENSE](LICENSE).
