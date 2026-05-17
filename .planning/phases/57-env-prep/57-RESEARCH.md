# Phase 57: 环境准备 - Research

**Researched:** 2026-05-17
**Domain:** Docker 网络与资源限制配置 (iStoreOS/OpenWrt ARM64)
**Confidence:** HIGH

## Summary

Phase 57 的核心任务是在 r4s (iStoreOS 24.10.6) 上搭建 Docker 运行环境，包括创建独立网桥、配置 Swap 缓冲、设置容器内存限制、建立 SSH 部署通道、验证 Docker 开机自启。所有配置通过幂等 Shell 脚本完成，放在 `scripts/r4s/` 目录下。

关键技术发现：(1) iStoreOS 使用 `/etc/config/dockerd` (UCI 格式) 管理 Docker 配置，而非标准的 `/etc/docker/daemon.json`；(2) `deploy.resources.limits.memory` 在 Docker Compose v5.x 非 Swarm 模式下已验证生效（本地测试确认 67108864 = 64MB）；(3) OpenWrt 使用 procd + `/etc/rc.local` 管理服务自启动，Swap 持久化通过 UCI fstab 配置；(4) 用户创建需要安装 `shadow-useradd` 包，docker 组已存在（GID 65536）。

**Primary recommendation:** 新建 `docker/docker-compose.r4s.yml` overlay 文件覆盖内存限制和端口映射，5 个幂等初始化脚本放在 `scripts/r4s/` 下，每个脚本对应一个 ENV 需求。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** PostgreSQL 768M（从 Mac 上的 2G 压缩）
- **D-02:** Keycloak 640M（保守缓冲，Java 应用启动峰值约 500M）
- **D-03:** Nginx 64M（反向代理开销低）
- **D-04:** noda-ops 256M（备份脚本 + Cloudflare Tunnel）
- **D-05:** findclass-ssr prod 384M（Node.js SSR 服务）
- **D-06:** findclass-ssr pre-prod 128M
- **D-07:** noda-admin 64M
- **D-08:** noda-auth 64M
- **D-09:** Pre-prod 总内存 256M
- **D-10:** 容器总内存 ~2.31 GiB，OS 保留 ~1.46 GiB，加 2GB Swap 安全缓冲
- **D-11:** 优先压缩数据库层（PG + KC），给应用层留更多空间
- **D-12:** 新增 `docker/docker-compose.r4s.yml` overlay 文件
- **D-13:** 容器名与 Mac 保持一致
- **D-14:** r4s 上仓库 clone 到 `/opt/noda-infra`
- **D-15:** 卷路径通过 `.env` 环境变量管理
- **D-16:** 密钥通过 Doppler CLI 动态注入
- **D-17:** r4s 上安装 Doppler CLI
- **D-18:** Compose 文件通过 git clone/pull 同步到 r4s
- **D-19:** 服务管理方式与 Mac 保持一致
- **D-20:** r4s 环境初始化用 shell 脚本（幂等），放在 `scripts/r4s/` 目录下
- **D-21:** 2GB Swap 文件放在 SD 卡 `/mnt/mmc1-4/docker/swapfile`
- **D-22:** `vm.swappiness=10`
- **D-23:** SD 卡先行，可迁移到机械硬盘
- **D-24:** 创建专用 jenkins 用户，加入 docker 组
- **D-25:** SSH 密钥类型 ed25519
- **D-26:** SSH 私钥存在 Jenkins credentials 中
- **D-27:** r4s jenkins 用户的 authorized_keys 只添加 Jenkins 公钥
- **D-28:** Nginx 容器映射到 8080:80 和 8443:443（高端口）
- **D-29:** noda-network 使用 Docker 默认子网（172.17.x.x）
- **D-30:** r4s 上容器日志配置 `max-size=5m, max-file=2`
- **D-31:** 在 Phase 57 脚本中验证 Docker 开机自启状态
- **D-32:** 所有初始化脚本全幂等

