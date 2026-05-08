#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# ============================================
# 安全的 upstream 更新脚本（Phase 56-01）
# ============================================
# 功能：安全地更新 upstream 配置，防止环境混淆
# 用途：Pipeline 中替代直接修改 upstream 文件
# 防护：
#   1. 环境验证（prod/preprod）
#   2. 文件权限检查（jenkins 用户所有）
#   3. 内容验证（防止环境标识混淆）
#   4. 原子替换（使用临时文件 + mv）
# ============================================

# 检查环境
check_environment() {
    local environment="$1"

    case "$environment" in
        prod)
            local upstream_file="/opt/noda/upstream/upstream.conf"
            local expected_prefix=""
            ;;
        preprod)
            local upstream_file="/opt/noda/upstream/_preprod_upstream.conf"
            local expected_prefix="_preprod_"
            ;;
        *)
            log_error "不支持的环境: $environment"
            exit 1
            ;;
    esac

    # 检查文件是否存在
    if [ ! -f "$upstream_file" ]; then
        log_error "上游文件不存在: $upstream_file"
        exit 1
    fi

    # 检查文件所有者（应该是 jenkins 用户）
    local file_owner
    if stat -c "%U" "$upstream_file" >/dev/null 2>&1; then
        file_owner=$(stat -c "%U" "$upstream_file")
    else
        # macOS 兼容：使用 stat -f '%Su'
        file_owner=$(stat -f '%Su' "$upstream_file")
    fi

    if [ "$file_owner" != "jenkins" ]; then
        log_warning "上游文件所有者不是 jenkins: $file_owner"
        log_warning "建议运行: sudo chown jenkins:jenkins $upstream_file"
    fi

    echo "$upstream_file" "$expected_prefix"
}

# 安全写入 upstream
safe_update_upstream() {
    local environment="$1"
    local color="$2"
    local upstream_file="$3"
    local expected_prefix="$4"

    # 生成新内容（根据环境选择容器名称）
    local new_content
    if [ "$environment" = "prod" ]; then
        new_content="# noda-apps upstream 变量 — prod 环境
# 由 update-upstream.sh 在蓝绿切换时更新
set \$findclass_upstream noda-apps-${color}:3000;
set \$www_upstream noda-apps-${color}:3002;
set \$auth_app_upstream noda-apps-${color}:3004;
set \$admin_upstream noda-apps-${color}:3006;
set \$admin_api_upstream noda-apps-${color}:3011;"
    else
        new_content="# noda-apps upstream 变量 — preprod 环境
# 由 update-upstream.sh 在蓝绿切换时更新
set \$findclass_upstream noda-apps-preprod-${color}:3000;
set \$www_upstream noda-apps-preprod-${color}:3002;
set \$auth_app_upstream noda-apps-preprod-${color}:3004;
set \$admin_upstream noda-apps-preprod-${color}:3006;
set \$admin_api_upstream noda-apps-preprod-${color}:3011;"
    fi

    # 写入临时文件
    local tmp_file="${upstream_file}.tmp.$$"
    echo "$new_content" >"$tmp_file"

    # 验证内容：preprod 必须包含标识，prod 不能包含标识
    if [ "$environment" = "preprod" ]; then
        if ! echo "$new_content" | grep -q "noda-apps-preprod"; then
            log_error "Pre-prod upstream 内容不包含 preprod 标识"
            rm -f "$tmp_file"
            exit 1
        fi
    elif [ "$environment" = "prod" ]; then
        if echo "$new_content" | grep -q "noda-apps-preprod"; then
            log_error "Prod upstream 内容包含 preprod 标识"
            rm -f "$tmp_file"
            exit 1
        fi
    fi

    # 原子替换
    if [ -w "$upstream_file" ]; then
        mv "$tmp_file" "$upstream_file"
    else
        # 需要sudo 权限
        sudo mv "$tmp_file" "$upstream_file"
    fi

    log_success "Upstream 更新完成: $environment -> $color"
}

# 主函数
main() {
    local environment="$1"
    local color="$2"

    log_info "开始更新 upstream: $environment 环境 -> $color"

    # 检查环境
    local check_result
    check_result=$(check_environment "$environment")
    local upstream_file=$(echo "$check_result" | cut -d' ' -f1)
    local expected_prefix=$(echo "$check_result" | cut -d' ' -f2)

    # 安全更新
    safe_update_upstream "$environment" "$color" "$upstream_file" "$expected_prefix"
}

# 参数检查
if [ $# -ne 2 ]; then
    echo "用法: $0 <prod|preprod> <blue|green>"
    exit 1
fi

# 验证颜色参数
if [[ ! "$2" =~ ^(blue|green)$ ]]; then
    echo "错误: 颜色参数必须是 blue 或 green"
    exit 1
fi

main "$1" "$2"
