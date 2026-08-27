# 共性体系完善清单

> 13 份方案的需求缺口分析。当前已完成 12 个共性模块，需要补 8 个通用能力方可支撑全部方案。

---

## 一、需求矩阵（方案 × 共通能力）

| 能力 | 黑灯 | 创意 | GEO | 知识IP | 万社 | life++ | 保险 | 绿色 | 跨境 | 培训 | 疗愈 | Meme | 缺口 |
|------|:--:|:--:|:--:|:-----:|:--:|:-----:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Pipeline | ✓ | ✓ | | | | | ✓ | | | | ✓ | | 0 |
| Role | ✓ | | | | ✓ | | | ✓ | | | ✓ | | 0 |
| Commission | ✓ | | | | ✓ | | | ✓ | | | | | 0 |
| Content Matrix | | ✓ | ✓ | ✓ | | | ✓ | | ✓ | ✓ | ✓ | ✓ | 0 |
| Referral | | | | | ✓ | | | ✓ | | ✓ | | ✓ | 0 |
| Dashboard V2 | ✓ | ✓ | ✓ | | ✓ | | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | 0 |
| Token Economy | | | | | | ✓ | | ✓ | | | | | 0 |
| Training | | | | ✓ | | ✓ | ✓ | | | ✓ | ✓ | | 0 |
| Wallet | | | | | ✓ | ✓ | | ✓ | ✓ | | ✓ | | 0 |
| i18n | | | | | | | ✓ | | ✓ | ✓ | | | 0 |
| Compliance | | ✓ | | | | ✓ | ✓ | | ✓ | | | | 0 |
| Community Ops | | | | ✓ | ✓ | ✓ | | | | ✓ | ✓ | ✓ | 0 |
| **Blockchain** | | | | | | ✗ | | ✗ | | | | ✗ | **3** |
| **External API** | | ✓ | ✓ | | | | ✓ | | ✗ | | ✓ | ✗ | **5** |
| **File/Media** | | ✓ | ✓ | ✓ | | | | | ✓ | ✓ | ✓ | ✓ | **7** |
| **Notification** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **13** |
| **Scheduler V2** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **13** |
| **Multi-tenancy** | | | | | ✗ | | | ✗ | ✗ | | | | **3** |
| **Analytics/BI** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **13** |
| **Task Queue** | | | | | | | | | | | | | 0 |

---

## 二、P0 — 必须补齐（所有方案都需要的通用能力）

### 1. 通知引擎 (Notification Engine)

**缺口**: 13/13 方案都需要，当前为 0。

```
渠道:
  · 邮件 (SMTP / SendGrid)
  · 短信 (阿里云 / Twilio)
  · 微信 (公众号模板消息 / 小程序订阅消息)
  · Telegram Bot
  · Discord Webhook
  · App Push (iOS/Android)
  · 站内信

Agent 工作流:
  触发条件 → 模板匹配 → 渠道路由 → 发送 → 追踪(送达/打开/点击)
```

#### zserver 侧

```
modules/notification/
├── model.zig    NotificationTemplate, NotificationLog
├── service.zig  send(channel, template, data) + multi-channel router
├── handler.zig  CRUD 模板 + 发送记录查询
├── routes.zig   /api/notifications (RequireWorkspaceMember)
```

#### 估时: 3 天

---

### 2. 定时调度 V2 (Scheduler V2)

**缺口**: 当前 Cron trigger 只能定时触发，不支持：延迟任务、重试、依赖、优先级。

```
新增能力:
  · 延迟任务: "3 天后发送续费提醒" → schedule_at(ts)
  · 重试: 失败自动重试 3 次, 间隔递增
  · 依赖: Task B 依赖 Task A 完成
  · 优先级: 高优任务跳过队列
  · 去重: 同类型任务不重复创建
```

#### zserver 侧

```
modules/scheduler/
├── model.zig    ScheduledTask, TaskDependency
├── service.zig  schedule / cancel / retry / listByStatus
├── handler.zig
├── routes.zig   /api/scheduler
```

#### 估时: 2 天

---

### 3. 数据分析引擎 V2 (Analytics/BI)

**缺口**: 当前 dashboard 只有基础统计，不支持：自定义指标、同比环比、预测、导出。

```
新增能力:
  · 自定义指标: 用户级 / 项目级 / 全局级
  · 时间对比: 同比 / 环比 / 7 日趋势
  · 预测: 基于历史数据预测未来 30 天
  · 导出: CSV / PDF / 图片
  · 定时报表: 每周一自动生成上周报表
```

#### zserver 侧

```
modules/analytics/
├── model.zig    Metric, Report, ExportJob
├── service.zig  track(name, value, tags) + query(metric, range) + generate_report
├── handler.zig  metric CRUD + report CRUD
├── routes.zig   /api/analytics (RequireWorkspaceMember)
```

#### 估时: 3 天

---

## 三、P1 — 重要补齐（3+ 方案需要）

### 4. 文件/媒体管理 (File/Media Management)

**缺口**: 7/13 方案需要，当前仅支持基础 JSON body。

```
新增能力:
  · 文件上传: 图片 / 视频 / PDF / 音频
  · CDN 分发: 自动生成缩略图 / 压缩 / CDN URL
  · 存储: 本地 / S3 / Cloudflare R2 / IPFS
  · 处理: 图片裁剪 / 视频转码 / 文档预览
```

