#!/bin/bash
set -euo pipefail

# ============================================
# Jenkins Pipeline 阶段函数库
# ============================================
# 功能：封装 Jenkinsfile Pipeline 所需的 bash 函数
# 用途：Jenkinsfile 通过 source 加载此文件，调用 pipeline_* 函数
# 依赖：scripts/lib/log.sh, scripts/lib/health.sh, scripts/lib/secrets.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/remote-ops.sh"
source "$PROJECT_ROOT/scripts/lib/health.sh"
source "$PROJECT_ROOT/scripts/lib/secrets.sh"
source "$PROJECT_ROOT/scripts/lib/deploy-check.sh"
source "$PROJECT_ROOT/scripts/lib/image-cleanup.sh"
source "$PROJECT_ROOT/scripts/lib/cleanup.sh"

# 加载密钥（Doppler 双模式，per D-03/D-04/D-10）
# SKIP_LOAD_SECRETS=1 时跳过（调用者自行注入 secrets，如 _deploy_liuyao_preprod.sh 用 CLI eval prd_pre）
[ "${SKIP_LOAD_SECRETS:-0}" = "1" ] || load_secrets

# ============================================
# 常量
# ============================================
HEALTH_CHECK_MAX_RETRIES="${HEALTH_CHECK_MAX_RETRIES:-30}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-4}"
E2E_MAX_RETRIES="${E2E_MAX_RETRIES:-5}"
E2E_INTERVAL="${E2E_INTERVAL:-2}"
BACKUP_HOST_DIR="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-12}"
IMAGE_RETENTION_DAYS="${IMAGE_RETENTION_DAYS:-7}"

# 部署目标配置（per D-04）
DEPLOY_TARGET="${DEPLOY_TARGET:-r4s}"  # r4s 或 local（默认 r4s）
R4S_HOST="${R4S_HOST:-root@192.168.100.1}"  # r4s 主机
R4S_GIT_BRANCH="${R4S_GIT_BRANCH:-main}"   # r4s 同步分支

# 固定容器名 / 网络 / 反代容器
NETWORK_NAME="noda-network"
# 反代容器（三容器拆分 2026-09）：noda-static-prod 合并原 noda-infra-nginx 角色
# 迁移期兼容：noda-static-prod 不在运行时自动回退旧 noda-infra-nginx（见 _resolve_nginx_container*）
NGINX_CONTAINER="noda-static-prod"
NGINX_CONTAINER_LEGACY="noda-infra-nginx"
# prod 双容器（2026-09 三容器拆分 → S5 2026-09-12 frontend Node 容器退役，剩 api + static；
# 旧单容器名保留为 legacy 停旧/回滚引用）
PROD_API_CONTAINER="noda-api-prod"
PROD_STATIC_CONTAINER="noda-static-prod"
PROD_CONTAINER="noda-apps-prod"  # legacy 单容器（全部新容器 healthy 后由停旧逻辑处理）

# ============================================
# 辅助函数（从 manage-containers.sh 内联）
# ============================================

# is_container_running - 检查容器是否在运行
# 参数：$1 = 容器名
# 返回：true 或 false（通过 echo 输出）
is_container_running()
{
    local name="$1"
    local running
    running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")
    echo "$running"
}

# get_host_snippets_dir - 获取 nginx snippets 目录在宿主机上的实际路径
get_host_snippets_dir()
{
    local host_path
    local nginx_name
    nginx_name=$(_resolve_nginx_container)
    host_path=$(docker inspect "$nginx_name" --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/snippets"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
    if [ -n "$host_path" ] && [ -d "$host_path" ]; then
        echo "$host_path"
        return
    fi
    echo "$PROJECT_ROOT/config/nginx/snippets"
}

# _resolve_nginx_container - 解析反代容器名（本地模式）
# 三容器拆分后优先 noda-static-prod；迁移期回退旧 noda-infra-nginx
_resolve_nginx_container()
{
    local name
    for name in "$NGINX_CONTAINER" "$NGINX_CONTAINER_LEGACY"; do
        if [ "$(is_container_running "$name")" = "true" ]; then
            echo "$name"
            return 0
        fi
    done
    echo "$NGINX_CONTAINER"
}

# _resolve_nginx_container_remote - 解析反代容器名（r4s 远程模式）
_resolve_nginx_container_remote()
{
    local name
    for name in "$NGINX_CONTAINER" "$NGINX_CONTAINER_LEGACY"; do
        if [ "$(remote_exec "docker inspect -f '{{.State.Running}}' $name 2>/dev/null || echo false")" = "true" ]; then
            echo "$name"
            return 0
        fi
    done
    echo "$NGINX_CONTAINER"
}

# reload_nginx - 重载 nginx 配置
reload_nginx()
{
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程模式
        local nginx_name
        nginx_name=$(_resolve_nginx_container_remote)
        if [ "$(remote_exec "docker inspect -f '{{.State.Running}}' $nginx_name")" != "true" ]; then
            log_error "反代容器（r4s）($nginx_name) 未运行"
            return 1
        fi
        remote_docker_exec "$nginx_name" "nginx -s reload"
        log_success "nginx 配置已重载（r4s: ${nginx_name}）"
    else
        # 本地模式（原有逻辑）
        local nginx_name
        nginx_name=$(_resolve_nginx_container)
        if [ "$(is_container_running "$nginx_name")" != "true" ]; then
            log_error "反代容器 ($nginx_name) 未运行"
            return 1
        fi
        docker exec "$nginx_name" nginx -s reload
        log_success "nginx 配置已重载（${nginx_name}）"
    fi
}

# ============================================
# 函数: check_backup_freshness
# ============================================
# 检查数据库备份文件是否在指定小时内
# 策略：先检查当天/昨天日期子目录，再回退全目录搜索
# 返回：0=备份新鲜，1=备份过期或不存在
# 环境变量：
#   BACKUP_HOST_DIR - 备份目录（默认 $PROJECT_ROOT/docker/volumes/backup）
#   BACKUP_MAX_AGE_HOURS - 最大允许年龄小时数（默认 26，匹配每日备份节奏）
check_backup_freshness()
{
    local backup_dir="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}"
    # 默认 26h：备份每日 03:00 NZST 跑一次，12h 阈值会让下午部署误报过期
    local max_age_hours="${BACKUP_MAX_AGE_HOURS:-26}"

    # r4s 远程模式：生产数据库和备份都在 r4s 上，本地目录是旧残留（迁移前）
    # Jenkins Pre-flight 注入 SSH_KEY_FILE 时走远程检查；本地开发无 key，走本地目录
    # r4s 是 BusyBox：find 不支持 -printf，用 -mmin 判断新鲜度（最老可接受 = 阈值小时）
    if [ -n "$SSH_KEY_FILE" ] && [ -n "$R4S_HOST" ]; then
        local remote_backup_dir="${R4S_BACKUP_DIR:-/opt/noda/noda-infra/docker/volumes/backup}"
        local max_age_minutes=$(( max_age_hours * 60 ))
        local fresh_file
        fresh_file=$(remote_exec "find '${remote_backup_dir}' -type f \( -name '*.dump' -o -name '*.sql' \) -mmin -${max_age_minutes} 2>/dev/null | head -1" 30 | grep -v '^\s*$' | head -1)
        if [ -n "$fresh_file" ]; then
            log_info "备份检查通过（r4s）: 存在 ${max_age_hours} 小时内的新备份: $fresh_file"
            return 0
        fi
        # 无新鲜文件：确认目录里是否完全没有备份文件（区分"过期"与"从未备份"）
        local any_file
        any_file=$(remote_exec "find '${remote_backup_dir}' -type f \( -name '*.dump' -o -name '*.sql' \) 2>/dev/null | sort | tail -1" 30 | grep -v '^\s*$' | tail -1)
        if [ -z "$any_file" ]; then
            log_error "r4s 上未找到任何备份文件 (查找路径: $remote_backup_dir)"
        else
            log_error "r4s 备份已过期（阈值: ${max_age_hours} 小时）"
            log_error "最新备份: $any_file"
        fi
        return 1
    fi

    # 策略：先检查当天目录，再检查前一天（D-04）
    local today today_minus1
    today=$(date +"%Y/%m/%d")
    # macOS 兼容：BSD date 使用 -v-1d 代替 GNU date -d "yesterday"
    if date -v-1d >/dev/null 2>&1; then
        today_minus1=$(date -v-1d +"%Y/%m/%d")
    else
        today_minus1=$(date -d "yesterday" +"%Y/%m/%d")
    fi

    local newest_file=""
    for search_dir in "$backup_dir/$today" "$backup_dir/$today_minus1"; do
        if [ -d "$search_dir" ]; then
            # macOS 兼容：不支持 find -printf，使用 stat 获取修改时间
            newest_file=$(find "$search_dir" -type f \( -name "*.dump" -o -name "*.sql" \) \
                -exec stat -f '%m %N' {} \; 2>/dev/null |
                sort -rn | head -1 | cut -d' ' -f2-)
            [ -n "$newest_file" ] && break
        fi
    done

    # 回退：全目录搜索最新备份文件
    if [ -z "$newest_file" ]; then
        newest_file=$(find "$backup_dir" -type f \( -name "*.dump" -o -name "*.sql" \) \
            -exec stat -f '%m %N' {} \; 2>/dev/null |
            sort -rn | head -1 | cut -d' ' -f2-)
    fi

    if [ -z "$newest_file" ]; then
        log_error "未找到任何备份文件 (查找路径: ${backup_dir})"
        return 1
    fi

    # 计算文件年龄（秒 -> 小时）
    # macOS 兼容：BSD stat 使用 -f '%m' 代替 GNU stat -c%Y
    local file_epoch now_epoch age_seconds age_hours
    if stat -f '%m' "$newest_file" >/dev/null 2>&1; then
        file_epoch=$(stat -f '%m' "$newest_file")
    else
        file_epoch=$(stat -c%Y "$newest_file")
    fi
    now_epoch=$(date +%s)
    age_seconds=$((now_epoch - file_epoch))
    age_hours=$((age_seconds / 3600))

    if [ "$age_hours" -ge "$max_age_hours" ]; then
        log_error "备份已过期 ${age_hours} 小时（阈值: ${max_age_hours} 小时）"
        log_error "最新备份: $newest_file"
        return 1
    fi

    log_info "备份检查通过: 最新备份 ${age_hours} 小时前（阈值: ${max_age_hours} 小时）"
    return 0
}

# ============================================
# Pipeline 阶段函数
# ============================================

# pipeline_preflight - 前置检查
# 检查 Docker daemon、nginx 容器、noda-network
# noda-apps 额外检查 Node.js、pnpm、package.json、lint、test
# 参数: $1 = APPS_DIR (可选，默认 $WORKSPACE/noda-apps)
pipeline_preflight()
{
    local apps_dir="${1:-$WORKSPACE/noda-apps}"
    log_info "前置检查..."

    # 远程部署模式初始化（per D-04）
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # SSH 密钥由 Jenkins withCredentials 注入（per D-05）
        SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_rsa_noda_deploy}"
        setup_remote "$SSH_KEY_FILE" "$R4S_HOST"
        log_info "远程部署模式: $R4S_HOST"

        # 获取部署锁（per D-19/D-20）
        if ! acquire_deploy_lock 3600; then
            log_error "无法获取部署锁，可能有其他部署进行中"
            return 1
        fi
        log_info "部署锁获取成功"
        # 在 r4s 上同步最新代码（per D-08/D-10）
        log_info "同步 r4s 仓库..."
        # 使用 fetch + reset --hard origin 替代 git pull，确保即使远程历史被重写（force push）
        # 也能正确同步；用 -e 排除运行时数据目录（history/crawler-logs 等），保护生产数据
        remote_exec "cd /opt/noda/noda-infra && git fetch origin ${R4S_GIT_BRANCH} && git reset --hard origin/${R4S_GIT_BRANCH} && git clean -fd -e docker/volumes/" || {
            log_error "r4s 仓库同步失败"
            return 1
        }
        log_info "r4s 仓库同步完成"
    fi

    # 检查 Docker daemon（本地，用于构建）
    # 确保 PATH 包含 Docker 可执行文件路径（macOS: /usr/local/bin）
    export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
    docker info >/dev/null 2>&1 || {
        log_error "Docker daemon 不可用"
        return 1
    }
    log_info "Docker daemon 可用"

    # 检查反代容器（r4s 模式检查远程容器；三容器拆分后为 noda-static-prod，兼容旧 noda-infra-nginx）
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        local nginx_running
        # tr 归一化：r4s 登录 shell 可能输出额外换行，避免 "\ntrue" != true 误判
        nginx_running=$(remote_exec "docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER 2>/dev/null || docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER_LEGACY 2>/dev/null || echo false" | tr -d '[:space:]')
        if [ "$nginx_running" != "true" ]; then
            log_error "反代容器未运行（r4s 远程检查: ${NGINX_CONTAINER} / ${NGINX_CONTAINER_LEGACY}）"
            return 1
        fi
    else
        # 本地模式（Mac）：preprod 用 docker-compose 自带 static + postgres，
        # 不需要独立的 noda-infra-nginx 容器或 noda-network
        log_info "本地模式：跳过反代/network 检查（compose 自带）"
    fi

    local service="${SERVICE_NAME:-noda-apps}"

    # noda-apps 目录仅对从源码构建的服务需要（noda-apps）
    # Keycloak 等使用官方镜像的服务不需要
    if [ "$service" != "keycloak" ]; then
        if [ ! -d "$apps_dir" ]; then
            log_error "noda-apps 目录不存在: $apps_dir"
            log_error "请检查 Jenkinsfile Pre-flight stage 的 checkout 配置"
            return 1
        fi
        log_info "noda-apps 目录存在: $apps_dir"
    fi

    if [ "$service" = "noda-apps" ]; then
        # noda-apps 专用检查：Node.js、pnpm、package.json、lint、test、备份
        if ! command -v node >/dev/null 2>&1; then
            log_error "Node.js 未安装"
            return 1
        fi
        log_info "Node.js: $(node --version)"

        command -v pnpm >/dev/null 2>&1 || {
            log_error "pnpm 未安装，Test 阶段需要 pnpm"
            return 1
        }
        log_info "pnpm: $(pnpm --version)"

        if [ ! -f "$apps_dir/package.json" ]; then
            log_error "noda-apps/package.json 不存在: $apps_dir/package.json"
            return 1
        fi
        log_info "noda-apps/package.json 存在"

        if ! grep -q '"lint"' "$apps_dir/package.json"; then
            log_error "noda-apps/package.json 缺少 lint 脚本"
            return 1
        fi
        log_info "package.json lint 脚本存在"

        if ! grep -q '"test"' "$apps_dir/package.json"; then
            log_error "noda-apps/package.json 缺少 test 脚本"
            return 1
        fi
        log_info "package.json test 脚本存在"

        # 备份时效性检查（本地开发环境降级为警告）
        if ! check_backup_freshness; then
            log_warn "备份检查未通过，继续部署（生产环境应调查备份状态）"
        fi
    else
        # Keycloak: 检查官方镜像配置
        if [ "$service" = "keycloak" ]; then
            local service_image="${SERVICE_IMAGE:-}"
            if [ -z "$service_image" ]; then
                log_error "SERVICE_IMAGE 未设置（Keycloak 需要指定官方镜像）"
                return 1
            fi
            log_info "Keycloak 镜像: $service_image"
            log_info "Keycloak 不需要构建，将使用 docker pull 拉取官方镜像"
        else
            # 其他服务：检查 Dockerfile 存在
            local dockerfile="${DOCKERFILE:-$PROJECT_ROOT/noda-apps/infra/docker/Dockerfile.${service}}"
            if [ ! -f "$dockerfile" ]; then
                log_error "Dockerfile 不存在: $dockerfile"
                return 1
            fi
            log_info "Dockerfile 存在: $dockerfile"
        fi
    fi

    log_success "前置检查全部通过"
}

# pipeline_build - 构建镜像（S5 双镜像：noda-api / noda-static）
# 参数: $1 = APPS_DIR (noda-apps 目录), $2 = GIT_SHA
# Dockerfile：noda-apps/infra/docker/Dockerfile.{noda-api,noda-static}
# 环境变量控制：
#   SERVICE_NAME - 仅保留兼容（legacy 单容器路径）；三容器拆分后固定构建三镜像
# ============================================
# LAYER 过滤（2026-09-12 PRODUCT×LAYER）
# api / web 层独立构建与部署：Go 侧靠 Dockerfile GOCACHE 缓存挂载增量编译
# （改一个产品只重编该产品包）；web 侧 turbo/pnpm 缓存。LAYER 缺省 all。
# ============================================
_layer_want_api() { [ "$LAYER_FILTER" = "all" ] || [ "$LAYER_FILTER" = "api" ]; }
_layer_want_web() { [ "$LAYER_FILTER" = "all" ] || [ "$LAYER_FILTER" = "web" ]; }

