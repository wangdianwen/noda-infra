---
status: complete
phase: 31-docker-socket
source: 31-01-SUMMARY.md, 31-02-SUMMARY.md
started: 2026-04-18T01:45:00Z
updated: 2026-04-18T02:00:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Shellcheck 代码质量检查
expected: 三个脚本（undo-permissions.sh、setup-jenkins.sh、apply-file-permissions.sh）均通过 shellcheck -S error 检查，无 error 级别问题
result: pass

### 2. setup-jenkins.sh 使用 socket 属组方式
expected: setup-jenkins.sh 不包含 `usermod -aG docker jenkins`，包含 `socket-permissions.conf`、`ExecStartPost`、`docker info` 和 `gpasswd -d jenkins docker`
result: pass

### 3. undo-permissions.sh 包含 backup/undo 子命令
expected: undo-permissions.sh 包含 backup_current_state 函数、undo_permissions 函数、BACKUP_FILE 路径
result: pass

### 4. apply-file-permissions.sh 包含完整子命令
expected: apply-file-permissions.sh 包含 cmd_apply、cmd_verify、cmd_hook 函数和 LOCKED_SCRIPTS 数组
result: pass

### 5. 生产服务器：权限应用
expected: 在生产服务器运行 `sudo bash scripts/apply-file-permissions.sh apply` 成功完成，无报错
result: issue
reported: "macOS 上运行报错 chown: jenkins: illegal group name。脚本依赖 systemd + jenkins 用户/组，当前环境为 macOS + Docker Desktop，无 systemd，无 jenkins 用户（Jenkins 以 dianwenwang 身份运行），Docker socket 由 Docker Desktop 管理（root:daemon）"
severity: blocker

### 6. 生产服务器：权限验证
expected: 在生产服务器运行 `sudo bash scripts/apply-file-permissions.sh verify` 输出全部 PASS
result: issue
reported: "verify 子命令同样依赖 systemd override、jenkins 用户组、Linux stat 命令。macOS 上无法通过"
severity: blocker

### 7. 生产服务器：jenkins 用户 Docker 访问
expected: `sudo -u jenkins docker ps` 返回容器列表（非 permission denied）
result: issue
reported: "无 jenkins 用户。Jenkins 以 dianwenwang 身份运行（Homebrew launchd 服务），macOS 上不存在 jenkins 用户/组"
severity: blocker

### 8. 生产服务器：非 jenkins 用户被拒绝
expected: `sudo -u admin docker ps` 返回 permission denied（非 jenkins 组用户无法访问 Docker socket）
result: issue
reported: "Docker Desktop for Mac 管理 socket 访问权限，不通过 Linux socket group 模型。socket 属组为 daemon 非 docker/jenkins"
severity: blocker

### 9. 生产服务器：Docker 重启后权限持久化
expected: `sudo systemctl restart docker && ls -la /var/run/docker.sock` 显示属组仍为 root:jenkins（systemd override 生效）
result: issue
reported: "macOS 无 systemctl。Docker Desktop 通过 VM 管理 Docker daemon，host 无法通过 systemd override 控制 socket 权限"
severity: blocker

### 10. 生产服务器：Jenkins Pipeline 端到端验证
expected: 触发 4 个 Jenkins Pipeline（findclass-ssr、noda-site、keycloak、infra）全部正常运行
result: skipped
reason: "前置条件（权限收敛）无法满足，跳过 Pipeline 验证"

## Summary

total: 10
passed: 4
issues: 6
pending: 0
skipped: 1

## Gaps

- truth: "apply-file-permissions.sh apply 在当前环境可成功执行"
  status: failed
  reason: "脚本依赖 Linux systemd + jenkins 用户/组，当前环境为 macOS + Docker Desktop。chown root:jenkins 失败（无 jenkins 组），systemctl 不存在"
  severity: blocker
  test: 5
  root_cause: "Phase 31 全部脚本假设 Linux 生产服务器（systemd + jenkins 用户），但实际部署环境为 macOS（launchd + dianwenwang 用户 + Docker Desktop VM）"
  artifacts:
    - path: "scripts/apply-file-permissions.sh"
      issue: "硬编码 jenkins 组和 systemctl 命令，macOS 不兼容"
    - path: "scripts/undo-permissions.sh"
      issue: "硬编码 jenkins 组和 systemctl 命令，macOS 不兼容"
    - path: "scripts/setup-jenkins.sh"
      issue: "systemd override 方式仅适用于 Linux"
  missing:
    - "macOS 适配：检测平台，Linux 用 systemd override，macOS 用 launchd 或其他机制"
    - "或者：明确脚本仅用于 Linux 服务器，当前 macOS 环境跳过权限收敛"

- truth: "apply-file-permissions.sh verify 在当前环境输出全部 PASS"
  status: failed
  reason: "verify 子命令检查 systemd override 文件和 jenkins 组，macOS 上均不存在"
  severity: blocker
  test: 6
  root_cause: "同上，verify 逻辑与 apply 共享 Linux 假设"
  artifacts: []
  missing: []

- truth: "jenkins 用户可通过 sudo -u jenkins docker ps 执行 Docker 命令"
  status: failed
  reason: "无 jenkins 用户。Jenkins 以 dianwenwang 身份运行（Homebrew launchd 服务）"
  severity: blocker
  test: 7
  root_cause: "macOS 上 Jenkins 通过 Homebrew 安装，以当前用户身份运行，不创建独立的 jenkins 系统用户"
  artifacts: []
  missing: []

- truth: "非 jenkins 用户无法访问 Docker socket"
  status: failed
  reason: "Docker Desktop for Mac 通过 VM 管理 socket，host 上 socket 属组为 daemon，Docker Desktop 自行控制访问权限"
  severity: blocker
  test: 8
  root_cause: "macOS Docker Desktop 的安全模型与 Linux 不同 — 不通过 socket group 控制访问"
  artifacts: []
  missing: []

- truth: "Docker 服务重启后 socket 属组持久化为 root:jenkins"
  status: failed
  reason: "macOS 无 systemd，无法通过 systemd override 持久化 socket 权限"
  severity: blocker
  test: 9
  root_cause: "systemd override 方式仅适用于 Linux，macOS 需要不同的持久化机制"
  artifacts: []
  missing: []
