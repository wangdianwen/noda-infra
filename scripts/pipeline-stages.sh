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

        # 并行化（2026-09-13）：preflight 不再全程持有单把锁——锁下沉到各
        # 部署函数（deploy_preprod 持 apps-preprod、deploy_prod 持 apps-prod），
        # 构建 A 在 preprod 验证时构建 B 可直接走 prod。本函数只做仓库同步与检查
        # （r4s 仓库 sync 的目标是同一 ref，并行构建重复执行幂等无害）。
        # 在 r4s 上同步最新代码（per D-08/D-10）
        log_info "同步 r4s 仓库..."
        # 使用 fetch + reset --hard origin 替代 git pull，确保即使远程历史被重写（force push）
        # 也能正确同步；用 -e 排除运行时数据目录（history/crawler-logs 等），保护生产数据
        # ⚠️ fetch 显式 refspec（+branch:refs/remotes/origin/branch）为防御性写法：
        # git ≥1.8.4 裸 `fetch origin main` 会机会式更新跟踪引用（infra #10 实测
        # 同步正常），但显式 refspec 不依赖该行为、容忍强推且意图明确
        remote_exec "cd /opt/noda/noda-infra && git fetch origin +${R4S_GIT_BRANCH}:refs/remotes/origin/${R4S_GIT_BRANCH} && git reset --hard origin/${R4S_GIT_BRANCH} && git clean -fd -e docker/volumes/" || {
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

    # noda-apps 源码检出检查
    if [ ! -d "$apps_dir" ]; then
        log_error "noda-apps 目录不存在: $apps_dir"
        log_error "请检查 Jenkinsfile Pre-flight stage 的 checkout 配置"
        return 1
    fi
    log_info "noda-apps 目录存在: $apps_dir"

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

    # snagme 守卫已移除（2026-09-13）：dashboard 改静态导出后 LAYER=static/all 全支持
    # 同服务互斥已上移到 Jenkinsfile 首阶段 Queue Gate（pipeline_queue_gate）——
    # 后触发构建在进入 Pre-flight 前排队等待，不再占用实际构建资源

    log_success "前置检查全部通过"
}

# pipeline_build - 构建镜像（S5 双镜像：noda-api / noda-static）
# 参数: $1 = APPS_DIR (noda-apps 目录), $2 = GIT_SHA
# Dockerfile：noda-apps/infra/docker/Dockerfile.{noda-api,noda-static}
# 反代镜像（noda-static）的独立构建入口见 pipeline_build_nginx_image（noda-infra SERVICE=nginx）
# ============================================
# LAYER 过滤（2026-09-13 noda-apps 双轨重构）
#   api    = 后端：noda-api 镜像构建/容器部署（Go 多模块单镜像，全产品共享容器）
#   static = 前端：产品静态站桶发布（pipeline_publish_product，无镜像无容器）
#   all    = 一起：api + noda-static 反代镜像顺带刷新 + 产品静态站
# 兼容：旧值 web（仅反代镜像）保留为内部别名——反代是公共 nginx 镜像，
# 常规发布归 noda-infra SERVICE=nginx，apps 侧仅随 all 顺带刷新
# Go 侧靠 Dockerfile GOCACHE 缓存挂载增量编译（改一个产品只重编该产品包）
# ============================================
_layer_want_api()    { [ "$LAYER_FILTER" = "all" ] || [ "$LAYER_FILTER" = "api" ]; }
_layer_want_web()    { [ "$LAYER_FILTER" = "all" ] || [ "$LAYER_FILTER" = "web" ]; }
_layer_want_static() { [ "$LAYER_FILTER" = "all" ] || [ "$LAYER_FILTER" = "static" ]; }

# _next_public_build_args - NEXT_PUBLIC_* build-args（逐行输出；noda-static 镜像构建共用）
# 照抄旧单容器清单；static 仅 www 消费其中 GA4_WWW_ID/Keycloak 等，多余变量无副作用
_next_public_build_args()
{
    cat <<'ARGS'
--build-arg
NEXT_PUBLIC_KEYCLOAK_URL=https://auth.noda.co.nz
--build-arg
NEXT_PUBLIC_KEYCLOAK_REALM=noda
--build-arg
NEXT_PUBLIC_KEYCLOAK_CLIENT_ID=noda-frontend
--build-arg
NEXT_PUBLIC_AUTH_APP_URL=https://auth.noda.co.nz
--build-arg
NEXT_PUBLIC_AUTH_BYPASS=false
--build-arg
NEXT_PUBLIC_AUTH_KEYCLOAK_CLIENT_ID=noda-auth
--build-arg
NEXT_PUBLIC_ALLOWED_ORIGINS=https://class.noda.co.nz,https://noda.co.nz
--build-arg
NEXT_PUBLIC_SITE_URL=https://class.noda.co.nz
--build-arg
NEXT_PUBLIC_REMARK_URL=https://comments.noda.co.nz
--build-arg
NEXT_PUBLIC_GA4_WWW_ID=G-FPEF7LXD2F
--build-arg
NEXT_PUBLIC_GA4_LIUYAO_ID=G-ZXK92PWTEF
--build-arg
NEXT_PUBLIC_GA4_NEARBY_ID=G-58CDREDT81
--build-arg
NEXT_PUBLIC_NEARBY_SITE_URL=https://nearby.noda.co.nz
ARGS
}

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

    # NEXT_PUBLIC_* build-args（见 _next_public_build_args）
    # POSIX 安全：Jenkins sh 在 macOS 是 POSIX 模式 bash，不支持进程替换 <(...)
    local next_public_args=()
    local _pa _pa_file
    _pa_file=$(mktemp /tmp/noda-buildargs.XXXXXX)
    _next_public_build_args >"$_pa_file"
    while IFS= read -r _pa; do next_public_args+=("$_pa"); done <"$_pa_file"
    rm -f "$_pa_file"

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
# 函数: pipeline_build_nginx_image
# ============================================
# 构建并传输 noda-static 反代镜像（noda-infra SERVICE=nginx 专用）
# 反代是公共 nginx 镜像，源码在 noda-apps 仓（Dockerfile.noda-static：nginx + www 静态导出）。
# 构建上下文 = HEAD 提交树的干净导出（git archive，防 WIP 泄入镜像，同 pipeline_build）；
# 构建后经 registry 增量传输到 r4s，pipeline_deploy_nginx 取 r4s 最新 tag 重建容器
# 参数: $1 = APPS_DIR（noda-apps 检出目录）  $2 = GIT_SHA（noda-apps HEAD 短 SHA）
pipeline_build_nginx_image()
{
    local apps_dir="$1"
    local git_sha="$2"

    local ctx_dir
    ctx_dir=$(mktemp /tmp/noda-nginx-ctx.XXXXXX)
    rm -rf "$ctx_dir" && mkdir -p "$ctx_dir"
    git -C "$apps_dir" archive HEAD | tar -x -C "$ctx_dir" || {
        log_error "git archive 导出构建上下文失败"
        rm -rf "$ctx_dir"
        return 1
    }
    trap 'rm -rf "$ctx_dir"' RETURN

    docker buildx inspect desktop-linux >/dev/null 2>&1 || {
        log_error "默认 builder desktop-linux 不存在"
        return 1
    }

    # 与 noda-apps Pipeline 共用同一 local cache（层缓存跨构建持久，nginx 发布增量快）
    local cache_dir="${HOME}/.cache/noda-buildcache"
    mkdir -p "$cache_dir"

    # POSIX 安全：Jenkins sh 在 macOS 是 POSIX 模式 bash，不支持进程替换 <(...)
    local next_public_args=()
    local _pa _pa_file
    _pa_file=$(mktemp /tmp/noda-buildargs.XXXXXX)
    _next_public_build_args >"$_pa_file"
    while IFS= read -r _pa; do next_public_args+=("$_pa"); done <"$_pa_file"
    rm -f "$_pa_file"

    log_info "构建 noda-static 反代镜像: noda-static:${git_sha} ..."
    if ! docker buildx build --load \
        --cache-from type=local,src="$cache_dir" \
        --cache-to type=local,dest="$cache_dir",mode=max \
        -t "noda-static:${git_sha}" \
        -f "$ctx_dir/infra/docker/Dockerfile.noda-static" \
        "${next_public_args[@]}" \
        "$ctx_dir"; then
        log_error "noda-static 镜像构建失败"
        return 1
    fi
    log_success "镜像构建完成: noda-static:${git_sha}"

    # 增量传输到 r4s；落地确认后才允许 pipeline_deploy_nginx 动旧容器
    if ! transfer_image "noda-static:${git_sha}" "noda-static:${git_sha}"; then
        log_error "镜像传输失败: noda-static:${git_sha}"
        return 1
    fi
    if ! remote_exec "docker image inspect noda-static:${git_sha} >/dev/null 2>&1"; then
        log_error "镜像 noda-static:${git_sha} 未在 r4s 落地，中止（旧容器未受影响）"
        return 1
    fi

    docker_image_retention noda-static
}

# ============================================
# pipeline_post_publish_cleanup - 发布后统一清理（2026-09-13）
# ============================================
# 用户要求：每次 Jenkins 发布后自动清理旧资源，preprod 与 prod 均生效：
#   ① docker 旧镜像——Mac 构建机 + r4s（docker_image_retention：每仓库保留
#      最新 2 版 = 当前 + 回滚锚点；同 ID 多 tag 折叠）
#   ② registry 旧镜像——localhost:5001 retention（keep 2）+ blob GC 回收磁盘
#      （cleanup 独立 job 已删除，现随每次发布收敛，不再有周度堆积窗口
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

