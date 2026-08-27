# Zig CLI / Daemon — 立项方案


> **Path note (2026-08):** repo layout is `frontend/{apps,packages}` and `backend/zserver`. Older `apps/` / `packages/` / `zserver/` mentions in this file mean those new locations.
Status: **M1-M4 + M5（自更新/桌面捆绑/安装器）+ 阶段 2/3 完成**

## M1 落地记录

- 新二进制 `1p`（zserver/build.zig 第二个 artifact，zig-out/bin/1p）。
- 命令（扁平化）：`config` / `login` / `pair` / `version`。
- `1p login --server_url ... --email ... --code ... [--path ...]`：send-code +
  verify-code → JWT 存 `~/.config/1person/config.json`（0600）。
- `1p pair --workspace_id <uuid> [--path ...]`：POST /api/daemon/tokens 铸造
  mdt_ 并存 config。
- 验证：`scripts/cli_m1_e2e.sh`（login → 建工作区 → pair → 用铸造令牌注册
  daemon → 权限 600），对真实 zserver DB 模式全部通过。
- 与方案的两处偏差：
  1. `daemon pair` 展平为 `pair` —— zcli 的嵌套子命令解析在本 zig-dev 版本
     有类型缺陷（父字段需要 Result 类型但 meta() 拒绝）。
  2. 命令树 ≥4 个子命令触发 std.simd.iota 的 comptime 1000 分支上限，在
     main() 用 `@setEvalBranchQuota(20000)` 解决。
- 踩坑记录：Zig 0.17 的 Io/JSON API 与旧版本差异大（无 std.posix.write、
  无 std.json.stringify、ObjectMap 是 unmanaged、ArrayList 无 .init、
  File.Writer 缓冲不落盘等），均已适配。

## 1. 目标

用 Zig 重写本地 CLI + agent daemon（当前为 Go 的 multica），使桌面端本地
运行时完全脱离 Go，与 zserver 形成同一生态。CLI 面向用户（登录、配置、
工作区/工单/技能操作），daemon 面向执行（注册、心跳、认领任务、在本机
执行 agent 任务并回报）。

## 2. 命令面（对齐 Go CLI，按优先级）

| 命令 | 说明 | 阶段 |
|------|------|------|
| `1p config` | 读写 ~/.config/1person/config.json（server URL、token） | M1 |
| `1p login` | 浏览器/验证码登录 → 存 JWT | M1 |
| `1p daemon pair` | 调 POST /api/daemon/tokens 铸造 mdt_（workspace 绑定） | M1 |
| `1p daemon start/stop/status` | 启动/停止/查询本地 daemon 进程 | M2 |
| `1p version` / `1p update` | 版本与自更新 | M5 |
| `1p issue/workspace/agent/skill ...` | 只读/管理命令（复用 zserver API） | M4 |

## 3. 认证与令牌

- 登录：POST /auth/send-code → /auth/verify-code（dev code 或邮件码）→ JWT（Bearer）。
- Daemon 令牌：POST /api/daemon/tokens（JWT + workspace 成员）→ `mdt_<40hex>`，
  服务端存 SHA-256。客户端只存明文令牌。
- 本地存储：~/.config/1person/config.json，权限 0600；JWT 与 mdt_ 均存于此。

## 4. Daemon 协议（对齐 Go daemonws + /api/daemon）

1. register：POST /api/daemon/register {runtime_id, name}（Bearer mdt_）→ daemon_id。
2. heartbeat：POST /api/daemon/heartbeat（周期 30s；失败重连退避）。
3. WS：GET /api/daemon/ws?runtime_ids=...（Bearer mdt_）→ 服务端推送
   `daemon:task_available`。
4. 任务认领：GET /api/daemon/runtimes/{rid}/tasks/pending + POST .../tasks/claim。
5. 执行：POST /api/daemon/tasks/{id}/start → 本地执行 → 周期
   POST .../tasks/{id}/progress → 完成 POST .../tasks/{id}/complete；
   失败 POST .../tasks/{id}/fail。
6. 副作用回报：usage / messages（对齐现有端点）。

## 5. 任务执行模型

- 认领的任务带 `work_dir`（或 waiting-local-directory 等待用户目录）。
- 执行器：spawn 子进程（std.process.Child），流式输出 → progress/messages。
- 技能：M4 接入 SKILL.md 驱动的本地技能目录（zserver skill 模块契约）。
- 安全：任务命令白名单/沙箱选项（与 Go daemon 当前行为对齐），M3 默认只执行
  `echo` 类示例任务，M4 放开。

## 6. 分阶段路线

