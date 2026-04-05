#!/bin/bash
# 清理 B2 测试文件

set -euo pipefail

BACKUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BACKUP_SCRIPT_DIR/lib/constants.sh"
source "$BACKUP_SCRIPT_DIR/lib/config.sh"
source "$BACKUP_SCRIPT_DIR/lib/cloud.sh"

load_config

echo "清理 B2 上的测试文件..."

# 创建配置
rclone_config=$(mktemp)
chmod 600 "$rclone_config"

b2_account_id=$(get_b2_account_id)
b2_application_key=$(get_b2_application_key)

cat > "$rclone_config" <<EOF
[b2remote]
type = b2
account = $b2_account_id
key = $b2_application_key
EOF

# 删除测试文件
b2_bucket_name=$(get_b2_bucket_name)
b2_path=$(get_b2_path)

rclone delete "b2remote:${b2_bucket_name}/${b2_path}2026/04/06/" \
  --config "$rclone_config" \
  --quiet

rm -f "$rclone_config"

echo "✅ B2 测试文件已清理"
