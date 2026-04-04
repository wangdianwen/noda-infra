#!/bin/bash

# Jenkins 环境变量设置脚本
# 在 Jenkins 流水线中 source 此脚本以设置必要的环境变量

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[INFO]${NC} 设置 Jenkins 环境变量..."

# Jenkins 特定的环境变量
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/var/jenkins_home/keys/team-keys.txt}"
export Jenkins_HOME="${Jenkins_HOME:-/var/jenkins_home}"

# 验证密钥文件存在
if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
  echo -e "${RED}[ERROR]${NC} Jenkins 密钥文件不存在: $SOPS_AGE_KEY_FILE"
  echo "请确保 age 密钥文件已正确挂载到 Jenkins 容器"
  exit 1
fi

echo -e "${GREEN}[OK]${NC} 密钥文件已找到: $SOPS_AGE_KEY_FILE"

# 设置 Docker 相关变量（Jenkins 可以构建 Docker 镜像）
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
export DOCKER_TLS_VERIFY="${DOCKER_TLS_VERIFY:-}"
export DOCKER_CERT_PATH="${DOCKER_CERT_PATH:-}"

# 项目根目录（自动检测）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PROJECT_ROOT

echo -e "${GREEN}[OK]${NC} 项目根目录: $PROJECT_ROOT"

# 构建相关变量
export DOCKER_IMAGE="${DOCKER_IMAGE:-noda-findclass}"
export DOCKER_TAG="${DOCKER_TAG:-latest}"
export BUILD_NUMBER="${BUILD_NUMBER:-dev}"

echo -e "${GREEN}[OK]${NC} Jenkins 环境变量设置完成"