pipeline_build()
{
    local apps_dir="$1"
    local git_sha="$2"
    LAYER_FILTER="${LAYER_FILTER:-all}"

    # 构建上下文 = HEAD 提交树的干净导出（git archive）：
    # 工作区可能残留未提交文件/并发会话写入（2026-09-13 build 338-341 实证），
    # 直接用工作目录会让 WIP 泄入镜像且不可复现——镜像必须是提交的确定性产物
    local ctx_dir
    ctx_dir=$(mktemp /tmp/noda-buildctx.XXXXXX)
    rm -rf "$ctx_dir" && mkdir -p "$ctx_dir"
    git -C "$apps_dir" archive HEAD | tar -x -C "$ctx_dir" || {
        log_error "git archive 导出构建上下文失败"
        rm -rf "$ctx_dir"
        return 1
    }
    trap 'rm -rf "$ctx_dir"' RETURN

    local df_dir="$ctx_dir/infra/docker"

    log_info "构建镜像（S5 双镜像: noda-api / noda-static）..."

    # 缓存策略（2026-09-11 复盘）：#312 曾试专用 container builder，但在本机
    # Docker Desktop 上 buildx --bootstrap 确定性挂起（docker 命令全部正常），
    # 回退内置 desktop-linux builder。真正的历史根因是宿主磁盘 94% 满——
    # 磁盘压力下 BuildKit GC 清缓存/元数据只读，表现为「层缓存记录丢失」。
    # 前提：宿主 /System/Volumes/Data 保持 ≥25GB 可用；Dockerfile 的
    # pnpm store / .next/cache / go-build cache mount 在磁盘健康时跨构建持久。
    docker buildx inspect desktop-linux >/dev/null 2>&1 || {
        log_error "默认 builder desktop-linux 不存在"
        return 1
    }


    # 显式本地构建缓存：本机 Docker Desktop(containerd) 的内置层缓存记录不可靠
    # （多次实测大 RUN 层记录丢失、跨构建不命中），local cache 导出/导入绕开该问题。
    # 目录跨构建持久，首次构建后即热。三镜像共用同一缓存目录。
    local cache_dir="${HOME}/.cache/noda-buildcache"
    mkdir -p "$cache_dir"

    # 缓存目录有界：超过上限整目录重建（local cache 无内建淘汰，旧记录会一直累积；
    # 清空后下次构建重新导出，仅慢一次）
    local cache_max_mb="${BUILD_CACHE_MAX_MB:-12288}"
    local cache_size_mb
    cache_size_mb=$(du -sm "$cache_dir" 2>/dev/null | cut -f1)
    if [ "${cache_size_mb:-0}" -gt "$cache_max_mb" ]; then
        log_info "构建缓存 ${cache_size_mb}MB 超过上限 ${cache_max_mb}MB，清理重建..."
        rm -rf "$cache_dir"
        mkdir -p "$cache_dir"
    fi

    # r4s 远程部署模式：镜像将在 Mac 构建后通过 SSH 传输到 r4s（per D-07）
    if [ "${DEPLOY_TARGET:-}" = "r4s" ]; then
        log_info "r4s 远程部署模式：镜像将在 Mac 构建后通过 SSH 传输到 r4s（per D-07）"
    fi

    # NEXT_PUBLIC_* build-args（照抄旧单容器清单；frontend 与 static 共用——
    # static 仅 www 消费其中 GA4_WWW_ID/Keycloak 等，多余变量无副作用）
    local next_public_args=(
        --build-arg NEXT_PUBLIC_KEYCLOAK_URL=https://auth.noda.co.nz
        --build-arg NEXT_PUBLIC_KEYCLOAK_REALM=noda
        --build-arg NEXT_PUBLIC_KEYCLOAK_CLIENT_ID=noda-frontend
        --build-arg NEXT_PUBLIC_AUTH_APP_URL=https://auth.noda.co.nz
        --build-arg NEXT_PUBLIC_AUTH_BYPASS=false
        --build-arg NEXT_PUBLIC_AUTH_KEYCLOAK_CLIENT_ID=noda-auth
        --build-arg "NEXT_PUBLIC_ALLOWED_ORIGINS=https://class.noda.co.nz,https://noda.co.nz"
        --build-arg NEXT_PUBLIC_SITE_URL=https://class.noda.co.nz
        --build-arg NEXT_PUBLIC_REMARK_URL=https://comments.noda.co.nz
        --build-arg NEXT_PUBLIC_GA4_WWW_ID=G-FPEF7LXD2F
        --build-arg NEXT_PUBLIC_GA4_LIUYAO_ID=G-ZXK92PWTEF
        --build-arg NEXT_PUBLIC_GA4_NEARBY_ID=G-58CDREDT81
        --build-arg NEXT_PUBLIC_NEARBY_SITE_URL=https://nearby.noda.co.nz
    )

    # 1/3 Go API（无 build-args；LAYER=web 时跳过——多模块 + GOCACHE 增量，只重编译改动包）
    # 只打 commit tag 不打 latest（2026-09-13）：latest 与 commit tag 指向同一镜像，
    # 纯视觉重复且会掩盖「latest 到底是哪版」的疑问；部署/回滚统一走 commit tag
    if _layer_want_api; then
    docker buildx build --load \
        --cache-from type=local,src="$cache_dir" \
        --cache-to type=local,dest="$cache_dir",mode=max \
        -t "noda-api:${git_sha}" \
        -f "$df_dir/Dockerfile.noda-api" \
        "$ctx_dir"
    log_success "镜像构建完成: noda-api:${git_sha}"
    fi

    # 2/3 Next.js Frontend Node 镜像（S5 2026-09-12 退役：auth/comment API 已 Go 化、
    # 五站页面静态化经 publish_*_static 桶发布——运行时零 Node，不再构建此镜像。
    # 回滚锚点：R4S/Mac 仍保留最后一个 noda-frontend 镜像，upstream 变量改回即可）

    # 3/3 Static（nginx + www 静态导出；LAYER=api 时跳过）
    if _layer_want_web; then
    docker buildx build --load \
        --cache-from type=local,src="$cache_dir" \
        --cache-to type=local,dest="$cache_dir",mode=max \
        -t "noda-static:${git_sha}" \
        -f "$df_dir/Dockerfile.noda-static" \
        "${next_public_args[@]}" \
        "$ctx_dir"
    log_success "镜像构建完成: noda-static:${git_sha}"
    fi

    # 本地镜像版本保留（每仓库最新 2 版）——构建后即清，防「多次构建未部署」堆积
    docker_image_retention noda-api
    docker_image_retention noda-static
}

# ============================================
# pipeline_post_publish_cleanup - 发布后统一清理（2026-09-13）
# ============================================
# 用户要求：每次 Jenkins 发布后自动清理旧资源，preprod 与 prod 均生效：
#   ① docker 旧镜像——Mac 构建机 + r4s（docker_image_retention：每仓库保留
#      最新 2 版 = 当前 + 回滚锚点；同 ID 多 tag 折叠）
#   ② registry 旧镜像——localhost:5001 retention（keep 2）+ blob GC 回收磁盘
#      （此前仅 Jenkinsfile.cleanup 周一 03:00 cron 跑，发布高峰期一周内可堆积
#      数十 tag；现随每次发布收敛）
#   ③ SeaweedFS 旧对象——apps 发布不写桶；桶收敛在 *-static 发布内经
#      mc mirror --remove 完成（见 pipeline_publish_static_site，prod+stg 双桶）
# 幂等；清理失败不回滚已成功的发布（|| true 兜底，仅日志可见）。
# 调用点：pipeline_deploy_prod / pipeline_deploy_preprod 成功尾部（双环境四路径）
pipeline_post_publish_cleanup()
{
    log_info "=== 发布后清理（镜像 / registry 保留策略）==="

    # ① Mac 构建机镜像保留
    docker_image_retention noda-api || true
    docker_image_retention noda-static || true

    # ② registry retention + GC（cleanup.sh 提供；registry 不可达时内部跳过）
    registry_maintenance || true

    # ③ r4s 镜像保留（仅远程部署模式动过 r4s 时需要）
    if [ "${DEPLOY_TARGET:-}" = "r4s" ]; then
        docker_image_retention noda-api "" remote || true
        docker_image_retention noda-static "" remote || true
    fi

    log_success "发布后清理完成"
}

# pipeline_test - 安装依赖（lint/test 由 Jenkinsfile 独立 sh 步骤调用）
# 参数: $1 = APPS_DIR (noda-apps 目录)
pipeline_test()
{
    local apps_dir="$1"
    (
        cd "$apps_dir"
        pnpm install --frozen-lockfile
        log_success "依赖安装完成"
    )

    # Go 多模块测试（2026-09-12 补齐：此前 CI 只跑 pnpm test，Go 测试从未进流水线）。
    # LAYER=web 跳过；PRODUCT≠all 只测对应产品模块 + common（保持反馈聚焦）。
    if [ "${LAYER_FILTER:-all}" != "web" ]; then
        local modules="api common common/crawler common/jobs nearby/api class/api liuyao/api admin/api auth/api comment/api"
        case "${PRODUCT_FILTER:-all}" in
            class)            modules="class/api common" ;;
            liuyao)           modules="liuyao/api common" ;;
            nearby)           modules="nearby/api common" ;;
            admin)            modules="admin/api common" ;;
            auth)             modules="auth/api common" ;;
            comment)          modules="comment/api common" ;;
            www)              modules="" ;;
        esac
        local m
        for m in $modules; do
            log_info "Go 测试: $m"
            ( cd "$apps_dir/$m" && go build ./... && go test ./... ) || return 1
        done
        log_success "Go 测试全部通过"
    fi
}

# ============================================
# 函数: pipeline_pull_image
# ============================================
# 拉取官方镜像（用于不从源码构建的服务如 Keycloak）
# 环境变量控制：
#   SERVICE_IMAGE - 官方镜像名（如 quay.io/keycloak/keycloak:26.2.3）
# 返回：0=成功，1=失败
pipeline_pull_image()
{
    local image="${SERVICE_IMAGE:-}"

    if [ -z "$image" ]; then
        log_error "SERVICE_IMAGE 未设置，无法拉取镜像"
        return 1
    fi

    log_info "拉取镜像: $image"

    if ! docker pull "$image"; then
        log_error "镜像拉取失败: $image"
        return 1
    fi

    log_success "镜像拉取完成: $image"
}


# _r4s_mem_available_mb - r4s 当前可用内存（MB），读取失败输出空字符串
# 用 /proc/meminfo 的 MemAvailable（含可回收页缓存），BusyBox awk 兼容
_r4s_mem_available_mb()
{
    remote_exec "awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo" 2>/dev/null | tr -d "'" | head -1
}

# ============================================
# 内部函数: _start_prod_api / _start_prod_static
# ============================================
# 三容器启动（三容器拆分 2026-09）。
# 参数: $1 = mode(remote|local)  $2 = image  $3 = env_file（remote: r4s 路径 / local: 本地路径）
# 返回: 启动命令失败返回非零（启动前先清理同名旧容器）
# 资源配额与 docker-compose.r4s.yml / docker-compose.apps-prod.yml 保持一致：
#   api 256m/0.5cpu、static 128m/0.25cpu
_start_prod_api()
{
    local mode="$1" image="$2" env_file="$3"
    log_info "启动容器: $PROD_API_CONTAINER ($image)"
    if [ "$mode" = "remote" ]; then
        remote_exec "docker rm -f $PROD_API_CONTAINER >/dev/null 2>&1 || true"
        remote_exec "docker run -d \
            --name $PROD_API_CONTAINER \
            --network $NETWORK_NAME \
            --network-alias $PROD_API_CONTAINER \
            --restart always \
            --stop-timeout 30 \
            --security-opt no-new-privileges \
            --cap-drop ALL \
            --read-only \
            --tmpfs /tmp \
            --tmpfs /app/crawl-output:uid=1001,gid=1001,mode=0755 \
            --tmpfs /app/crawler-logs:uid=1001,gid=1001,mode=0755 \
            --memory 256m \
            --memory-reservation 64m \
            --cpus 0.5 \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --env-file $env_file \
            --label com.docker.compose.project=noda-infra \
            --label com.docker.compose.service=noda-api \
            --label noda.service-group=apps \
            --label noda.environment=prod \
            --health-cmd \"wget --quiet --tries=1 --spider http://127.0.0.1:3001/api/health || exit 1\" \
            --health-interval 30s \
            --health-timeout 10s \
            --health-retries 3 \
            --health-start-period 30s \
            $image"
    else
        docker rm -f "$PROD_API_CONTAINER" >/dev/null 2>&1 || true
        docker run -d \
            --name "$PROD_API_CONTAINER" \
            --network "$NETWORK_NAME" \
            --network-alias "$PROD_API_CONTAINER" \
            --restart unless-stopped \
            --stop-timeout 30 \
            --security-opt no-new-privileges \
            --cap-drop ALL \
            --read-only \
            --tmpfs /tmp \
            --tmpfs /app/crawl-output:uid=1001,gid=1001,mode=0755 \
            --tmpfs /app/crawler-logs:uid=1001,gid=1001,mode=0755 \
            --memory 256m \
            --memory-reservation 64m \
            --cpus 0.5 \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --env-file "$env_file" \
            --label "com.docker.compose.project=noda-infra" \
            --label "com.docker.compose.service=noda-api-prod" \
            --label "noda.service-group=apps" \
            --label noda.environment=prod \
            --health-cmd "wget --quiet --tries=1 --spider http://127.0.0.1:3001/api/health || exit 1" \
            --health-interval 30s \
            --health-timeout 10s \
            --health-retries 3 \
            --health-start-period 30s \
            "$image"
    fi
}

# static：镜像内烘焙 www 静态站；反代配置由卷挂载覆盖
# r4s 高端口 8080/8081/8443 与 compose 定义一致；别名 noda-infra-nginx 必须保留
# （cloudflared 与 KEYCLOAK_INTERNAL_URL 引用）；compose 服务键为 nginx（infra 栈合并管理）
_start_prod_static()
{
    local mode="$1" image="$2"
    local config_dir="/opt/noda/noda-infra/config/nginx"
    # 过渡期宿主端口绑高位：旧 noda-infra-nginx 在退役前一直占用 8080/8081/8443，
    # 新 static 先行高位并存（流量经 docker DNS 别名 noda-infra-nginx 分流），
    # 旧 nginx 退役后由运维将宿主端口切到本容器（一次性操作，不在 pipeline 内）。
    local ports="-p 18080:80 -p 18081:81 -p 18443:443"
    if [ "$mode" != "remote" ]; then
        config_dir="$PROJECT_ROOT/config/nginx"
        # 本地模式不占宿主端口（infra nginx 可能占用 80/81/443），仅容器网络内服务
        ports=""
    fi
    log_info "启动容器: $PROD_STATIC_CONTAINER ($image)"
    if [ "$mode" = "remote" ]; then
        remote_exec "docker rm -f $PROD_STATIC_CONTAINER >/dev/null 2>&1 || true"
        remote_exec "docker run -d \
            --name $PROD_STATIC_CONTAINER \
            --network $NETWORK_NAME \
            --network-alias $PROD_STATIC_CONTAINER \
            --network-alias noda-infra-nginx \
            --restart always \
            --stop-timeout 30 \
            --security-opt no-new-privileges \
            --cap-drop ALL \
            --cap-add NET_BIND_SERVICE \
            --cap-add CHOWN \
            --cap-add SETGID \
            --cap-add SETUID \
            --read-only \
            --tmpfs /var/cache/nginx \
            --tmpfs /var/run \
            --tmpfs /tmp \
            $ports \
            -v $config_dir/nginx.conf:/etc/nginx/nginx.conf:ro \
            -v $config_dir/conf.d:/etc/nginx/conf.d:ro \
            -v $config_dir/snippets:/etc/nginx/snippets:ro \
            -v $config_dir/ssl:/etc/nginx/ssl:ro \
            -v $config_dir/errors:/etc/nginx/errors:ro \
            --memory 128m \
            --memory-reservation 32m \
            --cpus 0.25 \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --label com.docker.compose.project=noda-infra \
            --label com.docker.compose.service=nginx \
            --label noda.service-group=apps \
            --label noda.environment=prod \
            --health-cmd \"wget --quiet --tries=1 --spider http://127.0.0.1:81/health || exit 1\" \
            --health-interval 30s \
            --health-timeout 5s \
            --health-retries 3 \
            --health-start-period 10s \
            $image"
    else
        docker rm -f "$PROD_STATIC_CONTAINER" >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        docker run -d \
            --name "$PROD_STATIC_CONTAINER" \
            --network "$NETWORK_NAME" \
            --network-alias "$PROD_STATIC_CONTAINER" \
            --network-alias noda-infra-nginx \
            --restart unless-stopped \
            --stop-timeout 30 \
            --security-opt no-new-privileges \
            --cap-drop ALL \
            --cap-add NET_BIND_SERVICE \
            --cap-add CHOWN \
            --cap-add SETGID \
            --cap-add SETUID \
            --read-only \
            --tmpfs /var/cache/nginx \
            --tmpfs /var/run \
            --tmpfs /tmp \
            $ports \
            -v "$config_dir/nginx.conf:/etc/nginx/nginx.conf:ro" \
            -v "$config_dir/conf.d:/etc/nginx/conf.d:ro" \
            -v "$config_dir/snippets:/etc/nginx/snippets:ro" \
            -v "$config_dir/ssl:/etc/nginx/ssl:ro" \
            -v "$config_dir/errors:/etc/nginx/errors:ro" \
            --memory 128m \
            --memory-reservation 32m \
            --cpus 0.25 \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --label "com.docker.compose.project=noda-infra" \
            --label "com.docker.compose.service=nginx" \
            --label "noda.service-group=apps" \
            --label noda.environment=prod \
            --health-cmd "wget --quiet --tries=1 --spider http://127.0.0.1:81/health || exit 1" \
            --health-interval 30s \
            --health-timeout 5s \
            --health-retries 3 \
            --health-start-period 10s \
            "$image"
    fi
}

