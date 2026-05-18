#!/bin/bash
set -euo pipefail

# ============================================
# Jenkins Pipeline 阶段函数库
# ============================================
# 功能：封装 Jenkinsfile Pipeline 所需的 bash 函数
# 用途：Jenkinsfile 通过 source 加载此文件，调用 pipeline_* 函数
# 依赖：scripts/lib/log.sh, scripts/lib/health.sh, scripts/lib/secrets.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/remote-ops.sh"
source "$PROJECT_ROOT/scripts/lib/health.sh"
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
BACKUP_HOST_DIR="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-12}"
IMAGE_RETENTION_DAYS="${IMAGE_RETENTION_DAYS:-7}"

# 部署目标配置（per D-04）
DEPLOY_TARGET="${DEPLOY_TARGET:-local}"  # local 或 r4s
R4S_HOST="${R4S_HOST:-root@192.168.1.1}"  # r4s 主机

# 固定容器名 / 网络 / Nginx 容器
NETWORK_NAME="noda-network"
NGINX_CONTAINER="noda-infra-nginx"
PROD_CONTAINER="noda-apps-prod"

# ============================================
# 辅助函数（从 manage-containers.sh 内联）
# ============================================

# is_container_running - 检查容器是否在运行
# 参数：$1 = 容器名
# 返回：true 或 false（通过 echo 输出）
is_container_running()
{
    local name="$1"
    local running
    running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")
    echo "$running"
}

