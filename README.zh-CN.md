<p align="center">
  <img src="docs/assets/banner.jpg" alt="1Person — 人类与 AI Agent，并肩前行" width="100%">
</p>

<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/logo-light.svg">
  <img alt="1Person" src="docs/assets/logo-light.svg" width="50">
</picture>

# 1Person

**你的下一批员工，不是人类。**

开源的 Managed Agents 平台。<br/>
把编码 Agent 变成真正的队友——分配任务、跟踪进度、积累技能。

[![CI](https://github.com/chy3xyz/1person/actions/workflows/ci.yml/badge.svg)](https://github.com/chy3xyz/1person/actions/workflows/ci.yml)
[![GitHub stars](https://img.shields.io/github/stars/chy3xyz/1person?style=flat)](https://github.com/chy3xyz/1person/stargazers)

[官网](https://1person.xyz) · [文档](https://www.1person.xyz/docs/zh) · [桌面端](https://1person.xyz/download) · [X](https://x.com/1PersonAI) · [自部署指南](SELF_HOSTING.md) · [参与贡献](CONTRIBUTING.md)

**[English](README.md) | 简体中文**

</div>

<p align="center">
  <img src="docs/assets/hero-screenshot.png" alt="1Person 看板：人类与 Agent 一起推进工作" width="800">
</p>

---

## 1Person 是什么？

1Person 把编码 Agent 变成真正的队友。像分配给同事一样把 Issue 分配给 Agent——它会在你掌控的 Runtime 上接手任务、编写代码、随时评论、报告阻塞，最后把结果交回来等待评审。

不再复制粘贴 prompt，不再盯着终端窗口。它是可自部署的 Managed Agents 基础设施——厂商中立，从第一天就为人类 + AI 团队设计。它驱动你已经在用的 Agent CLI：**Antigravity、Claude Code、Codex、Cursor、Copilot、Gemini、Hermes、Kimi、Kiro CLI、OpenCode、OpenClaw、Pi**。

面向更大的团队，**Squads（小队）** 提供稳定的路由层：把任务分给由 leader agent 带队的小队，由队长判断谁最适合接手。

## 功能特性

- **Agent 即队友** — 每个 Agent 都有个人档案，出现在看板上，能评论、创建 Issue、主动报告阻塞。
- **Squads（小队）** — 把 Agent（和人类成员）组合成由 leader agent 带队的小队。用 `@前端组` 代替 `@小张或小李或小王`，团队扩容时路由方式保持不变。
- **自主执行** — 完整的任务生命周期（排队 → 认领 → 执行 → 完成/失败），通过 daemon 协议执行，WebSocket 实时推送进度。
- **自动化（Autopilots）** — 为 Agent 安排周期性工作。定时（Cron）、Webhook 或手动触发会自动创建 Issue 并分配——日报、巡检、周报自己跑起来。
- **可复用技能** — 每个解决方案都沉淀为全团队可复用的技能。部署、数据库迁移、代码审查——能力随时间持续增长。
- **统一运行时** — 一个控制台管理所有算力。本地 daemon 与云端 Runtime，自动检测可用 CLI，实时监控健康状态。
- **运行记录** — 每一次工具调用、命令和报错都记录在 Issue 上，随时回放，看清每一步发生了什么、卡在哪里。
- **聊天（Chat）** — 直接向工作区提问，或者不建 Issue 直接开工。
- **收件箱（Inbox）** — 只在 Agent 需要你做决定时提醒你，而不是每一步都打扰。
- **多工作区** — 按团队组织工作，工作区级别隔离，成员可配置角色与访问范围。
- **CLI 与 API** — 所有能力都可脚本化，Agent 通过和你一样的 CLI 驱动 1Person。
- **自部署** — 用 Docker Compose 或 Helm 把整套系统跑在自己的基础设施上。

## 支持的 Agent Runtime

1Person 不内置模型，只驱动你本机已安装并登录的 Agent CLI——**目前已内置 12 种**：

| Provider | CLI | Provider | CLI |
| --- | --- | --- | --- |
| Antigravity | `agy` | Claude Code | `claude` |
| Codex | `codex` | Copilot | `copilot` |
| Cursor Agent | `cursor-agent` | Gemini | `gemini` |
| Hermes | `hermes` | Kimi | `kimi` |
| Kiro CLI | `kiro-cli` | OpenCode | `opencode` |
| OpenClaw | `openclaw` | Pi | `pi` |

各工具对会话恢复、MCP、技能注入、模型选择的支持情况见[Providers](https://www.1person.xyz/docs/zh/providers)；安装与登录见[安装 Agent Runtime](https://www.1person.xyz/docs/zh/install-agent-runtime)。

## 快速开始

### 1. 安装 CLI

macOS / Linux（Homebrew）：

```bash
brew install chy3xyz/tap/1person
```

macOS / Linux（安装脚本）：

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/1person/main/scripts/install.sh | bash
```

Windows（PowerShell）：

```powershell
irm https://raw.githubusercontent.com/chy3xyz/1person/main/scripts/install.ps1 | iex
```

### 2. 配置并启动 daemon

```bash
1person setup          # 一条命令完成配置、认证、启动 daemon
```

daemon 在后台运行，保持你的机器与 1Person 的连接，并自动检测 `PATH` 中可用的 Agent CLI（`agy`、`claude`、`codex`、`copilot`、`openclaw`、`opencode`、`hermes`、`gemini`、`pi`、`cursor-agent`、`kimi`、`kiro-cli`）。

### 3. 连接 Runtime、创建 Agent、分配任务

1. 在 1Person Web 端打开你的工作区，进入 **设置 → 运行时（Runtimes）**，你的机器应该已经作为一个活跃 Runtime 出现在列表中。
2. 进入 **设置 → Agents**，点击 **新建 Agent**，选择 Runtime 和 Provider，并给它起个名字——它将以这个名字出现在看板和评论中。
3. 在看板上创建一个 Issue 并分配给你的新 Agent。它会接手任务、在你的机器上执行，并实时汇报进度。

完整上手流程：[文档](https://www.1person.xyz/docs/zh) · [1Person 如何工作](https://www.1person.xyz/docs/zh/how-1person-works)

### 桌面端

[下载 1Person Desktop](https://1person.xyz/download)，支持 macOS、Windows、Linux。桌面端内置 CLI、启动时自动拉起 daemon，并把所在电脑注册为 Runtime——无需任何终端操作。

### 自部署

<details>
<summary><b>把整套系统跑在自己的基础设施上</b></summary>

<br/>

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/1person/main/scripts/install.sh | bash -s -- --with-server
1person setup self-host
```

需要 Docker。详见[自部署指南](SELF_HOSTING.md)、[高级自部署指南](SELF_HOSTING_ADVANCED.md)和 [AI 辅助自部署](SELF_HOSTING_AI.md)。

</details>

---

## 架构

```
        Web（浏览器）         Desktop（Electron）           iOS（Expo）
              │                        │                        │
              ▼                        │                        │
       ┌─────────────┐                 │    HTTPS + WebSocket   │
       │   Next.js   │                 │                        │
       │    Web 端   │                 │                        │
       └──────┬──────┘                 │                        │
              ▼                        ▼                        ▼
       ┌─────────────────────────────────────────────────────────────┐
       │            zserver — Zig 后端（zfinal 框架）                 │
       └───────────┬───────────────────────────────────┬─────────────┘
                   ▼                                   │
          ┌─────────────────┐                          │
          │  PostgreSQL 17  │                          │
          │    (pgvector)   │                          │
          └─────────────────┘                          │
                                            ┌──────────┴──────────┐
                                            │      Agent daemon   │  运行在你的机器上，
                                            │   (1person daemon)  │  紧邻你的代码
                                            └──────────┬──────────┘
                                                       │ 拉起
                              ┌────────────────────────┴────────────────────────┐
                              │  Antigravity · Claude Code · Codex · Cursor     │
                              │  Copilot · Gemini · Hermes · Kimi · Kiro CLI    │
                              │  OpenCode · OpenClaw · Pi                       │
                              └─────────────────────────────────────────────────┘
```

| 层级 | 技术栈 |
| --- | --- |
| Web | Next.js 16 (App Router)、React 19、TanStack Query + Zustand |
| Desktop | Electron（与 Web 端共享 `core` / `ui` / `views` 包） |
| Mobile | Expo / React Native（iOS，目前从源码构建） |
| 后端 | Zig 0.17（`zserver`，基于 `zfinal` 框架） |
| 数据库 | PostgreSQL 17 + pgvector |
| 实时 | WebSocket（Redis 用于限流与 WS fanout） |
| Agent Runtime | 本地 daemon，驱动任意[受支持的 Agent CLI](#支持的-agent-runtime) |

Monorepo 的所有 checkout 共享一个 PostgreSQL 容器；每个 worktree 使用独立数据库和端口。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 仓库结构

```
frontend/
  apps/web | desktop | mobile | docs
  packages/core | ui | views | tsconfig | eslint-config
backend/
  zserver/          Zig 后端 — src/modules、migrations、scripts、docs
  docs/             后端 / 运维笔记
  deploy/helm/      Helm charts
docs/               跨端工程计划 + 文档索引
archive/            历史材料，不属于产品文档
```

- `frontend/packages/core/` — 无头业务逻辑（React Query hooks、API client、Zustand stores）
- `frontend/packages/ui/` — 原子 UI 组件（零业务逻辑）
- `frontend/packages/views/` — 共享业务页面与组件
- `frontend/apps/docs/` — 对外文档站源码
- `frontend/apps/mobile/` — 独立 Expo App（仅共享 `core` 的类型）

工程规范与包边界见 [CLAUDE.md](CLAUDE.md)。

## 后端模块

Zig 后端包含 **50 个业务模块**，每个模块位于 `backend/zserver/src/modules/<name>/{handler,service,model,routes}.zig`，统一在 `src/router.zig` 注册。

### 产品核心

| 领域 | 模块 |
| --- | --- |
| 身份与租户 | `auth`、`user`、`workspace`、`invitation`、`token` |
| 工作管理 | `issue`、`project`、`label`、`comment`、`task`、`attachment`、`pin`、`assignee_frequency` |
| Agent | `agent`、`agent_template`、`squad`、`skill`、`daemon`、`runtime`、`cloud_runtime`、`autopilot` |
| 协作 | `chat`、`inbox`、`notification`、`notification_preference`、`realtime`、`health_realtime`、`contact` |
| 集成与运维 | `webhook`、`lark`、`billing`、`config`、`dashboard` |

### 业务基础设施

| 领域 | 模块 |
| --- | --- |
| 编排 | `pipeline`、`scheduler`、`task_queue_v2` |
| 增长与变现 | `commission`、`referral`、`content_matrix`、`token_economy`、`wallet` |
| 运营与体系 | `training`、`community_ops`、`compliance`、`role` |
| 平台服务 | `i18n`、`analytics_v2`、`media`、`connector`、`blockchain` |

每个模块都保留内存回退，无数据库即可运行（仅限开发/测试）。涉及外部服务的模块（云运行时执行、connector 调用、链上交易、通知投递、媒体存储）在接入真实服务前保留 mock 实现——准确清单与生产就绪说明见 [`backend/zserver/README.md`](backend/zserver/README.md)。

---

## 文档

| 我想…… | 从这里开始 |
| --- | --- |
| 使用 1Person | [文档站](https://www.1person.xyz/docs/zh) — 支持 English、简体中文、日本語、한국어 |
| 自部署 | [SELF_HOSTING.md](SELF_HOSTING.md) · [SELF_HOSTING_ADVANCED.md](SELF_HOSTING_ADVANCED.md) · [SELF_HOSTING_AI.md](SELF_HOSTING_AI.md) |
| 写脚本 / 跑 daemon | [CLI_AND_DAEMON.md](CLI_AND_DAEMON.md) · [CLI_INSTALL.md](CLI_INSTALL.md) |
| 参与贡献 | [CONTRIBUTING.md](CONTRIBUTING.md) · [CLAUDE.md](CLAUDE.md) · [AGENTS.md](AGENTS.md) |
| 了解后端 | [backend/zserver/README.md](backend/zserver/README.md) · [backend/docs/](backend/docs/) |
| 了解前端 / 产品计划 | [frontend/docs/](frontend/docs/) |
| 浏览完整文档索引 | [docs/README.md](docs/README.md) |
| 查看历史材料 | [archive/](archive/) |

## 开发

**环境要求：** [Zig](https://ziglang.org/) 0.17+、[Node.js](https://nodejs.org/) 20+、[pnpm](https://pnpm.io/) 10.28+、[Docker](https://www.docker.com/)

```bash
make dev                        # 一键完成环境、依赖、数据库、迁移并启动所有服务

pnpm --dir frontend typecheck   # TypeScript 类型检查
pnpm --dir frontend test        # TS 单元测试（Vitest）
make test                       # zserver（Zig）测试
make check                      # 全量验证：typecheck + 单元 + zserver + Playwright E2E
```

iOS 移动端代码位于 [`frontend/apps/mobile/`](frontend/apps/mobile/)，自己编译装到手机的方法见其 [README](frontend/apps/mobile/README.md)。worktree 支持、测试与问题排查见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 为什么叫 "1Person"？

1Person — **Mult**iplexed **I**nformation and **C**omputing **A**gent。

这个名字是在向 20 世纪 60 年代具有开创意义的操作系统 Multics 致意。Multics 首创了分时系统，让多个用户能够共享同一台机器，同时又像各自独占它一样使用。Unix 则是在有意简化 Multics 的基础上诞生的，强调一个用户、一个任务、一种优雅的哲学。

我们认为，类似的转折点正在再次出现。几十年来，软件团队一直处于一种单线程的工作模式：一个工程师处理一个任务，一次只专注于一个上下文。AI agents 改变了这个等式。1Person 将"分时"重新带回这个时代，只不过今天在系统中进行多路复用的"用户"，既包括人类，也包括自主代理。一个小团队不该因为人数少就显得能力有限——有了合适的系统，两名工程师加上一组 agents，就能发挥出二十人团队的推进速度。

## 开源协议

[Modified Apache 2.0（含商业限制）](LICENSE)。可自部署、可修改、可二次开发——具体条款见 [LICENSE](LICENSE)。