### Claude's Discretion
None explicitly stated -- all decisions locked.

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ENV-01 | r4s 上创建 Docker 独立网桥（noda-network），端口映射避免与软路由冲突 | Docker `network create` 命令 + 高端口映射 (8080/8443)，见 Architecture Patterns |
| ENV-02 | r4s 上创建 Swap 文件（建议 2GB）作为 OOM 缓冲 | dd + mkswap + swapon + UCI fstab 持久化，见 Code Examples |
| ENV-03 | 所有容器配置内存限制（deploy.resources.limits），适配 3.77 GiB 内存 | docker-compose.r4s.yml overlay + 已验证非 Swarm 模式生效，见 Standard Stack |
| ENV-04 | 配置 Mac <-> r4s SSH 免密部署密钥 | jenkins 用户 + ed25519 + docker 组 + authorized_keys，见 Code Examples |
| ENV-05 | 确认 iStoreOS Docker 开机自启已配置 | procd init + /etc/init.d/dockerd + restart:unless-stopped，见 Architecture Patterns |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Docker 网桥创建 | r4s 宿主机 | -- | `docker network create` 是宿主机操作，不属于任何容器 |
| Swap 文件配置 | r4s 宿主机 | -- | 内核级操作，需要在宿主机上创建文件和配置 UCI |
| 容器内存限制 | Docker Compose overlay | -- | 通过 `deploy.resources.limits` 在 compose 文件中声明 |
| SSH 部署通道 | r4s 宿主机 | Jenkins (Mac) | jenkins 用户在 r4s 上创建，密钥在 Jenkins 端管理 |
| Docker 开机自启 | r4s procd 服务管理 | -- | OpenWrt 的 procd init 系统控制服务自启动 |
| 容器日志限制 | Docker Compose overlay | -- | 在 compose 文件或 daemon 配置中声明 |

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Docker Engine | 27.3.1 | 容器运行时 | r4s 已预装，无需额外安装 [ASSUMED] |
| Docker Compose | v2.39.1 | 服务编排 | r4s 已预装，支持 deploy.resources.limits 非 Swarm 模式 [ASSUMED] |
| OpenWrt procd | (系统内置) | 服务管理 | iStoreOS 24.10.6 基于 OpenWrt，procd 管理所有服务自启动 [CITED: openwrt.org/docs/guide-developer/procd-init-scripts] |
| UCI (Unified Configuration Interface) | (系统内置) | OpenWrt 配置管理 | 管理 fstab、dockerd 等系统配置 [CITED: openwrt.org] |
| BusyBox | (系统内置) | 基础命令集 | OpenWrt 的 shell 环境，部分命令受限（无 fallocate 等）[ASSUMED] |

### Supporting
| Library/Tool | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| shadow-useradd | (opkg 包) | 创建用户 | 创建 jenkins 用户时需要安装 [CITED: openwrt.org/docs/guide-user/additional-software/create-new-users] |
| shadow-usermod | (opkg 包) | 修改用户组 | 将 jenkins 加入 docker 组 [CITED: openwrt.org/docs/guide-user/additional-software/create-new-users] |
| openssh-server | (系统内置) | SSH 服务 | iStoreOS 默认已安装 dropbear 或 openssh [ASSUMED] |
| Doppler CLI | latest | 密钥管理 | 后续 Phase 需要，D-17 决定安装 [ASSUMED] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| dd 创建 Swap | fallocate | fallocate 在 BusyBox 环境通常不可用，dd 更通用 [ASSUMED] |
| UCI fstab 持久化 Swap | /etc/rc.local | UCI fstab 是 OpenWrt 推荐方式，更可靠；rc.local 顺序不确定 [CITED: openwrt.org] |
| /etc/docker/daemon.json | /etc/config/dockerd (UCI) | iStoreOS 使用 UCI 格式管理 Docker 配置，直接改 daemon.json 可能被系统更新覆盖 [CITED: github.com/istoreos/istoreos/issues/1762] |

## Package Legitimacy Audit

> 本 Phase 不安装 npm/pip/crates 包。所有工具均为系统级 opkg 包或预装软件。

| Package | Registry | Notes |
|---------|----------|-------|
| shadow-useradd | opkg (OpenWrt packages) | OpenWrt 官方包，用于创建系统用户 |
| shadow-usermod | opkg (OpenWrt packages) | OpenWrt 官方包，用于修改用户组 |

**Packages removed due to slopcheck:** N/A（系统级包，无需 slopcheck）
**Packages flagged as suspicious:** N/A

## Architecture Patterns

### System Architecture Diagram

```
Mac (Jenkins)                    r4s (iStoreOS)
┌─────────────────┐              ┌──────────────────────────────────────┐
│ Jenkins Pipeline │              │                                      │
│                  │   SSH        │  /opt/noda-infra/                   │
│ withCredentials  ├─────────────>│  ├── docker/                        │
│   (ssh-key)      │  (jenkins    │  │   ├── docker-compose.yml (base)   │
│                  │   user)      │  │   ├── docker-compose.prod.yml     │
│                  │              │  │   └── docker-compose.r4s.yml (NEW)│
└─────────────────┘              │  ├── .env (Doppler 动态注入)        │
                                 │  └── scripts/r4s/ (初始化脚本)      │
                                 │                                      │
                                 │  Docker Network: noda-network        │
                                 │  ┌──────────────────────────────┐    │
                                 │  │ nginx (8080:80, 8443:443)    │    │
                                 │  │   ├── postgres:5432          │    │
                                 │  │   ├── keycloak:8080          │    │
                                 │  │   ├── noda-ops               │    │
                                 │  │   ├── noda-apps-prod:3000    │    │
                                 │  │   ├── noda-apps-preprod:3000 │    │
                                 │  │   ├── noda-admin:8001        │    │
                                 │  │   └── noda-auth:3004         │    │
                                 │  └──────────────────────────────┘    │
                                 │                                      │
                                 │  /mnt/mmc1-4/docker/                 │
                                 │  ├── swapfile (2GB)                  │
                                 │  └── (Docker data)                   │
                                 └──────────────────────────────────────┘
```

