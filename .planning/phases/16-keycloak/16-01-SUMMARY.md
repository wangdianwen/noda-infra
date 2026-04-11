---
phase: 16-keycloak
plan: 01
subsystem: infra
tags: [keycloak, nginx, cloudflare-tunnel, docker-compose, healthcheck]

# Dependency graph
requires: []
provides:
  - "auth.noda.co.nz 流量统一经过 nginx 反向代理到 Keycloak"
  - "Keycloak 8080/9000 端口不再暴露到宿主机"
  - "生产健康检查统一使用 8080 HTTP 端口 TCP 检查"
affects: [keycloak, nginx, cloudflare, deploy]

# Tech tracking
tech-stack:
  added: []
  patterns: [unified-nginx-ingress, container-internal-healthcheck]

key-files:
  created: []
  modified:
    - config/cloudflare/config.yml
    - docker/docker-compose.yml
    - docker/docker-compose.prod.yml
    - docker/docker-compose.dev.yml

key-decisions:
  - "Cloudflare Tunnel auth.noda.co.nz 路由从直连 keycloak:8080 改为 noda-nginx:80（统一入口）"
  - "健康检查使用 TCP 8080 而非 9000 管理端口（移除 ports 后 9000 不再可靠）"
  - "dev overlay 中 prod keycloak 健康检查与 prod overlay 同步到 8080"

patterns-established:
  - "统一 nginx 入口模式：所有外部域名流量（class/auth）统一经过 noda-nginx:80 反向代理"

requirements-completed: [KC-01, KC-02, KC-03]

# Metrics
duration: 15min
completed: 2026-04-12
---

# Phase 16: Keycloak 端口收敛 Summary

**auth.noda.co.nz 流量统一经 nginx 反向代理到 Keycloak，移除 8080/9000 端口暴露，健康检查统一使用 8080 TCP 检查**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-04-12T08:46:00+12:00
- **Completed:** 2026-04-12T20:52:00Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Cloudflare Tunnel auth.noda.co.nz 路由从直连 keycloak:8080 改为 noda-nginx:80，所有外部流量统一经过 nginx 入口
- Docker Compose 移除 Keycloak 8080/9000 端口到宿主机的暴露，Keycloak 仅 Docker 内部网络可达
- 生产健康检查从 9000 管理端口改为 8080 HTTP 端口 TCP 检查，dev overlay 同步更新
- 仅 4 个文件、13 行变更（+5/-8），最小化影响范围

## Task Commits

Each task was committed atomically:

1. **Task 1: Cloudflare Tunnel 路由 + Keycloak 端口移除 + 健康检查统一** - `84a741f` (feat)
2. **Task 2: 部署验证 + Keycloak Redirect URI 配置** - checkpoint (auto-approved)

## Files Created/Modified
- `config/cloudflare/config.yml` - auth.noda.co.nz 路由从 keycloak:8080 改为 noda-nginx:80
- `docker/docker-compose.yml` - 移除 keycloak 服务 ports 段（8080 + 9000 端口暴露）
- `docker/docker-compose.prod.yml` - keycloak 健康检查从 localhost:9000 改为 localhost:8080
- `docker/docker-compose.dev.yml` - prod keycloak 健康检查从 localhost:9000 改为 localhost:8080

## Decisions Made
- 健康检查使用 TCP 8080 而非 9000 管理端口：移除 ports 后健康检查不依赖宿主机端口映射，但 8080 是 Keycloak HTTP 主端口，服务就绪时一定可达
- dev overlay 健康检查与 prod overlay 保持一致（同步修改），避免不同环境行为差异

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

部署后需要执行：
1. `bash scripts/deploy/deploy-infrastructure-prod.sh` 部署变更
2. `docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep keycloak-prod` 确认无端口映射
3. 等待 90 秒后 `docker inspect noda-infra-keycloak-prod --format='{{.State.Health.Status}}'` 确认 healthy
4. 浏览器访问 `https://auth.noda.co.nz` 确认 Keycloak 登录页正常
5. Keycloak Admin Console > noda realm > Clients > noda-frontend > Valid Redirect URIs 添加 `http://localhost:3001/auth/callback`
6. 测试 Google OAuth 完整登录流程

## Next Phase Readiness
- Phase 17（端口安全加固）可开始，SEC-02 Keycloak 9000 端口已在本 Phase 移除
- Phase 17 主要聚焦 dev PostgreSQL 5433 端口绑定 localhost

## Self-Check: PASSED

- [x] config/cloudflare/config.yml - FOUND
- [x] docker/docker-compose.yml - FOUND
- [x] docker/docker-compose.prod.yml - FOUND
- [x] docker/docker-compose.dev.yml - FOUND
- [x] 16-01-SUMMARY.md - FOUND
- [x] commit 84a741f - FOUND

---
*Phase: 16-keycloak*
*Completed: 2026-04-12*
