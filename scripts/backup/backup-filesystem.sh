#!/bin/bash
set -euo pipefail

# ============================================
# Noda 文件系统备份 - SeaweedFS 对象存储数据（S3 逻辑备份，2026-09-13 改版）
# ============================================
# 备份方式：rclone copy 直连 SeaweedFS S3 API → B2（对象级逻辑备份，流经内存
#           不落本地盘）。原 tar 整卷方式废弃：活动写入下 tar 有一致性风险，
#           且无法剔除可重建数据（sites/ 前端编译产物）。
# 备份对象：BACKUP_FS_SOURCES（逗号分隔的 rclone 源路径，默认
#           s3weed:noda-static/avatars:s3weed:noda-static/nearby，即头像 +
#           nearby 爬取图片素材；sites/ 可经 Jenkins infra-deploy 重建不备份）
# 目标：b2remote:<bucket>/<FS_B2_PATH><src_name>/<YYYY/MM/DD>/（对象树原样镜像，
#           恢复 = rclone copy 反向拷回 s3weed:noda-static/<src_name>/）
# 保留：FS_RETENTION_DAYS（默认 3 天）——每次备份后对 <FS_B2_PATH><src_name>/
#           前缀执行 rclone delete --min-age，及时删除历史文件控制 B2 用量
# 依赖：SEAWEED_S3_ENDPOINT / SEAWEED_S3_ACCESS_KEY / SEAWEED_S3_SECRET_KEY
#           （rclone s3weed remote，见 lib/cloud.sh setup_rclone_config）
# 运行位置：noda-ops 容器内 crond（deploy/crontab；容器与 seaweedfs 同在
#           noda-network，无需挂载数据卷）
# 用法：backup-filesystem.sh [--dry-run]
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载常量与库（与 backup-postgres.sh 同套约定）
source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/util.sh"
source "$SCRIPT_DIR/lib/cloud.sh"
source "$SCRIPT_DIR/lib/alert.sh"
source "$SCRIPT_DIR/lib/metrics.sh"

# 全局变量
PID_FILE="/tmp/backup-filesystem.pid"
LOCK_TIMEOUT=3600 # 1小时
DRY_RUN=false

# ============================================
# 函数：show_help
# ============================================
show_help()
{
    cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --dry-run    列出备份源与目标，不实际执行
  --help       显示帮助信息

环境变量:
  BACKUP_FS_SOURCES     逗号分隔的 rclone 备份源
                        （默认 s3weed:noda-static/avatars:s3weed:noda-static/nearby）
  FS_B2_PATH            B2 目标前缀（默认 backups/filesystem/）
  FS_RETENTION_DAYS     B2 端保留天数（默认 3）
  SEAWEED_S3_*          SeaweedFS S3 连接配置（endpoint/access key/secret key）

示例:
  $(basename "$0")              # 备份全部源并上传 B2 + 清理超期历史
  $(basename "$0") --dry-run    # 演练
EOF
}

# ============================================
# 函数：acquire_lock / release_lock
# ============================================
acquire_lock()
{
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        local pid_age=$(($(date +%s) - $(stat -f%m "$PID_FILE" 2>/dev/null || stat -c%Y "$PID_FILE" 2>/dev/null)))
        if [ $pid_age -gt $LOCK_TIMEOUT ]; then
            log_warn "检测到过期的锁文件（PID: $pid，已锁定 ${pid_age} 秒），自动清理"
            release_lock
        else
            log_error "另一个文件系统备份实例正在运行（PID: $pid）"
            exit 1
        fi
    fi
    echo $$ >"$PID_FILE"
    log_info "获取锁成功（PID: $$）"
}

release_lock()
{
    if [ -f "$PID_FILE" ]; then
        rm -f "$PID_FILE"
        log_info "释放锁成功"
    fi
}

# ============================================
# 函数：parse_arguments
# ============================================
parse_arguments()
{
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit $EXIT_INVALID_ARGS
                ;;
        esac
    done
}

# ============================================
# 函数：validate_fs_config
# ============================================
# FS 备份专属校验：S3 连接与源路径格式（load_config/validate_config 已跑通用项）
validate_fs_config()
{
    if [[ -z "$SEAWEED_S3_ACCESS_KEY" || -z "$SEAWEED_S3_SECRET_KEY" ]]; then
        log_error "SEAWEED_S3_ACCESS_KEY / SEAWEED_S3_SECRET_KEY 未设置（SeaweedFS S3 连接必需）"
        return 1
    fi
    if ! [[ "$FS_RETENTION_DAYS" =~ ^[0-9]+$ ]] || [[ "$FS_RETENTION_DAYS" -lt 1 ]]; then
        log_error "FS_RETENTION_DAYS 必须是正整数，当前值: $FS_RETENTION_DAYS"
        return 1
    fi
    return 0
}

