# Architecture Research: v1.6 Docker 权限收敛 + Jenkins Pipeline 强制执行

**Domain:** 单服务器 Linux 权限模型，Docker 访问控制，CI/CD 强制执行
**Researched:** 2026-04-17
**Confidence:** HIGH（基于项目代码库完整分析 + Linux/Docker 安全实践）

---

## 一、系统总览

### 1.1 当前权限模型（v1.5 已交付）

```
宿主机 Linux (Debian/Ubuntu)
┌──────────────────────────────────────────────────────────────┐
│                                                               │
│  用户/组:                                                     │
│  ├── root                ← 全权限                            │
│  ├── jenkins:docker      ← jenkins 用户，docker 组成员        │
│  └── admin:docker        ← 管理员用户，docker 组成员          │
│                                                               │
│  Docker Socket:                                               │
│  /var/run/docker.sock  root:docker  660                      │
│                                                               │
│  脚本权限:                                                    │
│  scripts/deploy/*.sh   755  ← 任何用户可执行                 │
│  scripts/*.sh           755  ← 任何用户可执行                │
│  config/nginx/snippets/ 644  ← 任何用户可读                  │
│                                                               │
│  问题:                                                        │
│  1. docker 组任何成员 = 完整 root 等价权限                    │
│  2. 任何 SSH 登录用户可直接 docker compose up/down            │
│  3. 任何用户可直接运行部署脚本                                │
│  4. 无操作审计日志                                            │
└──────────────────────────────────────────────────────────────┘
```

**核心安全问题：** `docker` 组等价于 `root`。任何 `docker` 组成员可以 `docker run -v /:/host` 获取宿主机完全控制权。当前 `admin` 用户（或其他用户）在 `docker` 组中，可以绕过 Jenkins 直接执行部署操作。

### 1.2 目标权限模型（v1.6）

```
宿主机 Linux (Debian/Ubuntu)
┌──────────────────────────────────────────────────────────────┐
│                                                               │
│  用户/组:                                                     │
│  ├── root                ← 全权限（sudoers 保护）            │
│  ├── jenkins:jenkins     ← docker 访问仅限 jenkins           │
│  │   └── Docker Socket 访问: 是（通过白名单机制）            │
│  └── admin:admin         ← 日常管理，无直接 docker 访问      │
│      └── 只读 docker 命令通过 sudo 白名单                    │
│      └── 紧急部署通过 break-glass 机制                       │
│                                                               │
│  Docker Socket:                                               │
│  /var/run/docker.sock  root:jenkins  660  ← 仅 jenkins 可访问│
│                                                               │
│  脚本权限:                                                    │
│  scripts/deploy/*.sh   750 root:jenkins  ← 仅 jenkins 可执行│
│  scripts/pipeline-stages.sh  750 root:jenkins                │
│  config/nginx/snippets/ 640 root:jenkins  ← 仅 jenkins 可写 │
│                                                               │
│  审计:                                                        │
│  auditd → 记录所有 docker 命令执行                            │
│  sudoers → 记录所有 sudo 操作                                 │
│  /var/log/noda-audit/ → 部署操作日志                         │
└──────────────────────────────────────────────────────────────┘
```

### 1.3 变更范围总览

| 变更类型 | 组件 | 影响 |
|----------|------|------|
| **新增** | Docker socket 权限收敛脚本 | 限制 docker.sock 仅 jenkins 可访问 |
| **新增** | sudoers 白名单文件 | admin 用户只读 docker + break-glass |
| **新增** | auditd 规则文件 | 记录所有 docker/sudo 操作 |
| **新增** | 权限收敛执行脚本 (`scripts/setup-docker-permissions.sh`) | 一键应用所有权限变更 |
| **修改** | `setup-jenkins.sh` | 调整 docker 组配置逻辑 |
| **修改** | deploy 脚本文件权限 | 750 root:jenkins |
| **修改** | nginx snippets 目录权限 | 640/750 root:jenkins |
| **修改** | `/opt/noda/` 状态文件权限 | root:jenkins 可写 |

---

## 二、组件边界

### 2.1 新增组件

| 组件 | 职责 | 实现方式 |
|------|------|---------|
| Docker socket 权限规则 | 限制 docker.sock 访问仅限 jenkins 用户 | udev 规则 或 systemd override |
| sudoers 白名单 (`/etc/sudoers.d/noda-docker`) | 定义哪些用户可以执行哪些 docker/sudo 命令 | sudoers 配置文件 |
| auditd Docker 规则 (`/etc/audit/rules.d/noda-docker.rules`) | 审计所有 docker 命令执行 | auditd 规则文件 |
| `scripts/setup-docker-permissions.sh` | 一键应用/验证/回滚所有权限配置 | bash 脚本 |
| break-glass 封条文件 (`/opt/noda/.break-glass-sealed`) | 记录紧急部署封条状态和时间戳 | 空文件 + 时间戳 |

### 2.2 修改组件

