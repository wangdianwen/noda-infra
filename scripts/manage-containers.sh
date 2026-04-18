#!/bin/bash
set -euo pipefail

# ============================================
# 蓝绿容器管理脚本
# ============================================
# 功能：管理蓝绿双容器的完整生命周期（支持 findclass-ssr, noda-site, keycloak 等多服务）
# 子命令：init, start, stop, restart, status, logs, switch
# 用途：Phase 21 蓝绿部署基础设施，Phase 22 通过 source 复用函数
# 参数化：通过环境变量 SERVICE_NAME/SERVICE_PORT/UPSTREAM_NAME 等适配不同服务
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/health.sh"

# ============================================
# 常量（通过环境变量覆盖，支持多服务蓝绿部署）
# ============================================
# 服务参数
SERVICE_NAME="${SERVICE_NAME:-findclass-ssr}"
SERVICE_PORT="${SERVICE_PORT:-3001}"
UPSTREAM_NAME="${UPSTREAM_NAME:-findclass_backend}"
HEALTH_PATH="${HEALTH_PATH:-/api/health}"

# 状态文件（每个服务独立）
ACTIVE_ENV_FILE="${ACTIVE_ENV_FILE:-/opt/noda/active-env}"

# 固定常量
NGINX_CONTAINER="noda-infra-nginx"
# UPSTREAM_CONF: nginx upstream 配置文件路径（findclass-ssr 用 upstream-findclass.conf，不是 upstream-findclass-ssr.conf）
UPSTREAM_CONF="${UPSTREAM_CONF:-$PROJECT_ROOT/config/nginx/snippets/upstream-findclass.conf}"
NETWORK_NAME="noda-network"

# get_env_template - 延迟获取 env 模板路径（SERVICE_NAME 可能被 wrapper 后设）
get_env_template()
{
    echo "$PROJECT_ROOT/docker/env-${SERVICE_NAME}.env"
}

# ============================================
# 辅助函数
# ============================================

# validate_env - 验证环境参数必须是 blue 或 green
# 参数：$1 = env
# 返回：0=有效，1=无效（同时退出脚本）
validate_env()
{
    local env="${1:-}"
    if [ "$env" != "blue" ] && [ "$env" != "green" ]; then
        log_error "环境参数必须是 blue 或 green，收到: '${env}'"
        exit 1
    fi
}

# get_active_env - 获取当前活跃环境
# 返回：blue 或 green（文件不存在时默认 blue）
get_active_env()
{
    if [ -f "$ACTIVE_ENV_FILE" ]; then
        cat "$ACTIVE_ENV_FILE"
    else
        echo "blue"
    fi
}

# get_inactive_env - 获取非活跃环境
# 返回：活跃环境的互补值
get_inactive_env()
{
    local active
    active=$(get_active_env)
    if [ "$active" = "blue" ]; then
        echo "green"
    else
        echo "blue"
    fi
}

# set_active_env - 原子写入活跃环境状态文件
# 参数：$1 = env (blue 或 green)
set_active_env()
{
    local env="$1"
    local dir
    dir="$(dirname "$ACTIVE_ENV_FILE")"
    local tmp_file="${dir}/.active-env.tmp.$$"

    # 优先尝试直接写入（无 sudo），失败时回退到 sudo（生产 Linux 环境）
    if [ -w "$dir" ] 2>/dev/null; then
        echo "$env" >"$tmp_file" && mv "$tmp_file" "$ACTIVE_ENV_FILE"
    elif [ -w "$ACTIVE_ENV_FILE" ] 2>/dev/null; then
        echo "$env" >"$tmp_file" && mv "$tmp_file" "$ACTIVE_ENV_FILE"
    else
        sudo mkdir -p "$dir"
        echo "$env" | sudo tee "$tmp_file" >/dev/null
        sudo mv "$tmp_file" "$ACTIVE_ENV_FILE"
    fi
    log_info "活跃环境已更新: $env"
}

