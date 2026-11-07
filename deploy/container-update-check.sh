#!/bin/sh
# ============================================
# container-update-check.sh — 双主机容器镜像自动更新（每周日凌晨）
# ============================================
# 策略演进：
#   2026-11-01 v1 巡检报告制（默认只报告，白名单才 recreate）——起因：Cloudflare
#     emSign 证书事件暴露全舰队无版本新鲜度跟踪。
#   2026-11-08 v2 用户定：**全部漂浮镜像自动 pull + recreate + 健康验证，
#     更新失败才 TG，成功静默**（心跳 hb ok/fail 照常监测脚本存活）。
#     调度：Mac 周日 04:00（launchd com.noda.container-update-check）、
#     r4s 周日 04:30（root cron，错峰 30 分钟）。
#
# 更新语义：
#   - 跳过本地构建/钉版镜像（发布走 Jenkins 管线或本地重建，pull 无意义）：
#     noda-api:* / noda-static:* / noda-ops:*（管线 commit tag）、localhost:5001/*
#     （本地 registry 推送）、headroom-proxy:*（2026-11-08 本地钉版，PyPI wheel
#     构建，升级走 docker/Dockerfile.headroom-proxy + scripts/headroom-recreate.sh）、
#     ourauckland-cdp:*（compose build，无远端 tag）
#   - 漂浮/版本 tag pull 后 RepoDigests 变化 → recreate：
#     · compose 管理 → cd workdir && docker compose up -d --no-deps <svc>
#     · 裸 docker run → 固化映射：hindsight→scripts/hindsight-recreate.sh rebuild、
#       noda-registry→固化 run 参数（下方 case 内）；无映射的裸容器 → 记为失败
#       TG 求助（不能盲建，run 参数会丢）
#   - recreate 后健康验证：有 healthcheck 轮询至 healthy（≤120s），无的查 running；
#     超时/未达 → 记为失败
#   - 汇总：有失败（pull 失败/recreate 失败/健康失败/无映射）→ 一条 TG；
#     cloudflared 落后作为 advisory 附在同条 TG；全干净 → 完全静默
#   - DRY_RUN=1：全流程演练（pull 照跑，recreate 只打印不执行），验证用
#
# 用法：container-update-check.sh [r4s|mac]（缺省按容器特征自动识别）
# 日志：r4s /var/log/noda-container-update.log；mac ~/Library/Logs/noda-container-update.log
# cloudflared 专项（本脚本的存在动机）：运行版本 vs GitHub latest release，落后即
#   TG 附升级路径（r4s=noda-ops 内二进制走管线；Mac=Homebrew）。
# 安装（r4s）：scp 本文件到 /mnt/mmc1-4/System/Scripts/ 后 chmod +x
# 调度：r4s root crontab 周日 04:30；mac launchd 周日 04:00
# ============================================

set -u

# cron/launchd 环境无 brew PATH（mac 端 docker/cloudflared 在 /opt/homebrew/bin 或
# /usr/local/bin），显式补齐；r4s 端无副作用
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

ROLE="${1:-}"
DRY_RUN="${CONTAINER_UPDATE_DRY_RUN:-}"
TG_FINDINGS=""
FAILURES=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
add_fail() { FAILURES="${FAILURES}${FAILURES:+
}• $1"; }

# ---------- 主机角色识别 ----------
detect_role()
{
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^noda-static-prod$'; then
        echo r4s; return
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^preprod-noda-api$'; then
        echo mac; return
    fi
    echo unknown
}

[ -n "$ROLE" ] || ROLE=$(detect_role)
if [ "$ROLE" != "r4s" ] && [ "$ROLE" != "mac" ]; then
    echo "无法识别主机角色，请显式传参 r4s|mac" >&2
    exit 1
fi

