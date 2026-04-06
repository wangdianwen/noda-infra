---
phase: 08-execute-restore-scripts
plan: 02
subsystem: database
tags: [postgresql, docker, restore, verification, bash, rclone, b2]

# Dependency graph
requires:
  - phase: 08-execute-restore-scripts
    provides: restore.sh 宿主机兼容的恢复函数（08-01 修复）
provides:
  - verify-restore.sh 自动化验证脚本（9 项测试，对照 4 个成功标准）
  - 08-VERIFICATION.md 验证文档（4 个部分）
  - restore.sh 宿主机 .dump 文件恢复修复（docker cp + stderr 日志修复）
affects: [09-verify-existing-features, restore-scripts]

# Tech tracking
tech-stack:
  added: []
  patterns: [docker-cp-for-restore, stderr-logging-in-return-functions, find-after-rclone-copy]

key-files:
  created:
    - scripts/backup/verify-restore.sh
    - .planning/phases/08-execute-restore-scripts/08-VERIFICATION.md
  modified:
    - scripts/backup/lib/restore.sh

key-decisions:
  - "verify-restore.sh 使用 TESTS_TOTAL=$((TESTS_TOTAL + 1)) 替代 ((TESTS_TOTAL++)) 避免 set -e 下退出"
  - "download_backup() 日志输出重定向到 stderr，stdout 仅返回文件路径"
  - ".dump 文件恢复使用 docker cp 将文件复制到容器内，SQL 文件使用 stdin 管道"
  - "download_backup() 使用 find 查找 rclone copy 保留目录结构后的文件"

patterns-established:
  - "函数返回值模式: stdout 返回值 + stderr 日志输出，避免命令替换中的日志污染"
  - "docker cp 模式: 宿主机 .dump 文件先 docker cp 到容器 /tmp/，操作后清理"
  - "bash 计数器: 使用 VAR=$((VAR + 1)) 替代 ((VAR++)) 避免零值时 set -e 退出"

requirements-completed: [RESTORE-01, RESTORE-02, RESTORE-03, RESTORE-04]

# Metrics
duration: 22min
completed: 2026-04-06
---

# Phase 8 Plan 02: 创建验证脚本和验证文档 Summary

**verify-restore.sh 对照 4 个成功标准 9 项测试全部通过，修复 restore.sh 的 .dump 文件 docker cp 宿主机兼容性和 download_backup() stdout 日志污染问题**

## Performance

- **Duration:** 22 min
- **Started:** 2026-04-06T09:15:56Z
- **Completed:** 2026-04-06T09:38:15Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- verify-restore.sh 创建完成，9 项测试全部通过（4 个成功标准 + 3 个边界情况 + 2 个子测试）
- 08-VERIFICATION.md 创建完成，包含成功标准验证、测试用例覆盖、边界情况和错误处理、使用指南 4 个部分
- 修复 restore_database() .dump 文件在宿主机上的恢复：使用 docker cp 将文件复制到容器内
- 修复 verify_backup_integrity() .dump 文件验证：使用 docker cp + 容器内路径
- 修复 download_backup() stdout 日志污染：日志重定向到 stderr，stdout 仅返回路径
- 修复 download_backup() rclone 目录结构：使用 find 查找子目录中的下载文件
- 端到端集成测试通过（B2 下载 -> 恢复到临时数据库 -> 验证表数量 -> 清理）

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建 verify-restore.sh + 修复 restore.sh** - `5128753` (feat)
2. **Task 2: 创建 08-VERIFICATION.md** - `e7a2ea4` (docs)

## Files Created/Modified
- `scripts/backup/verify-restore.sh` - 自动化验证脚本，对照 4 个成功标准逐项测试（9 项测试）
- `scripts/backup/lib/restore.sh` - 修复 download_backup() stdout 污染、.dump 文件 docker cp 恢复、rclone 目录结构查找
- `.planning/phases/08-execute-restore-scripts/08-VERIFICATION.md` - 验证文档（4 个部分）