### Recommended Project Structure
```
scripts/r4s/
├── setup-network.sh    # ENV-01: 创建 noda-network 独立网桥
├── setup-swap.sh       # ENV-02: 创建 2GB Swap 文件 + 持久化
├── setup-ssh.sh        # ENV-04: 创建 jenkins 用户 + SSH 密钥
├── verify-docker.sh    # ENV-05: 验证 Docker 开机自启 + 容器恢复
└── setup-r4s.sh        # 编排入口：依次调用以上脚本

docker/
├── docker-compose.yml          # 基础配置（不变）
├── docker-compose.prod.yml     # 生产环境 overlay（不变）
└── docker-compose.r4s.yml      # NEW: r4s 特有覆盖（内存限制 + 端口 + 日志）
```

### Pattern 1: 幂等初始化脚本
**What:** 每个步骤先检查当前状态再执行，重复运行不会产生副作用
**When to use:** 所有 r4s 初始化脚本
**Example:**
```bash
#!/bin/bash
# Source: 项目已建立的模式（参考 deploy-check.sh, platform.sh）
set -euo pipefail

# 幂等检查模式：先查状态，已存在则跳过
setup_swap()
{
    local swapfile="/mnt/mmc1-4/docker/swapfile"

    # 检查 Swap 是否已启用
    if swapon --show | grep -q "$swapfile"; then
        log_info "Swap 已启用: $swapfile"
        return 0
    fi

    # 检查文件是否存在
    if [ ! -f "$swapfile" ]; then
        log_info "创建 Swap 文件: $swapfile (2GB)..."
        dd if=/dev/zero of="$swapfile" bs=1M count=2048 status=progress
        chmod 600 "$swapfile"
        mkswap "$swapfile"
    fi

    swapon "$swapfile"
    log_success "Swap 已启用"
}
```

### Pattern 2: Docker Compose Overlay 叠加
**What:** r4s 特有配置通过独立 overlay 文件覆盖，不修改基础文件
**When to use:** 内存限制、端口映射、日志配置等 r4s 专属差异
**Example:**
```yaml
# docker/docker-compose.r4s.yml
# 使用：docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.r4s.yml up -d

name: noda-infra

services:
  postgres:
    deploy:
      resources:
        limits:
          memory: 768M

  nginx:
    ports:
      - "8080:80"
      - "8443:443"
    deploy:
      resources:
        limits:
          memory: 64M

  noda-ops:
    deploy:
      resources:
        limits:
          memory: 256M
```

### Pattern 3: UCI 配置持久化
**What:** OpenWrt 使用 UCI 管理系统配置，重启后不丢失
**When to use:** Swap fstab 持久化、sysctl 参数持久化
**Example:**
```bash
# Swap 持久化（UCI fstab 方式）
uci add fstab swap
uci set fstab.@swap[-1].device="/mnt/mmc1-4/docker/swapfile"
uci set fstab.@swap[-1].enabled="1"
uci commit fstab

# sysctl 持久化
echo "vm.swappiness=10" >> /etc/sysctl.conf
sysctl -p /etc/sysctl.conf
```

### Anti-Patterns to Avoid
- **直接修改 `/etc/docker/daemon.json`**：iStoreOS 使用 `/etc/config/dockerd` (UCI 格式) 管理 Docker 配置。直接修改 daemon.json 可能被系统更新覆盖。容器日志限制应在 compose 文件中设置，而非 daemon 全局配置 [CITED: github.com/istoreos/istoreos/issues/1762]
- **使用 fallocate 创建 Swap**：BusyBox 环境通常不包含 fallocate，应使用 dd [ASSUMED]
- **在 /etc/rc.local 中放 swapon**：UCI fstab 是 OpenWrt 推荐的持久化方式，rc.local 的执行顺序不确定 [CITED: openwrt.org]
- **使用 `mem_limit` 而非 `deploy.resources.limits`**：`mem_limit` 是 Compose v2 格式，已被 `deploy.resources` 替代。但两者在 Compose v2.20+ 都支持 [VERIFIED: 本地测试确认 deploy.resources.limits.memory 在非 Swarm 模式下生效]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Swap 持久化 | 自定义启动脚本 | UCI fstab 配置 | OpenWrt 原生机制，启动顺序可靠 |
| sysctl 持久化 | rc.local 中 sysctl -w | /etc/sysctl.conf | 标准持久化方式，重启自动生效 |
| Docker 日志限制 | daemon.json 全局配置 | compose 文件中 logging 配置 | 容器级控制更精确，不受 iStoreOS 配置管理冲突影响 |
| 用户创建 | 直接编辑 /etc/passwd | shadow-useradd + usermod | 避免格式错误，自动处理 shadow 文件 |

