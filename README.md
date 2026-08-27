# 1person

**一人公司基础设施。一个想法 → 一套体系 → 自动赚钱。**

1person 是一个模块化的全栈平台，为"一人公司"提供从 0 到 1 的完整自动化基础设施：Pipeline 编排、多级角色管理、分润结算、内容矩阵分发、裂变追踪、代币经济、培训认证、钱包支付、多语言、合规审计、社群运营。

---

## 架构

```
frontend/apps/web (Next.js 16)
  ├── frontend/packages/core    — 无头业务逻辑 (React Query hooks + Zustand + API client)
  ├── frontend/packages/ui      — 原子 UI 组件 (shadcn/Base UI, 零业务逻辑)
  └── frontend/packages/views   — 共享业务页面

backend/zserver (Zig, zfinal)
  ├── 43 模块, 24 套 e2e (no-DB + PostgreSQL 双模式)
  ├── Redis pub/sub bridge (WS 多实例同步)
  └── 30 前端集成检查

server/ (Go, 生产用)
  └── PostgreSQL 17 + Redis
```

---

## 模块总覽

### 核心业务模块 (17 模块)

| 模块 | 说明 |
|------|------|
| **auth** | 认证 (JWT + PAT + mdt_ + 多 token 类型) |
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
JWT_SECRET=my-secret MULTICA_DEV_VERIFICATION_CODE=000000 ./zig-out/bin/zserver server --port 8090
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

所有方案在 `docs/` 目录下：

| 文档 | 内容 |
|------|------|
| `common-infrastructure.md` | 共性基础设施——zserver 实现方案 |
| `one-person-factory.md` | 黑灯工厂——已有业务全自动运营 |
| `idea-to-revenue.md` | 创意变现——想法→产品→赚钱全链路 |
| `geo-auto-delivery.md` | GEO 自动交付——实体商户 AI 营销代运营 |
| `theory-to-ecosystem.md` | 理论→社群→生态——知识 IP 自动化体系 |
| `meaningful-consumption-community.md` | 意义消费万社互联——社区电商网络 |
| `lifepp-digital-life-community.md` | life++ 数字生命社区——Web3 灵性科技 |
| `us-insurance-ai-platform.md` | 美国保险经纪人 AI 平台——SaaS 运营 |

---

## 开发

**前提**: [Zig](https://ziglang.org/) 0.17+, [Node.js](https://nodejs.org/) 20+, [pnpm](https://pnpm.io/), [Go](https://go.dev/) 1.26+

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
