#!/bin/bash

# Jenkins 启动/停止脚本
# 用于管理 Jenkins 容器的生命周期

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# 如果 PROJECT_ROOT 不是 git 仓库根目录，则向上查找
if [ ! -f "$PROJECT_ROOT/package.json" ]; then
    PROJECT_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
fi
COMPOSE_FILE="$PROJECT_ROOT/infra/docker/docker-compose.jenkins.yml"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查 Docker Compose 文件是否存在
if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "${RED}❌ Docker Compose 文件不存在: $COMPOSE_FILE${NC}"
    exit 1
fi

# 检查 noda-network 是否存在
check_network() {
    if ! docker network inspect noda-network >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  noda-network 不存在，创建中...${NC}"
        docker network create noda-network
        echo -e "${GREEN}✅ noda-network 创建成功${NC}"
    fi
}

# 启动 Jenkins
start_jenkins() {
    echo -e "${GREEN}🚀 启动 Jenkins...${NC}"

    # 检查网络
    check_network

    # 检查密钥文件是否存在
    if [ ! -f "$HOME/.claude/team-keys.txt" ] && [ ! -d "$HOME/.claude/team-keys" ]; then
        echo -e "${YELLOW}⚠️  警告: team-keys 不存在，Jenkins 将无法解密密钥${NC}"
        echo "   请确保 age 密钥文件位于: $HOME/.claude/team-keys"
    fi

    # 启动 Jenkins
    docker-compose -f "$COMPOSE_FILE" up -d

    # 等待 Jenkins 启动
    echo -e "${GREEN}⏳ 等待 Jenkins 启动...${NC}"
    for i in {1..60}; do
        if curl -f http://localhost:8080/login >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Jenkins 已启动${NC}"
            echo ""
            echo "📍 Jenkins UI: http://localhost:8080"
            echo ""
            echo "🔑 获取初始管理员密码:"
            echo "   docker exec noda-jenkins cat /var/jenkins_home/secrets/initialAdminPassword"
            echo ""
            break
        fi
        if [ $i -eq 60 ]; then
            echo -e "${RED}❌ Jenkins 启动超时${NC}"
            exit 1
        fi
        sleep 2
    done
}

# 停止 Jenkins
stop_jenkins() {
    echo -e "${YELLOW}🛑 停止 Jenkins...${NC}"
    docker-compose -f "$COMPOSE_FILE" down
    echo -e "${GREEN}✅ Jenkins 已停止${NC}"
}

# 重启 Jenkins
restart_jenkins() {
    echo -e "${YELLOW}🔄 重启 Jenkins...${NC}"
    stop_jenkins
    start_jenkins
}

# 查看 Jenkins 日志
logs_jenkins() {
    docker-compose -f "$COMPOSE_FILE" logs -f jenkins
}

# 查看 Jenkins 状态
status_jenkins() {
    echo -e "${GREEN}📊 Jenkins 状态:${NC}"
    docker-compose -f "$COMPOSE_FILE" ps

    echo ""
    if curl -f http://localhost:8080/login >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Jenkins 运行正常${NC}"
        echo "📍 UI: http://localhost:8080"
    else
        echo -e "${RED}❌ Jenkins 无法访问${NC}"
    fi
}

# 显示帮助信息
show_help() {
    echo "Jenkins 管理脚本"
    echo ""
    echo "用法: $0 [命令]"
    echo ""
    echo "命令:"
    echo "  start    启动 Jenkins"
    echo "  stop     停止 Jenkins"
    echo "  restart  重启 Jenkins"
    echo "  logs     查看 Jenkins 日志"
    echo "  status   查看 Jenkins 状态"
    echo "  help     显示此帮助信息"
    echo ""
}

# 主逻辑
case "${1:-}" in
    start)
        start_jenkins
        ;;
    stop)
        stop_jenkins
        ;;
    restart)
        restart_jenkins
        ;;
    logs)
        logs_jenkins
        ;;
    status)
        status_jenkins
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}❌ 未知命令: ${1:-}${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac
