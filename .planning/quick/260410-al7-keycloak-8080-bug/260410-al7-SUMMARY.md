# Quick Task 260410-al7: Summary

## 问题

Keycloak Google OAuth 登录跳转到 `https://auth.noda.co.nz:8080/...`（端口 8080），而非正确的 `https://auth.noda.co.nz/...`（端口 443）。

## 根因

`KC_HOSTNAME_STRICT: "false"` 允许 Keycloak 从请求中派生端口。Cloudflare Tunnel 转发请求到 `http://keycloak:8080`，Keycloak 从请求中获取端口 8080 并覆盖了配置的 `KC_HOSTNAME_PORT: "443"`。

## 修复

1. **docker-compose.yml**: `KC_HOSTNAME_STRICT: "false"` → `"true"`
2. **docker-compose.prod.yml**: `KC_HOSTNAME_STRICT: "false"` → `"true"`
3. **deploy-infrastructure-prod.sh**: 添加 `-f docker/docker-compose.prod.yml` 到所有 docker compose 命令

## 修改文件

- `docker/docker-compose.yml` (line 143)
- `docker/docker-compose.prod.yml` (line 66)
- `scripts/deploy/deploy-infrastructure-prod.sh` (lines 79, 91)

## 部署后验证

重新部署 Keycloak 后，访问 `https://auth.noda.co.nz/realms/noda/.well-known/openid-configuration` 确认所有 URL 不包含 `:8080`。
