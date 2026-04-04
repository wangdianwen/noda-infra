#!/bin/bash

# Findclass 应用部署验证脚本（Jenkins 版本）
# 用于验证部署后的应用是否正常运行

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[INFO]${NC} 验证 Findclass 应用部署..."

# 配置
FINDCLASS_CONTAINER="noda-findclass"
NGINX_CONTAINER="noda-nginx"
API_CONTAINER="noda-api"
MAX_RETRIES=10
RETRY_INTERVAL=5

# 检查容器是否运行
check_container_running() {
    local container_name=$1

    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo -e "${GREEN}[OK]${NC} 容器 ${container_name} 正在运行"
        return 0
    else
        echo -e "${RED}[ERROR]${NC} 容器 ${container_name} 未运行"
        return 1
    fi
}

# 检查容器健康状态
check_container_health() {
    local container_name=$1

    local health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "unknown")

    if [[ "$health_status" == "healthy" ]]; then
        echo -e "${GREEN}[OK]${NC} 容器 ${container_name} 健康状态: ${health_status}"
        return 0
    elif [[ "$health_status" == "starting" ]]; then
        echo -e "${YELLOW}[WARN]${NC} 容器 ${container_name} 健康状态: ${health_status}"
        return 0
    else
        echo -e "${YELLOW}[INFO]${NC} 容器 ${container_name} 无健康检查配置"
        return 0
    fi
}

# 检查 HTTP 端点
check_http_endpoint() {
    local url=$1
    local description=$2
    local retries=$3

    echo -e "${GREEN}[INFO]${NC} 检查 ${description}: ${url}"

    i=1
    while [ $i -le $retries ]; do
        if curl -f -s -o /dev/null "$url"; then
            echo -e "${GREEN}[OK]${NC} ${description} 响应正常"
            return 0
        else
            echo -e "${YELLOW}[RETRY]${NC} ${description} 无响应，重试 ${i}/${retries}..."
            sleep $RETRY_INTERVAL
        fi
        i=$((i + 1))
    done

    echo -e "${RED}[ERROR]${NC} ${description} 无响应"
    return 1
}

# 主验证流程
main() {
    local failures=0

    # 1. 检查容器状态
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "检查容器状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if ! check_container_running "$FINDCLASS_CONTAINER"; then
        failures=$((failures + 1))
    fi

    if ! check_container_running "$NGINX_CONTAINER"; then
        failures=$((failures + 1))
    fi

    # 2. 检查健康状态
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "检查容器健康状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    check_container_health "$FINDCLASS_CONTAINER" || true
    check_container_health "$NGINX_CONTAINER" || true

    # 3. 检查 HTTP 端点
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "检查 HTTP 端点"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 检查 Nginx 前端
    if ! check_http_endpoint "http://localhost:3000" "前端应用" "$MAX_RETRIES"; then
        failures=$((failures + 1))
    fi

    # 检查 API 健康端点（如果配置了）
    if check_http_endpoint "http://localhost:3000/api/health" "API 健康端点" 2; then
        echo -e "${GREEN}[OK]${NC} API 健康端点响应正常"
    else
        echo -e "${YELLOW}[INFO]${NC} API 健康端点未配置或未响应（可选）"
    fi

    # 4. 显示容器日志
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "最近的容器日志"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo -e "${GREEN}[INFO]${NC} Findclass 容器日志（最后 20 行）:"
    docker logs "$FINDCLASS_CONTAINER" --tail 20 2>&1 || true

    echo ""
    echo -e "${GREEN}[INFO]${NC} Nginx 容器日志（最后 20 行）:"
    docker logs "$NGINX_CONTAINER" --tail 20 2>&1 || true

    # 5. 总结
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "验证总结"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ $failures -eq 0 ]]; then
        echo -e "${GREEN}✅ 所有验证通过！${NC}"
        echo ""
        echo "📍 应用访问地址:"
        echo "   前端: http://localhost:3000"
        echo "   Nginx: http://localhost:8080"
        echo ""
        return 0
    else
        echo -e "${RED}❌ 验证失败，${failures} 项检查未通过${NC}"
        echo ""
        echo "请检查容器状态和日志："
        echo "   docker ps -a"
        echo "   docker logs <container_name>"
        echo ""
        return 1
    fi
}

# 运行主函数
main "$@"
