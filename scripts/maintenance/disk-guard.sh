#!/bin/bash
# ============================================
# disk-guard.sh — Mac mini 磁盘阈值守卫（每日 cron 承载调度）
# ============================================
# 背景（2026-11-01）：mini 228G 盘约每 5 天灌满一次。主导项 = Jenkins 每次构建
# 落地 8-15G 的 nearby/web/out 静态导出（已在 Jenkinsfile.apps post always 根治），
# 其余为 noda-buildcache / zcode 日志 / Docker 安装残留 / 各类更新缓存等再生项。
# 本脚本是兜底层：阈值驱动，不再依赖人肉发现磁盘满。
#
# 分级（对 /System/Volumes/Data 的 avail）：
#   FREE >= 60G   level 0  仅记录 + 心跳
#   40G <= FREE < 60G  level 2  安全缓存清单
#   FREE <  40G   level 1  安全清单 + Jenkins 空闲工作区 + dev 构建产物
#   FREE <  20G   追加 TG 告警（website-gate tg.env，与 container-update-check 同款）
#
# 红线（永不触碰，2026-10-25/27 清理纪要与保留规则）：
#   - docker volume prune（dangling 卷 jenkins-gocache/jenkins-gomodcache 是
#     Jenkins 构建缓存，勿删）
#   - docker image prune -a（未使用非 dangling 镜像含 noda-rollback 回滚候选）
#   - ~/Library/Caches/go-build、~/go/pkg/mod、ms-playwright、huggingface
#     （hindsight 本地 embedding 模型）、Chrome/微信缓存、.ollama、.zcode/cli/db
#   - Jenkins 所有 @tmp 目录（r4s:5001 反向隧道密钥在 ws-1@tmp）
#   - 有活跃 durable 任务或 24h 内有文件活动的 ws
#
# 用法：disk-guard.sh [--dry-run]
# 心跳：脚本恒 exit 0，由 cron 行按退出码 hb ok/fail（同 container-update-check）。
# 日志：~/Library/Logs/noda-disk-guard.log（超 5MB 自动截尾）
# cron：10 7 * * *  （见 deploy 变更记录 / crontab -l）
# ============================================

set -uo pipefail

DRY_RUN=""
[ "${1:-}" = "--dry-run" ] && DRY_RUN="1"

LOG_FILE="${HOME}/Library/Logs/noda-disk-guard.log"
JENKINS_WS_ROOT="${HOME}/.jenkins/noda-apps"
PROJECT_HOME="${HOME}/Project"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# 简单日志截尾，防自身膨胀
rotate_log()
{
    [ -f "$LOG_FILE" ] || return 0
    local size
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt 5242880 ]; then
        tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

free_gb()
{
    df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}'
}

do_rm()
{
    if [ -n "$DRY_RUN" ]; then
        log "  [dry-run] 将删除: $*"
    else
        rm -rf "$@" 2>/dev/null || true
    fi
}

# docker 在跑 build 就绝不动缓存（同 lib/cleanup.sh 的并发保护口径）
docker_build_running()
{
    pgrep -f "docker build" >/dev/null 2>&1 || pgrep -f "docker.*buildx" >/dev/null 2>&1
}

# -------- 安全缓存清单（level 2 起跑） --------
clean_safe_caches()
{
    log "-- 安全缓存清单 --"
    do_rm "$HOME/.cache/noda-buildcache"
    do_rm "$HOME/Library/Caches/@zcodedesktop-updater"
    do_rm "$HOME/Library/Caches/pip"
    do_rm "$HOME/Library/Caches/node-gyp"
    do_rm "$HOME/Library/Application Support/com.docker.install/in_progress"
    find "$HOME/.zcode/cli/log" -type f -name '*.jsonl' -mtime +2 -delete 2>/dev/null || true
    find "$HOME/.zcode/cli/artifacts" -maxdepth 1 -type d -mtime +7 \
        -not -path "$HOME/.zcode/cli/artifacts" -exec rm -rf {} + 2>/dev/null || true

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if docker_build_running; then
            log "  检测到进行中的 docker build，跳过镜像/构建缓存 prune"
        else
            if [ -n "$DRY_RUN" ]; then
                log "  [dry-run] 将执行: docker image prune -f / docker builder prune -f"
            else
                docker image prune -f >/dev/null 2>&1 || true
                docker builder prune -f >/dev/null 2>&1 || true
            fi
        fi
    fi
}