# _node_pkg_for_product - PRODUCT → pnpm workspace 包名映射（Node 侧 lint/test 过滤用）
# 逐个核实自 noda-apps 各 package.json 的 name 字段（2026-09-13）：
#   class   → @noda-apps/web        (class/web)
#   www     → @noda-apps/www        (www/web)
#   admin   → @noda-apps/admin      (admin/web)
#   liuyao  → @noda-apps/liuyao-web (liuyao/web；注意不是 @noda-apps/liuyao)
#   nearby  → @noda-apps/nearby-web (nearby/web；包内无 test 脚本，turbo 静默跳过)
#   auth    → @noda-apps/auth-app   (auth；-app 后缀区分共享包 @noda-apps/auth=packages/auth)
#   comment → @noda-apps/comment    (comment；包内无 lint 脚本，同上)
#   snagme  → （空）snagme/{dashboard,scanner,engine,database} 均无 lint/test 脚本，
#             无 Node lint/test 可跑——调用方明确跳过并 log
# 未映射值 / PRODUCT_FILTER 未设置 → 返回空，调用方回退全仓跑（行为同旧版，防静默漏测）
_node_pkg_for_product()
{
    case "$1" in
        class)   echo "@noda-apps/web" ;;
        www)     echo "@noda-apps/www" ;;
        admin)   echo "@noda-apps/admin" ;;
        liuyao)  echo "@noda-apps/liuyao-web" ;;
        nearby)  echo "@noda-apps/nearby-web" ;;
        auth)    echo "@noda-apps/auth-app" ;;
        comment) echo "@noda-apps/comment" ;;
        *)       echo "" ;;
    esac
}

# pipeline_test - 安装依赖 + Go 模块测试 + Node lint/test（均按 LAYER/PRODUCT 过滤）
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
    # LAYER=static/web（纯前端）跳过；PRODUCT 必选单产品，只测对应产品模块 + common。
    case "${LAYER_FILTER:-all}" in
        static|web) ;;
        *)
        local modules="api common common/crawler common/jobs nearby/api class/api liuyao/api admin/api auth/api comment/api snagme/api"
        case "${PRODUCT_FILTER:-all}" in
            class)            modules="class/api common" ;;
            liuyao)           modules="liuyao/api common" ;;
            nearby)           modules="nearby/api common" ;;
            admin)            modules="admin/api common" ;;
            auth)             modules="auth/api common" ;;
            comment)          modules="comment/api common" ;;
            snagme)           modules="snagme/api common" ;;
            www)              modules="" ;;
        esac
        local m
        for m in $modules; do
            log_info "Go 测试: $m"
            ( cd "$apps_dir/$m" && go build ./... && go test ./... ) || return 1
        done
        log_success "Go 测试全部通过"
        ;;
    esac

    # Node 侧 lint/test（2026-09-13 补过滤：此前由 Jenkinsfile 两个独立 sh 步骤全仓
    # pnpm lint / pnpm test，static 发布也要等全仓 1-2 分钟）。不按 LAYER 跳过——
    # static 发布的挡板就是 Node lint/test。
    # 用 turbo --filter '<pkg>...'（三点 = 该包 + 其 workspace 依赖，与 root 脚本同
    # 工具链且有任务缓存）；turbo 对无对应 task 的包静默跳过（nearby 无 test、
    # auth/comment 无 lint，实测 exit 0 + WARNING），依赖包先 ^build 再 test。
    local node_pkg
    node_pkg=$(_node_pkg_for_product "${PRODUCT_FILTER:-}")
    (
        cd "$apps_dir"
        if [ -z "$node_pkg" ]; then
            if [ "${PRODUCT_FILTER:-}" = "snagme" ]; then
                log_info "Node lint/test: snagme/* 包均无 lint/test 脚本，跳过"
            else
                log_warn "Node lint/test: PRODUCT(${PRODUCT_FILTER:-未设置}) 无包映射，回退全仓 pnpm lint + pnpm test"
                pnpm lint
                pnpm test
            fi
        else
            log_info "Node lint/test: turbo 过滤到 $node_pkg 及其 workspace 依赖"
            pnpm exec turbo run lint --filter="$node_pkg..."
            pnpm exec turbo run test --filter="$node_pkg..."
            # test:i18n 为根级跨产品脚本（i18n parity 校验，秒级），无法按产品切分，保留全跑；
            # typecheck 原随全仓 pnpm test 尾部执行，此处收窄到同一产品切片，保持挡板强度
            pnpm test:i18n
            pnpm exec turbo run typecheck --filter="$node_pkg..."
        fi
        log_success "Node lint/test 完成（PRODUCT=${PRODUCT_FILTER:-未设置}）"
    ) || return 1
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

# _tag_rollback_anchors - 切换前给当前 prod 容器在用镜像打 rollback 锚点（2026-09-13）
# 容器替换是破坏性的（docker rm -f 旧容器 → 启新容器），旧版回滚依赖的 legacy
# 单容器已被停止容器清理（24h 保留）吃掉——健康检查失败曾致 prod 502 需手工救火。
# 现在切换前对每个触达层 docker tag 当前镜像为 <repo>:rollback（镜像不复制只贴标签），
# 失败路径 _rollback_prod_containers 用锚点镜像原地重建。首次部署无锚点 → 降级为仅清理。
# 参数: $1 = mode(remote|local)
_tag_rollback_anchors()
{
    local mode="$1"
    local container repo image
    for repo in noda-api noda-static; do
        case "$repo" in
            noda-api)    _layer_want_api || continue ; container="$PROD_API_CONTAINER" ;;
            noda-static) _layer_want_web || continue ; container="$PROD_STATIC_CONTAINER" ;;
        esac
        if [ "$mode" = "remote" ]; then
            image=$(remote_exec "docker inspect -f '{{.Config.Image}}' $container 2>/dev/null" 2>/dev/null | tr -d '\r' | head -1)
            if [ -n "$image" ] && remote_exec "docker image inspect $image >/dev/null 2>&1"; then
                if remote_exec "docker tag $image ${repo}:rollback"; then
                    log_info "回滚锚点已打: ${repo}:rollback <- $image"
                fi
            else
                log_warn "无回滚锚点可打: $container 不在运行（首次部署?）"
            fi
        else
            image=$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true)
            if [ -n "$image" ] && docker image inspect "$image" >/dev/null 2>&1; then
                docker tag "$image" "${repo}:rollback" && log_info "回滚锚点已打: ${repo}:rollback <- $image"
            else
                log_warn "无回滚锚点可打: $container 不在运行（首次部署?）"
            fi
        fi
    done
}

# _rollback_prod_containers - 部署失败时回滚到 rollback 锚点镜像（2026-09-13）
# 先清掉本层新容器，再对每个触达层用锚点镜像原地重建（api 回滚复用本次写入
# r4s 的 /tmp/prod-api.env——env 模板同构，新旧版本兼容），任一层无锚点则该层
# 保持清理后状态（首次部署场景）。最后 reload nginx；回滚容器 healthy 为尽力
# 等待——锚点镜像都起不来属环境级故障，保留现场交人工。
# 参数: $1 = mode(remote|local)
_rollback_prod_containers()
{
    local mode="$1"
    local health_timeout="$((HEALTH_CHECK_MAX_RETRIES * HEALTH_CHECK_INTERVAL))"
    local repo container
    _stop_new_prod_containers "$mode"
    for repo in noda-api noda-static; do
        case "$repo" in
            noda-api)    _layer_want_api || continue ; container="$PROD_API_CONTAINER" ;;
            noda-static) _layer_want_web || continue ; container="$PROD_STATIC_CONTAINER" ;;
        esac
        if [ "$mode" = "remote" ]; then
            if remote_exec "docker image inspect ${repo}:rollback >/dev/null 2>&1"; then
                log_warn "回滚 ${container} -> ${repo}:rollback"
                case "$repo" in
                    noda-api)    _start_prod_api remote "${repo}:rollback" "/tmp/prod-api.env" || true ;;
                    noda-static) _start_prod_static remote "${repo}:rollback" || true ;;
                esac
            else
                log_warn "无 ${repo}:rollback 锚点（首次部署?），该层保持清理后状态"
            fi
        else
            if docker image inspect "${repo}:rollback" >/dev/null 2>&1; then
                log_warn "回滚 ${container} -> ${repo}:rollback"
                case "$repo" in
                    noda-api)
                        # 本地模式 env 临时文件可能已随失败路径清理——重新生成
                        local env_file
                        if env_file=$(prepare_prod_api_env_file); then
                            _start_prod_api local "${repo}:rollback" "$env_file" || true
                            rm -f "$env_file"
                        else
                            log_warn "env 生成失败，跳过 api 回滚"
                        fi
                        ;;
                    noda-static) _start_prod_static local "${repo}:rollback" || true ;;
                esac
            else
                log_warn "无 ${repo}:rollback 锚点（首次部署?），该层保持清理后状态"
            fi
        fi
    done
    # 尽力等待回滚容器 healthy（失败不阻塞返回——日志可见，人工兜底）
    if [ "$mode" = "remote" ]; then
        _layer_want_api && { wait_container_healthy "$PROD_API_CONTAINER" "$health_timeout" true true || log_warn "回滚 api 容器未 healthy，请人工检查"; } || true
        _layer_want_web && { wait_container_healthy "$PROD_STATIC_CONTAINER" "$health_timeout" true true || log_warn "回滚 static 容器未 healthy，请人工检查"; } || true
    else
        _layer_want_api && { wait_container_healthy "$PROD_API_CONTAINER" "$health_timeout" || log_warn "回滚 api 容器未 healthy，请人工检查"; } || true
        _layer_want_web && { wait_container_healthy "$PROD_STATIC_CONTAINER" "$health_timeout" || log_warn "回滚 static 容器未 healthy，请人工检查"; } || true
    fi
    reload_nginx || true
    log_warn "已回滚到 rollback 锚点镜像（上一发布版本）"
}

