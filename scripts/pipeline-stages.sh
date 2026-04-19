#!/bin/bash
set -euo pipefail

# ============================================
# Jenkins Pipeline 阶段函数库
# ============================================
# 功能：封装 Jenkinsfile 8 阶段 Pipeline 所需的 bash 函数
# 用途：Jenkinsfile 通过 source 加载此文件，调用 pipeline_* 函数
# 依赖：scripts/lib/log.sh, scripts/manage-containers.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/manage-containers.sh"
source "$PROJECT_ROOT/scripts/lib/secrets.sh"
source "$PROJECT_ROOT/scripts/lib/deploy-check.sh"
source "$PROJECT_ROOT/scripts/lib/image-cleanup.sh"
source "$PROJECT_ROOT/scripts/lib/cleanup.sh"

# 加载密钥（Doppler 双模式，per D-03/D-04/D-10）
load_secrets

# ============================================
# 常量
# ============================================
HEALTH_CHECK_MAX_RETRIES="${HEALTH_CHECK_MAX_RETRIES:-30}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-4}"
E2E_MAX_RETRIES="${E2E_MAX_RETRIES:-5}"
E2E_INTERVAL="${E2E_INTERVAL:-2}"
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.app.yml"
BACKUP_HOST_DIR="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-12}"
IMAGE_RETENTION_DAYS="${IMAGE_RETENTION_DAYS:-7}"

# ============================================
# 函数: check_backup_freshness
# ============================================
# 检查数据库备份文件是否在指定小时内
# 策略：先检查当天/昨天日期子目录，再回退全目录搜索
# 返回：0=备份新鲜，1=备份过期或不存在
# 环境变量：
#   BACKUP_HOST_DIR - 备份目录（默认 $PROJECT_ROOT/docker/volumes/backup）
#   BACKUP_MAX_AGE_HOURS - 最大允许年龄小时数（默认 12）
check_backup_freshness()
{
    local backup_dir="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}"
    local max_age_hours="${BACKUP_MAX_AGE_HOURS:-12}"

    # 策略：先检查当天目录，再检查前一天（D-04）
    local today today_minus1
    today=$(date +"%Y/%m/%d")
    # macOS 兼容：BSD date 使用 -v-1d 代替 GNU date -d "yesterday"
    if date -v-1d >/dev/null 2>&1; then
        today_minus1=$(date -v-1d +"%Y/%m/%d")
    else
        today_minus1=$(date -d "yesterday" +"%Y/%m/%d")
    fi

    local newest_file=""
    for search_dir in "$backup_dir/$today" "$backup_dir/$today_minus1"; do
        if [ -d "$search_dir" ]; then
            # macOS 兼容：不支持 find -printf，使用 stat 获取修改时间
            newest_file=$(find "$search_dir" -type f \( -name "*.dump" -o -name "*.sql" \) \
                -exec stat -f '%m %N' {} \; 2>/dev/null |
                sort -rn | head -1 | cut -d' ' -f2-)
            [ -n "$newest_file" ] && break
        fi
    done

    # 回退：全目录搜索最新备份文件
    if [ -z "$newest_file" ]; then
        newest_file=$(find "$backup_dir" -type f \( -name "*.dump" -o -name "*.sql" \) \
            -exec stat -f '%m %N' {} \; 2>/dev/null |
            sort -rn | head -1 | cut -d' ' -f2-)
    fi

    if [ -z "$newest_file" ]; then
        log_error "未找到任何备份文件（查找路径: $backup_dir）"
        return 1
    fi

    # 计算文件年龄（秒 -> 小时）
    # macOS 兼容：BSD stat 使用 -f '%m' 代替 GNU stat -c%Y
    local file_epoch now_epoch age_seconds age_hours
    if stat -f '%m' "$newest_file" >/dev/null 2>&1; then
        file_epoch=$(stat -f '%m' "$newest_file")
    else
        file_epoch=$(stat -c%Y "$newest_file")
    fi
    now_epoch=$(date +%s)
    age_seconds=$((now_epoch - file_epoch))
    age_hours=$((age_seconds / 3600))

    if [ "$age_hours" -ge "$max_age_hours" ]; then
        log_error "备份已过期 ${age_hours} 小时（阈值: ${max_age_hours} 小时）"
        log_error "最新备份: $newest_file"
        return 1
    fi

    log_info "备份检查通过: 最新备份 ${age_hours} 小时前（阈值: ${max_age_hours} 小时）"
    return 0
}

