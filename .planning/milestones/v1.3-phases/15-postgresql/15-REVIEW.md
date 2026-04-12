---
phase: 15-postgresql
reviewed: 2026-04-12T12:00:00Z
depth: standard
files_reviewed: 2
files_reviewed_list:
  - deploy/Dockerfile.noda-ops
  - docker/docker-compose.yml
findings:
  critical: 1
  warning: 1
  info: 1
  total: 3
status: issues_found
---

# Phase 15: Code Review Report

**Reviewed:** 2026-04-12T12:00:00Z
**Depth:** standard
**Files Reviewed:** 2
**Status:** issues_found

## Summary

审查了 Phase 15 的两处变更：Dockerfile.noda-ops 升级 Alpine 3.21 + postgresql17-client，以及 docker-compose.yml 新增 PGSSLMODE=disable 环境变量。变更逻辑清晰、范围最小化，符合预期。

发现 1 个 Critical 问题（Keycloak 管理端口 9000 对外暴露）、1 个 Warning（nginx 和 noda-ops 未使用 healthcheck condition 依赖 postgres）、1 个 Info（noda-ops 健康检查间隔 1h 偏长）。

## Critical Issues

### CR-01: Keycloak 管理端口 9000 未绑定 127.0.0.1

**File:** `docker/docker-compose.yml:147`
**Issue:** Keycloak 的管理端口 9000 直接暴露为 `"9000:9000"`，未限制绑定地址。而同一服务块的 HTTP 端口 8080 已正确限制为 `"127.0.0.1:8080:8080"`。端口 9000 是 Keycloak 的管理控制台（Admin REST API），暴露到所有网络接口意味着同网段的任何主机都可以访问管理 API，构成未授权访问风险。
**Fix:**
```yaml
# 修改前
- "9000:9000"  # 管理端口（健康检查）

# 修改后
- "127.0.0.1:9000:9000"  # 管理端口（仅本机）
```

注意：如果管理端口用于外部健康检查（如负载均衡器），需要确认检查来源。但从架构看，健康检查应通过 Cloudflare Tunnel 或 docker 内部网络完成，不需要外部暴露。

## Warnings

### WR-01: nginx 和 noda-ops 对 postgres 的依赖未使用 healthcheck condition

**File:** `docker/docker-compose.yml:52-53, 92-93`
**Issue:** nginx 和 noda-ops 的 `depends_on` 仅列出了 `- postgres`（不带 condition），而 findclass-ssr 和 keycloak 正确使用了 `condition: service_healthy`。不带 condition 的 depends_on 只保证容器启动顺序，不保证 postgres 已通过 healthcheck 就绪。noda-ops 在启动后执行健康检查（`pg_isready`）可以部分缓解，但 nginx 依赖 postgres 启动后再启动并不保证 postgres 已接受连接。
**Fix:**
```yaml
# nginx 服务
depends_on:
  postgres:
    condition: service_healthy

# noda-ops 服务
depends_on:
  postgres:
    condition: service_healthy
```

## Info

### IN-01: noda-ops Dockerfile 健康检查间隔 1h 偏长

**File:** `deploy/Dockerfile.noda-ops:66`
**Issue:** HEALTHCHECK 的 interval 设置为 `1h`（1 小时），而 docker-compose.yml 中 noda-ops 服务的 healthcheck interval 为 `30s`。docker-compose.yml 中的 healthcheck 定义会覆盖 Dockerfile 中的 HEALTHCHECK 指令，因此 Dockerfile 中的 1h 间隔实际上不会生效。但两处定义不一致可能导致维护混淆。
**Fix:** 考虑从 Dockerfile 中移除 HEALTHCHECK 指令，统一在 docker-compose.yml 中管理，或者在两处使用一致的间隔值。

---

_Reviewed: 2026-04-12T12:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