# ============================================
# 函数: pipeline_deploy_prod
# ============================================
# 生产环境双容器部署（三容器拆分 2026-09 → S5 frontend 退役 2026-09-12）：
#   传镜像（api/static 按 LAYER）→ 打 rollback 锚点 → 依序启新容器 → 各自健康检查
#   → reload nginx 切流
# 安全措施：
#   - 镜像成功落地 r4s 前绝不动旧容器（传输失败旧容器全程未动）
#   - 切换前 docker tag 当前镜像为 <repo>:rollback（legacy 容器已被 24h 清理吃掉，
#     旧版"docker start legacy"回滚路径死亡——2026-09-13 改为锚点镜像原地重建）
#   - 任一新容器启动/健康检查失败 → _rollback_prod_containers 自动回上一版本
# 参数: $1 = GIT_SHA
pipeline_deploy_prod_inner()
{
    local git_sha="$1"
    LAYER_FILTER="${LAYER_FILTER:-all}"
    local api_image="noda-api:${git_sha}"
    local static_image="noda-static:${git_sha}"

    disk_snapshot "部署前"

    log_info "生产环境部署（LAYER=${LAYER_FILTER}）: $PROD_API_CONTAINER + $PROD_STATIC_CONTAINER ($git_sha)"

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式：registry 增量传输（流式，内存占用低）——旧容器全程
        # 保持服务直到新容器 healthy。内存护栏保留为观测项（低于阈值仅告警）。
        local free_mb
        free_mb=$(_r4s_mem_available_mb)
        if [ -n "$free_mb" ] && [ "$free_mb" -lt "${TRANSFER_FIRST_MIN_FREE_MB:-1024}" ]; then
            log_warn "r4s 可用内存 ${free_mb}MB 偏低——传输与容器重建可能变慢，请关注"
        fi

        # 传输镜像（按 LAYER 裁剪；r4s 增量拉层落盘）
        log_info "r4s 远程部署模式：传输镜像到 r4s（LAYER=${LAYER_FILTER:-all}）..."
        local img
        local transfer_list=()
        if _layer_want_api; then transfer_list+=("$api_image"); fi
        if _layer_want_web; then transfer_list+=("$static_image"); fi
        for img in "${transfer_list[@]}"; do
            if ! transfer_image "$img" "$img"; then
                log_error "镜像传输失败: $img（旧容器未受影响，线上继续服务）"
                return 1
            fi
        done

        # 切换不变式：本次部署的镜像必须确认落地 r4s，才允许动旧容器
        for img in "${transfer_list[@]}"; do
            if ! remote_exec "docker image inspect $img >/dev/null 2>&1"; then
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

        # 切换前打回滚锚点（破坏性替换的最后退路，见 _tag_rollback_anchors）
        _tag_rollback_anchors remote

        # 依序启动本层容器（api → static；未触达层保持原容器不动）
        # 任一失败：_rollback_prod_containers 用锚点镜像原地重建上一版本
        if _layer_want_api && ! _start_prod_api remote "$api_image" "/tmp/prod-api.env"; then
            log_error "api 容器启动失败 — 自动回滚"
            _rollback_prod_containers remote
            return 1
        fi
        if _layer_want_web && ! _start_prod_static remote "$static_image"; then
            log_error "static 容器启动失败 — 自动回滚"
            _rollback_prod_containers remote
            return 1
        fi

        # 健康检查（各自容器内探测，远程）
        log_info "等待容器健康检查（r4s 远程）..."
        local health_timeout="$((HEALTH_CHECK_MAX_RETRIES * HEALTH_CHECK_INTERVAL))"
        if _layer_want_api && ! wait_container_healthy "$PROD_API_CONTAINER" "$health_timeout" true true; then
            log_error "api 容器健康检查失败 — 自动回滚"
            _rollback_prod_containers remote
            return 1
        fi
        if _layer_want_web && ! wait_container_healthy "$PROD_STATIC_CONTAINER" "$health_timeout" true true; then
            log_error "static 容器健康检查失败 — 自动回滚"
            _rollback_prod_containers remote
            return 1
        fi

        # 全部 healthy：reload nginx 切流（upstream 指向新容器）
        reload_nginx

        # 发布后统一清理：Mac+r4s 镜像保留、registry retention+GC（失败不回滚部署）
        pipeline_post_publish_cleanup

        log_success "生产环境部署完成（r4s）: $PROD_API_CONTAINER + $PROD_STATIC_CONTAINER ($git_sha)"
    else
        # 本地模式（Mac）

        # 准备 env 文件（api）
        local tmp_api_env=""
        if _layer_want_api; then
            tmp_api_env=$(prepare_prod_api_env_file) || return 1
        fi

        # 切换前打回滚锚点
        _tag_rollback_anchors local

        # 依序启动本层容器
        if _layer_want_api && ! _start_prod_api local "$api_image" "$tmp_api_env"; then
            log_error "api 容器启动失败（本地模式）— 自动回滚"
            _rollback_prod_containers local
            rm -f "$tmp_api_env"
            return 1
        fi
        if _layer_want_web && ! _start_prod_static local "$static_image"; then
            log_error "static 容器启动失败（本地模式）— 自动回滚"
            _rollback_prod_containers local
            rm -f "$tmp_api_env"
            return 1
        fi

        rm -f "$tmp_api_env"

        # reload 反代刷新 DNS 缓存（容器重建后 IP 会变）
        reload_nginx || true

        # 健康检查
        log_info "等待容器健康检查（本地模式）..."
        local health_timeout="$((HEALTH_CHECK_MAX_RETRIES * HEALTH_CHECK_INTERVAL))"
        if _layer_want_api && ! wait_container_healthy "$PROD_API_CONTAINER" "$health_timeout"; then
            log_error "api 容器健康检查失败（本地模式）— 自动回滚"
            _rollback_prod_containers local
            return 1
        fi
        if _layer_want_web && ! wait_container_healthy "$PROD_STATIC_CONTAINER" "$health_timeout"; then
            log_error "static 容器健康检查失败（本地模式）— 自动回滚"
            _rollback_prod_containers local
            return 1
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
        '${POSTGRES_USER} ${POSTGRES_PASSWORD} ${RESEND_API_KEY} ${ANTHROPIC_AUTH_TOKEN} ${ANTHROPIC_BASE_URL} ${ANTHROPIC_API_KEY} ${ANTHROPIC_MAX_TOKENS} ${TOKEN_SECRET} ${EMAIL_SERVICE_API_KEY} ${STRIPE_SECRET_KEY} ${STRIPE_WEBHOOK_SECRET} ${STRIPE_PRICE_DEEP_READ} ${LIUYAO_WEB_BASE_URL} ${EVENTFINDA_API_HOST} ${EVENTFINDA_API_USERNAME} ${EVENTFINDA_API_PASSWORD} ${SNAGME_API_PORT} ${GOOGLE_OAUTH_CLIENT_ID} ${GOOGLE_OAUTH_CLIENT_SECRET} ${AUTH_STATE_SECRET}' \
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

# pipeline_purge_cdn_urls - 按产品精准清除 CDN 入口 URL（purge_everything 的替代路径）
# 背景：全域 purge 会把同 zone 下所有产品的边缘缓存全部打掉——单产品发布后
#   其它产品的缓存无谓失效、回源放大。改为只清本产品入口 URL。
# 清单选型（每产品 1-6 个）：HTML 壳入口（首页/列表页）+ 健康端点。静态发布链路
#   HTML 本身 no-cache（桶发布注释：HTML no-cache，浏览器与 CF 均不缓存陈旧壳），
#   但边缘仍可能缓存非 HTML 来源的响应（301 跳转、API GET、历史 404），入口 URL
#   精准 purge 兜底这些情况——数量少、单次请求成本近零。
#   各产品清单与 pipeline_verify_product 的 E2E 探针域名口径一致（www 探规范域）。
# CF API v4 zones/{zone_id}/purge_cache: {"files":[...]} 单次最多 30 个 URL——
#   本表每产品上限 6 个，一次请求即可，无需分批。
# 环境变量（由 Jenkins withCredentials 注入，同 pipeline_purge_cdn）：
#   CF_API_TOKEN - Cloudflare API Token
#   CF_ZONE_ID   - Cloudflare Zone ID
# 参数: $1 = 产品名（class/www/admin/liuyao/nearby/auth/comment/snagme）
# 返回: 0=成功或跳过（永远不阻止部署，per D-09/D-11，语义同 pipeline_purge_cdn）
pipeline_purge_cdn_urls()
{
    local product="$1"
    local urls=""

    # 入口 URL 表（与 _static_product_config 的产品维度对齐；注释一行说明选型理由）
    case "$product" in
        class)
            # en/zh/zh-TW 三个语言壳入口（out/en|zh|zh-TW.html）+ api 健康端点（verify 探针）
            urls="https://class.noda.co.nz/en
https://class.noda.co.nz/zh
https://class.noda.co.nz/zh-TW
https://class.noda.co.nz/api/health"
            ;;
        www)
            # 规范域首页 + zh/zh-TW 目录壳（www 301 → noda.co.nz，与 verify 一样只探规范域）
            urls="https://noda.co.nz/
https://noda.co.nz/zh/
https://noda.co.nz/zh-TW/"
            ;;
        admin)
            # 登录页壳（发布哨兵 out/login.html）+ 登录后落地 dashboard 壳
            # + snagme 看板壳（2026-09-13 集成，out/snagme.html）
            urls="https://admin.noda.co.nz/login