#### zserver 侧

```
modules/media/
├── model.zig    MediaAsset (id, url, type, size, metadata)
├── service.zig  upload / list / delete / transform
├── handler.zig  multipart upload handler
├── routes.zig   /api/media (RequireWorkspaceMember)
```

#### 估时: 3 天

---

### 5. 外部 API 集成框架 (External API Framework)

**缺口**: 5/13 方案需要调用第三方 API。

```
新增能力:
  · 统一 HTTP Client（GET/POST/PUT/DELETE + header + auth）
  · API 配置（URL / 密钥 / 超时 / 重试）
  · 请求日志（成功/失败/耗时/响应）
  · 限流（每个 API 独立频率限制）
  · 转换器（外部响应 → 内部统一格式）
```

#### zserver 侧

```
modules/connector/
├── model.zig    ApiConfig, ApiRequestLog
├── service.zig  call(api_name, method, path, body) + listConfigs
├── handler.zig
├── routes.zig   /api/connectors
```

#### 估时: 3 天

---

### 6. 区块链集成 (Blockchain Integration)

**缺口**: 3/13 方案需要，life++ / 绿色积分 / Meme 币。

```
新增能力:
  · EVM 兼容链交互（ETH/BSC/Polygon/Arbitrum）
  · 合约部署（ERC-20 / ERC-721 / 工厂合约）
  · 交易发送 + 等待确认 + 查询 receipt
  · 事件监听（Transfer / Mint / Burn）
  · 地址监控（余额 / 交易 / 授权）
```

#### zserver 侧

```
modules/blockchain/
├── model.zig    ChainConfig, Contract, Transaction, Event
├── service.zig  deploy / sendTx / getBalance / listenEvents
├── handler.zig
├── routes.zig   /api/blockchain
```

#### 估时: 5 天

---

## 四、P2 — 按需补齐（1-2 方案需要）

### 7. 多租户增强 (Multi-tenancy V2)

**缺口**: 万社互联（多层级社区）、绿色积分（多层级代理）、跨境电商（多店铺）。

```
新增能力:
  · Workspace 树形层级（Parent/Child）
  · 跨 Workspace 数据查询（上级看下级汇总）
  · 资源限额（每级 Workspace 的用户数/存储/API 配额）
  · 跨租户操作（上级替下级创建/管理）
```

#### zserver 侧: 扩展 workspace 模块

#### 估时: 3 天

---

### 8. 任务队列 (Task Queue)

**缺口**: 已有 agent task queue，需增强。

```
新增能力:
  · 优先级队列（高/中/低）
  · 延迟执行（schedule at timestamp）
  · 批量任务（1 个 pipeline → N 个并行 task）
  · 超时自动失败 + 重试
  · 队列监控（积压/吞吐/延迟）
```

#### zserver 侧: 扩展 task_queue 模块

#### 估时: 2 天

---

## 五、建设路线图

```
Week 1: P0 (必须)
  Day 1-3:  通知引擎 (Notification)
  Day 4-5:  定时调度 V2 (Scheduler V2)

Week 2: P0 + P1
  Day 6-8:  数据分析 V2 (Analytics/BI)
  Day 9-11: 文件/媒体管理 (File/Media)

Week 3: P1 (重要)
  Day 12-14: 外部 API 集成 (Connector)
  Day 15-16: 多租户增强 (Multi-tenancy V2)

Week 4: P1 + P2
  Day 17-21: 区块链集成 (Blockchain)
  Day 22-23: 任务队列 (Task Queue)

总计: 4 周补齐全部 8 个能力
```

---

## 六、补齐后的能力矩阵

```
P0 (已建):  Pipeline + Role + Commission
P1 (已建):  Content + Referral + Dashboard V2
P2 (已建):  Token + Training + Wallet
P3 (已建):  i18n + Compliance + Community Ops

新增 P4:    Notification + Scheduler V2 + Analytics V2   ← 3 模块
新增 P5:    File/Media + Connector + Multi-tenancy V2    ← 3 模块
新增 P6:    Blockchain + Task Queue                      ← 2 模块

总计: 12 已建 + 8 新增 = 20 共性模块
```

### 补齐后每方案的新增工作量

| 方案 | 当前需新建 | 补齐后需新建 | 节省 |
|------|:------:|:------:|:----:|
| 黑灯工厂 | 1 | 0 | 100% |
| 创意变现 | 3 | 1 | 67% |
| GEO | 3 | 1 | 67% |
| 知识 IP | 3 | 0 | 100% |
| 万社互联 | 3 | 1 | 67% |
| life++ | 6 | 2 (合约) | 67% |
| 保险 AI | 5 | 1 (业务逻辑) | 80% |
| 绿色积分 | 5 | 1 (合约) | 80% |
| 跨境电商 | 8 | 3 (选品/物流/客服) | 63% |
| OPC 培训 | 7 | 2 (测评/匹配) | 71% |
| 疗愈经济 | 6 | 2 (测评/匹配) | 67% |
| Meme 币 | 6 | 1 (合约) | 83% |

**平均节省 75% 的开发量。每方案从"几周"降至"几天"。**