# prepare_env_file - 从模板生成临时 env 文件
# 参数：$1 = env (blue 或 green)
# 返回：临时 env 文件路径（通过 echo 输出）
# 安全：只替换 ENVSUBST_VARS 中明确列出的变量名，避免替换 $HOSTNAME 等 shell 内置变量
prepare_env_file()
{
    local env="$1"
    # 使用服务容器名而非 SERVICE_NAME 来生成临时文件，避免多服务冲突
    local tmp_file="/tmp/${SERVICE_NAME}-${env}.env.$$"

    if ! command -v envsubst &>/dev/null; then
        log_error "envsubst 不可用，请安装 gettext: sudo apt install gettext"
        exit 1
    fi

    # 自动解析 Keycloak 蓝绿活跃容器名（findclass-ssr 等服务需要 KEYCLOAK_INTERNAL_URL）
    if [ -f "/opt/noda/active-env-keycloak" ]; then
        export KEYCLOAK_ACTIVE_CONTAINER="keycloak-$(cat /opt/noda/active-env-keycloak)"
    else
        export KEYCLOAK_ACTIVE_CONTAINER="${KEYCLOAK_ACTIVE_CONTAINER:-keycloak-blue}"
    fi

    # 支持通过 ENVSUBST_VARS 环境变量覆盖需要替换的变量列表
    # 默认值保持 findclass-ssr 兼容
    # 注意：不能在 ${VAR:-...} 内嵌套 ${...}，内层 } 会被误认为外层闭合
    local _default_vars='${POSTGRES_USER} ${POSTGRES_PASSWORD} ${RESEND_API_KEY} ${KEYCLOAK_ACTIVE_CONTAINER} ${ANTHROPIC_AUTH_TOKEN} ${ANTHROPIC_BASE_URL}'
    local vars="${ENVSUBST_VARS:-$_default_vars}"
    envsubst "$vars" <"$(get_env_template)" >"$tmp_file"
    echo "$tmp_file"
}

# get_container_name - 获取容器名
# 参数：$1 = env
# 返回：{SERVICE_NAME}-{blue|green}
get_container_name()
{
    local env="$1"
    echo "${SERVICE_NAME}-${env}"
}

# is_container_running - 检查容器是否在运行
# 参数：$1 = 容器名
# 返回：true 或 false
is_container_running()
{
    local name="$1"
    local running
    running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")
    echo "$running"
}

