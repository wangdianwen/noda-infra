# Phase 31: Docker Socket 权限收敛 + 文件权限锁定 - Research

**Researched:** 2026-04-18
**Domain:** Linux 文件权限 / Docker socket 访问控制 / systemd 服务配置 / Git hooks
**Confidence:** HIGH

## Summary

Phase 31 将 Docker socket (`/var/run/docker.sock`) 的属组从默认的 `docker` 改为 `jenkins`，使仅 jenkins 用户可通过 socket 执行 docker 命令。同时将 4 个关键部署脚本的文件权限锁定为 `750 root:jenkins`，并通过 systemd ExecStartPost override 确保服务器重启后权限持久化。Git post-merge hook 解决 git pull 后文件权限被重置的问题。

项目已完成深入的架构研究（`.planning/research/ARCHITECTURE.md`），方案 A（Socket 属组收敛）已在 PROJECT.md 中锁定。本 Phase 的核心工作是实现层面：编写执行脚本、修改 setup-jenkins.sh、创建 systemd override 和 post-merge hook。

**Primary recommendation:** 使用 systemd `ExecStartPost` 修改 Docker socket 属组为 `root:jenkins`，无需新建专用组。jenkins 用户本身的主组 (`jenkins`) 的 GID 即可用于 socket 权限控制。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 恢复/备份验证脚本由 jenkins 用户运行。管理员执行恢复时通过 `sudo -u jenkins bash scripts/backup/restore-postgres.sh` 或 Phase 32 的 Break-Glass 机制
- noda-ops 容器不挂载 Docker socket，备份通过内部网络 pg_dump，不受 socket 权限变更影响
- 宿主机备份脚本（restore.sh, verify.sh, health.sh）大量使用 `docker exec`，需确保 jenkins 用户可执行

- **D-02:** 使用 Git post-merge hook 自动恢复部署脚本的 `750 root:jenkins` 权限
- hook 文件由安装脚本创建，不在版本控制中（安全性考虑）
- hook 需要在 `.git/hooks/post-merge` 中调用 `chown root:jenkins` + `chmod 750`

- **D-03:** 最小范围锁定，仅需求明确列出的脚本：
  - `scripts/deploy/deploy-apps-prod.sh`
  - `scripts/deploy/deploy-infrastructure-prod.sh`
  - `scripts/pipeline-stages.sh`
  - `scripts/manage-containers.sh`
- 其他脚本通过上述脚本间接调用
- 锁定权限：`750 root:jenkins`

- **D-04:** Phase 31 提供最小 undo 脚本（undo-permissions.sh）
- 执行权限修改前先备份当前状态（socket 属组、文件权限列表）
- 回滚时恢复备份的状态
- Phase 34 将提供完整的 `setup-docker-permissions.sh rollback`

### Claude's Discretion
- Socket 属组具体名称（jenkins 组 vs 新建 docker-jenkins 组）— 研究阶段决定
- systemd override 具体配置参数
- post-merge hook 的具体实现方式
- undo 脚本的备份格式和存储位置

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PERM-01 | Docker socket 属组从 `docker` 改为 `jenkins`，非 jenkins 用户无法直接执行 docker 命令 | Socket 属组收敛方案（ARCHITECTURE.md 3.2），systemd ExecStartPost override |
| PERM-02 | Docker socket 权限通过 systemd override 持久化，服务器重启后自动恢复 | systemd drop-in 模式（`/etc/systemd/system/docker.service.d/override.conf`），ExecStartPost 在 Docker daemon 启动后执行 chown/chmod |
| PERM-03 | 部署脚本文件权限锁定为 `750 root:jenkins` | 仅 4 个脚本（D-03 锁定），chown + chmod 命令 |
| PERM-04 | git pull 后文件权限自动恢复（post-merge hook） | Git post-merge hook 在 `.git/hooks/post-merge` 中执行权限恢复 |
| PERM-05 | 统一权限管理脚本 `setup-docker-permissions.sh`，一站式配置所有权限 | Phase 34 范围，Phase 31 仅提供最小 undo 脚本 |
| JENKINS-01 | 权限收敛后所有 4 个 Jenkins Pipeline 正常工作 | Socket 属组为 jenkins → Pipeline 中 sh 步骤以 jenkins 用户执行 docker 命令 → 零代码修改（ARCHITECTURE.md 7.1） |
| JENKINS-02 | 权限收敛后备份脚本正常工作（noda-ops 容器内 + 宿主机 docker exec） | noda-ops 不挂载 socket（已验证 compose 文件），宿主机备份脚本由 jenkins 用户执行（D-01） |
</phase_requirements>

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|-------------|---------|---------|--------------|
| systemd ExecStartPost | 系统自带 | Docker socket 权限持久化 | Docker 重启后重建 socket，ExecStartPost 在 daemon 启动后自动修正权限 `[VERIFIED: .planning/research/ARCHITECTURE.md 6.2]` |
| chown/chmod | GNU coreutils | 文件权限管理 | Linux 标准工具，无需额外安装 `[ASSUMED]` |
| Git post-merge hook | Git 内置 | git pull 后权限恢复 | Git 原生 hook 机制，`.git/hooks/post-merge` 在 merge 完成后自动触发 `[CITED: git-scm.com/docs/githooks]` |

