#!/bin/bash

# Findclass 零依赖部署脚本
# 此脚本包含所有部署逻辑，无需外部配置或环境变量

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 配置
FINDCLASS_IMAGE="noda-findclass"
API_IMAGE="noda-api"
DEPLOY_TIMEOUT=300  # 5 分钟
HEALTH_CHECK_INTERVAL=5

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 错误处理
error_exit() {
    log_error "$1"
    exit 1
}

# 清理函数
cleanup() {
    if [[ -f "$DECRYPTED_ENV_FILE" ]]; then
        rm -f "$DECRYPTED_ENV_FILE"
        log_info "已清理临时环境变量文件"
    fi
}

# 设置清理 trap
trap cleanup EXIT INT TERM

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."

    local missing_deps=()

    for cmd in docker docker-compose; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error_exit "缺少依赖: ${missing_deps[*]}"
    fi

    log_info "依赖检查通过"
}

# 解密密钥
decrypt_secrets() {
    local encrypted_file="$PROJECT_ROOT/secrets/infra.env.prod.enc"
    local decrypted_file="/tmp/noda-secrets/.env.prod"

    if [[ ! -f "$encrypted_file" ]]; then
        log_warn "加密密钥文件不存在: $encrypted_file"
        log_warn "跳过密钥解密"
        return 0
    fi

    log_info "解密密钥..."

    # 创建临时目录
    mkdir -p /tmp/noda-secrets

    # 解密密钥
    if "$PROJECT_ROOT/scripts/decrypt-secrets.sh" infra /tmp/noda-secrets; then
        # 加载环境变量
        set -a
        source "$decrypted_file"
        set +a
        export DECRYPTED_ENV_FILE="$decrypted_file"
        log_info "密钥解密成功"
    else
        error_exit "密钥解密失败"
    fi
}

# 构建 Docker 镜像
build_images() {
    log_info "构建 Docker 镜像..."

    # 构建前端镜像
    log_info "构建前端镜像 ($FINDCLASS_IMAGE)..."
    if ! docker build \
        -t "$FINDCLASS_IMAGE:latest" \
        -f "$PROJECT_ROOT/docker/Dockerfile.findclass" \
        "$PROJECT_ROOT"; then
        error_exit "前端镜像构建失败"
    fi

    log_info "前端镜像构建成功"

    # 构建或拉取 API 镜像（如果存在 Dockerfile）
    if [[ -f "$PROJECT_ROOT/docker/Dockerfile.api" ]]; then
        log_info "构建 API 镜像 ($API_IMAGE)..."
        if ! docker build \
            -t "$API_IMAGE:latest" \
            -f "$PROJECT_ROOT/docker/Dockerfile.api" \
            "$PROJECT_ROOT"; then
            error_exit "API 镜像构建失败"
        fi
        log_info "API 镜像构建成功"
    else
        log_warn "API Dockerfile 不存在，跳过 API 镜像构建"
    fi
}

# 停止旧容器
stop_old_containers() {
    log_info "停止旧容器..."

    cd "$PROJECT_ROOT/docker"

    if ! docker-compose \
        -f docker-compose.yml \
        -f docker-compose.prod.yml \
        down; then
        log_warn "停止容器时出现警告"
    fi

    log_info "旧容器已停止"
}

# 启动新容器
start_new_containers() {
    log_info "启动新容器..."

    cd "$PROJECT_ROOT/docker"

    # 启动服务
    if ! docker-compose \
        -f docker-compose.yml \
        -f docker-compose.prod.yml \
        up -d; then
        error_exit "容器启动失败"
    fi

    log_info "新容器已启动"
}

# 等待容器就绪
wait_for_containers() {
    log_info "等待容器就绪..."

    local elapsed=0

    while [[ $elapsed -lt $DEPLOY_TIMEOUT ]]; do
        # 检查关键容器是否运行
        if docker ps --format '{{.Names}}' | grep -q "noda-findclass"; then
            log_info "容器已就绪"
            return 0
        fi

        sleep $HEALTH_CHECK_INTERVAL
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
        echo -n "."
    done

    echo ""
    error_exit "容器启动超时"
}

# 健康检查
health_check() {
    log_info "执行健康检查..."

    # 运行验证脚本
    if [[ -f "$SCRIPT_DIR/verify-findclass-jenkins.sh" ]]; then
        if bash "$SCRIPT_DIR/verify-findclass-jenkins.sh"; then
            log_info "健康检查通过"
            return 0
        else
            log_warn "健康检查失败，但容器已启动"
            return 1
        fi
    elif [[ -f "$SCRIPT_DIR/verify-findclass.sh" ]]; then
        if bash "$SCRIPT_DIR/verify-findclass.sh"; then
            log_info "健康检查通过"
            return 0
        else
            log_warn "健康检查失败，但容器已启动"
            return 1
        fi
    else
        log_warn "验证脚本不存在，跳过健康检查"
        return 0
    fi
}

# 回滚部署
rollback_deployment() {
    log_error "部署失败，开始回滚..."

    # 停止当前容器
    cd "$PROJECT_ROOT/docker"
    docker-compose \
        -f docker-compose.yml \
        -f docker-compose.prod.yml \
        down || true

    log_error "回滚完成，请检查日志并修复问题"
    exit 1
}

# 显示部署状态
show_deployment_status() {
    log_info "部署状态:"

    cd "$PROJECT_ROOT/docker"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "容器状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    docker-compose \
        -f docker-compose.yml \
        -f docker-compose.prod.yml \
        ps

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "应用访问地址"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "前端: http://localhost:3000"
    echo "Nginx: http://localhost:8080"
    echo ""
}

# 主部署流程
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Findclass 零依赖部署"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # 检查依赖
    check_dependencies

    # 解密密钥
    decrypt_secrets

    # 构建镜像
    build_images

    # 停止旧容器
    stop_old_containers

    # 启动新容器
    start_new_containers

    # 等待容器就绪
    wait_for_containers

    # 健康检查
    if ! health_check; then
        # 可选：在这里触发回滚
        # rollback_deployment
        log_warn "健康检查未通过，请手动验证"
    fi

    # 显示部署状态
    show_deployment_status

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "部署完成！"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# 运行主函数
main "$@"
