# 创意变现 · 自动赚钱机器 方案

> 用户输入一个想法，系统自动完成：商业计划 → 产品设计 → 代码开发 → 测试 → 部署 → 市场运营 → 客户成交 → 财税处理。
> 全链路 Agent 驱动，零人工干预。黑灯工厂的终极形态。

---

## 一、全链路流水线

```
用户: "做一个 AI 菜谱推荐 App"
        │
        ▼
┌──────────────────────────────────────────────────┐
│  Phase 1  商业计划 Agent                          │
│  ───────────────────────                         │
│  输入：一句话想法                                  │
│  输出：BP 文档（市场分析/竞品/商业模式/定价/里程碑）    │
│  工具：Web Search + 行业报告 + LLM 推理             │
│  产出：issue 存档 + BP.md + 财务模型 sheet          │
├──────────────────────────────────────────────────┤
│  Phase 2  产品设计 Agent                          │
│  ───────────────────────                         │
│  输入：BP 文档                                    │
│  输出：PRD + 原型稿 + 设计系统                     │
│  工具：Figma MCP / HTML 原型 / 设计 token          │
│  产出：issue（按页面拆分）+ Figma 链接 + 颜色/字体     │
├──────────────────────────────────────────────────┤
│  Phase 3  代码开发 Agent                          │
│  ───────────────────────                         │
│  输入：PRD + 设计稿                                │
│  输出：可运行代码（前后端 + 部署配置）                │
│  工具：Daemon Worker + GitHub CLI + Codex CLI      │
│  产出：git repo + CI 配置 + Dockerfile             │
├──────────────────────────────────────────────────┤
│  Phase 4  测试 Agent                              │
│  ───────────────────────                         │
│  输入：代码仓库 + PRD                              │
│  输出：测试报告（unit/e2e/visual/performance）      │
│  工具：Vitest + Playwright + Lighthouse + QA skill │
│  产出：issue（bug list）+ coverage report          │
├──────────────────────────────────────────────────┤
│  Phase 5  部署 Agent                              │
│  ───────────────────────                         │
│  输入：通过测试的代码                               │
│  输出：生产环境运行（域名 + SSL + DB + CDN）         │
│  工具：Cloud Runtime nodes + Docker + DNS API      │
│  产出：live URL + health check + 监控 dashboard     │
├──────────────────────────────────────────────────┤
│  Phase 6  市场运营 Agent                          │
│  ───────────────────────                         │
│  输入：产品 + BP                                  │
│  输出：Landing Page + SEO + 社交媒体 + 广告        │
│  工具：域名/CMS API + 定时发布 + Analytics          │
│  产出：landing page + 推文/帖子 + 流量报告          │
├──────────────────────────────────────────────────┤
│  Phase 7  客户成交 Agent                          │
│  ───────────────────────                         │
│  输入：流量 → 注册 → 试用 → 付费                    │
│  输出：Stripe 订阅激活 + 用户 onboarding           │
│  工具：Stripe webhook + 邮件 automation            │
│  产出：订单记录 + MRR dashboard                    │
├──────────────────────────────────────────────────┤
│  Phase 8  财税 Agent                              │
│  ───────────────────────                         │
│  输入：Stripe 收入 + 支出记录                       │
│  输出：月报/季报/年报 + 税务计算 + 发票              │
│  工具：Stripe API + 会计 skill + 定时 cron          │
│  产出：P&L + balance sheet + 税务申报 draft         │
└──────────────────────────────────────────────────┘
```

---

## 二、已有 1Person 能力可直接复用

| Phase | 需要的能力 | 1Person 现有 | 状态 |
|-------|----------|-------------|------|
| 1 | 创建 issue 存想法 | `POST /api/issues` | ✓ |
| 1 | Agent 执行 BP 分析 | Agent + Skill 系统 | ✓ 框架有 |
| 2 | 设计稿 → issue 拆分 | issue create + metadata | ✓ |
| 3 | Agent 调用 CLI | Daemon worker | ✓ |
| 3 | 代码提交 | Webhook trigger | ✓ |
| 4 | 测试结果 → issue | Webhook + autopilot | ✓ |
| 5 | 健康检查 | `/health` + dashboard | ✓ |
| 6 | 定时发布 | Cron trigger | ✓ |
| 7 | Stripe 事件 → issue | Webhook trigger | ✓ |
| 8 | 定时报表生成 | Cron trigger + Agent | ✓ |

