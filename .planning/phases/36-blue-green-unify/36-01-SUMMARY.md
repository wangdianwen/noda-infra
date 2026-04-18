---
phase: 36-blue-green-unify
plan: 01
subsystem: infra
tags: [blue-green, deployment, parameterization, docker, nginx]

# Dependency graph
requires:
  - phase: 35-shared-libs
    provides: "shared library extraction (deploy-check.sh, image-cleanup.sh)"
provides:
  - "统一参数化蓝绿部署脚本 blue-green-deploy.sh（IMAGE_SOURCE + CLEANUP_METHOD）"
  - "findclass-ssr 向后兼容 wrapper（blue-green-deploy-findclass.sh）"
  - "keycloak 向后兼容 wrapper（keycloak-blue-green-deploy.sh）"
affects: [36-02, pipeline-stages.sh, Jenkinsfile]

# Tech tracking
tech-stack:
  added: []
  patterns: ["环境变量参数化蓝绿部署（IMAGE_SOURCE/CLEANUP_METHOD）", "exec wrapper 模式（thin wrapper + exec 调用统一脚本）"]

key-files:
  created:
    - scripts/blue-green-deploy-findclass.sh
  modified:
    - scripts/blue-green-deploy.sh
    - scripts/keycloak-blue-green-deploy.sh

key-decisions:
  - "IMAGE_SOURCE 三模式（build/pull/none）替代硬编码构建逻辑"
  - "CLEANUP_METHOD 三策略（tag-count/dangling/none）替代硬编码清理调用"
  - "wrapper 使用 exec 调用统一脚本保持进程号一致"
  - "keycloak wrapper 保留原文件名确保 pipeline-stages.sh 无需改动"

patterns-established:
  - "Wrapper 模式: 服务专属参数 export + exec 调用统一脚本"
  - "参数化部署: IMAGE_SOURCE 控制镜像获取，CLEANUP_METHOD 控制清理策略"

requirements-completed: [BLUE-01]

# Metrics
duration: 2min
completed: 2026-04-19
---

# Phase 36 Plan 01: 蓝绿部署脚本统一 Summary

**合并 findclass-ssr 和 keycloak 蓝绿部署脚本为统一参数化脚本，通过 IMAGE_SOURCE/CLEANUP_METHOD 环境变量区分服务差异**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-18T20:10:15Z
- **Completed:** 2026-04-18T20:12:34Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- 统一脚本 blue-green-deploy.sh 支持 build/pull/none 三种镜像获取和 tag-count/dangling/none 三种清理策略
- findclass-ssr wrapper (blue-green-deploy-findclass.sh) 设置 IMAGE_SOURCE=build, CLEANUP_METHOD=tag-count
- keycloak wrapper (keycloak-blue-green-deploy.sh) 从 190 行精简到 51 行，设置 IMAGE_SOURCE=pull, CLEANUP_METHOD=dangling
- 所有健康检查调用使用 $SERVICE_PORT 和 $HEALTH_PATH，无硬编码端口或路径

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建统一参数化蓝绿部署脚本 blue-green-deploy.sh** - `88f26f7` (feat)
2. **Task 2: 创建 findclass wrapper + 改写 keycloak wrapper** - `9ed05a7` (feat)

## Files Created/Modified
- `scripts/blue-green-deploy.sh` - 统一参数化蓝绿部署脚本（107 行，覆盖旧 findclass-ssr 专用脚本）
- `scripts/blue-green-deploy-findclass.sh` - findclass-ssr 向后兼容 thin wrapper（新建，21 行）
- `scripts/keycloak-blue-green-deploy.sh` - keycloak 向后兼容 thin wrapper（从 190 行精简到 51 行）

## Decisions Made
- IMAGE_SOURCE 三模式设计（build/pull/none）直接映射两个服务的差异：findclass-ssr 用 build，keycloak 用 pull
- CLEANUP_METHOD 三策略设计（tag-count/dangling/none）：findclass-ssr 用 tag-count（保留 5 个 SHA 标签），keycloak 用 dangling（官方镜像无标签管理需求）
- wrapper 使用 exec 而非 bash 调用，确保信号传递和退出码一致
- COMPOSE_MIGRATION_CONTAINER 仅 keycloak 需要，统一脚本中通过条件检查处理

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Self-Check: PASSED

All files and commits verified present.

## Next Phase Readiness
- 统一脚本和两个 wrapper 已完成，pipeline-stages.sh 无需改动即可正常调用 keycloak wrapper
- Plan 02 可在此基础上继续清理其他重复代码

---
*Phase: 36-blue-green-unify*
*Completed: 2026-04-19*