# -------- Jenkins 空闲工作区（level 1） --------
# 判定空闲：无进程引用该 ws 路径，且 24h 内无文件活动。@tmp 一律不碰。
clean_jenkins_workspaces()
{
    [ -d "$JENKINS_WS_ROOT" ] || return 0
    log "-- Jenkins 空闲工作区（>24h 无活动且无进程引用）--"
    local ws
    for ws in "$JENKINS_WS_ROOT"/ws-*; do
        [ -d "$ws" ] || continue
        case "$(basename "$ws")" in *@tmp*) continue ;; esac
        # 有进程引用（durable 任务/构建脚本）→ 跳过
        if pgrep -f "jenkins/noda-apps/$(basename "$ws")" >/dev/null 2>&1; then
            log "  跳过 $(basename "$ws")（有进程引用）"
            continue
        fi
        # 24h 内有文件活动 → 跳过（-mmin 可移植；BSD find 的 -newermt 相对表达
        # 式会静默报错导致检查失效，2026-11-01 dry-run 实证）
        if find "$ws" -type f -mmin -1440 -print -quit 2>/dev/null | grep -q .; then
            log "  跳过 $(basename "$ws")（24h 内有活动）"
            continue
        fi
        log "  清理空闲工作区: $(basename "$ws")"
        do_rm "$ws"
    done
}

# -------- dev 仓构建产物（level 1） --------
# 12h 内有产物更新视为活跃开发中，跳过（避免打断当天验证）。
clean_dev_build_outputs()
{
    log "-- dev 构建产物（.next / out，>12h 无更新）--"
    local web out
    for web in "$PROJECT_HOME/noda-apps/nearby/web" "$PROJECT_HOME"/wt107-*/nearby/web; do
        [ -d "$web" ] || continue
        for out in "$web/.next" "$web/out"; do
            [ -e "$out" ] || continue
            if find "$out" -type f -mmin -720 -print -quit 2>/dev/null | grep -q .; then
                log "  跳过 $out（12h 内有构建活动）"
                continue
            fi
            log "  清理: $out"
            do_rm "$out"
        done
    done
}

# -------- TG 告警（同 deploy/container-update-check.sh 的 mac 分支） --------
tg_alert()
{
    local ENVF="$HOME/project/website-gate/credentials/tg.env"
    [ -f "$ENVF" ] || { log "tg.env 缺失，告警未发: $ENVF"; return 0; }
    # shellcheck disable=SC1090
    . "$ENVF"
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        if [ -n "$DRY_RUN" ]; then
            log "  [dry-run] 将发 TG 告警: $1"
        else
            curl -fsS -m 20 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
                --data-urlencode "text=$1" -o /dev/null \
                && log "  TG 告警已发" || log "  TG 告警发送失败"
        fi
    fi
    return 0
}

main()
{
    rotate_log
    local free clean_caches clean_deep
    free=$(free_gb)
    [ -n "$free" ] || free=0
    log "=================================================================="
    log "disk-guard 开始: 可用 ${free}G (dry-run=${DRY_RUN:-no})"

    # 双开关：free<60 清安全缓存；free<40 追加深度清单（空闲 ws + dev 产物）；
    # 清理后 <20G 发 TG 告警
    if [ "$free" -ge 60 ]; then
        clean_caches=0; clean_deep=0
        log "水位健康（>=60G），无需清理"
    elif [ "$free" -ge 40 ]; then
        clean_caches=1; clean_deep=0
        log "水位偏低（40-60G），执行安全缓存清单"
    else
        clean_caches=1; clean_deep=1
        log "水位告急（<40G），执行深度清单（缓存 + 空闲工作区 + dev 构建产物）"
    fi

    [ "$clean_caches" -eq 1 ] && clean_safe_caches
    [ "$clean_deep" -eq 1 ] && clean_jenkins_workspaces
    [ "$clean_deep" -eq 1 ] && clean_dev_build_outputs

    if [ "$clean_caches" -eq 1 ]; then
        free=$(free_gb)
        log "清理后可用: ${free}G"
        if [ "${free:-0}" -lt 20 ]; then
            log "清理后仍 <20G，发送 TG 告警"
            tg_alert "⚠️ Mac mini 磁盘告急: 仅剩 ${free}G（阈值 20G）。disk-guard 已执行深度清理仍不足，请人工介入检查大项（Docker.raw / seaweedfs / 系统数据）。"
        fi
    fi

    log "disk-guard 结束"
    return 0
}

main "$@"
exit 0