# ============================================
# Pipeline 阶段函数
# ============================================

# pipeline_preflight - 前置检查
# 检查 Docker daemon、nginx 容器、noda-network
# findclass-ssr 额外检查 Node.js、pnpm、package.json、lint、test
# 参数: $1 = APPS_DIR (可选，默认 $WORKSPACE/noda-apps)
pipeline_preflight()
{
    local apps_dir="${1:-$WORKSPACE/noda-apps}"
    log_info "前置检查..."

    # 检查 Docker daemon
    docker info >/dev/null 2>&1 || {
        log_error "Docker daemon 不可用"
        return 1
    }
    log_info "Docker daemon 可用"

    # 检查 nginx 容器
    if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
        log_error "nginx 容器未运行"
        return 1
    fi
    log_info "nginx 容器运行中"

    # 检查 noda-network
    docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || {
        log_error "Docker 网络 noda-network 不存在"
        return 1
    }
    log_info "Docker 网络 noda-network 存在"

    local service="${SERVICE_NAME:-findclass-ssr}"

    # noda-apps 目录仅对从源码构建的服务需要（findclass-ssr, noda-site）
    # Keycloak 等使用官方镜像的服务不需要
    if [ "$service" != "keycloak" ]; then
        if [ ! -d "$apps_dir" ]; then
            log_error "noda-apps 目录不存在: $apps_dir"
            log_error "请检查 Jenkinsfile Pre-flight stage 的 checkout 配置"
            return 1
        fi
        log_info "noda-apps 目录存在: $apps_dir"
    fi

    if [ "$service" = "findclass-ssr" ]; then
        # findclass-ssr 专用检查：Node.js、pnpm、package.json、lint、test、备份
        if ! command -v node >/dev/null 2>&1; then
            log_error "Node.js 未安装"
            return 1
        fi
        log_info "Node.js: $(node --version)"

        command -v pnpm >/dev/null 2>&1 || {
            log_error "pnpm 未安装，Test 阶段需要 pnpm"
            return 1
        }
        log_info "pnpm: $(pnpm --version)"

        if [ ! -f "$apps_dir/package.json" ]; then
            log_error "noda-apps/package.json 不存在: $apps_dir/package.json"
            return 1
        fi
        log_info "noda-apps/package.json 存在"

        if ! grep -q '"lint"' "$apps_dir/package.json"; then
            log_error "noda-apps/package.json 缺少 lint 脚本"
            return 1
        fi
        log_info "package.json lint 脚本存在"

        if ! grep -q '"test"' "$apps_dir/package.json"; then
            log_error "noda-apps/package.json 缺少 test 脚本"
            return 1
        fi
        log_info "package.json test 脚本存在"

        # 备份时效性检查（本地开发环境降级为警告）
        if ! check_backup_freshness; then
            log_warn "备份检查未通过，继续部署（生产环境应调查备份状态）"
        fi
    else
        # Keycloak: 检查官方镜像配置
        if [ "$service" = "keycloak" ]; then
            local service_image="${SERVICE_IMAGE:-}"
            if [ -z "$service_image" ]; then
                log_error "SERVICE_IMAGE 未设置（Keycloak 需要指定官方镜像）"
                return 1
            fi
            log_info "Keycloak 镜像: $service_image"
            log_info "Keycloak 不需要构建，将使用 docker pull 拉取官方镜像"
        else
            # 其他服务（noda-site 等）：检查 Dockerfile 存在
            local dockerfile="${DOCKERFILE:-$PROJECT_ROOT/deploy/Dockerfile.${service}}"
            if [ ! -f "$dockerfile" ]; then
                log_error "Dockerfile 不存在: $dockerfile"
                return 1
            fi
            log_info "Dockerfile 存在: $dockerfile"
        fi
    fi

    log_success "前置检查全部通过"
}

