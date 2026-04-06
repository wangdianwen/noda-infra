#!/bin/bash
# ============================================
# Noda 数据库备份系统 - rclone 测试脚本
# ============================================
# 功能：测试 rclone 配置和 B2 连接
# 用法：./test_rclone.sh
# ============================================

set -euo pipefail

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载依赖库
source "$BACKUP_SCRIPT_DIR/lib/config.sh"
source "$BACKUP_SCRIPT_DIR/lib/log.sh"

# ============================================
# 测试函数
# ============================================

# test_rclone_installed - 测试 rclone 是否已安装
test_rclone_installed() {
  echo "=========================================="
  echo "测试 1/5: rclone 安装检查"
  echo "=========================================="
  echo ""

  if ! command -v rclone &> /dev/null; then
    log_error "rclone 未安装"
    echo ""
    echo "安装命令："
    echo "  brew install rclone"
    return 1
  fi

  local version
  version=$(rclone version | head -1)
  log_success "rclone 已安装: $version"
  echo ""

  # 检查版本是否 >= 1.60
  local version_number
  version_number=$(echo "$version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

  if [[ -n "$version_number" ]]; then
    local major minor
    major=$(echo "$version_number" | cut -d. -f1)
    minor=$(echo "$version_number" | cut -d. -f2)

    if [[ $major -gt 1 ]] || [[ $major -eq 1 && $minor -ge 60 ]]; then
      log_success "rclone 版本符合要求 (>= 1.60)"
    else
      log_error "rclone 版本过低 (< 1.60)，请升级"
      return 1
    fi
  else
    log_warn "无法解析版本号，跳过版本检查"
  fi

  echo ""
  return 0
}

# test_b2_credentials - 测试 B2 凭证配置
test_b2_credentials() {
  echo "=========================================="
  echo "测试 2/5: B2 凭证配置"
  echo "=========================================="
  echo ""

  load_config

  local b2_account_id
  local b2_application_key
  local b2_bucket_name

  b2_account_id=$(get_b2_account_id)
  b2_application_key=$(get_b2_application_key)
  b2_bucket_name=$(get_b2_bucket_name)

  if [[ -z "$b2_account_id" ]]; then
    log_error "B2_ACCOUNT_ID 未设置"
    echo ""
    echo "请在 .env.backup 中设置："
    echo "  B2_ACCOUNT_ID=your_account_id"
    return 1
  fi

  if [[ -z "$b2_application_key" ]]; then
    log_error "B2_APPLICATION_KEY 未设置"
    echo ""
    echo "请在 .env.backup 中设置："
    echo "  B2_APPLICATION_KEY=your_application_key"
    return 1
  fi

  if [[ -z "$b2_bucket_name" ]]; then
    log_error "B2_BUCKET_NAME 未设置"
    echo ""
    echo "请在 .env.backup 中设置："
    echo "  B2_BUCKET_NAME=noda-backups"
    return 1
  fi

  log_success "B2_ACCOUNT_ID: ${b2_account_id:0:20}..."
  log_success "B2_APPLICATION_KEY: ${b2_application_key:0:20}..."
  log_success "B2_BUCKET_NAME: $b2_bucket_name"
  echo ""

  return 0
}

# test_rclone_config - 测试 rclone 配置创建
test_rclone_config() {
  echo "=========================================="
  echo "测试 3/5: rclone 配置创建"
  echo "=========================================="
  echo ""

  load_config

  local rclone_config
  rclone_config=$(mktemp)
  chmod 600 "$rclone_config"

  local b2_account_id
  local b2_application_key

  b2_account_id=$(get_b2_account_id)
  b2_application_key=$(get_b2_application_key)

  log_info "创建临时 rclone 配置..."

  # 直接写入配置文件（与 cloud.sh setup_rclone_config() 一致）
  cat > "$rclone_config" <<EOF
[b2remote]
type = b2
account = $b2_account_id
key = $b2_application_key
EOF

  log_success "rclone 配置写入成功"

  # 验证配置
  log_info "验证 rclone 配置..."
  if rclone listremotes --config "$rclone_config" | grep -q "b2remote:"; then
    log_success "rclone 配置验证成功"
  else
    log_error "rclone 配置验证失败"
    rm -f "$rclone_config"
    return 1
  fi

  # 清理配置
  rm -f "$rclone_config"
  echo ""

  return 0
}

# test_b2_connection - 测试 B2 连接
test_b2_connection() {
  echo "=========================================="
  echo "测试 4/5: B2 连接测试"
  echo "=========================================="
  echo ""

  load_config

  local rclone_config
  rclone_config=$(mktemp)
  chmod 600 "$rclone_config"

  local b2_account_id
  local b2_application_key
  local b2_bucket_name

  b2_account_id=$(get_b2_account_id)
  b2_application_key=$(get_b2_application_key)
  b2_bucket_name=$(get_b2_bucket_name)

  # 直接写入配置文件（与 cloud.sh setup_rclone_config() 一致）
  cat > "$rclone_config" <<EOF
[b2remote]
type = b2
account = $b2_account_id
key = $b2_application_key
EOF

  # 测试连接
  log_info "测试 B2 bucket 连接..."
  if rclone lsd "b2remote:${b2_bucket_name}" \
    --config "$rclone_config" >/dev/null 2>&1; then
    log_success "B2 bucket 连接成功: $b2_bucket_name"
  else
    log_error "B2 bucket 连接失败: $b2_bucket_name"
    echo ""
    echo "可能的原因："
    echo "  1. Bucket 名称错误"
    echo "  2. Application Key 权限不足"
    echo "  3. 网络连接问题"
    rm -f "$rclone_config"
    return 1
  fi

  # 清理配置
  rm -f "$rclone_config"
  echo ""

  return 0
}

# test_b2_operations - 测试 B2 基本操作
test_b2_operations() {
  echo "=========================================="
  echo "测试 5/5: B2 基本操作"
  echo "=========================================="
  echo ""

  load_config

  local rclone_config
  rclone_config=$(mktemp)
  chmod 600 "$rclone_config"

  local b2_account_id
  local b2_application_key
  local b2_bucket_name
  local b2_path

  b2_account_id=$(get_b2_account_id)
  b2_application_key=$(get_b2_application_key)
  b2_bucket_name=$(get_b2_bucket_name)
  b2_path=$(get_b2_path)

  # 直接写入配置文件（与 cloud.sh setup_rclone_config() 一致）
  cat > "$rclone_config" <<EOF
[b2remote]
type = b2
account = $b2_account_id
key = $b2_application_key
EOF

  # 创建测试文件
  local test_file
  test_file=$(mktemp)
  echo "test data $(date +%s)" > "$test_file"

  # 测试上传
  log_info "测试文件上传..."
  local remote_path="${b2_bucket_name}/${b2_path}test/"
  if rclone copy "$test_file" "b2remote:${remote_path}" \
    --config "$rclone_config" >/dev/null 2>&1; then
    log_success "文件上传成功"
  else
    log_error "文件上传失败"
    rm -f "$test_file" "$rclone_config"
    return 1
  fi

  # 测试列表
  log_info "测试文件列表..."
  if rclone ls "b2remote:${remote_path}" \
    --config "$rclone_config" >/dev/null 2>&1; then
    log_success "文件列表成功"
  else
    log_error "文件列表失败"
    rm -f "$test_file" "$rclone_config"
    return 1
  fi

  # 测试删除
  log_info "测试文件删除..."
  if rclone delete "b2remote:${remote_path}" \
    --config "$rclone_config" >/dev/null 2>&1; then
    log_success "文件删除成功"
  else
    log_error "文件删除失败"
    rm -f "$test_file" "$rclone_config"
    return 1
  fi

  # 清理
  rm -f "$test_file" "$rclone_config"
  echo ""

  return 0
}

# ============================================
# 主函数
# ============================================
main() {
  echo "=========================================="
  echo "rclone 配置完整测试"
  echo "=========================================="
  echo ""

  local failed=0

  if ! test_rclone_installed; then
    ((failed++))
  fi

  if ! test_b2_credentials; then
    ((failed++))
  fi

  if ! test_rclone_config; then
    ((failed++))
  fi

  if ! test_b2_connection; then
    ((failed++))
  fi

  if ! test_b2_operations; then
    ((failed++))
  fi

  # 输出结果
  echo "=========================================="
  if [[ $failed -eq 0 ]]; then
    log_success "所有 5/5 测试通过！rclone 配置正确"
  else
    log_error "测试失败：$failed/5"
  fi
  echo "=========================================="

  [[ $failed -eq 0 ]]
}

# 执行主函数
main "$@"