### Supporting
| Library/Tool | Version | Purpose | When to Use |
|-------------|---------|---------|-------------|
| `gpasswd` | shadow 包 | 从 docker 组移除用户 | 权限收敛时移除非 jenkins 用户 `[ASSUMED]` |
| `usermod` | shadow 包 | 用户组管理 | setup-jenkins.sh 修改（从 `-aG docker` 改为不加入 docker 组）`[ASSUMED]` |
| `setfacl`/`getfacl` | acl 包 | 可选的 ACL 权限管理 | 如果需要更细粒度的权限控制 `[ASSUMED]` |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|-----------|----------|----------|
| jenkins 主组作为 socket 属组 | 新建 docker-jenkins 专用组 | 专用组更清晰但多一个组管理开销；jenkins 主组已满足需求且更简洁 |
| systemd ExecStartPost | udev 规则 | Docker socket 不是设备节点，udev 不适用 `[VERIFIED: ARCHITECTURE.md 6.2]` |
| systemd ExecStartPost | tmpfiles.d | tmpfiles.d 管理 /run 下文件但语义不匹配（socket 是运行时创建的） |
| Git post-merge hook | Git smudge/clean filter | smudge/clean 更复杂且影响 diff，post-merge 更直观 `[ASSUMED]` |
| Git post-merge hook | CI/CD 权限恢复步骤 | Jenkins Pipeline 可在 pre-flight 阶段恢复权限，但只覆盖 Pipeline 执行场景 |

**Installation:**
```bash
# 无需安装额外软件包
# 所有工具（systemd, chown, chmod, gpasswd, usermod）均为 Debian/Ubuntu 默认安装
```

## Architecture Patterns

### Recommended Project Structure
```
scripts/
├── setup-docker-permissions.sh  # [Phase 34] 一站式权限管理脚本
├── undo-permissions.sh          # [Phase 31] 最小 undo 脚本
├── setup-jenkins.sh             # [修改] 第 8 步改为不加入 docker 组
├── pipeline-stages.sh           # [权限锁定] 750 root:jenkins
├── manage-containers.sh         # [权限锁定] 750 root:jenkins
├── deploy/
│   ├── deploy-apps-prod.sh      # [权限锁定] 750 root:jenkins
│   └── deploy-infrastructure-prod.sh  # [权限锁定] 750 root:jenkins
└── lib/
    ├── log.sh                   # [不变] 通用日志库
    └── health.sh                # [不变] 通用健康检查库

# 服务器端配置
/etc/systemd/system/docker.service.d/
└── socket-permissions.conf      # systemd override 持久化 socket 权限

.git/hooks/
└── post-merge                   # git pull 后恢复文件权限（不在版本控制中）
```

### Pattern 1: Socket 属组收敛
**What:** 将 `/var/run/docker.sock` 的属组从 `docker` 改为 `jenkins`
**When to use:** 单服务器场景，只有一个服务用户需要 Docker 访问
**Example:**
```ini
# /etc/systemd/system/docker.service.d/socket-permissions.conf
[Service]
ExecStartPost=/bin/sh -c 'chown root:jenkins /var/run/docker.sock && chmod 660 /var/run/docker.sock'
```
```
# 应用
sudo systemctl daemon-reload
sudo systemctl restart docker
# 验证
ls -la /var/run/docker.sock
# 期望: srw-rw---- 1 root jenkins 0 ... /var/run/docker.sock
```
Source: [VERIFIED: ARCHITECTURE.md 6.2, setup-jenkins.sh 已有相同 systemd override 模式用于端口配置]

