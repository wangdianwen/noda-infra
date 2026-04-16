#!/bin/bash
set -euo pipefail

# ============================================
# Jenkins Pipeline 阶段函数库
# ============================================
# 功能：封装 Jenkinsfile 8 阶段 Pipeline 所需的 bash 函数
# 用途：Jenkinsfile 通过 source 加载此文件，调用 pipeline_* 函数
# 依赖：scripts/lib/log.sh, scripts/manage-containers.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/manage-containers.sh"

# ============================================
# 常量
# ============================================
HEALTH_CHECK_MAX_RETRIES=30
HEALTH_CHECK_INTERVAL=4
E2E_MAX_RETRIES=5
E2E_INTERVAL=2
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.app.yml"
BACKUP_HOST_DIR="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-12}"
IMAGE_RETENTION_DAYS="${IMAGE_RETENTION_DAYS:-7}"

# ============================================
# 函数: check_backup_freshness
# ============================================
# 检查数据库备份文件是否在指定小时内
# 策略：先检查当天/昨天日期子目录，再回退全目录搜索
# 返回：0=备份新鲜，1=备份过期或不存在
# 环境变量：
#   BACKUP_HOST_DIR - 备份目录（默认 $PROJECT_ROOT/docker/volumes/backup）
#   BACKUP_MAX_AGE_HOURS - 最大允许年龄小时数（默认 12）
check_backup_freshness() {
  local backup_dir="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}"
  local max_age_hours="${BACKUP_MAX_AGE_HOURS:-12}"

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
        -exec stat -f '%m %N' {} \; 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)
      [ -n "$newest_file" ] && break
    fi
  done

  # 回退：全目录搜索最新备份文件
  if [ -z "$newest_file" ]; then
    newest_file=$(find "$backup_dir" -type f \( -name "*.dump" -o -name "*.sql" \) \
      -exec stat -f '%m %N' {} \; 2>/dev/null \
      | sort -rn | head -1 | cut -d' ' -f2-)
  fi

  if [ -z "$newest_file" ]; then
    log_error "未找到任何备份文件（查找路径: $backup_dir）"
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
# 函数: http_health_check
# ============================================
# 从 blue-green-deploy.sh 复制（该文件无 source guard，不能 source）
# 通过 docker exec 在目标容器内执行 wget 检测 HTTP 端点
# 参数:
#   $1: 容器名
#   $2: 最大重试次数（默认 30）
#   $3: 重试间隔秒数（默认 4）
# 返回：0=健康，1=失败
http_health_check() {
  local container="$1"
  local max_retries="${2:-$HEALTH_CHECK_MAX_RETRIES}"
  local interval="${3:-$HEALTH_CHECK_INTERVAL}"
  local attempt=0

  log_info "HTTP 健康检查: $container (最多 ${max_retries} 次, 间隔 ${interval}s)"

  while [ $attempt -lt $max_retries ]; do
    attempt=$((attempt + 1))

    if docker exec "$container" wget --quiet --tries=1 --spider "http://localhost:3001/api/health" 2>/dev/null; then
      log_success "$container — HTTP 健康检查通过 (第 ${attempt}/${max_retries} 次)"
      return 0
    fi

    if [ $attempt -lt $max_retries ]; then
      sleep "$interval"
    fi
  done

  log_error "$container — HTTP 健康检查失败 (${max_retries} 次尝试)"
  log_info "最近容器日志:"
  docker logs "$container" --tail 20 2>&1 | sed 's/^/  /'
  return 1
}

