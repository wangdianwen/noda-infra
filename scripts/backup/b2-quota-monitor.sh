#!/bin/bash
set -euo pipefail

# ============================================
# B2 免费额度用量监控（2026-09-26 增设）
# ============================================
# 背景：2026-09-26 桶内隐藏旧版本堆积 8.25/10 GB 触发 Backblaze 75% 告警
#       （rclone 对 B2 的 delete 只打 hide marker 不释放数据，详见
#       backup-filesystem.sh 头注与 git 0ea0080）。修复后稳态约 2.5-3 GB，
#       但 nearby 爬取素材持续净增（~12 MB/日），FS 全量镜像 × 4 天滚动窗口
#       的稳态用量随源大小线性上涨——本监控在远早于 75% 处两级预警，留出
#       处置时间（FS_RETENTION_DAYS 3→2 可立减约四分之一稳态用量）。
# 口径：rclone size --b2-versions，含隐藏旧版本 = 真实计费字节
#       （默认 size 只算当前版本会严重低估，2026-09-26 排查实证）。
# 阈值：B2_QUOTA_BYTES（默认 10 GiB）/ B2_QUOTA_WARN_PCT（默认 45）/
#       B2_QUOTA_CRIT_PCT（默认 60），环境变量可覆盖。
# 运行位置：noda-ops 容器 crond 每日 05:10（备份 04:30 / rclone cleanup 05:00
#           之后度量当日稳态；04:30-05:00 窗口的瞬时峰值约多一份当日副本，
#           已由阈值余量覆盖）。
# 用法：b2-quota-monitor.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/util.sh"
source "$SCRIPT_DIR/lib/cloud.sh"
source "$SCRIPT_DIR/lib/alert.sh"

B2_QUOTA_BYTES="${B2_QUOTA_BYTES:-10737418240}" # B2 免费层 10 GiB
B2_QUOTA_WARN_PCT="${B2_QUOTA_WARN_PCT:-45}"
B2_QUOTA_CRIT_PCT="${B2_QUOTA_CRIT_PCT:-60}"

# 用量超标时的分前缀明细（定位是哪条备份链在涨）
prefix_breakdown()
{
    local rclone_config=$1 bucket=$2
    local p size_json bytes
    for p in backups/postgres backups/filesystem/avatars backups/filesystem/nearby doppler-backup; do
        size_json=$(rclone size "b2remote:${bucket}/${p}" --b2-versions --json --config "$rclone_config" 2>/dev/null || echo '')
        bytes=$(echo "$size_json" | grep -o '"bytes":[0-9]*' | head -1 | cut -d: -f2)
        log_warn "  ${p}: ${bytes:-查询失败} bytes（含旧版本）"
    done
}

main()
{
    load_config
    if ! validate_b2_credentials; then
        log_error "B2 凭据缺失，无法监控额度"
        exit $EXIT_INVALID_ARGS
    fi

    local bucket
    bucket=$(get_b2_bucket_name)

    local rclone_config
    rclone_config=$(setup_rclone_config)

    # 计费口径：--b2-versions 含隐藏旧版本
    local bytes
    bytes=$(rclone size "b2remote:${bucket}" --b2-versions --json --config "$rclone_config" |
        grep -o '"bytes":[0-9]*' | head -1 | cut -d: -f2 || true)

    if [ -z "$bytes" ]; then
        cleanup_rclone_config "$rclone_config"
        log_error "B2 桶用量查询失败（rclone size --b2-versions 无返回）"
        send_alert "b2_quota_check_failed" "$bucket" "B2 用量查询失败：rclone size --b2-versions 无返回。监控本身故障，请人工核查桶状态。"
        exit $EXIT_CLOUD_UPLOAD_FAILED
    fi

    local pct=$((bytes * 100 / B2_QUOTA_BYTES))
    log_info "B2 桶 ${bucket} 用量: ${bytes} / ${B2_QUOTA_BYTES} bytes = ${pct}%（warn≥${B2_QUOTA_WARN_PCT}% crit≥${B2_QUOTA_CRIT_PCT}%）"

    if [ "$pct" -ge "$B2_QUOTA_CRIT_PCT" ]; then
        log_error "B2 用量达到严重阈值（${pct}% ≥ ${B2_QUOTA_CRIT_PCT}%）"
        prefix_breakdown "$rclone_config" "$bucket"
        cleanup_rclone_config "$rclone_config"
        send_alert "b2_quota_critical" "$bucket" "B2 桶 ${bucket} 用量 ${pct}%（≥${B2_QUOTA_CRIT_PCT}%，${bytes}/${B2_QUOTA_BYTES} bytes）。处置：① FS_RETENTION_DAYS 3→2（docker-compose 环境变量，约减 1/4 稳态）② 查 filesystem.log 保留清理与 b2-cleanup.log 每日 cleanup 是否正常 ③ 查桶生命周期规则是否被改（应为 7d 隐藏/1d 删除）"
        exit 0
    fi

    if [ "$pct" -ge "$B2_QUOTA_WARN_PCT" ]; then
        log_warn "B2 用量达到预警阈值（${pct}% ≥ ${B2_QUOTA_WARN_PCT}%）"
        prefix_breakdown "$rclone_config" "$bucket"
        cleanup_rclone_config "$rclone_config"
        send_alert "b2_quota_warning" "$bucket" "B2 桶 ${bucket} 用量 ${pct}%（≥${B2_QUOTA_WARN_PCT}%，${bytes}/${B2_QUOTA_BYTES} bytes）。当前仍在安全范围，但按增长趋势将持续上升——如需压回水位可把 FS_RETENTION_DAYS 3→2。"
        exit 0
    fi

    cleanup_rclone_config "$rclone_config"
    log_success "B2 用量正常（${pct}% < ${B2_QUOTA_WARN_PCT}%）"
}

main "$@"