# pipeline_build - 构建镜像
# 参数: $1 = APPS_DIR (noda-apps 目录), $2 = GIT_SHA
# 环境变量控制：
#   SERVICE_NAME - 镜像名（默认 findclass-ssr）
#   DOCKERFILE   - Dockerfile 路径（默认 deploy/Dockerfile.findclass-ssr）
pipeline_build()
{
    local apps_dir="$1"
    local git_sha="$2"

    local service="${SERVICE_NAME:-findclass-ssr}"
    local dockerfile="${DOCKERFILE:-$PROJECT_ROOT/deploy/Dockerfile.findclass-ssr}"

    log_info "构建镜像..."

    # 使用 docker build 直接构建，避免 compose 文件中其他服务的环境变量要求
    if [ "$service" = "findclass-ssr" ]; then
        docker build \
            -t "${service}:latest" \
            -t "${service}:${git_sha}" \
            -f "$dockerfile" \
            --build-arg VITE_KEYCLOAK_URL=https://auth.noda.co.nz \
            --build-arg VITE_KEYCLOAK_REALM=noda \
            --build-arg VITE_KEYCLOAK_CLIENT_ID=noda-frontend \
            "$apps_dir"
    else
        docker build \
            -t "${service}:latest" \
            -t "${service}:${git_sha}" \
            -f "$dockerfile" \
            "$apps_dir"
    fi

    log_success "镜像构建完成: ${service}:${git_sha}"
}

# pipeline_test - 安装依赖（lint/test 由 Jenkinsfile 独立 sh 步骤调用）
# 参数: $1 = APPS_DIR (noda-apps 目录)
pipeline_test()
{
    local apps_dir="$1"
    (
        cd "$apps_dir"
        pnpm install --frozen-lockfile
        log_success "依赖安装完成"
    )
}

# ============================================
# 函数: pipeline_pull_image
# ============================================
# 拉取官方镜像（用于不从源码构建的服务如 Keycloak）
# 环境变量控制：
#   SERVICE_IMAGE - 官方镜像名（如 quay.io/keycloak/keycloak:26.2.3）
# 返回：0=成功，1=失败
pipeline_pull_image()
{
    local image="${SERVICE_IMAGE:-}"

    if [ -z "$image" ]; then
        log_error "SERVICE_IMAGE 未设置，无法拉取镜像"
        return 1
    fi

    log_info "拉取镜像: $image"

    if ! docker pull "$image"; then
        log_error "镜像拉取失败: $image"
        return 1
    fi

    log_success "镜像拉取完成: $image"
}

# pipeline_deploy - 部署新容器到目标环境
# 参数: $1 = TARGET_ENV (blue/green), $2 = GIT_SHA (可选，官方镜像服务不需要)
# 环境变量控制：
#   SERVICE_NAME - 服务名（默认 findclass-ssr）
#   SERVICE_IMAGE - 官方镜像名（设置后忽略 GIT_SHA，用于 Keycloak 等）
pipeline_deploy()
{
    disk_snapshot "部署前"

    local target_env="$1"
    local git_sha="${2:-}"
    local service="${SERVICE_NAME:-findclass-ssr}"
    local target_container
    target_container=$(get_container_name "$target_env")

    # 确定镜像名：如果设置了 SERVICE_IMAGE 则使用官方镜像，否则使用 Git SHA 标签
    local image_name
    if [ -n "${SERVICE_IMAGE:-}" ]; then
        image_name="$SERVICE_IMAGE"
    else
        image_name="${service}:${git_sha}"
    fi

    # 停止旧的无后缀容器（从单容器模式迁移到蓝绿模式）
    local legacy_container="$service"
    if [ "$(is_container_running "$legacy_container")" = "true" ] &&
        [ "$legacy_container" != "$target_container" ]; then
        log_info "停止旧容器: $legacy_container"
        docker stop -t 30 "$legacy_container"
        docker rm "$legacy_container"
    fi

    # 停止旧目标容器（同色蓝绿容器）
    if [ "$(is_container_running "$target_container")" = "true" ]; then
        log_info "停止旧目标容器: $target_container"
        docker stop -t 30 "$target_container"
        docker rm "$target_container"
    fi

    # 启动新容器
    run_container "$target_env" "$image_name"
    log_success "部署完成: $target_container ($image_name)"
}

# pipeline_health_check - HTTP 健康检查
# 参数: $1 = TARGET_ENV
pipeline_health_check()
{
    local target_env="$1"
    local target_container
    target_container=$(get_container_name "$target_env")
    http_health_check "$target_container" "${SERVICE_PORT:-3001}" "${HEALTH_PATH:-/api/health}" "$HEALTH_CHECK_MAX_RETRIES" "$HEALTH_CHECK_INTERVAL"
}

