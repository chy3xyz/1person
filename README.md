# 1person

**一人公司基础设施。一个想法 → 一套体系 → 自动赚钱。**

1person 是一个模块化的全栈平台，为"一人公司"提供从 0 到 1 的完整自动化基础设施：Pipeline 编排、多级角色管理、分润结算、内容矩阵分发、裂变追踪、代币经济、培训认证、钱包支付、多语言、合规审计、社群运营。

---

## 架构

```
frontend/
  apps/web | desktop | mobile | docs
  packages/core | ui | views

backend/zserver (Zig, zfinal)
  ├── modules + migrations
  ├── Redis pub/sub (WS 多实例)
  └── e2e scripts (no-DB + PostgreSQL)
```

## 文档

| 位置 | 说明 |
|------|------|
| [`docs/`](docs/) | 文档索引 + 跨端工程计划 |
| [`frontend/docs/`](frontend/docs/) | 产品 / 设计 / 前端计划（含 [PRD](frontend/docs/PRD.md)） |
| [`backend/docs/`](backend/docs/) | 后端 / 部署 / daemon |
| [`frontend/apps/docs/`](frontend/apps/docs/) | 对外文档站（Fumadocs） |
| [`archive/`](archive/) | 非本品历史材料（不参与产品文档） |

---

## 模块总覽

### 核心业务模块 (17 模块)

| 模块 | 说明 |
|------|------|
| **auth** | 认证 (JWT + PAT + 1d_ + 多 token 类型) |
| **issue** | 工单系统 (CRUD + metadata + reaction + subscriber + label + dependency) |
| **workspace** | 多租户隔离 (invite + member 管理) |
| **project** | 项目分组 (status/priority/resource CRUD) |
| **label** | 标签管理 (issue 多对多关联) |
| **skill** | 可复用能力包 |
| **agent** | Agent 管理 (CRUD + env + skill + archive/restore + cancel-tasks) |
| **agent_template** | Agent 预置模板 (知识库/support/debugger/...) |
| **autopilot** | 自动化引擎 (webhook + cron trigger + delivery replay) |
| **daemon** | 本地 worker 协议 (register/heartbeat/claim/start/progress/complete) |
| **cloud_runtime** | 云节点生命周期 (create/start/stop/reboot/exec/status) |
| **chat** | 实时聊天 |
| **inbox** | 事件收件箱 (seq/since + unread-count + mark-all-read) |
| **dashboard** | 使用统计 (daily/by-agent/agent-runtime) |
| **comment** | 评论系统 (trigger-preview) |
| **billing** | 计费 |
| **webhook** | Webhook 管理 |

### 共性基础设施模块 (12 模块) — 新建

| 模块 | 端点 | e2e | 说明 |
|------|------|-----|------|
| **pipeline** | 9 | 10/10 | Pipeline 编排引擎 (config CRUD + run + phase complete) |
| **role** | 12 | 10/10 | 多级角色/权限 (defs + members + downline + upline) |
| **commission** | 9 | 6/6 | 分润/佣金引擎 (rule + calculate + settle) |
| **content_matrix** | 8 | 6/6 | 内容矩阵分发 (platform + distribute + results) |
| **referral** | 8 | 8/8 | 邀请/裂变追踪 (code + track + activate + tree) |
| **token_economy** | 8 | 8/8 | 代币/积分经济 (earn + spend + transfer + balance) |
| **training** | 12 | 8/8 | 培训/认证体系 (course + lesson + enroll + certificate) |
| **wallet** | 6 | 8/8 | 支付/钱包 (deposit + withdraw + reward + transactions) |
| **i18n** | 3 | 5/5 | 多语言 (locale + translation) |
| **compliance** | 6 | 6/6 | 合规/审计 (rule + run + audit log) |
| **community_ops** | 7 | 7/7 | 社群运营 (group + member + announcement + digest) |
| **dashboard_v2** | 2 | 4/4 | 可配置看板 (config + widget data) |

---

## 快速开始

### 后端

```bash
cd backend/zserver
zig build                        # 编译
# 无 DB 模式 (内存存储)
JWT_SECRET=my-secret ONEPERSON_DEV_VERIFICATION_CODE=000000 ./zig-out/bin/zserver server --port 8090
# PostgreSQL 模式
DATABASE_URL="postgres://user:pass@localhost/db?sslmode=disable" JWT_SECRET=my-secret ./zig-out/bin/zserver server --port 8090
```

### 运行所有测试

```bash
cd backend/zserver
make ci                           # 24 e2e + 30 前端集成, 全部自动运行
```

### 前端

```bash
cd frontend/apps/web
pnpm dev                          # Next.js dev server
pnpm typecheck                    # TypeScript 类型检查
```

---

## 方案文档

见 [`docs/`](docs/) 索引。产品与前端计划在 [`frontend/docs/`](frontend/docs/)，后端与部署在 [`backend/docs/`](backend/docs/)。与本品无关的历史材料在 [`archive/`](archive/)，不列入产品文档。

---

## 开发

**前提**: [Zig](https://ziglang.org/) 0.17+, [Node.js](https://nodejs.org/) 20+, [pnpm](https://pnpm.io/)

```bash
# 后端
cd backend/zserver && zig build test

# 前端
cd frontend/apps/web && pnpm dev

# 全量验证
cd backend/zserver && make ci
```

## License

MIT
