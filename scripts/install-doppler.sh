#!/usr/bin/env bash
# Doppler CLI 安装脚本
# 用途：在 Jenkins 宿主机上安装 Doppler CLI（brew 优先，curl 备选）
# 使用：bash scripts/install-doppler.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 检查是否已安装
if command -v doppler &>/dev/null; then
    CURRENT_VERSION=$(doppler --version 2>/dev/null || echo "unknown")
    info "Doppler CLI 已安装: ${CURRENT_VERSION}"
    info "如需重新安装，请先运行: brew uninstall dopplerhq/cli/doppler"
    exit 0
fi

info "开始安装 Doppler CLI..."

# 路径 1：Homebrew（推荐，适合宿主机持久安装）
if command -v brew &>/dev/null; then
    info "检测到 Homebrew，使用 brew 安装..."

    # 确保签名验证依赖存在
    info "安装 gnupg（签名验证依赖）..."
    brew install gnupg 2>/dev/null || true

    # 注册 Doppler 官方 tap 源
    info "注册 Doppler tap 源..."
    brew tap dopplerhq/cli

    # 安装 Doppler CLI
    info "安装 Doppler CLI..."
    brew install dopplerhq/cli/doppler

elif command -v curl &>/dev/null || command -v wget &>/dev/null; then
    # 路径 2：curl/wget 安装脚本（适合无 Homebrew 的环境）
    warn "未检测到 Homebrew，使用 curl/wget 安装脚本..."
    info "下载并执行 Doppler 官方安装脚本..."

    (curl -Ls --tlsv1.2 --proto "=https" --retry 3 https://cli.doppler.com/install.sh || \
     wget -t 3 -qO- https://cli.doppler.com/install.sh) | sudo sh
else
    error "需要 curl 或 wget 来下载安装脚本"
    error "请先安装 Homebrew: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
fi

# 验证安装
if command -v doppler &>/dev/null; then
    INSTALLED_VERSION=$(doppler --version 2>/dev/null || echo "unknown")
    info "Doppler CLI 安装成功！"
    info "版本: ${INSTALLED_VERSION}"

    echo ""
    info "下一步：设置 DOPPLER_TOKEN 环境变量以启用非交互式认证"
    info "  export DOPPLER_TOKEN='dp.st.prd.xxxx'"
    info "  doppler secrets download --format=env --no-file --project noda --config prod"
else
    error "Doppler CLI 安装失败，请检查上方错误信息"
    exit 1
fi
