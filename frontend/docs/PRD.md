# 1person — 产品需求文档 (PRD)

> **文档性质**：本 PRD 由现有代码反向归纳（reverse-engineered），描述**当前已实现**的产品能力与行为契约，作为产品、设计与工程的统一基准。与 README 的"目标愿景"不同，本文只说现状 —— 凡未实现的一律列入「范围外」。
>
> 数据来源：`packages/core/api`（类型定义 + API client）、`server/`（Go 生产后端）、`zserver/`（Zig 并行实现）、`apps/{web,desktop,mobile}` 路由与页面、`apps/*/CLAUDE.md` 架构基准。
>
> 最后同步于 2026-08。存放于 `docs/PRD.md`。

---

## 1. 产品概述

**1person** 是一个为「一人公司 / 微型团队」设计的模块化全栈自动化平台：让一个创始人在一套系统里，**管理 AI 智能体来完成真实工作**（写代码、改工单、回评论、跑自动化），并从"想法 → 任务 → 交付 → 沉淀为可复用资产"的全流程中持续累积体系资产（技能、自动规则、内容、分润、经济体），从而逼近"黑灯工厂 / 自动赚钱"。

一句话价值主张：

> **给"一个人"配一整支永不放假、随取随用、经验可沉淀的 AI 员工团队。**

### 1.1 双元定位（产品内同时成立）

| 视角 | 说的是什么 |
|------|-----------|
| **协作底座** | 类故障工单 + 项目管理：Issue / Project / Label / 成员 / 收件箱 / 评论 / 通知 |
| **AI 劳动力层** | Agent 智能体（真实执行任务、流式输出）、Skill 能力包、Runtimes 运行环境、Autopilot 无人值守规则、Squad 智能体编队、Chat 与 Agent 对话 |

这两个视角由"任务（task）+ 实时事件（realtime）"两层粘合：**人和 Agent 共同操作同一套 Issue 数据模型**，任何变更通过 WebSocket 事件流实时同步到各端。

### 1.2 平台形态（同一套后端，多端覆盖）

```
apps/web     — Next.js 桌面 Web（完整功能）
apps/desktop — Electron 打包桌面端（登录 + 核心详情页，本地 CLI 能力）
apps/mobile  — Expo/React Native 移动端（收件箱/聊天/我的任务/Issue 轻量操作）
CLI + daemon — 本地命令行 + Agent 守护进程（本地执行任务、与云端握手）
server/      — Go 生产后端（PostgreSQL 17 + Redis，WS 多实例同步）
zserver/     — 生产后端原型（Zig，内存 / PostgreSQL 双模式）
```

---

## 2. 目标用户与阶段画像

| 画像 | 核心诉求 | 对应能力 |
|------|---------|---------|
| 独立开发者 / 一人公司 | 用 AI 并行干活且不失控 | Agent + Task + 强制任务生命周期 |
| 微型产品团队 (2–10 人) | 轻量协作 + AI 辅助 | Issue / 项目 / 评论 / 成员/收件箱 |
| 熟悉 CLI 的工程用户 | 本地可控的 Agent 执行 | CLI + daemon + Runtime |
| 运营类用户 | 事件不丢失、知情可控 | Inbox（收件箱）3 级严重度 + 实时通知 |
| 想规模化的人 | 规则自动触发 Agent | Autopilot（cron/webhook/api 触发）|

---

## 3. 核心概念与统一数据模型

平台一切围绕 **三纵一横** 展开：

```
        ┌─────────────────────────── 横轴：Workspace（多租户隔离）───────────────┐
        │  Member(owner/admin/member) · Invitation · 权限(rules) · 通知偏好       │
        │                                                                           │
  纵轴A  Issue  — 工单/卡片：State · Priority · Assignee(member/agent/squad) ·     │
  纵轴B  Agent  — 智能体：Runtime · Skills · Env · Template · Status · 并发限制     │
  纵轴C  Rule   — 自动化：Autopilot(Task) · Trigger(cron/webhook/api) · 编排         │
        └──────────────────────────────────────────────────────────────────────────┘
                    横向穿越：Realtime WS 事件（issue:* / task:* / agent:* …）
```

### 3.1 核心实体