### Pattern 2: Git Post-Merge Hook 权限恢复
**What:** git pull 后自动恢复锁定脚本的 750 root:jenkins 权限
**When to use:** 受限文件在版本控制中，git pull 会重置权限
**Example:**
```bash
#!/bin/bash
# .git/hooks/post-merge（由 setup 脚本创建，不在版本控制中）
# git pull 后恢复部署脚本的锁定权限

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# D-03: 最小范围锁定
LOCKED_SCRIPTS=(
    "$PROJECT_ROOT/scripts/deploy/deploy-apps-prod.sh"
    "$PROJECT_ROOT/scripts/deploy/deploy-infrastructure-prod.sh"
    "$PROJECT_ROOT/scripts/pipeline-stages.sh"
    "$PROJECT_ROOT/scripts/manage-containers.sh"
)

for script in "${LOCKED_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        chown root:jenkins "$script" 2>/dev/null || true
        chmod 750 "$script" 2>/dev/null || true
    fi
done
```
Source: [ASSUMED — Git hooks 标准用法，需在生产环境验证]

### Pattern 3: 最小 Undo 脚本
**What:** 备份当前状态并提供一键回滚
**When to use:** 权限变更前的安全网
**Example:**
```bash
#!/bin/bash
# undo-permissions.sh — 备份并回滚 Phase 31 权限变更
# 备份格式: /opt/noda/pre-phase31-permissions-backup.txt
# 包含: socket 属组、4 个脚本的当前权限

BACKUP_FILE="/opt/noda/pre-phase31-permissions-backup.txt"

# 备份当前状态
backup_current_state() {
    sudo mkdir -p "$(dirname "$BACKUP_FILE")"
    {
        echo "# Phase 31 权限备份 - $(date -Iseconds)"
        echo "# Docker socket"
        ls -la /var/run/docker.sock
        echo "# 锁定脚本权限"
        ls -la scripts/deploy/deploy-apps-prod.sh
        ls -la scripts/deploy/deploy-infrastructure-prod.sh
        ls -la scripts/pipeline-stages.sh
        ls -la scripts/manage-containers.sh
        echo "# systemd docker override"
        cat /etc/systemd/system/docker.service.d/*.conf 2>/dev/null || echo "无 override"
        echo "# jenkins 组信息"
        groups jenkins
    } | sudo tee "$BACKUP_FILE" > /dev/null
    sudo chmod 600 "$BACKUP_FILE"
}
```
Source: [ASSUMED — 基于项目现有备份模式设计]

### Anti-Patterns to Avoid
- **`chmod 666 /var/run/docker.sock`:** 允许所有用户访问 Docker，安全灾难。永远不要使用。`[VERIFIED: PITFALLS.md Pitfall 2]`
- **`groupdel docker`:** Docker 安装/更新需要 docker 组存在。保留组但清空成员。`[VERIFIED: ARCHITECTURE.md 10.1]`
- **忘记重启 Jenkins:** Linux 组变更需要进程重启才生效。`usermod` 后必须 `systemctl restart jenkins`。`[VERIFIED: PITFALLS.md Pitfall 6]`
- **只修改 socket 权限不改 setup-jenkins.sh:** 重新安装 Jenkins 会回退到旧的 `usermod -aG docker` 模式。`[VERIFIED: PITFALLS.md Pitfall 7]`

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Docker socket 权限持久化 | udev 规则 / tmpfiles.d / cron job | systemd ExecStartPost | Socket 是运行时创建的，udev 不适用；ExecStartPost 时序精确，daemon 启动后立即执行 `[VERIFIED: ARCHITECTURE.md 6.2]` |
| Git pull 后权限恢复 | Git smudge/clean filter | Git post-merge hook | smudge/clean 影响 diff 和 staging，post-merge 只在 merge 完成后触发，不影响正常 Git 操作 `[ASSUMED]` |
| 审计日志收集 | 自定义日志脚本 | auditd (Phase 33) | auditd 是内核级审计，不可绕过；自定义脚本依赖用户自觉 `[VERIFIED: ARCHITECTURE.md]` |

