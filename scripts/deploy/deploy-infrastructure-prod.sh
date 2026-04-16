#!/bin/bash
# ============================================
# 手动回退部署脚本（生产环境）
# ============================================
# NOTE: 此脚本作为 Jenkins Pipeline 不可用时的紧急回退方案保留。
# 正常部署请使用 Jenkins Pipeline（Build Now -> findclass-deploy）。
#
# 原有功能：自动部署并配置基础设施服务
# 包括：PostgreSQL, Keycloak, Nginx, Noda-Ops, Findclass-SSR
#
# 此脚本行为不变，可直接手动执行。
# ============================================
set -euo pipefail

# ============================================
# 基础设施部署脚本（生产环境）
# ============================================
# 功能：自动部署并配置基础设施服务
# 包括：PostgreSQL, Keycloak, Nginx, Noda-Ops, Findclass-SSR
# ============================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/health.sh"

# 解析命令行参数
SKIP_BACKUP=false
for arg in "$@"; do
  case "$arg" in
    --skip-backup) SKIP_BACKUP=true ;;
  esac
done

# 回滚目录和文件
ROLLBACK_DIR="/tmp/noda-rollback"
ROLLBACK_FILE="$ROLLBACK_DIR/images-$(date +%s).txt"
ROLLBACK_COMPOSE="$ROLLBACK_DIR/docker-compose.rollback.yml"

# 注意：此变量故意不加引号使用，依赖 word splitting 拆分为多个 -f 参数
COMPOSE_FILES="-f docker/docker-compose.yml -f docker/docker-compose.prod.yml"

EXPECTED_CONTAINERS=(
  "noda-infra-postgres-prod"
  "noda-infra-keycloak-prod"
  "noda-infra-nginx"
  "noda-ops"
  "findclass-ssr"
)

# 启动的服务列表（findclass-ssr 需要单独启动，来自 docker-compose.app.yml）
START_SERVICES="postgres keycloak nginx noda-ops"

# ============================================
# 镜像回滚函数 (D-05)
# ============================================

# save_image_tags - 保存当前运行容器的镜像 digest
# 参数：无（保存到 ROLLBACK_FILE）
# 返回：0=成功
save_image_tags() {
  mkdir -p "$ROLLBACK_DIR"
  : > "$ROLLBACK_FILE"
  for container in "${EXPECTED_CONTAINERS[@]}"; do
    local image_id
    image_id=$(docker inspect --format='{{.Image}}' "$container" 2>/dev/null || echo "")
    if [ -n "$image_id" ]; then
      echo "${container}=${image_id}" >> "$ROLLBACK_FILE"
      log_info "已保存 ${container} 的镜像: ${image_id:0:12}..."
    fi
  done
  log_success "镜像标签已保存到 ${ROLLBACK_FILE}"
}

# rollback_images - 使用 docker compose override 回退到保存的镜像版本
# 参数：无（从 ROLLBACK_FILE 读取镜像 digest）
# 返回：0=成功，1=失败
#
# 原理：生成临时 docker-compose.rollback.yml，其中每个服务的 image 字段
# 设为保存的 digest。然后通过 docker compose -f base -f prod -f rollback
# up -d --no-deps --force-recreate 恢复服务，保留所有 compose 管理的配置。
#
# 容器名到服务名映射（因为 container_name 与 service name 不同）：
#   noda-infra-postgres-prod  -> postgres
#   noda-infra-keycloak-prod  -> keycloak
#   noda-infra-nginx          -> nginx
#   noda-ops                  -> noda-ops
#   findclass-ssr             -> findclass-ssr
rollback_images() {
  if [ ! -f "$ROLLBACK_FILE" ]; then
    log_error "回滚文件不存在: ${ROLLBACK_FILE}"
    return 1
  fi

  # 容器名 -> compose 服务名映射（兼容 bash 3.2，不使用 declare -A）
  container_to_service() {
    case "$1" in
      noda-infra-postgres-prod) echo "postgres" ;;
      noda-infra-keycloak-prod) echo "keycloak" ;;
      noda-infra-nginx) echo "nginx" ;;
      noda-ops) echo "noda-ops" ;;
      findclass-ssr) echo "findclass-ssr" ;;
      *) echo "" ;;
    esac
  }

  log_info "开始生成回滚 compose override..."

  # 生成 rollback compose override 文件
  cat > "$ROLLBACK_COMPOSE" <<'YAML_HEADER'