# pipeline_switch - 切换流量到目标环境
# 参数: $1 = TARGET_ENV, $2 = ACTIVE_ENV
pipeline_switch()
{
    local target_env="$1"
    local active_env="$2"

    update_upstream "$target_env"

    if ! docker exec "$NGINX_CONTAINER" nginx -t; then
        log_error "nginx 配置验证失败，回滚 upstream"
        update_upstream "$active_env"
        # 尝试 reload 使回滚生效（不检查返回值，nginx 可能本身就有问题）
        docker exec "$NGINX_CONTAINER" nginx -s reload 2>/dev/null || true
        return 1
    fi

    reload_nginx
    set_active_env "$target_env"
    log_success "流量切换完成: $active_env -> $target_env"
}

# pipeline_verify - E2E 验证
# 参数: $1 = TARGET_ENV
pipeline_verify()
{
    local target_env="$1"
    e2e_verify "$target_env" "${SERVICE_PORT:-3001}" "${HEALTH_PATH:-/api/health}" "$E2E_MAX_RETRIES" "$E2E_INTERVAL"
}

# pipeline_purge_cdn - 调用 Cloudflare API 清除 CDN 缓存
# 环境变量（由 Jenkins withCredentials 注入）：
#   CF_API_TOKEN - Cloudflare API Token
#   CF_ZONE_ID   - Cloudflare Zone ID
# 返回：0=成功或跳过（永远不阻止部署，per D-09）
pipeline_purge_cdn()
{
    # 凭据缺失时跳过（D-11）
    if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ZONE_ID:-}" ]; then
        log_warn "Cloudflare 凭据未配置，跳过 CDN 缓存清除"
        return 0
    fi

    log_info "清除 CDN 缓存 (zone: $CF_ZONE_ID)..."

    # 使用临时文件传递 JSON body，避免凭据出现在命令行参数中
    local tmp_body
    tmp_body=$(mktemp)
    echo '{"purge_everything":true}' >"$tmp_body"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d @"$tmp_body" \
        --connect-timeout 10 \
        --max-time 30 2>/dev/null) || true

    rm -f "$tmp_body"

    if [ "$http_code" = "200" ]; then
        log_success "CDN 缓存清除完成"
    else
        # D-09: 失败不阻止部署
        log_error "CDN 缓存清除失败 (HTTP ${http_code:-timeout})，不影响部署"
    fi

    return 0
}

# pipeline_cleanup - 停掉非活跃容器 + 清理旧镜像
# 官方镜像服务（Keycloak 等）跳过 SHA 镜像清理，仅清理 dangling images
pipeline_cleanup()
{
    # 停掉非活跃容器，降低资源消耗
    local active_env
    active_env=$(get_active_env)
    local inactive_env
    if [ "$active_env" = "blue" ]; then
        inactive_env="green"
    else
        inactive_env="blue"
    fi
    local inactive_container
    inactive_container=$(get_container_name "$inactive_env")

    if [ "$(is_container_running "$inactive_container")" = "true" ]; then
        log_info "停止非活跃容器: $inactive_container"
        docker stop -t 10 "$inactive_container"
        docker rm "$inactive_container"
        log_success "非活跃容器已清理: $inactive_container"
    else
        log_info "无非活跃容器需要清理"
    fi

    # 官方镜像服务（Keycloak 等）不需要 SHA 镜像清理
    if [ -z "${SERVICE_IMAGE:-}" ]; then
        cleanup_by_date_threshold "${SERVICE_NAME:-findclass-ssr}" "${IMAGE_RETENTION_DAYS:-7}"
    else
        # 仅清理 dangling images
        cleanup_dangling
    fi

    # === 部署后全面清理（per D-03）===
    cleanup_after_deploy "${WORKSPACE:-$PWD}"
}

# pipeline_failure_cleanup - 部署失败时捕获日志并清理
# 参数: $1 = TARGET_ENV
pipeline_failure_cleanup()
{
    local target_env="$1"
    local target_container
    target_container=$(get_container_name "$target_env")

    # 捕获目标容器日志（如果容器存在）
    docker logs "$target_container" >deploy-failure-container.log 2>&1 || true

    # 捕获 nginx 日志
    docker logs "$NGINX_CONTAINER" --tail 50 >deploy-failure-nginx.log 2>&1 || true

    # 清理失败的目标容器
    docker rm -f "$target_container" 2>/dev/null || true

    log_info "失败日志已保存: deploy-failure-container.log, deploy-failure-nginx.log"
}

