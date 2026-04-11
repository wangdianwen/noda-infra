# Phase 16: Keycloak 端口收敛 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-12
**Phase:** 16-keycloak
**Areas discussed:** Cloudflare Tunnel 路由, Keycloak 端口移除, Dev 认证, 健康检查
**Mode:** --auto

---

## Cloudflare Tunnel 路由

| Option | Description | Selected |
|--------|-------------|----------|
| 改为 nginx | Tunnel 目标从 keycloak:8080 改为 noda-nginx:80（nginx 已有完整配置） | ✓ |
| 保持直连 | 保持 Cloudflare Tunnel 直连 Keycloak（当前状态） | |

**Auto-selected:** 改为 nginx（推荐 — nginx 已有完整 auth.noda.co.nz 配置，包括 WebSocket 和安全头）
**Notes:** 无需修改 nginx 配置，仅修改 Cloudflare Tunnel config.yml

---

## Keycloak 端口移除

| Option | Description | Selected |
|--------|-------------|----------|
| 完全移除 | 移除所有 ports（8080 和 9000），Keycloak 仅通过 Docker 内部网络通信 | ✓ |
| 保留 9000 | 仅移除 8080，保留 9000 管理端口用于健康检查 | |
| 保留两者 | 保留 127.0.0.1 绑定，仅对外收敛 | |

**Auto-selected:** 完全移除（推荐 — 彻底消除端口暴露，Phase 17 SEC-02 也要求收敛 9000 端口）
**Notes:** 健康检查改为容器内部 localhost 连接

---

## Dev 环境认证

| Option | Description | Selected |
|--------|-------------|----------|
| 复用线上 Keycloak | dev 应用通过 auth.noda.co.nz 认证，添加 localhost redirect URI | ✓ |
| 独立 dev Keycloak | dev 环境使用独立 Keycloak 实例 | |

**Auto-selected:** 复用线上 Keycloak（推荐 — REQUIREMENTS.md KC-03 明确要求复用）
**Notes:** 需在 Keycloak noda-frontend client 添加 localhost redirect URI

---

## Keycloak 健康检查

| Option | Description | Selected |
|--------|-------------|----------|
| 容器内部 healthcheck | Docker healthcheck 通过 localhost:8080 检查，不暴露端口 | ✓ |
| nginx 代理 health | 通过 nginx 添加 /health 路由代理到 Keycloak | |

**Auto-selected:** 容器内部 healthcheck（推荐 — 简单直接，无需额外 nginx 配置）
**Notes:** Keycloak 有 /health/ready 端点可用于健康检查

---

## Claude's Discretion

- nginx proxy 配置细节调整
- Keycloak healthcheck 具体参数
- KEYCLOAK_INTERNAL_URL 是否需要调整

## Deferred Ideas

None