# get_host_snippets_dir - 获取 nginx snippets 目录在宿主机上的实际路径
get_host_snippets_dir()
{
    local host_path
    host_path=$(docker inspect "$NGINX_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/snippets"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
    if [ -n "$host_path" ] && [ -d "$host_path" ]; then
        echo "$host_path"
        return
    fi
    echo "$PROJECT_ROOT/config/nginx/snippets"
}

# reload_nginx - 重载 nginx 配置
reload_nginx()
{
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程模式
        if [ "$(remote_exec "docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER")" != "true" ]; then
            log_error "nginx 容器（r4s）($NGINX_CONTAINER) 未运行"
            return 1
        fi
        remote_docker_exec "$NGINX_CONTAINER" "nginx -s reload"
        log_success "nginx 配置已重载（r4s）"
    else
        # 本地模式（原有逻辑）
        if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
            log_error "nginx 容器 ($NGINX_CONTAINER) 未运行"
            return 1
        fi
        docker exec "$NGINX_CONTAINER" nginx -s reload
        log_success "nginx 配置已重载"
    fi
}

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
        log_error "未找到任何备份文件 (查找路径: ${backup_dir})"
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

    # 远程部署模式初始化（per D-04）
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # SSH 密钥由 Jenkins withCredentials 注入（per D-05）
        SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_rsa_noda_deploy}"
        setup_remote "$SSH_KEY_FILE" "$R4S_HOST"
        log_info "远程部署模式: $R4S_HOST"

        # 获取部署锁（per D-19/D-20）
        if ! acquire_deploy_lock 3600; then
            log_error "无法获取部署锁，可能有其他部署进行中"
            return 1
        fi
        log_info "部署锁获取成功"
        # 在 r4s 上同步最新代码（per D-08/D-10）
        log_info "同步 r4s 仓库..."
        if ! remote_exec "cd /opt/noda/noda-infra && git pull origin main"; then
            log_error "r4s 仓库同步失败"
            return 1
        fi
        log_info "r4s 仓库同步完成"
    fi

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

    local service="${SERVICE_NAME:-noda-apps}"

    # noda-apps 目录仅对从源码构建的服务需要（noda-apps）
    # Keycloak 等使用官方镜像的服务不需要
    if [ "$service" != "keycloak" ]; then
        if [ ! -d "$apps_dir" ]; then
            log_error "noda-apps 目录不存在: $apps_dir"
            log_error "请检查 Jenkinsfile Pre-flight stage 的 checkout 配置"
            return 1
        fi
        log_info "noda-apps 目录存在: $apps_dir"
    fi

    if [ "$service" = "noda-apps" ]; then
        # noda-apps 专用检查：Node.js、pnpm、package.json、lint、test、备份
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
            # 其他服务：检查 Dockerfile 存在
            local dockerfile="${DOCKERFILE:-$PROJECT_ROOT/noda-apps/infra/docker/Dockerfile.${service}}"
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
#   SERVICE_NAME - 镜像名（默认 noda-apps）
#   DOCKERFILE   - Dockerfile 路径（默认 noda-apps/infra/docker/Dockerfile.noda-apps）
pipeline_build()
{
    local apps_dir="$1"
    local git_sha="$2"

    local service="${SERVICE_NAME:-noda-apps}"
    local dockerfile="${DOCKERFILE:-$PROJECT_ROOT/noda-apps/infra/docker/Dockerfile.noda-apps}"

    log_info "构建镜像..."

    # r4s 远程部署模式：镜像将在 Mac 构建后通过 SSH 传输到 r4s（per D-07）
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        log_info "r4s 远程部署模式：镜像将在 Mac 构建后通过 SSH 传输到 r4s（per D-07）"
    fi
    if [ "$service" = "noda-apps" ]; then
        docker build \
            -t "${service}:latest" \
            -t "${service}:${git_sha}" \
            -f "$dockerfile" \
            --build-arg NEXT_PUBLIC_KEYCLOAK_URL=https://auth.noda.co.nz \
            --build-arg NEXT_PUBLIC_KEYCLOAK_REALM=noda \
            --build-arg NEXT_PUBLIC_KEYCLOAK_CLIENT_ID=noda-frontend \
            --build-arg NEXT_PUBLIC_AUTH_KEYCLOAK_CLIENT_ID=noda-auth \
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

# ============================================
# 函数: pipeline_deploy_prod
# ============================================
# 生产环境直接替换部署：停旧容器 -> 启新容器 -> 健康检查
# 参数: $1 = GIT_SHA
pipeline_deploy_prod()
{
    local git_sha="$1"
    local image="noda-apps:${git_sha}"

    disk_snapshot "部署前"

    log_info "生产环境部署: $PROD_CONTAINER ($image)"

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式
        log_info "r4s 远程部署模式：传输镜像到 r4s..."
        transfer_image "$image" "$image"

        # 停止并移除旧容器（远程）
        if remote_exec "docker inspect $PROD_CONTAINER >/dev/null 2>&1"; then
            if [ "$(remote_exec "docker inspect -f '{{.State.Running}}' $PROD_CONTAINER")" = "true" ]; then
                log_info "停止旧容器（r4s）: $PROD_CONTAINER"
                remote_exec "docker stop -t 30 $PROD_CONTAINER || true"
                remote_exec "docker rm $PROD_CONTAINER || true"
            else
                remote_exec "docker rm $PROD_CONTAINER || true"
            fi
        fi

        # 准备 env 文件（本地生成，传输到 r4s）
        local tmp_env
        tmp_env=$(prepare_prod_env_file)
        log_info "传输 env 文件到 r4s..."
        cat "$tmp_env" | remote_exec "cat > /tmp/prod.env"

        # 启动新容器（远程）
        log_info "启动容器（r4s）: $PROD_CONTAINER ($image)"
        remote_exec "docker run -d \
            --name $PROD_CONTAINER \
            --network $NETWORK_NAME \
            --network-alias $PROD_CONTAINER \
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
            --env-file /tmp/prod.env \
            --label com.docker.compose.project=noda-apps \
            --label com.docker.compose.service=noda-apps \
            --label noda.service-group=apps \
            --label noda.environment=prod \
            --health-cmd \"node -e \\\"fetch('http://localhost:3000/api/health').then(r=>{process.exit(r.ok?0:1)}).catch(()=>process.exit(1))\\\"\" \
            --health-interval 30s \
            --health-timeout 10s \
            --health-retries 3 \
            --health-start-period 60s \
            $image"

        rm -f "$tmp_env"

        # reload nginx（远程）
        reload_nginx

        # 健康检查（远程模式）
        log_info "等待容器健康检查（r4s 远程）..."
        wait_container_healthy "$PROD_CONTAINER" "$((HEALTH_CHECK_MAX_RETRIES * HEALTH_CHECK_INTERVAL))" true true

        log_success "生产环境部署完成（r4s）: $PROD_CONTAINER ($image)"
    else
        # 本地模式（原有逻辑）
        # 停止并移除旧容器
        if [ "$(is_container_running "$PROD_CONTAINER")" = "true" ]; then
            log_info "停止旧容器: $PROD_CONTAINER"
            docker stop -t 30 "$PROD_CONTAINER"
            docker rm "$PROD_CONTAINER"
        elif docker inspect "$PROD_CONTAINER" >/dev/null 2>&1; then
            # 容器存在但未运行
            docker rm "$PROD_CONTAINER"
        fi

        # 准备 env 文件
        local tmp_env
        tmp_env=$(prepare_prod_env_file)

        # 启动新容器
        log_info "启动容器: $PROD_CONTAINER ($image)"

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
            --label "com.docker.compose.project=noda-apps" \
            --label "com.docker.compose.service=noda-apps" \
            --label "noda.service-group=apps" \
            --label noda.environment=prod \
            --health-cmd "node -e \"fetch('http://localhost:3000/api/health').then(r=>{process.exit(r.ok?0:1)}).catch(()=>process.exit(1))\"" \
            --health-interval 30s \
            --health-timeout 10s \
            --health-retries 3 \
            --health-start-period 60s \
            "$image"

        rm -f "$tmp_env"

        # reload nginx 刷新 DNS 缓存（容器重建后 IP 会变）
        reload_nginx

        # 健康检查
        log_info "等待容器健康检查..."
        wait_container_healthy "$PROD_CONTAINER" "$((HEALTH_CHECK_MAX_RETRIES * HEALTH_CHECK_INTERVAL))"

        log_success "生产环境部署完成: $PROD_CONTAINER ($image)"
    fi
}

# ============================================
# 函数: prepare_prod_env_file
# ============================================
# 生成生产环境变量文件
# 返回: 临时 env 文件路径（通过 echo 输出）
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
    echo "$tmp_file"
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

# pipeline_cleanup - 清理旧镜像
# 官方镜像服务（Keycloak 等）跳过 SHA 镜像清理，仅清理 dangling images
pipeline_cleanup()
{
    # 官方镜像服务（Keycloak 等）不需要 SHA 镜像清理
    if [ -z "${SERVICE_IMAGE:-}" ]; then
        cleanup_by_date_threshold "${SERVICE_NAME:-noda-apps}" "${IMAGE_RETENTION_DAYS:-7}"
    else
        # 仅清理 dangling images
        cleanup_dangling
    fi

    # === 部署后全面清理（per D-03）===
    cleanup_after_deploy "${WORKSPACE:-$PWD}"
}

# pipeline_failure_cleanup - 部署失败时捕获日志并清理
pipeline_failure_cleanup()
{
    # 捕获目标容器日志（如果容器存在）
    docker logs "$PROD_CONTAINER" >deploy-failure-container.log 2>&1 || true

    # 捕获 nginx 日志
    docker logs "$NGINX_CONTAINER" --tail 50 >deploy-failure-nginx.log 2>&1 || true

    # 清理失败的目标容器
    docker rm -f "$PROD_CONTAINER" 2>/dev/null || true

    log_info "失败日志已保存: deploy-failure-container.log, deploy-failure-nginx.log"
}

# ============================================
# 基础设施服务 Pipeline 函数
# ============================================
# 用于 Jenkinsfile.infra 统一基础设施 Pipeline
# 支持 4 种服务: keycloak, nginx, noda-ops, postgres
# 每种服务使用独立的部署/健康检查策略
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

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程模式：检查远程 Docker daemon
        log_info "r4s 远程模式前置检查..."
        remote_exec "docker info >/dev/null 2>&1" || {
            log_error "r4s Docker daemon 不可用"
            return 1
        }
        log_info "r4s Docker daemon 可用"

        # 检查远程 nginx 容器（部署 nginx 本身时自动启动）
        local running
        running=$(remote_exec "docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER 2>/dev/null || echo false")
        if [ "$running" != "true" ]; then
            if [ "$service" = "nginx" ]; then
                log_info "nginx 容器未运行，正在通过 docker compose 启动（r4s 远程）..."
                remote_compose "up -d --no-deps nginx" \
                    "-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.r4s.yml" || {
                    log_error "docker compose 启动 nginx 失败（r4s）"
                    return 1
                }
                # 等待 nginx 就绪
                local _wait=0
                while [ "$_wait" -lt 30 ]; do
                    running=$(remote_exec "docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER 2>/dev/null || echo false")
                    if [ "$running" = "true" ]; then
                        log_info "nginx 容器已启动（等待 ${_wait} 秒）"
                        break
                    fi
                    sleep 1
                    _wait=$((_wait + 1))
                done
                running=$(remote_exec "docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER 2>/dev/null || echo false")
                if [ "$running" != "true" ]; then
                    log_error "nginx 启动超时（30秒）"
                    return 1
                fi
            else
                log_error "nginx 容器未运行（请先通过 infra-deploy Pipeline 部署 nginx）"
                return 1
            fi
        else
            log_info "nginx 容器运行中（r4s）"
        fi

        # 检查远程 noda-network
        remote_exec "docker network inspect $NETWORK_NAME >/dev/null 2>&1" || {
            log_error "r4s Docker 网络 $NETWORK_NAME 不存在"
            return 1
        }
        log_info "r4s Docker 网络 $NETWORK_NAME 存在"

        # 服务专属检查（r4s 模式）
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
                # 检查 postgres 容器是否 running（远程）
                running=$(remote_exec "docker inspect -f '{{.State.Running}}' noda-infra-postgres-prod 2>/dev/null || echo false")
                if [ "$running" != "true" ]; then
                    log_error "noda-infra-postgres-prod 容器未运行（r4s）"
                    return 1
                fi
                log_info "noda-infra-postgres-prod 容器运行中（r4s）"
                ;;
            *)
                log_error "未知服务: $service"
                return 1
                ;;
        esac
    else
        # 本地模式：保持现有逻辑
        # 检查 Docker daemon
        docker info >/dev/null 2>&1 || {
            log_error "Docker daemon 不可用"
            return 1
        }
        log_info "Docker daemon 可用"

        # 检查 nginx 容器（部署 nginx 本身时自动启动）
        if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
            if [ "$service" = "nginx" ]; then
                log_info "nginx 容器未运行，正在通过 docker compose 启动..."
                docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d --no-deps nginx || {
                    log_error "docker compose 启动 nginx 失败"
                    return 1
                }
                # 等待 nginx 就绪
                local _wait=0
                while [ "$_wait" -lt 30 ]; do
                    if [ "$(is_container_running "$NGINX_CONTAINER")" = "true" ]; then
                        log_info "nginx 容器已启动（等待 ${_wait} 秒）"
                        break
                    fi
                    sleep 1
                    _wait=$((_wait + 1))
                done
                if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
                    log_error "nginx 启动超时（30秒）"
                    return 1
                fi
            else
                log_error "nginx 容器未运行（请先通过 infra-deploy Pipeline 部署 nginx）"
                return 1
            fi
        else
            log_info "nginx 容器运行中"
        fi

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
    fi

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
    
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程模式：备份文件存储在 r4s 上
        local backup_dir="/opt/noda/noda-infra/docker/volumes/backup/infra-pipeline/${service}"
        local timestamp
        timestamp=$(date +"%Y%m%d-%H%M%S")
        local backup_file="${backup_dir}/${timestamp}.sql.gz"

        # nginx/noda-ops 不需要备份
        if [ "$service" != "keycloak" ] && [ "$service" != "postgres" ]; then
            log_info "$service 不需要备份（无持久化数据）"
            return 0
        fi

        # 在 r4s 上创建备份目录
        remote_exec "mkdir -p $backup_dir"

        log_info "部署前备份（r4s）: $service -> $backup_file"

        if [ "$service" = "keycloak" ]; then
            remote_docker_exec "noda-infra-postgres-prod" \
                "pg_dump -U postgres --clean --if-exists keycloak | gzip > ${backup_file}/${timestamp}.sql.gz"
        elif [ "$service" = "postgres" ]; then
            remote_docker_exec "noda-infra-postgres-prod" \
                "pg_dumpall -U postgres --clean --if-exists | gzip > ${backup_file}/${timestamp}.sql.gz"
        fi

        # 验证备份文件大小 > 1KB（在 r4s 上检查）
        local file_size
        file_size=$(remote_exec "stat -c%s ${backup_file}/${timestamp}.sql.gz 2>/dev/null || echo 0")
        if [ "$file_size" -lt 1024 ]; then
            log_error "备份文件异常（${file_size} 字节），中止部署"
            return 1
        fi

        log_success "备份完成（r4s）: $backup_file (${file_size} bytes)"
        INFRA_BACKUP_FILE="$backup_file"
        export INFRA_BACKUP_FILE
    else
        # 本地模式：保持现有逻辑
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
    fi
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
            pipeline_deploy_keycloak_prod
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
# 函数: pipeline_deploy_keycloak_prod
# ============================================
# Keycloak 直接替换部署（docker stop/rm/run）
# 不再使用蓝绿部署
# 返回: 0=成功，1=失败
pipeline_deploy_keycloak_prod()
{
    local container_name="noda-infra-keycloak"
    local image="${SERVICE_IMAGE:-quay.io/keycloak/keycloak:26.2.3}"

    log_info "Keycloak 直接替换部署: $container_name ($image)"

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式
        # 停止并移除旧容器（远程）
        local running
        running=$(remote_exec "docker inspect -f '{{.State.Running}}' $container_name 2>/dev/null || echo false")
        if [ "$running" = "true" ]; then
            log_info "停止旧容器（r4s）: $container_name"
            remote_exec "docker stop -t 30 $container_name || true"
            remote_exec "docker rm $container_name || true"
        elif remote_exec "docker inspect $container_name >/dev/null 2>&1"; then
            remote_exec "docker rm $container_name || true"
        fi

        # 准备 env 文件（本地生成，传输到 r4s）
        local tmp_env
        tmp_env=$(prepare_keycloak_env_file)
        log_info "传输 env 文件到 r4s..."
        cat "$tmp_env" | remote_exec "cat > /tmp/keycloak.env"

        # 拉取官方镜像（在 r4s 上，per D-07）
        log_info "拉取 Keycloak 镜像（r4s）: $image"
        remote_exec "docker pull $image"

        # 启动新容器（远程）
        log_info "启动容器（r4s）: $container_name ($image)"
        remote_exec "docker run -d \
            --name $container_name \
            --network $NETWORK_NAME \
            --network-alias $container_name \
            --restart unless-stopped \
            --stop-timeout 30 \
            --security-opt no-new-privileges \
            --cap-drop ALL \
            -v /opt/noda/noda-infra/docker/services/keycloak/themes:/opt/keycloak/themes/noda:ro \
            --tmpfs /opt/keycloak/data \
            --memory 1g \
            --memory-reservation 512m \
            --cpus 1 \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --env-file /tmp/keycloak.env \
            --label com.docker.compose.project=noda-infra \
            --label com.docker.compose.service=keycloak \
            --label noda.service-group=infra \
            --label noda.environment=prod \
            --health-cmd \"echo > /dev/tcp/localhost/8080 2>/dev/null || exit 1\" \
            --health-interval 10s \
            --health-timeout 5s \
            --health-retries 10 \
            --health-start-period 60s \
            $image \
            start --hostname-strict=false --proxy-headers=xforwarded"

        rm -f "$tmp_env"

        # reload nginx（远程）
        reload_nginx

        log_success "Keycloak 部署完成（r4s）: $container_name ($image)"
    else
        # 本地模式：保持现有逻辑
        # 停止并移除旧容器
        if [ "$(is_container_running "$container_name")" = "true" ]; then
            log_info "停止旧容器: $container_name"
            docker stop -t 30 "$container_name"
            docker rm "$container_name"
        elif docker inspect "$container_name" >/dev/null 2>&1; then
            docker rm "$container_name"
        fi

        # 准备 env 文件
        local tmp_env
        tmp_env=$(prepare_keycloak_env_file)

        # 启动新容器
        log_info "启动容器: $container_name ($image)"

        docker run -d \
            --name "$container_name" \
            --network "$NETWORK_NAME" \
            --network-alias "$container_name" \
            --restart unless-stopped \
            --stop-timeout 30 \
            --security-opt no-new-privileges \
            --cap-drop ALL \
            -v "$PROJECT_ROOT/docker/services/keycloak/themes:/opt/keycloak/themes/noda:ro" \
            --tmpfs /opt/keycloak/data \
            --memory 1g \
            --memory-reservation 512m \
            --cpus 1 \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --env-file "$tmp_env" \
            --label "com.docker.compose.project=noda-infra" \
            --label "com.docker.compose.service=keycloak" \
            --label "noda.service-group=infra" \
            --label noda.environment=prod \
            --health-cmd "echo > /dev/tcp/localhost/8080 2>/dev/null || exit 1" \
            --health-interval 10s \
            --health-timeout 5s \
            --health-retries 10 \
            --health-start-period 60s \
            "$image" \
            start --hostname-strict=false --proxy-headers=xforwarded

        rm -f "$tmp_env"

        # reload nginx 刷新 DNS 缓存（容器重建后 IP 会变）
        reload_nginx

        log_success "Keycloak 部署完成: $container_name ($image)"
    fi
}


