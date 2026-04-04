#!/bin/bash
set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "🐳 验证 Docker Compose 配置..."
echo "================================"

# 检查 Docker 是否安装
if ! command -v docker &> /dev/null; then
  echo -e "${RED}❌ Docker 未安装${NC}"
  exit 1
fi

if ! command -v docker compose &> /dev/null; then
  echo -e "${RED}❌ Docker Compose 未安装${NC}"
  exit 1
fi

echo -e "${GREEN}✓${NC} Docker 版本: $(docker --version)"
echo -e "${GREEN}✓${NC} Docker Compose 版本: $(docker compose version)"

# 验证基础配置
echo -e "\n📋 验证 docker-compose.yml..."
if [[ -f "docker/docker-compose.yml" ]]; then
  if docker compose -f docker/docker-compose.yml config &> /dev/null; then
    echo -e "${GREEN}✓${NC} 基础配置语法正确"
  else
    echo -e "${RED}✗${NC} 基础配置语法错误"
    exit 1
  fi
else
  echo -e "${RED}✗${NC} docker-compose.yml 不存在"
  exit 1
fi

# 验证开发环境配置
echo -e "\n📋 验证 docker-compose.dev.yml..."
if [[ -f "docker/docker-compose.dev.yml" ]]; then
  if docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml config &> /dev/null; then
    echo -e "${GREEN}✓${NC} 开发环境配置语法正确"
  else
    echo -e "${RED}✗${NC} 开发环境配置语法错误"
    exit 1
  fi
else
  echo -e "${RED}✗${NC} docker-compose.dev.yml 不存在"
  exit 1
fi

# 验证生产环境配置
echo -e "\n📋 验证 docker-compose.prod.yml..."
if [[ -f "docker/docker-compose.prod.yml" ]]; then
  if docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml config &> /dev/null; then
    echo -e "${GREEN}✓${NC} 生产环境配置语法正确"
  else
    echo -e "${RED}✗${NC} 生产环境配置语法错误"
    exit 1
  fi
else
  echo -e "${RED}✗${NC} docker-compose.prod.yml 不存在"
  exit 1
fi

echo -e "\n================================"
echo -e "${GREEN}✅ 所有 Docker Compose 配置验证通过${NC}"
exit 0
