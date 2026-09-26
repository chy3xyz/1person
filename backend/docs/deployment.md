# 1person 部署指南


> **Path note (2026-08):** repo layout is `frontend/{apps,packages}` and `backend/zserver`. Older `apps/` / `packages/` / `zserver/` mentions in this file mean those new locations.
## 一、部署模式

### 模式 A：单机 No-DB（开发/小规模）

```
zserver (单进程，内存存储)
  ├── 前端静态文件 (Next.js export)
  └── 0 外部依赖
```

**适用**：1 人使用、开发测试、快速原型。

### 模式 B：单机 + PostgreSQL（生产/中等规模）

```
zserver + PostgreSQL 17
  ├── 前端静态文件
  └── Redis (可选，WS 多实例需要)
```

**适用**：持久化数据、数据备份、中等并发。

### 模式 C：多实例 + Redis（大规模）

```
                   ┌─ Nginx / Caddy ─┐
                   │   (反向代理)      │
                   └──┬───────────┬──┘
                      ▼           ▼
              zserver-1     zserver-2
              (port 8090)   (port 8091)
                  │           │
                  └─────┬─────┘
                        ▼
                   PostgreSQL 17
                        │
                   Redis (WS pub/sub)
```

**适用**：高可用、水平扩展、多用户。

---

## 二、zserver 部署

### 构建

```bash
cd zserver
zig build -Doptimize=ReleaseSafe
# 二进制: zserver/zig-out/bin/zserver
```

### 环境变量

| 变量 | 必须 | 默认 | 说明 |
|------|------|------|------|
| `PORT` | 否 | 8090 | HTTP 端口 |
| `JWT_SECRET` | **是** | — | JWT 签名密钥 (≥32 字符) |
| `DATABASE_URL` | 否 | — | PG 连接串。不设则使用内存存储 |
| `REDIS_URL` | 否 | — | Redis 连接串。用于 WS 多实例同步 |
| `ONEPERSON_DEV_VERIFICATION_CODE` | 否 | — | 开发模式验证码 (不设则必须用真实邮件) |
| `CORS_ORIGIN` | 否 | `*` | 允许的跨域来源 |

### systemd 服务

```ini
# /etc/systemd/system/1person.service
[Unit]
Description=1person zserver
After=network.target postgresql.service

[Service]
Type=simple
User=1person
WorkingDirectory=/opt/1person
EnvironmentFile=/opt/1person/.env
ExecStart=/opt/1person/zserver server --port 8090
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

```bash
# .env
JWT_SECRET=your-random-secret-at-least-32-chars
DATABASE_URL=postgres://1person:pass@localhost:5432/1person?sslmode=disable
REDIS_URL=redis://localhost:6379
CORS_ORIGIN=https://your-domain.com
```

```bash
sudo systemctl enable 1person
sudo systemctl start 1person
```

### Docker

```dockerfile
# Dockerfile
FROM alpine:3.21
RUN apk add --no-cache libpq ca-certificates
COPY zig-out/bin/zserver /usr/local/bin/zserver
COPY scripts/ /opt/1person/scripts/
EXPOSE 8090
CMD ["zserver", "server", "--port", "8090"]
```

```bash
docker build -t 1person .
docker run -d \
  -p 8090:8090 \
  -e JWT_SECRET=xxx \
  -e DATABASE_URL=postgres://user:pass@host:5432/1person \
  --name 1person \
  1person
```

---

## 三、PostgreSQL 部署

### 数据库初始化

```bash
# 创建数据库
createdb 1person

# 运行 Go migration (从 server/migrations/)
cd server/migrations
for f in *.up.sql; do psql -d 1person -f "$f"; done
```

### 连接池配置

通过 `DATABASE_URL` query string 控制：

```
postgres://user:pass@host:5432/1person?sslmode=disable&max_connections=20
```

| 参数 | 默认 | 说明 |
|------|------|------|
| `max_connections` | 10 | zserver 连接池大小 |
| `sslmode` | disable | `disable` / `require` |
| `connect_timeout` | 5 | 连接超时（秒） |

### 备份

```bash
# 每日备份
pg_dump -d 1person | gzip > backup-$(date +%Y%m%d).sql.gz

# crontab
0 3 * * * pg_dump -d 1person | gzip > /backup/1person-$(date +\%Y\%m\%d).sql.gz
```

---

## 四、Redis 部署（可选）

### 安装

```bash
# macOS
brew install redis && brew services start redis