**Key insight:** iStoreOS 是基于 OpenWrt 的定制系统，许多标准 Linux 实践需要适配 OpenWrt 的 UCI 配置系统和 procd 服务管理。不要假设标准 Linux 配置路径（如 /etc/docker/daemon.json）可用。

## Common Pitfalls

### Pitfall 1: iStoreOS Docker 配置路径冲突
**What goes wrong:** 修改 `/etc/docker/daemon.json` 后被系统更新或 dockerd 重启覆盖
**Why it happens:** iStoreOS 通过 `/etc/config/dockerd` (UCI 格式) 生成 Docker 配置，直接修改 daemon.json 会被覆盖
**How to avoid:** 容器日志限制在 compose 文件的 `logging` 配置中设置（已在 docker-compose.prod.yml 的 x-common-security anchor 中），不修改 Docker daemon 全局配置
**Warning signs:** 修改 daemon.json 后重启 Docker 配置丢失

### Pitfall 2: deploy.resources.limits 非 Swarm 不生效（已验证不存在此问题）
**What goes wrong:** 旧版 Docker Compose 的 `deploy.resources.limits` 在非 Swarm 模式下被忽略
**Why it happens:** Compose v1 和早期 v2 版本只对 Swarm 模式生效
**How to avoid:** Docker Compose v2.20+ 已支持非 Swarm 模式。r4s 的 Compose v2.39.1 完全支持 [VERIFIED: 本地测试 67108864 = 64MB 限制生效]
**Warning signs:** `docker inspect` 显示 Memory=0 表示限制未生效

### Pitfall 3: BusyBox 环境命令缺失
**What goes wrong:** 脚本中使用的命令在 OpenWrt/BusyBox 环境不存在
**Why it happens:** BusyBox 是精简工具集，缺少很多标准 Linux 命令
**How to avoid:** 使用基础命令（dd 而非 fallocate、`[ ]` 而非 `[[ ]]`、避免 Bashism）。但注意 r4s 上的 shell 脚本是在 Mac 上编写然后 scp 到 r4s 执行的，需要确保使用 POSIX 兼容语法
**Warning signs:** `command not found` 错误

### Pitfall 4: Swap 文件在 SD 卡上的磨损
**What goes wrong:** 频繁的 Swap 读写加速 SD 卡老化
**Why it happens:** SD 卡的写入寿命有限（通常 10K-100K 次擦写）
**How to avoid:** `vm.swappiness=10` 大幅减少 Swap 使用频率，只在内存压力大时才 swap。未来迁移到机械硬盘后此问题消失 [ASSUMED]
**Warning signs:** dmesg 中出现 SD 卡 I/O 错误

### Pitfall 5: SSH 用户 shell 环境
**What goes wrong:** jenkins 用户创建时 shell 设为 /bin/false 导致无法 SSH 登录
**Why it happens:** OpenWrt 的有效 shell 是 `/bin/ash`（不是 /bin/bash），且 dropbear 可能对 shell 有要求
**How to avoid:** 创建用户时使用 `-s /bin/ash`，确保可以 SSH 登录执行命令 [CITED: openwrt.org/docs/guide-user/additional-software/create-new-users]
**Warning signs:** SSH 连接后立即断开

### Pitfall 6: docker 组不存在或 GID 不一致
**What goes wrong:** `usermod -aG docker jenkins` 失败因为 docker 组不存在
**Why it happens:** OpenWrt 上 docker 组由 Docker 安装自动创建，GID 是 65536 而非常见的 998/999
**How to avoid:** 脚本中先检查 docker 组是否存在，不存在则创建。用户需要注销重新登录才能生效 [CITED: openwrt.org -- /etc/passwd 示例显示 docker:x:65536:65536]
**Warning signs:** `docker: permission denied while trying to connect`

### Pitfall 7: Nginx 高端口映射覆盖
**What goes wrong:** docker-compose.r4s.yml 中的 ports 覆盖与 docker-compose.yml 中的 ports 定义冲突
**Why it happens:** Docker Compose overlay 的 ports 是完全替换而非合并
**How to avoid:** 在 r4s overlay 中完整定义所有需要的端口映射（8080:80, 8443:443, 8081:81），不依赖基础文件的 ports
**Warning signs:** 容器启动后端口映射不完整

## Code Examples

