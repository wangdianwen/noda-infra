---
phase: 31-docker-socket
plan: 01
subsystem: docker-permissions
tags: [security, docker-socket, jenkins, rollback]
dependency_graph:
  requires: []
  provides: [undo-permissions.sh, setup-jenkins.sh-socket-group-model]
  affects: [scripts/setup-jenkins.sh, scripts/undo-permissions.sh]
tech_stack:
  added: [systemd ExecStartPost override, socket-group-permission-model]
  patterns: [break-glass-undo-script, cross-platform-stat]
key-files:
  created:
    - scripts/undo-permissions.sh
  modified:
    - scripts/setup-jenkins.sh
decisions:
  - 使用 jenkins 主组（GID）作为 socket 属组，不创建额外专用组
  - macOS/Linux stat 命令通过 uname 条件判断兼容
  - cmd_status 用 docker info 替代 groups 检查，验证实际能力而非组成员
metrics:
  duration: 138s
  completed_date: "2026-04-17"
  tasks_completed: 2
  tasks_total: 2
  files_changed: 2
  lines_added: 258
  lines_removed: 8
---

# Phase 31 Plan 01: Docker Socket 权限收敛安全网 + setup-jenkins.sh 修改 Summary

Docker socket 属组收敛安全网（undo-permissions.sh）与 Jenkins 安装脚本 socket 属组方式改造（替代 docker 组成员模式）

## Tasks Completed

| Task | Name | Commit | Files |
| ---- | ---- | ------ | ----- |
| 1 | 创建 undo-permissions.sh 最小回滚脚本 | 7a58708 | scripts/undo-permissions.sh (new, 226 lines) |
| 2 | 修改 setup-jenkins.sh 为 socket 属组方式 | cc0b0c8 | scripts/setup-jenkins.sh (modified, 545 lines) |

## What Was Done

### Task 1: undo-permissions.sh

创建了 Phase 31 最小 undo 安全网脚本，包含两个核心子命令：

- **backup**: 备份 Docker socket 属组/权限模式、4 个锁定脚本权限、systemd override 内容、jenkins 组信息到 `/opt/noda/pre-phase31-permissions-backup.txt`（权限 600，缓解 T-31-02）
- **undo**: 从备份恢复权限状态 -- socket 恢复为 root:docker、移除 systemd override、恢复脚本权限为 755、jenkins 重新加入 docker 组、重启 Docker 和 Jenkins

技术要点：
- macOS/Linux stat 兼容（通过 `uname` 条件判断，macOS 用 `-f` 格式，Linux 用 `-c` 格式）
- 使用项目统一日志库 `scripts/lib/log.sh`
- D-03 最小范围锁定：仅 4 个脚本路径

### Task 2: setup-jenkins.sh 修改

三个位置的修改：

1. **cmd_install 步骤 8**（核心变更）：将 `usermod -aG docker jenkins` 替换为 systemd override 方式
   - `gpasswd -d jenkins docker`（幂等移除 docker 组成员）
   - 写入 `/etc/systemd/system/docker.service.d/socket-permissions.conf`
   - `ExecStartPost=/bin/sh -c 'chown root:jenkins /var/run/docker.sock && chmod 660 /var/run/docker.sock'`
   - daemon-reload + 条件性 Docker 重启

2. **cmd_status 检查 4/5**：从 `groups jenkins | grep docker` 改为 `sudo -u jenkins docker info`（验证实际能力），并新增 systemd override 文件存在性检查

3. **cmd_uninstall 步骤 11.5**（新增）：删除 Docker socket override 文件 + daemon-reload

## Deviations from Plan

None - plan executed exactly as written.

## Verification Results

| Check | Result |
|-------|--------|
| shellcheck scripts/undo-permissions.sh (error severity) | PASS |
| shellcheck scripts/setup-jenkins.sh (error severity) | PASS |
| grep socket-permissions.conf setup-jenkins.sh | PASS |
| grep ExecStartPost setup-jenkins.sh | PASS |
| grep 'docker info' setup-jenkins.sh | PASS |
| ! grep 'usermod -aG docker jenkins' setup-jenkins.sh | PASS |
| grep 'gpasswd -d jenkins docker' setup-jenkins.sh | PASS |
| grep backup_current_state undo-permissions.sh | PASS |
| grep undo_permissions undo-permissions.sh | PASS |
| grep pre-phase31-permissions-backup undo-permissions.sh | PASS |

## 生产服务器验证步骤（manual-only）

1. `sudo -u jenkins docker ps` -- 确认 jenkins 可执行 docker 命令
2. `sudo -u admin docker ps` -- 确认非 jenkins 用户无法访问 docker
3. `sudo systemctl restart docker && ls -la /var/run/docker.sock` -- 确认属组为 root:jenkins
4. 触发 4 个 Jenkins Pipeline 验证端到端正常

## Self-Check: PASSED

- scripts/undo-permissions.sh: FOUND
- scripts/setup-jenkins.sh: FOUND
- Commit 7a58708 (Task 1): FOUND
- Commit cc0b0c8 (Task 2): FOUND