# 自动生成的回滚 overlay — 恢复到部署前的镜像版本
name: noda-infra
services:
YAML_HEADER

  local has_entries=false
  while IFS='=' read -r container image_id; do
    [ -z "$container" ] && continue
    local service
    service="$(container_to_service "$container")"
    if [ -z "$service" ]; then
      log_info "跳过未映射的容器: ${container}"
      continue
    fi
    echo "  ${service}:" >> "$ROLLBACK_COMPOSE"
    echo "    image: ${image_id}" >> "$ROLLBACK_COMPOSE"
    has_entries=true
    log_info "回滚 ${service} 到镜像 ${image_id:0:12}..."
  done < "$ROLLBACK_FILE"

  if [ "$has_entries" = false ]; then
    log_error "没有可回滚的服务"
    return 1
  fi

  log_info "执行 docker compose 回滚..."
  if ! docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f "$ROLLBACK_COMPOSE" up -d --no-deps --force-recreate; then
    log_error "docker compose 回滚失败"
    return 1
  fi

  log_success "回滚完成（使用 compose override 恢复）"
  return 0
}

# ============================================
# 部署前备份检查函数 (D-06)
# ============================================

# check_recent_backup - 检查最近备份是否在 12 小时内
# 参数：无（检查 noda-ops 容器内的 history.json）
# 返回：0=备份足够新（跳过），1=需要备份
check_recent_backup() {
  local history_json
  history_json=$(docker exec noda-ops cat /app/history/history.json 2>/dev/null || echo "")

  if [ -z "$history_json" ]; then
    log_info "无备份历史记录，需要执行备份"
    return 1
  fi

  local last_backup_ts
  last_backup_ts=$(echo "$history_json" | jq -r '
    [(. // []) | select(.operation=="backup" and .duration > 0)] |
    sort_by(.timestamp) | reverse |
    .[0].timestamp // empty
  ' 2>/dev/null || echo "")

  if [ -z "$last_backup_ts" ]; then
    log_info "无成功备份记录，需要执行备份"
    return 1
  fi

  # 计算备份时间差（兼容 macOS 和 Linux）
  local last_epoch now_epoch age
  if date -u -v0S +%s >/dev/null 2>&1; then
    # macOS
    last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${last_backup_ts%%.*}Z" +%s 2>/dev/null || echo "0")
  else
    # Linux
    last_epoch=$(date -d "${last_backup_ts%%.*}Z" +%s 2>/dev/null || echo "0")
  fi
  now_epoch=$(date +%s)
  age=$((now_epoch - last_epoch))

  local threshold_seconds=43200  # 12 hours

  if [ "$age" -lt "$threshold_seconds" ]; then
    local age_hours=$((age / 3600))
    log_success "最近备份在 ${age_hours} 小时前，跳过部署前备份"
    return 0
  else
    log_info "最近备份超过 12 小时前，需要执行备份"
    return 1
  fi
}

# run_pre_deploy_backup - 执行部署前备份
# 参数：无
# 返回：0=成功，1=失败
run_pre_deploy_backup() {
  log_info "执行部署前数据库备份..."
  if ! docker exec noda-ops /app/backup/backup-postgres.sh; then
    log_error "部署前备份失败"
    return 1
  fi
  log_success "部署前备份完成"
  return 0
}

# ============================================
# 步骤 1/7: 验证环境
# ============================================
log_info "=========================================="
log_info "步骤 1/7: 验证环境配置"
log_info "=========================================="

if [ ! -f "config/secrets.sops.yaml" ]; then
  log_error "加密配置文件不存在: config/secrets.sops.yaml"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  log_error "Docker 未安装"
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  log_error "Docker Compose 未安装"
  exit 1
fi

log_success "环境验证通过"

# ============================================
# 步骤 2/7: 保存当前镜像标签 (D-05)
# ============================================
log_info "=========================================="
log_info "步骤 2/7: 保存当前镜像标签"
log_info "=========================================="

save_image_tags

# ============================================
# 步骤 3/7: 部署前自动备份 (D-06)
# ============================================
log_info "=========================================="
log_info "步骤 3/7: 部署前自动备份"
log_info "=========================================="

if ! check_recent_backup; then
  if [ "$SKIP_BACKUP" = true ]; then
    log_info "已通过 --skip-backup 跳过部署前备份"
  elif ! run_pre_deploy_backup; then
    log_error "部署前备份失败，中止部署"
    exit 1
  fi
fi

# ============================================
# 步骤 4/7: 重启容器
# ============================================
log_info "=========================================="
log_info "步骤 4/7: 重启容器"
log_info "=========================================="

log_info "停止现有容器..."
docker compose $COMPOSE_FILES down

log_info "启动 PostgreSQL, Keycloak, Nginx, Noda-Ops, Findclass-SSR..."
docker compose $COMPOSE_FILES up -d $START_SERVICES findclass-ssr

log_success "容器已启动"

# ============================================
# 步骤 5/7: 等待所有服务健康 + 初始化数据库
# ============================================
log_info "=========================================="
log_info "步骤 5/7: 等待所有服务健康"
log_info "=========================================="

HEALTH_TIMEOUT=90

for container in "${EXPECTED_CONTAINERS[@]}"; do
  if ! wait_container_healthy "$container" "$HEALTH_TIMEOUT"; then
    log_info "尝试回滚到上一版本..."
    rollback_images || true
    exit 1
  fi
done

# 容器健康后初始化数据库
log_info "初始化数据库..."
if ! bash scripts/init-databases.sh; then
  log_error "数据库初始化失败"
  exit 1
fi
log_success "数据库初始化完成"

# ============================================
# 步骤 6/7: 配置 Keycloak
# ============================================
log_info "=========================================="
log_info "步骤 6/7: 配置 Keycloak"
log_info "=========================================="

log_info "配置 realm, client 和 Google OAuth..."
if ! bash scripts/setup-keycloak-full.sh; then
  log_error "Keycloak 配置失败"
  log_info "尝试回滚到上一版本..."
  rollback_images || true
  exit 1
fi
log_success "Keycloak 配置完成"

# ============================================
# 步骤 7/7: 最终验证（重启次数）
# ============================================
log_info "=========================================="
log_info "步骤 7/7: 最终验证"
log_info "=========================================="

RESTART_ISSUES=0
for container in "${EXPECTED_CONTAINERS[@]}"; do
  RESTARTS=$(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo "0")
  if [ "$RESTARTS" -gt 10 ]; then
    log_error "$container — 已重启 ${RESTARTS} 次，可能存在异常"
    docker logs "$container" --tail 5 2>&1 | sed 's/^/  /'
    RESTART_ISSUES=$((RESTART_ISSUES + 1))
  elif [ "$RESTARTS" -gt 3 ]; then
    log_info "$container — 重启 ${RESTARTS} 次（启动期正常行为）"
  fi
done

if [ $RESTART_ISSUES -gt 0 ]; then
  log_error "$RESTART_ISSUES 个容器频繁重启，请检查日志"
  log_info "尝试回滚到上一版本..."
  rollback_images || true
  exit 1
fi

log_success "所有容器验证通过"

# ============================================
# 部署完成
# ============================================
log_success "=========================================="
log_success "基础设施部署完成！"
log_success "=========================================="
log_info "✓ PostgreSQL (Prod): 运行中"
log_info "✓ Keycloak: 运行中（已配置 realm 和 Google OAuth）"
log_info "✓ Nginx: 运行中"
log_info "✓ Noda-Ops: 运行中"
log_info "✓ Findclass-SSR: 运行中"
log_info ""
log_info "访问地址："
log_info "  管理控制台: https://auth.noda.co.nz/admin"
log_info "  Realm 端点: https://auth.noda.co.nz/realms/noda"
log_info "回滚文件: ${ROLLBACK_FILE}（部署成功，可安全忽略）"
log_success "=========================================="
