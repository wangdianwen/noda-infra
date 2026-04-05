#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 健康检查库
# ============================================
# 功能：备份前前置检查（连接状态 + 磁盘空间）
# 依赖：config.sh（加载配置）
# 作者：Noda 团队
# 版本：1.0.0
# ============================================

set -euo pipefail

# 加载依赖库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/constants.sh"

# 加载配置函数（如果尚未加载）
if ! type get_postgres_host &>/dev/null; then
  source "$SCRIPT_DIR/config.sh"
fi

# ============================================
# PostgreSQL 连接检查
# ============================================

# check_postgres_connection - 检查 PostgreSQL 连接状态
# 参数：无（使用全局配置变量）
# 返回：0=成功，1=失败
check_postgres_connection() {
  local postgres_host
  local postgres_port
  local postgres_user

  # 获取配置（从 config.sh）
  postgres_host=$(get_postgres_host)
  postgres_port=$(get_postgres_port)
  postgres_user=$(get_postgres_user)

  echo "ℹ️  检查 PostgreSQL 连接状态..."

  # 使用 pg_isready 检查连接（D-05）
  if docker exec "$postgres_host" pg_isready -U "$postgres_user" -h localhost -p "$postgres_port" > /dev/null 2>&1; then
    echo "✅ PostgreSQL 连接正常"
    return 0
  else
    echo "❌ 错误: PostgreSQL 连接失败"
    echo ""
    echo "可能的原因："
    echo "  1. PostgreSQL 容器未运行（检查：docker ps）"
    echo "  2. PostgreSQL 服务未启动（检查：docker logs $postgres_host）"
    echo "  3. 网络连接问题（检查：docker network ls）"
    echo "  4. 认证配置错误（检查：.pgpass 文件）"
    echo ""
    echo "解决建议："
    echo "  - 运行: docker ps -a | grep postgres"
    echo "  - 运行: docker logs $postgres_host --tail 50"
    echo "  - 检查: POSTGRES_HOST、POSTGRES_PORT、POSTGRES_USER 配置"
    return $EXIT_CONNECTION_FAILED
  fi
}

# ============================================
# 数据库大小查询
# ============================================

# get_database_size - 获取单个数据库大小
# 参数：$1 = 数据库名
# 返回：数据库大小（字节）
get_database_size() {
  local db_name="$1"
  local postgres_host
  local postgres_user

  postgres_host=$(get_postgres_host)
  postgres_user=$(get_postgres_user)

  # 使用 pg_database_size 函数查询数据库大小
  docker exec "$postgres_host" psql -U "$postgres_user" -d postgres -t -c \
    "SELECT pg_database_size('$db_name');" 2>/dev/null | tr -d ' '
}

