#!/bin/bash
# ============================================
# 容器健康检查库
# ============================================
# 提供容器健康状态轮询函数，供部署脚本复用
# 依赖：log.sh
# ============================================

# wait_container_healthy - 等待容器健康检查通过
# 参数：
#   $1: 容器名
#   $2: 超时秒数（默认 90）
#   $3: 失败时是否打印日志（默认 true）
# 返回：0=健康，1=失败/超时
# 输出：通过 log_success/log_error 报告状态
wait_container_healthy() {
  local container="$1"
  local timeout="${2:-90}"
  local show_logs="${3:-true}"
  local waited=0

  while [ $waited -lt $timeout ]; do
    local inspect
    inspect=$(docker inspect --format='{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo "missing|missing")
    local status="${inspect%%|*}"
    local health="${inspect##*|}"

    case "$status" in
      running)
        case "$health" in
          healthy)
            log_success "$container — healthy"
            return 0
            ;;
          unhealthy)
            log_error "$container — unhealthy"
            [ "$show_logs" = true ] && docker logs "$container" --tail 15 2>&1 | sed 's/^/  /'
            return 1
            ;;
          starting)
            sleep 3
            waited=$((waited + 3))
            ;;
          none)
            log_success "$container — 运行中"
            return 0
            ;;
        esac
        ;;
      missing)
        log_error "$container 不存在"
        return 1
        ;;
      exited|dead)
        log_error "$container 状态异常: $status"
        [ "$show_logs" = true ] && docker logs "$container" --tail 15 2>&1 | sed 's/^/  /'
        return 1
        ;;
      *)
        sleep 3
        waited=$((waited + 3))
        ;;
    esac
  done

  log_error "$container — 健康检查超时（${timeout}s）"
  [ "$show_logs" = true ] && docker logs "$container" --tail 15 2>&1 | sed 's/^/  /'
  return 1
}
