#!/bin/bash
set -euo pipefail

# ============================================
# Noda 开发环境一键搭建脚本
# ============================================
# 功能：一键完成本地开发环境搭建
# 用途：封装 setup-postgres-local.sh，提供更高层入口点
# 使用方式：bash setup-dev.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/log.sh"

SETUP_PG="$SCRIPT_DIR/scripts/setup-postgres-local.sh"
TOTAL_STEPS=4

# ============================================
# check_homebrew() — 步骤 1/4：检查 Homebrew 是否安装
# ============================================
check_homebrew() {
  log_info "步骤 1/${TOTAL_STEPS}: 检查 Homebrew"

  if command -v brew &>/dev/null; then
    local brew_version
    brew_version=$(brew --version | head -1)
    log_success "Homebrew 已安装（${brew_version}）"
  else
    log_error "Homebrew 未安装"
    log_info "安装命令："
    log_info '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
  fi
}

# ============================================
# install_postgresql() — 步骤 2/4：安装 PostgreSQL + 创建开发数据库
# ============================================
install_postgresql() {
  log_info "步骤 2/${TOTAL_STEPS}: 安装 PostgreSQL + 创建开发数据库"

  if [ ! -f "$SETUP_PG" ]; then
    log_error "setup-postgres-local.sh 不存在: ${SETUP_PG}"
    log_info "请确认项目完整性，该文件应由 Phase 26 创建"
    exit 1
  fi

  bash "$SETUP_PG" install
}

# ============================================
# verify_environment() — 步骤 3/4：环境验证
# ============================================
verify_environment() {
  log_info "步骤 3/${TOTAL_STEPS}: 环境验证"

  bash "$SETUP_PG" status
}

# ============================================
# show_next_steps() — 步骤 4/4：显示下一步指引
# ============================================
show_next_steps() {
  log_info "步骤 4/${TOTAL_STEPS}: 下一步"

  log_success "=========================================="
  log_success "开发环境就绪！"
  log_success "=========================================="
  log_info "连接开发数据库: psql -d noda_dev"
  log_info "查看 PG 状态: bash scripts/setup-postgres-local.sh status"
  log_info "查看开发文档: docs/DEVELOPMENT.md"
}

# ============================================
# 主流程
# ============================================
log_info "=========================================="
log_info "Noda 开发环境一键搭建"
log_info "=========================================="

check_homebrew
install_postgresql
verify_environment
show_next_steps