# ============================================
# 基础设施服务 Pipeline 函数
# ============================================
# 用于 Jenkinsfile.infra 统一基础设施 Pipeline
# 支持 4 种服务: keycloak, nginx, noda-ops, postgres
# 每种服务使用独立的部署/健康检查/回滚策略
# ============================================

# ============================================
# 函数: pipeline_infra_preflight
# ============================================
# 基础设施服务前置检查（统一入口）
# 参数: $1 = SERVICE (keycloak/nginx/noda-ops/postgres)
# 返回: 0=检查通过，1=检查失败
pipeline_infra_preflight()
{
    local service="$1"

    log_info "基础设施前置检查: $service"

    # 检查 Docker daemon
    docker info >/dev/null 2>&1 || {
        log_error "Docker daemon 不可用"
        return 1
    }
    log_info "Docker daemon 可用"

    # 检查 nginx 容器
    if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
        log_error "nginx 容器未运行"
        return 1
    fi
    log_info "nginx 容器运行中"

    # 检查 noda-network
    docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || {
        log_error "Docker 网络 noda-network 不存在"
        return 1
    }
    log_info "Docker 网络 noda-network 存在"

    # 服务专属检查
    case "$service" in
        keycloak)
            if [ -z "${SERVICE_IMAGE:-}" ]; then
                log_error "SERVICE_IMAGE 未设置（Keycloak 需要指定官方镜像）"
                return 1
            fi
            log_info "Keycloak 镜像: $SERVICE_IMAGE"
            ;;
        nginx)
            # 无额外检查
            ;;
        noda-ops)
            # 无额外检查
            ;;
        postgres)
            # 检查 postgres 容器是否 running
            if [ "$(is_container_running "noda-infra-postgres-prod")" != "true" ]; then
                log_error "noda-infra-postgres-prod 容器未运行"
                return 1
            fi
            log_info "noda-infra-postgres-prod 容器运行中"
            ;;
        *)
            log_error "未知服务: $service"
            return 1
            ;;
    esac

    log_success "前置检查全部通过"
}

# ============================================
# 函数: pipeline_backup_database
# ============================================
# 部署前自动备份
# 参数: $1 = SERVICE (keycloak/postgres)
# 环境变量: BACKUP_HOST_DIR
# 返回: 0=备份成功或跳过，1=备份失败
# 导出: INFRA_BACKUP_FILE（备份文件路径）
pipeline_backup_database()
{
    local service="$1"
    local backup_dir="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}/infra-pipeline/${service}"
    local timestamp
    timestamp=$(date +"%Y%m%d-%H%M%S")
    local backup_file="${backup_dir}/${timestamp}.sql.gz"

    # nginx/noda-ops 不需要备份
    if [ "$service" != "keycloak" ] && [ "$service" != "postgres" ]; then
        log_info "$service 不需要备份（无持久化数据）"
        return 0
    fi

    mkdir -p "$backup_dir"

    log_info "部署前备份: $service -> $backup_file"

    if [ "$service" = "keycloak" ]; then
        docker exec noda-infra-postgres-prod pg_dump -U postgres --clean --if-exists keycloak |
            gzip >"$backup_file"
    elif [ "$service" = "postgres" ]; then
        docker exec noda-infra-postgres-prod pg_dumpall -U postgres --clean --if-exists |
            gzip >"$backup_file"
    fi

    # 验证备份文件大小 > 1KB
    local file_size
    file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
    if [ "$file_size" -lt 1024 ]; then
        log_error "备份文件异常（${file_size} 字节），中止部署"
        return 1
    fi

    log_success "备份完成: $backup_file (${file_size} bytes)"
    INFRA_BACKUP_FILE="$backup_file"
    export INFRA_BACKUP_FILE
}

# ============================================
# 函数: pipeline_infra_deploy
# ============================================
# 部署分发（根据服务类型调用对应部署策略）
# 参数: $1 = SERVICE
# 返回: 由子函数决定
pipeline_infra_deploy()
{
    disk_snapshot "部署前"

    local service="$1"

    case "$service" in
        keycloak)
            pipeline_deploy_keycloak
            ;;
        nginx)
            pipeline_deploy_nginx
            ;;
        noda-ops)
            pipeline_deploy_noda_ops
            ;;
        postgres)
            pipeline_deploy_postgres
            ;;
        *)
            log_error "未知服务: $service"
            return 1
            ;;
    esac
}