**Key insight:** Docker socket 权限控制的核心是"谁拥有 socket 文件的组读写权限"。不需要引入任何额外的代理、插件或框架——Linux 文件权限本身就是最简单可靠的机制。

## Common Pitfalls

### Pitfall 1: 组变更不立即生效（进程缓存）
**What goes wrong:** `chown root:jenkins /var/run/docker.sock` 后，已运行的 jenkins 进程可能仍无法访问 socket
**Why it happens:** Linux 进程的补充组在 fork/exec 时确定，但 systemd 服务的组在服务启动时读取。如果 Jenkins 未重启，`groups` 命令显示正确但进程实际使用旧组列表。
**How to avoid:** 权限变更后必须 `systemctl restart jenkins`，然后验证 `sudo -u jenkins docker ps`
**Warning signs:** `groups jenkins` 显示正确但 `sudo -u jenkins docker ps` 报 permission denied

### Pitfall 2: Docker 重启后 socket 权限恢复默认
**What goes wrong:** 手动 `chown root:jenkins /var/run/docker.sock` 后，`systemctl restart docker` 或服务器重启后权限恢复为 `root:docker 660`
**Why it happens:** Docker daemon 启动时重新创建 socket 文件，使用编译时默认值
**How to avoid:** 必须通过 systemd override 的 `ExecStartPost` 确保持久化
**Warning signs:** 服务器重启后 `sudo -u jenkins docker ps` 报 permission denied

### Pitfall 3: 宿主机备份脚本 docker exec 失败
**What goes wrong:** `scripts/backup/lib/health.sh`、`restore.sh`、`verify.sh` 在宿主机上使用 `docker exec` 与容器交互。如果执行者不是 jenkins 用户，会失败。
**Why it happens:** 这些脚本通过 `docker exec noda-infra-postgres-prod` 执行数据库操作，需要 Docker socket 访问权限
**How to avoid:** D-01 决定由 jenkins 用户运行备份脚本。管理员通过 `sudo -u jenkins` 执行。
**Warning signs:** `docker exec` 报 `permission denied while trying to connect to the Docker daemon socket`

### Pitfall 4: git pull 重置文件权限
**What goes wrong:** `git pull` 会用 Git 索引中的文件权限覆盖文件系统权限。`750 root:jenkins` 变为 `755 user:user`
**Why it happens:** Git 不保存 owner/group 信息，只保存可执行位。`git checkout`/`git merge` 会重建文件
**How to avoid:** Git post-merge hook 自动恢复权限（D-02）
**Warning signs:** git pull 后 `ls -la scripts/deploy/deploy-apps-prod.sh` 显示非 root:jenkins

### Pitfall 5: nginx snippets 目录写入权限不足
**What goes wrong:** 蓝绿部署通过 `update_upstream()` 写入 `config/nginx/snippets/upstream-*.conf`。如果该目录属主不是 jenkins，写入失败。
**Why it happens:** Jenkins Pipeline 在 workspace 中执行，snippets 目录路径取决于 Docker volume 挂载配置
**How to avoid:** Jenkins workspace 中 checkout 的文件属主是 jenkins，Docker 容器挂载的是 workspace 目录，所以 jenkins 有写权限。但 `/opt/noda-infra/` 仓库中的 snippets 需要 root:jenkins 权限
**Warning signs:** `update_upstream()` 函数报 `Permission denied`

### Pitfall 6: setup-jenkins.sh 状态检查误报
**What goes wrong:** `setup-jenkins.sh cmd_status` 第 298 行检查 `groups jenkins | grep -q docker`。如果新权限模型中 jenkins 不在 docker 组（通过 socket 属组访问），状态检查会误报错误。
**Why it happens:** 状态检查逻辑假设"docker 权限 = docker 组成员"
**How to avoid:** 修改 `cmd_status` 中的检查逻辑，改为验证 `sudo -u jenkins docker ps` 是否成功
**Warning signs:** `setup-jenkins.sh status` 报 "jenkins 用户不属于 docker 组" 但实际 docker 命令正常

