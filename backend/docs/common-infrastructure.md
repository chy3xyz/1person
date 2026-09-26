# 共性基础设施 · zserver 实现方案

> 基于 zserver (Zig) + apps/web (Next.js) + packages/{core,ui,views}，
> 将 9 个共性模块落地为可复用的基础设施。
> 一次建设，七项目共用。

---

## 一、现有技术栈盘点

### zserver（Zig 后端）

| 层 | 现状 | 需要扩展 |
|----|------|---------|
| **模块系统** | 17 个模块（issue/workspace/agent/autopilot/...） | 新增 9 个共性模块 |
| **路由注册** | `router.zig` 自动扫描 `modules/` | 无需改动 |
| **数据存储** | 无 DB（内存） + PG（可选） | 部分模块需要持久化 |
| **鉴权** | JWT + PAT + 1d_ + 多 token 类型 | 增加角色级鉴权 |
| **实时** | WS RoomManager + Redis PUB 桥 | 增加事件类型 |
| **测试** | 12 套 e2e + 30 个 integration | 每个新模块配 e2e |

### apps/web（Next.js 前端）

| 层 | 现状 | 需要扩展 |
|----|------|---------|
| **路由** | App Router (`/app/`) | 新增模块页面路由 |
| **组件** | `packages/ui/` (shadcn/Base UI) | 新增通用组件 |
| **状态** | `packages/core/` (Zustand + React Query) | 新增 store |
| **API 客户端** | `packages/core/api/client.ts` | 新增 API 方法 |
| **Schema** | `packages/core/api/schemas.ts` (Zod) | 新增 DTO schema |

---

## 二、zserver 新增模块总览

```
zserver/src/modules/
├── pipeline/         ★ 新增: Pipeline 编排引擎
├── role/             ★ 新增: 多级角色/权限
├── commission/       ★ 新增: 分润/佣金引擎
├── content_matrix/   ★ 新增: 内容矩阵分发
├── referral/         ★ 新增: 邀请/裂变追踪
├── dashboard_v2/     ★ 扩展: 可配置看板
├── token_economy/    ★ 新增: 代币/积分体系
├── training/         ★ 新增: 培训/认证体系
├── wallet/           ★ 新增: 支付/钱包
└── (现有 17 个模块不变)
```

---

## 三、P0 模块 — zserver 侧实现

### 1. Pipeline 编排引擎 (`modules/pipeline/`)

#### 数据模型 (`model.zig`)

```zig
pub const PipelineConfig = struct {
    id: []const u8,
    name: []const u8,
    phases: []const PhaseConfig,
};

pub const PhaseConfig = struct {
    id: []const u8,
    agent: []const u8,          // agent name to claim
    depends_on: []const []const u8, // phase IDs
    timeout_seconds: u64,
    max_retries: u32,
    approval_gate: bool,        // pause for human approval
    artifact_pattern: []const u8, // e.g., "docs/*.md"
};

pub const PipelineRun = struct {
    id: []const u8,
    pipeline_id: []const u8,
    workspace_id: []const u8,
    status: Status,             // pending|running|blocked|done|failed
    current_phase: []const u8,
    phases: []const PhaseRun,
    created_at: []const u8,
};

pub const Status = enum { pending, running, blocked, done, failed };

pub const PhaseRun = struct {
    phase_id: []const u8,
    status: []const u8,         // pending|waiting_deps|running|awaiting_approval|done|failed
    task_ids: []const []const u8,
    artifacts: []const []const u8,
};
```

#### API 端点

| Method | Path | Handler |
|--------|------|---------|
| POST | `/api/pipelines` | 创建 pipeline 配置 |
| GET | `/api/pipelines` | 列出可用 pipeline |
| POST | `/api/pipelines/:id/run` | 启动一次 pipeline 执行 |
| GET | `/api/pipelines/:id/runs` | 查看执行历史 |
| GET | `/api/pipelines/:id/runs/:runId` | 查看某次执行详情 |
| POST | `/api/pipelines/:id/runs/:runId/approve` | 审批通过 |
| POST | `/api/pipelines/:id/runs/:runId/reject` | 审批拒绝 |