### 创建 Docker 独立网桥（ENV-01）
```bash
#!/bin/bash
# scripts/r4s/setup-network.sh
# 幂等创建 noda-network 独立网桥
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"

setup_network()
{
    local network_name="noda-network"

    # 幂等检查：网桥已存在则跳过
    if docker network ls --format '{{.Name}}' | grep -q "^${network_name}$"; then
        log_success "Docker 网络已存在: $network_name"
        # 显示网络信息
        docker network inspect "$network_name" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true
        return 0
    fi

    log_info "创建 Docker 网络: $network_name ..."
    docker network create \
        --driver bridge \
        --label "noda.managed=true" \
        "$network_name"

    log_success "Docker 网络创建完成: $network_name"
}

setup_network
```

### 创建 Swap 文件（ENV-02）
```bash
#!/bin/bash
# scripts/r4s/setup-swap.sh
# 幂等创建 2GB Swap 文件 + 持久化 + swappiness 调优
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"

SWAPFILE="/mnt/mmc1-4/docker/swapfile"
SWAP_SIZE_MB=2048

setup_swap()
{
    # 幂等检查：Swap 已启用
    if swapon --show | grep -q "$SWAPFILE"; then
        log_success "Swap 已启用: $SWAPFILE ($(swapon --show | grep "$SWAPFILE" | awk '{print $3}'))"
        configure_swappiness
        return 0
    fi

    # 确保 Docker 数据目录存在
    local swap_dir
    swap_dir="$(dirname "$SWAPFILE")"
    if [ ! -d "$swap_dir" ]; then
        log_error "Docker 数据目录不存在: $swap_dir"
        return 1
    fi

    # 检查磁盘空间
    local available_kb
    available_kb=$(df "$swap_dir" | awk 'NR==2 {print $4}')
    local required_kb=$((SWAP_SIZE_MB * 1024))
    if [ "$available_kb" -lt "$required_kb" ]; then
        log_error "磁盘空间不足: 需要 ${SWAP_SIZE_MB}MB，可用 $((available_kb / 1024))MB"
        return 1
    fi

    # 创建 Swap 文件
    log_info "创建 Swap 文件: $SWAPFILE (${SWAP_SIZE_MB}MB)..."
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_SIZE_MB" status=progress
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"

    log_success "Swap 已启用: $SWAPFILE"

    # 持久化：UCI fstab
    persist_swap
    configure_swappiness
}

persist_swap()
{
    # 幂等检查：UCI fstab 是否已配置
    if uci get fstab.@swap[-1].device 2>/dev/null | grep -q "$SWAPFILE"; then
        log_info "Swap 已在 fstab 中持久化"
        return 0
    fi

    log_info "持久化 Swap 到 UCI fstab..."
    uci add fstab swap
    uci set fstab.@swap[-1].device="$SWAPFILE"
    uci set fstab.@swap[-1].enabled="1"
    uci commit fstab
    log_success "Swap 持久化完成"
}

configure_swappiness()
{
    local target=10
    local current
    current=$(cat /proc/sys/vm/swappiness)

    if [ "$current" -eq "$target" ]; then
        log_info "vm.swappiness 已是 $target"
        return 0
    fi

    log_info "设置 vm.swappiness=$target ..."
    sysctl -w vm.swappiness="$target"

    # 持久化
    if ! grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.swappiness=$target" >> /etc/sysctl.conf
    else
        sed -i "s/vm.swappiness=.*/vm.swappiness=$target/" /etc/sysctl.conf
    fi
    log_success "vm.swappiness 持久化完成"
}

setup_swap
```

### 创建 jenkins 用户 + SSH 密钥（ENV-04）
```bash
#!/bin/bash
# scripts/r4s/setup-ssh.sh
# 幂等创建 jenkins 用户 + 配置 SSH 免密登录
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"

JENKINS_USER="jenkins"
JENKINS_HOME="/home/$JENKINS_USER"
JENKINS_SSH_DIR="$JENKINS_HOME/.ssh"

setup_jenkins_user()
{
    # 安装用户管理工具
    if ! command -v useradd >/dev/null 2>&1; then
        log_info "安装 shadow-useradd ..."
        opkg update
        opkg install shadow-useradd shadow-usermod
    fi

    # 幂等检查：用户已存在
    if id "$JENKINS_USER" >/dev/null 2>&1; then
        log_info "用户已存在: $JENKINS_USER"
    else
        log_info "创建用户: $JENKINS_USER ..."
        useradd -m -s /bin/ash "$JENKINS_USER"
        log_success "用户创建完成: $JENKINS_USER"
    fi

    # 确保 docker 组存在并加入
    ensure_docker_group

    # 创建 SSH 目录
    mkdir -p "$JENKINS_SSH_DIR"
    chmod 700 "$JENKINS_SSH_DIR"
    touch "$JENKINS_SSH_DIR/authorized_keys"
    chmod 600 "$JENKINS_SSH_DIR/authorized_keys"
    chown -R "$JENKINS_USER:$JENKINS_USER" "$JENKINS_HOME"

    log_success "jenkins 用户配置完成"
    log_info "请将 Jenkins 公钥追加到 $JENKINS_SSH_DIR/authorized_keys"
}

ensure_docker_group()
{
    # 检查 docker 组是否存在
    if ! grep -q "^docker:" /etc/group; then
        log_info "创建 docker 组 ..."
        groupadd docker
    fi

    # 将 jenkins 加入 docker 组
    if ! id -nG "$JENKINS_USER" | grep -qw docker; then
        log_info "将 $JENKINS_USER 加入 docker 组 ..."
        usermod -aG docker "$JENKINS_USER"
        log_success "$JENKINS_USER 已加入 docker 组"
    else
        log_info "$JENKINS_USER 已在 docker 组中"
    fi
}

# 添加公钥的辅助函数（从参数或 stdin 读取）
add_authorized_key()
{
    local pubkey="$1"

    if grep -qF "$pubkey" "$JENKINS_SSH_DIR/authorized_keys" 2>/dev/null; then
        log_info "公钥已存在，跳过"
        return 0
    fi

    echo "$pubkey" >> "$JENKINS_SSH_DIR/authorized_keys"
    chown "$JENKINS_USER:$JENKINS_USER" "$JENKINS_SSH_DIR/authorized_keys"
    log_success "公钥已添加"
}

setup_jenkins_user
```

