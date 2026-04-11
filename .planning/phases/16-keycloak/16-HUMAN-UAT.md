---
status: partial
phase: 16-keycloak
source: 16-VERIFICATION.md
started: 2026-04-12
updated: 2026-04-12
---

## Current Test

[awaiting human testing]

## Tests

### 1. Cloudflare Dashboard 路由更新（阻塞项）
expected: 在 Cloudflare Zero Trust Dashboard 中，将 auth.noda.co.nz 的 tunnel public hostname 的 service 从 `http://keycloak:8080` 改为 `http://noda-nginx:80`。**必须先于部署操作完成。**
result: [pending]

### 2. 部署验证 — 端口不暴露
expected: `docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep keycloak-prod` 无端口映射输出
result: [pending]

### 3. 部署验证 — 健康检查
expected: 等待 90 秒后 `docker inspect noda-infra-keycloak-prod --format='{{.State.Health.Status}}'` 输出 `healthy`
result: [pending]

### 4. 浏览器验证 — Keycloak 登录页
expected: 访问 `https://auth.noda.co.nz` 正常显示 Keycloak 登录页
result: [pending]

### 5. Google OAuth 登录流程
expected: `https://class.noda.co.nz` -> 登录 -> Google 认证 -> 成功返回首页
result: [pending]

### 6. localhost Redirect URI 配置（KC-03）
expected: Keycloak Admin Console > noda realm > Clients > noda-frontend > Valid Redirect URIs 包含 `http://localhost:3001/auth/callback`
result: [pending]

## Summary

total: 6
passed: 0
issues: 0
pending: 6
skipped: 0
blocked: 0

## Gaps