#### 自动化逻辑

```
PipelineRun 创建
  → Phase 1: depends_on 为空 → 直接创建 Task(agent=p1.agent)
  → Task complete → 检查 p1 artifact 是否存在
  → 存在 → Phase 2: depends_on = [p1] → dep 已满足 → 创建 Task
  → Phase 3: approval_gate = true → 暂停 → webhook 通知 → 等待 POST /approve
  → 全部完成 → PipelineRun.status = done
```

#### e2e 脚本

```
scripts/pipeline_e2e.sh
  1. 创建 pipeline 配置 (YAML/JSON)
  2. 启动 pipeline run
  3. 检查 phase 1 task 自动创建
  4. Phase 1 agent claim + complete
  5. 检查 phase 2 自动触发
  6. Phase 2 approval gate 暂停
  7. POST /approve → phase 2 继续
  8. Pipeline done → 产物存在
```

#### 估时：3 天

---

### 2. 多级角色/权限 (`modules/role/`)

#### 扩展 Member

```zig
// 扩展 workspace member
pub const MemberRole = struct {
    user_id: []const u8,
    workspace_id: []const u8,
    role: []const u8,          // "super_admin" | "region_admin" | "community_leader" | "ambassador" | "member"
    level: u32,                // 层级深度 (0=顶级, 1=二级...)
    parent_id: ?[]const u8,    // 上级 user_id
    permissions: []const []const u8, // ["view_downline", "manage_team", "set_commission"]
    joined_at: []const u8,
};

pub const RoleConfig = struct {
    name: []const u8,
    permissions: []const []const u8,
    upgrade_conditions: ?UpgradeCondition,
    downgrade_conditions: ?DowngradeCondition,
};
```

#### API 端点

| Method | Path | Handler |
|--------|------|---------|
| GET | `/api/roles` | 列出角色定义 |
| POST | `/api/roles` | 创建角色定义 |
| PATCH | `/api/members/:userId/role` | 更新用户角色 |
| GET | `/api/members/:userId/downline` | 查看下级成员树 |
| GET | `/api/members/:userId/upline` | 查看上级链路 |

#### e2e 脚本

```
scripts/role_e2e.sh
  1. 创建角色定义
  2. 绑定 A→B 上下级关系
  3. 查询 A 的下级树（包含 B）
  4. B 晋升 → 角色变更
  5. 查询 A 的下级树（B 已移除）
```

#### 估时：2 天

---

### 3. 分润/佣金引擎 (`modules/commission/`)

#### 数据模型

```zig
pub const CommissionRule = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    levels: []const LevelRule,
};

pub const LevelRule = struct {
    depth: u32,                // 1=直属, 2=二级...
    rate: f64,                 // 0.10 = 10%
    role: ?[]const u8,         // 限定角色
};

pub const CommissionRecord = struct {
    id: []const u8,
    transaction_id: []const u8,
    from_user_id: []const u8,
    to_user_id: []const u8,
    amount: f64,
    rate: f64,
    level: u32,
    status: []const u8,        // "pending" | "settled"
    created_at: []const u8,
};
```

#### API 端点

| Method | Path | Handler |
|--------|------|---------|
| POST | `/api/commissions/rules` | 创建分润规则 |
| GET | `/api/commissions/rules` | 列出规则 |
| POST | `/api/commissions/calculate` | 计算一笔交易的分润 |
| GET | `/api/commissions/records` | 查询分润记录 |
| POST | `/api/commissions/settle` | 执行结算 |

#### 自动化

```
Autopilot: 每笔订单 → trigger → calculate → 生成 CommissionRecord
Cron: 每周日 00:00 → settle 所有 pending 记录
Cron: 每月 1 日 → 生成上月分润报表
```