| 实体 | 关键字段/取值 | 备注 |
|------|--------------|------|
| **Issue** | `status ∈ {backlog, todo, in_progress, in_review, done, blocked, cancelled}`；`priority ∈ {urgent, high, medium, low, none}`；`assignee_type ∈ {member, agent, squad}` | 支持 `metadata`（扁平 KV：pipeline_status / pr_number 等）；`labels`；`reactions`；`subscribers`；父子（child-issue）；parent/due/start date |
| **Task** | `status ∈ {queued, dispatched, waiting_local_directory, running, completed, failed, cancelled}`；`result`（opaque）、`failure_reason`（`agent_error/connection_error/timeout/…`）| Agent 的一次执行；可重试（`parent_task_id` + `attempt`）|
| **Agent** | `runtime_mode ∈ {local, cloud}`；`status ∈ {idle, working, blocked, error, offline}`；`visibility ∈ {workspace, private}`；`runtime_config`；`model`；`max_concurrent_tasks` | 可与多 Skill / Env（脱敏）/ MCP 绑定 |
| **Skill** | 名称/描述/`content`(SKILL.md 50~200KB)/`config`/`files` | 可复用能力包；实例绑定到 Agent |
| **Runtime** | `status ∈ {online, offline}`；`visibility ∈ {private, public}`；`provider`；`metadata` | 局部 CLI 或云端节点 |
| **Autopilot** | `execution_mode ∈ {create_issue, run_only}`；`assignee_type ∈ {agent, squad}`；Trigger `{schedule(cron), webhook, api}` | 运行状态 `{issue_created, running, completed, failed, skipped}` |
| **Inbox** | `type ∈ {issue_assigned, mentioned, new_comment, task_completed, task_failed, …}`(17 种)；`severity ∈ {action_required, attention, info}`；`recipient_type ∈ {member, agent}` | 基于 event generation + `seq` 顺序游标；支持 `since` 增量拉取与 unread-count / mark-all-read |
| **NotificationPreference** | 分组 `{assignments, status_changes, comments, updates, agent_activity, system_notifications}`，值 `all|muted` | 工作区级偏好 |
| **Project** | `status {planned, in_progress, paused, completed, cancelled}`；`priority`；`lead_type {member, agent}`；`resources`（GitHub Repo / local_directory） | 资源可挂外部引用 |
| **Squad** | Leader(agent) + 成员(agent/member)；`member_type ∈ {agent, member}` | 给 Squad Dispatch → 解析为 leader |
| **Membership** | 工作区内 `role ∈ {owner, admin, member}` | 资源级 `can*` 规则（例：Agent 仅 owner/admin 可 edit/env）|

### 3.2 权限模型（子权限矩阵，见 `server` 及 `packages/permissions`）

- **工作区级**：`owner` > `admin` > `member`；邀请 pending/accepted/declined/expired。
- **资源级**：敏感操作（Agent env 明文、MCP secret、删除运行时）仅 owner/admin；`env` 轮询 `agent_env_revealed`/`agent_env_updated` 审计日志。
- **Agent 语境**：Agent actor 会话收到 403 对敏感读；`visibility` 控制谁可见。

### 3.3 实时事件命名空间（Realtime WS）

`activity:*`、`chat:*`、`comment:*`、`daemon:*`、`inbox:*`、`issue_labels:*`、`issue_metadata:*`、`issue_reaction:*`、`issue:*`、`member:*`、`reaction:*`、`subscriber:*`、`task:*`、`workspace:*`、`invitation:*`。

前端策略：**React Query 拥有 Server State**，WS 事件只做 invalidation / patch，从不直接写 Store；**Zustand 只存 Client State**（当前工作区、视图筛选、草稿、Modal）。

---

## 4. 功能范围（已实现）按模块逐束

> 标注：✅ 已实现在生产线（Go + Web App Router）；🔶 已实现但前台较弱；🗄 仅有 API / 原型后端，无前台业务页。

### 4.1 账号与工作区（Auth & Workspace） — ✅
- 认证：邮箱验证码发送/校验（dev 固定码）、Google OAuth、JWT + PAT；`/auth/callback`
- 工作区：创建/更新/切换；成员、邀请(resend/revoke/accept/decline)、角色(owner/admin/member)；离开
- 入职（onboarding）引导、工作区导航；
- 工作区内：设置 / profile / 通知偏好

### 4.2 Issue 工单系统 [核心] — ✅
- Issue CRUD + 全字段；列表 / 详情 / 按工作区、状态、标签、优先级筛选
- Quick-create（从 Chat / CLI 快速建单）；批量 update / batch-delete
- child-issue 树 + progress（parent 汇总 total/done）
- comments（评论 + `trigger-preview` 触发串预览）；reactions（comment & issue）
- subscribers / subscribe/unsubscribe
- 标签（listLabels / attach / detach —— label 多对多）
- metadata KV（agent pipeline 状态）；`/api/issues/{id}` 详情含 reaction/subscriber/label
- 关联 GitHub PR（listPullRequests / 状态与合并呈现）
- usage 面板（token 计数 per 工作区）

