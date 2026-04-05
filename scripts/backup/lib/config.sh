#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 配置管理库
# ============================================
# 功能：加载和验证备份配置
# 依赖：无（基础库）
# 作者：Noda 团队
# 版本：1.0.0
# ============================================

set -euo pipefail

# ============================================
# 默认配置值
# ============================================

# PostgreSQL 连接配置
readonly DEFAULT_POSTGRES_HOST="noda-infra-postgres-1"
readonly DEFAULT_POSTGRES_PORT="5432"
readonly DEFAULT_POSTGRES_USER="postgres"

# 备份目录配置
readonly DEFAULT_BACKUP_DIR="/var/lib/postgresql/backup"
readonly DEFAULT_BACKUP_HOST_DIR="/var/lib/docker/volumes/noda-infra_postgres_data/_data/backup"

# 备份策略配置
readonly DEFAULT_RETENTION_DAYS="7"
readonly DEFAULT_TIMEOUT_SECONDS="3600"
readonly DEFAULT_COMPRESSION_LEVEL="-1"
readonly DEFAULT_PARALLEL_BACKUP="false"

# Backblaze B2 配置（Phase 2）
readonly DEFAULT_B2_ACCOUNT_ID=""
readonly DEFAULT_B2_APPLICATION_KEY=""
readonly DEFAULT_B2_BUCKET_NAME="noda-backups"
readonly DEFAULT_B2_PATH="backups/postgres/"

# ============================================
# 全局配置变量（可被外部修改）
# ============================================

POSTGRES_HOST="${DEFAULT_POSTGRES_HOST}"
POSTGRES_PORT="${DEFAULT_POSTGRES_PORT}"
POSTGRES_USER="${DEFAULT_POSTGRES_USER}"
BACKUP_DIR="${DEFAULT_BACKUP_DIR}"
BACKUP_HOST_DIR="${DEFAULT_BACKUP_HOST_DIR}"
RETENTION_DAYS="${DEFAULT_RETENTION_DAYS}"
TIMEOUT_SECONDS="${DEFAULT_TIMEOUT_SECONDS}"
COMPRESSION_LEVEL="${DEFAULT_COMPRESSION_LEVEL}"
PARALLEL_BACKUP="${DEFAULT_PARALLEL_BACKUP}"

# Backblaze B2 配置变量
B2_ACCOUNT_ID="${DEFAULT_B2_ACCOUNT_ID}"
B2_APPLICATION_KEY="${DEFAULT_B2_APPLICATION_KEY}"
B2_BUCKET_NAME="${DEFAULT_B2_BUCKET_NAME}"
B2_PATH="${DEFAULT_B2_PATH}"

# ============================================
# 配置加载函数
# ============================================

