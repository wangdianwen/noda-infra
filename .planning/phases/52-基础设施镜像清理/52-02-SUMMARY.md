---
phase: 52-基础设施镜像清理
plan: 02
subsystem: infra
tags: [docker, dockerfile, layer-optimization, backup, security]

# Dependency graph
requires: []
provides:
  - backup Dockerfile 优化（4 RUN -> 2 RUN，移除 curl）
affects: [backup, image-cleanup]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "RUN 指令合并：初始化类操作（apk add + mkdir + touch + chmod）合并为单个 RUN 减少镜像层"
    - "最小攻击面原则：移除运行时未使用的包（curl）减少容器内可用工具"

key-files:
  created: []
  modified:
    - deploy/Dockerfile.backup

key-decisions:
  - "RUN 1/3/4 合并为单个 RUN（apk add + mkdir + touch + chmod），RUN 2（chmod +x entrypoint.sh）保留在 COPY 之后不可提前合并"
  - "移除 curl：scripts/backup/ 中 grep 确认无 curl 调用，健康检查使用 pg_isready（postgres 基础镜像自带）"

patterns-established:
  - "Dockerfile RUN 合并模式：所有初始化类操作可合并为单个 RUN，但依赖 COPY 产物的操作（如 chmod）必须保留在 COPY 之后"

requirements-completed: [INFRA-02]

# Metrics
duration: 1min
completed: 2026-04-20
---

# Phase 52 Plan 02: 合并 backup Dockerfile RUN 指令 Summary

**backup Dockerfile 从 4 个 RUN 指令精简为 2 个，移除未使用的 curl 包减少攻击面**

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-20T20:46:54Z
- **Completed:** 2026-04-20T20:47:45Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- backup Dockerfile 4 个 RUN 指令合并为 2 个，减少镜像层数
- 移除 curl（scripts/backup/ 中无调用），减少运行时攻击面 per D-08
- mkdir -p 两个目录合并为单个 mkdir 命令

## Task Commits

Each task was committed atomically:

1. **Task 1: 合并 backup Dockerfile RUN 指令并移除 curl** - `95be394` (feat)

## Files Created/Modified
- `deploy/Dockerfile.backup` - 4 RUN 合并为 2 RUN，移除 curl，mkdir 合并

## Decisions Made
- RUN 1 (apk add)、RUN 3 (mkdir+touch+chmod)、RUN 4 (mkdir /app/history) 合并为单个 RUN 指令 -- 它们都是初始化性质且变更频率相同
- RUN 2 (chmod +x entrypoint.sh) 保留在 COPY entrypoint.sh 之后，因为必须先 COPY 文件才能 chmod
- 注释中保留 curl 移除原因说明（per D-08），便于后续维护者理解决策依据

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- backup Dockerfile 优化完成，镜像层数减少
- 注意：docker build 和运行时验证需要在服务器环境执行（本地无法构建 postgres:17-alpine 相关镜像）

## Self-Check: PASSED

- FOUND: deploy/Dockerfile.backup
- FOUND: .planning/phases/52-基础设施镜像清理/52-02-SUMMARY.md
- FOUND: commit 95be394

---
*Phase: 52-基础设施镜像清理*
*Completed: 2026-04-20*
