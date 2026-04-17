---
phase: 31-docker-socket
plan: 02
subsystem: infra
tags: [docker, permissions, systemd, git-hooks, shellcheck, security]

# Dependency graph
requires:
  - phase: 31-docker-socket/01
    provides: "undo-permissions.sh 最小回滚脚本"
provides:
  - "apply-file-permissions.sh 一站式权限应用脚本（apply/verify/hook 子命令）"
  - "Docker socket 属组收敛：systemd override 创建"
  - "文件权限锁定：4 个部署脚本 750 root:jenkins"
  - "Git post-merge hook：git pull 后自动恢复权限"
affects: [32-break-glass, 34-permission-management]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "stat_perms/stat_group/stat_mode 函数封装 macOS/Linux 兼容"
    - "LOCKED_SCRIPTS 数组集中管理锁定目标"

key-files:
  created:
    - scripts/apply-file-permissions.sh
  modified: []

key-decisions:
  - "使用 uname 检测实现 macOS/Linux stat 命令兼容"
  - "systemctl 调用使用 2>/dev/null 保护，macOS 上静默跳过"
  - "post-merge hook 中使用 chown || sudo chown || true 三层降级策略"

patterns-established:
  - "stat 兼容封装：Darwin 用 -f '%Lp:%Su:%Sg'，Linux 用 -c '%a:%U:%G'"
  - "systemd override 写入模式：sudo tee > /dev/null + daemon-reload"
  - "LOCKED_SCRIPTS 数组：集中定义锁定目标，apply/verify/hook 共享"

requirements-completed: [PERM-03, PERM-04, JENKINS-02]

# Metrics
duration: 1min
completed: 2026-04-18
---

# Phase 31 Plan 02: 权限应用脚本 Summary

**一站式权限应用脚本：文件锁定 + systemd override + post-merge hook + 验证，macOS/Linux 双平台兼容**

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-17T21:14:50Z
- **Completed:** 2026-04-17T21:16:33Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- 创建 apply-file-permissions.sh 一站式权限应用脚本（320 行）
- 实现 apply 子命令：/opt/noda 目录创建 + 4 脚本锁定 + systemd override + docker 组清理 + Jenkins 重启 + hook 创建
- 实现 verify 子命令：socket 属组/权限 + systemd override + 脚本权限 + hook 存在性 + jenkins docker 访问 + /opt/noda 权限
- 实现 hook 子命令：创建幂等 post-merge hook（chown || sudo chown || true 三层降级）
- macOS/Linux stat 和 systemctl 完全兼容

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建 apply-file-permissions.sh 权限应用脚本** - `6bcf065` (feat)

## Files Created/Modified
- `scripts/apply-file-permissions.sh` - 一站式权限应用脚本，包含 apply/verify/hook/help 四个子命令

## Decisions Made
- 使用 `uname` 检测封装 stat 命令差异（Darwin: `-f '%Lp:%Su:%Sg'`, Linux: `-c '%a:%U:%G'`）
- systemctl 调用全部使用 `2>/dev/null` 保护，macOS 上静默跳过不报错
- post-merge hook 使用 `chown || sudo chown || true` 三层降级，确保 root 和非 root 用户都能执行

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - 脚本已创建，需要在生产服务器手动执行：
1. `sudo bash scripts/apply-file-permissions.sh apply`
2. `sudo bash scripts/apply-file-permissions.sh verify`

## Next Phase Readiness
- apply-file-permissions.sh 已就绪，配合 31-01 的 undo-permissions.sh 提供完整的安全网
- 生产服务器执行 apply 后即可完成 Docker socket 权限收敛 + 文件权限锁定
- Phase 32 可基于此脚本构建 Break-Glass 机制

## Self-Check: PASSED

- FOUND: scripts/apply-file-permissions.sh
- FOUND: .planning/phases/31-docker-socket/31-02-SUMMARY.md
- FOUND: commit 6bcf065

---
*Phase: 31-docker-socket*
*Completed: 2026-04-18*
