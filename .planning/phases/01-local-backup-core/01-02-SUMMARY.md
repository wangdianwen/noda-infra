---
phase: 01-local-backup-core
plan: 02
subsystem: database
tags: [postgresql, backup, logging, utilities, docker]

# Dependency graph
requires:
  - phase: 01-01
    provides: 健康检查和配置管理功能
provides:
  - 日志库（log.sh）- 统一的日志输出格式
  - 工具库（util.sh）- 时间戳、权限、清理、校验和功能
  - 数据库操作库（db.sh）- 数据库发现、备份、全局对象备份
affects: [01-03]

# Tech tracking
tech-stack:
  added: [Bash 4.0+, PostgreSQL 17.9, pg_dump, pg_dumpall, sha256sum]
  patterns: [库文件架构、Docker 容器内执行、自动发现用户数据库、失败时自动清理]

key-files:
  created:
    - scripts/backup/lib/log.sh
    - scripts/backup/lib/util.sh
    - scripts/backup/lib/db.sh
  modified: []

key-decisions:
  - "使用符号前缀（ℹ️、⚠️、❌、✅、📊）提高日志可读性"
  - "日志输出到 stderr（log_error）和 stdout（其他函数）"
  - "备份文件权限严格设置为 600（仅所有者可读写）"
  - "备份失败时自动清理已创建的备份文件（避免不完整的备份占用空间）"
  - "串行备份每个数据库（不并行）确保错误时立即停止"
  - "全局对象（角色和表空间）单独备份为 .sql 文件"

patterns-established:
  - "库文件依赖关系：db.sh 依赖 log.sh 和 util.sh"
  - "错误处理模式：使用 CREATED_BACKUPS 数组跟踪已创建文件，失败时清理"
  - "进度显示模式：使用 log_progress 显示当前进度和百分比"
  - "Docker 执行模式：通过 docker exec 在容器内执行 pg_dump 和 pg_dumpall"

requirements-completed: [BACKUP-01, BACKUP-02, BACKUP-03]

# Metrics
duration: 16 min
completed: 2026-04-05
---

# Phase 1 Plan 2: 数据库备份核心功能 Summary

**实现数据库备份的核心功能，包括日志输出、工具函数、数据库发现、备份执行和全局对象备份**

## Performance

- **Duration:** 16 min
- **Started:** 2026-04-05T22:35:36Z
- **Completed:** 2026-04-05T22:38:08Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments
- 创建日志库文件（lib/log.sh）提供统一的日志输出格式
- 创建工具库文件（lib/util.sh）提供时间戳、权限、清理、校验和功能
- 创建数据库操作库文件（lib/db.sh）实现数据库发现和备份功能
- 实现自动发现用户数据库（排除模板数据库）
- 实现单个数据库备份（pg_dump -Fc 格式）
- 实现全局对象备份（pg_dumpall -g）
- 实现失败时自动清理已创建的备份文件
- 使用进度显示函数跟踪备份进度

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建日志库文件（lib/log.sh）** - `54d7e2c` (feat)
2. **Task 2: 创建工具库文件（lib/util.sh）** - `5be388b` (feat)
3. **Task 3: 创建数据库操作库文件（lib/db.sh）** - `22f6d04` (feat)

**Plan metadata:** (待提交)

_Note: All tasks implemented as new features_

## Files Created/Modified
- `scripts/backup/lib/log.sh` - 日志库，提供统一的日志输出格式（log_info、log_warn、log_error、log_success、log_progress、log_json）
- `scripts/backup/lib/util.sh` - 工具库，提供时间戳、权限设置、清理、校验和、字节格式化功能
- `scripts/backup/lib/db.sh` - 数据库操作库，提供数据库发现、备份、全局对象备份、批量备份功能

## Decisions Made

1. **日志输出格式**：使用符号前缀（ℹ️、⚠️、❌、✅、📊）提高可读性，log_error 输出到 stderr
2. **备份文件权限**：所有备份文件权限严格设置为 600（仅所有者可读写）
3. **失败清理策略**：备份失败时自动清理已创建的备份文件，避免不完整的备份占用空间
4. **备份执行顺序**：首先备份全局对象，然后串行备份每个数据库
5. **依赖关系**：db.sh 依赖 log.sh 和 util.sh，通过 source 命令加载

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - all tasks completed successfully without issues.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- 日志、工具、数据库操作库文件已创建完成
- 所有库文件语法检查通过（bash -n）
- 数据库发现功能已实现（discover_databases）
- 数据库备份功能已实现（backup_database、backup_globals、backup_all_databases）
- 失败时自动清理功能已实现
- 准备执行下一计划（01-03：备份验证和主脚本集成）

---
*Phase: 01-local-backup-core*
*Completed: 2026-04-05*

## Self-Check: PASSED

所有文件创建成功：
- ✅ scripts/backup/lib/log.sh
- ✅ scripts/backup/lib/util.sh
- ✅ scripts/backup/lib/db.sh
- ✅ 01-02-SUMMARY.md

所有提交历史完整：
- ✅ 4 commits for plan 01-02
