#!/bin/bash
set -euo pipefail

# ============================================
# Noda Monorepo - 环境切换脚本
# ============================================
# 使用方法：
#   ./infra/scripts/switch-env.sh [dev|prod]

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 参数验证
ENV=${1:-dev}
COMPOSE_PROJECT_NAME="noda"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo -e "${RED}❌ 用法: $0 [dev|prod]${NC}"
  exit 1
fi

# 开始计时
START_TIME=$(date +%s)

echo -e "${BLUE}🔄 切换到 $ENV 环境...${NC}"
echo "项目根目录: $PROJECT_ROOT"
echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 1. 停止现有容器
echo -e "${BLUE}1️⃣  停止现有容器...${NC}"
if docker compose -p $COMPOSE_PROJECT_NAME --project-directory="$PROJECT_ROOT" down 2>/dev/null; then
  echo -e "${GREEN}✓${NC} 容器已停止"
else
  echo -e "${YELLOW}○${NC} 没有运行中的容器"
fi
echo ""

# 2. 加载环境变量
echo -e "${BLUE}2️⃣  加载环境变量...${NC}"

# 优先尝试从加密文件解密（SOPS 密钥管理）
DECRYPTED_ENV_FILE=""
if [[ "$ENV" == "prod" ]]; then
  if [[ -f "$PROJECT_ROOT/secrets/infra.env.prod.enc" ]]; then
    echo -e "${GREEN}✓${NC} 检测到加密环境文件，正在解密..."
    DECRYPTED_ENV_FILE="/tmp/noda-secrets/.env.prod"
    "$PROJECT_ROOT/scripts/decrypt-secrets.sh" infra /tmp/noda-secrets
    ENV_FILE="$DECRYPTED_ENV_FILE"
  fi
fi

# 如果没有解密文件，使用明文文件（向后兼容）
if [[ -z "$DECRYPTED_ENV_FILE" ]]; then
  ENV_FILE="$PROJECT_ROOT/infra/.env.$ENV"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}❌ 环境文件不存在: $ENV_FILE${NC}"
  echo "请先创建环境文件或加密密钥："
  echo "  明文: cp infra/.env.example $ENV_FILE"
  echo "  加密: ./scripts/encrypt-secrets.sh"
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

# 清理解密文件
if [[ -n "$DECRYPTED_ENV_FILE" && -f "$DECRYPTED_ENV_FILE" ]]; then
  rm -f "$DECRYPTED_ENV_FILE"
  echo -e "${GREEN}✓${NC} 已清理临时解密文件"
fi

echo -e "${GREEN}✓${NC} 环境变量已加载"
echo ""

# 3. 验证环境变量
echo -e "${BLUE}3️⃣  验证环境变量...${NC}"
if ! "$SCRIPT_DIR/check-env.sh" "$ENV"; then
  echo -e "${RED}❌ 环境变量验证失败${NC}"
  echo "请检查 $ENV_FILE 配置"
  exit 1
fi
echo ""

# 4. 选择 Docker Compose 文件
echo -e "${BLUE}4️⃣  选择 Docker Compose 配置...${NC}"
if [[ "$ENV" == "dev" ]]; then
  COMPOSE_FILES="-f $PROJECT_ROOT/docker/docker-compose.yml -f $PROJECT_ROOT/docker/docker-compose.dev.yml"
  ACCESS_URL="http://localhost:8080"
else
  COMPOSE_FILES="-f $PROJECT_ROOT/docker/docker-compose.yml -f $PROJECT_ROOT/docker/docker-compose.prod.yml"
  ACCESS_URL="https://class.noda.co.nz"
fi
echo -e "${GREEN}✓${NC} 配置文件已选择"
echo ""

# 5. 启动容器
echo -e "${BLUE}5️⃣  启动容器...${NC}"
if docker compose -p $COMPOSE_PROJECT_NAME --project-directory="$PROJECT_ROOT" $COMPOSE_FILES up -d; then
  echo -e "${GREEN}✓${NC} 容器已启动"
else
  echo -e "${RED}❌ 容器启动失败${NC}"
  exit 1
fi
echo ""

# 6. 等待容器就绪
echo -e "${BLUE}6️⃣  等待容器就绪...${NC}"
sleep 3  # 给容器一些时间启动

# 7. 显示容器状态
echo -e "${BLUE}7️⃣  容器状态:${NC}"
docker compose -p $COMPOSE_PROJECT_NAME --project-directory="$PROJECT_ROOT" ps
echo ""

# 8. 测试 PostgreSQL 连接
echo -e "${BLUE}8️⃣  测试 PostgreSQL 连接...${NC}"
if docker exec noda-postgres pg_isready -U ${POSTGRES_USER} &> /dev/null; then
  echo -e "${GREEN}✓${NC} PostgreSQL 连接成功"
else
  echo -e "${YELLOW}○${NC} PostgreSQL 尚未就绪（容器仍在初始化）"
fi
echo ""

# 9. 计算耗时
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# 10. 显示总结
echo "================================"
echo -e "${GREEN}✅ 已切换到 $ENV 环境${NC}"
echo "================================"
echo "访问地址: $ACCESS_URL"
echo "切换耗时: ${DURATION} 秒"
echo "完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 性能检查
if [[ $DURATION -gt 10 ]]; then
  echo -e "${YELLOW}⚠️  切换时间超过 10 秒，可能需要优化${NC}"
else
  echo -e "${GREEN}✓ 切换时间符合要求（< 10 秒）${NC}"
fi