| 里程碑 | 内容 | 验收 |
|--------|------|------|
| M1 | config + login + pair（本机可用） | 对真实 zserver：登录拿 JWT、铸造 mdt_ |
| M2 | daemon 主循环：register/heartbeat/WS/认领 | 对真实 zserver DB 模式：注册→心跳→WS 连接 |
| M3 | 任务执行垂直切片：认领→执行 echo→progress→complete | e2e：任务状态流转正确 |
| M4 | 技能与只读命令面 | skill e2e + issue 查询 |
| M5 | update/打包（desktop bundle 替换 Go CLI） | desktop 安装产物不再含 Go |

## 7. 验证策略

- 每个里程碑都有 shell e2e（复用 zserver/scripts 模式），对真实 zserver
  （DB 模式）断言。
- 服务端依赖已就绪：`POST /api/daemon/tokens`（scripts/daemon_db_e2e.sh
  全绿）、DB 模式 mdt_ 认证（伪造令牌 401）。
- 构建复用 zserver 的 build.zig.zon 依赖（zfinal/zcli，Zig git 包依赖）。

## 8. 边界与已知约束

- Redis WS 扇出尚未实现（zserver 侧）→ daemon 的 task_available 推送当前
  仅单实例生效；认领/轮询路径不受影响。
- 与 Go CLI 并存期：桌面端 bundle 暂缓（立项决策），M5 前不替换。

## M2 落地记录

- `1p daemon --runtime_id <id> [--token | --workspace_id] [--heartbeat_ms] [--claim_ms]`：
  register → WS 连接（自实现 RFC 6455 客户端）→ 心跳（HTTP + WS 帧）→ 认领轮询 →
  断线退避重连 → SIGINT/SIGTERM 优雅注销。
- WS 客户端 `src/cli/ws.zig`：握手（Sec-WebSocket-Accept 校验）+ 掩码帧收发 +
  ping/pong + 带超时的轮询读取（`operateTimeout`）。
- 验证：`scripts/cli_m2_e2e.sh`（no-DB，合成 mdt_）——register/WS/心跳/认领/优雅停止
  全部通过；服务器日志确认 `GET /api/daemon/ws` 连接保持 + `deregister 204`。
- 关键坑：服务器 greeting 帧与 101 响应头粘在同一 TCP 段，读响应头时被丢弃 → 增加
  pending buffer 消费残余字节后 WS 帧正常。
- 任务入队无公开端点（runtime 需先注册），认领空队列；带任务的认领→执行在 M3
  （需要 agent/runtime 创建流程）。
## M3 落地记录

- `1p daemon` 认领后执行任务：start → progress(25/80) → messages → complete/fail。
- 服务端配套：daemon register/deregister 同步 `agent_runtime.status` online/offline
  （Go 契约；否则 runtime 离线时 initiate 被拒）。
- 验证 `scripts/cli_m3_e2e.sh`（DB 模式）：login → 建工作区+agent(自定义 runtime_id)
  → pair → daemon → initiate models 入队 → 认领 → 执行 → complete → messages 落库。
- 说明：任务生命周期（start/progress/complete/messages）走内存 task_queue；
  `GET /tasks/{id}/status` 在 DB 模式查 agent_task_queue 表（另一任务模型），
  e2e 用 messages 端点验证记录。
- 遗留（M4）：按 task_type 的真实执行（models 列表、skills 运行、update 应用）+
  模块结果回报（/runtimes/{rid}/models/{requestId}/result 等）。
## 阶段 2 落地记录（根 CI/Docker/release 切 zserver）

- **Dockerfile**：重写为 zserver 镜像（builder: alpine + install-zig.sh + provision zig deps +
  zig build ReleaseSafe；runtime: alpine + libpq/sqlite-libs + migrations + entrypoint）。
  实测：构建成功，容器内 migrate 152 幂等、/health、/readyz（动态版本 119）。
- **docker/entrypoint.sh**：`./zserver migrate && exec ./zserver server`。
- **ci.yml**：移除失效的 Go backend job（源码 gitignored，全新 checkout 必挂），
  后端覆盖由 zserver-ci.yml 承担；修复 @multica → @1person 过滤器。
- **release.yml**：verify 改为 zserver 构建+单测；goreleaser（Go CLI）job 置 `if: false`
  并注释（等 Zig CLI M5 重接）。
- **install-zig.sh**：从官方 ziglang.org 下载固定版本（zigup 上游迁移/install.sh 404，
  旧 CI 步骤全部失效）；Dockerfile + zserver-ci.yml + migrate.yml 统一使用。