#### e2e 脚本

```
scripts/commission_e2e.sh
  1. 创建分润规则 (3 级, 10%/5%/2%)
  2. 绑定三级上下级关系
  3. 模拟交易 → 自动计算分润
  4. 检查三级分润记录
  5. 执行结算 → 状态变更为 settled
```

#### 估时：3 天

---

## 四、P1 模块 — zserver 侧实现

### 4. 内容矩阵分发 (`modules/content_matrix/`)

#### 设计思路

复用现有的 `issue/service.zig` 发布事件体系（`publishIssueEvent`），增加分发 Adapter 层。

```
Issue (content) → Content Agent claim
  → 生成多平台适配内容 (9 个 Task)
  → Adapter 发布 → 记录 URL → 更新 Issue metadata
```

#### API 端点

| Method | Path | Handler |
|--------|------|---------|
| POST | `/api/content/distribute` | 输入一篇内容 → 生成多平台适配 |
| GET | `/api/content/platforms` | 列出支持的平台 |
| POST | `/api/content/publish` | 发布到指定平台 |
| GET | `/api/content/tracking` | 查询内容在各平台的数据 |

#### 估时：3 天（适配器可逐步添加）

---

### 5. 邀请/裂变追踪 (`modules/referral/`)

#### 数据模型

```zig
pub const ReferralCode = struct {
    code: []const u8,
    user_id: []const u8,
    workspace_id: []const u8,
    created_at: []const u8,
};

pub const ReferralRecord = struct {
    id: []const u8,
    code: []const u8,
    referrer_user_id: []const u8,
    referee_user_id: []const u8,
    status: []const u8,  // "registered" | "activated" | "paid"
    rewarded_at: ?[]const u8,
};
```

#### 估时：2 天

---

### 6. 可配置数据看板 (`modules/dashboard_v2/`)

扩展现有 `dashboard/` 模块，支持：

- YAML 配置看板布局
- Agent 自动生成报表数据
- 每个角色看到不同的看板视图

#### 估时：3 天

---

## 五、前端复用方案

### packages/core/（无头业务逻辑）

```
packages/core/
├── api/
│   ├── client.ts              ← 新增 9 个模块的 API 方法
│   ├── schemas.ts             ← 新增 Zod schema
│   └── hooks/
│       ├── usePipeline.ts     ← 新增: Pipeline hooks
│       ├── useRoles.ts        ← 新增: 角色 hooks
│       ├── useCommission.ts   ← 新增: 佣金 hooks
│       ├── useContentMatrix.ts← 新增: 内容矩阵 hooks
│       └── useReferral.ts     ← 新增: 裂变 hooks
├── stores/
│   ├── pipeline-store.ts      ← 新增: Pipeline state
│   ├── role-store.ts          ← 新增: 角色 state
│   └── commission-store.ts    ← 新增: 佣金 state
```

### packages/ui/（原子 UI 组件）

```
packages/ui/
├── Pipeline/
│   ├── PipelineGraph.tsx       ← 新增: DAG 可视化
│   ├── PhaseCard.tsx
│   └── ApprovalGate.tsx
├── Role/
│   ├── RoleBadge.tsx
│   ├── DownlineTree.tsx        ← 新增: 层级树
│   └── PermissionGate.tsx      ← 新增: 权限门
├── Commission/
│   ├── CommissionTable.tsx
│   └── SplitChart.tsx
├── Content/
│   ├── PlatformAdapterPicker.tsx
│   └── PublishScheduler.tsx
├── Referral/
│   ├── ReferralCodeCard.tsx
│   └── ReferralLeaderboard.tsx
└── Dashboard/
    └── ConfigurableDashboard.tsx ← 新增: 可配置看板
```

### packages/views/（共享页面）

