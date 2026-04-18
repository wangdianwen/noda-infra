---
phase: 36-blue-green-unify
plan: 02
subsystem: infra
tags: [blue-green, rollback, nginx, docker, parameterization]

# Dependency graph
requires:
  - phase: 35-shared-libs
    provides: scripts/lib/deploy-check.sh, scripts/lib/log.sh 共享库
  - phase: 36-blue-green-unify/01
    provides: manage-containers.sh 参数化（SERVICE_NAME/SERVICE_PORT/HEALTH_PATH）
provides:
  - 统一参数化回滚脚本 rollback-deploy.sh
  - findclass-ssr 回滚 wrapper（向后兼容）
  - keycloak 回滚 wrapper
affects: [36-blue-green-unify, jenkinsfile, keycloak-deploy]

# Tech tracking
tech-stack:
  added: []
  patterns: [wrapper 模式: 服务专属 wrapper 通过环境变量覆盖参数后 exec 调用统一脚本]

key-files:
  created:
    - scripts/rollback-deploy.sh
    - scripts/rollback-keycloak.sh
  modified:
    - scripts/rollback-findclass.sh

key-decisions:
  - "回滚脚本通过 SERVICE_PORT/HEALTH_PATH 环境变量参数化，消除硬编码端口 3001 和路径 /api/health"
  - "重试参数通过 ROLLBACK_HEALTH_RETRIES/ROLLBACK_HEALTH_INTERVAL/ROLLBACK_E2E_RETRIES/ROLLBACK_E2E_INTERVAL 环境变量可配置"
  - "findclass wrapper 不设置任何参数覆盖，直接使用 manage-containers.sh 默认值"

patterns-established:
  - "Wrapper 模式: 服务专属 wrapper 通过 export 覆盖环境变量后 exec 调用统一脚本"
  - "参数化回滚: 重试次数/间隔通过 ROLLBACK_* 环境变量可配置，带合理默认值"

requirements-completed: [BLUE-02]

# Metrics
duration: 2min
completed: 2026-04-19
---

# Phase 36 Plan 02: 统一回滚脚本 Summary

**统一参数化蓝绿回滚脚本 rollback-deploy.sh + findclass wrapper + keycloak wrapper，消除硬编码端口和路径**

## Performance

- **Duration:** 1m 50s
- **Started:** 2026-04-18T20:10:16Z
- **Completed:** 2026-04-18T20:12:06Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- 创建统一回滚脚本 rollback-deploy.sh，所有端口/路径通过环境变量参数化
- 改写 rollback-findclass.sh 为 thin wrapper（14 行），保持向后兼容
- 创建 rollback-keycloak.sh wrapper，设置 keycloak 专属参数（SERVICE_PORT=8080, HEALTH_PATH=/realms/master）

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建统一回滚脚本 rollback-deploy.sh** - `b918d39` (feat)
2. **Task 2: 改写 rollback-findclass.sh 为 wrapper + 创建 rollback-keycloak.sh wrapper** - `f6527be` (feat)

## Files Created/Modified
- `scripts/rollback-deploy.sh` - 统一参数化蓝绿回滚脚本，通过 SERVICE_PORT/HEALTH_PATH/ROLLBACK_* 环境变量参数化
- `scripts/rollback-findclass.sh` - findclass-ssr 回滚 thin wrapper，exec 调用统一脚本
- `scripts/rollback-keycloak.sh` - keycloak 回滚 wrapper，设置 keycloak 专属参数后 exec 调用统一脚本

## Decisions Made
- 回滚脚本通过 SERVICE_PORT/HEALTH_PATH 环境变量参数化，消除硬编码端口 3001 和路径 /api/health（per D-03）
- 重试参数通过 ROLLBACK_HEALTH_RETRIES/ROLLBACK_HEALTH_INTERVAL/ROLLBACK_E2E_RETRIES/ROLLBACK_E2E_INTERVAL 环境变量可配置，带合理默认值（10/3/5/2）
- findclass wrapper 不设置任何参数覆盖，因为 manage-containers.sh 默认值就是 findclass-ssr 的值
- keycloak wrapper 必须覆盖 SERVICE_NAME、SERVICE_PORT、HEALTH_PATH、ACTIVE_ENV_FILE、UPSTREAM_CONF（与 keycloak-blue-green-deploy.sh 保持一致）

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- 回滚脚本统一完成，findclass-ssr 和 keycloak 各有专属 wrapper
- rollback-findclass.sh 保持向后兼容，现有调用方无需修改
- rollback-keycloak.sh 可直接用于 keycloak 紧急回滚

## Self-Check: PASSED

- scripts/rollback-deploy.sh: FOUND
- scripts/rollback-findclass.sh: FOUND
- scripts/rollback-keycloak.sh: FOUND
- 36-02-SUMMARY.md: FOUND
- Commit b918d39: FOUND
- Commit f6527be: FOUND

---
*Phase: 36-blue-green-unify*
*Completed: 2026-04-19*
