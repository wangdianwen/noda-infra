---
phase: 19-jenkins
plan: 01
subsystem: infra
tags: [jenkins, ci-cd, systemd, docker, bash]

# Dependency graph
requires:
  - phase: v1.1
    provides: "宿主机 Docker 环境、log.sh 日志库、现有脚本模式"
provides:
  - "setup-jenkins.sh — Jenkins 完整生命周期管理脚本（7 个子命令）"
  - "install 子命令 — Java 21 + Jenkins LTS + 端口 8888 + Docker 权限 + init.groovy.d 自动化配置"
  - "uninstall 子命令 — 完全卸载（apt purge + 数据目录 + APT 源 + jenkins 用户）"
  - "status/show-password/restart/upgrade/reset-password 子命令"
affects: [19-jenkins后续计划, Pipeline配置]

# Tech tracking
tech-stack:
  added: [jenkins-lts-2.541.3, openjdk-21-jre, jenkins-cli.jar]
  patterns: [systemd-override-port-config, init-groovy-d-auto-config, jenkins-cli-password-reset]

key-files:
  created:
    - scripts/setup-jenkins.sh
  modified: []

key-decisions:
  - "使用 $JENKINS_HOME 变量而非硬编码路径，提高脚本可维护性"
  - "reset-password 使用 jenkins-cli.jar + groovy 脚本，检查 4 个可能路径"
  - "init.groovy.d 脚本在 install 完成后立即清理，避免重复执行"

patterns-established:
  - "setup-jenkins.sh 子命令分发模式: case 分发到 cmd_* 函数"
  - "wait_for_jenkins HTTP 轮询模式: curl + sleep 5 + 120s 超时"

requirements-completed: [JENK-01, JENK-02, JENK-03, JENK-04]

# Metrics
duration: 6min
completed: 2026-04-14
---

# Phase 19 Plan 01: setup-jenkins.sh Jenkins 生命周期管理脚本 Summary

**setup-jenkins.sh 实现完整 Jenkins LTS 宿主机生命周期管理（install/uninstall/status 等 7 个子命令），使用 systemd override 配置端口 8888，init.groovy.d 首次自动化配置，jenkins-cli.jar 密码重置**

## Performance

- **Duration:** 6 min
- **Started:** 2026-04-14T11:10:51Z
- **Completed:** 2026-04-14T11:16:31Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- 创建完整的 setup-jenkins.sh 脚本，包含 7 个子命令：install、uninstall、status、show-password、restart、upgrade、reset-password
- install 子命令实现 Java 21 安装 + Jenkins LTS 安装 + systemd override 端口 8888 + Docker 权限 + init.groovy.d 自动化配置 + 管理员凭据写入
- reset-password 子命令实现 jenkins-cli.jar 多路径查找 + groovy 脚本密码重置 + 临时文件清理

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建 setup-jenkins.sh 脚本框架 + install + uninstall + status 子命令** - `246416a` (feat)
2. **Task 2: 实现 show-password + restart + upgrade + reset-password 子命令** - `8e910ea` (feat)

## Files Created/Modified
- `scripts/setup-jenkins.sh` - Jenkins 完整生命周期管理脚本（7 个子命令，521 行）

## Decisions Made
- 使用 `$JENKINS_HOME` 变量而非硬编码 `/var/lib/jenkins`，与项目其他脚本保持一致的变量模式
- reset-password 检查 4 个可能的 jenkins-cli.jar 路径，提高兼容性
- init.groovy.d 脚本在 install 完成后立即清理（`sudo rm -rf "$JENKINS_HOME/init.groovy.d"`），避免每次重启时重复执行
- 管理员凭据文件权限设为 600（仅 jenkins 用户可读），符合威胁模型 T-19-04 缓解要求

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- reset-password 函数中有一处多余引号（`"$new_password""`），导致 bash 语法错误，立即发现并修正

## User Setup Required

None - 脚本需要在生产服务器上执行验证（apt/systemd 命令在 macOS 上不可用）。

## Next Phase Readiness
- setup-jenkins.sh 已就绪，可在生产服务器上执行 install 验证
- init.groovy.d 目录结构已预留（scripts/jenkins/init.groovy.d/），后续计划可添加 groovy 脚本
- jenkins/config/ 目录结构已预留，后续计划可添加 jenkins-admin.env.example 模板
- 后续计划需要创建实际的 groovy 初始化脚本（01-security.groovy、02-plugins.groovy、03-pipeline-job.groovy）

## Self-Check: PASSED

- FOUND: scripts/setup-jenkins.sh
- FOUND: .planning/phases/19-jenkins/19-01-SUMMARY.md
- FOUND: 246416a (Task 1 commit)
- FOUND: 8e910ea (Task 2 commit)

---
*Phase: 19-jenkins*
*Completed: 2026-04-14*