| 组件 | 修改内容 | 修改范围 |
|------|---------|---------|
| `scripts/setup-jenkins.sh` | `cmd_install` 中 `usermod -aG docker jenkins` 改为 socket 权限分配 | 小 — 约 5 行 |
| `scripts/deploy/deploy-apps-prod.sh` | 文件权限改为 `750 root:jenkins` | 无代码变更 |
| `scripts/deploy/deploy-infrastructure-prod.sh` | 文件权限改为 `750 root:jenkins` | 无代码变更 |
| `scripts/pipeline-stages.sh` | 文件权限改为 `750 root:jenkins` | 无代码变更 |
| `scripts/manage-containers.sh` | 文件权限改为 `750 root:jenkins` | 无代码变更 |
| `scripts/blue-green-deploy.sh` | 文件权限改为 `750 root:jenkins` | 无代码变更 |
| `config/nginx/snippets/` | 目录权限改为 `750 root:jenkins`，文件权限 `640` | 无代码变更 |
| `/opt/noda/` 状态文件 | 文件权限改为 `660 root:jenkins` | 无代码变更 |

### 2.3 不变组件

| 组件 | 理由 |
|------|------|
| `jenkins/Jenkinsfile` | Pipeline 代码不变，通过 jenkins 用户执行 |
| `jenkins/Jenkinsfile.noda-site` | 同上 |
| `jenkins/Jenkinsfile.infra` | 同上 |
| `scripts/lib/log.sh` | 通用日志库，所有用户可读 |
| `scripts/lib/health.sh` | 通用健康检查库，所有用户可读 |
| `docker/docker-compose.yml` | Compose 配置不变 |
| `docker/docker-compose.prod.yml` | 同上 |

---

## 三、架构决策：Docker 访问控制方案选择

### 3.1 方案对比

| 方案 | 安全性 | 复杂度 | 与 Jenkins 兼容性 | break-glass 难度 |
|------|--------|--------|------------------|-----------------|
| **A. docker.sock 属主改为 jenkins** | HIGH | LOW | 完美 | 中等（sudo） |
| B. Rootless Docker | HIGHEST | HIGH | 需要大量适配 | 复杂 |
| C. sudoers 全量控制 | MEDIUM | MEDIUM | 需要 sudo 前缀 | 简单 |
| D. Docker 授权插件 | HIGH | HIGH | 需要插件配置 | 复杂 |

### 3.2 推荐方案：A. docker.sock 属主改为 jenkins + sudoers 白名单

**核心思路：** 不使用 `docker` 组，而是让 `jenkins` 用户直接拥有 Docker socket 的组访问权。

**为什么不用 Rootless Docker：**
1. 现有 `docker-compose.yml` 已经假设 rootful Docker（端口映射、网络模式等）
2. Rootless Docker 的 `--privileged`、某些网络功能受限
3. 迁移成本高（所有 Compose 文件、所有 docker run 命令都需要测试）
4. 单服务器场景下，Rootless Docker 的安全优势主要体现在容器逃逸后，但本项目的攻击面很小

**为什么不用纯 sudoers 方案：**
1. Jenkins Pipeline 中的 `sh` 步骤执行大量 docker 命令，每个都加 `sudo` 前缀改动面大
2. 环境变量不会通过 sudo 传递（需要 `--preserve-env` 配置）
3. `docker compose` 命令涉及复杂的子进程调用，sudoers 规则难以精确覆盖

**方案 A 的实现：**

```bash
# 1. 从 docker 组移除所有非必要用户
sudo gpasswd -d admin docker 2>/dev/null || true

# 2. jenkins 也不在 docker 组（改为直接 socket 访问）
sudo gpasswd -d jenkins docker 2>/dev/null || true

# 3. 创建专用组 jenkins-docker（可选）或直接修改 socket 属组
# 方案 A1: 直接让 jenkins 拥有 socket
sudo chown root:jenkins /var/run/docker.sock
sudo chmod 660 /var/run/docker.sock

# 方案 A2: 使用 systemd override 确保 Docker 重启后权限不变
# /etc/systemd/system/docker.service.d/override.conf
[Service]
ExecStartPost=/bin/chown root:jenkins /var/run/docker.sock
ExecStartPost=/bin/chmod 660 /var/run/docker.sock
```

**systemd override 是关键** — Docker 重启后会重新创建 socket 文件，恢复默认的 `root:docker 660`。必须在 `ExecStartPost` 中覆盖。

### 3.3 sudoers 白名单设计

**原则：** 非 jenkins 用户不能直接执行 docker 命令，但通过 sudo 可以执行只读命令（用于调试）。紧急部署需要 break-glass 机制。

