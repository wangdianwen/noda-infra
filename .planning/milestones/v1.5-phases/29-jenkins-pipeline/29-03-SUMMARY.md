---
phase: 29-jenkins-pipeline
plan: 03
subsystem: infra
tags: [jenkins, pipeline, deploy, bash, postgres]

# Dependency graph
requires:
  - phase: 29-jenkins-pipeline/01
    provides: pipeline-stages.sh 基础设施 Pipeline 函数
  - phase: 29-jenkins-pipeline/02
    provides: Jenkinsfile.infra 统一基础设施 Pipeline
provides:
  - 精简的 deploy-infrastructure-prod.sh 手动回退脚本（仅 postgres）
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns: [手动脚本仅保留紧急回退，Pipeline 为主要部署方式]

key-files:
  created: []
  modified:
    - scripts/deploy/deploy-infrastructure-prod.sh

key-decisions:
  - "保留备份函数通过 noda-ops 容器执行（postgres 部署前备份仍需要 noda-ops）"
  - "步骤从 7 步精简为 5 步，最终验证合并到步骤 5"

patterns-established:
  - "手动部署脚本仅保留核心服务（postgres），其他服务引用 Pipeline"

requirements-completed: []

# Metrics
duration: 4min
completed: 2026-04-17
---

# Phase 29 Plan 03: 精简手动部署回退脚本 Summary

**deploy-infrastructure-prod.sh 精简为仅 postgres 部署，nginx/noda-ops 迁移到 Jenkinsfile.infra Pipeline 管理**

## Performance

- **Duration:** 4 min
- **Started:** 2026-04-17T09:25:24Z
- **Completed:** 2026-04-17T09:29:22Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- deploy-infrastructure-prod.sh 从 360 行精简为 325 行（-61 行/+26 行）
- 移除 nginx、noda-ops、postgres-dev 从 EXPECTED_CONTAINERS 和 START_SERVICES
- 步骤从 7 步精简为 5 步（移除 Keycloak 配置步骤，合并最终验证到步骤 5）
- 头部注释更新，引用 Jenkinsfile.infra 作为主要部署方式

## Task Commits

Each task was committed atomically:

1. **Task 1: 精简 deploy-infrastructure-prod.sh** - `75c5b52` (refactor)

## Files Created/Modified
- `scripts/deploy/deploy-infrastructure-prod.sh` - 精简为仅 postgres 部署，移除 nginx/noda-ops 逻辑

## Decisions Made
- 保留备份函数（check_recent_backup/run_pre_deploy_backup）中对 noda-ops 容器的引用，因为 postgres 部署前备份仍需要通过 noda-ops 容器执行
- 步骤编号从 7 步更新为 5 步，最终验证（重启次数检查）合并到步骤 5/5 而非单独步骤
- COMPOSE_FILES 移除 dev overlay（Phase 27 已清理 postgres-dev 服务）

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Phase 29 全部 3 个 Plan 已完成
- Jenkinsfile.infra 已创建（Plan 02），pipeline-stages.sh 函数已添加（Plan 01），手动脚本已精简（Plan 03）
- 下一步：Phase 29 完成后进入 v1.5 下一阶段

## Self-Check: PASSED

- FOUND: scripts/deploy/deploy-infrastructure-prod.sh
- FOUND: .planning/phases/29-jenkins-pipeline/29-03-SUMMARY.md
- FOUND: commit 75c5b52

---
*Phase: 29-jenkins-pipeline*
*Completed: 2026-04-17*
