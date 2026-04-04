#!/bin/bash
set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "🔐 验证环境变量..."
echo "================================"

ENV_FILE=${1:-".env.dev"}

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}❌ 环境文件不存在: $ENV_FILE${NC}"
  echo "用法: $0 [.env.dev | .env.prod]"
  exit 1
fi

echo "📄 检查文件: $ENV_FILE"

# 加载环境变量
set -a
source "$ENV_FILE"
set +a

# 必需的环境变量
REQUIRED_VARS=(
  "POSTGRES_USER"
  "POSTGRES_PASSWORD"
  "POSTGRES_DB"
  "NGINX_PORT"
  "VITE_API_URL"
)

missing=0

echo -e "\n🔍 检查必需的环境变量..."
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo -e "${RED}✗${NC} $var (未设置)"
    ((missing++))
  else
    # 隐藏密码值
    if [[ "$var" == *"PASSWORD"* ]]; then
      echo -e "${GREEN}✓${NC} $var=********"
    else
      echo -e "${GREEN}✓${NC} $var=${!var}"
    fi
  fi
done

# 可选的环境变量（生产环境）
if [[ "$ENV_FILE" == ".env.prod" ]]; then
  echo -e "\n🔍 检查生产环境特定变量..."
  PROD_VARS=(
    "CLOUDFLARE_TUNNEL_TOKEN"
  )

  for var in "${PROD_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      echo -e "${YELLOW}⚠️  ${NC} $var (生产环境建议设置)"
    else
      if [[ "$var" == *"TOKEN"* ]]; then
        echo -e "${GREEN}✓${NC} $var=********"
      else
        echo -e "${GREEN}✓${NC} $var=${!var}"
      fi
    fi
  done
fi

# 总结
echo -e "\n================================"
if [[ $missing -gt 0 ]]; then
  echo -e "${RED}❌ 验证失败: $missing 个必需变量缺失${NC}"
  exit 1
else
  echo -e "${GREEN}✅ 验证通过: 所有必需变量已设置${NC}"
  exit 0
fi