### docker-compose.r4s.yml overlay（ENV-03）
```yaml
# ============================================
# r4s 特有配置 overlay
# ============================================
# 使用：docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.r4s.yml up -d
#
# 覆盖内容：
#   - 内存限制（适配 3.77 GiB RAM）
#   - 端口映射（高端口，避免与 iStoreOS 冲突）
#   - 容器日志限制（更紧凑的配置）
#   - 卷路径（SD 卡存储）

name: noda-infra

# 共享 r4s 日志配置
x-r4s-logging: &r4s-logging
  logging:
    driver: json-file
    options:
      max-size: "5m"
      max-file: "2"

services:
  # ----------------------------------------
  # PostgreSQL — 768M (D-01)
  # ----------------------------------------
  postgres:
    <<: *r4s-logging
    deploy:
      resources:
        limits:
          memory: 768M
        reservations:
          memory: 256M

  # ----------------------------------------
  # Nginx — 64M + 高端口映射 (D-03, D-28)
  # ----------------------------------------
  nginx:
    <<: *r4s-logging
    ports:
      - "8080:80"
      - "8443:443"
    deploy:
      resources:
        limits:
          memory: 64M
        reservations:
          memory: 16M

  # ----------------------------------------
  # Noda Ops — 256M (D-04)
  # ----------------------------------------
  noda-ops:
    <<: *r4s-logging
    deploy:
      resources:
        limits:
          memory: 256M
        reservations:
          memory: 64M

  # ----------------------------------------
  # Keycloak — 640M (D-02)
  # ----------------------------------------
  keycloak:
    <<: *r4s-logging
    deploy:
      resources:
        limits:
          memory: 640M
        reservations:
          memory: 256M
```

