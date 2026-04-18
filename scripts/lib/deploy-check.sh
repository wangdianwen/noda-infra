#!/bin/bash
# ============================================
# 部署检查共享库
# ============================================
# 提供 HTTP 健康检查和 E2E 验证函数
# 依赖：log.sh, manage-containers.sh (get_container_name)
# ============================================

# Source Guard
if [[ -n "${_NODA_DEPLOY_CHECK_LOADED:-}" ]]; then
    return 0
fi
_NODA_DEPLOY_CHECK_LOADED=1

# http_health_check - 通过 nginx 容器 wget 检查目标容器 HTTP 端点
# 参数:
#   $1: 容器名
#   $2: 服务端口
#   $3: 健康检查路径
#   $4: 最大重试次数
#   $5: 重试间隔秒数
# 返回：0=健康，1=失败
http_health_check()
{
    local container="$1"
    local service_port="$2"
    local health_path="$3"
    local max_retries="$4"
    local interval="$5"
    local attempt=0

    log_info "HTTP 健康检查: $container (最多 ${max_retries} 次, 间隔 ${interval}s)"

    while [ $attempt -lt $max_retries ]; do
        attempt=$((attempt + 1))

        if docker exec "$NGINX_CONTAINER" wget --quiet --tries=1 --spider "http://${container}:${service_port}${health_path}" 2>/dev/null; then
            log_success "$container — HTTP 健康检查通过 (第 ${attempt}/${max_retries} 次)"
            return 0
        fi

        if [ $attempt -lt $max_retries ]; then
            sleep "$interval"
        fi
    done

    log_error "$container — HTTP 健康检查失败 (${max_retries} 次尝试)"
    log_info "最近容器日志:"
    docker logs "$container" --tail 20 2>&1 | sed 's/^/  /'
    return 1
}

# e2e_verify - 通过 nginx 容器 curl/wget 验证完整请求链路
# 参数:
#   $1: 目标环境 (blue 或 green)
#   $2: 服务端口
#   $3: 健康检查路径
#   $4: 最大重试次数
#   $5: 重试间隔秒数
# 返回：0=验证通过，1=验证失败
e2e_verify()
{
    local target_env="$1"
    local service_port="$2"
    local health_path="$3"
    local max_retries="$4"
    local interval="$5"
    local container_name
    container_name=$(get_container_name "$target_env")

    log_info "E2E 验证: nginx -> $container_name (最多 ${max_retries} 次)"

    # 检测 nginx 容器是否有 curl
    local use_curl=true
    if ! docker exec "$NGINX_CONTAINER" which curl >/dev/null 2>&1; then
        log_info "nginx 容器无 curl，使用 wget 备选方案"
        use_curl=false
    fi

    local attempt=0
    while [ $attempt -lt $max_retries ]; do
        attempt=$((attempt + 1))

        local result=1

        if [ "$use_curl" = true ]; then
            local http_code
            http_code=$(docker exec "$NGINX_CONTAINER" \
                curl -s -o /dev/null -w "%{http_code}" \
                "http://${container_name}:${service_port}${health_path}" 2>/dev/null || echo "000")

            if [ "$http_code" = "200" ]; then
                result=0
            fi
        else
            if docker exec "$NGINX_CONTAINER" \
                wget --quiet --tries=1 --spider \
                "http://${container_name}:${service_port}${health_path}" 2>/dev/null; then
                result=0
            fi
        fi

        if [ $result -eq 0 ]; then
            log_success "E2E 验证通过 (第 ${attempt}/${max_retries} 次)"
            return 0
        fi

        if [ $attempt -lt $max_retries ]; then
            sleep "$interval"
        fi
    done

    log_error "E2E 验证失败 (${max_retries} 次尝试)"
    return 1
}