# ============================================
# 函数: prepare_keycloak_env_file
# ============================================
# 生成 Keycloak 环境变量文件
# 返回: 临时 env 文件路径（通过 echo 输出）
prepare_keycloak_env_file()
{
    local tmp_file="/tmp/keycloak-prod.env.$$"
    local env_template="$PROJECT_ROOT/docker/env-keycloak.env"

    if [ ! -f "$env_template" ]; then
        log_error "Keycloak env 模板文件不存在: $env_template"
        return 1
    fi

    local vars='${POSTGRES_USER} ${POSTGRES_PASSWORD} ${KEYCLOAK_ADMIN_USER} ${KEYCLOAK_ADMIN_PASSWORD} ${SMTP_HOST} ${SMTP_PORT} ${SMTP_FROM} ${SMTP_USER} ${SMTP_PASSWORD}'
    envsubst "$vars" <"$env_template" >"$tmp_file"
    echo "$tmp_file"
}

# ============================================
# 函数: pipeline_deploy_nginx
# ============================================
# Nginx docker compose recreate（秒级中断，非零停机）
# 返回: 0=成功，1=失败
pipeline_deploy_nginx()
{
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式
        log_info "Nginx 重建部署（r4s 远程 docker compose recreate）"

        # 先停止并移除旧容器，再创建新容器
        log_info "停止旧 nginx 容器（r4s）..."
        remote_exec "docker stop noda-infra-nginx 2>/dev/null || true"
        remote_exec "docker rm noda-infra-nginx 2>/dev/null || true"

        remote_compose "up -d --no-deps nginx" \
            "-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.r4s.yml"

        # 等待 nginx 容器启动
        log_info "等待 nginx 容器就绪（r4s）..."
        local _max_wait=30
        local _elapsed=0
        while [ $_elapsed -lt $_max_wait ]; do
            local _running
            _running=$(remote_exec "docker inspect --format='{{.State.Running}}' noda-infra-nginx 2>/dev/null || echo false")
            if [ "$_running" = "true" ]; then
                log_info "nginx 容器已就绪（等待 ${_elapsed} 秒）"
                break
            fi
            sleep 1
            _elapsed=$((_elapsed + 1))
        done
        if [ $_elapsed -ge $_max_wait ]; then
            log_error "nginx 容器未在 ${_max_wait} 秒内就绪（r4s）"
            remote_exec "docker logs noda-infra-nginx --tail 20 2>/dev/null || true"
            return 1
        fi

        log_success "Nginx 重建完成（r4s）"
    else
        # 本地模式：保持现有逻辑
        log_info "Nginx 重建部署（docker compose recreate）"

        # 先停止并移除旧容器，再创建新容器
        # 不使用 --force-recreate：该选项在新容器创建时网络连接尚未就绪，
        # 导致 nginx 解析 upstream DNS 失败并进入 restart 循环
        log_info "停止旧 nginx 容器..."
        docker stop noda-infra-nginx 2>/dev/null || true
        docker rm noda-infra-nginx 2>/dev/null || true

        docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
            up -d --no-deps nginx

        # 等待 nginx 容器启动
        log_info "等待 nginx 容器就绪..."
        local _max_wait=30
        local _elapsed=0
        while [ $_elapsed -lt $_max_wait ]; do
            local _running
            _running=$(docker inspect --format='{{.State.Running}}' noda-infra-nginx 2>/dev/null || echo "false")
            if [ "$_running" = "true" ]; then
                log_info "nginx 容器已就绪（等待 ${_elapsed} 秒）"
                break
            fi
            sleep 1
            _elapsed=$((_elapsed + 1))
        done
        if [ $_elapsed -ge $_max_wait ]; then
            log_error "nginx 容器未在 ${_max_wait} 秒内就绪"
            docker logs noda-infra-nginx --tail 20 2>/dev/null || true
            return 1
        fi

        log_success "Nginx 重建完成"
    fi
}


