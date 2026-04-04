#!/bin/bash
set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "🚀 运行完整验证套件..."
echo "================================"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 跟踪结果
RESULTS=()
FAIL_COUNT=0

# 函数：运行验证
run_validation() {
  local name=$1
  local command=$2

  echo -e "${BLUE}▶${NC} 运行: $name"
  echo "命令: $command"
  echo ""

  if eval "$command"; then
    echo -e "${GREEN}✓${NC} $name 通过"
    RESULTS+=("$name: ✅ PASS")
    echo ""
    return 0
  else
    echo -e "${RED}✗${NC} $name 失败"
    RESULTS+=("$name: ❌ FAIL")
    ((FAIL_COUNT++))
    echo ""
    return 1
  fi
}

# 运行所有验证
run_validation "Monorepo 目录结构" "./infra/scripts/validate-monorepo.sh"
run_validation "Docker Compose 配置" "./infra/scripts/validate-docker.sh"
run_validation "环境变量 (infra/.env.example)" "./infra/scripts/validate-env.sh infra/.env.example"

# 如果存在实际环境文件，也验证它们
if [[ -f "infra/.env.dev" ]]; then
  run_validation "环境变量 (infra/.env.dev)" "./infra/scripts/validate-env.sh infra/.env.dev"
fi

if [[ -f "infra/.env.prod" ]]; then
  run_validation "环境变量 (infra/.env.prod)" "./infra/scripts/validate-env.sh infra/.env.prod"
fi

# 显示总结
echo "================================"
echo "📊 验证总结"
echo "================================"
echo ""

for result in "${RESULTS[@]}"; do
  echo "  $result"
done

echo ""
echo "总计: ${#RESULTS[@]} 验证"
echo -e "通过: $(( ${#RESULTS[@]} - FAIL_COUNT ))/${#RESULTS[@]}"
echo -e "失败: $FAIL_COUNT/${#RESULTS[@]}"

echo ""
echo "================================"
if [[ $FAIL_COUNT -eq 0 ]]; then
  echo -e "${GREEN}✅ 所有验证通过${NC}"
  echo "================================"
  exit 0
else
  echo -e "${RED}❌ $FAIL_COUNT 个验证失败${NC}"
  echo "================================"
  exit 1
fi