tg_notify()  # $1=消息文本（r4s 用 telegram-alert.sh；mac 用 website-gate 的 0600 tg.env）
{
    if [ "$ROLE" = "r4s" ]; then
        /mnt/mmc1-4/System/Scripts/telegram-alert.sh "$1"
        return 0
    fi
    ENVF="$HOME/project/website-gate/credentials/tg.env"
    [ -f "$ENVF" ] || return 0
    # shellcheck disable=SC1090
    . "$ENVF"
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] && \
        curl -fsS -m 20 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=$1" -o /dev/null
    return 0
}

digest_of()  # 镜像当前 tag 指向的 RepoDigests 集合（排序后单行）
{
    docker image inspect --format '{{range .RepoDigests}}{{.}}
{{end}}' "$1" 2>/dev/null | sort | tr '\n' ' '
}

version_ge()  # $1 >= $2 ?（2026.10.3 三段数字比较）
{
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}

compose_labels()  # $1=容器名 → project|service|working_dir|config_files（非 compose 容器输出空）
{
    docker inspect --format \
        '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}' \
        "$1" 2>/dev/null | grep -v '^|'
}

wait_healthy()  # $1=容器 $2=超时秒 → 健康验证（有 hc 等 healthy，无 hc 等 running）
{
    has_hc=$(docker inspect "$1" --format '{{if .Config.Healthcheck}}1{{end}}' 2>/dev/null)
    waited=0
    while [ "$waited" -lt "$2" ]; do
        sleep 5
        waited=$((waited + 5))
        if [ -n "$has_hc" ]; then
            [ "$(docker inspect "$1" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null)" = "healthy" ] && return 0
        else
            [ "$(docker inspect "$1" --format '{{.State.Status}}' 2>/dev/null)" = "running" ] && return 0
        fi
    done
    return 1
}

recreate_container()  # $1=容器名 $2=镜像 → 0=ok 1=失败 2=无固化映射
{
    if [ "$DRY_RUN" = "1" ]; then
        log "[DRYRUN] 将 recreate ${1}（${2}）"
        return 0
    fi
    labels=$(compose_labels "$1")
    if [ -n "$labels" ]; then
        proj=${labels%%|*}; rest=${labels#*|}
        svc=${rest%%|*}; rest=${rest#*|}
        wd=${rest%%|*}; files=${rest#*|}
        log "recreate ${1}（compose ${proj}/${svc} @ ${wd}）"
        (cd "$wd" && docker compose -p "$proj" -f "$files" up -d --no-deps "$svc" >/dev/null 2>&1) || return 1
    else
        case "$1" in
            hindsight)
                # 固化脚本自带全部 run 参数与 LLM env 逻辑（env.zai 优先，
                # watchdog 降级位自愈兜底）
                [ -f "$HOME/Project/noda-infra/scripts/hindsight-recreate.sh" ] || return 2
                bash "$HOME/Project/noda-infra/scripts/hindsight-recreate.sh" rebuild >/dev/null 2>&1 || return 1
                ;;
            noda-registry)
                # 固化参数 = 2026-11-08 实测定义（named volume 数据不丢）
                docker rm -f noda-registry >/dev/null 2>&1
                docker run -d --name noda-registry \
                    -p 127.0.0.1:5001:5000 \
                    -v registry-data:/var/lib/registry \
                    -e OTEL_TRACES_EXPORTER=none \
                    --restart unless-stopped \
                    registry:3 /etc/distribution/config.yml >/dev/null 2>&1 || return 1
                ;;
            *)
                log "无固化重建映射：${1}（裸 docker run 容器）"
                return 2 ;;
        esac
    fi
    wait_healthy "$1" 120
}