- **bundle-cli.mjs**：Go 源码不存在时优雅跳过（不再因 gitignored 源码使桌面构建失败）。
- **关键 bug（容器验证抓到）**：migrate.zig 的 `openDir` 未传 `.iterate = true`，
  macOS 容忍、musl 严格拒绝 → 容器内迁移文件扫描为 0，migrations 永远无法应用。
  修复后容器内 152 迁移正常。
## M4 落地记录

- **任务结果回报契约修复**（zserver）：initiateUpdate/ListModels/ListLocalSkills/Import 的
  enqueue payload 由 target_version/空串/skill_key 改为 **request/update id**，
  daemon 据此回报结果（此前无关联字段，结果无法回报）。
- **daemon 按类型真实执行**（`src/cli/daemon.zig`）：
  - update：本地 1p 版本 vs target 对比 → `/runtimes/{rid}/update/{update_id}/result`
  - models：探测本地模型运行时（M4 如实报告 supported=false/空列表）→ `.../models/{request_id}/result`
  - local_skills：扫描 `~/.config/1person/skills` 的 SKILL.md → `.../local-skills/{request_id}/result`
  - local_skill_import：确认（真实拉取在 M5）→ `.../local-skills/import/{request_id}/result`
  - 完成后 POST /tasks/{id}/complete。
- **只读命令面**（`src/cli/query.zig` + api.getJson）：`1p workspaces` / `1p agents --workspace_id` /
  `1p issues --workspace_id`。
- 验证 `scripts/cli_m4_e2e.sh`（DB 模式）：models/update 任务从入队→认领→执行→回报→
  服务端 request 状态 completed 全链路；三个只读命令输出正确。
- 遗留（M5）：真实 update 应用（下载+替换二进制）、skill 真实拉取、goreleaser 重接。
## 阶段 3 落地记录（品牌/身份统一 → 1person）

已统一（无歧义 + 按仓库既定身份 1person-ai/1person）：
- **桌面身份分裂修复**（真 bug）：运行时注册 `1person://` + `ai.1person.desktop`，但
  electron-builder.yml 打包的是 multica scheme/appId/产物名/publish 仓库 →
  全部统一为 1person（appId ai.1person.desktop、productName 1Person、schemes [1person]、
  产物 1person-desktop-*、publish 1person-ai/1person）。打包产物现在能接收自己的深链。
- **CI 过滤器**：mobile-verify.yml `@multica/mobile` → `@1person/mobile`（此前选中空集）。
- **镜像/部署面**：release.yml + compose + helm chart + .env.example 的镜像名 →
  `ghcr.io/1person-ai/1person-backend|web`；compose 项目名/helm 图表 → 1person；
  RESEND_FROM_EMAIL → noreply@1person.app；goreleaser brew tap → 1person-ai。
- **helm chart**：deploy/helm/multica → deploy/helm/1person（chart 名、镜像、secret、域名）。
- **zserver**：isOfficialCloud 同时识别 multica.ai 与 1person.app（自托管判定兼容两代域名）。
- 镜像按最终代码重建验证（1person-backend:latest）。

保留并记录（需你定夺/属契约）：
- `MULTICA_*` 环境变量名前缀（真实 env 契约，重命名破坏兼容）。
- `POSTGRES_DB/USER=multica`（内部 DB 名，改则破坏本地/CI）。
- `apps/mobile/.env.production` 指向 multica.ai（真实生产后端 URL，待后端真正迁移域名）。
- `scripts/install.sh` 的 multica 引用（Go CLI 安装器，随 M5 Zig CLI 重写）。
- 镜像发布依赖 `1person-ai` org 真实存在。
## M5 落地记录

- **`1p update` 自更新**（`src/cli/update.zig` + api.getRaw）：version.txt 对比 → 下载
  `1person-{arch}-{os}` → 可执行魔数校验 + 可选 .sha256 校验 → 替换自身（target.new +
  rename）。实测：升级/已最新/坏二进制拒绝三分支全过（本地 HTTP release 服务器）。
- **桌面捆绑 Zig CLI**（`bundle-cli.mjs` 重写）：zig build 1p → 复制为
  resources/bin/1person（桌面运行时查找名）。实测：捆绑产物可运行（`1person version`）。
- **install.sh 重写为 1p**：version.txt 契约 + 直下二进制 + sha256 校验；品牌统一
  （1person-ai/1person、~/.1person）；安装后校验 `1person version`。install.test.sh
  测试桩同步更新，全部通过。
- **遗留（需真实发布仓库/服务端契约）**：
  - local_skill_import 真实拉取（需服务端 skill 导出端点或 URL 契约）。
  - goreleaser 重接为 Zig 1p 发布（release.yml 的 release job 已 `if: false`，待
    1person-ai org 存在 + M5 CLI 形态稳定后重写配置并启用）。