# Ubuntu
apt install redis-server
systemctl enable redis-server
```

### 配置

zserver 仅在 `REDIS_URL` 设置时连接 Redis。未设置时 WS 仅在同进程内广播。

```
REDIS_URL=redis://localhost:6379
```

---

## 五、前端部署

### 构建

```bash
cd apps/web
pnpm build
# 产出: apps/web/.next/
```

### 搭配 zserver（推荐）

zserver 已内建静态文件服务。将 Next.js 构建产物放在 `zserver/static/` 下：

```bash
# 1. 构建前端
cd apps/web && pnpm build

# 2. 导出静态文件 (如果使用 next export)
# 或使用 Next.js standalone 模式

# 3. zserver 自动从 static/ 目录提供静态文件
cp -r apps/web/out/ zserver/static/
```

### 独立部署（Vercel/Netlify）

前端可独立部署到 Vercel。设置 `REMOTE_API_URL` 指向 zserver：

```bash
REMOTE_API_URL=https://api.your-domain.com
```

---

## 六、反向代理（Nginx）

```nginx
server {
    listen 443 ssl http2;
    server_name your-domain.com;

    ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

    # API → zserver
    location /api/ {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # WebSocket → zserver
    location /ws {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
    }

    # 健康检查
    location /health {
        proxy_pass http://127.0.0.1:8090;
    }

    # 静态文件（如果 zserver 不提供）
    location / {
        proxy_pass http://127.0.0.1:3000;  # Next.js standalone
    }
}
```

---

## 七、安全检查清单

| 检查项 | 说明 |
|--------|------|
| ☐ `JWT_SECRET` 已设置 | ≥ 32 字符随机字符串 |
| ☐ `CORS_ORIGIN` 限制为具体域名 | 不要用 `*` 在生产环境 |
| ☐ PostgreSQL 不暴露公网 | 仅 listen 127.0.0.1 |
| ☐ Redis 设置密码 | `requirepass` 配置项 |
| ☐ HTTPS | 强制 TLS，禁止 HTTP |
| ☐ 限流 | zserver 已内置 Redis 限流中间件 |
| ☐ 日志轮转 | systemd journald 或 logrotate |
| ☐ 备份 | PG 每日备份 + 异地存储 |
| ☐ 监控 | `/health` 端点 + systemd watchdog |
| ☐ 文件上传大小限制 | Nginx `client_max_body_size 50m` |

---

## 八、监控

### 健康检查

```bash
# zserver 健康端点
curl http://127.0.0.1:8090/health         # → {"status":"ok"}
curl http://127.0.0.1:8090/readyz         # → {"status":"ready"} (DB + Redis 都可用)
curl http://127.0.0.1:8090/health/realtime # → WS 连接可用性
```

### systemd watchdog

```ini
[Service]
WatchdogSec=30
```

### Prometheus（可选）

zserver 目前只能通过日志分析监控。可扩展 `/metrics` 端点。

---

## 九、常见问题

### Q: No-DB 模式数据丢失？

A: 是的。重启即清空。仅用于开发/演示。生产必须用 PostgreSQL。

### Q: zserver 占用多少内存？

A: 基础 ~20MB。每 1000 个 issue 增加约 5MB。每 100 个 WS 连接增加约 10MB。

### Q: 如何升级？

```bash
cd zserver
git pull
zig build -Doptimize=ReleaseSafe
sudo systemctl restart 1person
```

### Q: 前端和 zserver 分离部署怎么做？

A: 前端部署到 Vercel，zserver 部署到自己的服务器。前端 `next.config.ts` 中设置 `REMOTE_API_URL` 指向 zserver。

### Q: 多实例时 WS 消息能同步吗？

A: 设置 `REDIS_URL` 后自动启用 Redis pub/sub bridge。publish 侧已就绪，subscribe 侧待 zfinal 补充 `readMessage` 后激活。

---

## 十、推荐部署配置

### 开发机（macOS）

```bash
# 终端 1: zserver
cd zserver && zig build && JWT_SECRET=dev-secret-dev-secret-dev-secret- ONEPERSON_DEV_VERIFICATION_CODE=000000 ./zig-out/bin/zserver server

# 终端 2: 前端
cd apps/web && pnpm dev

# 访问 http://localhost:3000 → 前端通过 REMOTE_API_URL 代理到 zserver
```

### 小型 VPS（2C4G）

```
zserver (no-DB) + Nginx + Let's Encrypt
≈ 30MB RAM
支持 100 并发用户
```

### 中型 VPS（4C8G）

```
zserver + PostgreSQL 17 + Nginx + Let's Encrypt
≈ 200MB RAM
支持 1000 并发用户
```
