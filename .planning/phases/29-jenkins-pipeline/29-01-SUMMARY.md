---
phase: 29-jenkins-pipeline
plan: 01
subsystem: infra
tags: [jenkins, pipeline, docker-compose, blue-green, pg_dump, health-check, rollback]

# Dependency graph
requires:
  - phase: 28-keycloak
    provides: keycloak-blue-green-deploy.sh 蓝绿部署脚本
provides:
  - pipeline-stages.sh 中 12 个基础设施 Pipeline 函数（备份/部署/健康检查/回滚/验证/清理）
  - 4 种服务的独立部署策略（keycloak=蓝绿, nginx=recreate, noda-ops=recreate, postgres=restart）
  - pipeline_backup_database 自动 pg_dump 备份函数
  - pipeline_infra_rollback 服务专属回滚（含 compose overlay 生成）
affects: [29-02, 29-03]

# Tech tracking
tech-stack:
  added: []
  patterns: [基础设施 Pipeline 函数分发模式, compose overlay 回滚模式, 服务专属健康检查策略]

key-files:
  created: []
  modified:
    - scripts/pipeline-stages.sh

key-decisions:
  - "Keycloak 部署复用 keycloak-blue-green-deploy.sh，通过环境变量注入参数"
  - "nginx/noda-ops 回滚使用临时 compose overlay 文件（参考 deploy-infrastructure-prod.sh rollback_images 模式）"
  - "备份函数对 keycloak 执行 pg_dump（单库），对 postgres 执行 pg_dumpall（全库）"
  - "Keycloak 健康检查由蓝绿脚本内部处理，pipeline 层做二次验证"

patterns-established:
  - "基础设施 Pipeline 函数命名: pipeline_infra_{action} 格式"
  - "服务分发: case 语句分发到 pipeline_deploy_{service} 子函数"
  - "回滚镜像保存: INFRA_ROLLBACK_IMAGE 环境变量保存部署前镜像 digest"
  - "备份文件导出: INFRA_BACKUP_FILE 环境变量供回滚函数使用"

requirements-completed: [PIPELINE-02, PIPELINE-03, PIPELINE-04, PIPELINE-05, PIPELINE-06]

# Metrics
duration: 5min
completed: 2026-04-17
---

# Phase 29 Plan 01: 基础设施 Pipeline 阶段函数 Summary

**pipeline-stages.sh 新增 12 个 pipeline_infra_* 函数，覆盖 4 种基础设施服务的备份/部署/健康检查/回滚/验证/清理完整生命周期**

## Performance

- **Duration:** 5 min
- **Started:** 2026-04-17T09:08:11Z
- **Completed:** 2026-04-17T09:13:14Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- 新增 7 个核心部署函数（preflight + backup + deploy 分发 + 4 个服务专属部署函数）
- 新增 5 个运维函数（health_check + rollback + verify + cleanup + failure_cleanup）
- 每种服务有独立的部署策略和回滚机制
- 备份函数自动验证文件大小，失败时中止部署

## Task Commits

Each task was committed atomically:

1. **Task 1: 新增 pipeline_backup_database 和 pipeline_infra_deploy 分发函数** - `729df8f` (feat)
2. **Task 2: 新增健康检查、回滚、Verify 和 Cleanup 函数** - `14b3a0c` (feat)

## Files Created/Modified
- `scripts/pipeline-stages.sh` - 新增 12 个基础设施 Pipeline 函数（+466 行），不修改现有函数

## Decisions Made
- Keycloak 部署复用 keycloak-blue-green-deploy.sh，通过 export 环境变量注入 SERVICE_NAME/PORT/UPSTREAM_NAME 等参数
- nginx/noda-ops 回滚使用 mktemp 生成临时 compose overlay 文件（含 image digest），参考 deploy-infrastructure-prod.sh rollback_images() 模式
- 备份函数对 keycloak 执行 pg_dump --clean --if-exists（单库），对 postgres 执行 pg_dumpall --clean --if-exists（全库）
- Keycloak 健康检查由蓝绿脚本内部处理，pipeline_infra_health_check 做二次 wait_container_healthy 验证

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- pipeline-stages.sh 已包含所有 Jenkinsfile.infra 需要的后端函数
- Plan 02 将创建 Jenkinsfile.infra 统一入口，通过 `when` 条件化阶段执行
- Plan 03 将更新 deploy-infrastructure-prod.sh 移除已被 Pipeline 覆盖的 nginx/noda-ops 逻辑

---
*Phase: 29-jenkins-pipeline*
*Completed: 2026-04-17*

## Self-Check: PASSED

- FOUND: scripts/pipeline-stages.sh
- FOUND: .planning/phases/29-jenkins-pipeline/29-01-SUMMARY.md
- FOUND: 729df8f (Task 1 commit)
- FOUND: 14b3a0c (Task 2 commit)
