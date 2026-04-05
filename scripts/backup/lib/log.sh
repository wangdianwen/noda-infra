#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 日志库
# ============================================
# 功能：统一的日志输出格式
# 依赖：无（基础库）
# ============================================

set -euo pipefail

# ============================================
# 日志函数
# ============================================

# 输出信息日志（前缀：ℹ️）
log_info() {
  echo "ℹ️  $1"
}

# 输出警告日志（前缀：⚠️）
log_warn() {
  echo "⚠️  $1"
}

# 输出错误日志（前缀：❌，到 stderr）
log_error() {
  echo "❌ $1" >&2
}

# 输出成功日志（前缀：✅）
log_success() {
  echo "✅ $1"
}

# 输出进度日志（百分比 + 消息）
# 参数：
#   $1: 当前进度
#   $2: 总数
#   $3: 消息内容
log_progress() {
  local current=$1
  local total=$2
  local message=$3
  local percent=$((current * 100 / total))
  echo "📊 [$current/$total] ($percent%) $message"
}

# 输出 JSON 格式日志（用于结构化日志，D-47）
# 参数：
#   $1: 键名
#   $2: 值
log_json() {
  local key=$1
  local value=$2
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"$key\":\"$value\",\"timestamp\":\"$timestamp\"}"
}