# _stop_new_prod_containers - 失败时清理本次触达的新容器（mode: remote|local）
# S5：容器只剩 api + static（frontend Node 容器 2026-09-12 退役）
_stop_new_prod_containers()
{
    local mode="$1"
    local name
    for name in "$PROD_STATIC_CONTAINER" "$PROD_API_CONTAINER"; do
        # LAYER 过滤：只清理本次部署触达的层（LAYER=api 时不得误杀在线 web 容器）
        case "$name" in
            "$PROD_API_CONTAINER") _layer_want_api || continue ;;
            *)                     _layer_want_web || continue ;;
        esac
        if [ "$mode" = "remote" ]; then
            remote_exec "docker stop -t 10 $name >/dev/null 2>&1 || true"
            remote_exec "docker rm -f $name >/dev/null 2>&1 || true"
        else
            docker stop -t 10 "$name" >/dev/null 2>&1 || true
            docker rm -f "$name" >/dev/null 2>&1 || true
        fi
    done
}

# ============================================
# 函数: pipeline_deploy_prod
# ============================================
# 生产环境双容器部署（三容器拆分 2026-09 → S5 frontend 退役 2026-09-12）：
#   传镜像（api/static 按 LAYER）→ 依序启新容器 → 各自健康检查
#   → reload nginx 切流 → 停旧 legacy 单容器（KEEP_LEGACY_APPS=1 跳过，灰度用）
# 安全措施（沿用 transfer-first 内存护栏与回滚语义）：
#   - 镜像成功落地 r4s 前绝不动旧容器（传输失败旧容器全程未动/秒级 docker start 回滚）
#   - 任一新容器启动/健康检查失败 → 停止并删除全部新容器，旧 noda-apps-prod 不受影响
#     （旧容器此刻仍在运行或可 docker start 秒级恢复——因此切换期间无需旧镜像重建）
#   - 三个新容器全部 healthy 后才停旧容器（只停不删，供秒级回滚）
# 参数: $1 = GIT_SHA
pipeline_deploy_prod()
{
    local git_sha="$1"
    LAYER_FILTER="${LAYER_FILTER:-all}"
    local api_image="noda-api:${git_sha}"
    local static_image="noda-static:${git_sha}"

    disk_snapshot "部署前"

    log_info "生产环境部署（LAYER=${LAYER_FILTER}）: $PROD_API_CONTAINER + $PROD_STATIC_CONTAINER ($git_sha)"

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式，两种顺序（沿用单容器时代不变式，2026-09-02 #200 事故教训）：
        #
        # TRANSFER_FIRST=1（默认）：先传三镜像（旧容器继续服务）→ 落地后启新容器切换。
        #   内存护栏：传输前读 r4s MemAvailable，低于阈值或读取失败自动回退先停模式。
        # TRANSFER_FIRST=0：先停（不删）旧容器再传镜像，内存紧张设备的保底模式。
        local legacy_running="false"
        if [ "$(remote_exec "docker inspect -f '{{.State.Running}}' $PROD_CONTAINER" 2>/dev/null)" = "true" ]; then
            legacy_running="true"
        fi

        # 模式决策（内存护栏）
        local transfer_first="${TRANSFER_FIRST:-1}"
        local min_free_mb="${TRANSFER_FIRST_MIN_FREE_MB:-1024}"
        if [ "$transfer_first" = "1" ]; then
            local free_mb
            free_mb=$(_r4s_mem_available_mb)
            if [ -z "$free_mb" ]; then
                log_warn "无法读取 r4s 可用内存，保守起见回退先停后传模式"
                transfer_first=0
            elif [ "$free_mb" -lt "$min_free_mb" ]; then
                log_warn "r4s 可用内存 ${free_mb}MB < ${min_free_mb}MB，回退先停后传模式"
                transfer_first=0
            else
                log_info "transfer-first 模式：r4s 可用内存 ${free_mb}MB ≥ ${min_free_mb}MB，旧容器保持服务，先传镜像"
            fi
        fi

        if [ "$transfer_first" != "1" ] && [ "$legacy_running" = "true" ]; then
            # 先停模式：只停（不删）旧容器，释放内存峰值，容器保留用于回滚
            log_info "停止旧容器（r4s，不删除）: $PROD_CONTAINER"
            remote_exec "docker stop -t 10 $PROD_CONTAINER || true"
        fi

        # 传输镜像（按 LAYER 裁剪；transfer-first 模式下旧容器持续服务，r4s 增量拉层落盘）
        log_info "r4s 远程部署模式：传输镜像到 r4s（LAYER=${LAYER_FILTER:-all}）..."
        local img
        local transfer_list=()
        if _layer_want_api; then transfer_list+=("$api_image"); fi
        if _layer_want_web; then transfer_list+=("$static_image"); fi  # S5：frontend 镜像退役
        for img in "${transfer_list[@]}"; do
            if ! transfer_image "$img" "$img"; then
                log_error "镜像传输失败: $img"
                if [ "$transfer_first" = "1" ]; then
                    log_info "transfer-first 模式：旧容器未受影响，线上继续服务"
                elif [ "$legacy_running" = "true" ]; then
                    log_info "尝试回滚：docker start 恢复旧容器 $PROD_CONTAINER..."
                    remote_exec "docker start $PROD_CONTAINER" >/dev/null 2>&1 || true
                    reload_nginx || true
                fi
                return 1
            fi
        done

        # 切换不变式：本次部署的镜像必须确认落地 r4s，才允许动旧容器
        for img in "${transfer_list[@]}"; do
            if ! remote_exec "docker image inspect $img >/dev/null 2>&1"; then
                if [ "$transfer_first" != "1" ] && [ "$legacy_running" = "true" ]; then
                    log_warn "回滚先停的旧容器..."
                    remote_exec "docker start $PROD_CONTAINER || true"
                    reload_nginx || true
                fi
                log_error "镜像 $img 未在 r4s 落地（pull 未完成），保持旧容器服务，中止切换"
                return 1
            fi
        done

        # 准备 env 文件（api；S5 起 static 容器纯 nginx 无需 env）
        local tmp_api_env=""
        if _layer_want_api; then
            tmp_api_env=$(prepare_prod_api_env_file) || return 1
        fi
        log_info "传输 env 文件到 r4s..."
        if [ -n "$tmp_api_env" ]; then
            cat "$tmp_api_env" | remote_exec "cat > /tmp/prod-api.env && chmod 600 /tmp/prod-api.env"
        fi
        rm -f "$tmp_api_env"

        # 依序启动本层容器（api → static；未触达层保持原容器不动）
        # 任一失败：清理本层新容器 + 恢复旧容器（transfer-first 下旧容器一直在跑）
        if _layer_want_api && ! _start_prod_api remote "$api_image" "/tmp/prod-api.env"; then
            log_error "api 容器启动失败"
            _stop_new_prod_containers remote
            [ "$legacy_running" = "true" ] && remote_exec "docker start $PROD_CONTAINER" >/dev/null 2>&1 || true
            reload_nginx || true
            return 1
        fi
        # S5 退役：frontend Node 容器不再部署（运行时零 Node）
        if _layer_want_web && ! _start_prod_static remote "$static_image"; then
            log_error "static 容器启动失败"
            _stop_new_prod_containers remote
            [ "$legacy_running" = "true" ] && remote_exec "docker start $PROD_CONTAINER" >/dev/null 2>&1 || true
            reload_nginx || true
            return 1
        fi

        # 健康检查（各自容器内探测，远程）
        log_info "等待三容器健康检查（r4s 远程）..."
        local health_timeout="$((HEALTH_CHECK_MAX_RETRIES * HEALTH_CHECK_INTERVAL))"
        if _layer_want_api && ! wait_container_healthy "$PROD_API_CONTAINER" "$health_timeout" true true; then
            log_error "api 容器健康检查失败 — 清理新容器，回滚"
            _stop_new_prod_containers remote
            [ "$legacy_running" = "true" ] && remote_exec "docker start $PROD_CONTAINER" >/dev/null 2>&1 || true
            reload_nginx || true
            return 1
        fi
        if _layer_want_web && ! wait_container_healthy "$PROD_STATIC_CONTAINER" "$health_timeout" true true; then
            log_error "static 容器健康检查失败 — 清理新容器，回滚"
            _stop_new_prod_containers remote
            [ "$legacy_running" = "true" ] && remote_exec "docker start $PROD_CONTAINER" >/dev/null 2>&1 || true
            reload_nginx || true
            return 1
        fi

        # 三个新容器全部 healthy：reload nginx 切流（upstream 指向新容器）
        reload_nginx

        # 停旧 legacy 单容器（只停不删，供秒级回滚）；KEEP_LEGACY_APPS=1 跳过（灰度对照）
        if [ "${KEEP_LEGACY_APPS:-0}" = "1" ]; then
            log_warn "KEEP_LEGACY_APPS=1 — 保留旧容器 $PROD_CONTAINER 运行（灰度模式，请人工确认后停用）"
        elif [ "$legacy_running" = "true" ]; then
            log_info "三个新容器已全部 healthy，停止旧容器（不删除）: $PROD_CONTAINER"
            remote_exec "docker stop -t 10 $PROD_CONTAINER || true"
        fi

        # 发布后统一清理：Mac+r4s 镜像保留、registry retention+GC（失败不回滚部署）
        pipeline_post_publish_cleanup

        log_success "生产环境部署完成（r4s）: $PROD_API_CONTAINER + $PROD_STATIC_CONTAINER ($git_sha)"
    else
        # 本地模式（Mac）
        local legacy_running="false"
        if [ "$(is_container_running "$PROD_CONTAINER")" = "true" ] || docker inspect "$PROD_CONTAINER" >/dev/null 2>&1; then
            legacy_running="true"
        fi

        # 准备 env 文件（api）
        local tmp_api_env=""
        if _layer_want_api; then
            tmp_api_env=$(prepare_prod_api_env_file) || return 1
        fi

        # 依序启动本层容器
        if _layer_want_api && ! _start_prod_api local "$api_image" "$tmp_api_env"; then
            log_error "api 容器启动失败（本地模式）"
            rm -f "$tmp_api_env"
            return 1
        fi
        # S5 退役：frontend Node 容器不再部署（运行时零 Node）
        if _layer_want_web && ! _start_prod_static local "$static_image"; then
            log_error "static 容器启动失败（本地模式）"
            _stop_new_prod_containers local
            rm -f "$tmp_api_env"
            return 1
        fi

        rm -f "$tmp_api_env"

        # reload 反代刷新 DNS 缓存（容器重建后 IP 会变）
        reload_nginx || true

        # 健康检查
        log_info "等待三容器健康检查（本地模式）..."
        local health_timeout="$((HEALTH_CHECK_MAX_RETRIES * HEALTH_CHECK_INTERVAL))"
        if _layer_want_api && ! wait_container_healthy "$PROD_API_CONTAINER" "$health_timeout"; then
            log_error "api 容器健康检查失败（本地模式）"
            return 1
        fi
        if _layer_want_web && ! wait_container_healthy "$PROD_STATIC_CONTAINER" "$health_timeout"; then
            log_error "static 容器健康检查失败（本地模式）"
            return 1
        fi

        # 停旧 legacy 单容器（KEEP_LEGACY_APPS=1 跳过）
        if [ "${KEEP_LEGACY_APPS:-0}" = "1" ]; then
            log_warn "KEEP_LEGACY_APPS=1 — 保留旧容器 $PROD_CONTAINER (灰度模式)"
        elif [ "$legacy_running" = "true" ]; then
            log_info "三个新容器已全部 healthy，停止旧容器（不删除）: $PROD_CONTAINER"
            docker stop -t 10 "$PROD_CONTAINER" || true
        fi

        # 发布后统一清理（本地模式：Mac 镜像保留 + registry；失败不回滚部署）
        pipeline_post_publish_cleanup

        log_success "生产环境部署完成: $PROD_API_CONTAINER + $PROD_STATIC_CONTAINER ($git_sha)"
    fi
}

# ============================================
# 内部函数: _prepare_env_file
# ============================================
# 通用 env 模板渲染：envsubst 替换 ${VAR} 后写临时文件（600 权限）
# 参数: $1 = 模板路径  $2 = 输出路径  $3 = envsubst 变量清单
_prepare_env_file()
{
    local env_template="$1" tmp_file="$2" vars="$3"
    if [ ! -f "$env_template" ]; then
        log_error "env 模板文件不存在: $env_template"
        return 1
    fi
    envsubst "$vars" <"$env_template" >"$tmp_file"
    chmod 600 "$tmp_file"
}

# ============================================
# 函数: prepare_prod_api_env_file
# ============================================
# 生成 prod api env 文件（S5：frontend env 随 Node 容器退役删除）
#   api      → env-noda-api.env       → r4s /tmp/prod-api.env
# 返回: 临时 env 文件路径（通过 echo 输出）
prepare_prod_api_env_file()
{
    local tmp_file="/tmp/noda-api-prod.env.$$"
    _prepare_env_file \
        "$PROJECT_ROOT/docker/env-noda-api.env" \
        "$tmp_file" \
        '${POSTGRES_USER} ${POSTGRES_PASSWORD} ${RESEND_API_KEY} ${ANTHROPIC_AUTH_TOKEN} ${ANTHROPIC_BASE_URL} ${ANTHROPIC_API_KEY} ${ANTHROPIC_MAX_TOKENS} ${TOKEN_SECRET} ${EMAIL_SERVICE_API_KEY} ${STRIPE_SECRET_KEY} ${STRIPE_WEBHOOK_SECRET} ${STRIPE_PRICE_DEEP_READ} ${LIUYAO_WEB_BASE_URL} ${EVENTFINDA_API_HOST} ${EVENTFINDA_API_USERNAME} ${EVENTFINDA_API_PASSWORD}' \
        || return 1
    echo "$tmp_file"
}

# pipeline_purge_cdn - 调用 Cloudflare API 清除 CDN 缓存
# 环境变量（由 Jenkins withCredentials 注入）：
#   CF_API_TOKEN - Cloudflare API Token
#   CF_ZONE_ID   - Cloudflare Zone ID
# 返回：0=成功或跳过（永远不阻止部署，per D-09）
pipeline_purge_cdn()
{
    # 凭据缺失时跳过（D-11）
    if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ZONE_ID:-}" ]; then
        log_warn "Cloudflare 凭据未配置，跳过 CDN 缓存清除"
        return 0
    fi

    log_info "清除 CDN 缓存 (zone: $CF_ZONE_ID)..."

    # 使用临时文件传递 JSON body，避免凭据出现在命令行参数中
    local tmp_body
    tmp_body=$(mktemp)
    echo '{"purge_everything":true}' >"$tmp_body"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d @"$tmp_body" \
        --connect-timeout 10 \
        --max-time 30 2>/dev/null) || true

    rm -f "$tmp_body"

    if [ "$http_code" = "200" ]; then
        log_success "CDN 缓存清除完成"
    else
        # D-09: 失败不阻止部署
        log_error "CDN 缓存清除失败 (HTTP ${http_code:-timeout})，不影响部署"
    fi

    return 0
}

# pipeline_cleanup - 清理旧镜像
# 官方镜像服务（Keycloak 等）跳过 SHA 镜像清理，仅清理 dangling images
pipeline_cleanup()
{
    # 官方镜像服务（Keycloak 等）不需要 SHA 镜像清理
    # S5 双容器：本 Mac 侧清理覆盖 noda-api / noda-static
    if [ -z "${SERVICE_IMAGE:-}" ]; then
        local _img_repo
        for _img_repo in noda-api noda-static; do
            cleanup_by_date_threshold "$_img_repo" "${IMAGE_RETENTION_DAYS:-7}"
        done
    else
        # 仅清理 dangling images
        cleanup_dangling
    fi

    # === registry 保留策略（每仓库最新 2 版；retired 仓库全删）===
    # 先本地清理再清 registry：retention 删除的 tag 其 blob 可能仍被本地 tag 引用
    registry_retention || true

    # === 部署后全面清理（per D-03）===
    cleanup_after_deploy "${WORKSPACE:-$PWD}"

    # === 清理 r4s 上的旧镜像（保留当前运行 + 上一个版本用于回滚）===
    if [ "${DEPLOY_TARGET:-}" = "r4s" ] && [ -n "${SSH_KEY_FILE:-}" ]; then
        log_info "清理 r4s 旧镜像..."
        # S5 双容器：分别清理 noda-api / noda-static 旧镜像，
        # 各保留最新的 2 个（当前 + 回滚），删除其余
        remote_exec "
            for repo in noda-api noda-static; do
                docker images \$repo --format '{{.ID}} {{.Tag}}' | \
                grep -v '<none>' | \
                sort -k2 -r | \
                tail -n +3 | \
                awk '{print \$1}' | \
                while read id; do docker rmi \$id 2>/dev/null; done
            done
            docker image prune -f 2>/dev/null
        " 2>/dev/null || true
        log_info "r4s 镜像清理完成"
    fi
}