# ============================================
# 函数: pipeline_deploy_keycloak
# ============================================
# Keycloak 蓝绿部署（复用 keycloak-blue-green-deploy.sh）
# 设置环境变量后调用现有脚本
# 返回: 由 keycloak-blue-green-deploy.sh 决定
pipeline_deploy_keycloak()
{
    log_info "Keycloak 蓝绿部署（复用 keycloak-blue-green-deploy.sh）"

    # 设置 Keycloak 专用环境变量
    export SERVICE_NAME="keycloak"
    export SERVICE_PORT="8080"
    export UPSTREAM_NAME="keycloak_backend"
    export HEALTH_PATH="/health/ready"
    export ACTIVE_ENV_FILE="/opt/noda/active-env-keycloak"
    export UPSTREAM_CONF="$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf"
    export SERVICE_GROUP="infra"
    export CONTAINER_MEMORY="1g"
    export CONTAINER_MEMORY_RESERVATION="512m"
    export CONTAINER_READONLY="false"
    export SERVICE_IMAGE="${SERVICE_IMAGE:-quay.io/keycloak/keycloak:26.2.3}"
    export EXTRA_DOCKER_ARGS="-v $PROJECT_ROOT/docker/services/keycloak/themes:/opt/keycloak/themes/noda:ro --tmpfs /opt/keycloak/data"
    export ENVSUBST_VARS='${POSTGRES_USER} ${POSTGRES_PASSWORD} ${KEYCLOAK_ADMIN_USER} ${KEYCLOAK_ADMIN_PASSWORD} ${SMTP_HOST} ${SMTP_PORT} ${SMTP_FROM} ${SMTP_USER} ${SMTP_PASSWORD}'

    bash "$PROJECT_ROOT/scripts/keycloak-blue-green-deploy.sh"
}

# ============================================
# 函数: pipeline_deploy_nginx
# ============================================
# Nginx docker compose recreate（秒级中断，非零停机）
# 保存当前镜像 digest 用于回滚
# 返回: 0=成功，1=失败
pipeline_deploy_nginx()
{
    log_info "Nginx 重建部署（docker compose recreate）"

    # 保存当前镜像 digest（用于回滚）
    INFRA_ROLLBACK_IMAGE=$(docker inspect --format='{{.Image}}' noda-infra-nginx 2>/dev/null || echo "")
    export INFRA_ROLLBACK_IMAGE
    if [ -n "$INFRA_ROLLBACK_IMAGE" ]; then
        log_info "保存当前镜像: ${INFRA_ROLLBACK_IMAGE:0:12}..."
    fi

    docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
        up -d --force-recreate --no-deps nginx

    # 等待 Docker DNS 就绪（per D-02）
    log_info "等待 Docker DNS 就绪..."
    sleep 5

    # 触发 DNS 重新解析（per D-02）
    log_info "触发 nginx DNS 重新解析..."
    if ! docker exec noda-infra-nginx nginx -s reload; then
        log_error "nginx reload 失败，DNS 可能未就绪"
        return 1
    fi
    log_success "nginx DNS 刷新完成"

    log_success "Nginx 重建完成"
}

# ============================================
# 函数: pipeline_deploy_noda_ops
# ============================================
# noda-ops docker compose recreate（使用 build 模式）
# 保存当前镜像 digest 用于回滚
# 返回: 0=成功，1=失败
pipeline_deploy_noda_ops()
{
    log_info "noda-ops 重建部署（docker compose recreate）"

    INFRA_ROLLBACK_IMAGE=$(docker inspect --format='{{.Image}}' noda-ops 2>/dev/null || echo "")
    export INFRA_ROLLBACK_IMAGE
    if [ -n "$INFRA_ROLLBACK_IMAGE" ]; then
        log_info "保存当前镜像: ${INFRA_ROLLBACK_IMAGE:0:12}..."
    fi

    # noda-ops 使用 build 模式，需要 --build
    docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
        up -d --build --force-recreate --no-deps noda-ops

    log_success "noda-ops 重建完成"
}

# ============================================
# 函数: pipeline_deploy_postgres
# ============================================
# Postgres compose restart（需要备份+人工确认已完成）
# 无需保存镜像（restart 不更换镜像）
# 返回: 0=成功，1=失败
pipeline_deploy_postgres()
{
    log_info "PostgreSQL 重启部署（docker compose restart）"

    docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
        restart postgres

    log_success "PostgreSQL 重启完成"
}