### Pitfall 7: /opt/noda/ 目录不存在导致状态文件写入失败
**What goes wrong:** `manage-containers.sh` 的 `set_active_env()` 写入 `/opt/noda/active-env`。如果目录不存在且 jenkins 无权创建，会失败。
**Why it happens:** 权限收敛前 `/opt/noda/` 可能不存在或属主不正确
**How to avoid:** 在权限脚本中预先创建 `/opt/noda/` 并设置 `root:jenkins 770`
**Warning signs:** `set_active_env` 函数报无法写入

## Code Examples

### Docker Socket Systemd Override

```ini
# /etc/systemd/system/docker.service.d/socket-permissions.conf
# 确保每次 Docker daemon 启动后，socket 属组为 jenkins
# Source: [VERIFIED: ARCHITECTURE.md 6.2] + setup-jenkins.sh 已有相同 override 模式
[Service]
ExecStartPost=/bin/sh -c 'chown root:jenkins /var/run/docker.sock && chmod 660 /var/run/docker.sock'
```

### setup-jenkins.sh 第 8 步修改（当前 → 目标）

```bash
# 当前代码（setup-jenkins.sh 第 159-161 行）:
# 步骤 8/10: Docker 权限
log_info "步骤 8/10: 配置 Docker 权限"
sudo usermod -aG docker jenkins
log_success "jenkins 用户已加入 docker 组"

# 目标代码:
# 步骤 8/10: Docker 权限（通过 socket 属组，不加入 docker 组）
log_info "步骤 8/10: 配置 Docker 权限（socket 属组方式）"
# 确保不在 docker 组（幂等操作）
sudo gpasswd -d jenkins docker 2>/dev/null || true
# 配置 systemd override 确保 socket 属组为 jenkins
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/socket-permissions.conf > /dev/null <<'EOF'
[Service]
ExecStartPost=/bin/sh -c 'chown root:jenkins /var/run/docker.sock && chmod 660 /var/run/docker.sock'
EOF
sudo systemctl daemon-reload
# 立即应用（如果 Docker 正在运行）
if systemctl is-active --quiet docker; then
    sudo systemctl restart docker
fi
log_success "Docker socket 权限配置完成（jenkins 用户通过 socket 属组访问）"
```
Source: [VERIFIED: scripts/setup-jenkins.sh 当前实现 + ARCHITECTURE.md 3.2]

### setup-jenkins.sh cmd_status 检查修改

```bash
# 当前代码（第 297-303 行）:
# 检查 4/5: Docker 权限
log_info "检查 4/5: Docker 权限"
if groups jenkins 2>/dev/null | grep -q docker; then
    log_success "jenkins 用户属于 docker 组"
else
    log_error "jenkins 用户不属于 docker 组"
    all_ok=false
fi

# 目标代码:
# 检查 4/5: Docker 权限（通过 socket 属组）
log_info "检查 4/5: Docker 权限"
if sudo -u jenkins docker info >/dev/null 2>&1; then
    log_success "jenkins 用户可以执行 docker 命令（socket 属组方式）"
else
    log_error "jenkins 用户无法执行 docker 命令"
    all_ok=false
fi
# 补充: 检查 systemd override 是否存在
if [ -f /etc/systemd/system/docker.service.d/socket-permissions.conf ]; then
    log_success "Docker socket 权限 systemd override 已配置"
else
    log_error "Docker socket 权限 systemd override 未配置（重启后会丢失）"
    all_ok=false
fi
```
Source: [VERIFIED: scripts/setup-jenkins.sh 当前实现]

### Git Post-Merge Hook

```bash
#!/bin/bash
# .git/hooks/post-merge
# 在 git pull（merge）完成后自动恢复部署脚本的锁定权限
# 由权限管理脚本创建，不在版本控制中
# Source: [ASSUMED — Git hooks 标准机制]

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOCKED_SCRIPTS=(
    "$PROJECT_ROOT/scripts/deploy/deploy-apps-prod.sh"
    "$PROJECT_ROOT/scripts/deploy/deploy-infrastructure-prod.sh"
    "$PROJECT_ROOT/scripts/pipeline-stages.sh"
    "$PROJECT_ROOT/scripts/manage-containers.sh"
)

for script in "${LOCKED_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        # 需要 root 权限执行 chown（hook 在 git pull 用户身份下运行）
        # 如果执行者是 root，直接 chown；否则尝试 sudo
        chown root:jenkins "$script" 2>/dev/null || \
            sudo chown root:jenkins "$script" 2>/dev/null || true
        chmod 750 "$script" 2>/dev/null || \
            sudo chmod 750 "$script" 2>/dev/null || true
    fi
done

# 无输出（静默执行，避免干扰 git pull 的正常输出）
```

