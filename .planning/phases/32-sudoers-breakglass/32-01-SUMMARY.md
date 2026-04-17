---
phase: 32-sudoers-breakglass
plan: 01
subsystem: infra
tags: [sudoers, docker, permissions, whitelist, security]

requires:
  - phase: 31-docker-socket
    provides: Docker socket permission convergence pattern (apply/verify/hook subcommand pattern)

provides:
  - install-sudoers-whitelist.sh: sudoers whitelist install/verify/uninstall script
  - verify-sudoers-whitelist.sh: standalone verification script with 12 check items

affects: [32-02, 33-audit-log, 34-setup-docker-permissions]

tech-stack:
  added: []
  patterns: [sudoers Cmnd_Alias whitelist/blacklist, visudo -cf syntax gate, /etc/sudoers.d/ drop-in]

key-files:
  created:
    - scripts/install-sudoers-whitelist.sh
    - scripts/verify-sudoers-whitelist.sh

key-decisions:
  - "sudoers Cmnd_Alias pattern: separate DOCKER_READ_ONLY and DOCKER_WRITE aliases for explicit allow/deny"
  - "NOPASSWD for read-only commands: harmless operations do not require password re-entry"
  - "visudo -cf gate: invalid sudoers is auto-deleted before it can break sudo"

patterns-established:
  - "Cmnd_Alias whitelist pattern: explicit command + wildcard for arguments (e.g. /usr/bin/docker ps, /usr/bin/docker ps *)"
  - "Deny-before-allow rule ordering: %sudo ALL = !DOCKER_WRITE before NOPASSWD: DOCKER_READ_ONLY"

requirements-completed: [BREAK-01, BREAK-02]

duration: 2min
completed: 2026-04-18
---

# Phase 32 Plan 01: sudoers Whitelist Summary

**sudoers 白名单规则脚本：Cmnd_Alias 模式实现 docker 只读命令白名单（ps/logs/inspect/stats/top）和写入命令黑名单，visudo -cf 语法门禁**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-17T23:38:55Z
- **Completed:** 2026-04-17T23:41:10Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- install-sudoers-whitelist.sh 支持 install/verify/uninstall 三个子命令，写入 /etc/sudoers.d/noda-docker-readonly
- sudoers 规则精确覆盖 BREAK-01（5 个只读命令）和 BREAK-02（18 个写入命令），docker exec 在黑名单中（D-04）
- verify-sudoers-whitelist.sh 独立验证 12 个检查项，PASS/FAIL 格式化输出

## Task Commits

1. **Task 1: install-sudoers-whitelist.sh** - `0a5541c` (feat)
2. **Task 2: verify-sudoers-whitelist.sh** - `144c585` (feat)

## Files Created/Modified

- `scripts/install-sudoers-whitelist.sh` - sudoers 白名单安装/验证/卸载脚本（298 行）
- `scripts/verify-sudoers-whitelist.sh` - 独立验证脚本，12 项检查（154 行）

## Decisions Made

- Cmnd_Alias 模式分离白名单和黑名单，拒绝规则优先于允许规则（!DOCKER_WRITE 在 NOPASSWD: DOCKER_READ_ONLY 之前）
- macOS 自动跳过安装和验证，Docker Desktop 无需 sudoers 规则
- visudo -cf 验证失败时立即删除无效文件，防止损坏 sudo 系统

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - 脚本需要到生产服务器执行 `sudo bash scripts/install-sudoers-whitelist.sh install` 进行实际安装。

## Next Phase Readiness

- sudoers 白名单脚本就绪，等待生产服务器执行安装
- Phase 32-02 Break-Glass 脚本可使用 install-sudoers-whitelist.sh 的模式
- Phase 34 setup-docker-permissions.sh 可整合 sudoers 规则安装

## Self-Check: PASSED

All files and commits verified present.

---
*Phase: 32-sudoers-breakglass*
*Completed: 2026-04-18*
