---
phase: 31-docker-socket
plan: 03
subsystem: scripts
tags: [cross-platform, macos, linux, permissions, jenkins]
dependency_graph:
  requires: [31-01, 31-02]
  provides: [cross-platform-permissions-scripts]
  affects: [scripts/apply-file-permissions.sh, scripts/undo-permissions.sh, scripts/setup-jenkins.sh]
tech_stack:
  added: [detect_platform() pattern, macOS Homebrew integration]
  patterns: [platform-conditional-branches, whoami:staff for macOS]
key_files:
  created: []
  modified:
    - scripts/apply-file-permissions.sh
    - scripts/undo-permissions.sh
    - scripts/setup-jenkins.sh
decisions:
  - macOS install/uninstall 明确拒绝，提示使用 Homebrew（不做半吊子适配）
  - macOS 文件权限使用 whoami:staff 替代 root:jenkins（无独立 jenkins 用户隔离）
  - macOS Jenkins home 路径自动检测（/opt/homebrew/var/jenkins > ~/Library/Application Support/Jenkins > ~/.jenkins）
metrics:
  duration: 7m
  completed: "2026-04-17"
  tasks_total: 3
  tasks_completed: 3
  files_modified: 3
  commits: 3
---

# Phase 31 Plan 03: macOS 跨平台适配 Summary

三个 Phase 31 权限脚本（apply-file-permissions.sh、undo-permissions.sh、setup-jenkins.sh）添加 macOS/Linux 双平台支持。macOS 上 Linux-only 操作（systemd、jenkins 用户/组）优雅跳过并输出 warning，Linux 上行为完全不变。

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | detect_platform() + apply-file-permissions.sh 跨平台 | 6f8d193 | scripts/apply-file-permissions.sh |
| 2 | undo-permissions.sh 跨平台 | 63f3a7b | scripts/undo-permissions.sh |
| 3 | setup-jenkins.sh 跨平台 | b645b52 | scripts/setup-jenkins.sh |

## Verification Results

- shellcheck -S error: 三个脚本全部通过（0 error）
- apply-file-permissions.sh verify: macOS 上运行不 crash，N/A 项正确输出
- undo-permissions.sh backup: macOS 上需要 sudo 创建目录（正常行为），语法正确
- setup-jenkins.sh status: macOS 上 exit 0，正确检测平台并输出环境信息
- 三个脚本均包含 detect_platform 函数
- Linux 路径全部保留：root:jenkins、root:docker、systemctl、gpasswd

## Key Changes

### apply-file-permissions.sh
- 添加 `detect_platform()` 函数和 `PLATFORM` 全局变量
- cmd_apply: macOS 跳过 systemd override（步骤 3）、gpasswd（步骤 6），使用 whoami:staff 权限
- cmd_verify: macOS 对 socket 属组/权限、systemd override 标记 N/A，检查当前用户 Docker 可用性
- cmd_hook: 生成的 hook 脚本包含跨平台 OWNER_GROUP 逻辑

### undo-permissions.sh
- 添加 `detect_platform()` 函数和 `PLATFORM` 全局变量
- backup_current_state: macOS 对 systemd/jenkins 信息标记 N/A
- undo_permissions: macOS 跳过 socket 属组恢复、systemd override 移除、Docker 重启、jenkins 组操作
- 步骤 4（chmod 755）通用执行，macOS 使用 whoami:staff
- 步骤 6（重启 Jenkins）macOS 使用 brew services restart

### setup-jenkins.sh
- 添加 `detect_platform()` 函数和 `PLATFORM` 全局变量
- 添加 `macos_jenkins_home()` 路径自动检测
- cmd_install: macOS 明确拒绝，提示使用 brew install jenkins
- cmd_uninstall: macOS 明确拒绝，提示使用 brew uninstall jenkins
- cmd_status: macOS 使用 brew list/services 检查，检查 Docker Desktop 可用性
- cmd_restart: macOS 使用 brew services restart jenkins
- cmd_upgrade: macOS 使用 brew upgrade jenkins
- cmd_show_password: macOS 使用 jenkins_home() 路径检测
- cmd_reset_password: macOS 以当前用户执行 java（非 sudo -u jenkins）

## Decisions Made

1. **macOS install/uninstall 拒绝策略**: 不做半吊子适配（apt/systemd/useradd 在 macOS 无意义），明确拒绝并提示 Homebrew 命令
2. **macOS 文件权限模型**: 使用 whoami:staff 替代 root:jenkins，macOS Docker Desktop 安全模型不通过 socket group 控制访问
3. **Jenkins home 路径检测**: 按优先级检测 /opt/homebrew/var/jenkins > ~/Library/Application Support/Jenkins > ~/.jenkins

## Deviations from Plan

None - plan executed exactly as written.

## Threat Flags

| Flag | File | Description |
|------|------|-------------|
| threat_flag: elevation | scripts/apply-file-permissions.sh | macOS 分支使用 whoami:staff 权限模型弱于 Linux root:jenkins 隔离（已接受 T-31-03-01） |

## Self-Check: PASSED

- All 3 modified script files exist on disk
- 31-03-SUMMARY.md exists
- All 3 task commits found in git log (6f8d193, 63f3a7b, b645b52)
