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
    # ServerAliveInterval/CountMax: 保活检测，连续 6 次（60s）无响应则断开
    # 超时方案：用 perl 的 alarm 信号包裹 SSH 调用
    #   - Mac 没有 GNU timeout（需要 brew install coreutils）
    #   - r4s BusyBox 也没有 timeout
    #   - perl 是 Mac 和 Linux 都自带的，用它实现超时是唯一可移植方案
    local exec_timeout=$(( timeout * 20 ))
    [ "$exec_timeout" -lt 120 ] && exec_timeout=120

    perl -e '
        alarm shift @ARGV;
        exec @ARGV or die "exec failed: $!";
    ' -- "$exec_timeout" \
    ssh -i "$SSH_KEY_FILE" \
        -o ConnectTimeout="$timeout" \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=6 \
        "$R4S_HOST" \
        "$cmd"
}

# ============================================
# 函数: transfer_image
# ============================================
# 通过 Docker Registry 增量传输镜像到 r4s
#
# 原理：Mac 上起 Registry 容器（端口 5001），通过 SSH reverse tunnel
# 让 r4s 的 localhost:5001 → Mac 的 registry。
# docker pull 是流式按层拉取——如果 node_modules 层没变，r4s 已有缓存，
# 只拉变化的几 MB。内存峰值远低于 docker load（不需要解压整个 tar）。
#
# 流程：
#   1. 确保 SSH tunnel 建立（r4s localhost:5001 → Mac registry）
#   2. Mac 上 docker tag + push 到 localhost:5001
#   3. r4s 上 docker pull localhost:5001/... + docker tag
#
# 参数:
#   $1: local_image - 本地镜像名（如 noda-apps:abc123）
#   $2: remote_image - 远程镜像名（传输后打 tag）
# 返回: 0=成功，1=失败
transfer_image()
{
    local local_image="$1"
    local remote_image="$2"
    local registry="localhost:5001"

    if [ -z "$R4S_HOST" ]; then
        log_error "R4S_HOST 未初始化，请先调用 setup_remote"
        return 1
    fi

    if [ -z "$SSH_KEY_FILE" ]; then
        log_error "SSH_KEY_FILE 未初始化，请先调用 setup_remote"
        return 1
    fi

    local ssh_opts="-i $SSH_KEY_FILE -o StrictHostKeyChecking=no -o ServerAliveInterval=10"
    local registry_image="${registry}/${local_image}"

    log_info "传输镜像（Registry 增量）: $local_image -> $R4S_HOST:$remote_image"

    # Step 0: 确保 Mac registry 容器在运行
    if ! docker ps --format '{{.Names}}' | grep -q noda-registry; then
        log_info "启动 Mac Registry..."
        docker run -d -p 5001:5000 --name noda-registry --restart unless-stopped \
            -v registry-data:/var/lib/registry registry:2 >/dev/null 2>&1
        sleep 2
    fi

    # Step 1: 确保 SSH reverse tunnel 建立（r4s:5001 → Mac:5001）
    if ! ssh $ssh_opts "$R4S_HOST" 'curl -sf http://localhost:5001/v2/ >/dev/null 2>&1'; then
        log_info "建立 SSH tunnel (r4s:5001 → Mac:5001)..."
        ssh -fnN -R 5001:localhost:5001 "$R4S_HOST" $ssh_opts 2>/dev/null
        sleep 2
        if ! ssh $ssh_opts "$R4S_HOST" 'curl -sf http://localhost:5001/v2/ >/dev/null 2>&1'; then
            log_error "SSH tunnel 建立失败"
            return 1
        fi
    fi
    log_info "Registry tunnel就绪"

    # Step 2: Mac 上 tag + push（增量推送——变化的层才上传）
    log_info "Push 到 Registry..."
    if ! docker tag "$local_image" "$registry_image" 2>/dev/null; then
        log_error "docker tag 失败: $local_image → $registry_image"
        return 1
    fi
    if ! docker push "$registry_image" 2>/dev/null; then
        log_error "docker push 失败: $registry_image"
        return 1
    fi
    docker rmi "$registry_image" >/dev/null 2>&1  # 清理本地 tag

    # Step 3: r4s 上 pull（增量拉取——已有层的跳过）
    log_info "r4s 端 pull（增量）..."
    if ! ssh $ssh_opts "$R4S_HOST" "docker pull $registry_image"; then
        log_error "docker pull 失败（r4s 端）"
        return 1
    fi

    # Step 4: r4s 上打正确的 tag
    ssh $ssh_opts "$R4S_HOST" "docker tag $registry_image $remote_image && docker rmi $registry_image 2>/dev/null"

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