# ============================================
# 函数: pipeline_deploy_noda_ops
# ============================================
# noda-ops docker compose recreate（使用 build 模式）
# 返回: 0=成功，1=失败
pipeline_deploy_noda_ops()
{
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式
        log_info "noda-ops 重建部署（r4s 远程）"

        # 在 Mac 上构建 noda-ops 镜像（保持现有逻辑）
        log_info "构建 noda-ops 镜像（Mac 本地）..."
        docker build -t noda-ops:latest -f docker/Dockerfile.noda-ops .

        # 传输镜像到 r4s
        log_info "传输 noda-ops 镜像到 r4s..."
        transfer_image "noda-ops:latest" "noda-ops:latest"

        # 从 Doppler Cloud 拉取密钥（在 Mac 上，per D-22）
        local secrets_file
        secrets_file=$(mktemp /tmp/noda-ops-secrets.XXXXXX.env)
        doppler secrets download --project noda --config prd --format env --no-file "$secrets_file"
        log_info "已从 Doppler 拉取密钥: $(grep -c '=' "$secrets_file") 个变量"

        # 传输密钥文件到 r4s
        log_info "传输密钥文件到 r4s..."
        cat "$secrets_file" | remote_exec "cat > /tmp/noda-ops-secrets.env"
        rm -f "$secrets_file"

        # 在 r4s 上启动容器（使用 --build 标志）
        remote_exec "docker compose --env-file /tmp/noda-ops-secrets.env \
            -f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.r4s.yml \
            up -d --build --force-recreate --no-deps noda-ops"

        log_success "noda-ops 重建完成（r4s）"
    else
        # 本地模式：保持现有逻辑
        log_info "noda-ops 重建部署（docker compose recreate）"

        # 从 Doppler Cloud 拉取密钥（B2、PostgreSQL、Cloudflare 等）
        local secrets_file
        secrets_file=$(mktemp /tmp/noda-ops-secrets.XXXXXX.env)
        doppler secrets download --project noda --config prd --format env --no-file "$secrets_file"
        log_info "已从 Doppler 拉取密钥: $(grep -c '=' "$secrets_file") 个变量"

        # noda-ops 使用 build 模式，需要 --build
        docker compose --env-file "$secrets_file" \
            -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
            up -d --build --force-recreate --no-deps noda-ops

        rm -f "$secrets_file"
        log_success "noda-ops 重建完成"
    fi
}