```bash
# /etc/sudoers.d/noda-docker
# 由 root 管理，权限 440

# ============================================
# 只读 docker 命令 — 所有 admin 组用户可执行
# ============================================
Cmnd_Alias DOCKER_READ = \
    /usr/bin/docker ps, \
    /usr/bin/docker ps *, \
    /usr/bin/docker images, \
    /usr/bin/docker images *, \
    /usr/bin/docker logs, \
    /usr/bin/docker logs *, \
    /usr/bin/docker inspect, \
    /usr/bin/docker inspect *, \
    /usr/bin/docker top *, \
    /usr/bin/docker stats, \
    /usr/bin/docker stats *, \
    /usr/bin/docker compose ps, \
    /usr/bin/docker compose ps *, \
    /usr/bin/docker compose logs, \
    /usr/bin/docker compose logs *, \
    /usr/bin/docker compose config, \
    /usr/bin/docker compose config *

%admin ALL=(root) NOPASSWD: DOCKER_READ

# ============================================
# Break-glass: 紧急部署 — 需要密码，记录审计日志
# ============================================
Cmnd_Alias DOCKER_DEPLOY = \
    /usr/local/bin/noda-emergency-deploy.sh

%admin ALL=(root) PASSWD: DOCKER_DEPLOY

# ============================================
# 部署脚本直接执行 — 禁止
# ============================================
# 无条目 = 默认拒绝
# scripts/deploy/*.sh 通过文件权限（750 root:jenkins）限制

# ============================================
# sudo 审计日志
# ============================================
Defaults log_output
Defaults iolog_dir=/var/log/sudo-io/%{user}/%{tsout}
Defaults!/usr/bin/docker*: iolog_dir=/var/log/sudo-io/docker/%{user}
```

### 3.4 Break-Glass 紧急部署机制

**场景：** Jenkins 不可用（服务宕机、磁盘满、Java 崩溃等），需要紧急手动部署。

**设计：**

```bash
#!/bin/bash
# /usr/local/bin/noda-emergency-deploy.sh
# 紧急部署入口 — 必须通过 sudo 执行
# 触发时记录封条状态、时间戳、操作者

set -euo pipefail

SEAL_FILE="/opt/noda/.break-glass-sealed"
AUDIT_LOG="/var/log/noda-audit/break-glass.log"

# 记录封条打破
log_break_glass() {
  local operator="${SUDO_USER:-$USER}"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  mkdir -p "$(dirname "$AUDIT_LOG")"
  echo "[${timestamp}] BREAK-GLASS operator=${operator} command=$*" >> "$AUDIT_LOG"
  logger -p auth.alert -t noda-break-glass "Emergency deploy by ${operator}: $*"
}

# 验证 Jenkins 确实不可用（防止滥用）
check_jenkins_down() {
  if curl -sf "http://localhost:8888/login" > /dev/null 2>&1; then
    echo "ERROR: Jenkins is responding. Use Jenkins Pipeline instead." >&2
    echo "If you believe this is an error, document the reason and use --force." >&2
    exit 1
  fi
}

case "${1:-}" in
  --force)
    shift
    log_break_glass "$@" "(forced)"
    ;;
  *)
    check_jenkins_down
    log_break_glass "$@"
    ;;
esac

# 将 jenkins 用户加入 docker 组临时（本次会话）
# 注意：这只是让当前 sudo 会话有效，不影响系统长期配置
exec "$@"
```

**封条文件 (`/opt/noda/.break-glass-sealed`)：**
- 存在 = 封条完整（未被打破）
- 删除/修改时间戳 = 封条被打破过
- 部署完成后由脚本重新创建

**Break-glass 工作流：**

```
1. 管理员发现 Jenkins 不可用
2. 管理员执行: sudo noda-emergency-deploy.sh bash scripts/deploy/deploy-apps-prod.sh
3. 脚本验证 Jenkins 确实不可用
4. 脚本记录审计日志 (operator + timestamp + command)
5. 脚本临时恢复 jenkins 用户的 docker 访问（或以 root 执行部署脚本）
6. 部署完成
7. 管理员恢复 Jenkins 并调查根因
8. 管理员检查 /var/log/noda-audit/break-glass.log 确认操作
9. 管理员重新创建封条文件
```

---

## 四、审计日志架构

### 4.1 auditd 规则

```bash
# /etc/audit/rules.d/noda-docker.rules

# 记录所有 docker 命令执行
-a always,exit -F path=/usr/bin/docker -F perm=x -F auid>=1000 -F auid!=4294967295 -k docker-cmd

# 记录 docker socket 访问
-w /var/run/docker.sock -p rwxa -k docker-socket

# 记录 docker compose 命令
-a always,exit -F path=/usr/libexec/docker/cli-plugins/docker-compose -F perm=x -F auid>=1000 -F auid!=4294967295 -k docker-compose-cmd

# 记录部署脚本执行
-w /opt/noda-infra/scripts/deploy -p x -k deploy-scripts

# 记录 nginx 配置修改
-w /opt/noda-infra/config/nginx -p wa -k nginx-config

# 记录 break-glass 使用
-w /usr/local/bin/noda-emergency-deploy.sh -p x -k break-glass

# 记录 sudoers 文件修改
-w /etc/sudoers.d/ -p wa -k sudoers-modification
```

### 4.2 日志查询

```bash
# 查看所有 docker 命令（最近 24 小时）
ausearch -k docker-cmd -ts yesterday | aureport -x --interpret

# 查看谁在什么时候执行了 docker 命令
ausearch -k docker-cmd --interpret | grep "auid"

# 查看 break-glass 使用记录
ausearch -k break-glass --interpret

# 查看部署脚本执行记录
ausearch -k deploy-scripts --interpret | aureport -x

# 查看 docker socket 异常访问
ausearch -k docker-socket -sc open -sv no  # 仅失败的访问（说明有人尝试未授权访问）
```

### 4.3 审计日志轮转

```bash
# /etc/logrotate.d/noda-audit
/var/log/noda-audit/*.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    create 0640 root root
}
```

