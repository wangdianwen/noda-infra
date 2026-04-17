# Stack Research: v1.6 Jenkins Pipeline 强制执行

**Domain:** Docker 权限收敛、部署脚本锁定、操作审计日志
**Researched:** 2026-04-17
**Confidence:** HIGH（基于 Linux 标准安全机制，无第三方依赖）

## 核心结论

**不需要引入任何新的软件包或第三方工具。** 所需的强制执行机制全部基于 Linux 标准权限模型：`docker` 组成员控制、文件属主/权限（chown/chmod）、`sudoers` 白名单、`auditd` 内核审计。这些是 Debian/Ubuntu 自带的标准组件，已有 20+ 年成熟历史。

## Recommended Stack

### 1. Docker 组成员控制（Docker Socket 访问）

| Mechanism | Component | Purpose | Why | Confidence |
|-----------|-----------|---------|-----|------------|
| `gpasswd -d` | `gpasswd` (shadow 包, 系统自带) | 从 docker 组移除非 jenkins 用户 | Docker socket (`/var/run/docker.sock`) 权限模型为 `root:docker 660`，只有 root 和 docker 组成员能执行 docker 命令 | HIGH |
| `usermod -aG docker jenkins` | `usermod` (passwd 包, 系统自带) | 保持 jenkins 用户在 docker 组 | Jenkins Pipeline 通过 `sh` 步骤调用 docker compose，需要 socket 访问权限 | HIGH |

**原理：** Docker daemon socket 是所有 docker 命令的入口。Linux 文件权限控制谁可以连接这个 socket。当前状态是 jenkins 用户已在 docker 组中（setup-jenkins.sh 第 160 行）。只需移除其他用户的 docker 组成员即可实现权限收敛。

**具体操作：**

```bash
# 1. 审计当前 docker 组成员
getent group docker
# 输出示例: docker:x:998:jenkins,wangdianwen

# 2. 移除非 jenkins 用户（保留 root，root 始终有权限）
sudo gpasswd -d wangdianwen docker

# 3. 验证
getent group docker
# 预期: docker:x:998:jenkins

# 4. 被移除的用户需要重新登录才会生效
# 或者: newgrp - (重置组会话)
```

**紧急恢复（如果 Jenkins 完全不可用）：**

```bash
# root 用户始终可以执行 docker 命令（不受 docker 组限制）
sudo docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml ps
sudo docker compose -f docker/docker-compose.app.yml build findclass-ssr

# 或者临时将自己加回 docker 组
sudo usermod -aG docker $USER
# 重新登录后生效
```

### 2. 部署脚本权限锁定

| Mechanism | Component | Purpose | Why | Confidence |
|-----------|-----------|---------|-----|------------|
| `chown root:jenkins` | `chown` (coreutils, 系统自带) | 脚本属主为 root，属组为 jenkins | root 属主防止 jenkins 用户篡改脚本内容 | HIGH |
| `chmod 750` | `chmod` (coreutils, 系统自带) | 仅 root 和 jenkins 组可执行 | 其他人（other）无读/写/执行权限 | HIGH |
| `chattr +i` | `chattr` (e2fsprogs, 系统自带) | 关键脚本设为不可变 | 防止任何人（包括 root 意外操作）修改脚本，解除需要 `chattr -i` | HIGH |

**需要锁定的文件清单：**

| 文件 | 属主 | 属组 | 权限 | 不可变 |
|------|------|------|------|--------|
| `scripts/deploy/deploy-infrastructure-prod.sh` | root | jenkins | 750 | 否 |
| `scripts/deploy/deploy-apps-prod.sh` | root | jenkins | 750 | 否 |
| `scripts/blue-green-deploy.sh` | root | jenkins | 750 | 否 |
| `scripts/manage-containers.sh` | root | jenkins | 750 | 否 |
| `scripts/pipeline-stages.sh` | root | jenkins | 750 | 否 |
| `scripts/lib/health.sh` | root | jenkins | 750 | 否 |
| `scripts/lib/log.sh` | root | jenkins | 750 | 否 |
| `config/nginx/snippets/upstream-*.conf` | root | jenkins | 660 | 否 |
| `/opt/noda/active-env*` | root | jenkins | 660 | 否 |

**具体操作：**