# ============================================
# 函数: pipeline_infra_health_check
# ============================================
# 服务专属健康检查
# 参数: $1 = SERVICE
# 返回: 0=健康，1=不健康
pipeline_infra_health_check()
{
    local service="$1"

    case "$service" in
        keycloak)
            # 由 keycloak-blue-green-deploy.sh 内部处理健康检查
            # 此处做二次验证：检查新容器确实在运行
            local active_env
            active_env=$(cat /opt/noda/active-env-keycloak 2>/dev/null || echo "blue")
            wait_container_healthy "keycloak-${active_env}" 180
            ;;
        nginx)
            # nginx -t 验证配置 + wait_container_healthy
            docker exec noda-infra-nginx nginx -t
            wait_container_healthy "noda-infra-nginx" 30
            ;;
        noda-ops)
            # 容器 running 即可（无 HTTP 端点）
            wait_container_healthy "noda-ops" 60
            ;;
        postgres)
            # pg_isready 验证数据库可连接 + wait_container_healthy
            docker exec noda-infra-postgres-prod pg_isready -h localhost -p 5432
            wait_container_healthy "noda-infra-postgres-prod" 90
            ;;
        *)
            log_error "未知服务: $service"
            return 1
            ;;
    esac
}

# ============================================
# 函数: pipeline_infra_rollback
# ============================================
# 服务专属回滚
# 参数: $1 = SERVICE
# 环境变量: INFRA_ROLLBACK_IMAGE（nginx/noda-ops 回滚镜像 digest）
#           INFRA_BACKUP_FILE（postgres 回滚备份文件）
# 返回: 0=回滚成功，1=回滚失败
pipeline_infra_rollback()
{
    local service="$1"

    log_info "回滚: $service"

    case "$service" in
        keycloak)
            # 读取当前活跃环境，切回旧环境
            local active_env
            active_env=$(cat /opt/noda/active-env-keycloak 2>/dev/null || echo "blue")
            local inactive_env
            if [ "$active_env" = "blue" ]; then
                inactive_env="green"
            else
                inactive_env="blue"
            fi
            update_upstream "$inactive_env"
            docker exec "$NGINX_CONTAINER" nginx -t
            reload_nginx
            set_active_env "$inactive_env"
            log_success "Keycloak 回滚完成: 切回 $inactive_env"
            ;;
        nginx)
            if [ -z "${INFRA_ROLLBACK_IMAGE:-}" ]; then
                log_error "无回滚镜像信息（INFRA_ROLLBACK_IMAGE 未设置）"
                return 1
            fi
            log_info "回滚 Nginx 到镜像: ${INFRA_ROLLBACK_IMAGE:0:12}..."
            local rollback_compose
            rollback_compose=$(mktemp)
            cat >"$rollback_compose" <<YAML
# 自动生成的回滚 overlay — 恢复 Nginx 到部署前的镜像
name: noda-infra
services:
  nginx:
    image: ${INFRA_ROLLBACK_IMAGE}
YAML
            docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
                -f "$rollback_compose" up -d --force-recreate --no-deps nginx
            rm -f "$rollback_compose"
            log_success "Nginx 回滚完成"
            ;;
        noda-ops)
            if [ -z "${INFRA_ROLLBACK_IMAGE:-}" ]; then
                log_error "无回滚镜像信息（INFRA_ROLLBACK_IMAGE 未设置）"
                return 1
            fi
            log_info "回滚 noda-ops 到镜像: ${INFRA_ROLLBACK_IMAGE:0:12}..."
            local rollback_compose
            rollback_compose=$(mktemp)
            cat >"$rollback_compose" <<YAML
# 自动生成的回滚 overlay — 恢复 noda-ops 到部署前的镜像
name: noda-infra
services:
  noda-ops:
    image: ${INFRA_ROLLBACK_IMAGE}
