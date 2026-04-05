#!/bin/bash
# 简单的 B2 文件列表验证

set -euo pipefail

BACKUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BACKUP_SCRIPT_DIR/lib/constants.sh"
source "$BACKUP_SCRIPT_DIR/lib/config.sh"
source "$BACKUP_SCRIPT_DIR/lib/log.sh"
source "$BACKUP_SCRIPT_DIR/lib/cloud.sh"

load_config

b2_bucket_name=$(get_b2_bucket_name)
b2_path=$(get_b2_path)

echo "检查 B2 上的文件："
echo "Bucket: $b2_bucket_name"
echo "Path: $b2_path"
echo ""

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

# 列出文件
echo "B2 上的文件："
rclone ls "b2remote:${b2_bucket_name}/${b2_path}" \
  --config "$rclone_config"

rm -f "$rclone_config"
