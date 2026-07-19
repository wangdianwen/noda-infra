#!/bin/bash
# ============================================
# SSH 远程操作封装库
# ============================================
# 功能：封装 SSH 远程命令执行、镜像传输、Docker Compose 操作
# 用途：支持 Jenkins 在 Mac 上通过 SSH 部署到 r4s
# 依赖：scripts/lib/log.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"

# ============================================
# 全局变量（由 setup_remote 初始化）
# ============================================
SSH_KEY_FILE="${SSH_KEY_FILE:-}"  # SSH 密钥文件路径
R4S_HOST="${R4S_HOST:-}"          # r4s 主机地址（user@host 格式）

# ============================================
# 函数: setup_remote
# ============================================
# 初始化 SSH 连接参数
# 参数:
#   $1: SSH_KEY_FILE - SSH 密钥文件路径
#   $2: R4S_HOST - r4s 主机地址（user@host 格式）
# 导出: SSH_KEY_FILE, R4S_HOST
setup_remote()
{
    SSH_KEY_FILE="$1"
    R4S_HOST="$2"

    if [ -z "$SSH_KEY_FILE" ]; then
        log_error "SSH_KEY_FILE 未设置"
        return 1
    fi

    if [ -z "$R4S_HOST" ]; then
        log_error "R4S_HOST 未设置"
        return 1
    fi

    if [ ! -f "$SSH_KEY_FILE" ]; then
        log_error "SSH 密钥文件不存在: $SSH_KEY_FILE"
        return 1
    fi

    export SSH_KEY_FILE R4S_HOST
    log_info "SSH 远程模式已初始化: $R4S_HOST"
}

# ============================================
# 函数: remote_exec
# ============================================
# 封装 SSH 远程命令执行
# 参数:
#   $1: cmd - 要执行的命令
#   $2: timeout - 连接超时秒数（默认 30）
# 返回: 命令的退出码
# 输出: 直接显示在 Jenkins console（不捕获，per D-22）
#
# 参数 $2 在旧版仅作为 ConnectTimeout；现在同时作为命令执行超时
# （r4s 上用 timeout 命令包裹，避免 docker load 等长时间操作挂住）
remote_exec()
{
    local cmd="$1"
    local timeout="${2:-30}"

    if [ -z "$R4S_HOST" ]; then
        log_error "R4S_HOST 未初始化，请先调用 setup_remote"
        return 1
    fi

    if [ -z "$SSH_KEY_FILE" ]; then
        log_error "SSH_KEY_FILE 未初始化，请先调用 setup_remote"
        return 1
    fi

    # SSH 连接参数（per D-05）
    # ConnectTimeout: SSH 连接超时
    # ServerAliveInterval: 保活间隔（防止 NAT 超时断连）
    # 远程命令用 timeout 包裹防止挂死（timeout 值 = connect timeout * 20，最少 120s）
    # 注意：不使用 sh -c 包裹，直接传命令，避免单引号嵌套问题
    #       （docker inspect -f '{{...}}' 等命令含单引号）
    local exec_timeout=$(( timeout * 20 ))
    [ "$exec_timeout" -lt 120 ] && exec_timeout=120

    ssh -i "$SSH_KEY_FILE" \
        -o ConnectTimeout="$timeout" \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=10 \
        "$R4S_HOST" \
        "timeout ${exec_timeout} $cmd"
}