# ============================================
# 辅助函数: get_host_snippets_dir
# ============================================
# 获取 nginx 容器 snippets 目录在宿主机上的实际路径
# Pipeline workspace 路径和 nginx 挂载路径可能不同
get_host_snippets_dir()
{
    # 优先从 docker inspect 获取挂载源
    local host_path
    host_path=$(docker inspect "$NGINX_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/snippets"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
    if [ -n "$host_path" ] && [ -d "$host_path" ]; then
        echo "$host_path"
        return
    fi
    # 回退到 PROJECT_ROOT 下的路径
    echo "$PROJECT_ROOT/config/nginx/snippets"
}

# ============================================
# 核心函数: run_container
# ============================================
# 启动一个蓝绿容器（Phase 22 通过 source 调用此函数）
# 参数：$1 = env (blue 或 green), $2 = image (镜像名)
# 环境变量控制：
#   SERVICE_NAME  - 服务名（默认 findclass-ssr）
#   SERVICE_PORT  - 服务端口（默认 3001）
#   HEALTH_PATH   - 健康检查路径（默认 /api/health）
#   ENV_TEMPLATE  - env 模板文件路径（不存在则跳过 env-file）
run_container()
{
    local env="$1"
    local image="$2"
    local container_name
    container_name=$(get_container_name "$env")

    # 如果有 env 模板文件，准备临时 env 文件（noda-site 等纯静态服务无 env 模板）
    local tmp_env_file=""
    if [ -f "$(get_env_template)" ]; then
        tmp_env_file=$(prepare_env_file "$env")
    fi

    # 支持通过环境变量覆盖容器参数（Keycloak 等服务需要更大内存、非只读、额外卷挂载）
    local container_memory="${CONTAINER_MEMORY:-512m}"
    local container_memory_reservation="${CONTAINER_MEMORY_RESERVATION:-128m}"
    local container_readonly="${CONTAINER_READONLY:-true}"
    local service_group="${SERVICE_GROUP:-apps}"
    local extra_docker_args="${EXTRA_DOCKER_ARGS:-}"
    local container_cmd="${CONTAINER_CMD:-}"
    local container_cap_add="${CONTAINER_CAP_ADD:-}"
    local _default_health_cmd="node -e \"fetch('http://localhost:${SERVICE_PORT}${HEALTH_PATH}').then(r=>{process.exit(r.ok?0:1)}).catch(()=>process.exit(1))\""
    local container_health_cmd="${CONTAINER_HEALTH_CMD:-$_default_health_cmd}"

    log_info "启动容器: $container_name (镜像: $image${container_cmd:+, 命令: $container_cmd})"

    docker run -d \
        --name "$container_name" \
        --network "$NETWORK_NAME" \
        --restart unless-stopped \
        --stop-timeout 30 \
        --security-opt no-new-privileges \
        --cap-drop ALL \
        ${container_cap_add:+--cap-add "$container_cap_add"} \
        $([ "$container_readonly" = "true" ] && echo "--read-only") \
        --tmpfs /tmp \
        --memory "$container_memory" \
        --memory-reservation "$container_memory_reservation" \
        --cpus 1 \
        --log-driver json-file \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        ${tmp_env_file:+--env-file "$tmp_env_file"} \
        --label "noda.service-group=${service_group}" \
        --label noda.environment=prod \
        --label "noda.blue-green=${env}" \
        --label com.docker.compose.project=noda-apps \
        --label "com.docker.compose.service=${SERVICE_NAME}" \
        --health-cmd "$container_health_cmd" \
        --health-interval 30s \
        --health-timeout 10s \
        --health-retries 3 \
        --health-start-period 60s \
        ${extra_docker_args} \
        "$image" \
        ${container_cmd:+"$container_cmd"}

    log_success "容器 $container_name 已启动"

    # 清理临时 env 文件
    rm -f "$tmp_env_file"
}

# ============================================
# update_upstream - 更新 nginx upstream 配置
# ============================================
# 参数：$1 = target env (blue 或 green)
# 环境变量控制：
#   UPSTREAM_NAME - nginx upstream 块名称（默认 findclass_backend）
#   SERVICE_PORT  - 服务端口（默认 3001）
update_upstream()
{
    local target_env="$1"
    local container_name
    container_name=$(get_container_name "$target_env")

    local upstream_content="upstream ${UPSTREAM_NAME} {
    server ${container_name}:${SERVICE_PORT} max_fails=3 fail_timeout=30s;
}"

    # 写入宿主机文件（nginx volume mount 的源目录）
    local snippets_dir
    snippets_dir=$(get_host_snippets_dir)
    local upstream_basename
    upstream_basename=$(basename "$UPSTREAM_CONF")
    local host_conf="$snippets_dir/$upstream_basename"

    local tmp_file="${host_conf}.tmp.$$"
    echo "$upstream_content" >"$tmp_file"
    mv "$tmp_file" "$host_conf"

    log_info "upstream 已更新: $container_name:$SERVICE_PORT"
}

# ============================================
# reload_nginx - 重载 nginx 配置
# ============================================
reload_nginx()
{
    if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
        log_error "nginx 容器 ($NGINX_CONTAINER) 未运行"
        exit 1
    fi
    docker exec "$NGINX_CONTAINER" nginx -s reload
    log_success "nginx 配置已重载"
}

