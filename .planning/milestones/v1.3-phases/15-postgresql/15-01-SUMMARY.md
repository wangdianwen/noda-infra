---
phase: 15-postgresql
plan: 01
subsystem: infra
tags: [postgres, alpine, docker, backup, sslmode]

# Dependency graph
requires: []
provides:
  - "noda-ops 容器 pg_dump 17.x 客户端（匹配服务端 17.9）"
  - "PGSSLMODE=disable 环境变量（Docker 内部网络 SSL 禁用）"
affects: [backup, deploy]

# Tech tracking
tech-stack:
  added: [postgresql17-client]
  patterns: [PGSSLMODE-env-var]

key-files:
  created: []
  modified:
    - deploy/Dockerfile.noda-ops
    - docker/docker-compose.yml

key-decisions:
  - "使用 PGSSLMODE 环境变量而非逐行修改脚本（覆盖所有 20+ 个 PG 客户端调用点）"
  - "Alpine 3.21 而非 edge（稳定版，提供 postgresql17-client 17.9-r0）"

patterns-established:
  - "PGSSLMODE 环境变量模式：通过 docker-compose.yml 环境变量全局控制 PG 客户端 SSL 行为"

requirements-completed: [PG-01, PG-02]

# Metrics
duration: 2min
completed: 2026-04-12
---

# Phase 15: PostgreSQL 客户端升级 Summary

**升级 noda-ops 容器 Alpine 3.21 + postgresql17-client，通过 PGSSLMODE=disable 环境变量全局禁用 Docker 内部 SSL 协商**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-12
- **Completed:** 2026-04-12
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Dockerfile 从 Alpine 3.19 升级到 3.21，pg_dump 版本从 16.11 升级到 17.x（匹配服务端 17.9）
- docker-compose.yml 添加 PGSSLMODE=disable，所有 PG 客户端工具自动跳过 SSL 协商
- 仅修改 2 个文件、4 行变更，最小化影响范围

## Task Commits

Each task was committed atomically:

1. **Task 1: 升级 Dockerfile 到 Alpine 3.21 + postgresql17-client** - `c1dbd74` (feat)
2. **Task 2: docker-compose.yml 添加 PGSSLMODE=disable** - `bd9c43b` (feat)

## Files Created/Modified
- `deploy/Dockerfile.noda-ops` - 基础镜像 Alpine 3.19 → 3.21，postgresql-client → postgresql17-client
- `docker/docker-compose.yml` - noda-ops environment 添加 PGSSLMODE: disable

## Decisions Made
- 使用 PGSSLMODE 环境变量方案而非逐行修改备份脚本（仅改 2 个文件 vs 8 个文件 20+ 调用点）
- 选择 Alpine 3.21 稳定版而非 edge（稳定性优先）

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

部署后需要执行：
1. `bash scripts/deploy/deploy-infrastructure-prod.sh` 重建 noda-ops 镜像
2. `docker exec noda-ops pg_dump --version` 验证版本为 17.x
3. `docker exec noda-ops printenv PGSSLMODE` 验证输出 disable
4. 手动触发备份验证全流程正常

## Next Phase Readiness
- Phase 16（Keycloak 端口收敛）可独立开始
- 本 Phase 变更不影响其他服务的运行

---
*Phase: 15-postgresql*
*Completed: 2026-04-12*