### Undo 脚本核心逻辑

```bash
#!/bin/bash
# scripts/undo-permissions.sh
# Phase 31 最小 undo 脚本：备份当前状态 → 执行权限变更 → 提供回滚能力
# Source: [ASSUMED — 基于项目现有模式设计]

set -euo pipefail

BACKUP_FILE="/opt/noda/pre-phase31-permissions-backup.txt"

backup_current_state() {
    sudo mkdir -p "$(dirname "$BACKUP_FILE")"
    {
        echo "# Phase 31 权限备份 - $(date -Iseconds)"
        echo "SOCKET_GROUP=$(stat -c '%G' /var/run/docker.sock 2>/dev/null || echo 'unknown')"
        echo "SOCKET_MODE=$(stat -c '%a' /var/run/docker.sock 2>/dev/null || echo 'unknown')"
        echo ""
        echo "# 脚本权限"
        for script in \
            scripts/deploy/deploy-apps-prod.sh \
            scripts/deploy/deploy-infrastructure-prod.sh \
            scripts/pipeline-stages.sh \
            scripts/manage-containers.sh; do
            if [ -f "$script" ]; then
                echo "FILE_PERMS=$(stat -c '%a:%U:%G' "$script") FILE=$script"
            fi
        done
    } | sudo tee "$BACKUP_FILE" > /dev/null
    sudo chmod 600 "$BACKUP_FILE"
}

undo() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "错误: 备份文件不存在: $BACKUP_FILE"
        exit 1
    fi
    # 恢复 socket 属组为 docker
    sudo chown root:docker /var/run/docker.sock
    sudo chmod 660 /var/run/docker.sock
    # 移除 systemd override
    sudo rm -f /etc/systemd/system/docker.service.d/socket-permissions.conf
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    # 恢复脚本权限为 755 默认值
    for script in \
        scripts/deploy/deploy-apps-prod.sh \
        scripts/deploy/deploy-infrastructure-prod.sh \
        scripts/pipeline-stages.sh \
        scripts/manage-containers.sh; do
        if [ -f "$script" ]; then
            sudo chmod 755 "$script"
            sudo chown "$(whoami):$(whoami)" "$script"
        fi
    done
    # 重新将 jenkins 加入 docker 组
    sudo usermod -aG docker jenkins
    sudo systemctl restart jenkins
    echo "Phase 31 权限变更已回滚"
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|-------------|-----------------|-------------|--------|
| `usermod -aG docker jenkins` | Socket 属组 chown root:jenkins | v1.6 Phase 31 | 不依赖 docker 组，直接控制 socket 访问 |
| 脚本权限 755 | 脚本权限 750 root:jenkins | v1.6 Phase 31 | 非 jenkins 用户无法直接执行部署脚本 |
| 手动 chown（临时） | systemd ExecStartPost（持久） | v1.6 Phase 31 | 重启后权限自动恢复 |
| 无 git pull 权限恢复 | post-merge hook | v1.6 Phase 31 | git pull 后权限自动恢复 |

**Deprecated/outdated:**
- `setup-jenkins.sh` 中的 `usermod -aG docker jenkins` 模式：将被替换为 socket 属组方式
- `setup-jenkins.sh` 中 `cmd_status` 检查 `groups jenkins | grep docker`：将改为 `sudo -u jenkins docker info`
- `setup-jenkins.sh` 中 `cmd_uninstall` 的 `gpasswd -d jenkins docker`：保留（幂等，无害）

## Socket 属组方案决策（Claude's Discretion -> 推荐）

### 推荐：使用 jenkins 主组（GID）

**理由：**
1. jenkins 用户安装时自动创建 `jenkins` 主组，无需额外创建组
2. `chown root:jenkins /var/run/docker.sock` 直接使用 jenkins 主组 GID
3. 无需维护额外组，减少配置复杂度
4. 与 setup-jenkins.sh 的 `chown -R jenkins:jenkins` 模式一致

**不推荐：新建 docker-jenkins 专用组**
- 额外的组管理（创建、维护、文档）
- 无实际安全收益（jenkins 主组已经只包含 jenkins 用户）
- 增加理解成本

**结论：** 直接使用 `jenkins` 主组作为 socket 属组。

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | systemd ExecStartPost 在 Docker daemon 完全启动后执行，socket 文件已存在 | Socket 属组收敛 | 需要在生产环境验证时序（如果 socket 还未创建则 chown 失败） |
| A2 | Git post-merge hook 可以通过 sudo 执行 chown（管理员 git pull 时） | Post-Merge Hook | 如果 sudo 需要 TTY 或密码，hook 会静默失败；需考虑无 TTY 场景 |
| A3 | 宿主机备份脚本通常由 jenkins 用户执行（非 cron 或其他用户） | 备份兼容性 | 如果有 cron job 以其他用户执行备份脚本，需要调整 |
| A4 | Docker compose 文件路径在 jenkins workspace 和 /opt/noda-infra/ 中一致 | 路径一致性 | Jenkins Pipeline 使用 workspace 路径，手动脚本使用仓库路径 |

## Open Questions

1. **生产服务器 docker 组当前成员**
   - What we know: setup-jenkins.sh 将 jenkins 加入 docker 组，但不知道还有哪些用户
   - What's unclear: admin 用户是否在 docker 组？是否有其他用户？
   - Recommendation: 在 Phase 31 执行前在生产服务器运行 `getent group docker` 确认

2. **Git hook 执行身份**
   - What we know: git pull 由管理员在 `/opt/noda-infra/` 仓库执行
   - What's unclear: 管理员是否有 NOPASSWD sudo 权限来执行 hook 中的 chown
   - Recommendation: hook 中使用 `sudo` + 确保 sudoers 允许管理员执行 `chown root:jenkins` 和 `chmod 750` 对特定文件

3. **Jenkins workspace 路径与仓库路径**
   - What we know: Jenkins Pipeline 在 workspace（`/var/lib/jenkins/workspace/xxx/`）中执行
   - What's unclear: Jenkins 是否配置了直接 checkout 到 `/opt/noda-infra/`
   - Recommendation: 这影响文件权限锁定范围。如果 Jenkins 用 workspace，锁定的脚本只在仓库路径有意义。

## Environment Availability

> Step 2.6: 此 Phase 为纯配置/脚本变更，无需外部工具安装。所有依赖（systemd, chown, chmod, gpasswd, usermod）为 Debian/Ubuntu 默认安装。

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| systemd | Socket 权限持久化 | N/A (生产服务器) | — | — |
| Docker daemon | Socket 存在 | N/A (生产服务器) | — | — |
| Git | post-merge hook | N/A (生产服务器) | — | — |
| jenkins 用户 | 权限收敛目标 | N/A (生产服务器) | — | — |

**注:** 本 Phase 的所有操作必须在生产服务器上执行。本地开发环境（macOS）无法验证 Linux 特定的权限和 systemd 配置。Plan 需要区分"在本地仓库中创建/修改的文件"和"在生产服务器上执行的命令"。

## Validation Architecture

> nyquist_validation: enabled (config.json workflow.nyquist_validation 未设置，默认 enabled)

### Test Framework
| Property | Value |
|----------|-------|
| Framework | ShellCheck (静态分析) + 手动验证脚本 |
| Config file | 无（使用 shellcheck 命令行） |
| Quick run command | `shellcheck scripts/undo-permissions.sh` |
| Full suite command | `shellcheck scripts/undo-permissions.sh scripts/setup-jenkins.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PERM-01 | `sudo -u jenkins docker ps` 返回容器列表 | manual-only | 需生产服务器 | N/A (Wave 0) |
| PERM-01 | `sudo -u admin docker ps` 返回 permission denied | manual-only | 需生产服务器 | N/A (Wave 0) |
| PERM-02 | 服务器重启后 socket 属组仍为 root:jenkins | manual-only | 需生产服务器 | N/A (Wave 0) |
| PERM-03 | 4 个脚本权限为 750 root:jenkins | unit | `ls -la scripts/deploy/*.sh scripts/pipeline-stages.sh scripts/manage-containers.sh` | N/A (Wave 0) |
| PERM-04 | post-merge hook 存在且可执行 | unit | `test -x .git/hooks/post-merge` | Wave 0 创建 |
| JENKINS-01 | 4 个 Pipeline 端到端正常运行 | manual-only | 需生产服务器触发 Pipeline | N/A (Wave 0) |
| JENKINS-02 | 备份脚本正常工作 | manual-only | 需生产服务器 | N/A (Wave 0) |

