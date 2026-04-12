# Phase 16: Keycloak 端口收敛 - Context

**Gathered:** 2026-04-12
**Status:** Ready for planning
**Source:** Auto mode (--auto)

<domain>
## Phase Boundary

将 auth.noda.co.nz 流量从 Cloudflare Tunnel 直连 Keycloak 改为经过 nginx 反向代理，移除 Docker Compose 中 Keycloak 8080/9000 端口到宿主机的暴露，确保 dev 环境可通过线上 Keycloak 完成认证。

</domain>

<decisions>
## Implementation Decisions

### Cloudflare Tunnel 路由
- **D-01:** 将 Cloudflare Tunnel 配置中 `auth.noda.co.nz` 的目标从 `http://keycloak:8080` 改为 `http://noda-nginx:80`（nginx 已有完整的 auth.noda.co.nz server block 和 proxy 配置）
- **D-02:** Nginx 已配置 upstream `keycloak_backend` 指向 `keycloak:8080`，包含 WebSocket 支持和安全头 — 无需修改 nginx 配置

### Keycloak 端口移除
- **D-03:** 从 docker-compose.yml 的 keycloak 服务中移除所有 `ports` 暴露（包括 `127.0.0.1:8080:8080` 和 `9000:9000`）
- **D-04:** Keycloak 保持 Docker 内部网络通信（noda-network），nginx 通过容器名 `keycloak:8080` 访问
- **D-05:** KC_PROXY 保持 `edge` 配置（nginx 层终止 TLS/代理，Cloudflare 已处理 HTTPS）

### Dev 环境认证（KC-03）
- **D-06:** dev 应用（findclass-ssr dev）使用 auth.noda.co.nz 进行认证，复用线上 Keycloak 实例
- **D-07:** 在 Keycloak 的 noda-frontend client 中添加 localhost redirect URI（如 `http://localhost:3001/auth/callback`）
- **D-08:** docker-compose.dev.yml 中 findclass-ssr 的 KEYCLOAK_URL 保持 `https://auth.noda.co.nz`（通过 Cloudflare 访问线上 Keycloak）

### Keycloak 健康检查
- **D-09:** 使用 Docker healthcheck 通过容器内部 localhost 连接检查 Keycloak 状态（`curl -f http://localhost:8080/health/ready`），不暴露端口到宿主机
- **D-10:** 如果 docker-compose.prod.yml 中有 9000 端口的健康检查配置，改为内部 8080 端口检查

### Claude's Discretion
- nginx proxy 配置细节调整（如需要增加 buffer size、timeout 等参数）
- Keycloak healthcheck 具体的 curl 命令和间隔参数
- 是否需要调整 findclass-ssr 的 KEYCLOAK_INTERNAL_URL

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docker Compose 配置
- `docker/docker-compose.yml` — 基础 compose 配置（Keycloak ports 暴露在此移除）
- `docker/docker-compose.prod.yml` — 生产环境覆盖（Keycloak 健康检查可能需修改）
- `docker/docker-compose.dev.yml` — 开发环境覆盖（dev Keycloak 独立实例配置）

### Nginx 配置
- `config/nginx/conf.d/default.conf` — 已有 auth.noda.co.nz server block（行 22-50）

### Cloudflare Tunnel 配置
- `config/cloudflare/config.yml` — Tunnel 路由配置（auth.noda.co.nz 目标需修改）

### Keycloak 相关
- `CLAUDE.md` — 项目指南，包含 Google 登录 8080 端口问题修复记录

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Nginx auth.noda.co.nz server block: 已完整配置（upstream keycloak_backend、proxy_pass、WebSocket 支持、安全头）
- Cloudflare Tunnel: 已配置为两个路由（auth.noda.co.nz → keycloak:8080, class.noda.co.nz → noda-nginx:80）

### Established Patterns
- noda-ops 服务已使用 nginx 反向代理模式（Cloudflare → nginx → noda-ops）
- Keycloak 使用 KC_PROXY=edge 模式（信任上游代理的 X-Forwarded 头）

### Integration Points
- Cloudflare Tunnel config.yml — auth.noda.co.nz 路由目标变更
- docker-compose.yml keycloak service — ports 移除
- docker-compose.prod.yml — Keycloak 健康检查端点可能从 9000 改为 8080
- docker-compose.dev.yml — dev Keycloak 独立实例的端口配置保持不变

</code_context>

<specifics>
## Specific Ideas

- 当前 nginx 配置已有 `proxy_pass http://keycloak_backend;`，upstream 定义为 `keycloak:8080`，改动最小
- Cloudflare Tunnel 改为 `noda-nginx:80` 后，class.noda.co.nz 和 auth.noda.co.nz 都走同一 nginx 入口
- Keycloak 9000 端口是管理端口（admin console），移除后无法从宿主机直接访问 admin console，需通过 nginx 代理或 docker exec 访问

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 16-keycloak*
*Context gathered: 2026-04-12 via auto mode*