# ============================================
# 子命令: cmd_init
# ============================================
# 从 compose 单容器迁移到蓝绿 blue 容器
cmd_init()
{
    log_info "=========================================="
    log_info "初始化蓝绿部署架构"
    log_info "=========================================="

    # 步骤 1：检测 compose 管理的旧容器
    # 先尝试直接 SERVICE_NAME（findclass-ssr 等），回退检查 compose 项目名前缀的容器
    local current_image=""
    local compose_container_name="noda-infra-${SERVICE_NAME}-prod"

    if docker inspect "$SERVICE_NAME" &>/dev/null; then
        current_image=$(docker inspect --format='{{.Config.Image}}' "$SERVICE_NAME" 2>/dev/null || echo "")
        log_info "检测到 compose 容器 $SERVICE_NAME (镜像: ${current_image:-未知})"
    elif docker inspect "$compose_container_name" &>/dev/null; then
        current_image=$(docker inspect --format='{{.Config.Image}}' "$compose_container_name" 2>/dev/null || echo "")
        log_info "检测到 compose 容器 $compose_container_name (镜像: ${current_image:-未知})"
    fi

    # 步骤 2：如果没有 compose 容器，检查是否已初始化
    if [ -z "$current_image" ]; then
        if [ -f "$ACTIVE_ENV_FILE" ]; then
            local active
            active=$(get_active_env)
            log_warn "蓝绿架构已初始化（活跃环境: $active）"
            log_info "如需重新初始化，请先手动停止所有蓝绿容器"
            exit 0
        else
            log_error "未找到 compose 容器 $SERVICE_NAME，且未检测到蓝绿架构状态"
            log_info "请先使用 docker compose 部署 $SERVICE_NAME 服务"
            exit 1
        fi
    fi

    # 步骤 3：用户确认
    log_warn "init 将短暂中断服务（约 60-90 秒）"
    read -p "确认继续? [y/N] " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "初始化已取消"
        exit 0
    fi

    # 步骤 4：停止 compose 容器
    log_info "步骤 4/10: 停止 compose 容器"
    local stop_container="$SERVICE_NAME"
    if ! docker inspect "$SERVICE_NAME" &>/dev/null 2>&1 && docker inspect "$compose_container_name" &>/dev/null 2>&1; then
        stop_container="$compose_container_name"
    fi
    docker stop "$stop_container"
    docker rm "$stop_container"
    log_success "compose 容器 $stop_container 已停止并移除"

    # 步骤 5：启动 blue 容器
    log_info "步骤 5/10: 启动 blue 容器"
    run_container blue "$current_image"

    # 步骤 6：等待健康检查
    log_info "步骤 6/10: 等待健康检查"
    if ! wait_container_healthy "${SERVICE_NAME}-blue" 120; then
        log_error "blue 容器健康检查失败"
        exit 1
    fi

    # 步骤 7：更新 nginx upstream
    log_info "步骤 7/10: 更新 nginx upstream"
    update_upstream blue

    # 步骤 8：reload nginx
    log_info "步骤 8/10: 重载 nginx"
    reload_nginx

    # 步骤 9：写入状态文件
    log_info "步骤 9/10: 写入状态文件"
    set_active_env blue

    # 步骤 10：完成
    log_info "步骤 10/10: 完成"
    log_success "=========================================="
    log_success "蓝绿架构初始化完成"
    log_success "=========================================="
    log_info "活跃环境: blue"
    log_info "容器: ${SERVICE_NAME}-blue"
    log_info "镜像: $current_image"
}

# ============================================
# 子命令: cmd_start
# ============================================
# 启动指定环境的容器
cmd_start()
{
    local env="${2:-}"
    if [ -z "$env" ]; then
        log_error "用法: $0 start <blue|green> [镜像名]"
        exit 1
    fi
    validate_env "$env"

    local container_name
    container_name=$(get_container_name "$env")

    # 检查是否已运行
    if [ "$(is_container_running "$container_name")" = "true" ]; then
        log_warn "$container_name 已在运行"
        exit 0
    fi

    # 检查网络
    if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
        log_error "网络 $NETWORK_NAME 不存在，请先启动基础设施服务"
        exit 1
    fi

    local image="${3:-${SERVICE_NAME}:latest}"
    run_container "$env" "$image"

    log_info "等待健康检查..."
    if ! wait_container_healthy "$container_name" 120; then
        log_error "$container_name 健康检查失败"
        exit 1
    fi

    log_success "$container_name 启动完成并已通过健康检查"
}