# ============================================
# 函数：fs_source_name
# ============================================
# rclone 源路径 → 目标目录名（s3weed:noda-static/nearby → nearby）
fs_source_name()
{
    local src=$1
    local name="${src%%\?*}"   # 去可能的 query
    name="${name%/}"           # 去尾斜杠
    echo "${name##*/}"
}

# ============================================
# 函数：main
# ============================================
main()
{
    parse_arguments "$@"
    load_config
    validate_config
    validate_fs_config

    log_info "=========================================="
    log_info "Noda 文件系统备份系统（S3 逻辑备份）"
    log_info "=========================================="

    # 解析备份源（rclone 路径列表；逗号分隔——路径自带 s3weed: 冒号，不能用冒号）
    local sources=()
    IFS=',' read -ra source_list <<<"$(get_fs_sources)"
    for src in "${source_list[@]}"; do
        [ -z "$src" ] && continue
        if [[ "$src" != s3weed:* ]]; then
            log_error "备份源必须是 s3weed: 前缀的 rclone 路径，当前: $src"
            exit $EXIT_INVALID_ARGS
        fi
        sources+=("$src")
    done
    if [ ${#sources[@]} -eq 0 ]; then
        log_error "未配置任何备份源（BACKUP_FS_SOURCES）"
        exit $EXIT_INVALID_ARGS
    fi

    acquire_lock

    local start_time
    start_time=$(date +%s)
    local date_path
    date_path=$(get_date_path)
    local rclone_config
    rclone_config=$(setup_rclone_config)

    log_info "备份源: ${sources[*]}"
    log_info "目标: b2remote:$(get_b2_bucket_name)/$(get_fs_b2_path)<src>/$date_path/（保留 ${FS_RETENTION_DAYS} 天）"
    if [ "$DRY_RUN" = true ]; then
        log_warn "模拟模式：跳过实际备份"
        cleanup_rclone_config "$rclone_config"
        release_lock
        exit 0
    fi

    # 逐源镜像备份（rclone copy 直传 B2，不落本地盘）
    local failed=0
    local last_size=0
    local src src_name remote_dir
    for src in "${sources[@]}"; do
        src_name=$(fs_source_name "$src")
        remote_dir="b2remote:$(get_b2_bucket_name)/$(get_fs_b2_path)${src_name}/${date_path}"
        log_info "开始备份: $src → $remote_dir"
        if ! rclone copy "$src" "$remote_dir" \
                --config "$rclone_config" \
                --transfers 4 \
                --checkers 8 \
                --retries 3 \
                --low-level-retries 10; then
            log_error "备份失败: $src"
            send_alert "backup_failed" "filesystem" "文件系统备份失败: $src"
            failed=1
            continue
        fi
        last_size=$(rclone size "$remote_dir" --config "$rclone_config" --json 2>/dev/null |
            grep -o '"bytes":[0-9]*' | head -1 | cut -d: -f2 || echo 0)
        log_success "备份完成: $src（${last_size:-0} bytes 累计）"
    done

    # 保留策略：删除各源前缀下超期对象（FS_RETENTION_DAYS，默认 3 天）。
    # 清理失败仅告警不置 failed——旧文件多留一天不致命，别让备份告警疲劳
    if [ "$failed" -eq 0 ]; then
        for src in "${sources[@]}"; do
            src_name=$(fs_source_name "$src")
            local prefix="b2remote:$(get_b2_bucket_name)/$(get_fs_b2_path)${src_name}"
            if rclone delete "$prefix" --config "$rclone_config" \
                    --min-age "${FS_RETENTION_DAYS}d" 2>/dev/null; then
                log_info "保留清理完成: $prefix（> ${FS_RETENTION_DAYS} 天对象已删除）"
            else
                log_warn "保留清理失败（不影响备份有效性）: $prefix"
            fi
        done
    fi
    cleanup_rclone_config "$rclone_config"

    if [ "$failed" -ne 0 ]; then
        release_lock
        exit $EXIT_BACKUP_FAILED
    fi

    # 记录指标（时长 + 最后一个源的上传大小）
    mkdir -p "$HISTORY_DIR" 2>/dev/null || true
    local duration=$(( $(date +%s) - start_time ))
    record_metric "backup" "filesystem" "$duration" "${last_size:-0}"

    log_success "文件系统备份全部完成（耗时 ${duration}s）"
    release_lock
}

main "$@"