# pipeline_failure_cleanup - 部署失败时捕获日志并清理
pipeline_failure_cleanup()
{
    # 捕获容器日志（S5 双容器 api + static；如果容器存在）
    docker logs "$PROD_API_CONTAINER" >deploy-failure-api.log 2>&1 || true
    docker logs "$PROD_STATIC_CONTAINER" >deploy-failure-static.log 2>&1 || true

    # 捕获反代容器日志（legacy 容器名兜底）
    docker logs "$(_resolve_nginx_container)" --tail 50 >deploy-failure-nginx.log 2>&1 || true

    # 清理失败的新容器
    docker rm -f "$PROD_API_CONTAINER" "$PROD_STATIC_CONTAINER" 2>/dev/null || true

    log_info "失败日志已保存: deploy-failure-{api,static,nginx}.log"
}

# ============================================
# 基础设施服务 Pipeline 函数
# ============================================
# 用于 Jenkinsfile.infra 统一基础设施 Pipeline
# 支持 4 种服务: keycloak, nginx, noda-ops, postgres
# 每种服务使用独立的部署/健康检查策略
# ============================================

# ============================================
# 函数: pipeline_infra_preflight
# ============================================
# 基础设施服务前置检查（统一入口）
# 参数: $1 = SERVICE (keycloak/nginx/noda-ops/postgres)
# 返回: 0=检查通过，1=检查失败
pipeline_infra_preflight()
{
    local service="$1"

    log_info "基础设施前置检查: $service"

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程模式：同步仓库 + 检查远程 Docker daemon
        log_info "r4s 远程模式前置检查..."

        # 同步 r4s 仓库
        log_info "同步 r4s 仓库..."
        # 使用 fetch + reset --hard 替代 git pull，确保即使远程历史被重写（force push）
        # 也能正确同步；清理本地修改避免冲突
        # 注意: git clean -fd 不删除 .gitignore 忽略的文件（如 backup/logs）；
        # 用 -e 排除运行时数据目录（history/crawler-logs 等），保护生产数据
        remote_exec "cd /opt/noda/noda-infra && git fetch origin ${R4S_GIT_BRANCH}" || {
            log_error "r4s 仓库 fetch 失败"
            return 1
        }
        remote_exec "cd /opt/noda/noda-infra && git reset --hard origin/${R4S_GIT_BRANCH} && git clean -fd -e docker/volumes/" || {
            log_error "r4s 仓库 reset 失败"
            return 1
        }
        log_info "r4s 仓库同步完成"

        # 检查远程 Docker daemon
        log_info "r4s 远程模式前置检查..."
        remote_exec "docker info >/dev/null 2>&1" || {
            log_error "r4s Docker daemon 不可用"
            return 1
        }
        log_info "r4s Docker daemon 可用"

        # 检查远程反代容器（三容器拆分后为 noda-static-prod，legacy noda-infra-nginx 兜底）
        local running
        running=$(remote_exec "docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER 2>/dev/null || docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER_LEGACY 2>/dev/null || echo false")
        if [ "$running" != "true" ]; then
            if [ "$service" = "nginx" ]; then
                log_info "反代容器未运行，正在通过 docker compose 启动（r4s 远程）..."
                remote_compose "up -d --no-deps nginx" \
                    "-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.r4s.yml" || {
                    log_error "docker compose 启动反代容器失败（r4s）"
                    return 1
                }
                # 等待反代容器就绪
                local _wait=0
                while [ "$_wait" -lt 30 ]; do
                    running=$(remote_exec "docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER 2>/dev/null || docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER_LEGACY 2>/dev/null || echo false")
                    if [ "$running" = "true" ]; then
                        log_info "反代容器已启动（等待 ${_wait} 秒）"
                        break
                    fi
                    sleep 1
                    _wait=$((_wait + 1))
                done
                running=$(remote_exec "docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER 2>/dev/null || docker inspect -f '{{.State.Running}}' $NGINX_CONTAINER_LEGACY 2>/dev/null || echo false")
                if [ "$running" != "true" ]; then
                    log_error "反代容器启动超时（30秒）"
                    return 1
                fi
            else
                log_error "反代容器未运行（请先通过 infra-deploy Pipeline 部署 nginx）"
                return 1
            fi
        else
            log_info "反代容器运行中（r4s）"
        fi

        # 检查远程 noda-network
        remote_exec "docker network inspect $NETWORK_NAME >/dev/null 2>&1" || {
            log_error "r4s Docker 网络 $NETWORK_NAME 不存在"
            return 1
        }
        log_info "r4s Docker 网络 $NETWORK_NAME 存在"

        # 服务专属检查（r4s 模式）
        case "$service" in
            keycloak)
                if [ -z "${SERVICE_IMAGE:-}" ]; then
                    log_error "SERVICE_IMAGE 未设置（Keycloak 需要指定官方镜像）"
                    return 1
                fi
                log_info "Keycloak 镜像: $SERVICE_IMAGE"
                ;;
            nginx)
                # 无额外检查
                ;;
            noda-ops)
                # 无额外检查
                ;;
            postgres)
                # 检查 postgres 容器是否 running（远程）
                running=$(remote_exec "docker inspect -f '{{.State.Running}}' noda-infra-postgres-prod 2>/dev/null || echo false")
                if [ "$running" != "true" ]; then
                    log_error "noda-infra-postgres-prod 容器未运行（r4s）"
                    return 1
                fi
                log_info "noda-infra-postgres-prod 容器运行中（r4s）"
                ;;
            remark42)
                # 无额外检查
                ;;
            seaweedfs)
                # 无额外检查（S3 凭据由 Doppler 注入）
                ;;
            *-static)
                # 静态站发布：无容器部署，仅构建 + mc mirror
                ;;
            *)
                log_error "未知服务: $service"
                return 1
                ;;
        esac
    else
        # 本地模式：保持现有逻辑
        # 检查 Docker daemon
        docker info >/dev/null 2>&1 || {
            log_error "Docker daemon 不可用"
            return 1
        }
        log_info "Docker daemon 可用"

        # 检查反代容器（三容器拆分后为 noda-static-prod，legacy noda-infra-nginx 兜底）
        if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ] && [ "$(is_container_running "$NGINX_CONTAINER_LEGACY")" != "true" ]; then
            if [ "$service" = "nginx" ]; then
                log_info "反代容器未运行，正在通过 docker compose 启动..."
                docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d --no-deps nginx || {
                    log_error "docker compose 启动反代容器失败"
                    return 1
                }
                # 等待反代容器就绪
                local _wait=0
                while [ "$_wait" -lt 30 ]; do
                    if [ "$(is_container_running "$NGINX_CONTAINER")" = "true" ] || [ "$(is_container_running "$NGINX_CONTAINER_LEGACY")" = "true" ]; then
                        log_info "反代容器已启动（等待 ${_wait} 秒）"
                        break
                    fi
                    sleep 1
                    _wait=$((_wait + 1))
                done
                if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ] && [ "$(is_container_running "$NGINX_CONTAINER_LEGACY")" != "true" ]; then
                    log_error "反代容器启动超时（30秒）"
                    return 1
                fi
            else
                log_error "反代容器未运行（请先通过 infra-deploy Pipeline 部署 nginx）"
                return 1
            fi
        else
            log_info "反代容器运行中"
        fi

        # 检查 noda-network
        docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || {
            log_error "Docker 网络 noda-network 不存在"
            return 1
        }
        log_info "Docker 网络 noda-network 存在"

        # 服务专属检查
        case "$service" in
            keycloak)
                if [ -z "${SERVICE_IMAGE:-}" ]; then
                    log_error "SERVICE_IMAGE 未设置（Keycloak 需要指定官方镜像）"
                    return 1
                fi
                log_info "Keycloak 镜像: $SERVICE_IMAGE"
                ;;
            nginx)
                # 无额外检查
                ;;
            noda-ops)
                # 无额外检查
                ;;
            postgres)
                # 检查 postgres 容器是否 running
                if [ "$(is_container_running "noda-infra-postgres-prod")" != "true" ]; then
                    log_error "noda-infra-postgres-prod 容器未运行"
                    return 1
                fi
                log_info "noda-infra-postgres-prod 容器运行中"
                ;;
            remark42)
                # 无额外检查
                ;;
            seaweedfs)
                # 无额外检查（S3 凭据由 Doppler 注入）
                ;;
            *-static)
                # 静态站发布：无容器部署，仅构建 + mc mirror
                ;;
            *)
                log_error "未知服务: $service"
                return 1
                ;;
        esac
    fi

    log_success "前置检查全部通过"
}


# ============================================
# 函数: pipeline_backup_database
# ============================================
# 部署前自动备份
# 参数: $1 = SERVICE (keycloak/postgres)
# 环境变量: BACKUP_HOST_DIR
# 返回: 0=备份成功或跳过，1=备份失败
# 导出: INFRA_BACKUP_FILE（备份文件路径）
pipeline_backup_database()
{
    local service="$1"
    
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程模式：备份文件存储在 r4s 上
        local backup_dir="/opt/noda/noda-infra/docker/volumes/backup/infra-pipeline/${service}"
        local timestamp
        timestamp=$(date +"%Y%m%d-%H%M%S")
        local backup_file="${backup_dir}/${timestamp}.sql.gz"

        # nginx/noda-ops 不需要备份
        if [ "$service" != "keycloak" ] && [ "$service" != "postgres" ]; then
            log_info "$service 不需要备份（无持久化数据）"
            return 0
        fi

        # 在 r4s 上创建备份目录
        remote_exec "mkdir -p $backup_dir"

        log_info "部署前备份（r4s）: $service -> $backup_file"

        if [ "$service" = "keycloak" ]; then
            remote_docker_exec "noda-infra-postgres-prod" \
                "pg_dump -U postgres --clean --if-exists keycloak | gzip > ${backup_file}"
        elif [ "$service" = "postgres" ]; then
            remote_docker_exec "noda-infra-postgres-prod" \
                "pg_dumpall -U postgres --clean --if-exists | gzip > ${backup_file}"
        fi

        # 验证备份文件大小 > 1KB（在 r4s 上检查）
        local file_size
        file_size=$(remote_exec "stat -c%s ${backup_file} 2>/dev/null || echo 0")
        if [ "$file_size" -lt 1024 ]; then
            log_error "备份文件异常（${file_size} 字节），中止部署"
            return 1
        fi

        log_success "备份完成（r4s）: $backup_file (${file_size} bytes)"
        INFRA_BACKUP_FILE="$backup_file"
        export INFRA_BACKUP_FILE
    else
        # 本地模式：保持现有逻辑
        local backup_dir="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}/infra-pipeline/${service}"
        local timestamp
        timestamp=$(date +"%Y%m%d-%H%M%S")
        local backup_file="${backup_dir}/${timestamp}.sql.gz"

        # nginx/noda-ops 不需要备份
        if [ "$service" != "keycloak" ] && [ "$service" != "postgres" ]; then
            log_info "$service 不需要备份（无持久化数据）"
            return 0
        fi

        mkdir -p "$backup_dir"

        log_info "部署前备份: $service -> $backup_file"

        if [ "$service" = "keycloak" ]; then
            docker exec noda-infra-postgres-prod pg_dump -U postgres --clean --if-exists keycloak |
                gzip >"$backup_file"
        elif [ "$service" = "postgres" ]; then
            docker exec noda-infra-postgres-prod pg_dumpall -U postgres --clean --if-exists |
                gzip >"$backup_file"
        fi

        # 验证备份文件大小 > 1KB
        local file_size
        file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
        if [ "$file_size" -lt 1024 ]; then
            log_error "备份文件异常（${file_size} 字节），中止部署"
            return 1
        fi

        log_success "备份完成: $backup_file (${file_size} bytes)"
        INFRA_BACKUP_FILE="$backup_file"
        export INFRA_BACKUP_FILE
    fi
}


# ============================================
# 函数: pipeline_infra_deploy
# ============================================
# 部署分发（根据服务类型调用对应部署策略）
# 参数: $1 = SERVICE
# 返回: 由子函数决定
pipeline_infra_deploy()
{
    disk_snapshot "部署前"

    local service="$1"

    case "$service" in
        keycloak)
            pipeline_deploy_keycloak_prod
            ;;
        nginx)
            pipeline_deploy_nginx
            ;;
        noda-ops)
            pipeline_deploy_noda_ops
            ;;
        postgres)
            pipeline_deploy_postgres
            ;;
        remark42)
            pipeline_deploy_remark42
            ;;
        seaweedfs)
            pipeline_deploy_seaweedfs
            ;;
        class-static)
            pipeline_publish_class_static
            ;;
        www-static)
            # 188 对象量级；阈值 50
            pipeline_publish_static_site www www/web out/index.html 50
            ;;
        admin-static)
            # 77 对象量级；阈值 20
            pipeline_publish_static_site admin admin/web out/login.html 20
            ;;
        liuyao-static)
            # 71 个 HTML + 资产 ≈ 数百对象；阈值 200。
            # GA4 分站 property 构建期烤进 bundle（NEXT_PUBLIC_* 静态构建无运行时 env），
            # 值同 LAYER=web 镜像构建的 --build-arg；SITE_URL/AUTH_APP_URL 代码默认值即生产。
            export NEXT_PUBLIC_GA4_LIUYAO_ID=G-ZXK92PWTEF
            pipeline_publish_static_site liuyao liuyao/web out/en.html 200
            ;;
        nearby-static)
            # 9 个 HTML + 图片/字体资产 ≈ 200 对象量级；阈值 60。
            # GA4 分站 property 构建期烤进 bundle（值同 LAYER=web 的 --build-arg，
            # 且代码兜底即此值，此处显式 export 防漂移）；sitemap.xml 由 nearbyapi 出。
            export NEXT_PUBLIC_GA4_NEARBY_ID=G-58CDREDT81
            pipeline_publish_static_site nearby nearby/web out/en.html 60
            ;;
        comment-static)
            # S5：comment 前端 admin 占位页（阈值 20；API 由 Go commentapi 承接）。
            pipeline_publish_static_site comment comment out/admin.html 20
            ;;
        auth-static)
            # S5：auth 页面静态壳（~35 HTML + 资产；阈值 60）。
            # zh 无前缀 canonical（defaultLocale=zh）——哨兵文件用 out/zh/login.html；
            # API 端点不在静态产物（Go authapi :3004 承接）。
            pipeline_publish_static_site auth auth out/zh/login.html 60
            ;;
        *)
            log_error "未知服务: $service"
            return 1
            ;;
    esac
}

# ============================================
# 函数: pipeline_deploy_keycloak_prod
# ============================================
# [2026-09-12 已下线] Keycloak 已退役：Google OAuth 由 auth 应用直连
# （授权码 + PKCE），会话走 auth_sessions 表；DB 已归档后 drop。
# 本函数保留仅为防误部署守卫；如需恢复，git revert 下线提交。
pipeline_deploy_keycloak_prod()
{
    log_error "keycloak 已于 2026-09-12 下线，拒绝部署（OAuth 走 auth 应用直连）。"
    log_error "如确需恢复：git revert 下线提交 + 恢复 backup/2026/decommission/keycloak-final-20260912.dump。"
    return 1
}

