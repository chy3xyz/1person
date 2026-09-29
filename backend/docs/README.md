# Backend / ops docs

Notes for `backend/zserver`, daemon/CLI, deployment, and infrastructure.

> Older files may still say `zserver/` at repo root. Current path: **`backend/zserver/`**.

## Ops & architecture

| Doc | What it is |
|-----|------------|
| [quickstart.md](quickstart.md) | API-level quickstart: curl through pipeline, roles, referral, token economy, content matrix |
| [deployment.md](deployment.md) | Deployment modes (no-DB / Postgres / multi-instance) |
| [zig-daemon-plan.md](zig-daemon-plan.md) | Zig `1p` CLI + daemon roadmap |
| [timezone-architecture-rfc.md](timezone-architecture-rfc.md) | Timezone architecture RFC |
| [common-infrastructure.md](common-infrastructure.md) | Shared infra notes (historical plan) |
| [common-gaps.md](common-gaps.md) | Known gaps |
| [codex-sandbox-troubleshooting.md](codex-sandbox-troubleshooting.md) | Codex sandbox troubleshooting |

## Plans

| Doc | What it is |
|-----|------------|
| [`../../docs/plans/backend/`](../../docs/plans/backend/) | Backend-scoped historical plans (e.g. zserver alignment) |

## Also see

- Product / frontend docs: [`../../frontend/docs/`](../../frontend/docs/)
- Shared plans: [`../../docs/plans/`](../../docs/plans/)
- CLI & daemon (repo root): `CLI_AND_DAEMON.md`, `CLI_INSTALL.md`
- Self-hosting (repo root): `SELF_HOSTING.md`, `SELF_HOSTING_ADVANCED.md`
- Backend code guide: [`../zserver/AGENTS.md`](../zserver/AGENTS.md)
- Full doc index: [`../../docs/README.md`](../../docs/README.md)