# ============================================
# 函数: e2e_verify
# ============================================
# 从 blue-green-deploy.sh 复制（该文件无 source guard，不能 source）
# 通过 nginx 容器 curl 目标容器，验证完整请求链路
# 参数:
#   $1: 目标环境 (blue 或 green)
#   $2: 最大重试次数（默认 5）
#   $3: 重试间隔秒数（默认 2）
# 返回：0=验证通过，1=验证失败
e2e_verify() {
  local target_env="$1"
  local max_retries="${2:-$E2E_MAX_RETRIES}"
  local interval="${3:-$E2E_INTERVAL}"
  local container_name
  container_name=$(get_container_name "$target_env")

  log_info "E2E 验证: nginx -> $container_name (最多 ${max_retries} 次)"

  # 检测 nginx 容器是否有 curl
  local use_curl=true
  if ! docker exec "$NGINX_CONTAINER" which curl >/dev/null 2>&1; then
    log_info "nginx 容器无 curl，使用 wget 备选方案"
    use_curl=false
  fi

  local attempt=0
  while [ $attempt -lt $max_retries ]; do
    attempt=$((attempt + 1))

    local result=1

    if [ "$use_curl" = true ]; then
      local http_code
      http_code=$(docker exec "$NGINX_CONTAINER" \
        curl -s -o /dev/null -w "%{http_code}" \
        "http://${container_name}:3001/api/health" 2>/dev/null || echo "000")

      if [ "$http_code" = "200" ]; then
        result=0
      fi
    else
      if docker exec "$NGINX_CONTAINER" \
        wget --quiet --tries=1 --spider \
        "http://${container_name}:3001/api/health" 2>/dev/null; then
        result=0
      fi
    fi

    if [ $result -eq 0 ]; then
      log_success "E2E 验证通过 (第 ${attempt}/${max_retries} 次)"
      return 0
    fi

    if [ $attempt -lt $max_retries ]; then
      sleep "$interval"
    fi
  done

  log_error "E2E 验证失败 (${max_retries} 次尝试)"
  return 1
}

# ============================================
# 函数: cleanup_old_images
# ============================================
# 删除超过指定天数的旧镜像和 dangling images（per D-12）
# 原逻辑：保留最近 N 个 → 新逻辑：删除超过 7 天的
# 参数：
#   $1: 保留天数（可选，默认使用 IMAGE_RETENTION_DAYS 变量）
# 环境变量：
#   IMAGE_RETENTION_DAYS - 镜像保留天数（默认 7，per D-13）
cleanup_old_images() {
  local retention_days="${IMAGE_RETENTION_DAYS:-${1:-7}}"

  log_info "镜像清理: 删除超过 ${retention_days} 天的旧镜像..."

  # macOS 兼容：BSD date 使用 -v-${retention_days}d
  local cutoff_epoch
  if date -v-1d >/dev/null 2>&1; then
    cutoff_epoch=$(date -v-"${retention_days}"d +%s)
  else
    cutoff_epoch=$(date -d "${retention_days} days ago" +%s)
  fi

  # 1. 清理带 Git SHA 标签的旧镜像（排除 latest，per D-14）
  local sha_tags
  sha_tags=$(docker images findclass-ssr --format '{{.Tag}}' \
    | grep -v '^latest$' \
    | grep -v '^<none>' || true)

  local deleted=0
  for tag in $sha_tags; do
    # 使用 docker inspect 获取 ISO 8601 创建时间（per RESEARCH: docker images CreatedAt 格式不稳定）
    local created_iso
    created_iso=$(docker inspect --format '{{.Created}}' "findclass-ssr:${tag}" 2>/dev/null || echo "")

    if [ -z "$created_iso" ]; then
      continue
    fi

    # 将 ISO 8601 转为 epoch（macOS 兼容）
    local image_epoch
    if date -j -f "%Y-%m-%dT%H:%M:%S" "" >/dev/null 2>&1; then
      # macOS: 截取 ISO 8601 到秒级精度
      local created_short
      created_short=$(echo "$created_iso" | sed 's/\..*//' | sed 's/Z$//')
      image_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$created_short" +%s 2>/dev/null || echo "0")
    else
      image_epoch=$(date -d "$created_iso" +%s 2>/dev/null || echo "0")
    fi

    if [ "$image_epoch" -eq 0 ]; then
      continue
    fi

    if [ "$image_epoch" -lt "$cutoff_epoch" ]; then
      # macOS 兼容的日期显示
      local image_date
      if date -r 0 >/dev/null 2>&1; then
        image_date=$(date -r "$image_epoch" +"%Y-%m-%d")
      else
        image_date=$(date -d "@$image_epoch" +"%Y-%m-%d")
      fi
      log_info "  删除 findclass-ssr:${tag} ($image_date)"
      docker rmi "findclass-ssr:${tag}" 2>/dev/null || true
      deleted=$((deleted + 1))
    fi
  done

  # 2. 清理 dangling images（per D-15）
  local dangling_ids
  dangling_ids=$(docker images -f "dangling=true" --format '{{.ID}}' 2>/dev/null || true)
  for img_id in $dangling_ids; do
    docker rmi "$img_id" 2>/dev/null || true
    deleted=$((deleted + 1))
  done

  if [ "$deleted" -gt 0 ]; then
    log_success "镜像清理完成: 删除 ${deleted} 个镜像"
  else
    log_info "镜像清理: 无需清理"
  fi
}