---

## 三、需要新增的组件

### Phase 1 — 商业计划 Agent

| 组件 | 说明 | 估时 |
|------|------|------|
| `superpowers:brainstorming` skill | 已有 → 输入想法 → 深度追问 → 收敛为 BP 初稿 | 0（复用） |
| Market Research skill | Web Search + 竞品分析 + 定价模型 | 3d |
| BP template | 标准化 BP 模板（Markdown），agent 填充 | 1d |

### Phase 2 — 产品设计 Agent

| 组件 | 说明 | 估时 |
|------|------|------|
| Design Consultation skill | 已有 `gstack-design-consultation` | 0（复用） |
| Design HTML skill | 已有 `gstack-design-html` | 0（复用） |
| Design Review skill | 已有 `gstack-design-review` | 0（复用） |
| PRD Generator | 设计稿 → PRD 文档 → issue 拆分 | 2d |

### Phase 3 — 代码开发 Agent

| 组件 | 说明 | 估时 |
|------|------|------|
| Codex CLI skill | 已有 `gstack-codex` | 0（复用） |
| zserver e2e 生成器 | 已有 12 模块 e2e 模板 | 0（已有） |
| 全栈脚手架生成 | 根据技术栈选择一键生成 zserver + Next.js | 3d |
| Git workflow Agent | 自动 branch → commit → PR → test → merge | 2d |

### Phase 4 — 测试 Agent

| 组件 | 说明 | 估时 |
|------|------|------|
| QA skill | 已有 `gstack-qa` + `gstack-qa-only` | 0（复用） |
| Design Review (视觉) | 已有 `gstack-design-review` + `gstack-ios-design-review` | 0（复用） |
| Benchmark skill | 已有 `gstack-benchmark` | 0（复用） |
| 全流程 Test Runner | 一键跑 unit + e2e + visual + perf → issue 归档 | 2d |

### Phase 5 — 部署 Agent

| 组件 | 说明 | 估时 |
|------|------|------|
| Land and Deploy skill | 已有 `gstack-land-and-deploy` | 0（复用） |
| Canary monitor | 已有 `gstack-canary` | 0（复用） |
| Cloud Runtime 节点 | zserver cloud_runtime 模块已有 | 0（已有） |
| DNS + SSL automation | 域名注册/SSL 证书 API 集成 | 2d |

### Phase 6 — 市场运营 Agent

| 组件 | 说明 | 估时 |
|------|------|------|
| Landing page generator | Design HTML → publish | 2d |
| SEO 分析 + 优化 | Web Search → keyword → meta | 2d |
| Social media 定时发布 | Cron trigger + 平台 API | 2d |
| Analytics dashboard | 已有 dashboard 模块 | 1d |

### Phase 7 — 客户成交 Agent

| 组件 | 说明 | 估时 |
|------|------|------|
| Stripe webhook handler | 已有 webhook 模块 | 1d |
| 订阅管理 | Stripe API → 用户状态 | 2d |
| Onboarding email | Cron + email API | 1d |

### Phase 8 — 财税 Agent

| 组件 | 说明 | 估时 |
|------|------|------|
| 记账 ledger | 已有（需新增业务模块） | 3d |
| 发票生成 | HTML → PDF skill | 1d |
| 税务计算 | 按地区/税率规则 | 2d |

---

## 四、Pipeline 编排引擎

核心：一个 `Pipeline Agent` 作为流水线调度器。