# load_config - 加载配置（按优先级：命令行参数 > .env 文件 > 默认值）
# 参数：无（从环境变量和配置文件读取）
# 返回：0=成功，非0=失败
load_config() {
  local script_dir
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  else
    script_dir="$(cd "$(dirname "${0}")/.." && pwd)"
  fi
  local config_file="${script_dir}/.env.backup"

  # 1. 加载默认值（已在全局变量中设置）

  # 2. 从 .env.backup 文件加载配置（如果存在）
  if [[ -f "$config_file" ]]; then
    echo "ℹ️  加载配置文件: $config_file"
    # 安全地加载配置文件（仅导出 KEY=value 格式的行）
    while IFS= read -r line || [[ -n "$line" ]]; do
      # 跳过空行和注释
      if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
        continue
      fi

      # 仅处理 KEY=value 格式的行
      if [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
        # 移除首尾空格
        local key value
        key="$(echo "$line" | cut -d'=' -f1 | xargs)"
        value="$(echo "$line" | cut -d'=' -f2- | xargs)"

        # 根据键名设置对应的变量
        case "$key" in
          POSTGRES_HOST)
            POSTGRES_HOST="$value"
            ;;
          POSTGRES_PORT)
            POSTGRES_PORT="$value"
            ;;
          POSTGRES_USER)
            POSTGRES_USER="$value"
            ;;
          BACKUP_DIR)
            BACKUP_DIR="$value"
            ;;
          BACKUP_HOST_DIR)
            BACKUP_HOST_DIR="$value"
            ;;
          RETENTION_DAYS)
            RETENTION_DAYS="$value"
            ;;
          TIMEOUT_SECONDS)
            TIMEOUT_SECONDS="$value"
            ;;
          COMPRESSION_LEVEL)
            COMPRESSION_LEVEL="$value"
            ;;
          PARALLEL_BACKUP)
            PARALLEL_BACKUP="$value"
            ;;
          B2_ACCOUNT_ID)
            B2_ACCOUNT_ID="$value"
            ;;
          B2_APPLICATION_KEY)
            B2_APPLICATION_KEY="$value"
            ;;
          B2_BUCKET_NAME)
            B2_BUCKET_NAME="$value"
            ;;
          B2_PATH)
            B2_PATH="$value"
            ;;
        esac
      fi
    done < "$config_file"
  else
    echo "ℹ️  配置文件不存在，使用默认值: $config_file"
  fi

  # 3. 环境变量覆盖（优先级最高）
  if [[ -n "${POSTGRES_HOST_ENV:-}" ]]; then
    POSTGRES_HOST="$POSTGRES_HOST_ENV"
  fi
  if [[ -n "${POSTGRES_PORT_ENV:-}" ]]; then
    POSTGRES_PORT="$POSTGRES_PORT_ENV"
  fi
  if [[ -n "${POSTGRES_USER_ENV:-}" ]]; then
    POSTGRES_USER="$POSTGRES_USER_ENV"
  fi
  if [[ -n "${BACKUP_DIR_ENV:-}" ]]; then
    BACKUP_DIR="$BACKUP_DIR_ENV"
  fi
  if [[ -n "${RETENTION_DAYS_ENV:-}" ]]; then
    RETENTION_DAYS="$RETENTION_DAYS_ENV"
  fi

  return 0
}

# ============================================
# 配置验证函数
# ============================================

# validate_config - 验证必需配置项
# 参数：无（验证全局配置变量）
# 返回：0=验证成功，1=验证失败
validate_config() {
  local errors=0

  # 验证 PostgreSQL 主机名
  if [[ -z "$POSTGRES_HOST" ]]; then
    echo "❌ 错误: POSTGRES_HOST 不能为空"
    ((errors++))
  fi

  # 验证 PostgreSQL 端口号（1-65535）
  if ! [[ "$POSTGRES_PORT" =~ ^[0-9]+$ ]] || [[ "$POSTGRES_PORT" -lt 1 ]] || [[ "$POSTGRES_PORT" -gt 65535 ]]; then
    echo "❌ 错误: POSTGRES_PORT 必须是 1-65535 之间的数字，当前值: $POSTGRES_PORT"
    ((errors++))
  fi

  # 验证 PostgreSQL 用户名
  if [[ -z "$POSTGRES_USER" ]]; then
    echo "❌ 错误: POSTGRES_USER 不能为空"
    ((errors++))
  fi

  # 验证备份目录路径
  if [[ -z "$BACKUP_DIR" ]]; then
    echo "❌ 错误: BACKUP_DIR 不能为空"
    ((errors++))
  fi

  # 验证保留天数（必须是正整数）
  if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || [[ "$RETENTION_DAYS" -lt 1 ]]; then
    echo "❌ 错误: RETENTION_DAYS 必须是正整数，当前值: $RETENTION_DAYS"
    ((errors++))
  fi

  # 验证超时时间（必须是正整数）
  if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECONDS" -lt 1 ]]; then
    echo "❌ 错误: TIMEOUT_SECONDS 必须是正整数，当前值: $TIMEOUT_SECONDS"
    ((errors++))
  fi

  # 验证压缩级别（-1 到 9）
  if ! [[ "$COMPRESSION_LEVEL" =~ ^-?[0-9]+$ ]] || [[ "$COMPRESSION_LEVEL" -lt -1 ]] || [[ "$COMPRESSION_LEVEL" -gt 9 ]]; then
    echo "❌ 错误: COMPRESSION_LEVEL 必须是 -1 到 9 之间的数字，当前值: $COMPRESSION_LEVEL"
    ((errors++))
  fi

  # 返回验证结果
  if [[ $errors -gt 0 ]]; then
    echo "❌ 配置验证失败，共 $errors 个错误"
    return 1
  fi

  echo "✅ 配置验证成功"
  return 0
}