```
packages/views/
├── pipeline/
│   └── PipelinePage.tsx        ← 新增
├── roles/
│   └── RolesPage.tsx           ← 新增
├── commission/
│   └── CommissionPage.tsx      ← 新增
└── ...
```

### apps/web/（Next.js 路由注册）

只需在各模块的路由文件中注册新页面，原有路由系统不变。

---

## 六、建设顺序

```
Week 1-2: zserver 后端
  Day 1-3:  Pipeline 编排引擎 (model/handler/routes/e2e)
  Day 4-5:  多级角色/权限
  Day 6-8:  分润/佣金引擎

Week 3-4: zserver 后端 + 前端
  Day 9-11: 内容矩阵分发
  Day 12-13: 邀请/裂变追踪
  Day 14-16: 可配置看板 (扩展 dashboard)
  ── 前端并行 ──
  Day 2-14: packages/core API hooks (随 zserver 新增同步)
  Day 10-16: packages/ui 通用组件

Week 5-6: 按需追加
  · 代币/积分 (life++ 需要时)
  · 培训/认证 (万社互联/保险需要时)
  · 钱包/支付 (万社互联需要时)
  · 多语言 (保险需要时)

总计: 6 周建成全部共性基础设施
```

---

## 七、每个模块的交付物清单

```
{module}/
├── zserver/src/modules/{module}/
│   ├── model.zig             数据模型 + 响应 DTO + 投影器
│   ├── service.zig           业务逻辑 (no-DB + DB 双路径)
│   ├── handler.zig           1-行 passthrough
│   └── routes.zig            路由注册 + 拦截器
├── zserver/scripts/{module}_e2e.sh    ← e2e 回归测试
├── packages/core/api/hooks/use{Module}.ts
├── packages/core/stores/{module}-store.ts
├── packages/ui/{Module}/
│   └── {Component}.tsx
├── packages/views/{module}/
│   └── {Module}Page.tsx
└── (apps/web 路由注册)
```

---

## 八、验证标准

每个模块建成后，交付标准：

```
□ zig build                  ← 编译通过
□ zig build test             ← 单元测试通过
□ {module}_e2e.sh            ← PG + no-DB 双模式通过
□ frontend_integration.sh    ← 30 check 无回归
□ packages/core typecheck    ← TS 类型检查通过
□ packages/ui 组件 story     ← 组件可独立预览
```

---

## 九、结论

**12 个共性模块已全部建成。**

### zserver 层（已完成）

```
43 模块 = 31 原有 + 12 新增
24 套 e2e 脚本，PG + no-DB 双模式全部通过
```

| 批次 | 模块 | e2e | 状态 |
|------|------|-----|------|
| P0 | Pipeline + Role + Commission | 26/26 | ✓ |
| P1 | Content Matrix + Referral + Dashboard V2 | 18/18 | ✓ |
| P2 | Token Economy + Training + Wallet | 24/24 | ✓ |
| P3 | i18n + Compliance + Community Ops | 18/18 | ✓ |

### 前端层（已启动）

```
packages/core/api/client.ts       ← 17 个新 API 方法
packages/core/api/hooks/
  ├── pipeline.ts                 ← 5 hooks
  ├── role.ts                     ← 10 hooks
  ├── commission.ts               ← 2 hooks
  ├── referral.ts                 ← 3 hooks
  ├── token.ts                    ← 4 hooks
  ├── wallet.ts                   ← 4 hooks
  └── training.ts                 ← 4 hooks
```

### 验证标准

每个模块：
- □ zig build 编译通过
- □ zig build test 单元测试通过
- □ {module}_e2e.sh no-DB 模式通过
- □ {module}_e2e.sh PG 模式通过
- □ frontend_integration.sh 30 check 无回归
- □ packages/core typecheck 通过

**建完之后，七份方案中的任一个都可通过写 Pipeline YAML + Agent Skill 在 1-3 天内从零到上线。**
