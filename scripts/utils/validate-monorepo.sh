#!/bin/bash
set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 验证 Monorepo 目录结构..."
echo "================================"

# 必需的目录
REQUIRED_DIRS=(
  "apps"
  "apps/noda"
  "infra"
  "docker"
  "infra/postgres"
  "infra/scripts"
  "infra/cloudflare"
  "packages"
)

# 必需的文件
REQUIRED_FILES=(
  "pnpm-workspace.yaml"
  "package.json"
  "README.md"
  "docker/docker-compose.yml"
  "docker/docker-compose.dev.yml"
  "docker/docker-compose.prod.yml"
  "infra/postgres/init/01-create-databases.sql"
  "infra/cloudflare/config.yml"
  "infra/.env.example"
)

missing_dirs=0
missing_files=0

# 检查目录
echo -e "\n📁 检查目录..."
for dir in "${REQUIRED_DIRS[@]}"; do
  if [[ -d "$dir" ]]; then
    echo -e "${GREEN}✓${NC} $dir"
  else
    echo -e "${RED}✗${NC} $dir (缺失)"
    ((missing_dirs++))
  fi
done

# 检查文件
echo -e "\n📄 检查文件..."
for file in "${REQUIRED_FILES[@]}"; do
  if [[ -f "$file" ]]; then
    echo -e "${GREEN}✓${NC} $file"
  else
    echo -e "${YELLOW}○${NC} $file (待创建)"
    ((missing_files++))
  fi
done

# 总结
echo -e "\n================================"
if [[ $missing_dirs -gt 0 ]]; then
  echo -e "${RED}❌ 验证失败: $missing_dirs 个目录缺失${NC}"
  exit 1
elif [[ $missing_files -gt 0 ]]; then
  echo -e "${YELLOW}⚠️  警告: $missing_files 个文件待创建${NC}"
  exit 0
else
  echo -e "${GREEN}✅ 验证通过: Monorepo 结构完整${NC}"
  exit 0
fi