# ============================================
# 函数: pipeline_deploy_postgres
# ============================================
# Postgres compose restart（需要备份+人工确认已完成）
# 无需保存镜像（restart 不更换镜像）
# 返回: 0=成功，1=失败
pipeline_deploy_postgres()
{
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式
        log_info "PostgreSQL 重启部署（r4s 远程 docker compose restart）"
        
        remote_compose "restart postgres" \
            "-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.r4s.yml"
        
        log_success "PostgreSQL 重启完成（r4s）"
    else
        # 本地模式：保持现有逻辑
        log_info "PostgreSQL 重启部署（docker compose restart）"

        docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
            restart postgres

        log_success "PostgreSQL 重启完成"
    fi
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

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程健康检查模式
        case "$service" in
            keycloak)
                wait_container_healthy "noda-infra-keycloak" 300 true true
                ;;
            nginx)
                # nginx -t 验证配置 + wait_container_healthy（远程）
                remote_docker_exec "noda-infra-nginx" "nginx -t"
                wait_container_healthy "noda-infra-nginx" 30 true true
                ;;
            noda-ops)
                # 容器 running 即可（无 HTTP 端点）
                wait_container_healthy "noda-ops" 60 true true
                ;;
            postgres)
                # pg_isready 验证数据库可连接 + wait_container_healthy（远程）
                remote_docker_exec "noda-infra-postgres-prod" "pg_isready -h localhost -p 5432"
                wait_container_healthy "noda-infra-postgres-prod" 90 true true
                ;;
            *)
                log_error "未知服务: $service"
                return 1
                ;;
        esac
    else
        # 本地模式：保持现有逻辑
        case "$service" in
            keycloak)
                wait_container_healthy "noda-infra-keycloak" 300
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
    fi
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
            # 通过 nginx 验证 Keycloak 可达（生产模式无 /health/ready，用根路径）
            docker exec "$NGINX_CONTAINER" wget --quiet --tries=1 --spider http://noda-infra-keycloak:8080/ 2>/dev/null
            log_success "Keycloak E2E 验证通过"
            ;;
        nginx)
            # 通过 nginx 容器 wget 自身验证（nginx 监听 81 端口）
            docker exec "$NGINX_CONTAINER" wget --quiet --tries=1 --spider http://127.0.0.1:81/ 2>/dev/null
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
# 部署失败清理（捕获日志）
# 参数: $1 = SERVICE
# 返回: 0=清理完成
pipeline_infra_failure_cleanup()
{
    local service="$1"

    # 捕获目标服务容器日志
    local container_name
    case "$service" in
        keycloak)
            container_name="noda-infra-keycloak"
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

    log_info "失败日志已保存"
}