### 4.3 Agent 与任务执行 [核心] — ✅
- Agent CRUD / archive / restore；批量 archive & 删运行时；cancel-tasks；env 明文查看(owner/admin)；skills 绑定
- **Task 任务**：状态机如上；`listTaskMessages` 流式渲染 (text/think/tool_use/tool_result/error)；任务暂停/恢复、失败原因映射（`failure_reason` → 用户文案 + 破坏性呈现）
- **Agent TaskSnapshot**：所有活动任务 + 每 Agent 最近终态（"活动赢、否则最近终态" 的现场判断）
- Agent Template（知识库/support/debugger 等预置）

### 4.4 Skill 能力包 — ✅
- 工作区级 skill CRUD；`/api/skills`（列表省略 content，防 CLI 超时）；`/api/agents/:id/skills` 绑定；支持从 GitHub 仓库导入能力包

### 4.5 自动化：Autopilot + Chat — ✅
- **Rules**（schedule/webhook/api 触发）→ 分配 Agent/Squad → 生成 Issue 或仅执行
- 运行为 `AutopilotRun`，含 trigger_payload / result / failure_reason
- **Chat**：会话（list/get/create/update/delete）+ 消息（list/page 分页）— 消息支持 streaming，`getPendingChatTask` 前台判读用户输入 → Agent 执行
- `listPendingChatTasks` 查询外呼中断态

### 4.6 收件箱（Inbox）— ✅ 全端
- 17 种事件类型 + severity 三分级；`/api/inbox` 分页 + `before_seq` 游标；unread-count；mark-all-read；archive；`recipient_type` 支持 member 与 agent 各自的盒子
- 移动端 Tab：Inbox

### 4.7 评论与通知 — ✅
- 评论系统 + trigger-preview；通知偏好（6 分组；all/muted）；通知规则/模板（Subscribe 通知；push 依赖平台通知能力，见 `docs/`）

### 4.8 全局搜索 — ✅
- `/api/issues/search`、`/api/projects/search`（command palette）+ `match_source {title, description, comment}` 语义标注

### 4.9 项目 / 标签 / 置顶 (Pins) — ✅
- Project（status/priority/lead + resources：GitHub/local_directory）
- Label 二级；`/pins` 侧边栏：Pin（issue/project）Reorder

### 4.10 Squad 智能体编队 — ✅
- Squad：leader(agent) + 成员(agent/member)；dispatch 到 leader；成员 status 列表；活动日志

### 4.11 Runtimes & 模型管理 — ✅
- 运行时列表（local/cloud）；模型推理/回看（initiate→getUpdateResult）；local skills 列举/导入；cloud Runtime 节点生命周期（create/start/stop/reboot/exec/status）

### 4.12 计费 (Billing) — ✅
- Balance / Transactions / Batches / PriceTier / Checkout(信用卡) / Portal；按 Agent/工作区计费额度

### 4.13 汇报与用量 — ✅
- Agent 活动 30 天；审计；compliance(合规) 规则 + audit log

---

## 5. 主要用户流程

### 流程 1：首次使用（新用户 → onboarding）
1. 邮箱验证码 / Google 注册 → 创建第一个工作区
2. 欢迎页引导 → 创建 Agent → 开始建第一个 Issue 或 Chat

### 流程 2：把一件事交给 Agent（标准流程）
1. 在 Issue 详情：「Assign to Agent」（或 `@提及`）
2. Agent 收到 inbox + 实时事件；Task queued → dispatched → running
3. 流式输出（thinking/tool_use）在 Issue/聊天窗口实时可见
4. 完成 → `task_completed` → inbox 通知；失败 → `task_failed` + 文案

### 流程 3：自动推进（Autopilot）
1. 定义 Rule（cron / webhook 触发）
2. Rule 触发 → 分配 Agent/Squad → 创建 Issue 或 直接运行
3. 失败时可手动重放（delivery replay）

### 流程 4：移动端轻量接管
- 手机查看 Inbox（各类事件）、回复 Chat、分配 Issue；深度操作回桌面端

## 6. 跨功能需求（非功能 + 工程契约）

