#!/bin/bash
set -euo pipefail

# ============================================
# Noda 文件系统备份 - SeaweedFS 对象存储数据
# ============================================
# 备份对象：BACKUP_FS_SOURCES（冒号分隔的目录列表，默认 /mnt/backup-src/seaweedfs，
#           即 r4s /mnt/mmc1-4/noda/seaweedfs：头像 / nearby 爬取图片 / 静态站桶数据）
# 方式：tar.gz 流式直传 B2（tar czf - | rclone rcat）——不落本地盘：
#       r4s 根分区仅 1.9G 且 noda-ops 的 /tmp 为 tmpfs，无法承载 ~700MB 暂存
# 运行位置：
#   a) r4s 宿主机 crontab 以 docker run 一次性容器执行（挂载源目录只读 + 本脚本），
#      与 snagme 爬虫的宿主 cron 模式一致
#   b) noda-ops 镜像内（需 compose 为容器挂载源目录后）
# 目标：b2remote:<bucket>/<b2_path>filesystem/YYYY/MM/DD/<name>_<ts>.tar.gz
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
FS_SOURCES="${BACKUP_FS_SOURCES:-/mnt/backup-src/seaweedfs}"

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
  BACKUP_FS_SOURCES    冒号分隔的备份源目录（默认 /mnt/backup-src/seaweedfs）

示例:
  $(basename "$0")              # 备份全部源目录并上传 B2
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
# 函数：main
# ============================================
main()
{
    parse_arguments "$@"
    load_config
    validate_config

    log_info "=========================================="
    log_info "Noda 文件系统备份系统"
    log_info "=========================================="

    # 校验备份源存在
    local sources=()
    IFS=':' read -ra source_list <<<"$FS_SOURCES"
    for src in "${source_list[@]}"; do
        [ -z "$src" ] && continue
        if [ ! -d "$src" ]; then
            log_error "备份源目录不存在: $src"
            send_alert "backup_failed" "filesystem" "备份源目录不存在: $src"
            exit $EXIT_BACKUP_FAILED
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
    local timestamp=$(get_timestamp)
    local date_path=$(get_date_path)
    local rclone_config
    rclone_config=$(setup_rclone_config)

    log_info "备份源: ${sources[*]}"
    log_info "目标: b2remote:$(get_b2_bucket_name)/$(get_b2_path)filesystem/$date_path/"
    if [ "$DRY_RUN" = true ]; then
        log_warn "模拟模式：跳过实际备份"
        cleanup_rclone_config "$rclone_config"
        release_lock
        exit 0
    fi

    # 逐源流式备份（tar.gz → rclone rcat 直传，不落本地盘）
    local failed=0
    for src in "${sources[@]}"; do
        local src_name
        src_name=$(basename "$src")
        local remote_file="b2remote:$(get_b2_bucket_name)/$(get_b2_path)filesystem/$date_path/${src_name}_${timestamp}.tar.gz"
        log_info "开始备份: $src → $remote_file"
        if ! tar -C "$(dirname "$src")" -czf - "$(basename "$src")" |
            rclone rcat "$remote_file" --config "$rclone_config"; then
            log_error "备份失败: $src"
            send_alert "backup_failed" "filesystem" "文件系统备份失败: $src"
            failed=1
            continue
        fi
        local size
        size=$(rclone lsjson "$remote_file" --config "$rclone_config" 2>/dev/null | grep -o '"Size":[0-9]*' | cut -d: -f2 || echo 0)
        log_success "备份完成: $src（$(du -sh "$src" 2>/dev/null | cut -f1) → ${size} bytes）"
    done
    cleanup_rclone_config "$rclone_config"

    if [ "$failed" -ne 0 ]; then
        release_lock
        exit $EXIT_BACKUP_FAILED
    fi

    # 记录指标（时长 + 最后一个源的上传大小）
    # 一次性容器（宿主 crontab docker run）里 history 目录不存在，先建
    mkdir -p "$HISTORY_DIR" 2>/dev/null || true
    local duration=$(( $(date +%s) - start_time ))
    record_metric "backup" "filesystem" "$duration" "${size:-0}"

    log_success "文件系统备份全部完成（耗时 ${duration}s）"
    release_lock
}

main "$@"