# ============================================
# 函数: transfer_image
# ============================================
# 三步式安全传输镜像到 r4s（避免内存峰值叠加导致路由器 OOM）
#
# 旧方式 docker save | ssh docker load 会同时在 r4s 上运行
# ssh 压缩 + docker load 解压，内存峰值 800MB+，在 3.77GB RAM 的
# r4s 上容易触发 OOM panic 导致路由器死机。
#
# 新方式分三步，降低 r4s 端峰值内存：
#   1. 本地 docker save | gzip（压缩在 Mac 上，不占 r4s 内存）
#   2. scp 传输压缩文件（纯网络 IO，r4s 内存 ~0）
#   3. r4s 端 docker load -i（只做 load，不做 ssh 压缩）
#
# 安全措施：
#   - 传输前预检 r4s 可用内存（至少 800MB 空闲）和磁盘空间
#   - docker load 失败时清理 r4s 上的临时 tar.gz，避免磁盘累积
#
# 参数:
#   $1: local_image - 本地镜像名
#   $2: remote_image - 远程镜像名（传输后打 tag）
# 返回: 0=成功，1=失败
transfer_image()
{
    local local_image="$1"
    local remote_image="$2"

    if [ -z "$R4S_HOST" ]; then
        log_error "R4S_HOST 未初始化，请先调用 setup_remote"
        return 1
    fi

    if [ -z "$SSH_KEY_FILE" ]; then
        log_error "SSH_KEY_FILE 未初始化，请先调用 setup_remote"
        return 1
    fi

    local ssh_opts="-i $SSH_KEY_FILE -o StrictHostKeyChecking=no -o ServerAliveInterval=10"
    local remote_tmp="/mnt/mmc1-4/docker-images"
    local tmp_gz="/tmp/${local_image//[:\/]/_}.tar.gz"
    local remote_gz="$remote_tmp/$(basename "$tmp_gz")"

    log_info "传输镜像（三步式）: $local_image -> $R4S_HOST:$remote_image"

    # Step 0: 预检 r4s 资源（内存 >= 800MB 空闲，磁盘 >= 2GB 空闲）
    log_info "Step 0/3: 预检 r4s 资源..."
    local mem_avail_kb disk_avail_kb
    mem_avail_kb=$(ssh $ssh_opts "$R4S_HOST" "awk '/MemAvailable/{print \$2}' /proc/meminfo" 2>/dev/null)
    disk_avail_kb=$(ssh $ssh_opts "$R4S_HOST" "df -P /mnt/mmc1-4 | tail -1 | awk '{print \$4}'" 2>/dev/null)
    local mem_mb=$(( mem_avail_kb / 1024 ))
    local disk_gb=$(( disk_avail_kb / 1048576 ))
    log_info "r4s 可用内存: ${mem_mb}MB, 可用磁盘: ${disk_gb}GB"

    if [ "$mem_mb" -lt 800 ] 2>/dev/null; then
        log_error "r4s 可用内存不足 (${mem_mb}MB < 800MB)，放弃传输避免 OOM"
        return 1
    fi
    if [ "$disk_gb" -lt 2 ] 2>/dev/null; then
        log_error "r4s 磁盘空间不足 (${disk_gb}GB < 2GB)，放弃传输"
        return 1
    fi

    # Step 1: 本地 save + gzip 压缩（在 Mac 上完成，不占 r4s 内存）
    log_info "Step 1/3: 本地压缩镜像..."
    if ! docker save "$local_image" | gzip > "$tmp_gz"; then
        log_error "镜像压缩失败: $local_image"
        rm -f "$tmp_gz"
        return 1
    fi
    local size_mb=$(( $(stat -f%z "$tmp_gz" 2>/dev/null || stat -c%s "$tmp_gz") / 1048576 ))
    log_info "压缩完成: ${size_mb}MB"

    # Step 2: scp 传输（纯网络 IO，r4s 内存消耗极低）
    log_info "Step 2/3: 传输到 r4s..."
    ssh $ssh_opts "$R4S_HOST" "mkdir -p $remote_tmp" 2>/dev/null
    if ! scp $ssh_opts "$tmp_gz" "$R4S_HOST:$remote_gz"; then
        log_error "镜像传输失败: scp error"
        rm -f "$tmp_gz"
        return 1
    fi
    rm -f "$tmp_gz"  # 清理本地临时文件

    # Step 3: r4s 端 docker load（只做 load，不做 ssh 压缩）
    # 无论成功失败都清理 remote tar.gz（用 ; 分隔确保 rm 总是执行）
    log_info "Step 3/3: r4s 端加载镜像..."
    local load_rc
    ssh $ssh_opts "$R4S_HOST" \
        "docker load -i $remote_gz && \
         docker tag $local_image $remote_image; \
         rc=\$?; rm -f $remote_gz; exit \$rc"
    load_rc=$?

    if [ "$load_rc" -ne 0 ]; then
        log_error "镜像加载失败（r4s 端，exit=$load_rc）"
        # 确保清理（可能上面 rm 也没执行到）
        ssh $ssh_opts "$R4S_HOST" "rm -f $remote_gz" 2>/dev/null
        return 1
    fi

    log_success "镜像传输完成: $remote_image"
    return 0
}