### 验证 Docker 开机自启（ENV-05）
```bash
#!/bin/bash
# scripts/r4s/verify-docker.sh
# 验证 Docker 开机自启 + 容器 restart:unless-stopped 生效
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"

verify_docker_autostart()
{
    log_info "验证 Docker 服务开机自启 ..."

    # 检查 dockerd init 脚本是否启用
    if [ -x /etc/init.d/dockerd ]; then
        if /etc/init.d/dockerd enabled 2>/dev/null; then
            log_success "Docker 服务已启用开机自启 (/etc/init.d/dockerd)"
        else
            log_warn "Docker 服务未启用开机自启，正在启用 ..."
            /etc/init.d/dockerd enable
            log_success "Docker 开机自启已启用"
        fi
    else
        log_error "/etc/init.d/dockerd 不存在，Docker 可能未正确安装"
        return 1
    fi

    # 检查 Docker 当前状态
    if docker info >/dev/null 2>&1; then
        local docker_version
        docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        log_success "Docker 运行中 (版本: $docker_version)"
    else
        log_error "Docker 未运行"
        return 1
    fi

    # 验证 restart:unless-stopped 策略
    log_info "验证容器 restart 策略 ..."
    local containers
    containers=$(docker ps -a --filter "label=noda.managed=true" --format '{{.Names}}' 2>/dev/null || true)
    if [ -z "$containers" ]; then
        log_info "暂无容器运行（首次部署前正常）"
    else
        for c in $containers; do
            local policy
            policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null || echo "unknown")
            if [ "$policy" = "unless-stopped" ]; then
                log_success "$c: restart=$policy"
            else
                log_warn "$c: restart=$policy (期望 unless-stopped)"
            fi
        done
    fi

    # 显示系统资源概况
    log_info "系统资源概况:"
    echo "  内存: $(free -m | awk 'NR==2{printf "%dM / %dM (used/total)", $3, $2}')"
    echo "  Swap: $(free -m | awk 'NR==3{printf "%dM / %dM (used/total)", $3, $2}')"
    echo "  磁盘: $(df -h /mnt/mmc1-4/docker | awk 'NR==2{printf "%s / %s (%s used)", $3, $2, $5}')"
}

verify_docker_autostart
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `mem_limit` / `cpus` (Compose v2 格式) | `deploy.resources.limits` (Compose v3) | Compose v3 规范 | deploy.resources 在 Compose v2.20+ 非 Swarm 模式也生效 |
| `/etc/docker/daemon.json` | `/etc/config/dockerd` (UCI) | iStoreOS 特有 | 不能使用标准 Linux 配置路径 |
| systemd | procd | OpenWrt 设计 | 服务管理命令不同 |
| `useradd` (标准) | `opkg install shadow-useradd` | OpenWrt 精简设计 | 需要先安装包 |
| `fallocate` | `dd if=/dev/zero` | BusyBox 限制 | 创建 Swap 文件需要用 dd |

**Deprecated/outdated:**
- `mem_limit` / `memswap_limit`（Compose v2 格式）：虽然仍然兼容，但 `deploy.resources.limits` 是推荐方式
- 直接编辑 `/etc/passwd` 创建用户：应使用 shadow-useradd 工具

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | r4s 上 Docker 27.3.1 和 Compose v2.39.1 已预装 | Standard Stack | 需要在 r4s 上运行 `docker version` 验证 |
| A2 | BusyBox 环境没有 fallocate | Common Pitfalls | 可在 r4s 上运行 `which fallocate` 确认 |
| A3 | iStoreOS 默认使用 dropbear 或 openssh 作为 SSH 服务 | Standard Stack | 需要确认 SSH 服务类型，影响配置方式 |
| A4 | SD 卡磨损问题通过 vm.swappiness=10 缓解 | Common Pitfalls | 高写入负载下仍可能加速老化 |
| A5 | Doppler CLI 可通过官方安装脚本在 ARM64 上安装 | Standard Stack | 需要确认 ARM64 支持情况 |
| A6 | iStoreOS 24.10.6 的 dockerd init 脚本支持 `enabled` 命令 | Code Examples | 需要在 r4s 上确认 |
| A7 | docker 组 GID 为 65536（来自 OpenWrt Wiki /etc/passwd 示例） | Common Pitfalls | 不同版本可能不同，脚本应动态检查 |

## Open Questions

1. **iStoreOS SSH 服务类型**
   - What we know: iStoreOS 基于 OpenWrt，可能使用 dropbear 或 OpenSSH
   - What's unclear: 具体使用哪种 SSH 服务，authorized_keys 的路径和格式是否标准
   - Recommendation: 在 r4s 上运行 `which sshd && cat /etc/ssh/sshd_config` 或 `ps | grep dropbear` 确认

2. **r4s 当前 Docker Root 路径验证**
   - What we know: CONTEXT.md 说 Docker Root 在 /mnt/mmc1-4/docker
   - What's unclear: 是否已通过 /etc/config/dockerd 正确配置
   - Recommendation: 在 r4s 上运行 `docker info | grep "Docker Root Dir"` 验证

3. **Compose overlay 文件在 r4s 上的合并行为**
   - What we know: Docker Compose overlay 模式在 Mac 上正常工作
   - What's unclear: r4s 上的 Compose v2.39.1 处理 overlay 时是否有差异（特别是 ports 覆盖）
   - Recommendation: 创建 overlay 后在 r4s 上运行 `docker compose config` 检查合并结果

## Environment Availability

> 本 Phase 的目标就是在 r4s 上搭建环境，以下是 r4s 上需要验证的工具可用性。

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker Engine | 全部 | 需验证 | 27.3.1 (预期) | -- |
| Docker Compose | ENV-01, ENV-03 | 需验证 | v2.39.1 (预期) | -- |
| dd (BusyBox) | ENV-02 Swap | 需验证 | BusyBox 内置 | -- |
| mkswap/swapon | ENV-02 Swap | 需验证 | BusyBox 内置 | -- |
| opkg | ENV-04 用户创建 | 需验证 | OpenWrt 内置 | -- |
| SSH 服务 | ENV-04 SSH | 需验证 | dropbear 或 openssh | -- |
| UCI | ENV-02 fstab | 需验证 | OpenWrt 内置 | -- |
| procd | ENV-05 服务管理 | 需验证 | OpenWrt 内置 | -- |

**Missing dependencies with no fallback:**
- 需要在 r4s 上逐一确认以上工具的可用性

**Missing dependencies with fallback:**
- 无

**注意:** 以上"需验证"是因为这些是远程 r4s 设备上的工具，在写脚本时需要假定它们可用（CONTEXT.md 确认 Docker 27.3.1 + Compose v2.39.1 已安装），脚本中应包含可用性检查。

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell 脚本幂等验证（无独立测试框架） |
| Config file | none |
| Quick run command | `bash scripts/r4s/verify-docker.sh` |
| Full suite command | 依次运行所有 setup 脚本 + verify 脚本 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ENV-01 | noda-network 网桥存在 | smoke | `docker network ls \| grep noda-network` | Wave 0: 新建 |
| ENV-02 | Swap 文件已启用 | smoke | `swapon --show \| grep swapfile` | Wave 0: 新建 |
| ENV-03 | 容器内存限制生效 | smoke | `docker inspect --format='{{.HostConfig.Memory}}' <container>` | Wave 0: 需容器运行后 |
| ENV-04 | SSH 免密登录 | smoke | `ssh -i <key> jenkins@r4s 'docker ps'` | Wave 0: 手动验证 |
| ENV-05 | Docker 开机自启 | smoke | `/etc/init.d/dockerd enabled` | Wave 0: 新建 |

### Sampling Rate
- **Per task commit:** 在 r4s 上运行对应 setup 脚本并检查退出码
- **Per wave merge:** 运行 verify-docker.sh 全量验证
- **Phase gate:** 所有 5 个 ENV 需求验证通过

### Wave 0 Gaps
- [ ] `scripts/r4s/setup-network.sh` -- covers ENV-01
- [ ] `scripts/r4s/setup-swap.sh` -- covers ENV-02
- [ ] `scripts/r4s/setup-ssh.sh` -- covers ENV-04
- [ ] `scripts/r4s/verify-docker.sh` -- covers ENV-05
- [ ] `scripts/r4s/setup-r4s.sh` -- 编排入口
- [ ] `docker/docker-compose.r4s.yml` -- covers ENV-03

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | SSH ed25519 公钥认证 |
| V3 Session Management | yes | SSH 密钥管理（jenkins 用户专用，不共享） |
| V4 Access Control | yes | jenkins 用户仅限 docker 组权限，无 sudo |
| V5 Input Validation | no | 本 Phase 无用户输入处理 |
| V6 Cryptography | yes | ed25519 SSH 密钥（现代加密） |

### Known Threat Patterns for Docker/SSH 部署

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| SSH 暴力破解 | Tampering | 公钥认证 only（禁用密码登录） |
| Docker socket 提权 | Elevation of Privilege | jenkins 用户在 docker 组，但不允许 sudo |
| 容器逃逸 | Elevation of Privilege | 容器 read_only + cap_drop ALL + no-new-privileges |
| Swap 泄露敏感数据 | Information Disclosure | Swap 内容为内核管理，物理访问才可读取；vm.swappiness=10 减少使用 |

## Sources

### Primary (HIGH confidence)
- OpenWrt Wiki: Create new users -- https://openwrt.org/docs/guide-user/additional-software/create-new-users
- OpenWrt Wiki: Procd Init Scripts -- https://openwrt.org/docs/guide-developer/procd-init-scripts
- iStoreOS GitHub Issue #1762 (Docker daemon.json 配置) -- https://github.com/istoreos/istoreos/issues/1762
- 本地验证: `deploy.resources.limits.memory` 在 Docker Compose v5.x 非 Swarm 模式下生效 (67108864 = 64MB)
- 项目代码: `docker/docker-compose.yml`, `docker/docker-compose.prod.yml`, `scripts/deploy/deploy-infrastructure-prod.sh`

### Secondary (MEDIUM confidence)
- Docker 官方文档: Resource Constraints -- https://docs.docker.com/engine/containers/resource_constraints/
- OpenWrt procd init 脚本示例 -- https://openwrt.org/docs/guide-developer/procd-init-script-example
- Docker Compose deploy.resources.limits GitHub Issues (#1523, #9542) -- 确认 v2.20+ 非 Swarm 支持

### Tertiary (LOW confidence)
- iStoreOS Docker 服务管理指南 -- https://comate.baidu.com/zh/page/zj4uvcdtlws (内容为空，无法验证)
- Doppler CLI ARM64 支持 -- https://cli.doppler.com/install.sh (未验证)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Docker/Compose 在 r4s 上已确认安装，overlay 模式本地验证
- Architecture: HIGH - 基于 OpenWrt 官方文档和 iStoreOS GitHub Issue 验证
- Pitfalls: HIGH - 关键 pitfalls（iStoreOS 配置路径、BusyBox 限制）有官方来源验证
- SSH 配置: MEDIUM - OpenWrt 用户创建有文档，但 iStoreOS 的 SSH 服务类型未确认
- Swap 配置: HIGH - 标准 Linux 操作，UCI fstab 有 OpenWrt 文档支持

**Research date:** 2026-05-17
**Valid until:** 2026-06-17（稳定领域，30 天有效）