---

## 五、文件权限矩阵

### 5.1 需要修改权限的文件

| 文件/目录 | 当前权限 | 目标权限 | 目标属主 | 理由 |
|-----------|---------|---------|---------|------|
| `/var/run/docker.sock` | `root:docker 660` | `root:jenkins 660` | jenkins 直接访问 Docker |
| `scripts/deploy/*.sh` | `755 :staff` | `750 root:jenkins` | 仅 jenkins 可执行 |
| `scripts/pipeline-stages.sh` | `755 :staff` | `750 root:jenkins` | 仅 jenkins 可执行 |
| `scripts/manage-containers.sh` | `755 :staff` | `750 root:jenkins` | 仅 jenkins 可执行 |
| `scripts/blue-green-deploy.sh` | `755 :staff` | `750 root:jenkins` | 仅 jenkins 可执行 |
| `scripts/keycloak-blue-green-deploy.sh` | `755 :staff` | `750 root:jenkins` | 仅 jenkins 可执行 |
| `scripts/rollback-findclass.sh` | `755 :staff` | `750 root:jenkins` | 仅 jenkins 可执行 |
| `config/nginx/snippets/` | `755 :staff` | `750 root:jenkins` | upstream 文件仅 jenkins 可写 |
| `config/nginx/snippets/upstream-*.conf` | `644 :staff` | `640 root:jenkins` | upstream 配置仅 jenkins 可写 |
| `/opt/noda/active-env*` | `644 root:root` | `660 root:jenkins` | 状态文件 jenkins 可写 |
| `docker/.env` | `644 :staff` | `640 root:jenkins` | 环境变量含密码 |
| `docker/env-*.env` | `644 :staff` | `640 root:jenkins` | env 模板含变量 |
| `config/secrets.sops.yaml` | `644 :staff` | `640 root:jenkins` | 加密密钥 |

### 5.2 保持不变权限的文件

| 文件/目录 | 当前权限 | 理由 |
|-----------|---------|------|
| `scripts/lib/log.sh` | `644` | 通用库，所有用户可读（无安全敏感操作） |
| `scripts/lib/health.sh` | `644` | 通用库，仅调用 docker inspect（只读） |
| `scripts/setup-jenkins.sh` | `755` | 初始化脚本，需要 root 执行（含 sudo 命令） |
| `scripts/setup-dev.sh` | `755` | 开发环境脚本 |
| `scripts/verify/*.sh` | `755` | 验证脚本，只读操作 |
| `docker/docker-compose*.yml` | `644` | compose 配置文件，需要可读但不可写 |

### 5.3 Jenkins workspace 文件权限

Jenkins Pipeline 执行 `git checkout` 后，workspace 中的文件属主为 `jenkins:jenkins`。这意味着：

1. Jenkins 可以直接执行 workspace 中的脚本（`sh 'source scripts/pipeline-stages.sh'`）
2. 脚本中调用 `docker compose`、`docker run` 等命令直接执行（无需 sudo）
3. `config/nginx/snippets/` 的修改通过 `update_upstream()` 函数直接写入

**关键点：** Jenkins workspace 中的文件属主是 `jenkins`，但 `/opt/noda-infra/` 仓库中的部署脚本需要 `root:jenkins` 权限。Jenkins Pipeline 实际执行的是 workspace 中的脚本副本，不是仓库中的原始文件。因此：

- 仓库文件权限 (`/opt/noda-infra/scripts/`) 用于限制手动执行
- Jenkins workspace 文件权限由 Git checkout 自动管理
- 两者互不干扰

---

## 六、systemd Docker Socket 权限持久化

### 6.1 问题

Docker daemon 重启时（`systemctl restart docker`）会重新创建 `/var/run/docker.sock`，恢复默认权限 `root:docker 660`。必须通过 systemd override 确保权限持久。

### 6.2 方案

```ini
# /etc/systemd/system/docker.service.d/socket-permissions.conf
[Unit]
Description=Docker Socket Permission Override for Jenkins

[Service]
# ExecStartPost 在 Docker daemon 启动后执行
# 修改 socket 属组为 jenkins（而非默认的 docker）
ExecStartPost=/bin/sh -c 'chown root:jenkins /var/run/docker.sock && chmod 660 /var/run/docker.sock'
```

**为什么用 `ExecStartPost` 而非 udev 规则：**
- Docker socket 不是设备节点，udev 规则不适用
- `ExecStartPost` 直接在 Docker daemon 启动后执行，时序可靠
- 可以在 `setup-docker-permissions.sh` 中用 `sudo systemctl daemon-reload` 应用

### 6.3 验证

```bash
# 应用 override
sudo systemctl daemon-reload
sudo systemctl restart docker

# 验证 socket 权限
ls -la /var/run/docker.sock
# 期望: srw-rw---- 1 root jenkins 0 ... /var/run/docker.sock

# 验证 jenkins 可以执行 docker 命令
sudo -u jenkins docker ps
# 期望: 正常输出容器列表

# 验证 admin 用户不能直接执行 docker 命令
sudo -u admin docker ps
# 期望: permission denied
```

---

## 七、集成点详细分析

### 7.1 Jenkins Pipeline 执行流（权限收敛后）

