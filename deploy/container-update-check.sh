#!/bin/sh
# ============================================
# container-update-check.sh — 双主机容器镜像版本巡检（每周）
# ============================================
# 背景：2026-10-27 Cloudflare emSign 证书事件邮件要求 cloudflared ≥2026.10.2。
#   noda-ops 容器内 cloudflared 恰为 2026.10.2（Dockerfile 构建时抓 latest 的运气），
#   且全舰队无任何机制跟踪容器/内嵌二进制版本新鲜度——「Action Required」类通告
#   只能靠人看邮件。本脚本补上这一层。
#
# 职责（r4s 与 Mac mini 同一脚本，按主机角色自适应）：
#   1. 镜像巡检：对每个运行中容器的镜像 docker pull 同 tag，对比 RepoDigests。
#      - tag 有新 digest = 上游发布了更新 → TG 汇报（pinned tag 需改 repo compose
#        走管线；:latest 漂浮 tag recreate 即生效）。
#      - 本地构建镜像（noda-api/noda-static commit tag、noda-ops）跳过——管线管理。
#      - 白名单 CONTAINER_UPDATE_WHITELIST（默认空=只报告不动容器）内的容器：
#        compose 管理的用 compose recreate；裸 docker run 的仅提示手动重建。
#   2. cloudflared 专项（本脚本的存在动机）：运行版本 vs GitHub latest release。
#      - r4s：noda-ops 容器内二进制；Mac：Homebrew。落后即 TG 告警附升级路径。
#   3. 有发现才 TG 推送，全干净静默（避免通知疲劳）。
#      心跳不在脚本内——由 crontab 行按退出码 hb ok/fail（脚本恒 exit 0，
#      崩溃由 cron 行 `|| hb fail` 兜底，与 deploy/crontab-r4s-host 全体模式一致）。
#
# 用法：container-update-check.sh [r4s|mac]（缺省按容器特征自动识别）
# 日志：r4s /var/log/noda-container-update.log；mac ~/Library/Logs/noda-container-update.log
# 白名单配置：r4s /etc/noda/container-update.env；mac ~/.container-update.env
#   内容形如：CONTAINER_UPDATE_WHITELIST="filebrowser immich_redis"
#   ⚠ r4s 的 compose recreate 可能因缺 TAG 等 env 失败——r4s 白名单慎用，
#     标准路径是改 repo + 管线发布。
# 安装（r4s）：scp 本文件到 /mnt/mmc1-4/System/Scripts/ 后 chmod +x
# 调度：r4s root crontab 周日 06:30；mac 用户 crontab 周日 06:00
# ============================================

set -u

# cron 环境无 brew PATH（mac 端 docker/cloudflared 都在 /opt/homebrew/bin 或
# /usr/local/bin），显式补齐；r4s 端无副作用
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

ROLE="${1:-}"
TG_FINDINGS=""
PULL_FAILS=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

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

add_finding() { TG_FINDINGS="${TG_FINDINGS}${TG_FINDINGS:+
}• $1"; }

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

# ---------- 1. 镜像巡检 ----------
# here-doc 喂 while（非管道）：循环须在当前 shell 跑，findings 变量才能带出去
WHITELIST="${CONTAINER_UPDATE_WHITELIST:-}"
log "==== 容器镜像巡检开始（role=${ROLE}）===="
while read -r name image; do
    [ -n "$name" ] || continue
    case "$image" in
        noda-api:*|noda-static:*|noda-ops:*|localhost:5001/*)
            log "跳过本地构建镜像: $name ($image)"; continue ;;
    esac
    case "$image" in *:*) ;; *) image="${image}:latest" ;; esac

    before=$(digest_of "$image")
    if ! docker pull -q "$image" >/dev/null 2>&1; then
        log "PULL_FAIL ${image}（容器 ${name}）"
        PULL_FAILS="${PULL_FAILS}${PULL_FAILS:+, }${image}"
        continue
    fi
    after=$(digest_of "$image")
    if [ -n "$before" ] && [ "$before" = "$after" ]; then
        log "UP_TO_DATE $name ($image)"
        continue
    fi
    log "UPDATE_AVAILABLE $name ($image) — tag 已指向新 digest"

    case " $WHITELIST " in
        *" $name "*)
            labels=$(compose_labels "$name")
            if [ -n "$labels" ]; then
                proj=${labels%%|*}; rest=${labels#*|}
                svc=${rest%%|*}; rest=${rest#*|}
                wd=${rest%%|*}; files=${rest#*|}
                log "白名单命中 ${name}：compose recreate（project=$proj service=${svc}）"
                if (cd "$wd" && docker compose -p "$proj" -f "$files" up -d --no-deps "$svc" >/dev/null 2>&1); then
                    log "RECREATED $name"
                    add_finding "已自动更新 recreate：${name}（${image}）"
                else
                    add_finding "白名单 recreate 失败：${name}（${image}）— 需人工处理"
                    log "RECREATE_FAIL $name"
                fi
            else
                add_finding "可更新但无 compose 标签（裸 docker run）：${name}（${image}）— 需手动重建"
            fi
            ;;
        *)
            add_finding "可更新：${name}（$image 上游 tag 已更新，需 recreate——repo/管线路径）"
            ;;
    esac
done <<EOF
$(docker ps --format '{{.Names}}\t{{.Image}}')
EOF

# ---------- 2. cloudflared 专项 ----------
log "---- cloudflared 版本核对 ----"
latest_cf=$(curl -fsS -o /dev/null -m 20 -w '%{redirect_url}' \
    https://github.com/cloudflare/cloudflared/releases/latest 2>/dev/null | sed 's|.*/tag/||')
if [ -z "$latest_cf" ]; then
    log "WARN GitHub latest 查询失败（网络），本轮跳过 cloudflared 对比"
    add_finding "cloudflared latest 查询失败（网络）——下轮自动重试"
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
        add_finding "cloudflared 落后：$cf_where $running_cf < latest $latest_cf → $cf_hint"
    fi
fi

# ---------- 3. 汇报 ----------
[ -z "$PULL_FAILS" ] || add_finding "pull 失败（registry 不可达/限流？）：$PULL_FAILS"

if [ -n "$TG_FINDINGS" ]; then
    log "有发现，TG 推送"
    tg_notify "📦 容器更新巡检（${ROLE}）$(date '+%m-%d %H:%M')
$TG_FINDINGS"
else
    log "全部干净，静默收工"
fi
log "==== 巡检结束 ===="
exit 0
