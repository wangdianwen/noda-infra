---
phase: 29-jenkins-pipeline
plan: 02
subsystem: infra
tags: [jenkins, pipeline, declarative, infrastructure, keycloak, nginx, noda-ops, postgres]

# Dependency graph
requires:
  - phase: 29-01
    provides: pipeline_infra_* 函数（pipeline-stages.sh 中新增的 7 个基础设施函数）
provides:
  - jenkins/Jenkinsfile.infra 统一基础设施 Pipeline
  - 参数化服务选择（choice 参数 4 服务）
  - 条件化 Backup 和 Human Approval 阶段
affects: [29-03, deploy-infrastructure-prod.sh]

# Tech tracking
tech-stack:
  added: []
  patterns: [jenkins-choice-parameter, when-conditional-stages, input-approval-gate]

key-files:
  created:
    - jenkins/Jenkinsfile.infra
  modified: []

key-decisions:
  - "单引号 sh 块防止 Groovy 插值泄露凭据到日志"
  - "不包含 CDN Purge 阶段 — 基础设施服务不涉及静态资源缓存"
  - "不包含 Build/Test 阶段 — 基础设施服务不从源码构建"
  - "Keycloak 的 Deploy 调用 keycloak-blue-green-deploy.sh，Health Check 做二次验证"

patterns-established:
  - "Jenkinsfile.infra 条件化模式: when { expression { params.SERVICE == 'xxx' } } 控制阶段执行"
  - "统一 Pipeline 分发: pipeline_infra_* 函数根据 SERVICE 参数 case 分发到服务专属逻辑"

requirements-completed: [PIPELINE-01, PIPELINE-07]

# Metrics
duration: 3min
completed: 2026-04-17
---

# Phase 29 Plan 02: Jenkinsfile.infra 统一基础设施 Pipeline Summary

**Declarative Pipeline 7 阶段统一基础设施部署，choice 参数选择 4 服务，Backup 条件化 + postgres 30 分钟人工确认门禁**

## Performance

- **Duration:** 3 min
- **Started:** 2026-04-17T09:19:12Z
- **Completed:** 2026-04-17T09:21:51Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- 创建 jenkins/Jenkinsfile.infra，统一管理 keycloak/nginx/noda-ops/postgres 4 种基础设施服务部署
- 7 阶段 Pipeline: Pre-flight -> Backup -> Human Approval -> Deploy -> Health Check -> Verify -> Cleanup
- Backup 阶段 when 条件化（仅 keycloak/postgres 执行 pg_dump）
- Human Approval 阶段 when 条件化（仅 postgres 需要 30 分钟超时人工确认）
- post failure 包含 pipeline_infra_failure_cleanup 自动回滚 + archiveArtifacts 日志归档

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建 Jenkinsfile.infra 统一基础设施 Pipeline** - `c3479a9` (feat)

## Files Created/Modified
- `jenkins/Jenkinsfile.infra` - 统一基础设施部署 Pipeline（132 行，Declarative Pipeline，7 阶段，参数化服务选择）

## Decisions Made
- 单引号 sh 块（`'''`）防止 Groovy 插值泄露凭据到日志（per Phase 24 安全决策）
- 不包含 CDN Purge 阶段 — 基础设施服务不涉及静态资源缓存
- 不包含 Build/Test 阶段 — 基础设施服务不从源码构建（keycloak 用官方镜像，nginx/noda-ops 用 compose）
- Keycloak Deploy 阶段调用 pipeline_infra_deploy，内部封装 keycloak-blue-green-deploy.sh；Health Check 阶段做二次验证

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Jenkinsfile.infra 已创建，可注册到 Jenkins 作为 Pipeline 任务
- Plan 03 将同步更新 deploy-infrastructure-prod.sh（移除已被 Pipeline 覆盖的服务）
- pipeline-stages.sh 中 pipeline_infra_* 函数（Plan 01 产出）已可被 Jenkinsfile.infra 调用

## Self-Check: PASSED

- [x] jenkins/Jenkinsfile.infra exists
- [x] 29-02-SUMMARY.md exists
- [x] Commit c3479a9 found in git log

---
*Phase: 29-jenkins-pipeline*
*Completed: 2026-04-17*