```
Jenkins (jenkins 用户)
    │
    │ git checkout → workspace 文件属主 jenkins:jenkins
    │
    │ sh 'source scripts/lib/log.sh'
    │ sh 'source scripts/pipeline-stages.sh'
    │     └── pipeline_build()
    │         └── docker build ...         ← jenkins 直接执行（socket 属组 jenkins）
    │     └── pipeline_deploy()
    │         └── docker run ...           ← jenkins 直接执行
    │         └── run_container()          ← manage-containers.sh 中的函数
    │             └── docker run -d ...    ← jenkins 直接执行
    │     └── pipeline_switch()
    │         └── update_upstream()        ← 写入 config/nginx/snippets/
    │             └── echo > snippets dir  ← jenkins 可以写（组权限）
    │         └── docker exec nginx reload ← jenkins 直接执行
    │
    │ 无变化！Pipeline 不需要任何代码修改
```

**结论：** 方案 A 对 Jenkins Pipeline 的影响为零。`jenkins` 用户通过 socket 属组获得 Docker 访问权，Pipeline 中的所有 `docker` 命令无需修改。

### 7.2 手动部署脚本执行流（权限收敛后）

```
admin 用户 SSH 登录
    │
    │ 直接执行 docker compose up    ← REJECTED (admin 不在 socket 属组)
    │ 直接执行 scripts/deploy/*.sh  ← REJECTED (750 root:jenkins)
    │
    │ sudo docker ps                 ← ALLOWED (sudoers 白名单)
    │ sudo docker logs ...           ← ALLOWED (sudoers 白名单)
    │
    │ Jenkins 不可用时:
    │ sudo noda-emergency-deploy.sh bash scripts/deploy/deploy-apps-prod.sh
    │   ← ALLOWED (break-glass, 需要 admin 密码, 记录审计日志)
```

### 7.3 manage-containers.sh 中的 set_active_env() 适配

当前 `set_active_env()` 函数在写入 `/opt/noda/active-env` 时有 sudo 回退逻辑：

```bash
# 优先尝试直接写入（无 sudo），失败时回退到 sudo
if [ -w "$dir" ] 2>/dev/null; then
    echo "$env" > "$tmp_file" && mv "$tmp_file" "$ACTIVE_ENV_FILE"
elif [ -w "$ACTIVE_ENV_FILE" ] 2>/dev/null; then
    echo "$env" > "$tmp_file" && mv "$tmp_file" "$ACTIVE_ENV_FILE"
else
    sudo mkdir -p "$dir"
    echo "$env" | sudo tee "$tmp_file" > /dev/null
    sudo mv "$tmp_file" "$ACTIVE_ENV_FILE"
fi
```

权限收敛后，`/opt/noda/` 目录属主为 `root:jenkins`，权限 `770`。jenkins 用户可以直接写入，不需要 sudo 回退。但回退逻辑无害，保留即可。

**但需要注意：** 如果 `/opt/noda/` 不存在，`mkdir -p` 需要 root 权限。在 `setup-docker-permissions.sh` 中应预先创建：

```bash
sudo mkdir -p /opt/noda
sudo chown root:jenkins /opt/noda
sudo chmod 770 /opt/noda
```

### 7.4 manage-containers.sh 中的 update_upstream() 适配

当前 `update_upstream()` 写入 nginx snippets 目录。权限收敛后，需要确保 jenkins 用户可以写入。

```bash
# get_host_snippets_dir() 返回的路径需要 jenkins 可写
# Jenkins workspace 中 checkout 的 snippets 目录属主是 jenkins
# 但 docker inspect 获取的 Mount.Source 可能指向 /opt/noda-infra/config/nginx/snippets
```

**分析：** Jenkins Pipeline 在 workspace（`/var/lib/jenkins/workspace/xxx/`）中执行，snippets 目录的路径取决于 Docker Compose 中的 volume 挂载配置。当前 `docker-compose.yml` 中：

```yaml
volumes:
  - ../config/nginx/snippets:/etc/nginx/snippets:ro
```

这意味着 Jenkins 执行 `update_upstream()` 时，写入的是 workspace 中的 `config/nginx/snippets/` 目录（属主 jenkins），而 Docker 容器挂载的是这个目录。所以 jenkins 用户有写权限，不需要修改。

**但如果 Jenkins workspace 使用的是 `/opt/noda-infra/`（直接 checkout 到仓库目录）：** 这时需要确保 `config/nginx/snippets/` 目录 jenkins 可写。目标权限 `750 root:jenkins` 已经覆盖了这个场景。

---

## 八、数据流

### 8.1 权限收敛执行流

```
执行 scripts/setup-docker-permissions.sh apply
    │
    ├── 1. 创建 jenkins-docker 组（可选）或确认 jenkins 用户配置
    ├── 2. 从 docker 组移除非必要用户
    ├── 3. 配置 systemd override (docker socket 权限)
    ├── 4. 重启 Docker daemon
    ├── 5. 修改文件权限 (deploy scripts → 750 root:jenkins)
    ├── 6. 修改目录权限 (snippets → 750 root:jenkins)
    ├── 7. 创建 /opt/noda/ 目录并设置权限
    ├── 8. 部署 sudoers 白名单
    ├── 9. 部署 auditd 规则
    ├── 10. 创建 break-glass 脚本
    ├── 11. 验证所有权限设置
    └── 12. 创建封条文件
```