pipeline_deploy_keycloak_prod_disabled()
{
    local container_name="noda-infra-keycloak"
    local image="${SERVICE_IMAGE:-quay.io/keycloak/keycloak:26.2.3}"

    log_info "Keycloak 直接替换部署: $container_name ($image)"

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式
        # 停止并移除旧容器（远程）
        local running
        running=$(remote_exec "docker inspect -f '{{.State.Running}}' $container_name 2>/dev/null || echo false")
        if [ "$running" = "true" ]; then
            log_info "停止旧容器（r4s）: $container_name"
            remote_exec "docker stop -t 30 $container_name || true"
            remote_exec "docker rm $container_name || true"
        elif remote_exec "docker inspect $container_name >/dev/null 2>&1"; then
            remote_exec "docker rm $container_name || true"
        fi

        # 准备 env 文件（本地生成，传输到 r4s）
        local tmp_env
        tmp_env=$(prepare_keycloak_env_file)
        log_info "传输 env 文件到 r4s..."
        cat "$tmp_env" | remote_exec "cat > /tmp/keycloak.env"

        # 拉取官方镜像（在 r4s 上，per D-07）
        log_info "拉取 Keycloak 镜像（r4s）: $image"
        remote_exec "docker pull $image"

        # 启动新容器（远程）
        # realm 持久化在 postgres（KC_DB），data 目录挂持久卷防 realm 丢失
        # ⚠️ 2026-09-02 教训：旧版 --tmpfs /opt/keycloak/data + 无 KC_DB，
        #    每次部署 realm 全丢
        log_info "启动容器（r4s）: $container_name ($image)"
        remote_exec "mkdir -p /opt/noda/noda-infra/docker/services/keycloak/data"
        # KC 镜像以 uid 1000(keycloak) 运行：root 属主的 data 目录会让主题资源聚合
        # 写不了 data/tmp，/resources/* 全部 500（登录页裸奔）
        remote_exec "chown -R 1000:0 /opt/noda/noda-infra/docker/services/keycloak/data"
        remote_exec "docker run -d \
            --name $container_name \
            --network $NETWORK_NAME \
            --network-alias $container_name \
            --restart always \
            --stop-timeout 30 \
            --security-opt no-new-privileges \
            --cap-drop ALL \
            -v /opt/noda/noda-infra/docker/services/keycloak/themes:/opt/keycloak/themes:ro \
            -v /opt/noda/noda-infra/docker/services/keycloak/data:/opt/keycloak/data \
            --memory 768m \
            --memory-reservation 512m \
            --cpus 1 \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --env-file /tmp/keycloak.env \
            --label com.docker.compose.project=noda-infra \
            --label com.docker.compose.service=keycloak \
            --label noda.service-group=infra \
            --label noda.environment=prod \
            --health-cmd \"echo > /dev/tcp/localhost/8080 2>/dev/null || exit 1\" \
            --health-interval 10s \
            --health-timeout 5s \
            --health-retries 10 \
            --health-start-period 900s \
            $image \
            start --hostname=auth.noda.co.nz --http-enabled=true"

        rm -f "$tmp_env"

        # reload nginx（远程）
        reload_nginx

        log_success "Keycloak 部署完成（r4s）: $container_name ($image)"
    else
        # 本地模式：保持现有逻辑
        # 停止并移除旧容器
        if [ "$(is_container_running "$container_name")" = "true" ]; then
            log_info "停止旧容器: $container_name"
            docker stop -t 30 "$container_name"
            docker rm "$container_name"
        elif docker inspect "$container_name" >/dev/null 2>&1; then
            docker rm "$container_name"
        fi

        # 准备 env 文件
        local tmp_env
        tmp_env=$(prepare_keycloak_env_file)

        # 启动新容器
        log_info "启动容器: $container_name ($image)"

        docker run -d \
            --name "$container_name" \
            --network "$NETWORK_NAME" \
            --network-alias "$container_name" \
            --restart always \
            --stop-timeout 30 \
            --security-opt no-new-privileges \
            --cap-drop ALL \
            -v "$PROJECT_ROOT/docker/services/keycloak/themes:/opt/keycloak/themes:ro" \
            -v "$PROJECT_ROOT/docker/services/keycloak/data:/opt/keycloak/data" \
            --memory 768m \
            --memory-reservation 512m \
            --cpus 1 \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --env-file "$tmp_env" \
            --label "com.docker.compose.project=noda-infra" \
            --label "com.docker.compose.service=keycloak" \
            --label "noda.service-group=infra" \
            --label noda.environment=prod \
            --health-cmd "echo > /dev/tcp/localhost/8080 2>/dev/null || exit 1" \
            --health-interval 10s \
            --health-timeout 5s \
            --health-retries 10 \
            --health-start-period 900s \
            "$image" \
            start --hostname=auth.noda.co.nz --http-enabled=true

        rm -f "$tmp_env"

        # reload nginx 刷新 DNS 缓存（容器重建后 IP 会变）
        reload_nginx

        log_success "Keycloak 部署完成: $container_name ($image)"
    fi
}


# ============================================
# 函数: prepare_keycloak_env_file
# ============================================
# 生成 Keycloak 环境变量文件
# 返回: 临时 env 文件路径（通过 echo 输出）
prepare_keycloak_env_file()
{
    local tmp_file="/tmp/keycloak-prod.env.$$"
    local env_template="$PROJECT_ROOT/docker/env-keycloak.env"

    if [ ! -f "$env_template" ]; then
        log_error "Keycloak env 模板文件不存在: $env_template"
        return 1
    fi

    local vars='${POSTGRES_USER} ${POSTGRES_PASSWORD} ${KEYCLOAK_ADMIN_USER} ${KEYCLOAK_ADMIN_PASSWORD} ${SMTP_HOST} ${SMTP_PORT} ${SMTP_FROM} ${SMTP_USER} ${SMTP_PASSWORD}'
    envsubst "$vars" <"$env_template" >"$tmp_file"
    echo "$tmp_file"
}

# ============================================
# 函数: pipeline_deploy_remark42
# ============================================
# [2026-09-12 已下线] Remark42 已退役：评论由 comment 应用接管
# （comments.noda.co.nz → noda-frontend-prod:3012，remark42 兼容 API 形状）。
# 本函数保留仅为防误部署守卫；如需恢复，git revert 下线提交。
pipeline_deploy_remark42()
{
    log_error "remark42 已于 2026-09 下线，拒绝部署（评论走 comment 应用 :3012）。"
    log_error "如确需恢复：git revert 下线提交后重跑；下线前的数据卷 remark42-data 已归档。"
    return 1
}

pipeline_deploy_remark42_disabled()
{
    local compose_file="docker/docker-compose.remark42.yml"

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        log_info "Remark42 部署（r4s 远程）"

        # 拉取最新镜像
        log_info "拉取 Remark42 镜像..."
        remote_exec "docker pull umputun/remark42:latest"

        # 停止旧容器
        remote_exec "docker rm -f remark42 2>/dev/null || true"

        # 从 Doppler 下载密钥到临时文件（避免在 SSH 命令中内联展开密钥）
        local secrets_file
        secrets_file=$(mktemp /tmp/remark42-secrets.XXXXXX.env)
        chmod 600 "$secrets_file"
        # 安全防护：doppler 下载时禁用 trace（避免密钥值打印到 Jenkins 日志）
        local _restore_trace=""
        if [[ $- == *x* ]]; then _restore_trace="set -x"; set +x; fi
        doppler secrets download --project noda --config prd --format env --no-file > "$secrets_file"
        $_restore_trace
        log_info "已从 Doppler 拉取 Remark42 密钥"

        # 传输密钥文件到 r4s
        log_info "传输密钥文件到 r4s..."
        cat "$secrets_file" | remote_exec "cat > /tmp/remark42-secrets.env"
        rm -f "$secrets_file"

        # 启动新容器（使用 --env-file 传递密钥，不在命令行中暴露密钥值）
        remote_exec "cd /opt/noda/noda-infra && docker compose --env-file /tmp/remark42-secrets.env --env-file docker/.env -f ${compose_file} up -d"

        # 等待健康检查
        log_info "等待 Remark42 就绪..."
        local _max_wait=30
        local _elapsed=0
        while [ $_elapsed -lt $_max_wait ]; do
            local _healthy
            _healthy=$(remote_exec "docker inspect --format='{{.State.Health.Status}}' remark42 2>/dev/null || echo unknown")
            if [ "$_healthy" = "healthy" ]; then
                log_info "Remark42 已就绪（等待 ${_elapsed} 秒）"
                break
            fi
            sleep 2
            _elapsed=$((_elapsed + 2))
        done
        if [ $_elapsed -ge $_max_wait ]; then
            log_warn "Remark42 健康检查超时，检查日志..."
            remote_exec "docker logs remark42 --tail 20 2>/dev/null || true"
        fi
        log_success "Remark42 部署完成（r4s）"
    else
        # 本地模式
        log_info "Remark42 部署（本地 docker compose）"

        docker compose --env-file docker/.env -f ${compose_file} up -d

        log_info "等待 Remark42 就绪..."
        local _max_wait=30
        local _elapsed=0
        while [ $_elapsed -lt $_max_wait ]; do
            local _healthy
            _healthy=$(docker inspect --format='{{.State.Health.Status}}' remark42 2>/dev/null || echo "unknown")
            if [ "$_healthy" = "healthy" ]; then
                log_info "Remark42 已就绪（等待 ${_elapsed} 秒）"
                break
            fi
            sleep 2
            _elapsed=$((_elapsed + 2))
        done
        if [ $_elapsed -ge $_max_wait ]; then
            log_warn "Remark42 健康检查超时"
            docker logs remark42 --tail 20 2>/dev/null || true
        fi
        log_success "Remark42 部署完成"
    fi
}

# 函数: pipeline_deploy_nginx
# ============================================
# Nginx docker compose recreate（秒级中断，非零停机）
# 返回: 0=成功，1=失败
pipeline_deploy_nginx()
{
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式
        log_info "Nginx 重建部署（r4s 远程 docker compose recreate）"

        # 从 Doppler 恢复 SSL 证书（确保 git reset --hard 后证书仍在）
        restore_ssl_certs || return 1

        # 先停止并移除旧容器，再创建新容器
        # 三容器拆分：容器名为 noda-static-prod（compose 服务键仍为 nginx）；legacy 名兜底清理
        log_info "停止旧反代容器（r4s）..."
        remote_exec "docker stop $NGINX_CONTAINER 2>/dev/null || true"
        remote_exec "docker rm $NGINX_CONTAINER 2>/dev/null || true"
        remote_exec "docker stop $NGINX_CONTAINER_LEGACY 2>/dev/null || true"
        remote_exec "docker rm $NGINX_CONTAINER_LEGACY 2>/dev/null || true"

        # compose 模板镜像引用已变量化（apps 只发 commit tag，r4s 无 latest）——
        # 取 r4s 上最新 noda-static 的 tag 经 env 传给 compose；无静态镜像时回退
        # 模板 latest fallback（报错信息里可见，比静默失败清晰）
        local static_tag
        static_tag=$(remote_exec "docker images noda-static --format '{{.Tag}}' | grep -v '<none>' | head -1" 2>/dev/null | tr -d '\r')
        local env_prefix=""
        if [ -n "$static_tag" ]; then
            env_prefix="NODA_STATIC_IMAGE=noda-static:${static_tag}"
            log_info "nginx 重建使用静态镜像: noda-static:${static_tag}"
        else
            log_warn "r4s 上无 noda-static 镜像，compose 回退 latest fallback"
        fi

        remote_compose "up -d --no-deps nginx" \
            "-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.r4s.yml" \
            "$env_prefix"

        # 等待反代容器启动
        log_info "等待反代容器就绪（r4s）..."
        local _max_wait=30
        local _elapsed=0
        while [ $_elapsed -lt $_max_wait ]; do
            local _running
            _running=$(remote_exec "docker inspect --format='{{.State.Running}}' $(_resolve_nginx_container_remote) 2>/dev/null || echo false")
            if [ "$_running" = "true" ]; then
                log_info "反代容器已就绪（等待 ${_elapsed} 秒）"
                break
            fi
            sleep 1
            _elapsed=$((_elapsed + 1))
        done
        if [ $_elapsed -ge $_max_wait ]; then
            log_error "反代容器未在 ${_max_wait} 秒内就绪（r4s）"
            remote_exec "docker logs $NGINX_CONTAINER --tail 20 2>/dev/null || true"
            return 1
        fi

        log_success "Nginx 重建完成（r4s）"
    else
        # 本地模式：保持现有逻辑
        log_info "Nginx 重建部署（docker compose recreate）"

        # 从 Doppler 恢复 SSL 证书（确保 git reset --hard 后证书仍在）
        restore_ssl_certs || return 1

        # 先停止并移除旧容器，再创建新容器
        # 不使用 --force-recreate：该选项在新容器创建时网络连接尚未就绪，
        # 导致 nginx 解析 upstream DNS 失败并进入 restart 循环
        # 三容器拆分：容器名为 noda-static-prod（compose 服务键仍为 nginx）；legacy 名兜底清理
        log_info "停止旧反代容器..."
        docker stop "$NGINX_CONTAINER" 2>/dev/null || true
        docker rm "$NGINX_CONTAINER" 2>/dev/null || true
        docker stop "$NGINX_CONTAINER_LEGACY" 2>/dev/null || true
        docker rm "$NGINX_CONTAINER_LEGACY" 2>/dev/null || true

        docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
            up -d --no-deps nginx

        # 等待反代容器启动
        log_info "等待反代容器就绪..."
        local _max_wait=30
        local _elapsed=0
        while [ $_elapsed -lt $_max_wait ]; do
            local _running
            _running=$(docker inspect --format='{{.State.Running}}' "$(_resolve_nginx_container)" 2>/dev/null || echo "false")
            if [ "$_running" = "true" ]; then
                log_info "反代容器已就绪（等待 ${_elapsed} 秒）"
                break
            fi
            sleep 1
            _elapsed=$((_elapsed + 1))
        done
        if [ $_elapsed -ge $_max_wait ]; then
            log_error "反代容器未在 ${_max_wait} 秒内就绪"
            docker logs "$NGINX_CONTAINER" --tail 20 2>/dev/null || true
            return 1
        fi

        log_success "Nginx 重建完成"
    fi
}


# ============================================
# 函数: pipeline_publish_class_static / pipeline_publish_static_site
# ============================================
# 静态站发布（S1 class 沉淀，S2 泛化；Jenkinsfile.infra SERVICE=<product>-static）
# 流程：本地构建（pnpm build → out/）→ alpine/socat 临时中继
#   （R4S registry mirror 受限拉不动 minio/mc，复用 prod 种子期同款中继）
#   → mc mirror 增量同步到 SeaweedFS 桶 noda-static/sites/<product>/ → 中继即拆
#   （S3 端口不常驻暴露 LAN）→ 桶内对象数验证
# 凭据：/etc/noda/jobs.env 的 S3_ACCESS_KEY/S3_SECRET_KEY——经 ssh 读入本地 shell
#   变量后传给 mc，不回显、不落盘、不进日志
# nginx 侧无需重启：桶内容更新即时生效（HTML no-cache，浏览器与 CF 均不缓存陈旧壳）
# 参数: $1=产品名（=桶前缀 sites/<product>/） $2=web 目录（相对 noda-apps 根）
#       $3=发布校验文件（相对 out/） $4=最少对象数阈值（防「整树漏传」类事故）
# 依赖：本机 mc（brew install minio/stable/mc）、NODA_APPS_DIR（默认 $PROJECT_ROOT/noda-apps）
pipeline_publish_class_static()
{
    # 39 个 html + 资产 ≈ 422 对象；阈值 30
    pipeline_publish_static_site class class/web out/en.html 30
}

