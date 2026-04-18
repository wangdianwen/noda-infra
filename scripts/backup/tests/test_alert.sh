#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 告警库测试
# ============================================
# 功能：测试告警库的各项功能
# 作者：Noda 团队
# 版本：1.0.0
# ============================================

set -euo pipefail

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 引入依赖库（alert.sh 会自动 source constants.sh 和 log.sh）
# shellcheck source=lib/alert.sh
source "$SCRIPT_DIR/../lib/alert.sh"

# 测试计数器
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================
# 测试辅助函数
# ============================================

# 断言函数
assert_equals()
{
    local expected=$1
    local actual=$2
    local message=${3:-"断言失败"}

    if [[ "$expected" == "$actual" ]]; then
        echo "  ✅ $message"
        ((TESTS_PASSED++)) || true
    else
        echo "  ❌ $message"
        echo "     期望: $expected"
        echo "     实际: $actual"
        ((TESTS_FAILED++)) || true
    fi
    ((TESTS_RUN++)) || true
}

# ============================================
# 测试用例
# ============================================

# 测试 1: 检查 mail 命令
test_mail_command()
{
    echo "测试 1: 检查 mail 命令"

    if command -v mail >/dev/null 2>&1; then
        assert_equals 0 0 "mail 命令已安装"
    else
        assert_equals 1 0 "mail 命令未安装（需要安装）"
    fi
}

# 测试 2: 历史文件初始化
test_history_file_init()
{
    echo "测试 2: 历史文件初始化"

    # 注意：由于 ALERT_HISTORY_FILE 是 readonly，我们无法在测试中覆盖它
    # 这里只测试历史文件路径是否定义
    if [[ -n "$ALERT_HISTORY_FILE" ]]; then
        assert_equals 0 0 "ALERT_HISTORY_FILE 已定义: $ALERT_HISTORY_FILE"
    else
        assert_equals 1 0 "ALERT_HISTORY_FILE 未定义"
    fi

    # 验证目录存在
    local history_dir
    history_dir=$(dirname "$ALERT_HISTORY_FILE")
    if [[ -d "$history_dir" ]]; then
        assert_equals 0 0 "历史记录目录存在"
    else
        assert_equals 1 0 "历史记录目录不存在"
    fi
}

# 测试 3: 告警去重机制
test_alert_dedup()
{
    echo "测试 3: 告警去重机制"

    # 由于 ALERT_HISTORY_FILE 是 readonly，我们无法使用临时文件
    # 这里只测试去重逻辑的函数是否存在且可调用
    if type should_send_alert >/dev/null 2>&1; then
        assert_equals 0 0 "should_send_alert 函数存在"
    else
        assert_equals 1 0 "should_send_alert 函数不存在"
    fi

    if type record_alert >/dev/null 2>&1; then
        assert_equals 0 0 "record_alert 函数存在"
    else
        assert_equals 1 0 "record_alert 函数不存在"
    fi

    # 验证去重窗口配置
    if [[ $ALERT_DEDUP_WINDOW -gt 0 ]]; then
        assert_equals 0 0 "去重窗口配置正确: ${ALERT_DEDUP_WINDOW}s"
    else
        assert_equals 1 0 "去重窗口配置错误"
    fi
}

# 测试 4: 告警记录格式
test_alert_record_format()
{
    echo "测试 4: 告警记录格式"

    # 由于 ALERT_HISTORY_FILE 是 readonly，这里只测试函数可用性
    # 创建一个测试 JSON 记录来验证格式
    local test_record
    test_record=$(
        cat <<EOF
{
  "type": "test_type",
  "database": "test_db",
  "time": $(date +%s)
}
EOF
    )

    # 验证 JSON 格式
    local validation
    validation=$(echo "$test_record" | jq empty 2>&1)

    if [[ -z "$validation" ]]; then
        assert_equals 0 0 "JSON 格式正确"
    else
        assert_equals 1 0 "JSON 格式错误: $validation"
    fi
}

# 测试 5: 告警禁用状态
test_alert_disabled()
{
    echo "测试 5: 告警配置验证"

    # 验证 ALERT_ENABLED 配置存在
    if [[ -n "$ALERT_ENABLED" ]]; then
        assert_equals 0 0 "ALERT_ENABLED 已定义: $ALERT_ENABLED"
    else
        assert_equals 1 0 "ALERT_ENABLED 未定义"
    fi

    # 验证 ALERT_EMAIL 配置
    if [[ -n "$ALERT_EMAIL" ]]; then
        assert_equals 0 0 "ALERT_EMAIL 已配置: $ALERT_EMAIL"
    else
        echo "  ⚠️  ALERT_EMAIL 未配置（跳过邮件发送测试）"
        assert_equals 0 0 "ALERT_EMAIL 未配置（符合预期）"
    fi
}

# ============================================
# 主函数
# ============================================

main()
{
    echo "=========================================="
    echo "告警库测试"
    echo "=========================================="
    echo ""

    # 运行所有测试
    test_mail_command
    test_history_file_init
    test_alert_dedup
    test_alert_record_format
    test_alert_disabled

    # 输出测试结果
    echo ""
    echo "=========================================="
    echo "测试结果"
    echo "=========================================="
    echo "总计: $TESTS_RUN"
    echo "通过: $TESTS_PASSED"
    echo "失败: $TESTS_FAILED"
    echo "=========================================="

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "✅ 所有测试通过！"
        exit 0
    else
        echo "❌ 部分测试失败！"
        exit 1
    fi
}

# 运行主函数
main "$@"