https://admin.noda.co.nz/dashboard
https://admin.noda.co.nz/snagme"
            ;;
        liuyao)
            # divine 主入口（en 无前缀）+ zh / zh-TW 变体壳（out/zh|zh-TW/divine.html）
            urls="https://liuyao.noda.co.nz/divine
https://liuyao.noda.co.nz/zh/divine
https://liuyao.noda.co.nz/zh-TW/divine"
            ;;
        nearby)
            # 根入口（defaultLocale 落地）+ en/zh 壳（zh-TW 同构页面随 Cache-Control 自然过期）
            urls="https://nearby.noda.co.nz/
https://nearby.noda.co.nz/en
https://nearby.noda.co.nz/zh"
            ;;
        auth)
            # defaultLocale=zh 无前缀：/login /register 即 zh 壳的两个认证入口
            urls="https://auth.noda.co.nz/login
https://auth.noda.co.nz/register"
            ;;
        comment)
            # 唯一静态占位页壳（其余路径走 Go commentapi 动态响应，不在桶上）
            urls="https://comments.noda.co.nz/admin"
            ;;
        snagme)
            # 看板三壳：首页/历史/雷达（单语言无 locale 前缀，数据全客户端 fetch）
            urls="https://snagme.noda.co.nz/
https://snagme.noda.co.nz/history
https://snagme.noda.co.nz/radar"
            ;;
        *)
            # D-09: 未知产品不阻止部署（打错日志提示修正 _static_product_config 同款清单）
            # ${product} 花括号形式：紧随全角括号时 bash 3.2/C locale 会把多字节字节并入变量名
            log_error "未知产品: ${product}（可选 class/www/admin/liuyao/nearby/auth/comment/snagme），跳过 CDN URL 精准清除"
            return 0
            ;;
    esac

    # 自动派生（2026-09-13）：扫描本构建产物 out/ 顶层 HTML 入口并入列表——
    # 产品新增 locale/入口页时不再需要手动同步上面的基线表。
    # 规则：out/*.html 与 out/<dir>/index.html（depth<=2）→ URL（index.html → /，
    # <dir>/index.html → /<dir>/，其余去 .html）；去重、cap 30（CF 单请求上限）。
    _static_product_config "$product" 2>/dev/null || true
    local out_dir="${NODA_APPS_DIR:-$PROJECT_ROOT/noda-apps}/${STATIC_WEB_DIR:-}/out"
    if [ -d "$out_dir" ]; then
        local base_host=""
        case "$product" in
            class)   base_host="https://class.noda.co.nz" ;;
            www)     base_host="https://noda.co.nz" ;;
            admin)   base_host="https://admin.noda.co.nz" ;;
            liuyao)  base_host="https://liuyao.noda.co.nz" ;;
            nearby)  base_host="https://nearby.noda.co.nz" ;;
            auth)    base_host="https://auth.noda.co.nz" ;;
            comment) base_host="https://comments.noda.co.nz" ;;
            snagme)  base_host="https://snagme.noda.co.nz" ;;
        esac
        if [ -n "$base_host" ]; then
            local f rel url _purge_list
            _purge_list=$(mktemp /tmp/noda-purge-urls.XXXXXX)
            find "$out_dir" -maxdepth 2 -name '*.html' -type f | sort >"$_purge_list"
            while IFS= read -r f; do
                rel="${f#"$out_dir"/}"
                case "$rel" in
                    index.html)      url="$base_host/" ;;
                    */index.html)    url="$base_host/${rel%/index.html}/" ;;
                    *.html)          url="$base_host/${rel%.html}" ;;
                    *)               continue ;;
                esac
                case "
$urls
" in *"
$url
"*) continue ;; esac
                urls="$urls
$url"
            done <"$_purge_list"
            rm -f "$_purge_list"
            # （find 结果经临时文件读取——POSIX 模式禁进程替换，同 build-args 教训）
            # cap 30（CF purge files 单请求上限），超出时优先保留基线表 + 字序靠前的入口
            urls=$(printf '%s\n' "$urls" | grep . | head -30)
            log_info "purge URL 列表（基线表 + 产物派生）: $(printf '%s\n' "$urls" | grep -c .) 个"
        fi
    else
        log_info "产物 out/ 不存在（本机无本次构建产物?），仅用基线 URL 表"
    fi

    # 凭据缺失时跳过（D-11，同 pipeline_purge_cdn）
    if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ZONE_ID:-}" ]; then
        log_warn "Cloudflare 凭据未配置，跳过 CDN 入口 URL 清除 ($product)"
        return 0
    fi

    log_info "精准清除 CDN 入口 URL (product: $product, zone: $CF_ZONE_ID, $(printf '%s\n' "$urls" | grep -c .) 个)..."

    # 换行分隔的 URL 列表 → {"files":[...]} JSON（here-doc 而非管道：while 不进子 shell；
    # 临时文件传 body，与 pipeline_purge_cdn 同约定）
    local tmp_body
    tmp_body=$(mktemp)
    {
        printf '{"files":['
        local _sep="" _url
        while IFS= read -r _url; do
            [ -z "$_url" ] && continue
            printf '%s"%s"' "$_sep" "$_url"
            _sep=","
        done <<EOF
$urls
EOF
        printf ']}'
    } >"$tmp_body"

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
        log_success "CDN 入口 URL 清除完成 ($product)"
    else
        # D-09: 失败不阻止部署
        log_error "CDN 入口 URL 清除失败 (HTTP ${http_code:-timeout})，不影响部署 ($product)"
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
# 仅公共基础设施服务: nginx, seaweedfs, noda-ops, postgres
# 每种服务使用独立的部署/健康检查策略
# ============================================

# ============================================
# 函数: pipeline_infra_preflight
# ============================================
# 基础设施服务前置检查（统一入口）
# 参数: $1 = SERVICE (nginx/seaweedfs/noda-ops/postgres)
# 返回: 0=检查通过，1=检查失败
pipeline_infra_preflight()
{
    local service="$1"

    log_info "基础设施前置检查: $service"

    # 同服务互斥已上移到 Jenkinsfile 首阶段 Queue Gate（pipeline_queue_gate）——
    # 后触发构建在进入 Pre-flight 前排队等待，不再占用实际构建资源。
    # 共享设施互斥（infra-core）在 Deploy 阶段经 pipeline_infra_core_enter 获取。

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程模式：同步仓库 + 检查远程 Docker daemon
        log_info "r4s 远程模式前置检查..."

        # 同步 r4s 仓库
        log_info "同步 r4s 仓库..."
        # 使用 fetch + reset --hard 替代 git pull，确保即使远程历史被重写（force push）
        # 也能正确同步；清理本地修改避免冲突
        # 注意: git clean -fd 不删除 .gitignore 忽略的文件（如 backup/logs）；
        # 用 -e 排除运行时数据目录（history/crawler-logs 等），保护生产数据
        # ⚠️ fetch 显式 refspec 为防御性写法（git ≥1.8.4 裸 fetch 亦会机会式更新
        # 跟踪引用，infra #10 实测同步正常；显式写法不依赖该行为且容忍强推）
        remote_exec "cd /opt/noda/noda-infra && git fetch origin +${R4S_GIT_BRANCH}:refs/remotes/origin/${R4S_GIT_BRANCH}" || {
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
                log_error "反代容器未运行（请先通过 noda-infra Pipeline 部署 nginx）"
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
            seaweedfs)
                # 无额外检查（S3 凭据由 Doppler 注入）
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
                log_error "反代容器未运行（请先通过 noda-infra Pipeline 部署 nginx）"
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
            seaweedfs)
                # 无额外检查（S3 凭据由 Doppler 注入）
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
# 参数: $1 = SERVICE（仅 postgres 需要备份，其余服务直接跳过）
# 环境变量: BACKUP_HOST_DIR
# 返回: 0=备份成功或跳过，1=备份失败
# 导出: INFRA_BACKUP_FILE（备份文件路径）
pipeline_backup_database()
{
    local service="$1"

    # 仅 postgres 有持久化数据需要备份
    if [ "$service" != "postgres" ]; then
        log_info "$service 不需要备份（无持久化数据）"
        return 0
    fi

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程模式：备份文件存储在 r4s 上
        local backup_dir="/opt/noda/noda-infra/docker/volumes/backup/infra-pipeline/${service}"
        local timestamp
        timestamp=$(date +"%Y%m%d-%H%M%S")
        local backup_file="${backup_dir}/${timestamp}.sql.gz"

        # 在 r4s 上创建备份目录
        remote_exec "mkdir -p $backup_dir"

        log_info "部署前备份（r4s）: $service -> $backup_file"

        remote_docker_exec "noda-infra-postgres-prod" \
            "pg_dumpall -U postgres --clean --if-exists | gzip > ${backup_file}"

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

        mkdir -p "$backup_dir"

        log_info "部署前备份: $service -> $backup_file"

        docker exec noda-infra-postgres-prod pg_dumpall -U postgres --clean --if-exists |
            gzip >"$backup_file"

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


# pipeline_infra_core_enter - 进入共享设施互斥区（infra-core 锁）
# Deploy 阶段起持有（Health/Verify 延续持有），post always 的
# pipeline_release_lock 统一释放；防止 nginx 重建窗口内其它核心服务并发操作
pipeline_infra_core_enter()
{
    NODA_LOCK_NAME="infra-core"
    export NODA_LOCK_NAME
    if ! acquire_deploy_lock 3600 "infra-core"; then
        log_error "无法获取部署锁 [infra-core]，可能有其他基础设施部署进行中"
        return 1
    fi
}

# ============================================
# 函数: pipeline_infra_deploy
# ============================================
# 部署分发（根据服务类型调用对应部署策略）
# 仅公共基础设施服务：nginx / seaweedfs / noda-ops / postgres
# 产品静态站发布已迁往 noda-apps Pipeline（pipeline_publish_product）
# 参数: $1 = SERVICE
# 返回: 由子函数决定
pipeline_infra_deploy()
{
    disk_snapshot "部署前"

    local service="$1"

    case "$service" in
        nginx)
            pipeline_deploy_nginx
            ;;
        noda-ops)
            pipeline_deploy_noda_ops
            ;;
        postgres)
            pipeline_deploy_postgres
            ;;
        seaweedfs)
            pipeline_deploy_seaweedfs
            ;;
        *)
            log_error "未知服务: $service（可选 nginx/seaweedfs/noda-ops/postgres）"
            return 1
            ;;
    esac
}

