---
phase: 34-jenkins-matrix
plan: 01
subsystem: auth
tags: [jenkins, matrix-auth, groovy, authorization, rbac]

# Dependency graph
requires:
  - phase: 34-jenkins-matrix
    provides: setup-jenkins.sh 已有 Groovy CLI 模式和 jenkins-cli.jar 搜索逻辑
provides:
  - Jenkins 权限矩阵 Groovy 脚本（06-matrix-auth.groovy）
  - setup-jenkins.sh apply-matrix-auth / verify-matrix-auth 子命令
affects: [34-jenkins-matrix, setup-docker-permissions.sh]

# Tech tracking
tech-stack:
  added: [matrix-auth Jenkins plugin, GlobalMatrixAuthorizationStrategy]
  patterns: [Groovy init script for authorization, CLI-based matrix auth verification]

key-files:
  created:
    - scripts/jenkins/init.groovy.d/06-matrix-auth.groovy
  modified:
    - scripts/setup-jenkins.sh

key-decisions:
  - "权限矩阵通过 GlobalMatrixAuthorizationStrategy 实现两角色分离（Admin 全权限 + Developer 最小权限）"
  - "developer 用户通过 Groovy 脚本自动创建，初始密码 changeme-immediately"
  - "verify-matrix-auth 使用内联 Groovy 脚本通过 CLI 验证 7 项权限检查"

patterns-established:
  - "Groovy 脚本权限验证模式：通过 jenkins-cli.jar 执行内联 Groovy 脚本检查 Jenkins 运行时配置"
  - "setup-jenkins.sh 子命令扩展模式：复用 jenkins-cli.jar 搜索逻辑 + root 权限检查 + macOS 跳过"

requirements-completed: [JENKINS-03, JENKINS-04]

# Metrics
duration: 2min
completed: 2026-04-18
---

# Phase 34 Plan 01: Jenkins 权限矩阵 Summary

**两角色 Jenkins 权限矩阵（Admin 全权限 + Developer 最小权限），通过 Groovy 脚本 + setup-jenkins.sh 子命令自动化配置和验证**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-18T01:20:17Z
- **Completed:** 2026-04-18T01:22:36Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- 创建 06-matrix-auth.groovy 脚本，自动安装 matrix-auth 插件并配置权限矩阵
- Developer 用户权限最小化：仅 Overall/Read + Job/Read + Job/Build + Job/Discover + Run/Read + View/Read
- Developer 明确不授予 Item/Configure、Credentials、Script Console 等敏感权限
- setup-jenkins.sh 新增 apply-matrix-auth 和 verify-matrix-auth 两个子命令

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建 06-matrix-auth.groovy 权限矩阵脚本** - `0b13e77` (feat)
2. **Task 2: 在 setup-jenkins.sh 中添加 apply-matrix-auth 和 verify-matrix-auth 子命令** - `bd27515` (feat)

## Files Created/Modified
- `scripts/jenkins/init.groovy.d/06-matrix-auth.groovy` - Jenkins 权限矩阵 Groovy 脚本（插件安装 + 用户创建 + 权限配置）
- `scripts/setup-jenkins.sh` - 新增 cmd_apply_matrix_auth / cmd_verify_matrix_auth 函数 + usage/case 更新

## Decisions Made
- 权限矩阵通过 GlobalMatrixAuthorizationStrategy 实现，每次执行重新创建策略对象保证幂等性
- developer 用户通过 HudsonPrivateSecurityRealm.createAccount 自动创建，初始密码 changeme-immediately（管理员需通过 UI 修改）
- verify-matrix-auth 检查 7 项权限配置：策略类型、admin ADMINISTER、developer BUILD/READ/RUN.READ/OVERALL.READ、developer 无 CONFIGURE

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Plan 01 完成为权限矩阵自动化配置基础
- Plan 02（统一管理脚本 setup-docker-permissions.sh）可调用 apply-matrix-auth / verify-matrix-auth 子命令

## Self-Check: PASSED

- FOUND: scripts/jenkins/init.groovy.d/06-matrix-auth.groovy
- FOUND: scripts/setup-jenkins.sh
- FOUND: .planning/phases/34-jenkins-matrix/34-01-SUMMARY.md
- FOUND: commit 0b13e77 (Task 1)
- FOUND: commit bd27515 (Task 2)

---
*Phase: 34-jenkins-matrix*
*Completed: 2026-04-18*