# ============================================
# Pre-prod Pipeline 函数
# ============================================
# 用于 Jenkinsfile.apps 统一 Pipeline 的 pre-prod 阶段
# Pre-prod 使用单容器（非蓝绿），固定容器名 noda-apps-preprod
# 数据库: noda_preprod（独立）
# Keycloak: 与 prod 共用（同 realm）
# ============================================

PREPROD_CONTAINER="noda-apps-preprod"

# pipeline_deploy_preprod - 部署镜像到 pre-prod 环境
# 参数: $1 = GIT_SHA
pipeline_deploy_preprod()
{
    local git_sha="$1"
    local image="noda-apps:${git_sha}"

    disk_snapshot "Pre-prod 部署前"

    log_info "部署 Pre-prod 环境..."

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式
        log_info "r4s 远程部署模式：传输镜像到 r4s..."
        transfer_image "$image" "$image"

        # 停止旧 preprod 容器（远程）
        if remote_exec "docker inspect $PREPROD_CONTAINER >/dev/null 2>&1"; then
            if [ "$(remote_exec "docker inspect -f '{{.State.Running}}' $PREPROD_CONTAINER")" = "true" ]; then
                log_info "停止旧 preprod 容器（r4s）: $PREPROD_CONTAINER"
                remote_exec "docker stop -t 30 $PREPROD_CONTAINER || true"
                remote_exec "docker rm $PREPROD_CONTAINER || true"
            else
                remote_exec "docker rm $PREPROD_CONTAINER || true"
            fi
        fi

        # 准备 preprod 专用 env 文件（本地生成，传输到 r4s）
        local tmp_env
        tmp_env=$(prepare_preprod_env_file)
        log_info "传输 env 文件到 r4s..."
        envsubst < "$tmp_env" | remote_exec "cat > /tmp/preprod.env"

        # 启动新 preprod 容器（远程）
        log_info "启动 preprod 容器（r4s）: $PREPROD_CONTAINER ($image)"
        remote_exec "docker run -d \
            --name $PREPROD_CONTAINER \
            --network $NETWORK_NAME \
            --network-alias $PREPROD_CONTAINER \
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
            --memory 512m \
            --memory-reservation 128m \
            --cpus 0.5 \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --env-file /tmp/preprod.env \
            --label com.docker.compose.project=noda-apps \
            --label com.docker.compose.service=noda-apps-preprod \
            --label noda.service-group=apps \
            --label noda.environment=preprod \
            --health-cmd \"node -e \\\"fetch('http://localhost:3000/api/health').then(r=>{process.exit(r.ok?0:1)}).catch(()=>process.exit(1))\\\"\" \
            --health-interval 30s \
            --health-timeout 10s \
            --health-retries 3 \
            --health-start-period 60s \
            $image"

        rm -f "$tmp_env"

        # 更新 preprod upstream 配置（远程）
        local upstream_content="# noda-apps preprod upstream 变量 — 在 pre-prod server block 中 include
# 使用 resolver 127.0.0.11 动态解析 DNS，容器重建后自动刷新 IP
# 由 pipeline_deploy_preprod() 更新
# 容器名: noda-apps-preprod（单容器，非蓝绿）
set \$preprod_findclass_upstream ${PREPROD_CONTAINER}:3000;
set \$preprod_www_upstream ${PREPROD_CONTAINER}:3002;
set \$preprod_auth_app_upstream ${PREPROD_CONTAINER}:3004;
set \$preprod_admin_upstream ${PREPROD_CONTAINER}:3006;
set \$preprod_admin_api_upstream ${PREPROD_CONTAINER}:3011;"

        log_info "更新 preprod upstream 配置（r4s）..."
        echo "$upstream_content" | remote_exec "mkdir -p /opt/noda/noda-infra/config/nginx/snippets && cat > /opt/noda/noda-infra/config/nginx/snippets/upstream-preprod.conf"

        # reload nginx（远程）
        reload_nginx

        log_success "Pre-prod 部署完成（r4s）: $PREPROD_CONTAINER ($image)"
    else
        # 本地模式（原有逻辑）
        # 停止旧 preprod 容器
        if [ "$(is_container_running "$PREPROD_CONTAINER")" = "true" ]; then
            log_info "停止旧 preprod 容器: $PREPROD_CONTAINER"
            docker stop -t 30 "$PREPROD_CONTAINER"
            docker rm "$PREPROD_CONTAINER"
        fi

        # 准备 preprod 专用 env 文件
        local tmp_env
        tmp_env=$(prepare_preprod_env_file)

        # 启动新 preprod 容器
        log_info "启动 preprod 容器: $PREPROD_CONTAINER ($image)"

        docker run -d \
            --name "$PREPROD_CONTAINER" \
            --network "$NETWORK_NAME" \
            --network-alias "$PREPROD_CONTAINER" \
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
            --memory 512m \
            --memory-reservation 128m \
            --cpus 0.5 \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --env-file "$tmp_env" \
            --label "com.docker.compose.project=noda-apps" \
            --label "com.docker.compose.service=noda-apps-preprod" \
            --label "noda.service-group=apps" \
            --label noda.environment=preprod \
            --health-cmd "node -e \"fetch('http://localhost:3000/api/health').then(r=>{process.exit(r.ok?0:1)}).catch(()=>process.exit(1))\"" \
            --health-interval 30s \
            --health-timeout 10s \
            --health-retries 3 \
            --health-start-period 60s \
            "$image"

        rm -f "$tmp_env"

        # 更新 preprod upstream 配置
        update_preprod_upstream

        # reload nginx 使 preprod server blocks 生效
        reload_nginx

        log_success "Pre-prod 部署完成: $PREPROD_CONTAINER ($image)"
    fi
}

