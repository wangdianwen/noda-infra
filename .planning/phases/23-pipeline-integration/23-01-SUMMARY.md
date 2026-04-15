---
phase: 23-pipeline-integration
plan: 01
subsystem: ci-cd
tags: [jenkins, pipeline, blue-green, declarative-pipeline, groovy]

# Dependency graph
requires:
  - phase: 22-blue-green-deploy
    provides: "blue-green-deploy.sh 中的 http_health_check, e2e_verify, cleanup_old_images 函数"
  - phase: 21-blue-green-infra
    provides: "manage-containers.sh 中的 run_container, update_upstream, reload_nginx 等函数"
  - phase: 20-nginx-upstream
    provides: "upstream-findclass.conf include 文件"
  - phase: 19-jenkins-install
    provides: "03-pipeline-job.groovy 占位作业配置"
provides:
  - "jenkins/Jenkinsfile — 8 阶段 Declarative Pipeline"
  - "scripts/pipeline-stages.sh — Jenkinsfile 阶段函数库"
  - "03-pipeline-job.groovy — SCM 模式 Pipeline 作业配置"
affects: [23-02-PLAN, jenkins-deployment]

# Tech tracking
tech-stack:
  added: [jenkins-pipeline, groovy-jenkinsfile]
  patterns: [declarative-pipeline, single-source-of-truth, stage-view-granularity]

key-files:
  created:
    - jenkins/Jenkinsfile
    - scripts/pipeline-stages.sh
  modified:
    - scripts/jenkins/init.groovy.d/03-pipeline-job.groovy

key-decisions:
  - "pipeline-stages.sh 独立封装解决 blue-green-deploy.sh 无 source guard 问题"
  - "Test 阶段 install/lint/test 三步分离，Stage View 可区分失败步骤"
  - "03-pipeline-job.groovy 使用 updateByXml 更新策略替代幂等跳过"

patterns-established:
  - "Pipeline 阶段函数模式: pipeline-stages.sh 中 pipeline_* 函数 + Jenkinsfile sh 步骤调用"
  - "单引号 sh 命令: 防止 Groovy 插值泄露环境变量"
  - "Pre-flight 单一真相源: 所有前置检查集中在 pipeline_preflight() 中"

requirements-completed: [PIPE-01, PIPE-04, PIPE-05]

# Metrics
duration: 2min
completed: 2026-04-15
---

# Phase 23 Plan 01: Pipeline 集成 Summary

**8 阶段 Declarative Pipeline（Pre-flight/Build/Test/Deploy/Health Check/Switch/Verify/Cleanup）+ SCM 模式作业配置 + pipeline-stages.sh 函数库封装**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-15T20:00:02Z
- **Completed:** 2026-04-15T20:02:59Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- 创建 scripts/pipeline-stages.sh 函数库，封装 9 个 pipeline_* 函数 + 3 个从 blue-green-deploy.sh 复制的函数
- 创建 jenkins/Jenkinsfile 8 阶段 Declarative Pipeline，每阶段调用 pipeline-stages.sh 函数
- 更新 03-pipeline-job.groovy 从 CpsFlowDefinition 占位模式改为 CpsScmFlowDefinition SCM 模式
- Test 阶段 install/lint/test 三步分离，Jenkins Stage View 可精确区分失败步骤

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建 scripts/pipeline-stages.sh 阶段函数库** - `bee5bea` (feat)
2. **Task 2: 创建 jenkins/Jenkinsfile + 更新 03-pipeline-job.groovy** - `b349f1c` (feat)

## Files Created/Modified
- `scripts/pipeline-stages.sh` - Jenkinsfile 阶段函数库（9 个 pipeline_* 函数 + 3 个辅助函数）
- `jenkins/Jenkinsfile` - 8 阶段 Declarative Pipeline 完整定义
- `scripts/jenkins/init.groovy.d/03-pipeline-job.groovy` - SCM 模式 Pipeline 作业配置（CpsScmFlowDefinition）

## Decisions Made
- **pipeline-stages.sh 独立封装**: blue-green-deploy.sh 末尾直接调用 `main "$@"` 无 source guard，不能安全 source。将 Jenkinsfile 需要的函数独立封装到 pipeline-stages.sh
- **Test 阶段三步分离**: install/lint/test 作为三个独立 sh 步骤，Jenkins Stage View 可区分是 lint 还是 test 失败（RESEARCH.md Pitfall 4）
- **updateByXml 更新策略**: 03-pipeline-job.groovy 从"已存在则跳过"改为"已存在则更新配置"，解决 Phase 19 占位作业的幂等性问题
- **pipeline_test 仅处理 pnpm install**: lint 和 test 不通过 pipeline_test 函数调用，确保 Stage View 粒度

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Pipeline 定义完成，可通过 "Build Now" 手动触发部署
- 需要确保 Jenkins 服务器上存在 noda-apps-git-credentials 和 noda-infra-git-credentials 凭据
- Phase 23 Plan 02 将处理测试门禁和 Pipeline 端到端验证

## Self-Check: PASSED

- FOUND: scripts/pipeline-stages.sh
- FOUND: jenkins/Jenkinsfile
- FOUND: scripts/jenkins/init.groovy.d/03-pipeline-job.groovy
- FOUND: 23-01-SUMMARY.md
- FOUND: bee5bea (Task 1 commit)
- FOUND: b349f1c (Task 2 commit)

---
*Phase: 23-pipeline-integration*
*Completed: 2026-04-15*
