# 一人公司 · 黑灯工厂 演进方案

> 目标：将 1Person 从"人+AI 协作的项目管理平台"演进为"一人公司全自动运营系统"。
> 黑灯工厂 = 零人工干预，Agent 自主扫描、决策、执行、闭环。

---

## 一、已有基础（可直接复用）

| 能力 | 说明 | 黑灯价值 |
|------|------|---------|
| **Agent 执行引擎** | Autopilot + Trigger + Agent + Task Queue | AI 领任务 → 拆子任务 → 执行 → 上报 |
| **Daemon worker** | 注册/心跳/claim/start/progress/complete | 本地/云端节点 7×24 运行 |
| **Webhook + Cron** | 外部事件 + 定时触发 | 监听 GitHub/Stripe/webhook；定时报告 |
| **Skill 系统** | 可复用能力包 | 报税 skill、客服 skill、部署 skill |
| **WS 实时推送** | issue/subscriber/reaction/metadata 全事件 | UI 实时刷新，无需轮询 |
| **Comment trigger-preview** | `@agent-name` 触发执行 | 直接 `@accountant 报税` |
| **Audit Log** | 所有操作记入 `uploads/audit/` | 全量可回溯 |
| **Redis Pub/Sub** | 多实例 WS 同步 | 水平扩展 |
| **zserver** | 单进程内存存储 + 可选 PG | 零依赖快速部署 |

---

## 二、需要新增的核心模块

### 1. Agent 自主决策层（P0 — 核心引擎）

```
现在：人类创建 issue → autopilot 分配给 agent → 执行
目标：Agent 自身扫描 issue → 评估能力 → claim → 执行 → close
```

**组件**：

- **Agent Scheduler**：定期扫描 `state=todo` 的 issue，按 skill 匹配 agent，自动 claim
- **Plan Generator**：agent 收到任务后拆分为子 task（DAG），预估工时
- **Self-Validation**：agent 执行完成后自动跑 test/lint/typecheck，通过才 close
- **Feedback Loop**：失败后自主重试或创建 follow-up issue

### 2. Supervisory Agent（P1 — 监管层）

```
CEO Agent 每日巡检：
  ① 所有 agent 状态（在线/队列长度/错误率）
  ② 资金流（收入/支出/余额）
  ③ 异常告警（超预算/连续失败/合同到期）
  ④ 生成每日健康报告
```

**规则**：

- 超过预算 → 暂停关联 agent → @owner 审批
- 连续 3 次失败 → 自动降级，人工介入
- 合同/合规到期前 7 天 → 提醒

### 3. 业务模块（P2-P3 — 一人公司刚需）

| 模块 | 说明 | 优先级 |
|------|------|--------|
| **Billing/Invoice** | Stripe 集成，自动开票、催款、对账 | P2 |
| **Finance/Ledger** | 收支记账，agent 每月生成报表 | P2 |
| **Customer Support** | 工单 + agent 自动回复 + 知识库检索 | P3 |
| **Marketing** | 定时推文、SEO 报告、竞品监控 | P3 |
| **HR/Compliance** | 合同模板、税务日历、合规检查 | P3 |
| **Deploy/CI** | Agent 自动 deploy、rollback、日志巡检 | P3 |

---

## 三、黑灯运行架构

```
                       ┌────────────────────────┐
                       │   Supervisory Agent     │
                       │  "CEO Agent"            │
                       │  健康巡检 + 决策审批      │
                       └───────────┬────────────┘
           ┌───────────────────────┼───────────────────────┐
           ▼                       ▼                       ▼
   ┌─────────────┐        ┌─────────────┐        ┌─────────────┐
   │ DevOps Agent│        │ Finance Ag. │        │ Support Ag. │
   │ deploy      │        │ invoice/tax │        │ ticket/reply│
   │ monitor     │        │ ledger      │        │ knowledge   │
   └──────┬──────┘        └──────┬──────┘        └──────┬──────┘
          │                      │                      │
          └──────────────────────┼──────────────────────┘
                                 ▼
                       ┌────────────────────────┐
                       │    Daemon Workers       │
                       │  本地 + 云端执行节点      │
                       │  信用：report/output    │
                       └────────────────────────┘
                                 │
                                 ▼
                       ┌────────────────────────┐
                       │    External Systems     │
                       │  GitHub / Stripe /      │
                       │  Slack / Email / VPS    │
                       └────────────────────────┘
```

**关键流**：

1. **事件注入**：GitHub webhook/Stripe event/Cron → 创建 issue（todo）
2. **Agent Scheduler 扫描** → 匹配 skill → claim（state=in_progress）
3. **Agent 拆分执行** → 子 task 队列 → daemon worker 执行
4. **结果验证** → pass → close issue；fail → 重试或 create follow-up
5. **Supervisory Agent** → 每日巡检 → 异常告警 → @owner

---

## 四、实施路径

| 阶段 | 内容 | 估时 |
|------|------|------|
| **P0** | Agent 自主 claim + Plan Generator + Self-Validation | 2-3 周 |
| **P1** | Supervisory Agent + Escalation + 每日健康报告 | 1-2 周 |
| **P2** | Billing/Finance 模块（Stripe + 报表） | 2-3 周 |
| **P3** | Support/Marketing/Compliance 模块 | 3-4 周 |
| **P4** | 黑灯 Dashboard + 一键启动脚本 + 部署文档 | 1-2 周 |

---

## 五、风险与缓解

| 风险 | 缓解 |
|------|------|
| Agent 幻觉/错误操作 | Self-Validation + Escalation + Audit Log |
| 资金操作风险 | Stripe 限额 + 人工审批闸门 |
| 单点故障（Agent 宕机） | Supervisor 检测 + 自动重启 |
| zserver 内存存储数据丢失 | 定期备份到 PG + JSONL audit log |
| 多 Agent 并发冲突 | issue claim 原子操作（数据库行锁） |

---

## 六、zserver 侧改动预估

| 改动 | 说明 |
|------|------|
| Agent Scheduler（新增） | 后台 goroutine 扫描 issue + claim |
| Plan Generator（新增） | Agent 自主拆子任务 |
| Task DAG（已有） | 扩展为有依赖关系的 DAG |
| Self-Validation（已有 skill） | 封装为内置 skill |
| Health Check API（已有 `/health`） | 扩展 supervisor agent 查询 endpoint |
| Escalation 规则引擎（新增） | 阈值配置 + 自动暂停 |
| Dashboard（已有） | 扩展为黑灯专用视图 |

---

## 七、结论

1Person 的 Agent/Autopilot/Daemon/Skill 四件套 + zserver 轻量执行引擎 + 内存/PostgreSQL 双存储，**已具备黑灯工厂的核心架构基础**。

剩余工作是增量式的：Agent 自主决策 + 业务模块 + 监管层。不是推倒重来，而是在现有框架上叠加三块拼图即可成型。
