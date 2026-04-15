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
# 从 blue-green-deploy.sh 复制（该文件无 source guard，不能 source）
# 保留最近 N 个带标签的镜像，删除更早的
# 参数:
#   $1: 保留数量（默认 5）
cleanup_old_images() {
  local keep_count="${1:-5}"

  # 列出所有非 latest 标签的镜像，按创建时间排序（最新在前）
  local images
  images=$(docker images findclass-ssr --format '{{.Tag}} {{.CreatedAt}}' \
    | grep -v '^latest ' \
    | sort -t' ' -k2 -r \
    | awk '{print $1}')

  local total
  total=$(echo "$images" | grep -c . || true)

  if [ "$total" -le "$keep_count" ]; then
    log_info "镜像清理: ${total} 个标签镜像 <= 保留 ${keep_count}，无需清理"
    return 0
  fi

  local to_delete
  to_delete=$(echo "$images" | tail -n +$((keep_count + 1)))

  log_info "镜像清理: ${total} 个标签镜像，保留 ${keep_count}，删除 $((total - keep_count)) 个"

  for tag in $to_delete; do
    log_info "  删除 findclass-ssr:${tag}"
    docker rmi "findclass-ssr:${tag}" 2>/dev/null || true
  done

  log_success "旧镜像清理完成"
}

# ============================================
# Pipeline 阶段函数
# ============================================

# pipeline_preflight - 前置检查
# 检查 Docker daemon、nginx 容器、noda-network、pnpm
pipeline_preflight() {
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

  # 检查 pnpm
  command -v pnpm >/dev/null 2>&1 || { log_error "pnpm 未安装，Test 阶段需要 pnpm"; return 1; }
  log_info "pnpm 可用"

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
  cd "$apps_dir"
  pnpm install --frozen-lockfile
  log_success "依赖安装完成"
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

# pipeline_cleanup - 清理旧镜像
pipeline_cleanup() {
  cleanup_old_images 5
}

# pipeline_failure_cleanup - 部署失败时捕获日志并清理
# 参数: $1 = TARGET_ENV
pipeline_failure_cleanup() {
  local target_env="$1"
  local target_container="findclass-ssr-${target_env}"

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
