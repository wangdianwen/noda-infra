# Noda Infrastructure - Claude 项目指南

## 项目概述

Noda 基础设施仓库，管理 Docker Compose 部署配置。包含 PostgreSQL、Keycloak、Nginx、Cloudflare Tunnel、findclass-ssr 等服务。

## 架构

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops 容器) → nginx → Docker 内部服务
  class.noda.co.nz → nginx → findclass-ssr (SSR + API + 静态文件)
  auth.noda.co.nz  → nginx → keycloak:8080 (容器内部)
```

| 服务 | 端口 | 备注 |
|------|------|------|
| PostgreSQL | 5432 | 数据持久化在 `noda-infra_postgres_data` 卷 |
| Keycloak | 8080 (内部) | 不暴露外部端口，通过 nginx 反向代理访问 |
| findclass-ssr | 3001 | SSR + 静态文件，通过 nginx 代理 |
| noda-ops | - | 备份 + Cloudflare Tunnel |
| Nginx | 80 | 反向代理（所有外部流量统一入口） |

## 部署规则

### 禁止直接使用 Docker Compose 命令

**严禁 LLM 直接运行 `docker compose up/down/restart/start/stop` 等命令来上线/下线服务。**

所有服务部署、重启、下线操作必须通过项目脚本执行：

| 操作 | 脚本 |
|------|------|
| 全量部署（基础设施+应用） | `bash scripts/deploy/deploy-infrastructure-prod.sh` |
| 部署应用（findclass-ssr） | `bash scripts/deploy/deploy-apps-prod.sh` |

允许的 docker compose 命令仅限只读操作：`ps`、`logs`、`config`、`images`。

### 项目名一致性
- `docker-compose.yml` 和 `docker-compose.prod.yml` 项目名必须一致（当前为 `noda-infra`）
- 不一致会创建重复容器和空数据卷

### 构建时 vs 运行时环境变量
Vite 的 `VITE_*` 变量在 `docker build` 时写入 JS 文件，运行时环境变量只影响 SSR 服务端。
**修改前端配置必须重新构建镜像，不能只改运行时环境变量。**

### Cloudflare 缓存
静态资源更新后需要清除 CDN 缓存。静态资源 URL 包含 hash，但 index.html 会被缓存。

## Google 登录 8080 端口问题修复记录（2026-04-10）

### 发现的 5 层问题

| # | 层 | 问题 | 修复文件 |
|---|---|------|----------|
| 1 | 前端构建 | JS 中 Keycloak URL 硬编码为 `localhost:8080`（构建时未传 `VITE_KEYCLOAK_URL`） | `deploy/Dockerfile.findclass-ssr` 添加 ARG |
| 2 | Nginx 路由 | `/auth/` 被代理到 Keycloak，覆盖了应用 `/auth/callback` | `config/nginx/conf.d/default.conf` 移除 `/auth/` 代理 |
| 3 | SSR 中间件 | `url.startsWith('/auth')` 跳过了 `/auth/callback`，不渲染 SPA | `noda-apps/.../ssr-middleware.ts` 移除跳过条件 |
| 4 | Keycloak 配置 | v1 hostname 选项废弃，`KC_HOSTNAME_PORT` 不生效 | `docker-compose.yml` 改为 `KC_HOSTNAME: "https://auth.noda.co.nz"` |
| 5 | 项目名冲突 | `docker-compose.prod.yml` 项目名 `noda-prod` 与 `noda-infra` 冲突 | 统一为 `noda-infra` |

### 根因链路

```
浏览器加载 JS → Keycloak URL = localhost:8080（构建时硬编码）
  → 登录请求发到 localhost（cookie 设在 localhost 域）
  → Keycloak 重定向到 auth.noda.co.nz
  → cookie 不跨域 → cookie_not_found 错误
```

### 修复要点

**Dockerfile（永久修复）：**
```dockerfile
ARG VITE_KEYCLOAK_URL=https://auth.noda.co.nz
ARG VITE_KEYCLOAK_REALM=noda
ARG VITE_KEYCLOAK_CLIENT_ID=noda-frontend
```

**Keycloak v2 Hostname SPI：**
- `KC_HOSTNAME: "https://auth.noda.co.nz"` — 完整 URL，端口从 scheme 推导
- `KC_PROXY: "edge"` — 必须保留，否则 cookie 缺少 Secure 标记
- `KC_PROXY_HEADERS: "xforwarded"` — 读取 Cloudflare X-Forwarded 头
- 不要使用 `KC_HOSTNAME_PORT`、`KC_HOSTNAME_STRICT_HTTPS`（v1 废弃选项）

**部署脚本：**
- `deploy-infrastructure-prod.sh` 需使用 `-f base -f prod` 双文件
- 需清理旧项目名容器避免端口冲突

### 调试方法论

1. **用 Chrome DevTools MCP 跟踪网络请求**，检查 redirect chain 和 cookie domain
2. 不要只验证 Keycloak OIDC 端点，要跟踪完整登录链路
3. 问题表象（Keycloak :8080）不一定等于根因（前端 localhost:8080）
4. 构建产物中的硬编码值无法通过运行时环境变量覆盖

### 附加修复

- `lru-cache` ESM 兼容问题：Dockerfile 中 sed 修复 named export
- API 入口文件路径修正：`dist/api/src/api.js` → `dist/api.js`

## 部署命令

```bash
# 全量部署（基础设施 + 应用）
bash scripts/deploy/deploy-infrastructure-prod.sh

# 仅部署应用（findclass-ssr）
bash scripts/deploy/deploy-apps-prod.sh

# 查看状态（只读，允许直接使用）
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml ps
```
