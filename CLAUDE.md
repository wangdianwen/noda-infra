# Noda Infrastructure - Claude 项目指南

## 项目概述

Noda 基础设施仓库，管理 Docker Compose 部署配置。包含 PostgreSQL、Keycloak、Nginx、Cloudflare Tunnel、findclass-ssr 等服务。

## 架构要点

### 网络拓扑
```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops 容器) → Docker 内部服务
  class.noda.co.nz → nginx → findclass-ssr
  auth.noda.co.nz → keycloak:8080
```

### 项目名一致性
- `docker-compose.yml` 和 `docker-compose.prod.yml` 项目名必须一致（当前为 `noda-infra`）
- 不一致会导致创建重复容器和空数据卷

## 关键经验教训

### 构建时 vs 运行时环境变量（重要！）

Vite 的 `VITE_*` 变量在 `docker build` 时写入 JS 文件，运行时环境变量只影响 SSR 服务端。
**修改前端配置必须重新构建镜像，不能只改运行时环境变量。**

### Google 登录 8080 端口问题（2026-04-10）

**根因：** findclass-ssr 镜像构建时未传入 `VITE_KEYCLOAK_URL`，前端 JS 硬编码为 `http://localhost:8080`。

**完整链路：**
1. 浏览器加载 `index-DFMfROkI.js`，其中 Keycloak URL = `http://localhost:8080`
2. 登录时浏览器请求 `http://localhost:8080`（cookie 设在 localhost 域）
3. Keycloak 303 重定向到 `https://auth.noda.co.nz/broker/google/login`
4. cookie 不跨域（localhost → auth.noda.co.nz）→ `cookie_not_found`

**修复：** 重新构建 findclass-ssr 镜像，传入构建参数：
```yaml
build:
  args:
    VITE_KEYCLOAK_URL: https://auth.noda.co.nz
    VITE_KEYCLOAK_REALM: noda
    VITE_KEYCLOAK_CLIENT_ID: noda-frontend
```

**调试方法：** 用 Chrome DevTools MCP 跟踪网络请求链，检查实际的 redirect chain 和 cookie domain。

### Keycloak v2 Hostname SPI（26.2.3）

Keycloak 26 使用 v2 Hostname SPI：
- `KC_HOSTNAME` 接受完整 URL：`https://auth.noda.co.nz`（包含 scheme，端口自动推导）
- `KC_HOSTNAME_PORT`、`KC_PROXY` 是 v1 废弃选项（会触发 WARNING 但仍可用）
- `KC_PROXY: "edge"` 必须保留，否则 cookie 缺少 Secure 标记
- `KC_PROXY_HEADERS: "xforwarded"` 读取 Cloudflare Tunnel 的 X-Forwarded 头

### 部署注意事项

1. **不要只重启 Keycloak** — 问题可能在前端构建产物
2. **Cloudflare CDN 缓存** — 静态资源更新后需要清除 CDN 缓存
3. **容器内热修补不持久** — `sed` 替换仅在容器生命周期内有效，重建容器会丢失
4. **部署脚本** `deploy-infrastructure-prod.sh` 需要同时清理旧项目名（`noda-infra`）的容器

## 服务配置

| 服务 | 端口 | 备注 |
|------|------|------|
| PostgreSQL | 5432 | 数据持久化在 `noda-infra_postgres_data` 卷 |
| Keycloak | 8080/9000 | HTTP + 管理端口，通过 Cloudflare Tunnel 暴露 |
| findclass-ssr | 3001 | SSR + 静态文件，通过 nginx 代理 |
| noda-ops | - | 备份 + Cloudflare Tunnel |
| Nginx | 80 | 反向代理 |