```
POST /api/ideas
  body: { "idea": "做一个 AI 菜谱推荐 App", "tech_stack": ["zserver","next.js"], "budget": 500 }

→ Pipeline Agent 创建 Master Issue
→ Phase 1 Agent claim → execute → 产出 BP → close sub-issue
→ Phase 2 Agent claim → execute → 产出设计稿 → close sub-issue
→ ... Phase 8 close
→ Master Issue close → 通知用户: 产品已上线，MRR=$X
```

**编排配置**（`pipeline.yaml`）:

```yaml
pipelines:
  saas_product:
    phases:
      - id: business_plan
        agent: bp-agent
        timeout: 2h
        artifact: docs/bp.md
      - id: product_design
        agent: design-agent
        depends_on: [business_plan]
        artifact: docs/prd.md, designs/
      - id: code_dev
        agent: dev-agent
        depends_on: [product_design]
        artifact: git repo
      - id: testing
        agent: qa-agent
        depends_on: [code_dev]
        approval_gate: true  # 需要人类确认测试通过
      - id: deploy
        agent: deploy-agent
        depends_on: [testing]
      - id: marketing
        agent: marketing-agent
        depends_on: [deploy]
      - id: sales_finance
        agent: finance-agent
        depends_on: [deploy]
```

---

## 五、实施路径

| 阶段 | 内容 | 估时 | 关键产出 |
|------|------|------|---------|
| **P0** | Pipeline 编排引擎 + Phase 1-2 Agent | 1 周 | 想法 → BP → 设计稿 自动生成 |
| **P1** | Phase 3-5 Agent (开发+测试+部署) | 2 周 | 设计稿 → 上线产品 |
| **P2** | Phase 6-8 Agent (运营+成交+财税) | 2 周 | 上线 → 首单付费 |
| **P3** | 一人公司 black-launch | 1 周 | 输入想法 → 一周后产品上线 + 开始赚钱 |
| **总计** | | **6 周** | |

---

## 六、zserver 侧改动预估

| 改动 | 说明 |
|------|------|
| **Pipeline Agent**（新增） | 编排各 phase agent，跟踪依赖和状态 |
| **Pipeline Config**（新增） | `pipeline.yaml` 加载 + 校验 |
| **Idea API**（新增） | `POST /api/ideas` + 查询 |
| **Artifact Store**（新增） | 各 phase 产出的文件/链接管理系统 |
| **Approval Gate**（扩展） | 关键 phase 暂停等人工确认（不改动数据层） |
| 其余各 phase Agent | 基于已有 skill 封装为 Agent，无新 API |

---

## 七、风险与收束

| 风险 | 缓解 |
|------|------|
| Agent 生成代码质量差 | Phase 4 测试不通过 → 打回 Phase 3 重做，最多 3 轮 |
| 全自动花钱（广告/云） | 预算帽 + Approval Gate + 每日 Supervisory Agent 审查 |
| 法律合规 | Phase 1 BP 阶段自动搜索目标市场法规 → 合规清单 |
| 无限循环 | Pipeline 超时机制 + 每 phase 最大重试次数 |
| 竞品抄袭 | 这是工具，使用者负责。系统不判断创意合法性 |

---

## 八、与"黑灯工厂"的关系

```
黑灯工厂方案（docs/one-person-factory.md）
  └── 解决：已有业务如何自动化运营

创意变现方案（本方案）
  └── 解决：从零到一自动创建新业务

两者互补：
  黑灯工厂 = 稳态（运营现有产品）
  创意变现 = 从 0 到 1（创建新产品）
  合体 = 完整的自动赚钱机器
```

---

## 九、结论

**可以。且大部分基础设施已就绪。**

1Person 的 Agent/Autopilot/Daemon/Skill/Cron/Webhook 六件套 + zserver 轻量引擎 + 已有的 50+ gstack skill（design/qa/benchmark/deploy/canary/codex），天然是"创意变现流水线"的最佳宿主。

核心增量只有两块：
1. **Pipeline 编排引擎**（Phase 间依赖 + 状态流）— ~3 天
2. **各 Phase 的 Agent 封装**（把已有 skill 包装为 Phase Agent）— ~2 周

其余全部复用现有能力。6 周可从零到上线赚钱。