# ---------- 1. 镜像自动更新 ----------
# 镜像名取 docker inspect 的 Config.Image（创建时配置）而非 docker ps 的 .Image
# ——:latest 漂浮 tag 被新 pull 转移后 .Image 显示镜像 ID（如 50311d02b4d5），
# 拿 ID 拼 :latest 去 pull 必失败（2026-11-08 修复）。
# 触发判定 = 容器实际运行的 digest vs pull 后 tag 的 digest（而非 pull 前后对比
# ——若镜像曾被其他运行拉过，pull 无 digest 变化，容器会永远落后不重建，2026-11-08 v2 实测坑）。
log "==== 容器自动更新开始（role=${ROLE}${DRY_RUN:+，DRY_RUN}）===="
while read -r name; do
    [ -n "$name" ] || continue
    image=$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null) || continue
    [ -n "$image" ] || continue
    case "$image" in
        noda-api:*|noda-static:*|noda-ops:*|localhost:5001/*|headroom-proxy:*|ourauckland-cdp:*)
            log "跳过本地构建/钉版镜像: $name ($image)"; continue ;;
    esac
    case "$image" in *:*) ;; *) image="${image}:latest" ;; esac

    if ! docker pull -q "$image" >/dev/null 2>&1; then
        log "PULL_FAIL ${image}（容器 ${name}）"
        add_fail "pull 失败（registry 不可达/限流/镜像名不存在？）：${image}（容器 ${name}）"
        continue
    fi
    running_digest=$(docker image inspect --format '{{range .RepoDigests}}{{.}}
{{end}}' "$(docker inspect "$name" --format '{{.Image}}')" 2>/dev/null | sort | tr '\n' ' ')
    tag_digest=$(digest_of "$image")
    if [ -z "$running_digest" ]; then
        # 容器镜像无 RepoDigests（本地构建未 push）→ 无法判定，不盲重建
        log "NO_DIGEST $name ($image) — 无法判定新旧，跳过"
        continue
    fi
    if [ "$running_digest" = "$tag_digest" ]; then
        log "UP_TO_DATE $name ($image)"
        continue
    fi
    log "UPDATE $name ($image) — 容器落后于 tag digest → recreate"

    recreate_container "$name" "$image"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        log "UPDATED_OK ${name}（${image}，健康验证通过）"
    elif [ "$rc" -eq 2 ]; then
        add_fail "已拉取新镜像但无固化重建映射（裸 docker run，需人工重建防参数丢失）：${name}（${image}）"
        log "NO_MAPPING $name"
    else
        add_fail "recreate 或健康验证失败：${name}（${image}）— 查 docker logs ${name}；旧镜像未删可回退"
        log "UPDATE_FAIL $name"
    fi
done <<EOF
$(docker ps --format '{{.Names}}')
EOF

# ---------- 2. cloudflared 版本核对 ----------
log "---- cloudflared 版本核对 ----"
latest_cf=$(curl -fsS -o /dev/null -m 20 -w '%{redirect_url}' \
    https://github.com/cloudflare/cloudflared/releases/latest 2>/dev/null | sed 's|.*/tag/||')
if [ -z "$latest_cf" ]; then
    log "WARN GitHub latest 查询失败（网络），本轮跳过 cloudflared 对比"
else
    if [ "$ROLE" = "r4s" ]; then
        running_cf=$(docker exec noda-ops /usr/local/bin/cloudflared --version 2>/dev/null | awk '{print $3}')
        cf_where="noda-ops 容器"
        cf_hint="改 deploy/Dockerfile.noda-ops 的 ARG CLOUDFLARED_VERSION 后触发 noda-infra 管线 SERVICE=noda-ops"
    else
        running_cf=$(cloudflared --version 2>/dev/null | awk '{print $3}')
        cf_where="Mac Homebrew"
        cf_hint="brew upgrade cloudflared 后重启隧道进程生效"
    fi
    log "cloudflared [$cf_where] running=${running_cf:-未知} latest=${latest_cf}"
    if [ -n "$running_cf" ] && ! version_ge "$running_cf" "$latest_cf"; then
        add_fail "cloudflared 落后（advisory，需人工升级）：$cf_where $running_cf < latest $latest_cf → $cf_hint"
    fi
fi

# ---------- 3. 汇报：失败才 TG，成功静默 ----------
if [ -n "$FAILURES" ]; then
    log "有失败项，TG 推送"
    tg_notify "🚨 容器自动更新失败（${ROLE}）$(date '+%m-%d %H:%M')
$FAILURES"
else
    log "全部更新完成/无更新，静默收工"
fi
log "==== 容器自动更新结束 ===="
exit 0
