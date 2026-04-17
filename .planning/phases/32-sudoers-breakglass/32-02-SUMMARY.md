---
phase: 32-sudoers-breakglass
plan: 02
subsystem: infra
tags: [break-glass, jenkins, emergency-deploy, audit-log, pam, sudoers]

requires:
  - phase: 31-docker-socket
    provides: 部署脚本权限锁定（750 root:jenkins），jenkins 用户 Docker socket 属组访问
  - phase: 32-sudoers-breakglass/01
    provides: install-sudoers-whitelist.sh 子命令模式（install/verify/uninstall）

provides:
  - break-glass.sh: 紧急部署入口脚本（deploy/status/log 子命令）
  - Jenkins HTTP 健康检查防滥用机制（localhost:8888/login）
  - PAM 密码身份验证（sudo -v）
  - 审计日志记录到 /var/log/noda/break-glass.log

affects: [33-audit-log, 34-setup-docker-permissions]

tech-stack:
  added: []
  patterns: [curl HTTP health check for service liveness, sudo -v PAM re-authentication, tee -a append-only audit log, script whitelist with basename resolution]

key-files:
  created:
    - scripts/break-glass.sh

key-decisions:
  - "Jenkins 可用性判断使用 HTTP 检查 localhost:8888/login，200/302/403 均视为可用（进程在响应）"
  - "sudo -v 触发 PAM 密码验证作为 Break-Glass 身份验证，复用系统认证不创建独立密码"
  - "审计日志写入 /var/log/noda/break-glass.log，640 root:jenkins 权限"
  - "部署脚本白名单支持简写名（basename）和完整路径两种匹配方式"

patterns-established:
  - "Break-Glass 模式：Jenkins 健康检查拒绝 + PAM 认证 + 审计日志 + 脚本白名单"
  - "部署执行身份：sudo -u jenkins（Phase 31 权限锁定模型）"

requirements-completed: [BREAK-03, BREAK-04]

duration: 2min
completed: 2026-04-18
---

# Phase 32 Plan 02: Break-Glass 紧急部署脚本 Summary

**Break-Glass 紧急部署入口：Jenkins HTTP 健康检查防滥用 + PAM 密码验证 + 脚本白名单 + 审计日志，仅在 Jenkins 不可用时允许管理员执行 deploy-apps-prod.sh 或 deploy-infrastructure-prod.sh**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-17T23:42:27Z
- **Completed:** 2026-04-17T23:44:05Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- break-glass.sh 支持 deploy/status/log 三个子命令，完整覆盖 BREAK-03（身份验证+审计日志）和 BREAK-04（Jenkins 可用时拒绝）
- Jenkins HTTP 健康检查直连 localhost:8888/login，200/302/403 均视为 Jenkins 可用，超时 10 秒避免误判（T-32-05, T-32-07）
- 脚本白名单严格限制为 deploy-apps-prod.sh 和 deploy-infrastructure-prod.sh，支持简写名匹配（T-32-08）
- 所有操作（DENIED/START/SUCCESS/FAILED）记录到 /var/log/noda/break-glass.log（T-32-06）

## Task Commits

1. **Task 1: break-glass.sh 紧急部署入口脚本** - `96af091` (feat)

## Files Created/Modified

- `scripts/break-glass.sh` - Break-Glass 紧急部署入口脚本（324 行，755 权限）

## Decisions Made

- Jenkins 可用性判断使用 HTTP 状态码检查，200/302/403 都视为 Jenkins 在响应（302 是重定向到登录页，403 是需要认证）
- PAM 认证复用 sudo -v，零额外配置，利用现有系统安全基础设施
- 审计日志文件权限 640 root:jenkins，确保 jenkins 用户可读（Phase 33 审计系统集成）
- 部署脚本通过 sudo -u jenkins 执行，符合 Phase 31 权限锁定模型

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - 脚本需要到生产服务器运行 `bash scripts/break-glass.sh status` 查看状态。紧急部署时运行 `bash scripts/break-glass.sh deploy deploy-apps-prod.sh`。

## Next Phase Readiness

- Break-Glass 紧急部署机制就绪，Phase 32 全部完成
- Phase 33 审计系统可消费 /var/log/noda/break-glass.log
- Phase 34 setup-docker-permissions.sh 可整合 Break-Glass 和 sudoers 白名单安装

## Self-Check: PASSED

- FOUND: scripts/break-glass.sh
- FOUND: .planning/phases/32-sudoers-breakglass/32-02-SUMMARY.md
- FOUND: commit 96af091

---
*Phase: 32-sudoers-breakglass*
*Completed: 2026-04-18*