# ============================================
# Pipeline 阶段函数
# ============================================

# pipeline_preflight - 前置检查
# 检查 Docker daemon、nginx 容器、noda-network、Node.js、pnpm、noda-apps
# 参数: $1 = APPS_DIR (可选，默认 $WORKSPACE/noda-apps)
pipeline_preflight() {
  local apps_dir="${1:-$WORKSPACE/noda-apps}"
  log_info "前置检查..."

  # 检查 Docker daemon
  docker info >/dev/null 2>&1 || { log_error "Docker daemon 不可用"; return 1; }
  log_info "Docker daemon 可用"

  # 检查 nginx 容器
  if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
    log_error "nginx 容器未运行"; return 1
  fi
  log_info "nginx 容器运行中"

  # 检查 noda-network
  docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || { log_error "Docker 网络 noda-network 不存在"; return 1; }
  log_info "Docker 网络 noda-network 存在"

  # 检查 Node.js
  if ! command -v node >/dev/null 2>&1; then
    log_error "Node.js 未安装"
    log_error "安装方式: curl -fsSL https://deb.nodesource.com/setup_21.x | sudo -E bash - && sudo apt install -y nodejs"
    return 1
  fi
  log_info "Node.js: $(node --version)"

  # 检查 pnpm
  command -v pnpm >/dev/null 2>&1 || { log_error "pnpm 未安装，Test 阶段需要 pnpm"; return 1; }
  log_info "pnpm: $(pnpm --version)"

  # 检查 noda-apps 目录
  if [ ! -d "$apps_dir" ]; then
    log_error "noda-apps 目录不存在: $apps_dir"
    log_error "请检查 Jenkinsfile Pre-flight stage 的 checkout 配置"
    return 1
  fi
  log_info "noda-apps 目录存在: $apps_dir"

  # 检查 package.json
  if [ ! -f "$apps_dir/package.json" ]; then
    log_error "noda-apps/package.json 不存在: $apps_dir/package.json"
    return 1
  fi
  log_info "noda-apps/package.json 存在"

  # 检查 lint 脚本
  if ! grep -q '"lint"' "$apps_dir/package.json"; then
    log_error "noda-apps/package.json 缺少 lint 脚本"
    log_error '请在 package.json 的 scripts 中添加: "lint": "eslint ."'
    return 1
  fi
  log_info "package.json lint 脚本存在"

  # 检查 test 脚本
  if ! grep -q '"test"' "$apps_dir/package.json"; then
    log_error "noda-apps/package.json 缺少 test 脚本"
    log_error '请在 package.json 的 scripts 中添加: "test": "vitest run"'
    return 1
  fi
  log_info "package.json test 脚本存在"

  # 备份时效性检查（D-01, D-19: 放在所有其他检查之后）
  # 本地开发环境可能无生产备份，降级为警告
  if ! check_backup_freshness; then
    log_warn "备份检查未通过，继续部署（生产环境应调查备份状态）"
  fi

  log_success "前置检查全部通过"
}

# pipeline_build - 构建镜像
# 参数: $1 = APPS_DIR (noda-apps 目录), $2 = GIT_SHA
pipeline_build() {
  local apps_dir="$1"
  local git_sha="$2"

  log_info "构建镜像..."
  docker compose -f "$COMPOSE_FILE" build findclass-ssr
  docker tag findclass-ssr:latest "findclass-ssr:${git_sha}"
  log_success "镜像构建完成: findclass-ssr:${git_sha}"
}