# ============================================
# 函数: pipeline_deploy_nginx
# ============================================
# Nginx docker compose recreate（秒级中断，非零停机）
# noda-infra SERVICE=nginx：反代镜像（noda-static，源码在 noda-apps 仓）已由
# pipeline_build_nginx_image 构建并传输到 r4s，此处取 r4s 最新 tag 重建容器
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
# 函数: _static_product_config / pipeline_publish_product / pipeline_publish_static_site
# ============================================
# 产品静态站发布（noda-apps Pipeline LAYER=static 前端路径；原 infra *-static 服务迁入）
# 流程：本地构建（pnpm build → out/）→ alpine/socat 临时中继
#   （R4S registry mirror 受限拉不动 minio/mc，复用 prod 种子期同款中继）
#   → mc mirror 增量同步到 SeaweedFS 桶 noda-static/sites/<product>/ → 中继即拆
#   （S3 端口不常驻暴露 LAN）→ 桶内对象数验证 + 哨兵文件
# 凭据：/etc/noda/jobs.env 的 S3_ACCESS_KEY/S3_SECRET_KEY——经 ssh 读入本地 shell
#   变量后传给 mc，不回显、不落盘、不进日志
# nginx 侧无需重启：桶内容更新即时生效（HTML no-cache，浏览器与 CF 均不缓存陈旧壳）
# 并行安全：publish-<product> 锁 + 中继容器名/端口（9333-9340 固定映射）/mc alias
#   全部带产品维度——跨产品并行发布互不覆盖
# 依赖：本机 mc（brew install minio/stable/mc）、NODA_APPS_DIR（默认 $PROJECT_ROOT/noda-apps）

# _static_product_config - 产品发布配置表
# 设置: STATIC_WEB_DIR（相对 noda-apps 根） STATIC_SENTINEL（相对 out/） STATIC_MIN_OBJS
# 阈值防「整树漏传」类事故；GA4 分站 property 构建期烤进 bundle（静态构建无运行时 env），
# 值同 LAYER=all 镜像构建的 --build-arg，此处显式 export 防漂移
_static_product_config()
{
    case "$1" in
        class)
            # 39 个 html + 资产 ≈ 422 对象；阈值 30
            STATIC_WEB_DIR="class/web";  STATIC_SENTINEL="out/en.html";      STATIC_MIN_OBJS=30 ;;
        www)
            # 188 对象量级；阈值 50
            STATIC_WEB_DIR="www/web";    STATIC_SENTINEL="out/index.html";   STATIC_MIN_OBJS=50 ;;
        admin)
            # 77 对象量级；阈值 20
            STATIC_WEB_DIR="admin/web";  STATIC_SENTINEL="out/login.html";   STATIC_MIN_OBJS=20 ;;
        liuyao)
            # 71 个 HTML + 资产 ≈ 数百对象；阈值 200
            export NEXT_PUBLIC_GA4_LIUYAO_ID=G-ZXK92PWTEF
            STATIC_WEB_DIR="liuyao/web"; STATIC_SENTINEL="out/en.html";      STATIC_MIN_OBJS=200 ;;
        nearby)
            # 9 个 HTML + 图片/字体资产 ≈ 200 对象量级；阈值 60；sitemap.xml 由 nearbyapi 出
            export NEXT_PUBLIC_GA4_NEARBY_ID=G-58CDREDT81
            STATIC_WEB_DIR="nearby/web"; STATIC_SENTINEL="out/en.html";      STATIC_MIN_OBJS=60 ;;
        comment)
            # admin 占位页（阈值 20；API 由 Go commentapi 承接）
            STATIC_WEB_DIR="comment";    STATIC_SENTINEL="out/admin.html";   STATIC_MIN_OBJS=20 ;;
        snagme)
            # 静态看板（Next.js output:'export'，单语言无 locale 前缀；数据全客户端
            # fetch Go API :3015）；out/ 51 对象量级；阈值 30
            STATIC_WEB_DIR="snagme/dashboard"; STATIC_SENTINEL="out/index.html"; STATIC_MIN_OBJS=30 ;;
        auth)
            # 静态壳（~35 HTML + 资产；阈值 60）；zh 无前缀 canonical（defaultLocale=zh）
            # ——哨兵文件用 out/zh/login.html；API 端点不在静态产物（Go authapi :3004 承接）
            STATIC_WEB_DIR="auth";       STATIC_SENTINEL="out/zh/login.html"; STATIC_MIN_OBJS=60 ;;
        *)
            log_error "未知静态站产品: ${1}（可选 class/www/admin/liuyao/nearby/auth/comment）"
            return 1
            ;;
    esac
}

# pipeline_publish_product - 产品静态站发布入口（noda-apps LAYER=static 调用）
# publish-<product> 锁互斥同产品发布；锁登记到 NODA_LOCK_REGISTRY，
# post always 的 pipeline_release_lock 兜底释放
pipeline_publish_product()
{
    local product="$1"
    _static_product_config "$product" || return 1
    NODA_LOCK_NAME="publish-${product}"
    export NODA_LOCK_NAME
    if ! acquire_deploy_lock 3600 "$NODA_LOCK_NAME"; then
        log_error "无法获取发布锁 [publish-${product}]，可能有同产品发布进行中"
        return 1
    fi
    local rc=0
    pipeline_publish_static_site "$product" || rc=1
    release_deploy_lock "$NODA_LOCK_NAME"
    return $rc
}

