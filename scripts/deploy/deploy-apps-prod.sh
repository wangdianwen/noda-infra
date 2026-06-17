#!/bin/bash
# ============================================
# 手动回退部署脚本（应用服务 — Prod 直接替换）
# ============================================
# NOTE: 此脚本作为 Jenkins Pipeline 不可用时的紧急回退方案保留。
# 正常部署请使用 Jenkins apps-deploy Pipeline。
#
# 三分组架构：noda-infra / noda-apps-prod / noda-apps-pre-prod
# 容器命名：noda-apps-prod（单容器，直接替换）
# ============================================

set -euo pipefail

IMAGE_TAG=${1:-"latest"}
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/health.sh"
source "$PROJECT_ROOT/scripts/lib/secrets.sh"

load_secrets

PROD_CONTAINER="noda-apps-prod"
NETWORK_NAME="noda-network"
NGINX_CONTAINER="noda-infra-nginx"

# 临时密钥文件清理（防止脚本异常退出时密钥残留在 /tmp）
_TMP_SECRET_FILES=()
cleanup_tmp_secrets() {
    for f in "${_TMP_SECRET_FILES[@]}"; do
        [ -f "$f" ] && rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup_tmp_secrets EXIT INT TERM

is_container_running()
{
    local name="$1"
    local running
    running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")
    echo "$running"
}

reload_nginx()
{
    if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
        log_error "nginx 容器未运行"
        return 1
    fi
    docker exec "$NGINX_CONTAINER" nginx -s reload
    log_success "nginx 配置已重载"
}

prepare_prod_env_file()
{
    local tmp_file="/tmp/noda-apps-prod.env.$$"
    local env_template="$PROJECT_ROOT/docker/env-noda-apps.env"

    if [ ! -f "$env_template" ]; then
        log_error "prod env 模板文件不存在: $env_template"
        return 1
    fi

    local vars='${POSTGRES_USER} ${POSTGRES_PASSWORD} ${RESEND_API_KEY} ${ANTHROPIC_AUTH_TOKEN} ${ANTHROPIC_BASE_URL} ${ANTHROPIC_API_KEY} ${KEYCLOAK_ADMIN_USER} ${KEYCLOAK_ADMIN_PASSWORD} ${TOKEN_SECRET} ${EMAIL_SERVICE_API_KEY}'
    envsubst "$vars" <"$env_template" >"$tmp_file"
    chmod 600 "$tmp_file"
    _TMP_SECRET_FILES+=("$tmp_file")
    echo "$tmp_file"
}

# ============================================
# 步骤 1/5: 验证基础设施
# ============================================
log_info "=========================================="
log_info "步骤 1/5: 验证基础设施服务"
log_info "=========================================="

# ============================================
# 步骤 2/5: 保存当前镜像标签（rollback）
# ============================================
log_info "=========================================="
log_info "步骤 2/5: 保存当前镜像标签（rollback）"
log_info "=========================================="

if docker inspect "$PROD_CONTAINER" >/dev/null 2>&1; then
    current_image=$(docker inspect --format='{{.Config.Image}}' "$PROD_CONTAINER" 2>/dev/null || echo "")
    if [ -n "$current_image" ]; then
        docker tag "$current_image" "noda-apps:rollback" 2>/dev/null || true
        log_info "保存 rollback 镜像: noda-apps:rollback (from $current_image)"
    fi
fi

# ============================================
# 步骤 3/5: 构建新镜像
# ============================================
log_info "=========================================="
log_info "步骤 3/5: 构建镜像"
log_info "=========================================="

APPS_GIT_SHA=$(cd "$PROJECT_ROOT/../noda-apps" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo "manual")

docker build \
    -t "noda-apps:latest" \
    -t "noda-apps:${APPS_GIT_SHA}" \
    -f "$PROJECT_ROOT/../noda-apps/infra/docker/Dockerfile.noda-apps" \
    --build-arg NEXT_PUBLIC_KEYCLOAK_URL=https://auth.noda.co.nz \
    --build-arg NEXT_PUBLIC_KEYCLOAK_REALM=noda \
    --build-arg NEXT_PUBLIC_KEYCLOAK_CLIENT_ID=noda-frontend \
    --build-arg NEXT_PUBLIC_AUTH_KEYCLOAK_CLIENT_ID=noda-auth \
    "$PROJECT_ROOT/../noda-apps"
log_success "镜像构建完成: noda-apps:${APPS_GIT_SHA}"

# ============================================
# 步骤 4/5: 直接替换部署
# ============================================
log_info "=========================================="
log_info "步骤 4/5: 直接替换部署"
log_info "=========================================="

# 停止并移除旧容器
if [ "$(is_container_running "$PROD_CONTAINER")" = "true" ]; then
    log_info "停止旧容器: $PROD_CONTAINER"
    docker stop -t 30 "$PROD_CONTAINER"
    docker rm "$PROD_CONTAINER"
elif docker inspect "$PROD_CONTAINER" >/dev/null 2>&1; then
    docker rm "$PROD_CONTAINER"
fi

# 准备环境变量
tmp_env=$(prepare_prod_env_file)

# 启动新容器
log_info "启动容器: $PROD_CONTAINER (noda-apps:${APPS_GIT_SHA})"

docker run -d \
    --name "$PROD_CONTAINER" \
    --network "$NETWORK_NAME" \
    --network-alias "$PROD_CONTAINER" \
    --restart unless-stopped \
    --stop-timeout 30 \
    --security-opt no-new-privileges \
    --cap-drop ALL \
    --read-only \
    --tmpfs /tmp \
    --tmpfs /app/scripts/logs \
    --tmpfs /app/apps/findclass/scripts/python/cache:uid=1001,gid=1001,mode=0755 \
    --tmpfs /app/apps/findclass/scripts/python/logs:uid=1001,gid=1001,mode=0755 \
    --tmpfs /app/apps/findclass/api/crawl-output:uid=1001,gid=1001,mode=0755 \
    --memory 1g \
    --memory-reservation 128m \
    --cpus 1 \
    --log-driver json-file \
    --log-opt max-size=10m \
    --log-opt max-file=3 \
    --env-file "$tmp_env" \
    --label "noda.service-group=apps" \
    --label noda.environment=prod \
    --health-cmd "node -e \"fetch('http://localhost:3000/api/health').then(r=>{process.exit(r.ok?0:1)}).catch(()=>process.exit(1))\"" \
    --health-interval 30s \
    --health-timeout 10s \
    --health-retries 3 \
    --health-start-period 60s \
    "noda-apps:${APPS_GIT_SHA}"

# 注意：不在此处删除 $tmp_env，由 trap cleanup_tmp_secrets 在脚本退出时统一清理
# 这样回滚逻辑（需要重新用 $tmp_env 启动容器）才能正常工作

# reload nginx 刷新 DNS 缓存
reload_nginx

# ============================================
# 步骤 5/5: 健康检查
# ============================================
log_info "=========================================="
log_info "步骤 5/5: 健康检查"
log_info "=========================================="

if ! wait_container_healthy "$PROD_CONTAINER" 120; then
    log_error "健康检查失败，回滚到 rollback 镜像..."
    docker rm -f "$PROD_CONTAINER" 2>/dev/null || true
    if docker inspect "noda-apps:rollback" >/dev/null 2>&1; then
        docker run -d \
            --name "$PROD_CONTAINER" \
            --network "$NETWORK_NAME" \
            --network-alias "$PROD_CONTAINER" \
            --restart unless-stopped \
            --env-file "$tmp_env" \
            "noda-apps:rollback"
        log_info "已回滚到 rollback 镜像"
    fi
    exit 1
fi

# ============================================
# 部署完成
# ============================================
log_success "=========================================="
log_success "应用部署完成！"
log_success "=========================================="
