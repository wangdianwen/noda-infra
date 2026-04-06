---
phase: 08-execute-restore-scripts
plan: 01
subsystem: database
tags: [postgresql, docker, restore, docker-exec, bash]

# Dependency graph
requires:
  - phase: 07-execute-cloud-integration
    provides: 云存储集成功能（cloud.sh 已验证）
provides:
  - restore.sh 宿主机兼容的 restore_database() 函数
  - restore.sh 宿主机兼容的 verify_backup_integrity() 函数
  - test_restore_quick.sh 全部 5 项测试通过
affects: [08-02, restore-scripts]

# Tech tracking
tech-stack:
  added: []
  patterns: [docker-exec-host-detection, is_host-boolean-flag]

key-files:
  created: []
  modified:
    - scripts/backup/lib/restore.sh
    - scripts/backup/tests/test_restore_quick.sh

key-decisions:
  - "restore_database() 和 verify_backup_integrity() 采用与 verify.sh 一致的 /.dockerenv 检测模式"
  - "SQL 文件恢复使用 docker exec -i 通过 stdin 管道传入容器"
  - "修复 test_restore_quick.sh 中 heredoc 缺少 -i 标志的预先存在 bug"

patterns-established:
  - "宿主机/容器环境检测: local is_host=false; if [[ ! -f /.dockerenv ]]; then is_host=true; fi"
  - "docker exec 封装: 宿主机使用 docker exec noda-infra-postgres-1 (psql|pg_restore)，容器内直接调用"

requirements-completed: [RESTORE-01, RESTORE-03, RESTORE-04]

# Metrics
duration: 5min
completed: 2026-04-06
---

# Phase 8 Plan 01: 修复 restore.sh docker exec 兼容性 Summary

**restore_database() 和 verify_backup_integrity() 添加 /.dockerenv 环境检测，宿主机通过 docker exec 封装执行 PostgreSQL 命令，test_restore_quick.sh 全部 5 项测试通过**

## Performance

- **Duration:** 5 min
- **Started:** 2026-04-06T09:07:13Z
- **Completed:** 2026-04-06T09:12:27Z
- **Tasks:** 1
- **Files modified:** 2

## Accomplishments
- restore_database() 在宿主机上通过 docker exec 正确执行 DROP/CREATE DATABASE、pg_restore、psql 恢复和表数量验证
- verify_backup_integrity() 在宿主机上通过 docker exec 正确执行 pg_restore -l 验证
- test_restore_quick.sh 全部 5 项测试在 macOS 宿主机上通过

## Task Commits

Each task was committed atomically:

1. **Task 1: 修复 restore.sh 的 docker exec 兼容性** - `0d7f75b` (fix)

## Files Created/Modified
- `scripts/backup/lib/restore.sh` - 添加 restore_database() 和 verify_backup_integrity() 的宿主机/容器环境检测和 docker exec 封装
- `scripts/backup/tests/test_restore_quick.sh` - 修复 heredoc 传递 SQL 缺少 -i 标志的 bug

## Decisions Made
- 采用与 verify.sh 一致的 `/.dockerenv` 检测模式，两个函数都使用 `local is_host=false` + `if [[ ! -f /.dockerenv ]]; then is_host=true; fi` 判断运行环境
- SQL 文件恢复在宿主机上使用 `docker exec -i` 通过 stdin 管道传入（`< "$backup_file"`），而非 `-f` 参数
- docker exec 命令中不传递 `$pg_params`，容器内使用本地 socket 连接，只需 `-U postgres`

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] 修复 test_restore_quick.sh heredoc 缺少 -i 标志**
- **Found during:** Task 1 (TDD GREEN 阶段)
- **Issue:** `test_restore_quick.sh` 第 35 行 `docker exec noda-infra-postgres-1 psql` 使用 heredoc 传入 SQL 创建表，但缺少 `-i` 标志导致 stdin 未附加到容器，SQL 未被执行，表创建静默失败
- **Fix:** 添加 `-i` 标志：`docker exec -i noda-infra-postgres-1 psql ...`
- **Files modified:** scripts/backup/tests/test_restore_quick.sh
- **Verification:** test_restore_quick.sh 全部 5 项测试通过
- **Committed in:** 0d7f75b (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** 修复了阻止验证通过的预先存在 bug，确保测试能正确执行。

## Issues Encountered
- 测试 4 初始失败原因是双重问题：(1) restore_database() 缺少 docker exec 封装（计划已覆盖）；(2) test_restore_quick.sh 的 heredoc 缺少 -i（预先存在的 bug，通过 Rule 1 自动修复）

## User Setup Required
None - 无需外部服务配置。

## Next Phase Readiness
- restore.sh 宿主机兼容性已修复，test_restore_quick.sh 全部 5 项测试通过
- 准备执行 08-02-PLAN（创建 verify-restore.sh + 08-VERIFICATION.md + 端到端集成测试）

## Self-Check: PASSED

- scripts/backup/lib/restore.sh: FOUND
- scripts/backup/tests/test_restore_quick.sh: FOUND
- 08-01-SUMMARY.md: FOUND
- Commit 0d7f75b: FOUND
- is_host=false count: 2 (>= 2)
- docker exec psql count: 3 (>= 1)
- docker exec pg_restore count: 2 (>= 1)
- docker exec -i psql count: 1 (>= 1)
- docker exec total count: 5 (>= 5)

---
*Phase: 08-execute-restore-scripts*
*Completed: 2026-04-06*