# ============================================
# 配置访问函数
# ============================================

# get_backup_dir - 返回备份目录路径
# 参数：无
# 返回：备份目录路径（字符串）
get_backup_dir() {
  echo "$BACKUP_DIR"
}

# get_retention_days - 返回保留天数
# 参数：无
# 返回：保留天数（整数）
get_retention_days() {
  echo "$RETENTION_DAYS"
}

# get_postgres_host - 返回 PostgreSQL 主机名
# 参数：无
# 返回：PostgreSQL 主机名（字符串）
get_postgres_host() {
  echo "$POSTGRES_HOST"
}

# get_postgres_port - 返回 PostgreSQL 端口号
# 参数：无
# 返回：PostgreSQL 端口号（字符串）
get_postgres_port() {
  echo "$POSTGRES_PORT"
}

# get_postgres_user - 返回 PostgreSQL 用户名
# 参数：无
# 返回：PostgreSQL 用户名（字符串）
get_postgres_user() {
  echo "$POSTGRES_USER"
}

# get_timeout_seconds - 返回超时时间
# 参数：无
# 返回：超时时间（秒）
get_timeout_seconds() {
  echo "$TIMEOUT_SECONDS"
}

# ============================================
# B2 配置访问函数（Phase 2）
# ============================================

# get_b2_account_id - 返回 B2 Account ID
# 参数：无
# 返回：B2 Account ID（字符串）
get_b2_account_id() {
  echo "$B2_ACCOUNT_ID"
}

# get_b2_application_key - 返回 B2 Application Key
# 参数：无
# 返回：B2 Application Key（字符串）
get_b2_application_key() {
  echo "$B2_APPLICATION_KEY"
}

# get_b2_bucket_name - 返回 B2 Bucket 名称
# 参数：无
# 返回：B2 Bucket 名称（字符串）
get_b2_bucket_name() {
  echo "$B2_BUCKET_NAME"
}

# get_b2_path - 返回 B2 路径前缀
# 参数：无
# 返回：B2 路径前缀（字符串）
get_b2_path() {
  echo "$B2_PATH"
}

# validate_b2_credentials - 验证 B2 凭证配置
# 参数：无
# 返回：0=验证成功，1=验证失败
validate_b2_credentials() {
  local b2_account_id
  local b2_application_key
  local b2_bucket_name

  b2_account_id=$(get_b2_account_id)
  b2_application_key=$(get_b2_application_key)
  b2_bucket_name=$(get_b2_bucket_name)

  if [[ -z "$b2_account_id" ]]; then
    echo "❌ 错误: B2_ACCOUNT_ID 未设置"
    echo "  请在 .env.backup 中设置: B2_ACCOUNT_ID=your_account_id"
    return 1
  fi

  if [[ -z "$b2_application_key" ]]; then
    echo "❌ 错误: B2_APPLICATION_KEY 未设置"
    echo "  请在 .env.backup 中设置: B2_APPLICATION_KEY=your_application_key"
    return 1
  fi

  if [[ -z "$b2_bucket_name" ]]; then
    echo "❌ 错误: B2_BUCKET_NAME 未设置"
    echo "  请在 .env.backup 中设置: B2_BUCKET_NAME=noda-backups"
    return 1
  fi

  return 0
}

# ============================================
# 显示当前配置（用于调试）
# ============================================

# show_config - 显示当前配置
# 参数：无
# 返回：无（输出到标准输出）
show_config() {
  echo "=========================================="
  echo "当前配置"
  echo "=========================================="
  echo "PostgreSQL 连接:"
  echo "  主机: $POSTGRES_HOST"
  echo "  端口: $POSTGRES_PORT"
  echo "  用户: $POSTGRES_USER"
  echo ""
  echo "备份配置:"
  echo "  备份目录（容器内）: $BACKUP_DIR"
  echo "  备份目录（宿主机）: $BACKUP_HOST_DIR"
  echo "  保留天数: $RETENTION_DAYS"
  echo "  超时时间: $TIMEOUT_SECONDS 秒"
  echo "  压缩级别: $COMPRESSION_LEVEL"
  echo "  并行备份: $PARALLEL_BACKUP"
  echo "=========================================="
}