pipeline_publish_static_site()
{
    local product="$1"
    local min_objs="${4:-20}"
    local apps_dir="${NODA_APPS_DIR:-$PROJECT_ROOT/noda-apps}"
    local web_dir="$apps_dir/$2"
    local relay_name="tmp-s3-relay"
    local relay_port="9333"
    local alias_name="noda-prd-relay"

    _publish_class_cleanup()
    {
        remote_exec "docker rm -f $relay_name >/dev/null 2>&1 || true" || true
        mc alias remove "$alias_name" >/dev/null 2>&1 || true
        mc alias remove "$alias_name-stg" >/dev/null 2>&1 || true
    }

    if ! command -v mc >/dev/null 2>&1; then
        log_error "本机未安装 minio client（brew install minio/stable/mc）"
        return 1
    fi

    # node/pnpm 就绪：Jenkins launchd 环境 PATH 不含 nvm——显式注入
    # （apps-deploy 同款 v24.12.0 优先，其次任意 nvm 版本；homebrew node 仅作兜底）
    local nvm_bin
    if [ -d "$HOME/.nvm/versions/node/v24.12.0/bin" ]; then
        nvm_bin="$HOME/.nvm/versions/node/v24.12.0/bin"
    else
        nvm_bin=$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort | tail -1)
    fi
    if [ -n "$nvm_bin" ] && [ -x "$nvm_bin/node" ]; then
        export PATH="$nvm_bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
    fi
    if ! command -v pnpm >/dev/null 2>&1; then
        # nvm node 未带 pnpm 时用 corepack 激活（packageManager 字段锁定版本）
        if command -v corepack >/dev/null 2>&1; then
            corepack enable pnpm >/dev/null 2>&1 || true
        fi
    fi
    if ! command -v pnpm >/dev/null 2>&1; then
        log_error "pnpm 不可用（nvm/corepack/homebrew 均未找到）"
        return 1
    fi

    # 依赖就绪：fresh checkout 无 node_modules（Jenkins infra-deploy workspace 不持久），
    # workspace 安装一次后随目录持久，frozen-lockfile 幂等且快
    if [ ! -d "$web_dir/node_modules" ]; then
        log_info "前端依赖缺失，pnpm install --frozen-lockfile ($apps_dir)..."
        (cd "$ctx_dir" && pnpm install --frozen-lockfile) || {
            log_error "pnpm install 失败: $apps_dir"
            return 1
        }
    fi

    log_info "构建 $product 静态站（pnpm build → out/）..."
    if ! (cd "$web_dir" && pnpm build); then
        log_error "$product 静态站构建失败: $web_dir"
        return 1
    fi
    if [ ! -f "$web_dir/$3" ]; then
        log_error "构建产物缺失 $web_dir/$3（output:export 校验失败）"
        return 1
    fi

    # 临时 S3 中继：192.168.100.1:9333 → seaweedfs:8333（noda-network 内）
    _publish_class_cleanup
    if ! remote_exec "docker rm -f $relay_name >/dev/null 2>&1 || true; docker run -d --name $relay_name --network $NETWORK_NAME -p 192.168.100.1:${relay_port}:8333 alpine/socat tcp-listen:8333,fork,reuseaddr tcp:seaweedfs:8333"; then
        log_error "S3 中继启动失败"
        _publish_class_cleanup
        return 1
    fi

    local s3a s3s
    # jobs.env 的契约是 docker --env-file（cron 容器消费），不是 shell 文件：
    # NEARBY_COUNCIL_WHERE 等值含空格/括号，source 会语法报错（ash: unexpected "("）
    # 或把空格后内容当命令——按行 grep 抽取，对值内容零假设
    s3a=$(remote_exec "grep -E '^S3_ACCESS_KEY=' /etc/noda/jobs.env | head -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r"')
    s3s=$(remote_exec "grep -E '^S3_SECRET_KEY=' /etc/noda/jobs.env | head -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r"')
    if [ -z "$s3a" ] || [ -z "$s3s" ]; then
        log_error "S3 凭据读取失败（/etc/noda/jobs.env）"
        _publish_class_cleanup
        return 1
    fi

    # stg 桶（noda-static-stg，本机 seaweedfs-stg）凭据与 prod 不同源：
    # 优先环境变量，其次挂载配置文件（gitignored，ensure_stg_s3_json 保证在位）
    local stg_a="" stg_s=""
    if [ -n "${STG_S3_ACCESS_KEY:-}" ] && [ -n "${STG_S3_SECRET_KEY:-}" ]; then
        stg_a="$STG_S3_ACCESS_KEY"; stg_s="$STG_S3_SECRET_KEY"
    else
        local stg_json="$PROJECT_ROOT/config/seaweedfs/s3.json"
        [ -f "$stg_json" ] || stg_json="$HOME/Project/noda-infra/config/seaweedfs/s3.json"
        if [ -f "$stg_json" ]; then
            stg_a=$(python3 -c "import json;d=json.load(open('$stg_json'));print(d['identities'][0]['credentials'][0]['accessKey'])" 2>/dev/null)
            stg_s=$(python3 -c "import json;d=json.load(open('$stg_json'));print(d['identities'][0]['credentials'][0]['secretKey'])" 2>/dev/null)
        fi
    fi

    if ! mc alias set "$alias_name" "http://192.168.100.1:${relay_port}" "$s3a" "$s3s" --api S3v4; then
        log_error "mc alias 设置失败"
        _publish_class_cleanup
        return 1
    fi

    log_info "mc mirror 增量同步（含删除） out/ → noda-static/sites/$product/ ..."
    # --remove：桶内该前缀收敛为当前 out/（旧构建 hash 资产/已删页面对象随之清理）；
    # 作用域仅 sites/<product>/ 前缀，图片（avatars/ 等）与其它前缀不受影响
    if ! mc mirror --overwrite --remove --quiet "$web_dir/out/" "$alias_name/noda-static/sites/$product/"; then
        log_error "静态站同步失败"
        _publish_class_cleanup
        return 1
    fi

    # preprod 桶同构收敛（2026-09-13）：preprod 五站页面由本机 seaweedfs-stg 的
    # noda-static-stg/sites/<product>/ 伺服——同一次发布一并 mirror --remove，
    # prod/stg 双桶同步且各自收敛旧对象（用户要求：清理对 preprod+prod 都生效）。
    # stg S3 只绑 127.0.0.1:8333（Jenkins 同机可直连）；不可达/凭据缺失仅告警不阻塞
    if [ -n "$stg_a" ] && [ -n "$stg_s" ] && mc alias set "$alias_name-stg" "http://127.0.0.1:8333" "$stg_a" "$stg_s" --api S3v4 >/dev/null 2>&1; then
        # 桶自愈（2026-09-13 实证：seaweedfs-stg 崩溃重建后桶元数据丢失，
        # preprod 全站 404）——mc mb 幂等确保桶在位，任何环境桶丢失随发布自动重建
        mc mb --ignore-existing "$alias_name-stg/noda-static-stg" >/dev/null 2>&1 || true
        log_info "mc mirror 增量同步（含删除） out/ → noda-static-stg/sites/$product/ ..."
        if ! mc mirror --overwrite --remove --quiet "$web_dir/out/" "$alias_name-stg/noda-static-stg/sites/$product/"; then
            log_warn "preprod 桶（noda-static-stg）同步失败——preprod 静态内容可能滞后（不影响 prod）"
        fi
    else
        log_warn "stg S3（127.0.0.1:8333）不可达或凭据缺失，跳过 preprod 桶同步"
    fi

    # 对象级对账（2026-09-13 build 72 实证：mc mirror 曾静默漏传 zh/topic/love.html
    # ——同目录部分对象上传部分跳过且零报错，min_objs 阈值无法发现，verify 探测兜住）。
    # 源 out/ 文件数必须与桶前缀对象数完全一致，否则判发布不完整并失败。
    local objs src_objs
    src_objs=$(find "$web_dir/out" -type f 2>/dev/null | wc -l | tr -d ' ')
    objs=$(mc ls --recursive "$alias_name/noda-static/sites/$product/" 2>/dev/null | grep -c . || true)
    _publish_class_cleanup
    if [ "${objs:-0}" -lt "$min_objs" ]; then
        log_error "桶内对象数异常（${objs} < ${min_objs}），发布疑似不完整"
        return 1
    fi
    if [ "${objs:-0}" -ne "${src_objs:-0}" ]; then
        log_error "镜像对账失败：源 out/ $src_objs 个文件 ≠ 桶 $objs 个对象——mc mirror 静默漏传，发布不完整"
        return 1
    fi

    log_success "$product 静态站发布完成：noda-static/sites/$product/（$objs 个对象，与源一致，中继已拆除）"
}

# ============================================
# 函数: pipeline_deploy_seaweedfs
# ============================================
# ensure_stg_s3_json - stg 挂载配置自愈（2026-09-13）
# ============================================
# config/seaweedfs/s3.json 被 gitignore（凭据不入库），但 docker-compose.preprod-local.yml
# 的 seaweedfs 服务 bind-mount 它——Jenkins workspace 每次构建被 CleanBeforeCheckout
# 清空后，Docker 会在 bind 源自动建**空目录**，seaweedfs-stg 的 S3 组件启动即 fatal，
# 无限重启（2026-09-13 实证：/etc/seaweedfs/s3.json is a directory，重启一上午）。
# 自愈：workspace 缺文件（或是目录）时，从本机持久检出恢复；两边都没有仅告警
# （只有 seaweedfs 容器 recreate 时才真正需要，不阻塞 apps 发布）。
ensure_stg_s3_json()
{
    local target="$PROJECT_ROOT/config/seaweedfs/s3.json"
    local fallback="${STG_S3JSON_FALLBACK:-$HOME/Project/noda-infra/config/seaweedfs/s3.json}"

    if [ -f "$target" ]; then
        return 0
    fi

    if [ -d "$target" ]; then
        # Docker 把 bind 源自动建成目录了——先移除才能放真文件
        rmdir "$target" 2>/dev/null || { log_warn "无法移除目录化的 $target"; return 0; }
    fi

    if [ -f "$fallback" ]; then
        mkdir -p "$(dirname "$target")"
        cp "$fallback" "$target" && chmod 600 "$target"
        log_info "已从持久检出恢复 s3.json 到 $target (防 CleanBeforeCheckout 清除致 stg 崩溃）"
    else
        log_warn "s3.json 缺失且无持久检出兜底 ($fallback) --seaweedfs-stg 下次 recreate 将崩溃，请部署 SERVICE=seaweedfs 渲染"
    fi
    return 0
}

# pipeline_deploy_seaweedfs - SeaweedFS 对象存储部署（Phase 1, 2026-09-12）
# ① Doppler 注入 S3_ACCESS_KEY/S3_SECRET_KEY/S3_BUCKET → 渲染 s3.json（600，不落 git）
# ② compose up（r4s 远程 / 本地 preprod-local）+ 健康等待
# ③ mc 初始化桶 + 匿名只读（幂等，--network 内一次性 mc 容器）
# 返回: 0=成功，1=失败
pipeline_deploy_seaweedfs()
{
    if [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ] || [ -z "${S3_BUCKET:-}" ]; then
        log_error "S3_ACCESS_KEY/S3_SECRET_KEY/S3_BUCKET 未注入（应经 doppler run 提供，DOPPLER_CONFIG 必须与环境匹配）"
        return 1
    fi

    # ① 渲染 s3.json（600 权限临时文件）
    local s3json
    s3json=$(mktemp /tmp/seaweedfs-s3.XXXXXX.json)
    chmod 600 "$s3json"
    sed -e "s|__S3_ACCESS_KEY__|${S3_ACCESS_KEY}|g" \
        -e "s|__S3_SECRET_KEY__|${S3_SECRET_KEY}|g" \
        -e "s|__S3_BUCKET__|${S3_BUCKET}|g" \
        config/seaweedfs/s3.template.json > "$s3json"

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        log_info "SeaweedFS 部署（r4s 远程）"
        # 数据盘数据目录
        remote_exec "mkdir -p /mnt/mmc1-4/noda/seaweedfs"
        # s3.json → 远端仓库配置路径（gitignored；经 stdin 传输，密钥不进 Jenkins 日志）
        remote_exec "mkdir -p /opt/noda/noda-infra/config/seaweedfs"
        cat "$s3json" | remote_exec "cat > /opt/noda/noda-infra/config/seaweedfs/s3.json && chmod 600 /opt/noda/noda-infra/config/seaweedfs/s3.json" || { rm -f "$s3json"; return 1; }

        remote_compose "up -d --no-deps seaweedfs" \
            "-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.r4s.yml"

        log_info "等待 SeaweedFS 健康（r4s）..."
        local _elapsed=0 _health
        while [ "$_elapsed" -lt 60 ]; do
            _health=$(remote_exec "docker inspect --format='{{.State.Health.Status}}' seaweedfs 2>/dev/null || echo unknown")
            [ "$_health" = "healthy" ] && break
            sleep 2
            _elapsed=$((_elapsed + 2))
        done
        if [ "$_elapsed" -ge 60 ]; then
            log_error "SeaweedFS 未在 60s 内健康（r4s）"
            remote_exec "docker logs seaweedfs --tail 20 2>/dev/null || true"
            rm -f "$s3json"
            return 1
        fi
        log_info "SeaweedFS 健康（等待 ${_elapsed} 秒）"
    else
        log_info "SeaweedFS 部署（本地 preprod-local）"
        # 自愈优先（workspace 文件可能被 CleanBeforeCheckout 清成目录），
        # 随后 Doppler 渲染版覆盖写入挂载路径
        ensure_stg_s3_json
        cp "$s3json" config/seaweedfs/s3.json
        docker compose -f docker/docker-compose.preprod-local.yml up -d --no-deps seaweedfs
        local _elapsed=0 _health
        while [ "$_elapsed" -lt 60 ]; do
            _health=$(docker inspect --format='{{.State.Health.Status}}' seaweedfs-stg 2>/dev/null || echo unknown)
            [ "$_health" = "healthy" ] && break
            sleep 2
            _elapsed=$((_elapsed + 2))
        done
        if [ "$_elapsed" -ge 60 ]; then
            log_error "SeaweedFS 未在 60s 内健康（本地）"
            docker logs seaweedfs-stg --tail 20 2>/dev/null || true
            rm -f "$s3json"
            return 1
        fi
        log_info "SeaweedFS 健康（等待 ${_elapsed} 秒）"
    fi
    rm -f "$s3json"

    # ③ mc 初始化桶 + 匿名只读（幂等）
    log_info "初始化 S3 桶 ${S3_BUCKET}（mb --ignore-existing + anonymous download）..."
    local mc_sh="mc mb --ignore-existing seaweedfs/${S3_BUCKET} && mc anonymous set download seaweedfs/${S3_BUCKET}"
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        remote_exec "docker image inspect minio/mc:latest >/dev/null 2>&1 || docker pull minio/mc:latest" 60
        remote_exec "docker run --rm --network noda-network -e MC_HOST_seaweed=\"http://${S3_ACCESS_KEY}:${S3_SECRET_KEY}@seaweedfs:8333\" minio/mc:latest sh -c 'mc ready seaweedfs && ${mc_sh}'" 120
    else
        local net
        net=$(docker inspect seaweedfs-stg --format '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}}{{end}}')
        docker pull minio/mc:latest >/dev/null 2>&1 || true
        docker run --rm --network "$net" -e MC_HOST_seaweed="http://${S3_ACCESS_KEY}:${S3_SECRET_KEY}@seaweedfs:8333" minio/mc:latest sh -c "mc ready seaweedfs && ${mc_sh}"
    fi

    log_success "SeaweedFS 部署完成（桶 ${S3_BUCKET} 匿名只读已配置）"
}


# ============================================
# 函数: pipeline_deploy_noda_ops
# ============================================
# noda-ops docker compose recreate（使用 build 模式）
# noda-ops 功能：数据库备份 + Cloudflare Tunnel + Doppler 密钥备份
# （python 爬虫链路已退役，抓取由 noda-api 内置 cron 接管）
# 返回: 0=成功，1=失败
pipeline_deploy_noda_ops()
{
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式
        log_info "noda-ops 重建部署（r4s 远程）"

        # 在 Mac 上构建 noda-ops 镜像（保持现有逻辑）
        log_info "构建 noda-ops 镜像（Mac 本地）..."
        # --no-cache：脚本文件变更必须进镜像（历史爬虫时代即如此，保守保留）
        docker build --no-cache -t noda-ops:latest -f deploy/Dockerfile.noda-ops .

        # 传输镜像到 r4s（先传再删旧容器，避免传失败导致服务中断）
        log_info "传输 noda-ops 镜像到 r4s..."
        if ! transfer_image "noda-ops:latest" "noda-ops:latest"; then
            log_error "noda-ops 镜像传输失败，旧容器保留"
            return 1
        fi

        # 从 Doppler Cloud 拉取密钥（在 Mac 上，per D-22）
        # 使用 --no-file > file 获取明文格式（直接写入文件是加密格式）
        local secrets_file
        secrets_file=$(mktemp /tmp/noda-ops-secrets.XXXXXX.env)
        doppler secrets download --project noda --config prd --format env --no-file > "$secrets_file"
        log_info "已从 Doppler 拉取密钥: $(grep -c '=' "$secrets_file") 个变量"

        # 传输密钥文件到 r4s
        log_info "传输密钥文件到 r4s..."
        cat "$secrets_file" | remote_exec "cat > /tmp/noda-ops-secrets.env"
        rm -f "$secrets_file"

        # 清理可能存在的旧容器（手动创建或僵尸容器）
        log_info "清理旧 noda-ops 容器..."
        remote_exec "docker rm -f noda-ops 2>/dev/null || true"

        # 在 r4s 上启动容器
        if ! remote_exec "cd /opt/noda/noda-infra && docker compose --env-file /tmp/noda-ops-secrets.env \
            -f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.r4s.yml \
            up -d --force-recreate --no-deps noda-ops"; then
            log_error "noda-ops 容器启动失败"
            return 1
        fi

        log_success "noda-ops 重建完成（r4s）"
    else
        # 本地模式：保持现有逻辑
        log_info "noda-ops 重建部署（docker compose recreate）"

        # 从 Doppler Cloud 拉取密钥（B2、PostgreSQL、Cloudflare 等）
        # 使用 --no-file > file 获取明文格式（直接写入文件是加密格式）
        local secrets_file
        secrets_file=$(mktemp /tmp/noda-ops-secrets.XXXXXX.env)
        doppler secrets download --project noda --config prd --format env --no-file > "$secrets_file"
        log_info "已从 Doppler 拉取密钥: $(grep -c '=' "$secrets_file") 个变量"

        # noda-ops 使用 build 模式，需要 --build
        docker compose --env-file "$secrets_file" \
            -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
            up -d --build --force-recreate --no-deps noda-ops

        rm -f "$secrets_file"
        log_success "noda-ops 重建完成"
    fi
}


# ============================================
# 函数: pipeline_deploy_postgres
# ============================================
# Postgres compose restart（需要备份+人工确认已完成）
# 无需保存镜像（不更换镜像）
# 返回: 0=成功，1=失败
pipeline_deploy_postgres()
{
    # up -d --force-recreate 而非 restart：healthcheck 配置变更（interval/retries/start_period）
    # 只有重建容器才生效，restart 会沿用旧容器已固化的检查配置
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式
        log_info "PostgreSQL 重建部署（r4s 远程 docker compose up -d --force-recreate）"

        remote_compose "up -d --force-recreate postgres" \
            "-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.r4s.yml"

        log_success "PostgreSQL 重建完成（r4s）"
    else
        # 本地模式：保持现有逻辑
        log_info "PostgreSQL 重建部署（docker compose up -d --force-recreate）"

        docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
            up -d --force-recreate postgres

        log_success "PostgreSQL 重建完成"
    fi
}


# ============================================
# 函数: pipeline_infra_health_check
# ============================================
# 服务专属健康检查
# 参数: $1 = SERVICE
# 返回: 0=健康，1=不健康
pipeline_infra_health_check()
{
    local service="$1"

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程健康检查模式
        case "$service" in
            keycloak)
                # 900s：Keycloak 在 r4s（ARM）上冷启动实测 ~6-10 分钟；且配置变更（如
                # JAVA_OPTS_APPEND）会触发 Quarkus 重新增强（实测 +175s）。docker 的
                # --health-start-period 已同步设为 900s，宽限期内探测失败不计数，
                # 两者必须保持一致，否则 boot 中途被标记 unhealthy 会误判部署失败
                #（构建 #41 教训：60s 宽限 + 300s 门槛 → 启动到 ~160s 被误杀）。
                wait_container_healthy "noda-infra-keycloak" 900 true true
                ;;
            nginx)
                # nginx -t 验证配置 + wait_container_healthy（远程；容器名动态解析）
                remote_docker_exec "$(_resolve_nginx_container_remote)" "nginx -t"
                wait_container_healthy "$(_resolve_nginx_container_remote)" 30 true true
                ;;
            noda-ops)
                # 容器健康检查（备份 + Cloudflare Tunnel）
                wait_container_healthy "noda-ops" 60 true true
                ;;
            postgres)
                # pg_isready 验证数据库可连接 + wait_container_healthy（远程）
                remote_docker_exec "noda-infra-postgres-prod" "pg_isready -h localhost -p 5432"
                wait_container_healthy "noda-infra-postgres-prod" 90 true true
                ;;
            remark42)
                wait_container_healthy "remark42" 60 true true
                ;;
            seaweedfs)
                # healthcheck 探测 master API（9333/cluster/status，容器内）
                wait_container_healthy "seaweedfs" 60 true true
                ;;
            class-static)
                # 静态壳发布无容器可查：以「nginx class 块可从桶拉到首页」为健康
                # ⚠️ 必须带 Host: localhost——127.0.0.1 的 Host 不匹配任何 server_name，
                # 会落进字母序最前的 cdn 默认块（cdn.conf）造成假 404
                remote_docker_exec "$(_resolve_nginx_container_remote)" "wget --quiet --tries=1 --header 'Host: localhost' --spider http://127.0.0.1:81/en"
                ;;
            www-static)
                # www 块桶托管健康：首页可从桶拉取（Host 定位 www 块，同上 Host 教训）
                remote_docker_exec "$(_resolve_nginx_container_remote)" "wget --quiet --tries=1 --header 'Host: noda.co.nz' --spider http://127.0.0.1:81/"
                ;;
            admin-static)
                # admin 块桶托管健康：/dashboard 页可拉取（根路径 / 已 302 到此）
                remote_docker_exec "$(_resolve_nginx_container_remote)" "wget --quiet --tries=1 --header 'Host: admin.noda.co.nz' --spider http://127.0.0.1:81/dashboard"
                ;;
            liuyao-static)
                # liuyao 块桶托管健康：/divine（无前缀 en）经内部改写从桶拉取 +
                # 带前缀 zh 路径直取（Host 定位 liuyao 块，同上 Host 教训）
                # ⚠️ 每条探针独立 remote_docker_exec：&& 链会被 r4s 宿主 shell 拆开，
                # 第二条 wget 落到宿主机执行（81 未绑定 → exit 4 假失败，build 62/63 实证）
                remote_docker_exec "$(_resolve_nginx_container_remote)" "wget --quiet --tries=1 --header 'Host: liuyao.noda.co.nz' --spider http://127.0.0.1:81/divine"
                remote_docker_exec "$(_resolve_nginx_container_remote)" "wget --quiet --tries=1 --header 'Host: liuyao.noda.co.nz' --spider http://127.0.0.1:81/zh/divine"
                ;;
            nearby-static)
                # nearby 块桶托管健康：/（无前缀 en）经内部改写从桶拉取 +
                # sitemap.xml 反代 nearbyapi（Host 定位 nearby 块，同上 Host 教训；
                # 探针独立调用，理由同 liuyao-static）
                remote_docker_exec "$(_resolve_nginx_container_remote)" "wget --quiet --tries=1 --header 'Host: nearby.noda.co.nz' --spider http://127.0.0.1:81/"
                remote_docker_exec "$(_resolve_nginx_container_remote)" "wget --quiet --tries=1 --header 'Host: nearby.noda.co.nz' --spider http://127.0.0.1:81/sitemap.xml"
                ;;
            auth-static)
                # S5：auth 块桶托管健康：/login（zh 无前缀，内部改写从桶拉取）
                remote_docker_exec "$(_resolve_nginx_container_remote)" "wget --quiet --tries=1 --header 'Host: auth.noda.co.nz' --spider http://127.0.0.1:81/login"
                ;;
            comment-static)
                # S5：comment 块桶托管健康：/ →302 /admin（占位页从桶拉取）
                remote_docker_exec "$(_resolve_nginx_container_remote)" "wget --quiet --tries=1 --header 'Host: comments.noda.co.nz' --spider http://127.0.0.1:81/admin"
                ;;
            *)
                log_error "未知服务: $service"
                return 1
                ;;
        esac
    else
        # 本地模式：保持现有逻辑
        case "$service" in
            keycloak)
                wait_container_healthy "noda-infra-keycloak" 300
                ;;
            nginx)
                # nginx -t 验证配置 + wait_container_healthy（容器名动态解析）
                docker exec "$(_resolve_nginx_container)" nginx -t
                wait_container_healthy "$(_resolve_nginx_container)" 30
                ;;
            noda-ops)
                # 容器健康检查（备份 + Cloudflare Tunnel）
                wait_container_healthy "noda-ops" 60
                ;;
            postgres)
                # pg_isready 验证数据库可连接 + wait_container_healthy
                docker exec noda-infra-postgres-prod pg_isready -h localhost -p 5432
                wait_container_healthy "noda-infra-postgres-prod" 90
                ;;
            remark42)
                wait_container_healthy "remark42" 60
                ;;
            seaweedfs)
                wait_container_healthy "seaweedfs-stg" 60
                ;;
            *-static)
                # 静态站发布即桶同步，无容器可查
                log_info "静态站本地模式无容器健康检查，跳过"
                ;;
            *)
                log_error "未知服务: $service"
                return 1
                ;;
        esac
    fi
}