YAML
            docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
                -f "$rollback_compose" up -d --force-recreate --no-deps noda-ops
            rm -f "$rollback_compose"
            log_success "noda-ops 回滚完成"
            ;;
        postgres)
            if [ -z "${INFRA_BACKUP_FILE:-}" ]; then
                log_error "无备份文件（INFRA_BACKUP_FILE 未设置），无法回滚"
                return 1
            fi
            if [ ! -f "$INFRA_BACKUP_FILE" ]; then
                log_error "备份文件不存在: $INFRA_BACKUP_FILE"
                return 1
            fi
            log_info "从备份恢复 PostgreSQL: $INFRA_BACKUP_FILE"
            gunzip -c "$INFRA_BACKUP_FILE" | docker exec -i noda-infra-postgres-prod psql -U postgres
            # 恢复后验证
            docker exec noda-infra-postgres-prod pg_isready -h localhost -p 5432
            log_success "PostgreSQL 恢复完成"
            ;;
        *)
            log_error "未知服务: $service"
            return 1
            ;;
    esac
}

# ============================================
# 函数: pipeline_infra_verify
# ============================================
# 部署后验证
# 参数: $1 = SERVICE
# 返回: 0=验证通过，1=验证失败
pipeline_infra_verify()
{
    local service="$1"

    case "$service" in
        keycloak)
            # 由 keycloak-blue-green-deploy.sh 内部已做 E2E，此处 skip
            log_info "Keycloak E2E 验证已由蓝绿脚本内部完成"
            ;;
        nginx)
            # 通过 nginx 容器 wget 自身验证
            docker exec "$NGINX_CONTAINER" wget --quiet --tries=1 --spider http://localhost/ 2>/dev/null
            log_success "Nginx E2E 验证通过"
            ;;
        noda-ops)
            # 验证容器运行中
            local running
            running=$(docker ps --filter name=noda-ops --filter status=running --format '{{.Names}}')
            if [ -z "$running" ]; then
                log_error "noda-ops 容器未运行"
                return 1
            fi
            log_success "noda-ops 验证通过: 容器运行中"
            ;;
        postgres)
            # pg_isready 验证
            docker exec noda-infra-postgres-prod pg_isready -h localhost -p 5432
            log_success "PostgreSQL 验证通过"
            ;;
        *)
            log_error "未知服务: $service"
            return 1
            ;;
    esac
}

# ============================================
# 函数: pipeline_infra_cleanup
# ============================================
# 部署后清理（备份文件保留）
# 参数: $1 = SERVICE
# 返回: 0=成功
pipeline_infra_cleanup()
{
    local service="$1"

    # 创建备份目录索引（用于审计）
    ls -la "${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}/infra-pipeline/${service}/" 2>/dev/null || true

    case "$service" in
        keycloak)
            cleanup_dangling
            ;;
        nginx)
            log_info "$service 无需额外清理（dangling 清理由通用 wrapper 处理）"
            ;;
        noda-ops)
            cleanup_by_date_threshold "noda-ops"
            ;;
        postgres)
            log_info "PostgreSQL 无需额外清理"
            ;;
        *)
            log_info "未知服务: $service，跳过清理"
            ;;
    esac

    # === 基础设施部署后全面清理（per D-03）===
    cleanup_after_infra_deploy "$service" "${WORKSPACE:-$PWD}"
}

# ============================================
# 函数: pipeline_infra_failure_cleanup
# ============================================
# 部署失败清理（捕获日志 + 尝试自动回滚）
# 参数: $1 = SERVICE
# 返回: 0=清理完成
pipeline_infra_failure_cleanup()
{
    local service="$1"

    # 捕获目标服务容器日志
    local container_name
    case "$service" in
        keycloak)
            local active_env
            active_env=$(cat /opt/noda/active-env-keycloak 2>/dev/null || echo "blue")
            container_name="keycloak-${active_env}"
            ;;
        nginx)
            container_name="noda-infra-nginx"
            ;;
        noda-ops)
            container_name="noda-ops"
            ;;
        postgres)
            container_name="noda-infra-postgres-prod"
            ;;
        *)
            container_name="$service"
            ;;
    esac

    docker logs "$container_name" --tail 50 >deploy-failure-infra.log 2>&1 || true
    docker logs "$NGINX_CONTAINER" --tail 50 >deploy-failure-nginx.log 2>&1 || true

    # 尝试自动回滚
    pipeline_infra_rollback "$service" || true

    log_info "失败日志已保存"
}

# ============================================
# Source guard — 仅允许 source 加载，禁止直接执行
# ============================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "pipeline-stages.sh 是函数库，不支持直接执行"
    echo "请通过 Jenkinsfile 或 blue-green-deploy.sh 调用"
    exit 1
fi
