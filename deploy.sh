#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 自动部署脚本
# ============================================

set -e

IMAGE_NAME="noda-backup"
CONTAINER_NAME="opdev"
BACKUP_DIR="$PWD/deploy/volumes/backup"
HISTORY_DIR="$PWD/deploy/volumes/history"
LOG_DIR="$PWD/deploy/volumes/logs"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/log.sh"

check_environment() {
  log_info "检查部署环境..."
  if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker 未安装"
    exit 1
  fi
  if [ ! -f "scripts/backup/.env.backup" ]; then
    log_error "配置文件不存在: scripts/backup/.env.backup"
    exit 1
  fi
  mkdir -p "$BACKUP_DIR" "$HISTORY_DIR" "$LOG_DIR"
  log_info "✓ 环境检查通过"
}

build_image() {
  log_info "构建 Docker 镜像: $IMAGE_NAME"
  docker build -f deploy/Dockerfile.backup -t "$IMAGE_NAME:latest" .
  log_info "✓ 镜像构建完成"
}

start_container() {
  log_info "启动容器: $CONTAINER_NAME"
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_warn "容器已存在，先删除"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi

  set -a
  source scripts/backup/.env.backup

  # 如果配置文件中没有密码，尝试从环境变量读取
  if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
    export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
  fi
  set +a

  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network noda-network \
    -e POSTGRES_HOST="$POSTGRES_HOST" \
    -e POSTGRES_PORT="$POSTGRES_PORT" \
    -e POSTGRES_USER="$POSTGRES_USER" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}" \
    -e B2_ACCOUNT_ID="$B2_ACCOUNT_ID" \
    -e B2_APPLICATION_KEY="$B2_APPLICATION_KEY" \
    -e B2_BUCKET_NAME="$B2_BUCKET_NAME" \
    -e ALERT_EMAIL="${ALERT_EMAIL:-}" \
    -v "$BACKUP_DIR:/tmp/postgres_backups" \
    -v "$HISTORY_DIR:/app/history" \
    -v "$LOG_DIR:/var/log/noda-backup" \
    "$IMAGE_NAME:latest"

  log_info "✓ 容器启动完成"
}

stop_container() {
  log_info "停止容器: $CONTAINER_NAME"
  docker stop "$CONTAINER_NAME" 2>/dev/null || log_warn "容器未运行"
}

show_status() {
  log_info "容器状态:"
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "状态: 运行中 ✓"
    docker ps --filter "name=$CONTAINER_NAME" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
  else
    echo "状态: 未运行 ✗"
  fi
}

main() {
  case "${1:-}" in
    build) check_environment; build_image ;;
    start) check_environment; start_container; show_status ;;
    stop) stop_container ;;
    restart) stop_container; sleep 2; check_environment; start_container; show_status ;;
    logs) docker logs -f "$CONTAINER_NAME" ;;
    status) show_status ;;
    clean) docker rm -f "$CONTAINER_NAME" 2>/dev/null || true; log_info "✓ 清理完成" ;;
    *)
      echo "用法: $0 {build|start|stop|restart|logs|status|clean}"
      exit 1
      ;;
  esac
}

main "$@"