### Sampling Rate
- **Per task commit:** `shellcheck scripts/undo-permissions.sh`
- **Per wave merge:** 完整 shellcheck 所有修改脚本
- **Phase gate:** 生产服务器端到端验证

### Wave 0 Gaps
- [ ] `scripts/undo-permissions.sh` — 需创建
- [ ] `.git/hooks/post-merge` — 需在生产服务器创建（不在版本控制中）
- [ ] 修改 `scripts/setup-jenkins.sh` — 已存在，需修改第 8 步和 cmd_status

**注:** 大部分验证是 manual-only（需要在生产服务器执行），因为涉及 Linux 特定的权限操作。Plan 中需要明确列出生产服务器的验证步骤清单。

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | jenkins 用户通过 socket 属组获得 Docker 访问（等同身份验证） |
| V4 Access Control | yes | 文件权限 750 root:jenkins 限制执行范围 |
| V5 Input Validation | yes | 脚本参数验证（防止路径注入） |
| V6 Cryptography | no | 无加密操作 |

### Known Threat Patterns for Linux Docker Permissions

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 非 jenkins 用户通过 docker 获取 root | Elevation of Privilege | Socket 属组收敛为 jenkins `[VERIFIED: ARCHITECTURE.md 3.2]` |
| 修改部署脚本注入恶意命令 | Tampering | 文件权限 750 root:jenkins + chattr (Phase 34) |
| Docker 重启后权限回退 | Tampering | systemd ExecStartPost override `[VERIFIED: ARCHITECTURE.md 6.2]` |
| git pull 覆盖文件权限 | Tampering | post-merge hook 自动恢复 `[ASSUMED]` |
| sudoers 规则语法错误导致锁定 | Denial of Service | 使用 `visudo -c` 验证（Phase 32） |

