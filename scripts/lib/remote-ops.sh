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
    # -i: 密钥文件
    # -o ConnectTimeout: 连接超时
    # -o StrictHostKeyChecking=no: 跳过主机密钥检查（内网环境）
    # -o ServerAliveInterval: 保活间隔
    ssh -i "$SSH_KEY_FILE" \
        -o ConnectTimeout="$timeout" \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=10 \
        "$R4S_HOST" \
        "$cmd"
}

# ============================================
# 函数: transfer_image
# ============================================
# SSH 管道传输镜像
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

    log_info "传输镜像: $local_image -> $R4S_HOST:$remote_image"

    # docker save | ssh | docker load（per D-03）
    # -C: 启用压缩减少传输时间
    docker save "$local_image" | \
        ssh -C -i "$SSH_KEY_FILE" \
            -o StrictHostKeyChecking=no \
            -o ServerAliveInterval=10 \
            "$R4S_HOST" \
            "docker load && docker tag $local_image $remote_image"

    if [ $? -eq 0 ]; then
        log_success "镜像传输完成: $remote_image"
        return 0
    else
        log_error "镜像传输失败: $local_image"
        return 1
    fi
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
# 获取 flock 文件锁
# 参数:
#   $1: timeout - 锁超时秒数（默认 3600，per D-20）
# 返回: 0=获取成功，1=获取失败
acquire_deploy_lock()
{
    local timeout="${1:-3600}"

    if [ -z "$R4S_HOST" ]; then
        log_error "R4S_HOST 未初始化，请先调用 setup_remote"
        return 1
    fi

    log_info "尝试获取部署锁（超时 ${timeout} 秒）..."

    # flock -n: 非阻塞模式，-w: 超时
    if remote_exec "flock -n -w $timeout /tmp/noda-deploy.lock true"; then
        log_success "部署锁获取成功"
        return 0
    else
        log_error "无法获取部署锁，可能有其他部署进行中"
        return 1
    fi
}

# ============================================
# 函数: release_deploy_lock
# ============================================
# 释放 flock 文件锁
# 返回: 0=释放成功
release_deploy_lock()
{
    if [ -z "$R4S_HOST" ]; then
        log_error "R4S_HOST 未初始化，请先调用 setup_remote"
        return 1
    fi

    log_info "释放部署锁..."

    # flock -u: 释放锁
    remote_exec "flock -u /tmp/noda-deploy.lock"

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
