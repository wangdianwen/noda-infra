---
phase: 44-jenkins-maintenance-cleanup
plan: 02
subsystem: infra
tags: [jenkins, cleanup, pnpm, npm, cron, declarative-pipeline]

# Dependency graph
requires:
  - phase: 44-jenkins-maintenance-cleanup
    plan: 01
    provides: cleanup.sh 新增的 cleanup_jenkins_workspace / cleanup_pnpm_store / cleanup_npm_cache / cleanup_periodic_maintenance / disk_snapshot 函数
provides:
  - jenkins/Jenkinsfile.cleanup - 定期清理 Pipeline 定义（每周一 03:00 cron + FORCE 参数）
affects: [jenkins-maintenance, jenkins-pipeline-registry]

# Tech tracking
tech-stack:
  added: []
patterns: [Declarative Pipeline 定期清理模式, cron + booleanParam 组合用于低频维护任务]

key-files:
  created:
    - jenkins/Jenkinsfile.cleanup
  modified: []

key-decisions:
  - "清理 Pipeline 不包含 COMPOSE_BASE 和 DOPPLER_TOKEN（清理操作无需部署能力）"
  - "清理 Pipeline 直接调用 cleanup.sh 函数，不依赖 pipeline-stages.sh 中间层"
  - "buildDiscarder 保留 10 次构建日志（低于部署 Pipeline 的 20 次，清理日志价值更低）"

patterns-established:
  - "定期清理 Pipeline 模式: cron trigger + booleanParam FORCE + 磁盘快照前后对比"
  - "FORCE 参数透传模式: sh 块中将 Jenkins booleanParam 转为 cleanup.sh 函数的 force 参数"

requirements-completed: [JENK-01, JENK-02, CACHE-02, CACHE-03]

# Metrics
duration: 1min
completed: 2026-04-20
---

# Phase 44 Plan 02: 定期清理 Pipeline Summary

**新建 Jenkinsfile.cleanup 定期清理 Pipeline（cron 每周一 03:00 + FORCE 跳过间隔），直接调用 cleanup.sh 函数实现 Jenkins workspace、pnpm store、npm cache 三类清理**

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-19T20:21:59Z
- **Completed:** 2026-04-19T20:23:05Z
- **Tasks:** 1
- **Files created:** 1

## Accomplishments
- 创建 5 阶段 Declarative Pipeline: Pre-flight -> Disk Snapshot (Before) -> Jenkins Workspace Cleanup -> Package Cache Cleanup -> Disk Snapshot (After)
- cron('0 3 * * 1') 每周一凌晨 3 点自动触发，单服务器使用固定时间 0
- FORCE boolean 参数控制 pnpm store prune 跳过 7 天间隔限制
- 磁盘快照前后对比，直观展示清理效果
- 不依赖 COMPOSE_BASE / DOPPLER_TOKEN / pipeline-stages.sh

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建 jenkins/Jenkinsfile.cleanup 定期清理 Pipeline** - `88bf6e7` (feat)

## Files Created/Modified
- `jenkins/Jenkinsfile.cleanup` - 定期清理 Pipeline 定义（100 行，5 阶段 Declarative Pipeline）

## Decisions Made
- 清理 Pipeline 不包含 COMPOSE_BASE 和 DOPPLER_TOKEN（清理操作不需要部署能力，降低权限暴露）
- 清理 Pipeline 直接 source cleanup.sh 调用函数，不依赖 pipeline-stages.sh 中间层（简化调用链路）
- buildDiscarder 保留 10 次构建日志（低于部署 Pipeline 的 20 次，清理日志诊断价值更低）
- Pre-flight 阶段使用 `${FORCE:-false}` 提供默认值（Jenkins 首次运行时 parameters 块尚未注册）

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Jenkinsfile.cleanup 可通过 Jenkins UI 创建 `cleanup` Pipeline 任务并指向此文件
- 服务器端需要在 Jenkins 中注册 Pipeline Job 并配置 SCM 指向 jenkins/Jenkinsfile.cleanup
- Phase 44 全部完成（Plan 01 + Plan 02）

## Self-Check: PASSED

- FOUND: jenkins/Jenkinsfile.cleanup
- FOUND: 88bf6e7 (task commit)
- FOUND: .planning/phases/44-jenkins-maintenance-cleanup/44-02-SUMMARY.md

---
*Phase: 44-jenkins-maintenance-cleanup*
*Completed: 2026-04-20*