```bash
PROJECT_ROOT="/path/to/noda-infra"

# 1. 创建 jenkins 组可访问的脚本锁定
sudo chown root:jenkins "$PROJECT_ROOT/scripts/deploy/deploy-infrastructure-prod.sh"
sudo chown root:jenkins "$PROJECT_ROOT/scripts/deploy/deploy-apps-prod.sh"
sudo chown root:jenkins "$PROJECT_ROOT/scripts/blue-green-deploy.sh"
sudo chown root:jenkins "$PROJECT_ROOT/scripts/manage-containers.sh"
sudo chown root:jenkins "$PROJECT_ROOT/scripts/pipeline-stages.sh"
sudo chown root:jenkins "$PROJECT_ROOT/scripts/lib/health.sh"
sudo chown root:jenkins "$PROJECT_ROOT/scripts/lib/log.sh"

# 2. 设置权限（root 和 jenkins 组可读写执行，其他人无权限）
sudo chmod 750 "$PROJECT_ROOT/scripts/deploy/deploy-infrastructure-prod.sh"
sudo chmod 750 "$PROJECT_ROOT/scripts/deploy/deploy-apps-prod.sh"
sudo chmod 750 "$PROJECT_ROOT/scripts/blue-green-deploy.sh"
sudo chmod 750 "$PROJECT_ROOT/scripts/manage-containers.sh"
sudo chmod 750 "$PROJECT_ROOT/scripts/pipeline-stages.sh"
sudo chmod 750 "$PROJECT_ROOT/scripts/lib/health.sh"
sudo chmod 750 "$PROJECT_ROOT/scripts/lib/log.sh"

# 3. upstream 配置文件（Jenkins 需要读写，nginx 容器挂载读取）
sudo chown root:jenkins "$PROJECT_ROOT/config/nginx/snippets/upstream-findclass.conf"
sudo chown root:jenkins "$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf"
sudo chown root:jenkins "$PROJECT_ROOT/config/nginx/snippets/upstream-noda-site.conf"
sudo chmod 660 "$PROJECT_ROOT/config/nginx/snippets/upstream-"*.conf

# 4. 蓝绿状态文件
sudo mkdir -p /opt/noda
sudo chown root:jenkins /opt/noda
sudo chmod 770 /opt/noda
# active-env 文件（已存在时）
sudo chown root:jenkins /opt/noda/active-env 2>/dev/null || true
sudo chown root:jenkins /opt/noda/active-env-keycloak 2>/dev/null || true
sudo chmod 660 /opt/noda/active-env* 2>/dev/null || true
```

**注意事项：**

1. **git pull 后权限会被重置** — git 只记录 executable bit，不记录 owner/group。每次 `git pull` 后需要重新执行权限设置。解决方案：创建 `scripts/lock-permissions.sh` 脚本，在 Jenkins Pipeline 的 Pre-flight 阶段自动执行。
2. **Jenkins workspace vs 生产路径** — Jenkins Pipeline 在 `$WORKSPACE` 中 checkout 代码并执行。setup-jenkins.sh 中 `usermod -aG docker jenkins` 确保 jenkins 用户有 docker 权限。文件权限锁定主要针对生产服务器上的部署路径。
3. **脚本可读性** — 750 权限下 jenkins 组成员可以读取脚本内容。这是故意的——Jenkins 需要读取脚本才能 source 和执行。

### 3. 操作审计日志（auditd）

| Mechanism | Component | Purpose | Why | Confidence |
|-----------|-----------|---------|-----|------------|
| `auditd` | `auditd` (auditd 包, Debian/Ubuntu 自带) | 内核级审计 Docker 命令执行 | auditd 是 Linux 标准审计框架，记录谁在什么时候执行了什么命令，不可被用户空间程序绕过 | HIGH |
| `auditctl` | `auditd` 子命令 | 添加审计规则 | 监控 docker/docker compose 二进制的执行事件 | HIGH |
| `ausearch`/`aureport` | `auditd` 子命令 | 查询审计日志 | 追溯操作历史 | HIGH |
| `/etc/audit/rules.d/` | 持久化规则目录 | 重启后保留规则 | auditd 包安装时自动创建 | HIGH |

**auditd 安装与配置：**