### 8.2 日常 Jenkins 部署流（无变化）

```
开发者 → Jenkins UI → Build Now
    │
    ▼
Jenkins (jenkins 用户)
    │  1. git checkout
    │  2. source pipeline-stages.sh
    │  3. docker build / docker run / docker compose
    │  4. update_upstream() → 写入 snippets
    │  5. docker exec nginx -s reload
    │  6. 审计日志自动记录 (auditd)
    │
    ▼
部署完成
```

### 8.3 紧急手动部署流（break-glass）

```
admin 用户 → SSH → sudo noda-emergency-deploy.sh ...
    │
    ├── 1. 验证 Jenkins 不可用
    ├── 2. 记录审计日志 (operator + timestamp + command)
    ├── 3. logger -p auth.alert (系统日志)
    ├── 4. 以 root 执行部署脚本
    └── 5. 部署完成后重建封条
```

---

## 九、架构模式

### Pattern 1: Socket 属组收敛（核心模式）

**内容：** 将 Docker socket 的属组从 `docker` 改为 `jenkins`，直接控制谁能访问 Docker。

**使用条件：** 单服务器，只有一个用户需要 Docker 访问权限。

**权衡：**
- 优点：实现简单，对现有 Jenkins Pipeline 零影响
- 优点：不引入额外复杂度（无 rootless、无插件）
- 缺点：容器逃逸后 jenkins 用户仍然有等效 root 权限（但攻击面很小）
- 缺点：需要在 Docker 重启后恢复权限（通过 systemd override 解决）

**代码示例：**

```ini
# /etc/systemd/system/docker.service.d/socket-permissions.conf
[Service]
ExecStartPost=/bin/sh -c 'chown root:jenkins /var/run/docker.sock && chmod 660 /var/run/docker.sock'
```

### Pattern 2: 最小权限 sudoers 白名单

**内容：** 通过 `Cmnd_Alias` 定义只读命令集合，只允许调试操作。

**使用条件：** 需要给管理员提供有限的系统查看能力，但不允许修改。

**权衡：**
- 优点：精确控制，易于审计
- 优点：`NOPASSWD` 只读命令方便日常调试
- 缺点：维护 sudoers 规则需要仔细测试（语法错误会导致 sudo 完全不可用）
- 缺点：docker compose 的子命令路径可能因安装方式不同而不同

**关键实现细节：**

```bash
# docker compose 可能是独立二进制文件或 Docker CLI 插件
# 需要确认路径:
which docker    # /usr/bin/docker
docker compose version  # 确认 compose 是 CLI 插件还是独立二进制

# 如果是 CLI 插件，路径是 /usr/libexec/docker/cli-plugins/docker-compose
# 如果是独立二进制，路径是 /usr/local/bin/docker-compose
```

### Pattern 3: Break-Glass 封条机制

**内容：** 紧急部署必须通过专用入口脚本，自动记录审计日志并验证前置条件。

**使用条件：** 正常操作路径（Jenkins）不可用时，需要受控的替代路径。

**权衡：**
- 优点：紧急情况下不阻塞运维
- 优点：所有操作有审计记录
- 缺点：需要手动验证封条状态
- 缺点：break-glass 脚本本身需要安全保护（`chown root:root`，`chmod 755`，不可修改）

### Pattern 4: 多层审计（纵深防御）

**内容：** 同时使用 auditd（内核级）+ sudo 日志（应用级）+ 应用日志（脚本级）三层审计。

**使用条件：** 需要完整的操作审计追踪。

**权衡：**
- 优点：任何绕过单层的尝试都会被其他层捕获
- 优点：auditd 日志不可篡改（由内核写入）
- 缺点：日志量增加（需要 logrotate）
- 缺点：查询需要学习 `ausearch`/`aureport` 命令

---

## 十、反模式

### Anti-Pattern 1: 直接移除 docker 组

**错误做法：** `groupdel docker`，完全移除 docker 组。

**原因：** Docker 安装和更新过程会重新创建 docker 组。如果 docker 组不存在，`apt upgrade docker-ce` 可能失败或创建空的 docker 组。

**正确做法：** 保留 docker 组，但清空其成员。通过 socket 属组控制访问。docker 组存在但无人属于它，等效于禁用。

### Anti-Pattern 2: sudoers 规则过于宽松

**错误做法：**
```bash
admin ALL=(root) NOPASSWD: /usr/bin/docker *
```

**原因：** 通配符 `*` 匹配所有参数。`sudo docker run -v /:/host -it ubuntu bash` 直接给 root shell。

**正确做法：**
```bash
# 只读命令不需要参数限制（ps, images, logs 本身是安全的）
admin ALL=(root) NOPASSWD: /usr/bin/docker ps, /usr/bin/docker images, /usr/bin/docker logs
# 写入命令完全不允许（不列出 = 默认拒绝）
```

### Anti-Pattern 3: 文件权限收得太紧

**错误做法：** `scripts/lib/log.sh` 设为 `640 root:jenkins`。