# prepare_preprod_env_file - 生成 preprod 环境变量文件
# 返回: 临时 env 文件路径（通过 echo 输出）
prepare_preprod_env_file()
{
    local tmp_file="/tmp/noda-apps-preprod.env.$$"
    local env_template="$PROJECT_ROOT/docker/env-noda-apps-preprod.env"

    if [ ! -f "$env_template" ]; then
        log_error "preprod env 模板文件不存在: $env_template"
        return 1
    fi

    # Keycloak 容器名固定为 keycloak（不再读取 active-env-keycloak）
    export KEYCLOAK_ACTIVE_CONTAINER="noda-infra-keycloak"

    local vars='${POSTGRES_USER} ${POSTGRES_PASSWORD} ${RESEND_API_KEY} ${KEYCLOAK_ACTIVE_CONTAINER} ${ANTHROPIC_AUTH_TOKEN} ${ANTHROPIC_BASE_URL} ${ANTHROPIC_API_KEY} ${KEYCLOAK_ADMIN_USER} ${KEYCLOAK_ADMIN_PASSWORD} ${TOKEN_SECRET} ${EMAIL_SERVICE_API_KEY}'
    envsubst "$vars" <"$env_template" >"$tmp_file"
    echo "$tmp_file"
}

# update_preprod_upstream - 更新 preprod nginx upstream 配置
update_preprod_upstream()
{
    local upstream_content="# noda-apps preprod upstream 变量 — 在 pre-prod server block 中 include
# 使用 resolver 127.0.0.11 动态解析 DNS，容器重建后自动刷新 IP
# 由 pipeline_deploy_preprod() 更新
# 容器名: noda-apps-preprod（单容器，非蓝绿）
set \$preprod_findclass_upstream ${PREPROD_CONTAINER}:3000;
set \$preprod_www_upstream ${PREPROD_CONTAINER}:3002;
set \$preprod_auth_app_upstream ${PREPROD_CONTAINER}:3004;
set \$preprod_admin_upstream ${PREPROD_CONTAINER}:3006;
set \$preprod_admin_api_upstream ${PREPROD_CONTAINER}:3011;"

    local snippets_dir
    snippets_dir=$(get_host_snippets_dir)
    local host_conf="$snippets_dir/upstream-preprod.conf"

    local tmp_file="${host_conf}.tmp.$$"
    echo "$upstream_content" >"$tmp_file"
    mv "$tmp_file" "$host_conf"

    log_info "preprod upstream 已更新: $host_conf"
}