pipeline_publish_static_site()
{
    local product="$1"
    _static_product_config "$product" || return 1
    local min_objs="$STATIC_MIN_OBJS"
    local apps_dir="${NODA_APPS_DIR:-$PROJECT_ROOT/noda-apps}"
    local web_dir="$apps_dir/$STATIC_WEB_DIR"
    # 中继按产品隔离（2026-09-13 并行化）：不同产品的静态发布同时进行时，
    # 共享的容器名/端口/alias 会互删对方的中继（build 76/77 实证）——
    # 容器名、端口（9333-9340 固定映射）、mc alias 全部带产品维度。
    local relay_name="tmp-s3-relay-${product}"
    case "$product" in
        class)   local relay_port="9333" ;;
        www)     local relay_port="9334" ;;
        admin)   local relay_port="9335" ;;
        liuyao)  local relay_port="9336" ;;
        nearby)  local relay_port="9337" ;;
        auth)    local relay_port="9338" ;;
        comment) local relay_port="9339" ;;
        snagme)  local relay_port="9340" ;;
        *)       local relay_port="9341" ;;
    esac
    local alias_name="noda-prd-relay-${product}"

    _publish_site_cleanup()
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
    # （noda-apps 同款 v24.12.0 优先，其次任意 nvm 版本；homebrew node 仅作兜底）
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

    # 依赖就绪：fresh checkout 无 node_modules（Jenkins workspace 轮换槽位首次使用时），
    # workspace 安装一次后随目录持久，frozen-lockfile 幂等且快
    if [ ! -d "$web_dir/node_modules" ]; then
        log_info "前端依赖缺失，pnpm install --frozen-lockfile ($apps_dir)..."
        (cd "$apps_dir" && pnpm install --frozen-lockfile) || {
            log_error "pnpm install 失败: $apps_dir"
            return 1
        }
    fi

    log_info "构建 $product 静态站（pnpm build → out/）..."
    if ! (cd "$web_dir" && pnpm build); then
        log_error "$product 静态站构建失败: $web_dir"
        return 1
    fi
    if [ ! -f "$web_dir/$STATIC_SENTINEL" ]; then
        log_error "构建产物缺失 $web_dir/$STATIC_SENTINEL（output:export 校验失败）"
        return 1
    fi

    # 临时 S3 中继：192.168.100.1:9333 → seaweedfs:8333（noda-network 内）
    _publish_site_cleanup
    if ! remote_exec "docker rm -f $relay_name >/dev/null 2>&1 || true; docker run -d --name $relay_name --network $NETWORK_NAME -p 192.168.100.1:${relay_port}:8333 alpine/socat tcp-listen:8333,fork,reuseaddr tcp:seaweedfs:8333"; then
        log_error "S3 中继启动失败"
        _publish_site_cleanup
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
        _publish_site_cleanup
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
        _publish_site_cleanup
        return 1
    fi

    # 发布前快照轮转（N 层滚动，2026-09-13 打磨）：snap(max)←snap(max-1)←...←snap(1)←主前缀
    # -prev/-prev2 前缀不在 nginx 改写映射内，公网不可达；层数 MAX_STATIC_SNAPSHOTS（默认 2）
    _static_snapshot_rotate "$alias_name" "noda-static" "$product"

    log_info "mc mirror 增量同步（含删除） out/ → noda-static/sites/$product/ ..."
    # --remove：桶内该前缀收敛为当前 out/（旧构建 hash 资产/已删页面对象随之清理）；
    # 作用域仅 sites/<product>/ 前缀，图片（avatars/ 等）与其它前缀不受影响
    if ! mc mirror --overwrite --remove --quiet "$web_dir/out/" "$alias_name/noda-static/sites/$product/"; then
        log_error "静态站同步失败"
        _publish_site_cleanup
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
        if mc ls --recursive "$alias_name-stg/noda-static-stg/sites/$product/" >/dev/null 2>&1; then
            _static_snapshot_rotate "$alias_name-stg" "noda-static-stg" "$product"
        fi
        log_info "mc mirror 增量同步（含删除） out/ → noda-static-stg/sites/$product/ ..."
        if ! mc mirror --overwrite --remove --quiet "$web_dir/out/" "$alias_name-stg/noda-static-stg/sites/$product/"; then
            log_warn "preprod 桶（noda-static-stg）同步失败——preprod 静态内容可能滞后（不影响 prod）"
        fi
        # stg 对象级对账（同下方 prod 侧同款策略；build #35/#36 实证：stg 直连
        # SeaweedFS 的 mirror 也会静默漏传 + 误删——#36 把 #35 刚传的 snagme.*
        # 整组删除，preprod 页面随机 404。计数比对 + --overwrite 幂等补传，
        # 绝不清空前缀）
        local stg_src_objs stg_objs stg_attempt
        stg_src_objs=$(find "$web_dir/out" -type f 2>/dev/null | wc -l | tr -d ' ')
        for stg_attempt in 1 2 3; do
            stg_objs=$(mc ls --recursive "$alias_name-stg/noda-static-stg/sites/$product/" 2>/dev/null | grep -c . || true)
            if [ "${stg_objs:-0}" -ge "${stg_src_objs:-0}" ] && [ "${stg_objs:-0}" -gt 0 ]; then
                break
            fi
            log_warn "stg 桶列举 ${stg_objs:-0} < 源 ${stg_src_objs:-0}——重跑 mirror 补传（第 ${stg_attempt} 次）..."
            mc mirror --overwrite --quiet "$web_dir/out/" "$alias_name-stg/noda-static-stg/sites/$product/" || true
        done
    else
        log_warn "stg S3（127.0.0.1:8333）不可达或凭据缺失，跳过 preprod 桶同步"
    fi

    # 对象级对账（2026-09-13 build 72 实证：mc mirror 曾静默漏传 zh/topic/love.html
    # ——同目录部分对象上传部分跳过且零报错，min_objs 阈值无法发现，verify 探测兜住）。
    # ⚠️ 中继（socat→seaweedfs）上的 mc ls --recursive 会随机截断：同一棵树实测
    # 52/54/55/70 浮动（build 68/71/75）。截断计数曾触发「清空前缀全量重建」，
    # rm --recursive + 半程重传直接把线上 /zh 打成 nginx 404（build 75 实证）。
    # 因此对账策略改为：
    #   1) 列举重试 3 次取最大值——截断只少不多，max 收敛于真值；
    #   2) 不一致只重跑 mirror --overwrite（幂等补传，安全方向），
    #      绝不清空前缀（rm --recursive 在列举抖动下是破坏性操作，已移除）；
    #   3) 哨兵文件 mc stat 单对象 HEAD 兜底（计数巧合对不上单点缺失）。
    local objs src_objs attempt
    src_objs=$(find "$web_dir/out" -type f 2>/dev/null | wc -l | tr -d ' ')
    objs=0
    for attempt in 1 2 3; do
        objs=$(mc ls --recursive "$alias_name/noda-static/sites/$product/" 2>/dev/null | grep -c . || true)
        if [ "${objs:-0}" -ge "${src_objs:-0}" ]; then
            break
        fi
        log_warn "桶列举 ${objs} < 源 ${src_objs}（中继截断或漏传）——重跑 mirror 补传（第 ${attempt} 次）..."
        mc mirror --overwrite --quiet "$web_dir/out/" "$alias_name/noda-static/sites/$product/" >/dev/null 2>&1 || true
    done

    # 全部校验（对象数/对账/哨兵）都依赖 mc alias 在位——中继拆除必须放在最后。
    # （旧写法先 cleanup 再 mc stat，哨兵检查必然失败——旧 infra-deploy #80 的 FAILURE 根因）
    local publish_ok="true"
    if [ "${objs:-0}" -lt "$min_objs" ]; then
        log_error "桶内对象数异常（${objs} < ${min_objs}），发布疑似不完整"
        publish_ok="false"
    fi
    if [ "${objs:-0}" -ne "${src_objs:-0}" ]; then
        log_error "镜像对账失败：源 out/ $src_objs 个文件 ≠ 桶 $objs 个对象——mc mirror 静默漏传，发布不完整"
        publish_ok="false"
    fi
    local sentinel="${STATIC_SENTINEL#out/}"
    if [ -f "$web_dir/out/$sentinel" ]; then
        if ! mc stat "$alias_name/noda-static/sites/$product/$sentinel" >/dev/null 2>&1; then
            log_error "哨兵对象缺失：sites/$product/$sentinel（mc mirror 静默漏传）"
            publish_ok="false"
        fi
    fi

    _publish_site_cleanup
    if [ "$publish_ok" != "true" ]; then
        return 1
    fi

    log_success "$product 静态站发布完成：noda-static/sites/$product/（$objs 个对象，与源一致，中继已拆除）"
}

# ============================================
# 静态站多层快照（2026-09-13 打磨：单份 -prev 只能回滚一步 → N 层滚动）
# ============================================
# 深度 i 对应的桶前缀：i=1 → <product>-prev（兼容既有命名），i≥2 → <product>-prev<i>
_static_snapshot_dir()
{
    local product="$1" depth="${2:-1}"
    if [ "$depth" -le 1 ]; then
        echo "${product}-prev"
    else
        echo "${product}-prev${depth}"
    fi
}

# 发布前快照轮转（深→浅逐层外移，最浅层吃掉当前主前缀）：
#   snap(max) ← snap(max-1) ← ... ← snap(1) ← sites/<product>/
# MAX_STATIC_SNAPSHOTS 控制层数（默认 2：-prev 可回滚一步 / -prev2 可回滚两步）。
# 任一层轮转失败仅告警——快照是回滚锚点，但绝不能阻塞发布本身。
# 快照前缀不在 nginx 改写映射内，公网不可达。
_static_snapshot_rotate()
{
    local alias_name="$1" bucket_root="$2" product="$3"
    local max_snap="${MAX_STATIC_SNAPSHOTS:-2}"
    local i src dst
    if ! mc ls --recursive "$alias_name/$bucket_root/sites/$product/" >/dev/null 2>&1; then
        log_info "首次发布（桶内无 $product 前缀），跳过快照"
        return 0
    fi
    i=$((max_snap - 1))
    while [ "$i" -ge 1 ]; do
        src=$(_static_snapshot_dir "$product" "$i")
        dst=$(_static_snapshot_dir "$product" "$((i + 1))")
        if mc ls --recursive "$alias_name/$bucket_root/sites/$src/" >/dev/null 2>&1; then
            log_info "快照轮转 $src → $dst ..."
            mc mirror --overwrite --remove --quiet \
                "$alias_name/$bucket_root/sites/$src/" \
                "$alias_name/$bucket_root/sites/$dst/" || \
                log_warn "快照轮转 $src → $dst 失败（该层快照可能过期）"
        fi
        i=$((i - 1))
    done
    log_info "快照当前发布 → $bucket_root/sites/$(_static_snapshot_dir "$product" 1)/ ..."
    mc mirror --overwrite --remove --quiet \
        "$alias_name/$bucket_root/sites/$product/" \
        "$alias_name/$bucket_root/sites/$(_static_snapshot_dir "$product" 1)/" || \
        log_warn "快照失败（不影响本次发布，仅失去回滚锚点）"
}