**原因：** log.sh 只包含颜色常量和 echo 函数，无安全敏感操作。如果 admin 用户无法 `source log.sh`，那连 `docker ps` 的彩色输出都会失败（因为 log.sh 被 health.sh 引用）。

**正确做法：** 只有包含 docker 写入操作或部署逻辑的脚本需要限制权限。通用库保持可读。

### Anti-Pattern 4: Break-glass 跳过 Jenkins 健康检查

**错误做法：** break-glass 脚本直接执行部署命令，不检查 Jenkins 是否真的不可用。

**原因：** 管理员可能在 Jenkins 正常运行时也使用 break-glass，绕过 Pipeline 的质量门禁（lint、test、健康检查等）。

**正确做法：** break-glash 脚本必须先验证 Jenkins 不可用。只有加 `--force` 参数才能跳过检查，但仍然记录审计日志。

### Anti-Pattern 5: 忘记处理 Docker 重启后 socket 权限

**错误做法：** 手动 `chown root:jenkins /var/run/docker.sock`，不配置 systemd override。

**原因：** 下次 Docker daemon 重启（系统重启、`systemctl restart docker`、Docker 升级），socket 权限恢复为 `root:docker`，jenkins 用户失去 Docker 访问，所有 Pipeline 开始失败。

**正确做法：** 使用 systemd `ExecStartPost` override 确保每次 Docker 启动后都设置正确权限。

---

## 十一、setup-docker-permissions.sh 脚本设计

### 子命令结构

```
setup-docker-permissions.sh <命令>

命令:
  apply     — 应用所有权限收敛配置
  verify    — 验证所有权限配置是否正确
  rollback  — 回滚到收敛前的状态（恢复 docker 组访问）
  status    — 显示当前权限状态
```

### apply 流程

```
1. 前置检查（root 执行，Docker 运行中，jenkins 用户存在）
2. 备份当前状态到 /opt/noda/.permission-backup/
3. 从 docker 组移除非必要用户
4. 配置 systemd override
5. daemon-reload + restart docker
6. 等待 docker 就绪
7. 修改文件权限
8. 部署 sudoers 白名单
9. 部署 auditd 规则
10. 创建 break-glass 脚本
11. 创建 /opt/noda/ 目录结构
12. 创建封条文件
13. 验证所有配置
14. 输出结果摘要
```

### verify 流程

```
检查项:
  [PASS/FAIL] docker.sock 属组: root:jenkins
  [PASS/FAIL] docker.sock 权限: 660
  [PASS/FAIL] systemd override 存在
  [PASS/FAIL] docker 组无非必要成员
  [PASS/FAIL] jenkins 用户可执行 docker ps
  [PASS/FAIL] admin 用户不可直接执行 docker ps
  [PASS/FAIL] admin 用户可通过 sudo docker ps
  [PASS/FAIL] deploy scripts 权限: 750 root:jenkins
  [PASS/FAIL] nginx snippets 权限: 750 root:jenkins
  [PASS/FAIL] /opt/noda/ 权限: 770 root:jenkins
  [PASS/FAIL] sudoers 白名单文件存在且语法正确
  [PASS/FAIL] auditd 规则已加载
  [PASS/FAIL] break-glass 脚本存在且可执行
  [PASS/FAIL] 封条文件存在
```

### rollback 流程

```
1. 将 admin 用户重新加入 docker 组
2. 移除 systemd override
3. daemon-reload + restart docker
4. 恢复文件权限为 755
5. 移除 sudoers 白名单
6. 移除 auditd 规则
7. 验证回滚成功
```

---

## 十二、构建顺序建议

```
Phase 1: Docker socket 权限收敛
  │  配置 systemd override
  │  从 docker 组移除非必要用户
  │  重启 Docker 验证权限持久
  │  验证: jenkins 用户可执行 docker ps
  │  验证: admin 用户不可执行 docker ps
  │
  ├─ 依赖：无
  ├─ 风险：低（jenkins 验证后再移除其他用户）
  └─ 回滚：移除 override，重启 Docker

Phase 2: 部署脚本文件权限锁定
  │  修改 scripts/deploy/*.sh → 750 root:jenkins
  │  修改 scripts/pipeline-stages.sh → 750 root:jenkins
  │  修改 scripts/manage-containers.sh → 750 root:jenkins
  │  修改 config/nginx/snippets/ → 750 root:jenkins
  │  验证: admin 用户不可直接执行部署脚本
  │  验证: Jenkins Pipeline 正常运行（不受影响）
  │
  ├─ 依赖：Phase 1（jenkins 用户已有 Docker 访问权）
  ├─ 风险：低（文件权限变更可立即回滚）
  └─ 回滚：chmod 755 恢复原始权限

Phase 3: sudoers 白名单 + break-glass
  │  部署 /etc/sudoers.d/noda-docker
  │  创建 /usr/local/bin/noda-emergency-deploy.sh
  │  验证: sudo docker ps 正常工作
  │  验证: sudo docker run 被拒绝
  │  验证: break-glash 脚本记录审计日志
  │
  ├─ 依赖：Phase 1 + 2
  ├─ 风险：中（sudoers 语法错误会导致 sudo 完全不可用）
  │  → 必须使用 visudo -f 验证语法后再部署
  └─ 回滚：删除 /etc/sudoers.d/noda-docker

Phase 4: auditd 审计日志
  │  部署 /etc/audit/rules.d/noda-docker.rules
  │  augenrules --load
  │  验证: ausearch -k docker-cmd 返回结果
  │  验证: 日志轮转配置正确
  │
  ├─ 依赖：无（独立于其他 Phase）
  ├─ 风险：低（auditd 规则不影响系统功能）
  └─ 回滚：删除规则文件，augenrules --load

Phase 5: 统一执行脚本 + 验证
  │  编写 setup-docker-permissions.sh
  │  集成 apply/verify/rollback/status 子命令
  │  端到端验证所有功能
  │  文档更新
  │
  ├─ 依赖：Phase 1-4 全部完成
  └─ 风险：低（仅整合已有配置）
```

