#!/bin/bash
# 测试 B2 配置函数

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BACKUP_DIR/lib/config.sh"

echo "=========================================="
echo "测试 B2 配置函数"
echo "=========================================="
echo ""

load_config

echo "B2_ACCOUNT_ID: $(get_b2_account_id | head -c 20)..."
echo "B2_APPLICATION_KEY: $(get_b2_application_key | head -c 20)..."
echo "B2_BUCKET_NAME: $(get_b2_bucket_name)"
echo "B2_PATH: $(get_b2_path)"
echo ""

if validate_b2_credentials; then
    echo "✅ B2 配置函数测试通过"
    exit 0
else
    echo "❌ B2 配置函数测试失败"
    exit 1
fi