```bash
# 1. 安装（Ubuntu 22.04/24.04 通常已预装）
sudo apt install -y auditd audispd-plugins

# 2. 验证服务状态
sudo systemctl status auditd
# 预期: active (running)

# 3. 添加 Docker 专属审计规则
sudo tee /etc/audit/rules.d/docker-audit.rules <<'EOF'
# ============================================
# Docker 操作审计规则
# ============================================
# 目的：记录所有 docker 命令的执行（谁、什么时候、什么命令）
# 查询：ausearch -k docker-cmd | aureport -x -k docker-cmd
# ============================================

# 监控 docker 二进制的执行
-w /usr/bin/docker -p x -k docker-cmd

# 监控 docker compose 插件的执行
-w /usr/libexec/docker/cli-plugins/docker-compose -p x -k docker-cmd 2>/dev/null || true
-w /usr/lib/docker/cli-plugins/docker-compose -p x -k docker-cmd 2>/dev/null || true

# 监控 Docker socket 的写入（所有 docker 操作的底层入口）
-w /var/run/docker.sock -p wa -k docker-socket

# 监控关键部署脚本的执行
-w /path/to/noda-infra/scripts/deploy/deploy-infrastructure-prod.sh -p x -k deploy-script
-w /path/to/noda-infra/scripts/deploy/deploy-apps-prod.sh -p x -k deploy-script
-w /path/to/noda-infra/scripts/blue-green-deploy.sh -p x -k deploy-script
-w /path/to/noda-infra/scripts/manage-containers.sh -p x -k deploy-script
EOF

# 注意：上面的路径需要替换为实际的生产路径

# 4. 加载规则（不重启服务的方式）
sudo augenrules --load

# 5. 验证规则已加载
sudo auditctl -l | grep -E "docker-cmd|docker-socket|deploy-script"
```

**auditd 配置优化（`/etc/audit/auditd.conf`）：**

```ini
# 日志文件大小和轮转（生产服务器磁盘有限）
max_log_file = 50
num_logs = 10
max_log_file_action = ROTATE

# 空间管理
space_left = 100
space_left_action = SYSLOG
admin_space_left = 50
admin_space_left_action = SUSPEND

# 刷盘策略（平衡性能和安全）
flush = INCREMENTAL_ASYNC
freq = 50
```

**查询审计日志：**

```bash
# 查看所有 docker 命令执行记录
sudo ausearch -k docker-cmd | aureport -x -i

# 查看特定用户（jenkins, UID 通常 1001）的操作
sudo ausearch -k docker-cmd -ua 1001

# 查看最近 1 小时的 docker 操作
sudo ausearch -k docker-cmd --start $(date -d '1 hour ago' +%H:%M:%S)

# 查看部署脚本执行记录
sudo ausearch -k deploy-script | aureport -x -i

# 查看非 jenkins 用户执行 docker 命令的记录（异常检测）
sudo ausearch -k docker-cmd | grep -v "auid=1001" | grep "auid=" | aureport -x -i
```

**auditd 日志示例输出：**

```
Executable Report
===================================
# date time exe term host auid event
===================================
1. 04/17/2026 14:30:22 /usr/bin/docker pts/0 server 1001 1234
2. 04/17/2026 14:32:15 /usr/bin/docker pts/0 server 1000 1235
```

其中 `auid=1001` 是 jenkins 用户，`auid=1000` 是普通用户。后者表示有人绕过了 Jenkins 直接执行 docker 命令。

### 4. sudoers 白名单（紧急操作通道）

| Mechanism | Component | Purpose | Why | Confidence |
|-----------|-----------|---------|-----|------------|
| `/etc/sudoers.d/` | `visudo` (sudo 包, 系统自带) | 授权特定用户执行受限的紧急操作 | 紧急情况下（Jenkins 完全不可用），root 或授权管理员需要能通过 sudo 执行部署 | HIGH |

**sudoers 配置（`/etc/sudoers.d/noda-deploy`）：**

```bash
# Noda 部署权限控制
# 此文件管理谁可以执行部署相关操作

# jenkins 用户：可以无密码执行 docker 命令（Pipeline 需要）
jenkins ALL=(root) NOPASSWD: /usr/bin/docker *
jenkins ALL=(root) NOPASSWD: /usr/bin/docker

# 管理员（如 wangdianwen）：可以通过 sudo 执行部署脚本（紧急回退）
# 但不能直接执行 docker 命令（必须通过脚本）
admin-user ALL=(root) /path/to/noda-infra/scripts/deploy/deploy-infrastructure-prod.sh
admin-user ALL=(root) /path/to/noda-infra/scripts/deploy/deploy-apps-prod.sh
admin-user ALL=(root) /usr/bin/docker ps
admin-user ALL=(root) /usr/bin/docker logs *
admin-user ALL=(root) /usr/bin/docker compose ps
admin-user ALL=(root) /usr/bin/docker compose logs *
```

