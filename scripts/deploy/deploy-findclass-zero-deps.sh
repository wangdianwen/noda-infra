#!/bin/bash
# DEPRECATED: 此脚本已过时，请使用 scripts/deploy/deploy-infrastructure-prod.sh 或 scripts/deploy/deploy-apps-prod.sh

# Findclass 零依赖部署脚本
# 此脚本包含所有部署逻辑，无需外部配置或环境变量

set -euo pipefail

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"

# 配置
FINDCLASS_IMAGE="noda-findclass"
API_IMAGE="noda-api"
DEPLOY_TIMEOUT=300  # 5 分钟
HEALTH_CHECK_INTERVAL=5
DECRYPTED_ENV_FILE=""

# 错误处理
error_exit() {
    log_error "$1"
    exit 1
}

# 清理函数
cleanup() {
    local env_file="${DECRYPTED_ENV_FILE:-}"
    if [[ -n "$env_file" && -f "$env_file" ]]; then
        rm -f "$env_file"
        log_info "已清理临时环境变量文件"
    fi
}

# 设置清理 trap
trap cleanup EXIT INT TERM

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."

    if ! command -v docker >/dev/null 2>&1; then
        error_exit "缺少依赖: docker"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        error_exit "缺少依赖: docker compose"
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
    log_error "此脚本已废弃，请使用 deploy-infrastructure-prod.sh 或 deploy-apps-prod.sh"
    exit 1
}

# 停止旧容器
stop_old_containers() {
    log_info "停止旧容器..."

    cd "$PROJECT_ROOT/docker"

    if ! docker compose \
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
    if ! docker compose \
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
        if docker ps --format '{{.Names}}' | grep -q "findclass-ssr"; then
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
    # 旧 verify-findclass.sh 已删除（硬编码旧架构路径，不可用）
    # 健康检查由 Jenkins Pipeline 部署阶段覆盖
    log_info "健康检查由 Pipeline 覆盖，跳过本地验证"
    return 0
}

# 回滚部署
rollback_deployment() {
    log_error "部署失败，开始回滚..."

    # 停止当前容器
    cd "$PROJECT_ROOT/docker"
    docker compose \
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

    docker compose \
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
    echo "Findclass 零依赖部署 (DEPRECATED)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_error "此脚本已废弃，请使用 deploy-infrastructure-prod.sh 或 deploy-apps-prod.sh"
    exit 1
}

# 运行主函数
main "$@"
