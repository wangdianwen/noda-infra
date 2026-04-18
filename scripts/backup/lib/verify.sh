#!/bin/bash
set -euo pipefail

# ============================================
# Noda 数据库备份系统 - 验证库
# ============================================
# 功能：备份验证（pg_restore --list、SHA-256 校验和）
# 依赖：constants.sh, log.sh, util.sh
# ============================================

# 加载依赖库
_VERIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 条件 source constants.sh（避免重复定义 readonly 变量）
if [[ -z "${EXIT_SUCCESS+x}" ]]; then
    source "$_VERIFY_LIB_DIR/constants.sh"
fi

source "$_VERIFY_LIB_DIR/log.sh"
source "$_VERIFY_LIB_DIR/util.sh"

# ============================================
# 函数：verify_backup_readable
# 功能：使用 pg_restore --list 验证备份文件可读性
# 参数：
#   $1 - backup_file: 备份文件路径
# 返回：
#   0 - 验证成功
#   非零 - 验证失败
# ============================================
verify_backup_readable()
{
    local backup_file=$1

    log_info "验证备份文件可读性: $backup_file"

    # 检查是否在容器内运行
    if [[ -f /.dockerenv ]]; then
        # 容器内：直接使用 pg_restore
        if PGPASSWORD=$POSTGRES_PASSWORD pg_restore --list -h noda-infra-postgres-prod -U postgres "$backup_file" >/dev/null 2>&1; then
            log_success "备份文件可读性验证通过"
            return 0
        else
            log_error "备份文件可读性验证失败: pg_restore --list 执行失败"
            return $EXIT_VERIFICATION_FAILED
        fi
    else
        # 宿主机：使用 docker exec
        if docker exec noda-infra-postgres-prod pg_restore --list "$backup_file" >/dev/null 2>&1; then
            log_success "备份文件可读性验证通过"
            return 0
        else
            log_error "备份文件可读性验证失败: pg_restore --list 执行失败"
            return $EXIT_VERIFICATION_FAILED
        fi
    fi
}

# ============================================
# 函数：verify_backup_checksum
# 功能：验证备份文件校验和
# 参数：
#   $1 - backup_file: 备份文件路径
#   $2 - expected_checksum: 预期的 SHA-256 校验和
# 返回：
#   0 - 校验和匹配
#   非零 - 校验和不匹配
# ============================================
verify_backup_checksum()
{
    local backup_file=$1
    local expected_checksum=$2

    log_info "验证备份文件校验和: $backup_file"

    # 计算实际校验和
    local actual_checksum=$(calculate_checksum "$backup_file")

    # 比较校验和
    if [ "$actual_checksum" = "$expected_checksum" ]; then
        log_success "备份文件校验和验证通过"
        return 0
    else
        log_error "备份文件校验和验证失败"
        log_error "  预期: $expected_checksum"
        log_error "  实际: $actual_checksum"
        return $EXIT_VERIFICATION_FAILED
    fi
}

# ============================================
# 函数：verify_backup
# 功能：综合验证备份文件（可读性 + 校验和）
# 参数：
#   $1 - backup_file: 备份文件路径
#   $2 - metadata_file: 元数据文件路径（可选）
# 返回：
#   0 - 验证成功
#   非零 - 验证失败
# ============================================
verify_backup()
{
    local backup_file=$1
    local metadata_file=${2:-}

    log_info "开始综合验证备份文件: $backup_file"

    # 验证可读性
    if ! verify_backup_readable "$backup_file"; then
        return $EXIT_VERIFICATION_FAILED
    fi

    # 如果提供了元数据文件，验证校验和
    if [ -n "$metadata_file" ] && [ -f "$metadata_file" ]; then
        local expected_checksum=$(jq -r '.checksum' "$metadata_file" 2>/dev/null || echo "")

        if [ -n "$expected_checksum" ]; then
            if ! verify_backup_checksum "$backup_file" "$expected_checksum"; then
                return $EXIT_VERIFICATION_FAILED
            fi
        fi
    fi

    log_success "备份文件综合验证通过"
    return 0
}

# ============================================
# 函数：generate_metadata
# 功能：生成备份元数据（JSON 格式）
# 参数：
#   $1 - backup_file: 备份文件路径
#   $2 - db_name: 数据库名称
#   $3 - timestamp: 备份时间戳
# 返回：
#   元数据文件路径（通过标准输出）
# ============================================
generate_metadata()
{
    local backup_file=$1
    local db_name=$2
    local timestamp=$3

    # 获取备份文件信息
    local checksum=$(calculate_checksum "$backup_file")
    local file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null)
    local file_name=$(basename "$backup_file")

    # 生成元数据文件路径
    local metadata_file="$(dirname "$backup_file")/metadata_${db_name}_${timestamp}.json"

    # 生成 JSON 格式元数据
    cat >"$metadata_file" <<EOF
{
  "database": "$db_name",
  "timestamp": "$timestamp",
  "file": "$file_name",
  "size": $file_size,
  "checksum": "$checksum",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "format": "custom",
  "compression": "zlib"
}
EOF

    # 设置元数据文件权限
    set_file_permissions "$metadata_file"

    log_info "生成元数据文件: $metadata_file"

    # 返回元数据文件路径
    echo "$metadata_file"
}

# ============================================
# 函数：verify_all_backups
# 功能：验证备份目录中的所有备份文件
# 参数：
#   $1 - backup_dir: 备份目录路径
#   $2 - metadata_file: 总元数据文件路径（可选）
# 返回：
#   0 - 所有备份验证通过
#   非零 - 验证失败
# ============================================
verify_all_backups()
{
    local backup_dir=$1
    local metadata_file=${2:-}

    log_info "验证备份目录中的所有备份: $backup_dir"

    local backup_count=0
    local failed_count=0

    # 遍历所有 .dump 文件
    for backup_file in "$backup_dir"/*.dump; do
        if [ -f "$backup_file" ]; then
            ((backup_count++))

            log_info "验证备份文件 ($backup_count): $(basename "$backup_file")"

            # 查找对应的元数据文件
            local db_name=$(basename "$backup_file" | sed 's/_[0-9]\{8\}_[0-9]\{6\}\.dump$//')
            local timestamp=$(basename "$backup_file" | grep -oE '[0-9]{8}_[0-9]{6}')
            local db_metadata_file="$backup_dir/metadata_${db_name}_${timestamp}.json"

            # 执行验证
            if ! verify_backup "$backup_file" "$db_metadata_file"; then
                ((failed_count++))
            fi
        fi
    done

    # 验证全局对象备份
    for globals_file in "$backup_dir"/globals_*.sql; do
        if [ -f "$globals_file" ]; then
            ((backup_count++))

            log_info "验证全局对象备份 ($backup_count): $(basename "$globals_file")"

            # 全局对象备份只验证文件存在和大小
            if [ ! -s "$globals_file" ]; then
                log_error "全局对象备份文件为空: $globals_file"
                ((failed_count++))
            fi
        fi
    done

    # 输出验证结果
    if [ $failed_count -eq 0 ]; then
        log_success "所有备份验证通过 (总计: $backup_count)"
        return 0
    else
        log_error "备份验证失败: $failed_count / $backup_count"
        return $EXIT_VERIFICATION_FAILED
    fi
}
