#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 云上传测试脚本（简化版）
# ============================================

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载依赖库
source "$BACKUP_SCRIPT_DIR/lib/constants.sh"
source "$BACKUP_SCRIPT_DIR/lib/config.sh"
source "$BACKUP_SCRIPT_DIR/lib/util.sh"
source "$BACKUP_SCRIPT_DIR/lib/log.sh"
source "$BACKUP_SCRIPT_DIR/lib/cloud.sh"

echo "=========================================="
echo "云上传端到端测试"
echo "=========================================="
echo ""

# 1. rclone 安装检查
echo "测试 1/6: rclone 安装检查"
if ! command -v rclone &>/dev/null; then
    log_error "rclone 未安装"
    exit 1
fi
log_success "rclone 已安装"
echo ""

# 2. B2 凭证配置
echo "测试 2/6: B2 凭证配置"
load_config
if ! validate_b2_credentials; then
    log_error "B2 凭证验证失败"
    exit 1
fi
log_success "B2 凭证配置正确"
echo ""

# 3. 创建测试备份
echo "测试 3/6: 创建测试备份"
test_backup_dir=$(mktemp -d)
log_info "创建测试备份目录: $test_backup_dir"

echo "Test database dump - created at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$test_backup_dir/test_db_$(date +%Y%m%d_%H%M%S).dump"
echo "Test globals - created at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$test_backup_dir/globals_$(date +%Y%m%d_%H%M%S).sql"
echo '{"test": "metadata"}' >"$test_backup_dir/metadata_test.json"

file_count=$(find "$test_backup_dir" -type f | wc -l | tr -d ' ')
log_success "测试备份创建成功（共 $file_count 个文件）"
echo ""

# 4. 上传到 B2
echo "测试 4/6: 上传到 B2"
log_info "上传测试备份到 B2..."
if ! upload_to_b2 "$test_backup_dir"; then
    log_error "上传失败"
    rm -rf "$test_backup_dir"
    exit 1
fi
log_success "上传成功"
echo ""

# 5. 验证上传
echo "测试 5/6: 验证上传文件"
b2_bucket_name=$(get_b2_bucket_name)
b2_path=$(get_b2_path)

rclone_config=$(setup_rclone_config)
file_count=$(rclone ls "b2remote:${b2_bucket_name}/${b2_path}" \
    --config "$rclone_config" \
    2>/dev/null | wc -l | tr -d ' ')
cleanup_rclone_config "$rclone_config"

if [[ $file_count -gt 0 ]]; then
    log_success "验证成功（B2 上有 $file_count 个文件）"
else
    log_error "验证失败（B2 上没有文件）"
    rm -rf "$test_backup_dir"
    exit 1
fi
echo ""

# 6. 清理测试文件
echo "测试 6/6: 清理测试文件"
rm -rf "$test_backup_dir"
log_success "本地测试文件已清理"

if cleanup_old_backups_b2 0; then
    log_success "B2 测试文件已清理"
else
    log_warn "B2 测试文件清理失败（可能没有测试文件）"
fi
echo ""

# 完成
echo "=========================================="
log_success "所有测试通过！云上传功能正常"
echo "=========================================="