| 领域 | 约束 / 已经实现 |
|------|----------------|
| **实时** | 单 WS 通道多事件命名空间；Redis pub/sub 跨多实例同步 |
| **数据一致性** | React Query 作为 ServerState，一切靠 WS 事件 Invalidate；Zustand 只存 ClientState |
| **网络韧性** | 每个 API 调度的 schema 校验 + `.loose()` 宽松 + `parseWithFallback`，任何严重畸变不白屏、回退到 `EMPTY_*`（API 类型安全覆盖 → 持续审计中）|
| **实时消息** | `listChatMessagesPage` 降级：`/page` 端点 404 时回退整份 `/messages`，保证旧后端或新版本不放白 |
| **安全** | JWT + PAT + 多 token 类型；env / MCP secret 的明文读取仅 owner/admin；敏感操作写审计日志；`lark/github` 绑定需来源 reconcile |
| **可访问性 a11y** | （正在审计）|
| **JSON/URL** | 遵循团队约定（见 CLAUDE.md / server）|

## 7. 非功能指标（已能观测）

- 收件框 unread 计数实时更新；
- 任务状态 CPU(O(1)) 支撑「每 Agent 现场即时不卡」；
- `/issues/search` 跨工作区；
- 错误 = fallback 而非白屏 —— 单接口缺陷不强于整个面板。

## 8. 平台覆盖矩阵（依现有）

| 功能 | Web | Desktop | Mobile | CLI |
|------|:---:|:-------:|:------:|:---:|
| Issue 创建/编辑/分配 | ✅ | ✅ | 🔶(轻量) | ✅(新建/编辑) |
| Task 状态/流式输出 | ✅ | 🔶(任务明细页) | — | ✅ |
| Agent 管理 | ✅ | ✅ | 🔶 | ✅ |
| Skill | ✅ | 🔶 | — | ✅(本地 list/import) |
| 收件箱/聊天 | ✅ | ✅ | ✅ | — |
| Autopilot | ✅ | ✅ | — | — |
| 搜索 | ✅ | — | — | — |
| Billing/用量 | ✅ | — | — | — |
| 权限/审计 | ✅ | — | — | ✅ |

## 9. 关键产品决策与既有取舍（技术前置合约）

- **技术线**：Go 生产 + Zig 原型 + monorepo `@1person`（core/ui/views 分包）；
- **schema 防线**：`packages/core/api` + `parseWithFallback` 约定，所有读走宽松 schema（`.loose()`），在两端防新键/新枚举漂移引发的渲染崩溃。
- **AI 与产品**：Agent 是"员工"而非"功能"；系统以「任务生命周期」为第一公民，确保人能发现 Agent 的每一步。

## 10. 关键业务指标（建议观测北极星）

- **派发效率**：一次分配 → Agent 交付的完成率（`task_completed / task` 总数）
- **自动进展占比**：Autopilot 触发任务 vs 手动创建任务的比例
- **协作留存**：工作区周活（成员每周新建/更新 Issue、读取 Inbox 次数）
- **可控性**：失败/阻塞任务的可重试率（`attempt > 1` 占比）、中止率
- **资产沉淀**：Skill 使用率、绑定 Agent 数、被复用的能力包数

## 11. 边界与非目标（反向往现有代码的真实约束）

反向归纳当前**明确不为**的能力子集：

1. **不做完全无监督的全自动**：每条 Agent 任务都保持可中止/暂停/失败可见的生命周期；失败需人工介入或 Autopilot 显式重放；`waiting_local_directory` 等人工状态会推给用户而非静默卡死。
2. **不做跨工作区共享**：一切读写按 Workspace 强隔离；`visibility: private` 仅对 owner 可见；env 明文、MCP secret、运行时删除均限 owner/admin 并写审计日志。
3. **产品边界**：平台侧重「工单 + AI 劳动力」，不做通用文档/表格/日历套件 —— 这些由 Skill 与 GitHub / 本地目录资源替代。
4. **遗留模块**：`analytics / media / connectors / blockchain / task_queue / audit / scheduler / training / referral / token / commission / pipeline / community` 等仅有 API 或 zserver 原型、无前台业务页，属长尾，不在本期 PRD 主线。

若出现与上述冲突的新需求，请在文末「变更记录」登记后再调整范围框架。

---

## 附注

- 本 PRD **随时更新**：新增功能/端请在上文「4. 功能范围」补一行并标注 ✅/🔶/🗄。
- 规格与实现细节以 `CLAUDE.md`、`docs/design.md`、`docs/deployment.md`、`docs/*.md` 为链；本文为主干视图。
- 本文件是**现有能力的契约**，与 README 的「未来愿景」不同；愿景类描述不入此处。