# ============================================
# 函数: pipeline_infra_verify
# ============================================
# 部署后验证
# 参数: $1 = SERVICE
# 返回: 0=验证通过，1=验证失败
pipeline_infra_verify()
{
    local service="$1"

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        case "$service" in
            keycloak)
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --spider http://noda-infra-keycloak:8080/ 2>/dev/null"
                log_success "Keycloak E2E 验证通过（r4s）"
                ;;
            nginx)
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --spider http://127.0.0.1:81/ 2>/dev/null"
                log_success "Nginx E2E 验证通过（r4s）"
                ;;
            noda-ops)
                local running
                running=$(remote_exec "docker ps --filter name=noda-ops --filter status=running --format '{{.Names}}'")
                if [ -z "$running" ]; then
                    log_error "noda-ops 容器未运行（r4s）"
                    return 1
                fi
                log_success "noda-ops 验证通过（r4s）: 容器运行中（备份 + Cloudflare Tunnel）"
                ;;
            postgres)
                remote_exec "docker exec noda-infra-postgres-prod pg_isready -h localhost -p 5432"
                log_success "PostgreSQL 验证通过（r4s）"
                ;;
            remark42)
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --spider http://remark42:8080/ping 2>/dev/null"
                log_success "Remark42 E2E 验证通过（r4s）"
                ;;
            seaweedfs)
                # E2E：同网络内对桶根发 GET（匿名只读 → 200 ListBucket）
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --spider http://seaweedfs:8333/noda-static/"
                log_success "SeaweedFS E2E 验证通过（r4s）"
                ;;
            class-static)
                # E2E：首页 /en 静态壳 + 动态段 app-shell 兜底 + /api 直达 Go API
                # （Host: localhost 定位 class 块，见 health_check 同款注释）
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: localhost' --spider http://127.0.0.1:81/en"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: localhost' --spider http://127.0.0.1:81/en/course/app-shell.html"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: localhost' --spider http://127.0.0.1:81/api/health"
                log_success "Class 静态壳 E2E 验证通过（r4s）"
                ;;
            www-static)
                # E2E：首页 + 中文页 + API 直连（Host 定位 www 块）
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: noda.co.nz' --spider http://127.0.0.1:81/"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: noda.co.nz' --spider http://127.0.0.1:81/zh/"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: noda.co.nz' --spider http://127.0.0.1:81/api/courses"
                log_success "www 静态站 E2E 验证通过（r4s）"
                ;;
            admin-static)
                # E2E：登录页 + 动态路由壳文件 + cronjobs 深链兜底（=200 壳）+ Go API 健康
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: admin.noda.co.nz' --spider http://127.0.0.1:81/login"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: admin.noda.co.nz' --spider http://127.0.0.1:81/cronjobs/app-shell.html"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: admin.noda.co.nz' --spider http://127.0.0.1:81/cronjobs/noda-api/backup-db"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: admin.noda.co.nz' --spider http://127.0.0.1:81/api/admin/health"
                log_success "Admin 静态壳 E2E 验证通过（r4s）"
                ;;
            liuyao-static)
                # E2E：无前缀 en 首页（内部改写）+ zh 前缀页 + 静态 sitemap/robots +
                # 分享深链壳兜底（=200）+ .txt 净 404（--server-response 断言 404）+ API 直连
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: liuyao.noda.co.nz' --spider http://127.0.0.1:81/divine"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: liuyao.noda.co.nz' --spider http://127.0.0.1:81/zh/topic/love"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: liuyao.noda.co.nz' --spider http://127.0.0.1:81/sitemap.xml"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: liuyao.noda.co.nz' --spider http://127.0.0.1:81/en/s/app-shell.html"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: liuyao.noda.co.nz' --spider http://127.0.0.1:81/en/s/deadbeef-0000-0000-0000-000000000000"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --server-response --spider --header 'Host: liuyao.noda.co.nz' http://127.0.0.1:81/en/s/deadbeef-0000-0000-0000-000000000000.txt 2>&1 | grep -q 'HTTP/1.1 404'"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: liuyao.noda.co.nz' --spider http://127.0.0.1:81/api/health"
                log_success "Liuyao 静态壳 E2E 验证通过（r4s）"
                ;;
            nearby-static)
                # E2E：无前缀 en 首页（内部改写）+ zh 前缀页 + sitemap 反代 Go + item
                # 深链壳兜底（=200）+ .txt 净 404 + API 直连
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: nearby.noda.co.nz' --spider http://127.0.0.1:81/"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: nearby.noda.co.nz' --spider http://127.0.0.1:81/zh"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: nearby.noda.co.nz' --spider http://127.0.0.1:81/sitemap.xml"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: nearby.noda.co.nz' --spider http://127.0.0.1:81/en/item/app-shell.html"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: nearby.noda.co.nz' --spider http://127.0.0.1:81/en/item/deadbeef-0000-0000-0000-000000000000"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --server-response --spider --header 'Host: nearby.noda.co.nz' http://127.0.0.1:81/en/item/deadbeef-0000-0000-0000-000000000000.txt 2>&1 | grep -q 'HTTP/1.1 404'"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: nearby.noda.co.nz' --spider 'http://127.0.0.1:81/api/nearby/feed?city=auckland&limit=1'"
                log_success "Nearby 静态壳 E2E 验证通过（r4s）"
                ;;
            auth-static)
                # E2E：login/register 静态壳（桶）+ Go authapi 健康
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: auth.noda.co.nz' --spider http://127.0.0.1:81/login"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: auth.noda.co.nz' --spider http://127.0.0.1:81/register"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: auth.noda.co.nz' --spider http://127.0.0.1:81/api/health"
                log_success "Auth 静态壳 E2E 验证通过（r4s）"
                ;;
            comment-static)
                # E2E：admin 占位页（桶）+ Go commentapi 健康
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: comments.noda.co.nz' --spider http://127.0.0.1:81/admin"
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --header 'Host: comments.noda.co.nz' --spider http://127.0.0.1:81/api/health"
                log_success "Comment 静态壳 E2E 验证通过（r4s）"
                ;;
            *)
                log_error "未知服务: $service"
                return 1
                ;;
        esac
    else
        case "$service" in
            keycloak)
                docker exec "$NGINX_CONTAINER" wget --quiet --tries=1 --spider http://noda-infra-keycloak:8080/ 2>/dev/null
                log_success "Keycloak E2E 验证通过"
                ;;
            nginx)
                docker exec "$NGINX_CONTAINER" wget --quiet --tries=1 --spider http://127.0.0.1:81/ 2>/dev/null
                log_success "Nginx E2E 验证通过"
                ;;
            noda-ops)
                local running
                running=$(docker ps --filter name=noda-ops --filter status=running --format '{{.Names}}')
                if [ -z "$running" ]; then
                    log_error "noda-ops 容器未运行"
                    return 1
                fi
                log_success "noda-ops 验证通过: 容器运行中（备份 + Cloudflare Tunnel）"
                ;;
            postgres)
                docker exec noda-infra-postgres-prod pg_isready -h localhost -p 5432
                log_success "PostgreSQL 验证通过"
                ;;
            remark42)
                docker exec "$NGINX_CONTAINER" wget --quiet --tries=1 --spider http://remark42:8080/ping 2>/dev/null
                log_success "Remark42 E2E 验证通过"
                ;;
            seaweedfs)
                docker exec "$NGINX_CONTAINER" wget --quiet --tries=1 --spider http://seaweedfs:8333/noda-static-stg/
                log_success "SeaweedFS E2E 验证通过"
                ;;
            *-static)
                log_info "静态站本地模式无 E2E 容器验证，跳过"
                ;;
            *)
                log_error "未知服务: $service"
                return 1
                ;;
        esac
    fi
}

# ============================================
# 函数: pipeline_infra_cleanup
# ============================================
# 部署后清理（备份文件保留）
# 参数: $1 = SERVICE
# 返回: 0=成功
pipeline_infra_cleanup()
{
    local service="$1"

    # 创建备份目录索引（用于审计）
    ls -la "${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}/infra-pipeline/${service}/" 2>/dev/null || true

    case "$service" in
        keycloak)
            cleanup_dangling
            ;;
        nginx)
            log_info "$service 无需额外清理（dangling 清理由通用 wrapper 处理）"
            ;;
        noda-ops)
            cleanup_by_date_threshold "noda-ops"
            ;;
        postgres)
            log_info "PostgreSQL 无需额外清理"
            ;;
        remark42)
            cleanup_dangling
            ;;
        *)
            log_info "未知服务: ${service}，跳过清理"
            ;;
    esac

    # === 基础设施部署后全面清理（per D-03）===
    cleanup_after_infra_deploy "$service" "${WORKSPACE:-$PWD}"
}

# ============================================
# 函数: pipeline_infra_failure_cleanup
# ============================================
# 部署失败清理（捕获日志）
# 参数: $1 = SERVICE
# 返回: 0=清理完成
pipeline_infra_failure_cleanup()
{
    local service="$1"

    # 捕获目标服务容器日志
    local container_name
    case "$service" in
        keycloak)
            container_name="noda-infra-keycloak"
            ;;
        nginx)
            container_name="$(_resolve_nginx_container)"
            ;;
        noda-ops)
            container_name="noda-ops"
            ;;
        postgres)
            container_name="noda-infra-postgres-prod"
            ;;
        remark42)
            container_name="remark42"
            ;;
        *)
            container_name="$service"
            ;;
    esac

    docker logs "$container_name" --tail 50 >deploy-failure-infra.log 2>&1 || true
    docker logs "$NGINX_CONTAINER" --tail 50 >deploy-failure-nginx.log 2>&1 || true

    log_info "失败日志已保存"
}

# ============================================
# Pre-prod Pipeline 函数
# ============================================
# 用于 Jenkinsfile.apps 统一 Pipeline 的 pre-prod 阶段
# 三容器拆分（2026-09）→ S5 双容器（2026-09-12 frontend 退役）：
#   preprod-noda-api（Go 七 listener）/ preprod-noda-static（nginx，Mac 本地顶替 preprod-nginx）
# 旧单容器名 noda-apps-preprod 保留为 legacy 清理引用
# 数据库: noda_preprod（独立）
# Keycloak: preprod 独立实例（同 realm）
# ============================================

PREPROD_API_CONTAINER="preprod-noda-api"
PREPROD_FRONTEND_CONTAINER="preprod-noda-frontend"
PREPROD_STATIC_CONTAINER="preprod-noda-static"
PREPROD_CONTAINER="preprod-noda-apps"  # legacy 单容器（清理用）

# _preprod_infra_running - 本地 preprod 基础设施容器（postgres/seaweedfs/static）是否齐全且运行中
# preprod-nginx 已删除——static 容器顶替其反代角色；preprod-keycloak 已随 S5 退役
_preprod_infra_running()
{
    local cname
    for cname in preprod-postgres seaweedfs-stg preprod-noda-static; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null)" != "true" ]; then
            return 1
        fi
    done
    return 0
}