**注意：** 上面的 `admin-user` 需要替换为实际的管理员用户名。

**为什么 jenkins 需要 NOPASSWD sudo docker 权限：**

当前 Jenkins Pipeline 中的 `sh` 步骤以 jenkins 用户身份执行。Jenkins 已在 docker 组中，可以直接执行 docker 命令。`sudoers` 中的 docker 权限是额外的安全网——如果未来从 docker 组移除 jenkins，可以通过 sudo 继续工作。

**实际方案中 jenkins 不需要 sudoers 规则。** 它通过 docker 组成员获得权限。sudoers 配置是给管理员用户的紧急通道。

## Supporting Tools

### 5. 权限锁定脚本（新建）

| Tool | Purpose | When to Run |
|------|---------|-------------|
| `scripts/lock-permissions.sh` | 一键设置所有部署相关文件的属主和权限 | git pull 后、手动执行、或 Pipeline Pre-flight 阶段 |

**脚本功能：**

```bash
#!/bin/bash
# scripts/lock-permissions.sh
# 一键锁定部署脚本和配置文件的权限
# 用途：git pull 后执行，确保权限不被重置
# 执行：sudo bash scripts/lock-permissions.sh

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_USER="jenkins"

echo "=== 锁定部署脚本权限 ==="

# 部署脚本
for script in \
  scripts/deploy/deploy-infrastructure-prod.sh \
  scripts/deploy/deploy-apps-prod.sh \
  scripts/blue-green-deploy.sh \
  scripts/manage-containers.sh \
  scripts/pipeline-stages.sh \
  scripts/lib/health.sh \
  scripts/lib/log.sh; do
  chown "root:${DEPLOY_USER}" "${PROJECT_ROOT}/${script}"
  chmod 750 "${PROJECT_ROOT}/${script}"
  echo "  ${script} -> root:${DEPLOY_USER} 750"
done

# Nginx upstream 配置（Jenkins 需要读写）
for conf in "${PROJECT_ROOT}"/config/nginx/snippets/upstream-*.conf; do
  chown "root:${DEPLOY_USER}" "$conf"
  chmod 660 "$conf"
  echo "  $(basename $conf) -> root:${DEPLOY_USER} 660"
done

# 蓝绿状态文件
mkdir -p /opt/noda
chown "root:${DEPLOY_USER}" /opt/noda
chmod 770 /opt/noda
for statefile in /opt/noda/active-env*; do
  [ -f "$statefile" ] || continue
  chown "root:${DEPLOY_USER}" "$statefile"
  chmod 660 "$statefile"
  echo "  $(basename $statefile) -> root:${DEPLOY_USER} 660"
done

echo "=== 权限锁定完成 ==="
```

### 6. 审计检查脚本（新建）

| Tool | Purpose | When to Run |
|------|---------|-------------|
| `scripts/check-audit.sh` | 检查是否有非 jenkins 用户执行了 docker 命令 | 定期 cron 或手动检查 |

**脚本功能：**

```bash
#!/bin/bash
# scripts/check-audit.sh
# 检查是否有非 jenkins 用户直接执行了 docker/deploy 命令
# 用途：安全审计，检测绕过 Jenkins Pipeline 的操作
# 执行：sudo bash scripts/check-audit.sh

JENKINS_UID=$(id -u jenkins 2>/dev/null || echo "1001")
HOURS="${1:-24}"

echo "=== Docker 操作审计报告（最近 ${HOURS} 小时）==="

echo ""
echo "--- 非 Jenkins 用户执行的 docker 命令 ---"
sudo ausearch -k docker-cmd --start $(date -d "${HOURS} hours ago" +%H:%M:%S 2>/dev/null || echo "today") 2>/dev/null | \
  grep -v "auid=${JENKINS_UID}" | \
  grep "auid=" | \
  aureport -x -i 2>/dev/null || echo "  （无异常记录）"

echo ""
echo "--- 部署脚本执行记录 ---"
sudo ausearch -k deploy-script --start $(date -d "${HOURS} hours ago" +%H:%M:%S 2>/dev/null || echo "today") 2>/dev/null | \
  aureport -x -i 2>/dev/null || echo "  （无记录）"

echo ""
echo "--- Docker socket 写入记录 ---"
sudo ausearch -k docker-socket --start $(date -d "${HOURS} hours ago" +%H:%M:%S 2>/dev/null || echo "today") 2>/dev/null | \
  aureport -x -i 2>/dev/null || echo "  （无异常记录）"

echo ""
echo "=== 审计报告结束 ==="
```