## Decisions Made
- 使用 `TESTS_TOTAL=$((TESTS_TOTAL + 1))` 替代 `((TESTS_TOTAL++))`，因为后者在变量为 0 时返回非零退出码，导致 `set -e` 下脚本终止
- download_backup() 中所有 log_info/log_success 调用重定向到 stderr (`>&2`)，因为此函数通过 stdout 返回文件路径，日志输出会污染返回值
- .dump 文件（pg_restore 自定义格式）不支持 stdin 管道输入，必须使用 docker cp 复制到容器内后通过容器内路径访问
- rclone copy 保留远程目录结构，下载后的文件可能在 `$local_dir/YYYY/MM/DD/` 子目录中，使用 find 查找实际路径

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] 修复 restore_database() .dump 文件宿主机恢复路径问题**
- **Found during:** Task 1 (TDD 执行阶段)
- **Issue:** restore_database() 在宿主机上对 .dump 文件使用 `docker exec pg_restore "$backup_file"`，但 $backup_file 是宿主机路径，容器内无法访问
- **Fix:** 添加 docker cp 将文件复制到容器内 /tmp/ 目录，使用容器内路径执行 pg_restore，操作后清理容器内临时文件
- **Files modified:** scripts/backup/lib/restore.sh
- **Verification:** .dump 文件从 B2 下载后成功恢复到临时数据库（88 个表）
- **Committed in:** 5128753 (Task 1 commit)

**2. [Rule 1 - Bug] 修复 download_backup() stdout 日志污染返回值**
- **Found during:** Task 1 (TDD 执行阶段)
- **Issue:** download_backup() 的 log_info/log_success 输出到 stdout，被命令替换 $(download_backup) 捕获后混入返回的文件路径，导致 restore_database() 收到无效路径
- **Fix:** 将 download_backup() 中所有 log_info/log_success/rclone --progress 重定向到 stderr (>&2)，确保 stdout 仅输出最终文件路径
- **Files modified:** scripts/backup/lib/restore.sh
- **Verification:** restore-postgres.sh --restore 成功下载并恢复 keycloak 备份到临时数据库
- **Committed in:** 5128753 (Task 1 commit)

**3. [Rule 1 - Bug] 修复 download_backup() rclone 目录结构文件查找**
- **Found during:** Task 1 (TDD 执行阶段)
- **Issue:** rclone copy 保留远程目录结构（YYYY/MM/DD/），下载后文件在子目录中，但原代码检查 $local_dir/$backup_filename 路径不存在
- **Fix:** 使用 find 递归查找下载后的文件实际路径
- **Files modified:** scripts/backup/lib/restore.sh
- **Verification:** keycloak_20260406_081638.dump 从 B2 成功下载（路径: $tmpdir/2026/04/06/）
- **Committed in:** 5128753 (Task 1 commit)

**4. [Rule 1 - Bug] 修复 verify_backup_integrity() .dump 文件宿主机验证路径**
- **Found during:** Task 1 (TDD 执行阶段)
- **Issue:** verify_backup_integrity() 在宿主机上对 .dump 文件使用 `docker exec pg_restore -l "$backup_file"`，但 $backup_file 是宿主机路径
- **Fix:** 添加 docker cp 将文件复制到容器内，使用容器内路径验证，验证后清理
- **Files modified:** scripts/backup/lib/restore.sh
- **Verification:** 本地 .dump 文件验证通过（2877 bytes）
- **Comitted in:** 5128753 (Task 1 commit)

**5. [Rule 1 - Bug] 修复 ((TESTS_TOTAL++)) 在 set -e 下的退出问题**
- **Found during:** Task 1 (TDD 执行阶段)
- **Issue:** bash 中 `((var++))` 在 var 为 0 时表达式求值为 0（false），返回退出码 1，在 set -e 模式下导致脚本终止
- **Fix:** 使用 `TESTS_TOTAL=$((TESTS_TOTAL + 1))` 替代 `((TESTS_TOTAL++))`
- **Files modified:** scripts/backup/verify-restore.sh
- **Verification:** verify-restore.sh 完整运行不中断
- **Committed in:** 5128753 (Task 1 commit)

---

**Total deviations:** 5 auto-fixed (5 bugs)
**Impact on plan:** 所有修复都是 restore.sh 在宿主机环境下的兼容性问题，确保端到端测试（B2 下载 -> 恢复 -> 验证）完整通过。无范围蔓延。

## Issues Encountered
- restore.sh 中 .dump 文件恢复和验证在宿主机上需要 docker cp 中转，因为 pg_restore 在容器内运行但文件在宿主机上
- download_backup() 的日志输出与返回值共用 stdout 导致命令替换污染
- rclone copy 保留远程目录结构导致下载后文件路径与预期不符

## User Setup Required
None - 无需外部服务配置。

## Next Phase Readiness
- verify-restore.sh 全部 9 项测试通过，4 个成功标准全覆盖
- 08-VERIFICATION.md 文档包含 4 个必需部分
- 端到端集成测试（备份 -> 云上传 -> 下载 -> 恢复 -> 验证）通过
- 准备执行 Phase 09（验证已实现功能）

---
*Phase: 08-execute-restore-scripts*
*Completed: 2026-04-06*
