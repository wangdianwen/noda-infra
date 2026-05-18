#!/bin/bash
# ============================================
# 容器健康检查库
# ============================================
# 提供容器健康状态轮询函数，供部署脚本复用
# 依赖：log.sh, remote-ops.sh（远程模式）
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 延迟加载 remote-ops.sh（仅在使用远程模式时需要）
# 避免循环依赖：pipeline-stages.sh 已加载 remote-ops.sh
if [ -f "$PROJECT_ROOT/scripts/lib/remote-ops.sh" ]; then
    source "$PROJECT_ROOT/scripts/lib/remote-ops.sh" 2>/dev/null || true
fi
source "$PROJECT_ROOT/scripts/lib/log.sh"

# wait_container_healthy - 等待容器健康检查通过
# 参数：
#   $1: 容器名
#   $2: 超时秒数（默认 90）
#   $3: 失败时是否打印日志（默认 true）
#   $4: 是否远程执行（默认 false，per D-14）
# 返回：0=健康，1=失败/超时
# 输出：通过 log_success/log_error 报告状态
wait_container_healthy()
{
    local container="$1"
    local timeout="${2:-90}"
    local show_logs="${3:-true}"
    local remote_mode="${4:-false}"  # 新增：是否远程执行
    local waited=0

    while [ $waited -lt $timeout ]; do
        local inspect
        local inspect_cmd="docker inspect --format='{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $container"

        if [ "$remote_mode" = true ]; then
            inspect=$(remote_exec "$inspect_cmd" 2>/dev/null || echo "missing|missing")
        else
            inspect=$(eval "$inspect_cmd" 2>/dev/null || echo "missing|missing")
        fi
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
                        [ "$show_logs" = true ] && \
                        if [ "$remote_mode" = true ]; then
                            remote_exec "docker logs $container --tail 15" | sed 's/^/  /'
                        else
                            docker logs "$container" --tail 15 2>&1 | sed 's/^/  /'
                        fi
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
            exited | dead)
                log_error "$container 状态异常: $status"
                [ "$show_logs" = true ] && \
                if [ "$remote_mode" = true ]; then
                    remote_exec "docker logs $container --tail 15" | sed 's/^/  /'
                else
                    docker logs "$container" --tail 15 2>&1 | sed 's/^/  /'
                fi
                return 1
                ;;
            *)
                sleep 3
                waited=$((waited + 3))
                ;;
        esac
    done

    log_error "$container — 健康检查超时（${timeout}s）"
    [ "$show_logs" = true ] && \
    if [ "$remote_mode" = true ]; then
        remote_exec "docker logs $container --tail 15" | sed 's/^/  /'
    else
        docker logs "$container" --tail 15 2>&1 | sed 's/^/  /'
    fi
    return 1
}
