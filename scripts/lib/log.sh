#!/bin/bash
# ============================================
# 通用日志库（带颜色）
# ============================================

# 确保 PATH 包含必要的可执行文件路径（所有脚本依赖）
# macOS Homebrew: /usr/local/bin, /opt/homebrew/bin
# Node.js (nvm): ~/.nvm/versions/node/v*/bin
# pnpm: ~/.nvm/versions/node/v*/bin
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# 如果存在 nvm，加载 Node.js 和 pnpm
if [ -d "$HOME/.nvm" ] && [ -s "$HOME/.nvm/nvm.sh" ]; then
    export NVM_DIR="$HOME/.nvm"
    # 加载 nvm 而不 sourcing（避免在非交互 shell 中的问题）
    export PATH="$HOME/.nvm/versions/node/$(cat "$HOME/.nvmrc" 2>/dev/null | head -1 || echo "v24.12.0")/bin:$PATH"
fi

_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_RED='\033[0;31m'
_BLUE='\033[0;34m'
_NC='\033[0m'

# 导出颜色常量（供需要内联颜色标记的脚本使用）
GREEN="$_GREEN"
YELLOW="$_YELLOW"
RED="$_RED"
BLUE="$_BLUE"
NC="$_NC"

log_info()
{
    printf "${_YELLOW}ℹ️  %s${_NC}\n" "$*"
}

log_success()
{
    printf "${_GREEN}✅ %s${_NC}\n" "$*"
}

log_error()
{
    printf "${_RED}❌ %s${_NC}\n" "$*" >&2
}

log_warn()
{
    printf "${_YELLOW}⚠️  %s${_NC}\n" "$*"
}