## Alternatives Considered

### Docker 权限控制方案

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| docker 组成员控制 | Docker Socket Proxy (Tecnativa) | 引入额外容器组件，单服务器场景下过度复杂；docker 组控制已足够 |
| docker 组成员控制 | Rootless Docker | 需要完全重新配置 Docker 环境，与现有 docker-compose 配置不兼容，改动范围过大 |
| docker 组成员控制 | AppArmor/SELinux 策略 | Debian 默认不启用 SELinux；AppArmor 需要 writing 复杂的 profile，维护成本高；docker 组控制足够简单有效 |
| docker 组成员控制 | `iptables owner` 模块 | docker 命令通过 Unix socket 通信，不是 TCP 连接，iptables owner 模块不适用 |

### 审计日志方案

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| auditd | `journalctl` + syslog | syslog 记录应用日志，不记录命令执行的完整审计链（谁、什么时候、什么参数）；auditd 是内核级审计，不可被用户空间绕过 |
| auditd | Docker daemon `--log-driver` | Docker log driver 记录的是容器 stdout/stderr，不是宿主机上谁执行了 docker 命令 |
| auditd | Falco / Sysdig | 需要安装内核模块，增加系统复杂度和故障面；auditd 是 Linux 内建组件 |
| auditd | `history` 命令 / `.bash_history` | 用户可以删除/修改自己的 history 文件；auditd 日志只有 root 可以访问 |
| auditd | 自定义 shell wrapper 替换 docker 命令 | 用户可以绕过 wrapper 直接调用二进制；auditd 在内核层面拦截，不可绕过 |

### 脚本权限锁定方案

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| chown/chmod | sudoers 命令白名单 | sudoers 限制 sudo 执行的命令，但不阻止直接执行脚本；chmod 750 直接在文件权限层面阻止非授权用户执行 |
| chown/chmod | Linux ACL (`setfacl`) | ACL 更灵活但更复杂；标准 owner/group/other 权限模型已满足需求（只有 jenkins 需要访问） |
| chattr +i | Git hooks 防止修改 | Git hooks 可以被 `--no-verify` 跳过；chattr +i 在文件系统层面锁定，无法绕过 |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Docker Socket Proxy (Tecnativa) | 引入额外容器，增加故障面；单服务器不需要网络层过滤 | docker 组成员控制 |
| Rootless Docker | 与现有 docker-compose 配置不兼容，需要重新配置所有服务 | docker 组成员控制 |
| Falco / Sysdig | 需要安装内核模块，维护成本高，auditd 已满足需求 | auditd |
| Portainer RBAC | 引入完整的容器管理平台，过度工程化 | docker 组 + auditd |
| AppArmor Docker profile | 需要编写和维护复杂的 profile，单服务器场景收益低 | docker 组成员控制 |
| `chmod 666 /var/run/docker.sock` | 允许所有用户访问 Docker socket，安全灾难 | docker 组成员控制 |
| `.bash_history` 审计 | 用户可控，不可靠 | auditd 内核审计 |
| `strace`/`ltrace` 监控 | 性能开销大，不适合生产环境持续运行 | auditd |
| Kubernetes RBAC | 项目是单服务器 Docker Compose 架构，无 K8s | Linux 标准权限 |

## 与现有架构的集成点

| 现有组件 | 集成方式 | 变更范围 | 风险 |
|---------|---------|---------|------|
| `setup-jenkins.sh` | 无变更。已有 `usermod -aG docker jenkins`（第 160 行） | 无 | None |
| `scripts/deploy/*.sh` | chown/chmod 锁定权限，脚本内容不变 | 仅文件权限 | Low |
| `scripts/manage-containers.sh` | chown/chmod 锁定权限，脚本内容不变 | 仅文件权限 | Low |
| `scripts/pipeline-stages.sh` | chown/chmod 锁定权限，脚本内容不变 | 仅文件权限 | Low |
| `config/nginx/snippets/upstream-*.conf` | chown/chmod 锁定，Jenkins 需要读写 | 仅文件权限 | Low |
| `/opt/noda/active-env*` | chown/chmod 锁定，Jenkins 需要读写 | 仅文件权限 | Low |
| `jenkins/Jenkinsfile` | 无变更 | 无 | None |
| `jenkins/Jenkinsfile.infra` | 无变更 | 无 | None |
| Docker daemon 配置 | 无变更（`/etc/docker/daemon.json`） | 无 | None |
| 新增: `scripts/lock-permissions.sh` | git pull 后执行权限恢复 | 新文件 | None |
| 新增: `scripts/check-audit.sh` | 审计报告生成 | 新文件 | None |
| 新增: `/etc/audit/rules.d/docker-audit.rules` | auditd Docker 审计规则 | 新配置文件 | Low |