# pipeline_health_check_preprod - preprod 容器健康检查
pipeline_health_check_preprod()
{
    log_info "Pre-prod 健康检查..."

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程健康检查模式
        log_info "Pre-prod 健康检查（r4s 远程）..."
        wait_container_healthy "$PREPROD_CONTAINER" "$((HEALTH_CHECK_MAX_RETRIES * HEALTH_CHECK_INTERVAL))" true true

        # HTTP 健康检查（通过 r4s 执行 curl）
        log_info "HTTP 健康检查（r4s 远程）..."
        if remote_exec "curl -sf http://localhost:3000/api/health"; then
            log_success "HTTP 健康检查通过（r4s）"
        else
            log_error "HTTP 健康检查失败（r4s）"
            return 1
        fi

        log_success "Pre-prod 健康检查通过（r4s）"
    else
        # 本地模式（原有逻辑）
        # 主应用 (3000)
        http_health_check "$PREPROD_CONTAINER" "3000" "/api/health" "$HEALTH_CHECK_MAX_RETRIES" "$HEALTH_CHECK_INTERVAL"

        log_success "Pre-prod 健康检查通过"
    fi
}

# ============================================
# 函数: pipeline_release_lock
# ============================================
# 释放部署锁（供 Jenkins post 块调用）
# 返回: 0=释放成功
pipeline_release_lock()
{
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        release_deploy_lock
        log_info "部署锁已释放"
    fi
}

# ============================================
# Source guard — 仅允许 source 加载，禁止直接执行
# ============================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "pipeline-stages.sh 是函数库，不支持直接执行"
    echo "请通过 Jenkinsfile 调用"
    exit 1
fi