# ============================================
# 函数: pipeline_rollback_static_site
# ============================================
# 静态站发布回滚：把指定层的快照 mirror 回主前缀（prod+stg 双桶）。
# 用于发布失误（内容错误/产物异常）——mirror --remove 让旧内容立即消失，
# 本函数以发布时自动打的快照为回滚源，一次 mirror 即回上一/上二版本。
# 用法（noda-apps 构建机）：
#   SKIP_LOAD_SECRETS=1 DEPLOY_TARGET=r4s SSH_KEY_FILE=<key> \
#     source scripts/pipeline-stages.sh && pipeline_rollback_static_site <product> [depth]
# 参数：depth=1 回滚到上一次发布（默认）；depth=2 上两次；上限 MAX_STATIC_SNAPSHOTS。
# 注意：快照为 N 层滚动（每次发布深→浅轮转），可回滚窗口 = 层数。
pipeline_rollback_static_site()
{
    local product="$1"
    local depth="${2:-1}"
    local max_snap="${MAX_STATIC_SNAPSHOTS:-2}"
    case "$depth" in ''|*[!0-9]*) depth=1 ;; esac
    [ "$depth" -lt 1 ] && depth=1
    [ "$depth" -gt "$max_snap" ] && depth=$max_snap
    local snap_dir
    snap_dir=$(_static_snapshot_dir "$product" "$depth")
    if [ -z "$product" ]; then
        log_error "用法: pipeline_rollback_static_site <product> [depth=1..${MAX_STATIC_SNAPSHOTS:-2}]"
        return 1
    fi
    if ! command -v mc >/dev/null 2>&1; then
        log_error "本机未安装 minio client（brew install minio/stable/mc）"
        return 1
    fi

    local relay_name="tmp-s3-relay-${product}"
    local relay_port
    case "$product" in
        class)   relay_port="9333" ;;
        www)     relay_port="9334" ;;
        admin)   relay_port="9335" ;;
        liuyao)  relay_port="9336" ;;
        nearby)  relay_port="9337" ;;
        auth)    relay_port="9338" ;;
        comment) relay_port="9339" ;;
        snagme)  relay_port="9340" ;;
        *)       relay_port="9341" ;;
    esac
    local alias_name="noda-prd-relay-${product}"
    _rollback_cleanup()
    {
        remote_exec "docker rm -f $relay_name >/dev/null 2>&1 || true" || true
        mc alias remove "$alias_name" >/dev/null 2>&1 || true
    }

    if ! remote_exec "docker rm -f $relay_name >/dev/null 2>&1 || true; docker run -d --name $relay_name --network $NETWORK_NAME -p 192.168.100.1:${relay_port}:8333 alpine/socat tcp-listen:8333,fork,reuseaddr tcp:seaweedfs:8333"; then
        log_error "S3 中继启动失败"
        return 1
    fi

    local s3a s3s
    s3a=$(remote_exec "grep -E '^S3_ACCESS_KEY=' /etc/noda/jobs.env | head -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r"')
    s3s=$(remote_exec "grep -E '^S3_SECRET_KEY=' /etc/noda/jobs.env | head -1 | cut -d= -f2-" 2>/dev/null | tr -d '\r"')
    if [ -z "$s3a" ] || [ -z "$s3s" ]; then
        log_error "S3 凭据读取失败（/etc/noda/jobs.env）"
        _rollback_cleanup
        return 1
    fi
    if ! mc alias set "$alias_name" "http://192.168.100.1:${relay_port}" "$s3a" "$s3s" --api S3v4; then
        log_error "mc alias 设置失败"
        _rollback_cleanup
        return 1
    fi

    local prev_objs
    prev_objs=$(mc ls --recursive "$alias_name/noda-static/sites/${snap_dir}/" 2>/dev/null | grep -c . || true)
    if [ "${prev_objs:-0}" -eq 0 ]; then
        log_error "回滚快照为空：sites/${snap_dir}/ 不存在或无对象（该层快照尚未产生/无此深度历史）"
        _rollback_cleanup
        return 1
    fi

    log_info "回滚: sites/${snap_dir}/（$prev_objs 对象）→ sites/$product/ ..."
    if ! mc mirror --overwrite --remove --quiet \
        "$alias_name/noda-static/sites/${product}-prev/" \
        "$alias_name/noda-static/sites/$product/"; then
        log_error "prod 桶回滚失败"
        _rollback_cleanup
        return 1
    fi

    # stg 桶同步回滚（失败仅告警——preprod 非关键路径）
    local stg_json="$PROJECT_ROOT/config/seaweedfs/s3.json"
    if [ -f "$stg_json" ]; then
        if mc alias set "$alias_name-stg" "http://127.0.0.1:8333" \
            "$(python3 -c "import json;d=json.load(open('$stg_json'));print(d['identities'][0]['credentials'][0]['accessKey'])" 2>/dev/null)" \
            "$(python3 -c "import json;d=json.load(open('$stg_json'));print(d['identities'][0]['credentials'][0]['secretKey'])" 2>/dev/null)" \
            --api S3v4 >/dev/null 2>&1; then
            mc mirror --overwrite --remove --quiet \
                "$alias_name-stg/noda-static-stg/sites/${snap_dir}/" \
                "$alias_name-stg/noda-static-stg/sites/$product/" \
                && log_info "stg 桶已同步回滚" || log_warn "stg 桶回滚失败（不影响 prod）"
        fi
    fi

    # 对象数校验须在拆 alias 之前
    local now_objs
    now_objs=$(mc ls --recursive "$alias_name/noda-static/sites/$product/" 2>/dev/null | grep -c . || true)
    _rollback_cleanup
    log_info "回滚后主前缀对象数: $now_objs（快照 $prev_objs）"
    if [ "$now_objs" != "$prev_objs" ]; then
        log_warn "回滚后对象数与快照不一致（$now_objs vs $prev_objs）——请人工核对"
    fi
    log_success "$product 静态站已回滚到第 ${depth} 层快照（$now_objs 对象）；确认恢复后下次发布会重新快照"
    return 0
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
    # r4s registry mirror 拉不动 minio/mc（publish 同款已知限制，实测 pull denied）——
    # r4s 模式改走「本地 mc + 临时 socat 中继」，9340 端口与产品发布端口池隔离，中继即拆
    log_info "初始化 S3 桶 ${S3_BUCKET}（mb --ignore-existing + anonymous download）..."
    local mc_sh="mc mb --ignore-existing seaweedfs/${S3_BUCKET} && mc anonymous set download seaweedfs/${S3_BUCKET}"
    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        if ! command -v mc >/dev/null 2>&1; then
            log_error "本机未安装 minio client（brew install minio/stable/mc）"
            return 1
        fi
        local relay_name="tmp-s3-relay-seaweedfs"
        local alias_name="noda-prd-relay-seaweedfs"
        remote_exec "docker rm -f $relay_name >/dev/null 2>&1 || true; docker run -d --name $relay_name --network $NETWORK_NAME -p 192.168.100.1:9340:8333 alpine/socat tcp-listen:8333,fork,reuseaddr tcp:seaweedfs:8333" || {
            log_error "S3 中继启动失败"
            return 1
        }
        # 匿名读由本部署渲染的 s3.json anonymous identity（Read:<bucket>）授予；
        # mc anonymous set download 依赖 ACL header，SeaweedFS 未实现（实测 NotImplemented），
        # 仅作 best-effort，失败不阻塞部署
        local init_ok="false"
        if mc alias set "$alias_name" "http://192.168.100.1:9340" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" --api S3v4 \
            && mc mb --ignore-existing "$alias_name/$S3_BUCKET"; then
            init_ok="true"
            mc anonymous set download "$alias_name/$S3_BUCKET" 2>/dev/null \
                || log_info "mc anonymous 不被 SeaweedFS 支持，匿名读走 s3.json anonymous identity（已生效）"
        fi
        remote_exec "docker rm -f $relay_name >/dev/null 2>&1 || true" || true
        mc alias remove "$alias_name" >/dev/null 2>&1 || true
        if [ "$init_ok" != "true" ]; then
            log_error "S3 桶初始化失败（$S3_BUCKET）"
            return 1
        fi
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
            seaweedfs)
                # healthcheck 探测 master API（9333/cluster/status，容器内）
                wait_container_healthy "seaweedfs" 60 true true
                ;;
            *)
                log_error "未知服务: $service"
                return 1
                ;;
        esac
    else
        # 本地模式：保持现有逻辑
        case "$service" in
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
            seaweedfs)
                wait_container_healthy "seaweedfs-stg" 60
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
# 部署后验证（公共基础设施服务）
# 参数: $1 = SERVICE (nginx/seaweedfs/noda-ops/postgres)
# 返回: 0=验证通过，1=验证失败
pipeline_infra_verify()
{
    local service="$1"

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        case "$service" in
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
            seaweedfs)
                # E2E：同网络内对桶根发 GET（匿名只读 → 200 ListBucket）
                remote_docker_exec "$NGINX_CONTAINER" "wget --quiet --tries=1 --spider http://seaweedfs:8333/noda-static/"
                log_success "SeaweedFS E2E 验证通过（r4s）"
                ;;
            *)
                log_error "未知服务: $service"
                return 1
                ;;
        esac
    else
        case "$service" in
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
            seaweedfs)
                docker exec "$NGINX_CONTAINER" wget --quiet --tries=1 --spider http://seaweedfs:8333/noda-static-stg/
                log_success "SeaweedFS E2E 验证通过"
                ;;
            *)
                log_error "未知服务: $service"
                return 1
                ;;
        esac
    fi
}

# ============================================
# 函数: pipeline_verify_product
# ============================================
# 产品维度 E2E 验证（noda-apps Pipeline Verify 阶段）
# 纯公网链路（Cloudflare → 边缘反代 → 桶静态壳 / Go API），与部署目标无关：
# LAYER=static 验证「桶页面 + API 直达」，LAYER=api/all 验证所选产品的 API 链路
# 参数: $1 = PRODUCT (class/www/admin/liuyao/nearby/auth/comment)
# 返回: 0=全部探针 200，1=任一失败
pipeline_verify_product()
{
    local product="$1"
    local retries="${E2E_MAX_RETRIES:-5}"
    local interval="${E2E_INTERVAL:-2}"
    local checks=""

    case "$product" in
        class)
            checks="https://class.noda.co.nz/en|class 静态壳
https://class.noda.co.nz/api/health|class api 链"
            ;;
        www)
            # www.noda.co.nz 301 → noda.co.nz（规范域）；直接探规范域
            checks="https://noda.co.nz/|www 首页
https://noda.co.nz/zh/|www 中文页
https://noda.co.nz/api/courses|www api 链"
            ;;
        admin)
            checks="https://admin.noda.co.nz/login|admin 登录页
https://admin.noda.co.nz/api/admin/health|admin api 链"
            ;;
        liuyao)
            checks="https://liuyao.noda.co.nz/divine|liuyao 静态壳
https://liuyao.noda.co.nz/api/health|liuyao api 链"
            ;;
        nearby)
            checks="https://nearby.noda.co.nz/|nearby 静态壳
https://nearby.noda.co.nz/sitemap.xml|nearby sitemap（反代 Go）
https://nearby.noda.co.nz/api/nearby/feed?city=auckland&limit=1|nearby api 链"
            ;;
        auth)
            checks="https://auth.noda.co.nz/login|auth 登录页