## Stack Patterns by Variant

**如果服务器有多个管理员用户：**
- 使用 `/etc/sudoers.d/noda-deploy` 限制每个管理员的 docker 操作范围
- 只允许通过 sudo 执行部署脚本，不允许直接 docker 命令
- auditd 记录所有 sudo 操作

**如果只有 root 和 jenkins 两个用户（当前情况）：**
- 只需 docker 组控制（移除 root 以外非 jenkins 用户）
- 文件权限锁定（chown/chmod）
- auditd 审计
- 无需复杂的 sudoers 配置

**如果未来迁移到多服务器架构：**
- 当前方案完全不适用
- 需要引入集中式配置管理（Ansible）和集中式日志（ELK/Grafana Loki）
- auditd 日志转发到中央日志服务器

## Version Compatibility

| Component | Version | Compatible With | Notes |
|-----------|---------|-----------------|-------|
| `auditd` | 1:3.0.x (Ubuntu 24.04) | Linux kernel 5.15+ | Debian/Ubuntu 自带，无需额外安装 |
| `gpasswd` | shadow 4.x | 所有 Linux 发行版 | 系统自带 |
| `chown`/`chmod` | GNU coreutils 9.x | 所有 Linux 发行版 | 系统自带 |
| `chattr` | e2fsprogs 1.47.x | ext4 文件系统 | 服务器默认文件系统 |
| `visudo` | sudo 1.9.x | 所有 Linux 发行版 | 系统自带 |

## Installation

```bash
# ============================================
# v1.6 Pipeline 强制执行 — 一次性安装
# ============================================

# 1. 安装 auditd（如未安装）
sudo apt install -y auditd audispd-plugins
sudo systemctl enable auditd
sudo systemctl start auditd

# 2. Docker 组权限收敛
# 审计当前成员
getent group docker
# 移除非 jenkins 用户（替换 <username>）
# sudo gpasswd -d <username> docker

# 3. 部署脚本权限锁定
# sudo bash scripts/lock-permissions.sh

# 4. 配置 auditd Docker 审计规则
# 编辑 /etc/audit/rules.d/docker-audit.rules（见上方配置）
# sudo augenrules --load

# 5. 验证
sudo auditctl -l | grep docker
getent group docker
ls -la scripts/deploy/deploy-infrastructure-prod.sh
```

## Sources

- [Docker Security - Docker Documentation](https://docs.docker.com/engine/security/) — docker 组等同于 root 权限，socket 权限模型，HIGH confidence
- [Linux auditd Documentation](https://linux.die.net/man/8/auditd) — auditd 配置和规则语法，HIGH confidence
- [auditctl man page](https://linux.die.net/man/8/auditctl) — 审计规则语法 (-w, -p, -k)，HIGH confidence
- [ausearch/aureport man page](https://linux.die.net/man/8/ausearch) — 审计日志查询语法，HIGH confidence
- [Ubuntu auditd Guide](https://ubuntu.com/server/docs/security-the-audit-daemon) — Ubuntu 官方 auditd 配置指南，HIGH confidence
- [CIS Benchmark Linux](https://www.cisecurity.org/cis-benchmarks) — auditd 配置最佳实践，MEDIUM confidence
- [sudoers man page](https://linux.die.net/man/5/sudoers) — sudoers 语法，HIGH confidence
- [Linux File Permissions](https://man7.org/linux/man-pages/man2/chmod.2.html) — chmod 系统调用，HIGH confidence
- 项目代码: `scripts/setup-jenkins.sh` (第 160 行 docker 组配置), `jenkins/Jenkinsfile`, `jenkins/Jenkinsfile.infra`, `scripts/deploy/*.sh`, `scripts/manage-containers.sh`, `scripts/pipeline-stages.sh` — 现有架构分析

---
*Stack research for: Noda v1.6 Jenkins Pipeline 强制执行*
*Researched: 2026-04-17*
