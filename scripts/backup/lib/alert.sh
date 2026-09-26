#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 告警库
# ============================================
# 功能：邮件告警系统，支持去重和模板
# 依赖：constants.sh, log.sh
# ============================================

set -euo pipefail

# 引入依赖
_ALERT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 条件 source constants.sh（避免重复定义 readonly 变量）
if [[ -z "${EXIT_SUCCESS+x}" ]]; then
    # shellcheck source=lib/constants.sh
    source "$_ALERT_LIB_DIR/constants.sh"
fi

# 条件 source log.sh
if [[ "$(type -t log_info)" != "function" ]]; then
    # shellcheck source=lib/log.sh
    source "$_ALERT_LIB_DIR/log.sh"
fi

# ============================================
# 邮件发送函数
# ============================================

# send_email - 发送邮件
# 参数：
#   $1: 收件人
#   $2: 主题
#   $3: 正文
# 通道（2026-09-26 修复容器内告警从未发出的问题）：
#   1) RESEND_API_KEY + wget（生产容器路径）：走 Resend HTTP API——容器无 MTA
#      且无 mail 命令，旧 mail 路径在容器内恒失败（静默）。与 adminapi/emailapi
#      同一发送通道（noda.co.nz 域已在 Resend 验证），凭据经 Doppler → compose
#      env-file 注入。busybox wget 支持 --post-data/--header。
#   2) mail 命令（本机开发兜底）：无 RESEND_API_KEY 时走原路径。
send_email()
{
    local recipient=$1
    local subject=$2
    local body=$3

    # 通道 1：Resend HTTP API（生产容器；jq 缺席时落到通道 2，防 set -e 中断）
    if [[ -n "${RESEND_API_KEY:-}" ]] && command -v wget >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        local from="${RESEND_FROM_EMAIL:-Noda <noreply@noda.co.nz>}"
        local payload resp
        payload=$(jq -n \
            --arg from "$from" \
            --arg to "$recipient" \
            --arg subject "$subject" \
            --arg body "$body" \
            '{from: $from, to: [$to], subject: $subject, html: ("<pre style=\"font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;line-height:1.5;white-space:pre-wrap\">" + ($body | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")) + "</pre>")}')
        if resp=$(wget -q -O - --timeout=30 \
                --header="Authorization: Bearer ${RESEND_API_KEY}" \
                --header="Content-Type: application/json" \
                --post-data="$payload" \
                https://api.resend.com/emails 2>&1); then
            log_info "邮件发送成功（Resend）: $recipient（${resp:-无响应体}）"
            return 0
        fi
        log_error "Resend 发送失败: $recipient（${resp:-无响应}）"
        return 1
    fi

    # 通道 2：mail 命令（本机开发兜底）
    if ! command -v mail >/dev/null 2>&1; then
        log_error "无法发送邮件：RESEND_API_KEY 未设置且 mail 命令未安装"
        log_error "容器内经 Doppler 注入 RESEND_API_KEY；本机开发装 postfix+mail"
        return 1
    fi

    # 发送邮件
    echo "$body" | mail -s "$subject" "$recipient"

    if [[ $? -eq 0 ]]; then
        log_info "邮件发送成功: $recipient"
        return 0
    else
        log_error "邮件发送失败: $recipient"
        return 1
    fi
}

# ============================================
# 告警去重函数
# ============================================

# should_send_alert - 检查是否应该发送告警
# 参数：
#   $1: 告警类型
#   $2: 数据库
# 返回：0（发送）或 1（跳过）
should_send_alert()
{
    local alert_type=$1
    local database=$2
    local current_time
    current_time=$(date +%s)

    # 初始化历史文件
    if [[ ! -f "$ALERT_HISTORY_FILE" ]]; then
        echo "[]" >"$ALERT_HISTORY_FILE"
        return 0
    fi

    # 查找最近的相同告警
    local last_alert
    last_alert=$(jq -r \
        ".[] | select(.type==\"$alert_type\" and .database==\"$database\") | .time" \
        "$ALERT_HISTORY_FILE" 2>/dev/null | tail -1)

    if [[ -z "$last_alert" ]]; then
        return 0 # 无历史记录
    fi

    # 检查时间窗口
    local time_diff=$((current_time - last_alert))
    if [[ $time_diff -ge $ALERT_DEDUP_WINDOW ]]; then
        return 0 # 超过去重窗口
    else
        log_info "跳过重复告警: $alert_type - $database"
        return 1 # 在窗口内
    fi
}

# record_alert - 记录告警
# 参数：
#   $1: 告警类型
#   $2: 数据库
record_alert()
{
    local alert_type=$1
    local database=$2
    local current_time
    current_time=$(date +%s)

    # 添加到历史记录
    local temp_file="${ALERT_HISTORY_FILE}.tmp"
    jq ". += [{\"type\":\"$alert_type\",\"database\":\"$database\",\"time\":$current_time}]" \
        "$ALERT_HISTORY_FILE" >"$temp_file" 2>/dev/null
    mv "$temp_file" "$ALERT_HISTORY_FILE"
}

# ============================================
# 告警发送函数
# ============================================

# send_alert - 发送告警
# 参数：
#   $1: 告警类型
#   $2: 数据库
#   $3: 告警消息
send_alert()
{
    local alert_type=$1
    local database=$2
    local message=$3

    # 检查告警是否启用
    if [[ "$ALERT_ENABLED" != "true" ]]; then
        return 0
    fi

    # 检查收件人
    if [[ -z "$ALERT_EMAIL" ]]; then
        log_warn "ALERT_EMAIL 未设置，跳过告警"
        return 0
    fi

    # 检查去重
    if ! should_send_alert "$alert_type" "$database"; then
        return 0
    fi

    # 构建邮件内容
    local subject="[$alert_type] $database - $(date '+%Y-%m-%d %H:%M')"
    local body="备份系统告警

类型: $alert_type
数据库: $database
时间: $(date '+%Y-%m-%d %H:%M:%S UTC')

消息: $message

---
Noda 备份系统"

    # 发送邮件
    send_email "$ALERT_EMAIL" "$subject" "$body"

    # 记录告警
    record_alert "$alert_type" "$database"
}
