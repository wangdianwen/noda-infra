---
phase: 28-keycloak
plan: 03
subsystem: infra
tags: [jenkins, pipeline, keycloak, blue-green, docker]

# Dependency graph
requires:
  - phase: 28-01
    provides: "Keycloak 蓝绿容器管理脚本 + env-keycloak.env + nginx upstream 配置"
  - phase: 28-02
    provides: "keycloak-blue-green-deploy.sh 部署脚本 + manage-containers.sh Keycloak 参数化"
provides:
  - "Jenkinsfile.keycloak — Keycloak 蓝绿部署 Jenkins Pipeline（7 阶段）"
  - "pipeline_pull_image 函数 — 官方镜像拉取（无构建服务复用）"
  - "pipeline_deploy SERVICE_IMAGE 支持 — 官方镜像名覆盖 Git SHA 标签"
  - "pipeline_cleanup 官方镜像优化 — 跳过 SHA 清理，仅清理 dangling images"
affects: [phase-29-unified-pipeline, keycloak-deploy]

# Tech tracking
tech-stack:
  added: [jenkinsfile.keycloak, pipeline_pull_image]
  patterns: [官方镜像无构建Pipeline, SERVICE_IMAGE参数化部署, 固定版本标签跳过SHA清理]

key-files:
  created: [jenkins/Jenkinsfile.keycloak]
  modified: [scripts/pipeline-stages.sh]

key-decisions:
  - "Keycloak Pipeline 不包含 Build/Test/Cleanup 阶段，使用 Pull Image 拉取官方镜像"
  - "pipeline_deploy 通过 SERVICE_IMAGE 环境变量区分官方镜像和自构建镜像"
  - "pipeline_preflight 对 Keycloak 跳过 noda-apps 目录检查"

patterns-established:
  - "无构建 Pipeline 模式: Pre-flight -> Pull Image -> Deploy -> Health Check -> Switch -> Verify -> CDN Purge"
  - "SERVICE_IMAGE 环境变量: 设置后 pipeline_deploy 使用官方镜像而非 Git SHA 标签"

requirements-completed: [KCBLUE-04, KCBLUE-01]

# Metrics
duration: 3min
completed: 2026-04-17
---

# Phase 28 Plan 03: Keycloak 蓝绿部署 Pipeline Summary

**Keycloak 7 阶段蓝绿部署 Pipeline（无构建模式）+ pipeline-stages.sh 扩展支持官方镜像服务**

## Performance

- **Duration:** 3 min
- **Started:** 2026-04-17T04:31:36Z
- **Completed:** 2026-04-17T04:34:37Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- 创建 Jenkinsfile.keycloak（7 阶段: Pre-flight -> Pull Image -> Deploy -> Health Check -> Switch -> Verify -> CDN Purge）
- pipeline-stages.sh 新增 pipeline_pull_image 函数，支持 Keycloak 等官方镜像服务的无构建部署流程
- pipeline_deploy 支持 SERVICE_IMAGE 环境变量，自动区分官方镜像和自构建 Git SHA 镜像
- pipeline_cleanup 优化：官方镜像服务跳过 SHA 镜像清理，仅清理 dangling images

## Task Commits

Each task was committed atomically:

1. **Task 1: pipeline-stages.sh 新增 pipeline_pull_image 函数** - `ac3816c` (feat)
2. **Task 2: 创建 Jenkinsfile.keycloak** - `564670c` (feat)

## Files Created/Modified
- `jenkins/Jenkinsfile.keycloak` - Keycloak 蓝绿部署 Jenkins Pipeline（7 阶段，手动触发，无构建模式）
- `scripts/pipeline-stages.sh` - 新增 pipeline_pull_image 函数 + Keycloak preflight 支持 + SERVICE_IMAGE 部署支持 + 官方镜像清理优化

## Decisions Made
- Keycloak Pipeline 不包含 Build/Test/Cleanup 阶段，改用 Pull Image 拉取 quay.io/keycloak/keycloak:26.2.3
- pipeline_preflight 对 Keycloak 服务跳过 noda-apps 目录检查（Keycloak 不需要源码）
- pipeline_cleanup 对官方镜像服务仅清理 dangling images，跳过 Git SHA 标签清理
- pipeline_deploy 不传 GIT_SHA 参数（SERVICE_IMAGE 已提供完整镜像名）

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] pipeline_preflight 条件化 noda-apps 目录检查**
- **Found during:** Task 1 (pipeline-stages.sh 修改)
- **Issue:** pipeline_preflight 无条件检查 noda-apps 目录是否存在，Keycloak Pipeline 的 WORKSPACE 下不会有 noda-apps，会导致 Pre-flight 阶段必然失败
- **Fix:** 将 noda-apps 目录检查移到条件分支内，对 keycloak 服务跳过此检查
- **Files modified:** scripts/pipeline-stages.sh
- **Verification:** 逻辑审查通过，keycloak 分支不执行 noda-apps 检查
- **Committed in:** ac3816c (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 missing critical)
**Impact on plan:** 必要的修正。无 noda-apps 目录检查跳过，Keycloak Pipeline 无法通过 Pre-flight 阶段。无范围蔓延。

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Keycloak 蓝绿部署 Pipeline 已就绪，可在 Jenkins 中创建 keycloak-deploy 任务
- pipeline-stages.sh 已支持 SERVICE_IMAGE 参数化，未来其他官方镜像服务可复用同一模式
- 需要 28-01/28-02 的基础设施就绪后（manage-containers.sh Keycloak 参数、nginx upstream 配置、env-keycloak.env）才能实际运行 Pipeline

## Self-Check: PASSED

- FOUND: jenkins/Jenkinsfile.keycloak
- FOUND: scripts/pipeline-stages.sh
- FOUND: .planning/phases/28-keycloak/28-03-SUMMARY.md
- FOUND: ac3816c (Task 1 commit)
- FOUND: 564670c (Task 2 commit)

---
*Phase: 28-keycloak*
*Completed: 2026-04-17*