https://auth.noda.co.nz/api/health|auth api 链"
            ;;
        comment)
            checks="https://comments.noda.co.nz/admin|comment 占位页
https://comments.noda.co.nz/api/health|comment api 链"
            ;;
        snagme)
            # 公网探针（域名已生效）：看板静态壳 + Go API 业务端点
            checks="https://snagme.noda.co.nz/|snagme 看板
https://snagme.noda.co.nz/api/snagme/status|snagme api 链"
            ;;
        *)
            log_error "未知产品: ${product}（可选 class/www/admin/liuyao/nearby/auth/comment/snagme）"
            return 1
            ;;
    esac

    local entry url label code i all_ok="true"
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        url="${entry%%|*}"
        label="${entry#*|}"
        code="000"
        for i in $(seq 1 "$retries"); do
            code=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || echo "000")
            if [ "$code" = "200" ]; then
                break
            fi
            log_info "等待 $label → 200 ... (${i}/${retries}, HTTP ${code})"
            sleep "$interval"
        done
        if [ "$code" = "200" ]; then
            log_success "$label → 200 ($url)"
        else
            log_error "E2E 验证失败: $label ($url) 最后状态 HTTP ${code}"
            all_ok="false"
        fi
    done <<EOF
$checks
EOF

    if [ "$all_ok" != "true" ]; then
        return 1
    fi
    log_success "产品 $product E2E 验证全部通过"
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
        nginx)
            log_info "$service 无需额外清理（dangling 清理由通用 wrapper 处理）"
            ;;
        noda-ops)
            cleanup_by_date_threshold "noda-ops"
            ;;
        postgres)
            log_info "PostgreSQL 无需额外清理"
            ;;
        seaweedfs)
            log_info "SeaweedFS 无需额外清理"
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
        nginx)
            container_name="$(_resolve_nginx_container)"
            ;;
        noda-ops)
            container_name="noda-ops"
            ;;
        postgres)
            container_name="noda-infra-postgres-prod"
            ;;
        seaweedfs)
            container_name="seaweedfs"
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

# pipeline_deploy_preprod_inner - preprod 部署主体（锁由外层包装持有）
# 参数: $1 = GIT_SHA
pipeline_deploy_preprod_inner()
{
    local git_sha="$1"
    local api_image="noda-api:${git_sha}"
    local static_image="noda-static:${git_sha}"

    disk_snapshot "Pre-prod 部署前"

    log_info "部署 Pre-prod 环境（S5 双容器: api + static）..."

    if [ "$DEPLOY_TARGET" = "r4s" ]; then
        # r4s 远程部署模式（休眠路径：noda-apps Pipeline 的 preprod 走 DEPLOY_TARGET=local）
        # ⚠️ 先传镜像再动旧容器（如果传失败，旧容器保留服务不断）；按 LAYER 裁剪
        log_info "r4s 远程部署模式：传输镜像到 r4s（LAYER=${LAYER_FILTER:-all}）..."
        local img
        local transfer_list=()
        if _layer_want_api; then transfer_list+=("$api_image"); fi
        if _layer_want_web; then transfer_list+=("$static_image"); fi
        for img in "${transfer_list[@]}"; do
            if ! transfer_image "$img" "$img"; then
                log_error "Pre-prod 镜像传输失败: ${img}，旧容器保留"
                return 1
            fi
        done

        # 清理旧 preprod 容器（远程；含 legacy 单容器与 preprod-nginx）
        _preprod_cleanup_legacy remote

        # 准备 preprod 专用 env 文件（api，本地生成，传输到 r4s）
        local tmp_api_env=""
        if _layer_want_api; then
            tmp_api_env=$(prepare_preprod_api_env_file) || return 1
            log_info "传输 env 文件到 r4s..."
            cat "$tmp_api_env" | remote_exec "cat > /tmp/preprod-api.env && chmod 600 /tmp/preprod-api.env"
            rm -f "$tmp_api_env"
        fi

        # 启动 preprod 容器（远程）：仅重建本层容器，未触达层保持原容器不动
        if _layer_want_web; then
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
        fi

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
        '${POSTGRES_USER} ${POSTGRES_PASSWORD} ${RESEND_API_KEY} ${ANTHROPIC_AUTH_TOKEN} ${ANTHROPIC_BASE_URL} ${ANTHROPIC_API_KEY} ${ANTHROPIC_MAX_TOKENS} ${TOKEN_SECRET} ${EMAIL_SERVICE_API_KEY} ${STRIPE_SECRET_KEY} ${STRIPE_WEBHOOK_SECRET} ${STRIPE_PRICE_DEEP_READ} ${LIUYAO_WEB_BASE_URL} ${EVENTFINDA_API_HOST} ${EVENTFINDA_API_USERNAME} ${EVENTFINDA_API_PASSWORD} ${SNAGME_API_PORT}' \
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
    #
    # 并行化（2026-09-13）：锁按资源维度命名，且并行构建可能同时持有不同锁——
    # 只释放「本构建」登记在 NODA_LOCK_REGISTRY 的锁（mkdir 锁无属主语义，
    # 盲放全局锁名会拆掉别的并行构建正持有的锁）。构建硬杀后 30 分钟由
    # acquire 的陈旧锁自愈兜底。
    if [ -n "${NODA_LOCK_REGISTRY:-}" ] && [ -f "$NODA_LOCK_REGISTRY" ]; then
        # 先读全再循环——release 内部会重写 registry 文件，流式读会错乱
        local lk
        for lk in $(cat "$NODA_LOCK_REGISTRY" 2>/dev/null); do
            [ -n "$lk" ] && release_deploy_lock "$lk"
        done
        rm -f "$NODA_LOCK_REGISTRY"
    fi
    log_info "部署锁已释放（本构建登记的全部锁）"
}

# ============================================
# 并行化包装（2026-09-13）：锁只在实际操作共享容器时持有——
#   preprod 部署持 apps-preprod（preprod-noda-api/static 容器）
#   prod 部署持 apps-prod（noda-api-prod/static 容器 + upstream 切流）
# 构建A 的 preprod 验证窗口内，构建B 可直接执行 prod 部署。
# 锁获取成功即登记到 NODA_LOCK_REGISTRY（按构建隔离），post always 兜底
# 只释放本构建持有的锁；部署函数内所有 return 路径由包装统一 release。
NODA_LOCK_REGISTRY="${NODA_LOCK_REGISTRY:-${WORKSPACE:-/tmp}/.noda-locks-${BUILD_NUMBER:-$$}}"

# pipeline_queue_gate - 同服务队列门禁（Jenkinsfile 首阶段调用，2026-09-13）
# 语义：同一服务的多条 Pipeline 不允许同时构建——后触发者在门禁处等待
# （不做 checkout/测试/传输等任何实际工作），先到者完成后自动接棒；
# 等待超过 GATE_WAIT_SECONDS（默认 900s）则明确失败并释放 executor。
# 锁登记 NODA_LOCK_REGISTRY，post always 兜底释放；normal 模式在 Human
# Approval 前主动释放（避免审批挂起阻塞同服务后续发布），Deploy Prod
# /Rebuild 前经本函数重新获取。
pipeline_queue_gate()
{
    local svc="$1"
    if [ -z "$svc" ]; then
        log_error "队列门禁缺少服务标识"
        return 1
    fi
    NODA_LOCK_NAME="build-${svc}"
    export NODA_LOCK_NAME
    # 幂等：本构建已在 Gate 持有同名锁（registry 登记）则直接通过——
    # Deploy Prod 重取是「审批窗口释放后」的路径，fast/static 无审批路径
    # 锁仍在手，重取会 mkdir 撞自己（mkdir 锁无属主语义，#6 自锁 15min 实证）
    if [ -f "${NODA_LOCK_REGISTRY:-}" ] && grep -Fxq "build-${svc}" "$NODA_LOCK_REGISTRY" 2>/dev/null; then
        log_info "队列门禁 [$svc]：本构建已持有锁，跳过重取"
        return 0
    fi
    log_info "队列门禁 [$svc]：同服务互斥——如有同服务发布进行中，本构建在此等待（最长 ${GATE_WAIT_SECONDS:-900}s）..."
    if ! acquire_deploy_lock "${GATE_WAIT_SECONDS:-900}" "build-${svc}"; then
        log_error "同服务 $svc 的发布等待超时（${GATE_WAIT_SECONDS:-900}s 未获得锁）——本构建终止，请稍后重试"
        return 1
    fi
    log_success "队列门禁通过 [$svc]"
}

# pipeline_release_build_lock - 审批前主动释放队列门禁锁（Deploy 前重取）
pipeline_release_build_lock()
{
    release_deploy_lock "build-$1"
    log_info "队列门禁锁已释放（审批窗口不再阻塞同服务后续发布）"
}

pipeline_deploy_preprod()
{
    if ! acquire_deploy_lock 3600 apps-preprod; then
        log_error "preprod 部署锁获取失败（apps-preprod），中止"
        return 1
    fi
    local rc=0
    pipeline_deploy_preprod_inner "$@" || rc=1
    release_deploy_lock apps-preprod
    return $rc
}

pipeline_deploy_prod()
{
    if ! acquire_deploy_lock 3600 apps-prod; then
        log_error "prod 部署锁获取失败（apps-prod），中止"
        return 1
    fi
    local rc=0
    pipeline_deploy_prod_inner "$@" || rc=1
    release_deploy_lock apps-prod
    return $rc
}

# ============================================
# Source guard — 仅允许 source 加载，禁止直接执行
# ============================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "pipeline-stages.sh 是函数库，不支持直接执行"
    echo "请通过 Jenkinsfile 调用"
    exit 1
fi