# get_total_database_size - 获取所有用户数据库总大小
# 参数：无
# 返回：数据库总大小（字节）
get_total_database_size() {
  local postgres_host
  local postgres_user
  local total_size=0

  postgres_host=$(get_postgres_host)
  postgres_user=$(get_postgres_user)

  echo "ℹ️  查询所有用户数据库大小..."

  # 查询所有用户数据库（排除模板数据库和系统数据库）
  local databases
  databases=$(docker exec "$postgres_host" psql -U "$postgres_user" -d postgres -t -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres', 'template0', 'template1') ORDER BY datname;" 2>/dev/null | tr -d ' ')

  # 累加每个数据库的大小
  for db in $databases; do
    local db_size
    db_size=$(get_database_size "$db")

    if [[ -n "$db_size" && "$db_size" =~ ^[0-9]+$ ]]; then
      total_size=$((total_size + db_size))
      # 转换为 GB 显示（保留 2 位小数）
      local db_size_gb
      db_size_gb=$(echo "scale=2; $db_size / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
      echo "  - $db: ${db_size_gb} GB ($db_size 字节)"
    fi
  done

  echo "$total_size"
}

# ============================================
# 磁盘空间检查
# ============================================

# check_disk_space - 检查磁盘空间（容器 + 宿主机）
# 参数：无（使用全局配置变量）
# 返回：0=成功，2=空间不足
check_disk_space() {
  local postgres_host
  local backup_dir

  postgres_host=$(get_postgres_host)
  backup_dir=$(get_backup_dir)

  echo "ℹ️  检查磁盘空间..."

  # 1. 获取所有数据库总大小
  local total_db_size
  total_db_size=$(get_total_database_size)

  if [[ -z "$total_db_size" || ! "$total_db_size" =~ ^[0-9]+$ ]]; then
    echo "❌ 错误: 无法获取数据库大小"
    return $EXIT_DISK_SPACE_INSUFFICIENT
  fi

  # 2. 计算所需空间：数据库大小 × 2（D-15）
  local required_space=$((total_db_size * 2))
  local required_space_gb
  required_space_gb=$(echo "scale=2; $required_space / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")

  echo "ℹ️  所需磁盘空间: ${required_space_gb} GB (数据库大小 × 2)"

  # 3. 检查容器内磁盘空间（D-14）
  echo "ℹ️  检查容器内磁盘空间..."
  local container_available
  container_available=$(docker exec "$postgres_host" df -B1 "$backup_dir" 2>/dev/null | tail -1 | awk '{print $4}')

  if [[ -z "$container_available" || ! "$container_available" =~ ^[0-9]+$ ]]; then
    echo "❌ 错误: 无法获取容器内磁盘空间"
    return $EXIT_DISK_SPACE_INSUFFICIENT
  fi

  local container_available_gb
  container_available_gb=$(echo "scale=2; $container_available / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
  echo "  - 容器内可用空间: ${container_available_gb} GB"

  if [[ $container_available -lt $required_space ]]; then
    echo "❌ 错误: 容器内磁盘空间不足"
    echo "  - 可用: ${container_available_gb} GB"
    echo "  - 需要: ${required_space_gb} GB"
    echo ""
    echo "解决建议："
    echo "  - 清理旧的备份文件"
    echo "  - 扩展 Docker volume 大小"
    echo "  - 检查: docker exec $postgres_host df -h"
    return $EXIT_DISK_SPACE_INSUFFICIENT
  fi

  # 4. 检查宿主机磁盘空间（D-14）
  echo "ℹ️  检查宿主机磁盘空间..."
  local host_backup_dir="/var/lib/docker/volumes/noda-infra_postgres_data/_data"

  # 检查宿主机路径是否存在
  if [[ ! -d "$host_backup_dir" ]]; then
    echo "⚠️  警告: 宿主机备份目录不存在: $host_backup_dir"
    echo "  - 跳过宿主机磁盘空间检查"
  else
    local host_available
    host_available=$(df -B1 "$host_backup_dir" 2>/dev/null | tail -1 | awk '{print $4}')

    if [[ -z "$host_available" || ! "$host_available" =~ ^[0-9]+$ ]]; then
      echo "❌ 错误: 无法获取宿主机磁盘空间"
      return $EXIT_DISK_SPACE_INSUFFICIENT
    fi

    local host_available_gb
    host_available_gb=$(echo "scale=2; $host_available / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
    echo "  - 宿主机可用空间: ${host_available_gb} GB"

    if [[ $host_available -lt $required_space ]]; then
      echo "❌ 错误: 宿主机磁盘空间不足"
      echo "  - 可用: ${host_available_gb} GB"
      echo "  - 需要: ${required_space_gb} GB"
      echo ""
      echo "解决建议："
      echo "  - 清理宿主机磁盘空间"
      echo "  - 检查: df -h $host_backup_dir"
      return $EXIT_DISK_SPACE_INSUFFICIENT
    fi
  fi

  echo "✅ 磁盘空间检查通过"
  return 0
}

# ============================================
# 综合检查函数
# ============================================

# check_prerequisites - 综合检查函数（连接 + 磁盘空间）
# 参数：无
# 返回：0=成功，非0=失败
check_prerequisites() {
  echo "=========================================="
  echo "备份前健康检查"
  echo "=========================================="
  echo ""

  # 1. 检查 PostgreSQL 连接
  if ! check_postgres_connection; then
    return $EXIT_CONNECTION_FAILED
  fi

  echo ""

  # 2. 检查磁盘空间
  if ! check_disk_space; then
    return $EXIT_DISK_SPACE_INSUFFICIENT
  fi

  echo ""
  echo "=========================================="
  echo "✅ 所有健康检查通过"
  echo "=========================================="
  return 0
}

# ============================================
# 辅助函数：获取数据库列表
# ============================================

# list_databases - 列出所有可备份的用户数据库
# 参数：无
# 返回：数据库名列表（每行一个）
list_databases() {
  local postgres_host
  local postgres_user

  postgres_host=$(get_postgres_host)
  postgres_user=$(get_postgres_user)

  # 查询所有用户数据库（排除模板数据库和系统数据库）
  docker exec "$postgres_host" psql -U "$postgres_user" -d postgres -t -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres', 'template0', 'template1') ORDER BY datname;" 2>/dev/null | tr -d ' '
}