# ============================================
# 子命令: cmd_stop
# ============================================
# 停止指定环境的容器
cmd_stop()
{
    local env="${2:-}"
    if [ -z "$env" ]; then
        log_error "用法: $0 stop <blue|green>"
        exit 1
    fi
    validate_env "$env"

    local container_name
    container_name=$(get_container_name "$env")

    # 检查容器是否存在
    if ! docker inspect "$container_name" &>/dev/null; then
        log_warn "$container_name 不存在"
        exit 0
    fi

    # 安全检查：停止活跃环境需要确认
    local active_env
    active_env=$(get_active_env)
    if [ "$env" = "$active_env" ]; then
        log_warn "警告: $env 是当前活跃环境，停止后服务将中断"
        read -p "确认停止活跃环境? [y/N] " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "已取消"
            exit 0
        fi
    fi

    log_info "停止容器: $container_name"
    docker stop -t 30 "$container_name"
    docker rm "$container_name"
    log_success "$container_name 已停止并移除"
}

# ============================================
# 子命令: cmd_restart
# ============================================
# 重启指定环境的容器
cmd_restart()
{
    local env="${2:-}"
    if [ -z "$env" ]; then
        log_error "用法: $0 restart <blue|green>"
        exit 1
    fi
    validate_env "$env"

    local container_name
    container_name=$(get_container_name "$env")

    # 获取当前镜像
    local current_image
    current_image=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null || echo "")
    if [ -z "$current_image" ]; then
        log_error "$container_name 不存在，无法重启。请使用 start 命令"
        exit 1
    fi

    log_info "重启 $container_name (镜像: $current_image)"
    docker stop -t 30 "$container_name"
    docker rm "$container_name"

    run_container "$env" "$current_image"

    log_info "等待健康检查..."
    if ! wait_container_healthy "$container_name" 120; then
        log_error "$container_name 健康检查失败"
        exit 1
    fi

    log_success "$container_name 重启完成"
}

# ============================================
# 子命令: cmd_status
# ============================================
# 显示蓝绿容器状态
cmd_status()
{
    local active_env
    active_env=$(get_active_env)

    log_info "=========================================="
    log_info "蓝绿容器状态"
    log_info "=========================================="
    log_info "活跃环境: $active_env"
    log_info ""

    for env in blue green; do
        local container_name
        container_name=$(get_container_name "$env")
        local marker=""
        if [ "$env" = "$active_env" ]; then
            marker=" [ACTIVE]"
        fi

        log_info "--- $env${marker} ---"

        if ! docker inspect "$container_name" &>/dev/null; then
            log_info "  状态: 不存在"
        else
            local running health image created
            running=$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || echo "unknown")
            health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || echo "unknown")
            image=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null || echo "unknown")
            created=$(docker inspect --format='{{.Created}}' "$container_name" 2>/dev/null || echo "unknown")

            log_info "  运行: $running"
            log_info "  健康: $health"
            log_info "  镜像: $image"
            log_info "  创建: $created"
        fi
        log_info ""
    done
}

# ============================================
# 子命令: cmd_logs
# ============================================
# 查看容器日志
cmd_logs()
{
    local env="${2:-}"
    if [ -z "$env" ]; then
        log_error "用法: $0 logs <blue|green> [docker logs 参数...]"
        exit 1
    fi
    validate_env "$env"

    local container_name
    container_name=$(get_container_name "$env")

    docker logs "$container_name" "${@:3}"
}

# ============================================
# 子命令: cmd_switch
# ============================================
# 切换活跃环境（流量切换）
cmd_switch()
{
    local target_env="${2:-}"
    if [ -z "$target_env" ]; then
        log_error "用法: $0 switch <blue|green>"
        exit 1
    fi
    validate_env "$target_env"

    local target_container
    target_container=$(get_container_name "$target_env")

    # 检查目标容器是否在运行
    if [ "$(is_container_running "$target_container")" != "true" ]; then
        log_error "目标容器 $target_container 未运行，无法切换"
        exit 1
    fi

    # 检查目标容器是否健康
    log_info "验证目标容器健康状态..."
    if ! wait_container_healthy "$target_container" 10; then
        log_error "目标容器 $target_container 不健康，拒绝切换"
        exit 1
    fi

    local current_env
    current_env=$(get_active_env)
    log_info "切换流量: $current_env -> $target_env"

    # 更新 upstream 文件（原子操作）
    update_upstream "$target_env"

    # nginx -t 验证配置
    log_info "验证 nginx 配置..."
    if ! docker exec "$NGINX_CONTAINER" nginx -t; then
        log_error "nginx 配置验证失败，回滚 upstream"
        update_upstream "$current_env"
        exit 1
    fi

    # nginx reload
    reload_nginx

    # 更新状态文件
    set_active_env "$target_env"

    log_success "=========================================="
    log_success "流量切换完成"
    log_success "=========================================="
    log_success "$current_env -> $target_env"
}