# ============================================
# 函数: remote_compose
# ============================================
# SSH 远程执行 docker compose
# 参数:
#   $1: cmd - compose 子命令（如 up, down, ps, logs）
#   $2: compose_files - compose 文件列表（如 "-f docker-compose.yml -f docker-compose.prod.yml"）
# 返回: compose 命令的退出码
remote_compose()
{
    local cmd="$1"
    local compose_files="${2:-}"

    if [ -z "$R4S_HOST" ]; then
        log_error "R4S_HOST 未初始化，请先调用 setup_remote"
        return 1
    fi

    log_info "远程执行: docker compose $compose_files $cmd"

    # 在 r4s 上执行：cd /opt/noda/noda-infra && docker compose $cmd
    remote_exec "cd /opt/noda/noda-infra && docker compose $compose_files $cmd"
}

# ============================================
# 函数: remote_docker_exec
# ============================================
# SSH 远程 docker exec
# 参数:
#   $1: container - 容器名
#   $2: cmd - 要在容器内执行的命令
# 返回: docker exec 命令的退出码
remote_docker_exec()
{
    local container="$1"
    local cmd="$2"

    if [ -z "$R4S_HOST" ]; then
        log_error "R4S_HOST 未初始化，请先调用 setup_remote"
        return 1
    fi

    # 嵌套 SSH：ssh root@$R4S_HOST "docker exec $container $cmd"（per D-12）
    remote_exec "docker exec $container $cmd"
}

# ============================================
# 函数: acquire_deploy_lock
# ============================================
# 获取部署锁（mkdir 原子操作，兼容 BusyBox）
# 参数:
#   $1: max_wait - 最大等待秒数（默认 60）
# 返回: 0=获取成功，1=获取失败
acquire_deploy_lock()
{
    local max_wait="${1:-60}"

    if [ -z "$R4S_HOST" ]; then
        log_error "R4S_HOST 未初始化，请先调用 setup_remote"
        return 1
    fi

    log_info "尝试获取部署锁（最多等待 ${max_wait} 秒）..."

    # mkdir 是原子操作，兼容 BusyBox（r4s/iStoreOS）
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if remote_exec "mkdir /tmp/noda-deploy.lock 2>/dev/null"; then
            log_success "部署锁获取成功"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_error "无法获取部署锁，可能有其他部署进行中"
    return 1
}

# ============================================
# 函数: release_deploy_lock
# ============================================
# 释放部署锁（rmdir，兼容 BusyBox）
# 返回: 0=释放成功
release_deploy_lock()
{
    if [ -z "$R4S_HOST" ]; then
        log_error "R4S_HOST 未初始化，请先调用 setup_remote"
        return 1
    fi

    log_info "释放部署锁..."

    remote_exec "rmdir /tmp/noda-deploy.lock 2>/dev/null || true"

    log_success "部署锁已释放"
    return 0
}

# ============================================
# Source guard — 仅允许 source 加载，禁止直接执行
# ============================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "remote-ops.sh 是函数库，不支持直接执行"
    echo "请通过 source scripts/lib/remote-ops.sh 加载"
    exit 1
fi