**Phase 排序理由：**
1. Phase 1 是基础 -- 没有 socket 权限收敛，其他所有措施都是空谈
2. Phase 2 紧跟 Phase 1 -- 确保 jenkins 能正常工作后再锁定脚本
3. Phase 3 在 Phase 1+2 之后 -- 先确保正常路径工作，再配置替代路径
4. Phase 4 独立 -- 审计日志是监控层，不影响操作权限
5. Phase 5 最后 -- 统一脚本整合所有配置

---

## 十三、与 v1.5 架构的兼容性

### 13.1 不影响的 v1.5 功能

| v1.5 功能 | 权限收敛影响 | 理由 |
|-----------|-------------|------|
| Jenkins Pipeline（findclass-ssr） | 无影响 | jenkins 用户通过 socket 属组访问 Docker |
| Jenkins Pipeline（noda-site） | 无影响 | 同上 |
| Jenkinsfile.infra | 无影响 | 同上 |
| Keycloak 蓝绿部署 | 无影响 | manage-containers.sh 属于 jenkins 可执行 |
| 宿主机 PostgreSQL | 无影响 | 与 Docker 权限无关 |
| 开发环境 setup-dev.sh | 无影响 | 开发环境不受生产权限限制 |

### 13.2 需要注意的集成点

| 集成点 | 注意事项 |
|--------|---------|
| `setup-jenkins.sh install` | 步骤 8 需要修改：不再加入 docker 组，改为 socket 属组 |
| `manage-containers.sh set_active_env()` | sudo 回退逻辑保留但不应触发（/opt/noda/ 属组 jenkins） |
| `pipeline-stages.sh pipeline_backup_database()` | 备份文件写入 BACKUP_HOST_DIR，需确认 jenkins 有写权限 |
| `docker compose` volume 挂载 | snippets 目录只读挂载（`:ro`），jenkins 在宿主机端写入，无冲突 |

---

## 十四、可扩展性考虑

| 关注点 | 当前（单服务器，1 admin + 1 jenkins） | 增长（3-5 admin） | 大型 |
|-------|--------------------------------------|-------------------|------|
| Docker 访问控制 | socket 属组 | 同上 | Rootless Docker 或 K8s |
| 部署执行 | Jenkins 专用 | 同上 | 多 Jenkins agent |
| 审计 | auditd 本地 | 同上 + 日志聚合 | SIEM（ELK/Datadog） |
| break-glass | 单脚本 + 封条文件 | 密码保险库（Vault） | JIT 临时权限（Teleport） |
| sudoers 规则 | 单文件 | 按角色拆分多个文件 | LDAP/SSSD 集中管理 |

**当前阶段结论：** 单服务器、少量管理员场景下，socket 属组 + sudoers 白名单 + break-glass 脚本是最佳平衡点。不引入额外依赖，运维复杂度最低。

---

## 数据源

| 来源 | 置信度 | 用途 |
|------|--------|------|
| `docker/docker-compose.yml` | HIGH（直接读取） | Docker 服务定义、volume 挂载 |
| `scripts/pipeline-stages.sh` | HIGH（直接读取） | Jenkins Pipeline 函数、docker 命令调用 |
| `scripts/manage-containers.sh` | HIGH（直接读取） | 蓝绿容器管理、set_active_env()、update_upstream() |
| `scripts/setup-jenkins.sh` | HIGH（直接读取） | Jenkins 安装逻辑、docker 组配置 |
| `jenkins/Jenkinsfile` | HIGH（直接读取） | Pipeline 结构、sh 步骤调用 |
| `config/nginx/snippets/upstream-*.conf` | HIGH（直接读取） | upstream 动态切换文件 |
| `.planning/PROJECT.md` | HIGH（直接读取） | v1.6 里程碑目标 |
| Linux sudoers 文档 | HIGH（稳定技术） | Cmnd_Alias 语法、Defaults 日志配置 |
| Docker socket 安全模型 | HIGH（稳定技术） | docker 组 = root 等价权限 |
| auditd 规则语法 | HIGH（稳定技术） | audit 规则字段、ausearch/aureport 用法 |
| systemd override 机制 | HIGH（稳定技术） | ExecStartPost 钩子 |

---

*Architecture research for: Noda v1.6 Jenkins Pipeline 强制执行 — Docker 权限收敛*
*Researched: 2026-04-17*
