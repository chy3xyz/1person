# 1person 快速开始

## 10 分钟从零到第一个 Pipeline

### 1. 启动 zserver

```bash
cd zserver
zig build
JWT_SECRET=my-secret MULTICA_DEV_VERIFICATION_CODE=000000 \
  ./zig-out/bin/zserver server --port 8090
```

### 2. 创建 Workspace + 获取 Token

```bash
# 发送验证码
curl -X POST -H "Content-Type: application/json" \
  -d '{"email":"me@example.com"}' \
  http://127.0.0.1:8090/auth/send-code

# 验证 (dev 模式 code 固定为 000000)
TOKEN=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"email":"me@example.com","code":"000000"}' \
  http://127.0.0.1:8090/auth/verify-code | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")

# 创建 workspace
WS=$(curl -s -X POST -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"name":"My Startup","slug":"my-startup"}' \
  http://127.0.0.1:8090/api/workspaces)

WS_ID=$(echo "$WS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
AUTH="Authorization: Bearer $TOKEN"
HWS="X-Workspace-Id: $WS_ID"
```

### 3. 创建 Pipeline

```bash
# 定义一个 3 阶段 Pipeline
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{
    "name": "SaaS Launch",
    "description": "从 0 到 1 启动一个 SaaS 产品",
    "phases": [
      {"id":"p1","name":"市场调研","agent":"research-agent","depends_on":[],"timeout_seconds":3600,"max_retries":2,"approval_gate":false},
      {"id":"p2","name":"产品设计","agent":"design-agent","depends_on":["p1"],"timeout_seconds":7200,"max_retries":2,"approval_gate":true},
      {"id":"p3","name":"代码开发","agent":"dev-agent","depends_on":["p2"],"timeout_seconds":14400,"max_retries":3,"approval_gate":false}
    ]
  }' \
  http://127.0.0.1:8090/api/pipelines
```

### 4. 启动 Pipeline 执行

```bash
# 启动执行 (返回 run_id)
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{}' \
  http://127.0.0.1:8090/api/pipelines/{pipeline_id}/start

# 查看执行状态
curl -H "$AUTH" -H "$HWS" \
  http://127.0.0.1:8090/api/pipelines/{pipeline_id}/runs/{run_id}

# 完成一个 Phase (Agent 执行完毕后调用)
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{}' \
  http://127.0.0.1:8090/api/pipelines/{pipeline_id}/runs/{run_id}/phases/p1/complete
```

### 5. 设置角色层级 (用于分润)

```bash
# 创建角色定义
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{"name":"community_leader","permissions":["manage_team","view_downline"],"level":1}' \
  http://127.0.0.1:8090/api/roles/defs

# 绑定上下级关系 (A 是 B 的上级)
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{"user_id":"user-b","role":"ambassador","parent_id":"user-a","level":2}' \
  http://127.0.0.1:8090/api/roles/members

# 查看 A 的下级树
curl -H "$AUTH" -H "$HWS" \
  http://127.0.0.1:8090/api/roles/members/user-a/downline
```

### 6. 配置分润规则

```bash
# 创建 3 级分润规则
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{"name":"3-Level Split","levels":[{"depth":1,"rate":0.1},{"depth":2,"rate":0.05},{"depth":3,"rate":0.02}]}' \
  http://127.0.0.1:8090/api/commissions/rules

# 计算一笔交易的分润
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{"rule_id":"{rule_id}","transaction_id":"tx-001","amount":1000,"from_user_id":"user-c","upline_chain":["user-b","user-a"]}' \
  http://127.0.0.1:8090/api/commissions/calculate
```

### 7. 创建裂变追踪

```bash
# 为用户 A 创建邀请码
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{"user_id":"user-a"}' \
  http://127.0.0.1:8090/api/referrals/codes

# 用户 B 通过邀请码注册
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{"code":"{code}","referee_user_id":"user-b"}' \
  http://127.0.0.1:8090/api/referrals/track

# B 付费后激活
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{"record_id":"{record_id}"}' \
  http://127.0.0.1:8090/api/referrals/activate
```

### 8. 代币激励

```bash
# 用户 A 获得 100 代币
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{"user_id":"user-a","amount":100,"reason":"完成 Pipeline Phase 1"}' \
  http://127.0.0.1:8090/api/token-economy/earn

# 查询余额
curl -H "$AUTH" -H "$HWS" \
  'http://127.0.0.1:8090/api/token-economy/balance?user_id=user-a'
```

### 9. 内容矩阵分发

```bash
# 创建分发平台
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{"name":"Blog","adapter_type":"markdown"}' \
  http://127.0.0.1:8090/api/content-matrix/platforms

# 分发内容到多个平台
curl -X POST -H "Content-Type: application/json" -H "$AUTH" -H "$HWS" \
  -d '{"original_content":"# Hello World\n\nThis is a test.","platforms":["blog","twitter"]}' \
  http://127.0.0.1:8090/api/content-matrix/distribute
```

### 10. 运行全部 e2e 验证

```bash
cd zserver
make ci
# 输出: 24 套 e2e + 30 前端集成检查, 全部 PASS
```

---

## 下一步

- 阅读 `docs/common-infrastructure.md` 了解各模块的实现细节
- 阅读 `docs/` 下的方案文档选择你的业务方向
- 写 Pipeline YAML + Agent Skill → 1 天内从零到上线