## Sources

### Primary (HIGH confidence)
- `.planning/research/ARCHITECTURE.md` — Docker 权限架构设计（Socket 属组方案、systemd override、集成点分析）
- `.planning/research/PITFALLS.md` — 7 个关键 Pitfall 和规避策略
- `scripts/setup-jenkins.sh` — 当前 Jenkins 安装脚本（第 8 步 usermod -aG docker 模式、systemd override 模式）
- `scripts/pipeline-stages.sh` — Pipeline 函数库（1097 行，所有 docker 命令调用链）
- `scripts/manage-containers.sh` — 蓝绿容器管理（646 行，docker run/exec/stop/rm）
- `scripts/deploy/deploy-apps-prod.sh` — 应用部署手动回退脚本
- `scripts/deploy/deploy-infrastructure-prod.sh` — 基础设施部署手动回退脚本
- `docker/docker-compose*.yml` — 确认 noda-ops 不挂载 Docker socket

### Secondary (MEDIUM confidence)
- `.planning/research/STACK.md` — 技术栈选择（gpasswd, usermod, systemd override）
- `scripts/backup/lib/restore.sh` — 宿主机备份恢复（docker exec 调用链）
- `scripts/backup/lib/health.sh` — 备份健康检查（docker exec 调用链）
- `scripts/backup/lib/verify.sh` — 备份验证（docker exec 调用链）

### Tertiary (LOW confidence)
- systemd ExecStartPost 时序可靠性（假设 daemon 完全启动后 socket 已创建，需生产环境验证）

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有工具为 Linux 标准组件，项目已有相同模式（Jenkins systemd override）
- Architecture: HIGH — ARCHITECTURE.md 已完整分析方案 A 的实现细节
- Pitfalls: HIGH — PITFALLS.md 覆盖 7 个关键陷阱，基于项目代码库完整审计
- Post-merge hook: MEDIUM — Git hooks 机制标准，但 sudo in hook 需生产环境验证

**Research date:** 2026-04-18
**Valid until:** 2026-05-18（Linux 权限模型稳定，30 天有效期）
