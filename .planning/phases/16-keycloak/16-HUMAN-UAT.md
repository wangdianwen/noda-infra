---
status: pass
phase: 16-keycloak
source: 16-VERIFICATION.md
started: 2026-04-12
updated: 2026-04-12
---

## Tests

### 1. Cloudflare Dashboard 路由更新（阻塞项）
expected: 在 Cloudflare Zero Trust Dashboard 中，将 auth.noda.co.nz 的 tunnel public hostname 的 service 从 `http://keycloak:8080` 改为 `http://noda-nginx:80`（注：实际 Docker 服务名是 `nginx`，Dashboard 中应为 `http://nginx:80`）
result: PASS — 用户已手动更新

### 2. 部署验证 — 端口不暴露
expected: `docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep keycloak-prod` 无端口映射输出
result: PASS — keycloak 服务无 ports 段

### 3. 部署验证 — 健康检查
expected: 等待 90 秒后 `docker inspect noda-infra-keycloak-prod --format='{{.State.Health.Status}}'` 输出 `healthy`
result: PASS — 容器健康

### 4. 浏览器验证 — Keycloak 登录页
expected: 访问 `https://auth.noda.co.nz` 正常显示 Keycloak 登录页
result: PASS — 页面正常显示

### 5. Google OAuth 登录流程
expected: `https://class.noda.co.nz` -> 登录 -> Google 认证 -> 成功返回首页
result: PASS — Google OAuth 完整流程成功
note: 需要额外修复 3 个问题才通过（见下方）

### 6. localhost Redirect URI 配置（KC-03）
expected: Keycloak Admin Console > noda realm > Clients > noda-frontend > Valid Redirect URIs 包含 `http://localhost:3001/auth/callback`
result: pending — 非阻塞项，开发环境配置

## Additional Fixes Required for Test 5

Google OAuth 登录通过前发现并修复了 3 个额外问题：

| # | 问题 | 修复 |
|---|------|------|
| 1 | `keycloak-js` 默认 `responseMode='fragment'`，PKCE 无法处理 hash 中的 code | 在 `initKeycloak()` 中添加 `responseMode: 'query'` |
| 2 | Keycloak 容器 `KC_PROXY=none`（旧配置未重建），导致 cookie 不安全 | `docker compose up --force-recreate keycloak` 使 `KC_PROXY=edge` 生效 |
| 3 | nginx `X-Frame-Options: SAMEORIGIN` 阻止 SSO iframe 跨域嵌入 | 改为 `ALLOW-FROM` + `CSP frame-ancestors` |

此外还修复了 findclass-ssr 镜像的 shared 包 ESM 兼容问题（Dockerfile 中添加 tsc 编译 + import 扩展名修复）。

## Summary

total: 6
passed: 5
issues: 0
pending: 1 (KC-03 localhost redirect URI，非阻塞)
skipped: 0
blocked: 0