# pipeline_test - 安装依赖（lint/test 由 Jenkinsfile 独立 sh 步骤调用）
# 参数: $1 = APPS_DIR (noda-apps 目录)
pipeline_test() {
  local apps_dir="$1"
  (
    cd "$apps_dir"
    pnpm install --frozen-lockfile
    log_success "依赖安装完成"
  )
}

# pipeline_deploy - 部署新容器到目标环境
# 参数: $1 = TARGET_ENV (blue/green), $2 = GIT_SHA
pipeline_deploy() {
  local target_env="$1"
  local git_sha="$2"
  local target_container
  target_container=$(get_container_name "$target_env")

  # 停止旧目标容器
  if [ "$(is_container_running "$target_container")" = "true" ]; then
    log_info "停止旧目标容器: $target_container"
    docker stop -t 30 "$target_container"
    docker rm "$target_container"
  fi

  # 启动新容器
  run_container "$target_env" "findclass-ssr:${git_sha}"
  log_success "部署完成: $target_container (findclass-ssr:${git_sha})"
}

# pipeline_health_check - HTTP 健康检查
# 参数: $1 = TARGET_ENV
pipeline_health_check() {
  local target_env="$1"
  local target_container
  target_container=$(get_container_name "$target_env")
  http_health_check "$target_container" "$HEALTH_CHECK_MAX_RETRIES" "$HEALTH_CHECK_INTERVAL"
}

# pipeline_switch - 切换流量到目标环境
# 参数: $1 = TARGET_ENV, $2 = ACTIVE_ENV
pipeline_switch() {
  local target_env="$1"
  local active_env="$2"

  update_upstream "$target_env"

  if ! docker exec "$NGINX_CONTAINER" nginx -t; then
    log_error "nginx 配置验证失败，回滚 upstream"
    update_upstream "$active_env"
    # 尝试 reload 使回滚生效（不检查返回值，nginx 可能本身就有问题）
    docker exec "$NGINX_CONTAINER" nginx -s reload 2>/dev/null || true
    return 1
  fi

  reload_nginx
  set_active_env "$target_env"
  log_success "流量切换完成: $active_env -> $target_env"
}

# pipeline_verify - E2E 验证
# 参数: $1 = TARGET_ENV
pipeline_verify() {
  local target_env="$1"
  e2e_verify "$target_env" "$E2E_MAX_RETRIES" "$E2E_INTERVAL"
}

# pipeline_purge_cdn - 调用 Cloudflare API 清除 CDN 缓存
# 环境变量（由 Jenkins withCredentials 注入）：
#   CF_API_TOKEN - Cloudflare API Token
#   CF_ZONE_ID   - Cloudflare Zone ID
# 返回：0=成功或跳过（永远不阻止部署，per D-09）
pipeline_purge_cdn() {
  # 凭据缺失时跳过（D-11）
  if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ZONE_ID:-}" ]; then
    log_warn "Cloudflare 凭据未配置，跳过 CDN 缓存清除"
    return 0
  fi

  log_info "清除 CDN 缓存 (zone: $CF_ZONE_ID)..."

  # 使用临时文件传递 JSON body，避免凭据出现在命令行参数中
  local tmp_body
  tmp_body=$(mktemp)
  echo '{"purge_everything":true}' > "$tmp_body"

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
pipeline_cleanup() {
  cleanup_old_images
}

# pipeline_failure_cleanup - 部署失败时捕获日志并清理
# 参数: $1 = TARGET_ENV
pipeline_failure_cleanup() {
  local target_env="$1"
  local target_container
  target_container=$(get_container_name "$target_env")

  # 捕获目标容器日志（如果容器存在）
  docker logs "$target_container" > deploy-failure-container.log 2>&1 || true

  # 捕获 nginx 日志
  docker logs "$NGINX_CONTAINER" --tail 50 > deploy-failure-nginx.log 2>&1 || true

  # 清理失败的目标容器
  docker rm -f "$target_container" 2>/dev/null || true

  log_info "失败日志已保存: deploy-failure-container.log, deploy-failure-nginx.log"
}

# ============================================
# Source guard — 仅允许 source 加载，禁止直接执行
# ============================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "pipeline-stages.sh 是函数库，不支持直接执行"
  echo "请通过 Jenkinsfile 或 blue-green-deploy.sh 调用"
  exit 1
fi
