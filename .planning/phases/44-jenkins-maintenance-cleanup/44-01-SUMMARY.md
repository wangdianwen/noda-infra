---
phase: 44-jenkins-maintenance-cleanup
plan: 01
subsystem: infra
tags: [jenkins, cleanup, pnpm, npm, shell, bash]

# Dependency graph
requires:
  - phase: 43-jenkins-cicd-pipeline
    provides: cleanup.sh 共享库基础函数和模式
provides:
  - cleanup_jenkins_workspace() - Jenkins workspace @tmp 残留目录清理
  - cleanup_pnpm_store() - pnpm store 定期 prune（7 天间隔 + force 模式）
  - cleanup_npm_cache() - npm cache clean --force 清理
  - cleanup_periodic_maintenance() - 定期维护 wrapper 编排以上 3 个函数
affects: [44-02-jenkinsfile-cleanup, jenkins-maintenance]

# Tech tracking
tech-stack:
  added: []
  patterns: [7-day interval marker file for periodic operations, force parameter pattern for interval bypass]

key-files:
  created: []
  modified:
    - scripts/lib/cleanup.sh

key-decisions:
  - "stat 命令同时兼容 macOS（-f %m）和 Linux（-c %Y）以支持跨平台开发"
  - "pnpm store prune 使用标记文件而非 lock 文件，避免与 pnpm install 产生锁冲突"

patterns-established:
  - "间隔标记文件模式: ~/.cache/noda-cleanup/pnpm-prune-marker，stat 读取 mtime 计算天数"
  - "force 参数模式: 函数首个参数接受 'force' 字符串跳过间隔检查"

requirements-completed: [JENK-02, CACHE-02, CACHE-03]

# Metrics
duration: 1min
completed: 2026-04-20
---

# Phase 44 Plan 01: 清理函数扩展 Summary

**为 cleanup.sh 追加 Jenkins workspace @tmp 清理、pnpm store 7 天间隔 prune、npm cache 清理 3 个函数及定期维护 wrapper**

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-19T20:18:52Z
- **Completed:** 2026-04-19T20:19:53Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- cleanup_jenkins_workspace() 遍历 Jenkins workspace 根目录，清理 @tmp 残留目录
- cleanup_pnpm_store() 实现 7 天间隔检查（标记文件机制），支持 force 参数跳过间隔限制
- cleanup_npm_cache() 执行 npm cache clean --force，失败不影响后续操作
- cleanup_periodic_maintenance() wrapper 编排以上 3 个函数，供 Jenkinsfile.cleanup 调用

## Task Commits

Each task was committed atomically:

1. **Task 1: 扩展 cleanup.sh 添加 3 个新清理函数 + 定期清理 wrapper** - `1e35e46` (feat)

## Files Created/Modified
- `scripts/lib/cleanup.sh` - 追加 4 个新函数（131 行新增）

## Decisions Made
- stat 命令同时兼容 macOS（`stat -f '%m'`）和 Linux（`stat -c '%Y'`），确保本地开发和服务器均可运行
- pnpm store prune 使用标记文件（`~/.cache/noda-cleanup/pnpm-prune-marker`）而非 lock 文件，避免与 pnpm install 并发冲突

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- cleanup.sh 已包含 Plan 02 所需的全部清理函数
- cleanup_periodic_maintenance() 可直接被 Jenkinsfile.cleanup 通过 source 调用
- 7 天间隔机制已就位，Plan 02 只需编写 Jenkinsfile 调度逻辑

## Self-Check: PASSED

- FOUND: scripts/lib/cleanup.sh
- FOUND: 1e35e46 (task commit)
- FOUND: .planning/phases/44-jenkins-maintenance-cleanup/44-01-SUMMARY.md

---
*Phase: 44-jenkins-maintenance-cleanup*
*Completed: 2026-04-20*
