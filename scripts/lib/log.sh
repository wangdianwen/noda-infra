#!/bin/bash
# ============================================
# 通用日志库（带颜色）
# ============================================

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

log_info() {
  echo -e "${_YELLOW}ℹ️  $*${_NC}"
}

log_success() {
  echo -e "${_GREEN}✅ $*${_NC}"
}

log_error() {
  echo -e "${_RED}❌ $*${_NC}" >&2
}

log_warn() {
  echo -e "${_YELLOW}⚠️  $*${_NC}"
}
