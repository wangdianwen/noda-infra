#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 指标库
# ============================================
# 功能：耗时追踪和历史记录管理
# 依赖：constants.sh, log.sh, alert.sh
# ============================================

set -euo pipefail

# 引入依赖
_METRICS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 条件 source constants.sh（避免重复定义 readonly 变量）
if [[ -z "${EXIT_SUCCESS+x}" ]]; then
    # shellcheck source=lib/constants.sh
    source "$_METRICS_LIB_DIR/constants.sh"
fi

# 条件 source log.sh
if [[ "$(type -t log_info)" != "function" ]]; then
    # shellcheck source=lib/log.sh
    source "$_METRICS_LIB_DIR/log.sh"
fi

# 条件 source alert.sh（避免重复 source constants.sh）
if [[ "$(type -t send_alert)" != "function" ]]; then
    # shellcheck source=lib/alert.sh
    source "$_METRICS_LIB_DIR/alert.sh"
fi

# ============================================
# 指标记录函数
# ============================================

# record_metric - 记录指标
# 参数：
#   $1: 操作类型（backup, upload, verify）
#   $2: 数据库
#   $3: 耗时（秒）
#   $4: 文件大小（字节，可选）
record_metric()
{
    local operation=$1
    local database=$2
    local duration=$3
    local file_size=${4:-0}

    # 初始化历史文件
    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo "[]" >"$HISTORY_FILE"
    fi

    # 构建新记录
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local new_record
    new_record=$(
        cat <<EOF
{
  "timestamp": "$timestamp",
  "database": "$database",
  "operation": "$operation",
  "duration": $duration,
  "file_size": $file_size
}
EOF
    )

    # 添加到历史文件
    local temp_file="${HISTORY_FILE}.tmp"
    jq ". += [$new_record]" "$HISTORY_FILE" >"$temp_file"
    mv "$temp_file" "$HISTORY_FILE"

    log_info "记录指标: $operation - $database - ${duration}s"
}

# ============================================
# 平均值计算函数
# ============================================

# calculate_average_duration - 计算平均耗时
# 参数：
#   $1: 数据库
#   $2: 操作类型
# 返回：平均耗时（秒）
calculate_average_duration()
{
    local database=$1
    local operation=$2

    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo "0"
        return
    fi

    # 获取最近 N 次记录
    local recent_records
    recent_records=$(jq \
        "[.[] | select(.database==\"$database\" and .operation==\"$operation\")] | reverse | .[0:$METRICS_WINDOW_SIZE]" \
        "$HISTORY_FILE" 2>/dev/null)

    # 计算平均值
    local sum
    sum=$(echo "$recent_records" | jq "[].duration | add" 2>/dev/null || echo "0")

    local count
    count=$(echo "$recent_records" | jq "length" 2>/dev/null || echo "0")

    if [[ $count -gt 0 && $sum -gt 0 ]]; then
        local average=$((sum / count))
        echo "$average"
    else
        echo "0"
    fi
}

# ============================================
# 异常检测函数
# ============================================

# check_duration_anomaly - 检查耗时异常
# 参数：
#   $1: 数据库
#   $2: 操作类型
#   $3: 当前耗时
check_duration_anomaly()
{
    local database=$1
    local operation=$2
    local current_duration=$3

    # 计算历史平均值
    local average
    average=$(calculate_average_duration "$database" "$operation")

    if [[ $average -eq 0 ]]; then
        return 0 # 无历史数据
    fi

    # 计算偏差
    local deviation=$(((current_duration - average) * 100 / average))

    if [[ $deviation -gt $METRICS_ANOMALY_THRESHOLD ]]; then
        log_warn "耗时异常: $database - $operation"
        log_warn "  当前: ${current_duration}s, 平均: ${average}s, 偏差: +${deviation}%"

        # 发送告警
        send_alert "duration_anomaly" "$database" \
            "耗时异常 ($operation): 当前 ${current_duration}s，平均 ${average}s，偏差 +${deviation}%"

        return 1
    fi

    return 0
}

# ============================================
# 历史记录清理函数
# ============================================

# cleanup_old_metrics - 清理旧的历史记录（保留 7 天）
cleanup_old_metrics()
{
    if [[ ! -f "$HISTORY_FILE" ]]; then
        return 0
    fi

    local cutoff_time
    cutoff_time=$(date -d "$LOG_RETENTION_DAYS days ago" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -v-${LOG_RETENTION_DAYS}d -u +"%Y-%m-%dT%H:%M:%SZ")

    # 过滤掉旧记录（timestamp 为 ISO 8601 格式，使用字符串比较）
    local temp_file="${HISTORY_FILE}.tmp"
    jq "[.[] | select(.timestamp >= \"$cutoff_time\")]" "$HISTORY_FILE" >"$temp_file" 2>/dev/null
    mv "$temp_file" "$HISTORY_FILE"

    log_info "已清理 $LOG_RETENTION_DAYS 天前的历史记录"
}

# cleanup_old_alerts - 清理旧的告警记录（保留 7 天）
cleanup_old_alerts()
{
    if [[ ! -f "$ALERT_HISTORY_FILE" ]]; then
        return 0
    fi

    local cutoff_time
    cutoff_time=$(date +%s)
    cutoff_time=$((cutoff_time - (LOG_RETENTION_DAYS * 86400)))

    # 过滤掉旧记录
    local temp_file="${ALERT_HISTORY_FILE}.tmp"
    jq "[.[] | select(.time >= $cutoff_time)]" "$ALERT_HISTORY_FILE" >"$temp_file" 2>/dev/null
    mv "$temp_file" "$ALERT_HISTORY_FILE"

    log_info "已清理 $LOG_RETENTION_DAYS 天前的告警记录"
}

# ============================================
# 主函数（支持命令行调用）
# ============================================

# 如果脚本被直接执行（而不是被 source），则运行主函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        cleanup)
            cleanup_old_metrics
            cleanup_old_alerts
            ;;
        *)
            echo "用法: $0 {cleanup}"
            exit 1
            ;;
    esac
fi