# _preprod_cleanup_legacy - 清理 legacy 单容器时代的 preprod 容器（容器名冲突防护）
# 参数: $1 = mode(remote|local)
_preprod_cleanup_legacy()
{
    local mode="$1"
    local cname
    for cname in "$PREPROD_CONTAINER" preprod-nginx "$PREPROD_API_CONTAINER" "$PREPROD_FRONTEND_CONTAINER" "$PREPROD_STATIC_CONTAINER"; do
        if [ "$mode" = "remote" ]; then
            remote_exec "docker rm -f $cname >/dev/null 2>&1 || true"
        else
            docker rm -f "$cname" >/dev/null 2>&1 || true
        fi
    done
}

# pipeline_deploy_preprod - 部署三容器到 pre-prod 环境
# 参数: $1 = GIT_SHA
pipeline_deploy_preprod()
{
    local git_sha="$1"
    local api_image="noda-api:${git_sha}"
    local static_image="noda-static:${git_sha}"

    disk_snapshot "Pre-prod 部署前"

    log_info "部署 Pre-prod 环境（S5 双容器: api + static）..."

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式
        # ⚠️ 先传三镜像再动旧容器（如果传失败，旧容器保留服务不断）
        log_info "r4s 远程部署模式：传输三镜像到 r4s..."
        local img
        for img in "$api_image" "$static_image"; do
            if ! transfer_image "$img" "$img"; then
                log_error "Pre-prod 镜像传输失败: ${img}，旧容器保留"
                return 1
            fi
        done

        # 清理旧 preprod 容器（远程；含 legacy 单容器与 preprod-nginx）
        _preprod_cleanup_legacy remote

        # 准备 preprod 专用 env 文件（api，本地生成，传输到 r4s）
        local tmp_api_env
        tmp_api_env=$(prepare_preprod_api_env_file) || return 1
        log_info "传输 env 文件到 r4s..."
        cat "$tmp_api_env" | remote_exec "cat > /tmp/preprod-api.env && chmod 600 /tmp/preprod-api.env"
        rm -f "$tmp_api_env"

        # 启动 preprod 双容器（远程）：api → static
        log_info "启动 preprod 容器（r4s）: $PREPROD_STATIC_CONTAINER ($static_image)"
        remote_exec "docker run -d \
            --name $PREPROD_STATIC_CONTAINER \
            --network $NETWORK_NAME \
            --network-alias $PREPROD_STATIC_CONTAINER \
            --restart unless-stopped \
            --stop-timeout 30 \
            --security-opt no-new-privileges \
            --cap-drop ALL \
            --cap-add NET_BIND_SERVICE \
            --cap-add CHOWN \
            --cap-add SETGID \
            --cap-add SETUID \
            --read-only \
            --tmpfs /var/cache/nginx \
            --tmpfs /var/run \
            --tmpfs /tmp \
            --memory 128m \
            --memory-reservation 32m \
            --cpus 0.25 \
            --log-driver json-file \
            --log-opt max-size=10m \
            --log-opt max-file=3 \
            --label com.docker.compose.project=preprod \
            --label com.docker.compose.service=preprod-noda-static \
            --label noda.service-group=apps \
            --label noda.environment=preprod \
            --health-cmd \"wget --quiet --tries=1 --spider http://127.0.0.1:80/health || exit 1\" \
            --health-interval 30s \
            --health-timeout 5s \
            --health-retries 3 \
            --health-start-period 10s \
            $static_image"

        # 更新 preprod upstream 配置（远程）
        local upstream_content
        upstream_content=$(_preprod_upstream_content)

        log_info "更新 preprod upstream 配置（r4s）..."
        echo "$upstream_content" | remote_exec "mkdir -p /opt/noda/noda-infra/config/nginx/snippets && cat > /opt/noda/noda-infra/config/nginx/snippets/upstream-preprod.conf"

        # reload nginx（远程）
        reload_nginx

        # 发布后统一清理：Mac+r4s 镜像保留、registry retention+GC（失败不回滚部署）
        pipeline_post_publish_cleanup

        log_success "Pre-prod 部署完成（r4s）: $PREPROD_API_CONTAINER + $PREPROD_STATIC_CONTAINER"
    else
        # 本地模式（Mac）：用 docker-compose.preprod-local.yml
        # 包含 postgres + keycloak + 应用三容器（static 顶替原 preprod-nginx），独立于 prod 基础设施
        local compose_file="$PROJECT_ROOT/docker/docker-compose.preprod-local.yml"

        # 自愈：CleanBeforeCheckout 会清掉 gitignored 的 s3.json（seaweedfs-stg
        # bind-mount 源）——缺失则从持久检出恢复，防容器下次 recreate 崩溃
        ensure_stg_s3_json

        log_info "部署本地 preprod (docker compose): $api_image / $static_image"

        # 密钥源头隔离（环境隔离规则）：顶层 load_secrets 加载 prd（live key），
        # preprod 禁用任何 prod key——此处从 Doppler prd_pre 覆盖 STRIPE_/ANTHROPIC_ 前缀。
        # 子 shell 内覆盖，不污染父进程（prod 阶段 envsubst 仍取 prd 导出值）。
        # ANTHROPIC 当前 prd_pre 与 prd 同值（共用违规待开发 key 建好后替换 prd_pre 值）
        # COMMENT_SERVICE_KEY：评论服务间凭据按环境隔离（2026-09 auth/comment 迁移）
        local _preprod_key_override
        local _preprod_doppler_args=""
        # prd_pre 用专用 token（Jenkins 主 token 只授权 prd，读 prd_pre 返回空导出）
        if [ -n "${DOPPLER_TOKEN_PREPROD:-}" ]; then
            _preprod_doppler_args="--token ${DOPPLER_TOKEN_PREPROD}"
        fi
        _preprod_key_override=$(doppler secrets download ${_preprod_doppler_args} --project noda --config prd_pre --no-file --format=env 2>/dev/null | grep -E '^(STRIPE_|ANTHROPIC_|COMMENT_SERVICE_KEY|GOOGLE_OAUTH_|TOKEN_SECRET|AUTH_STATE_SECRET|EMAIL_SERVICE_API_KEY|EVENTFINDA_)' || true)
        if [ -z "$_preprod_key_override" ]; then
            log_warn "prd_pre 密钥导出为空，preprod 将无 Stripe/Anthropic 凭据"
        fi

        if _preprod_infra_running; then
            # 快路径：postgres/keycloak 保持运行，只重建应用三容器。
            # 省掉整栈 down/up（keycloak 冷启动 30s+ + postgres healthcheck）。
            # static 用 resolver 127.0.0.11 动态解析容器名，容器重建换 IP 自动生效。
            # 先清理 legacy 单容器与 preprod-nginx（80/443 被其占用会导致
            # preprod-noda-static 绑定失败；旧单容器也不再被新 upstream 引用）。
            log_info "清理 legacy preprod 容器（preprod-noda-apps / preprod-nginx）..."
            _preprod_cleanup_legacy local
            log_info "基础设施容器运行中，按 LAYER 重建应用容器..."
            (
                if [ -n "$_preprod_key_override" ]; then
                    eval "export ${_preprod_key_override//$'\n'/ }"
                fi
                local svc_list=""
                local img_envs=""
                if _layer_want_api; then
                    svc_list="$svc_list preprod-noda-api"
                    img_envs="$img_envs NORA_API_IMAGE=$api_image"
                fi
                if _layer_want_web; then
                    svc_list="$svc_list preprod-noda-static"
                    img_envs="$img_envs NORA_STATIC_IMAGE=$static_image"
                fi
                # 只重建本层服务：未触达层不动（镜像标签不存在时 compose 会尝试拉取而失败）
                eval "COMPOSE_PROJECT_NAME=preprod $img_envs docker compose -f $compose_file up -d --no-deps --force-recreate $svc_list"
                # 兼顾 api 重建的依赖级联历史行为：兜底确保 static 在位（幂等）。
                # LAYER=api 时本次未构建 static 镜像——用本地最新 noda-static commit tag
                # （2026-09-13 起构建不打 latest，不传 env 会踩模板 fallback 失败）
                if ! _layer_want_web; then
                    local latest_static_tag
                    latest_static_tag=$(docker images noda-static --format '{{.Tag}}' | grep -v '<none>' | head -1)
                    if [ -n "$latest_static_tag" ]; then
                        img_envs="$img_envs NORA_STATIC_IMAGE=noda-static:${latest_static_tag}"
                    fi
                fi
                eval "COMPOSE_PROJECT_NAME=preprod $img_envs docker compose -f $compose_file up -d --no-deps preprod-noda-static"
            )
        else
            # 兜底路径：基础设施容器缺失（首次部署/被手动清理），整栈拉起
            log_info "基础设施容器缺失，整栈启动本地 preprod..."
            # 先停止并清理旧的 preprod 容器（避免容器名冲突）
            # 注意：旧容器可能由不同 project name 创建，compose down 无法清理
            # 因此先按固定容器名 docker rm -f，再 compose down 清理孤儿
            # （含 legacy 单容器 preprod-noda-apps 与已删除的 preprod-nginx）
            log_info "清理旧的 preprod 容器..."
            for cname in preprod-postgres preprod-keycloak; do
                docker rm -f "$cname" 2>/dev/null || true
            done
            _preprod_cleanup_legacy local
            COMPOSE_PROJECT_NAME=preprod \
            docker compose -f "$compose_file" down --remove-orphans 2>/dev/null || true

            (
                if [ -n "$_preprod_key_override" ]; then
                    eval "export ${_preprod_key_override//$'\n'/ }"
                fi
                local img_envs=""
                if _layer_want_api; then img_envs="$img_envs NORA_API_IMAGE=$api_image"; fi
                if _layer_want_web; then img_envs="$img_envs NORA_STATIC_IMAGE=$static_image"; fi
                eval "COMPOSE_PROJECT_NAME=preprod $img_envs docker compose -f $compose_file up -d --force-recreate"
            )

            # 确保 keycloak 数据库存在（init SQL 可能无法 CREATE DATABASE）
            docker exec preprod-postgres psql -U postgres -c "CREATE DATABASE keycloak" 2>/dev/null || true

            # 等待容器就绪
            log_info "等待容器启动..."
            sleep 10
        fi

        # 发布后统一清理（本地模式：Mac 镜像保留 + registry；失败不回滚部署）
        pipeline_post_publish_cleanup

        log_success "Pre-prod 部署完成（本地 Mac）: $api_image / $static_image"
        log_info "  liuyao:    https://liuyao-preprod.noda.co.nz/"
        log_info "  class:     https://class-preprod.noda.co.nz/"
    fi
}

# _preprod_upstream_content - 生成 preprod upstream snippet 内容
# ⚠️ $preprod_{class,liuyao,auth_app,admin,comments}_upstream 五个应用变量为 legacy 保留：
# prod nginx default.conf 的 *-preprod 块仍引用（缺定义会致 nginx 启动失败），
# 但 S5 起 preprod 页面由桶伺服，这些变量在活跃路径上已无消费（r4s-preprod 模式休眠）。
_preprod_upstream_content()
{
    cat <<UPEOF
# noda 三容器 preprod upstream 变量 — 在 pre-prod server block 中 include
# 使用 resolver 127.0.0.11 动态解析 DNS，容器重建后自动刷新 IP
# 由 pipeline_deploy_preprod() / update_preprod_upstream() 更新
# 三容器拆分（2026-09）：preprod-noda-frontend（Next.js）/ preprod-noda-api（Go API）
set \$preprod_class_upstream ${PREPROD_FRONTEND_CONTAINER}:3000;
set \$preprod_liuyao_upstream ${PREPROD_FRONTEND_CONTAINER}:3005;
set \$preprod_auth_app_upstream ${PREPROD_FRONTEND_CONTAINER}:3004;
set \$preprod_admin_upstream ${PREPROD_FRONTEND_CONTAINER}:3006;
set \$preprod_comments_upstream ${PREPROD_FRONTEND_CONTAINER}:3012;
set \$preprod_class_api_upstream ${PREPROD_API_CONTAINER}:3001;
set \$preprod_liuyao_api_upstream ${PREPROD_API_CONTAINER}:3007;
set \$preprod_admin_api_upstream ${PREPROD_API_CONTAINER}:3011;
UPEOF
}

# prepare_preprod_api_env_file - 生成 preprod api env 文件（env-noda-api-preprod.env）
# 返回: 临时 env 文件路径（通过 echo 输出）
prepare_preprod_api_env_file()
{
    local tmp_file="/tmp/noda-api-preprod.env.$$"
    _prepare_env_file \
        "$PROJECT_ROOT/docker/env-noda-api-preprod.env" \
        "$tmp_file" \
        '${POSTGRES_USER} ${POSTGRES_PASSWORD} ${RESEND_API_KEY} ${ANTHROPIC_AUTH_TOKEN} ${ANTHROPIC_BASE_URL} ${ANTHROPIC_API_KEY} ${ANTHROPIC_MAX_TOKENS} ${TOKEN_SECRET} ${EMAIL_SERVICE_API_KEY} ${STRIPE_SECRET_KEY} ${STRIPE_WEBHOOK_SECRET} ${STRIPE_PRICE_DEEP_READ} ${LIUYAO_WEB_BASE_URL} ${EVENTFINDA_API_HOST} ${EVENTFINDA_API_USERNAME} ${EVENTFINDA_API_PASSWORD}' \
        || return 1
    echo "$tmp_file"
}

# update_preprod_upstream - 更新 preprod nginx upstream 配置（本地宿主机 snippets）
update_preprod_upstream()
{
    local upstream_content
    upstream_content=$(_preprod_upstream_content)

    local snippets_dir
    snippets_dir=$(get_host_snippets_dir)
    local host_conf="$snippets_dir/upstream-preprod.conf"

    local tmp_file="${host_conf}.tmp.$$"
    echo "$upstream_content" >"$tmp_file"
    mv "$tmp_file" "$host_conf"

    log_info "preprod upstream 已更新: $host_conf"
}

# pipeline_health_check_preprod - preprod 三容器健康检查
pipeline_health_check_preprod()
{
    log_info "Pre-prod 健康检查..."

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程健康检查模式：依次等待三容器 healthy
        log_info "Pre-prod 健康检查（r4s 远程）..."
        local health_timeout="$((HEALTH_CHECK_MAX_RETRIES * HEALTH_CHECK_INTERVAL))"
        wait_container_healthy "$PREPROD_API_CONTAINER" "$health_timeout" true true || return 1
        wait_container_healthy "$PREPROD_STATIC_CONTAINER" "$health_timeout" true true || return 1
        log_success "Pre-prod 健康检查通过（r4s 双容器）"
        return 0
    else
        # 本地模式（Mac）：容器无宿主端口映射，经 static 反代依次探测三条链路：
        #   1. liuyao /api/health  — static → api 链（preprod-noda-api:3007）
        #   2. class  /api/health  — static → api 链（preprod-noda-api:3001）
        #   3. class  /            — static → 桶静态站链（S5：页面 = SeaweedFS stg 桶伺服）
        log_info "Pre-prod 健康检查（本地 Mac, via static 反代）..."
        local retries="${HEALTH_CHECK_MAX_RETRIES:-30}"
        local interval="${HEALTH_CHECK_INTERVAL:-4}"
        local url label url_ok="false"
        # class / 是 302 跳转（静态站 nginx locale 语义，与 prod 同构）——探 /en 取 200
        for check in \
            "https://liuyao-preprod.noda.co.nz/api/health|liuyao static→api 链" \
            "https://class-preprod.noda.co.nz/api/health|class static→api 链" \
            "https://class-preprod.noda.co.nz/en|class static→桶静态站链"; do
            url="${check%%|*}"
            label="${check##*|}"
            url_ok="false"
            local i code
            for i in $(seq 1 "$retries"); do
                code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
                if [ "$code" = "200" ]; then
                    log_success "Pre-prod $label → 200 ($url)"
                    url_ok="true"
                    break
                fi
                log_info "等待 preprod 就绪（${label}）... (${i}/${retries}, HTTP ${code})"
                sleep "$interval"
            done
            if [ "$url_ok" != "true" ]; then
                log_error "Pre-prod 健康检查超时 ($label: $url)"
                return 1
            fi
        done
        log_success "Pre-prod 健康检查全部通过（本地 Mac 三链路）"
        return 0
    fi
}

# ============================================
# 函数: pipeline_release_lock
# ============================================
# 释放部署锁（供 Jenkins post 块调用）
# 返回: 0=释放成功
pipeline_release_lock()
{
    # 无条件释放：preprod 本地部署（DEPLOY_TARGET=local）同样在 preflight 获取了
    # r4s 部署锁——按 TARGET 过滤曾导致 normal 模式每次发版泄漏锁，
    # 后续构建无限等待（2026-09-13 build 335 实证）
    release_deploy_lock
    log_info "部署锁已释放"
}

# ============================================
# Source guard — 仅允许 source 加载，禁止直接执行
# ============================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "pipeline-stages.sh 是函数库，不支持直接执行"
    echo "请通过 Jenkinsfile 调用"
    exit 1
fi