# ============================================
# usage - 显示帮助信息
# ============================================
usage()
{
    cat <<EOF
蓝绿容器管理脚本（服务: ${SERVICE_NAME}）

用法: manage-containers.sh <命令> [参数]

命令:
  init                      从 compose 单容器迁移到蓝绿 blue 容器
  start <blue|green> [镜像]  启动指定环境的容器
  stop <blue|green>         停止指定环境的容器
  restart <blue|green>      重启指定环境的容器
  status                    显示蓝绿容器状态和活跃环境
  logs <blue|green> [参数]  查看容器日志（支持 --tail, --follow 等）
  switch <blue|green>       切换活跃环境（流量切换）

环境变量:
  SERVICE_NAME   服务名（默认 findclass-ssr）
  SERVICE_PORT   服务端口（默认 3001）
  UPSTREAM_NAME  nginx upstream 名称（默认 findclass_backend）
  HEALTH_PATH    健康检查路径（默认 /api/health）
  ACTIVE_ENV_FILE 活跃环境状态文件（默认 /opt/noda/active-env）
  CONTAINER_MEMORY  容器内存限制（默认 512m）
  CONTAINER_MEMORY_RESERVATION  容器内存预留（默认 128m）
  CONTAINER_READONLY  容器只读模式（默认 true）
  SERVICE_GROUP  服务组标签（默认 apps）
  EXTRA_DOCKER_ARGS  额外 docker run 参数（默认 无）
  ENVSUBST_VARS  envsubst 替换变量列表（默认 findclass-ssr 三个变量）

示例:
  manage-containers.sh init
  manage-containers.sh start blue
  manage-containers.sh start green ${SERVICE_NAME}:v2
  manage-containers.sh status
  manage-containers.sh logs blue --tail 100 -f
  manage-containers.sh switch green

  SERVICE_NAME=noda-site SERVICE_PORT=3000 manage-containers.sh status

  SERVICE_NAME=keycloak SERVICE_PORT=8080 UPSTREAM_NAME=keycloak_backend \\
    HEALTH_PATH=/health/ready ACTIVE_ENV_FILE=/opt/noda/active-env-keycloak \\
    UPSTREAM_CONF=\$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf \\
    CONTAINER_MEMORY=1g CONTAINER_MEMORY_RESERVATION=512m CONTAINER_READONLY=false \\
    SERVICE_GROUP=infra \\
    ENVSUBST_VARS='\${POSTGRES_USER} \${POSTGRES_PASSWORD} \${KEYCLOAK_ADMIN_USER} \${KEYCLOAK_ADMIN_PASSWORD} \${SMTP_HOST} \${SMTP_PORT} \${SMTP_FROM} \${SMTP_USER} \${SMTP_PASSWORD}' \\
    EXTRA_DOCKER_ARGS='-v /path/to/themes:/opt/keycloak/themes/noda:ro --tmpfs /opt/keycloak/data' \\
    bash scripts/manage-containers.sh status
EOF
}

# ============================================
# 子命令分发（仅直接执行时触发，source 时跳过）
# ============================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        init) cmd_init "$@" ;;
        start) cmd_start "$@" ;;
        stop) cmd_stop "$@" ;;
        restart) cmd_restart "$@" ;;
        status) cmd_status "$@" ;;
        logs) cmd_logs "$@" ;;
        switch) cmd_switch "$@" ;;
        *) usage && exit 1 ;;
    esac
fi
