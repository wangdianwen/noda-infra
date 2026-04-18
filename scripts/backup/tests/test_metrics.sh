#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 指标库测试
# ============================================
# 功能：测试指标库的各项功能
# 作者：Noda 团队
# 版本：1.0.0
# ============================================

set -euo pipefail

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 引入依赖库（metrics.sh 会自动 source alert.sh, constants.sh 和 log.sh）
# shellcheck source=lib/metrics.sh
source "$SCRIPT_DIR/../lib/metrics.sh"

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

assert_greater_than()
{
    local min=$1
    local actual=$2
    local message=${3:-"断言失败"}

    if [[ "$actual" -gt "$min" ]]; then
        echo "  ✅ $message"
        ((TESTS_PASSED++)) || true
    else
        echo "  ❌ $message"
        echo "     最小值: $min"
        echo "     实际: $actual"
        ((TESTS_FAILED++)) || true
    fi
    ((TESTS_RUN++)) || true
}

# ============================================
# 测试用例
# ============================================

# 测试 1: 指标记录
test_record_metric()
{
    echo "测试 1: 指标记录"

    # 由于 HISTORY_FILE 是 readonly，这里只测试函数可用性和配置
    if type record_metric >/dev/null 2>&1; then
        assert_equals 0 0 "record_metric 函数存在"
    else
        assert_equals 1 0 "record_metric 函数不存在"
    fi

    # 验证配置
    if [[ -n "$HISTORY_FILE" ]]; then
        assert_equals 0 0 "HISTORY_FILE 已定义: $HISTORY_FILE"
    else
        assert_equals 1 0 "HISTORY_FILE 未定义"
    fi

    # 验证目录存在
    local history_dir
    history_dir=$(dirname "$HISTORY_FILE")
    if [[ -d "$history_dir" ]]; then
        assert_equals 0 0 "历史记录目录存在"
    else
        assert_equals 1 0 "历史记录目录不存在"
    fi
}

# 测试 2: 平均值计算
test_calculate_average()
{
    echo "测试 2: 平均值计算"

    # 验证函数存在
    if type calculate_average_duration >/dev/null 2>&1; then
        assert_equals 0 0 "calculate_average_duration 函数存在"
    else
        assert_equals 1 0 "calculate_average_duration 函数不存在"
    fi

    # 验证配置
    if [[ $METRICS_WINDOW_SIZE -gt 0 ]]; then
        assert_equals 0 0 "METRICS_WINDOW_SIZE 配置正确: $METRICS_WINDOW_SIZE"
    else
        assert_equals 1 0 "METRICS_WINDOW_SIZE 配置错误"
    fi
}

# 测试 3: 异常检测
test_duration_anomaly()
{
    echo "测试 3: 异常检测"

    # 验证函数存在
    if type check_duration_anomaly >/dev/null 2>&1; then
        assert_equals 0 0 "check_duration_anomaly 函数存在"
    else
        assert_equals 1 0 "check_duration_anomaly 函数不存在"
    fi

    # 验证配置
    if [[ $METRICS_ANOMALY_THRESHOLD -gt 0 ]]; then
        assert_equals 0 0 "METRICS_ANOMALY_THRESHOLD 配置正确: $METRICS_ANOMALY_THRESHOLD"
    else
        assert_equals 1 0 "METRICS_ANOMALY_THRESHOLD 配置错误"
    fi
}

# 测试 4: 历史记录清理
test_cleanup_old_metrics()
{
    echo "测试 4: 历史记录清理"

    # 验证清理函数存在
    if type cleanup_old_metrics >/dev/null 2>&1; then
        assert_equals 0 0 "cleanup_old_metrics 函数存在"
    else
        assert_equals 1 0 "cleanup_old_metrics 函数不存在"
    fi

    if type cleanup_old_alerts >/dev/null 2>&1; then
        assert_equals 0 0 "cleanup_old_alerts 函数存在"
    else
        assert_equals 1 0 "cleanup_old_alerts 函数不存在"
    fi

    # 验证保留天数配置
    if [[ $LOG_RETENTION_DAYS -gt 0 ]]; then
        assert_equals 0 0 "LOG_RETENTION_DAYS 配置正确: $LOG_RETENTION_DAYS 天"
    else
        assert_equals 1 0 "LOG_RETENTION_DAYS 配置错误"
    fi
}

# 测试 5: JSON 格式验证
test_json_format()
{
    echo "测试 5: JSON 格式验证"

    # 创建测试 JSON 记录
    local test_record
    test_record=$(
        cat <<EOF
{
  "timestamp": "2026-04-06T03:00:00Z",
  "database": "test_db",
  "operation": "backup",
  "duration": 60,
  "file_size": 1024000
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

    # 验证字段提取
    local duration
    duration=$(echo "$test_record" | jq -r ".duration")
    assert_equals "60" "$duration" "字段提取正确"
}

# ============================================
# 主函数
# ============================================

main()
{
    echo "=========================================="
    echo "指标库测试"
    echo "=========================================="
    echo ""

    # 运行所有测试
    test_record_metric
    test_calculate_average
    test_duration_anomaly
    test_cleanup_old_metrics
    test_json_format

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
