# Phase 22: 蓝绿部署核心流程 - Research

**Researched:** 2026-04-15
**Domain:** Bash 脚本编写 + Docker 蓝绿部署 + Nginx 流量切换
**Confidence:** HIGH

## Summary

Phase 22 需要编写两个 bash 脚本：`blue-green-deploy.sh`（主部署脚本）和 `rollback-findclass.sh`（紧急回滚脚本）。这两个脚本将 source 复用 Phase 21 产出的 `manage-containers.sh` 中的函数（`run_container`, `update_upstream`, `reload_nginx`, `get_active_env`, `get_inactive_env`），实现完整的蓝绿部署生命周期。

核心挑战在于：（1）构建后用 `docker tag` 添加 Git SHA 短哈希标签替代 latest；（2）通过 `docker exec` 在目标容器内执行 `wget` 进行 HTTP 健康检查（容器基于 `node:20-alpine`，只有 wget 没有 curl）；（3）流量切换后通过 nginx 容器内部 curl 执行 E2E 验证，确认完整请求链路。脚本需要在任何步骤失败时自动防护，不切换流量、不停止旧容器。

**Primary recommendation:** 严格复用 `manage-containers.sh` 已有函数，部署脚本只负责编排流程和新增 HTTP 直检/E2E 验证逻辑。健康检查用 `docker exec wget`，E2E 验证用 `docker exec nginx curl`。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 部署脚本使用 **HTTP 直检** — 通过 `docker exec` 在目标容器内部执行 wget/curl 检测 `http://localhost:3001/api/health`
- **D-02:** 不复用 `wait_container_healthy()`（Docker inspect healthcheck），部署脚本有独立的 HTTP 检查逻辑，超时参数更灵活（建议 120 秒，30 次 x 4 秒，覆盖 SSR 冷启动）
- **D-03:** Docker healthcheck（Phase 21 配置的 `--health-cmd wget`）作为容器长期监控，与部署脚本的 HTTP 直检是两套独立机制
- **D-04:** 目标环境**自动检测** — 脚本读取 `/opt/noda/active-env` 获取当前活跃环境，自动部署到非活跃侧
- **D-05:** **当前目录构建** — 脚本在 noda-apps 代码目录执行，从 `.git` 获取 SHA
- **D-06:** 通过 **source 复用** `manage-containers.sh` 的函数
- **D-07:** `rollback-findclass.sh` 执行**切回上一容器**
- **D-08:** 回滚流程：验证旧容器运行中 → 更新 upstream → reload nginx → 更新 active-env → 停止新版本容器
- **D-09:** 旧镜像保留策略：**保留最近 N 个**带标签的镜像（建议 N=5）
- **D-10:** 镜像标签使用 **Git SHA 短哈希 7 字符**
- **D-11:** 构建命令使用 **docker compose build**
- **D-12:** 构建失败时脚本立即中止（`set -e` 自然行为）

### Claude's Discretion
- HTTP 健康检查的具体实现细节（重试间隔、超时参数、失败日志输出）
- E2E 验证的 curl 端点和判断逻辑
- 保留镜像数量 N 的默认值
- 脚本的步骤日志格式和进度输出
- rollback-findclass.sh 的参数设计

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PIPE-02 | 每次构建的镜像使用 Git SHA 短哈希标签，替代 latest | D-10/D-11 已锁定：`git rev-parse --short HEAD` 获取 7 字符 SHA，构建后 `docker tag` 添加标签 |
| PIPE-03 | 构建阶段失败时自动中止 Pipeline，不进入部署阶段 | D-12 已锁定：`set -euo pipefail` 自然中止，构建和部署需分阶段 |
| TEST-03 | 部署后对目标容器执行 HTTP 健康检查，最多重试 10 次每次间隔 5 秒 | D-01/D-02 已锁定：`docker exec` + wget 直检，但 CONTEXT.md 建议 120s/30x4s，需协调需求与决策 |
| TEST-04 | 流量切换后通过 nginx 执行 E2E 验证，确认完整请求链路正常 | nginx 容器内有 curl，可通过 `docker exec nginx curl` 验证 |
| TEST-05 | 健康检查或 E2E 验证失败时，不切换流量、不停止旧容器 | D-07/D-08 已锁定回滚策略，脚本需在每个关键步骤后检查结果 |
</phase_requirements>

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| bash | 5.x | 脚本执行环境 | 项目所有脚本的标准环境，`set -euo pipefail` 严格模式 |
| Docker Compose | v2.40.3 | 构建镜像 | `docker compose build` 是项目标准构建方式 [VERIFIED: 本机] |
| Docker CLI | 24+ | 容器管理 + exec | `docker exec`, `docker tag`, `docker inspect` 等 [VERIFIED: 本机] |
| wget (BusyBox) | 内置于 node:20-alpine | 容器内 HTTP 健康检查 | `node:20-alpine` 自带 BusyBox wget，`--spider` 模式只检查不下载 [VERIFIED: 本机测试] |

### Supporting
| Tool | Location | Purpose | When to Use |
|------|----------|---------|-------------|
| log.sh | scripts/lib/ | 统一日志输出 | 所有脚本必须 source |
| manage-containers.sh | scripts/ | 蓝绿容器管理函数库 | source 复用 `run_container()`, `update_upstream()` 等 |
| health.sh | scripts/lib/ | Docker inspect 健康检查 | 仅参考模式，部署脚本不复用此函数 |
| nginx -t | nginx 容器内 | 配置验证 | 每次 reload 前必须验证，已有模式见 manage-containers.sh:482 |
| curl | nginx 容器内 | E2E 验证 | nginx:1.25-alpine 包含 curl，用于流量切换后端到端验证 [ASSUMED] |

### Key Environment Facts
| Fact | Value | Source |
|------|-------|--------|
| `git rev-parse --short HEAD` 输出长度 | 7 字符（默认） | [VERIFIED: 本机测试输出 `8f52cf7`] |
| findclass-ssr 基础镜像 | `node:20-alpine` | [VERIFIED: Dockerfile.findclass-ssr:92] |
| node:20-alpine 中的 wget | `/usr/bin/wget` (BusyBox) | [VERIFIED: 本机 docker run 测试] |
| node:20-alpine 中的 curl | 不可用 | [VERIFIED: 本机 docker run 测试] |
| 宿主机 curl | `/usr/bin/curl` | [VERIFIED: 本机 which curl] |
| docker compose build 默认镜像名 | `findclass-ssr:latest`（来自 compose image 字段） | [VERIFIED: docker-compose.app.yml:27] |
| compose file 中 findclass-ssr 的 build context | `../../noda-apps` | [VERIFIED: docker-compose.app.yml:21] |

## Architecture Patterns

### 推荐的项目结构
```
scripts/
├── blue-green-deploy.sh      # Phase 22 新增 — 主部署脚本
├── rollback-findclass.sh     # Phase 22 新增 — 紧急回滚脚本
├── manage-containers.sh      # Phase 21 产出 — source 复用的函数库
└── lib/
    ├── log.sh                # 统一日志
    └── health.sh             # Docker inspect 健康检查（参考，不复用）
```

### Pattern 1: 分阶段部署编排
**What:** 部署脚本按严格阶段顺序执行，每阶段有明确的成功/失败判定
**When to use:** 蓝绿部署主脚本 `blue-green-deploy.sh`

**流程编排：**
```
构建 → tag → 停止旧目标容器 → 启动新目标容器 → HTTP 健康检查 → 切换流量 → E2E 验证 → 完成
  │                                                              │
  └── 失败 → 脚本中止（旧容器不变）                                └── 失败 → 自动回滚（切回旧容器）
```

**关键：** 每个阶段通过函数封装，函数返回非零时由 `set -e` 触发退出。但需要注意 `set -e` 在某些上下文中不会触发（如 `if` 条件、`&&` 链、管道），所以关键步骤应使用显式 `if ! func; then ... exit 1; fi` 模式。

### Pattern 2: HTTP 直检（不走 Docker healthcheck）
**What:** 通过 `docker exec` 在目标容器内执行 wget，直接探测 HTTP 端点
**When to use:** 部署后验证新容器应用就绪

**Example:**
```bash
# Source: 基于 CONTEXT.md D-01/D-02 决策 + node:20-alpine 可用工具验证
http_health_check() {
  local container="$1"
  local max_retries="${2:-30}"
  local interval="${3:-4}"
  local url="http://localhost:3001/api/health"

  for i in $(seq 1 "$max_retries"); do
    if docker exec "$container" wget --quiet --tries=1 --spider "$url" 2>/dev/null; then
      log_success "HTTP 健康检查通过: $container (第 ${i} 次尝试)"
      return 0
    fi
    log_info "等待应用就绪... ($i/$max_retries)"
    sleep "$interval"
  done

  log_error "HTTP 健康检查失败: $container (${max_retries} 次重试后)"
  docker logs "$container" --tail 20 2>&1 | sed 's/^/  /'
  return 1
}
```

**注意：** `docker exec` 在容器 `running` 但应用尚未监听端口时会返回非零，这正是期望的行为。

### Pattern 3: E2E 验证（通过 nginx 容器 curl）
**What:** 流量切换后，从 nginx 容器内部 curl 目标容器，验证完整请求链路
**When to use:** 流量切换后、回滚前

**Example:**
```bash
# Source: 基于项目架构 — nginx 容器可以通过 Docker DNS 访问蓝绿容器
e2e_verify() {
  local target_env="$1"
  local container_name
  container_name=$(get_container_name "$target_env")
  local max_retries="${2:-5}"
  local interval="${3:-2}"

  for i in $(seq 1 "$max_retries"); do
    local http_code
    http_code=$(docker exec "$NGINX_CONTAINER" \
      curl -s -o /dev/null -w "%{http_code}" \
      "http://${container_name}:3001/api/health" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ]; then
      log_success "E2E 验证通过: nginx -> $container_name (HTTP 200)"
      return 0
    fi
    log_info "E2E 验证重试... ($i/$max_retries, HTTP: $http_code)"
    sleep "$interval"
  done

  log_error "E2E 验证失败: nginx -> $container_name"
  return 1
}
```

**备选方案：** 如果 nginx:1.25-alpine 中没有 curl（需要验证），可以改用 `docker exec nginx wget -q --spider http://findclass-ssr-{color}:3001/api/health`。

### Pattern 4: 镜像标签管理
**What:** 构建后用 `docker tag` 为镜像添加 Git SHA 短哈希标签
**When to use:** 每次构建后

```bash
# Source: CONTEXT.md D-10/D-11
# docker compose build 产出 findclass-ssr:latest
# 然后用 docker tag 添加 SHA 标签
SHORT_SHA=$(git -C "$APPS_DIR" rev-parse --short HEAD)  # 7 字符
docker tag findclass-ssr:latest "findclass-ssr:${SHORT_SHA}"
```

**注意：** `docker tag` 创建的是引用（不是复制），所以不占额外磁盘空间。多个标签指向同一个 image ID。

### Anti-Patterns to Avoid
- **不要在 docker exec 中使用管道不加 `set -o pipefail`**：管道中任一命令失败可能被忽略
- **不要用 `set -e` 保护所有场景**：`set -e` 在 `if`、`&&`、`||` 链中不触发，关键失败路径需要显式检查
- **不要在构建前停止旧容器**：蓝绿部署的核心是"先启新再停旧"，构建失败时旧容器必须保持运行
- **不要忽略 nginx -t 验证**：`manage-containers.sh` 的 `cmd_switch` 已有 `nginx -t` 验证模式（第 482 行），reload 前必须验证
- **不要复用 `wait_container_healthy`**：D-02 已锁定不复用，部署脚本需要自己的 HTTP 直检逻辑

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 容器启停 | 自己写 docker run 命令 | `manage-containers.sh` 的 `run_container()` | 已包含完整安全参数（no-new-privileges/cap-drop/read-only/memory/cpu） |
| upstream 切换 | 自己写配置文件操作 | `manage-containers.sh` 的 `update_upstream()` | 原子写入（tmpfile + mv），已有验证模式 |
| nginx reload | 自己写 docker exec nginx -s reload | `manage-containers.sh` 的 `reload_nginx()` | 已包含容器运行检查 |
| 活跃环境读取 | 自己读文件 | `manage-containers.sh` 的 `get_active_env()` / `get_inactive_env()` | 已处理文件不存在默认值 |
| 日志输出 | 自己写 echo/printf | `scripts/lib/log.sh` | 统一颜色和格式 |

**Key insight:** Phase 21 已经完成了蓝绿容器管理的底层函数，Phase 22 只需要编排这些函数 + 新增 HTTP 直检和 E2E 验证逻辑。不要重复实现容器管理。

## Common Pitfalls

### Pitfall 1: TEST-03 需求与 CONTEXT.md D-02 参数不一致
**What goes wrong:** REQUIREMENTS.md TEST-03 要求"最多重试 10 次每次间隔 5 秒"（50 秒），但 CONTEXT.md D-02 建议"120 秒，30 次 x 4 秒"
**Why it happens:** 需求定义时未考虑 SSR 冷启动时间，Phase 21 实测发现 SSR 启动需要更长时间
**How to avoid:** 以 CONTEXT.md D-02 为准（它是对需求的专业修正），120 秒超时覆盖 SSR 冷启动场景。需求中"10 次每次 5 秒"可能是概念性的，实际参数由 D-02 决定
**Warning signs:** SSR 启动时间可能随数据量增长而增加

### Pitfall 2: `set -e` 在 source 函数中不总是触发
**What goes wrong:** 当 source 的函数在 `if` 或 `||` 条件中使用时，`set -e` 不会触发退出
**Why it happens:** bash 的 `set -e` 在复合命令中有特殊豁免规则
**How to avoid:** 关键步骤使用显式 `if ! func; then ... exit 1; fi` 模式，不依赖 `set -e` 自动退出
**Warning signs:** 函数返回非零但脚本继续执行

### Pitfall 3: docker compose build 使用 BuildKit 缓存
**What goes wrong:** Dockerfile 修改后 `docker compose build` 可能使用缓存的旧层
**Why it happens:** BuildKit 默认启用缓存
**How to avoid:** 考虑在蓝绿部署脚本中提供 `--no-cache` 选项，或在关键修改后强制无缓存构建
**Warning signs:** 构建很快完成但运行的是旧代码（CLAUDE.md 已记录此问题）

### Pitfall 4: 容器 DNS 解析延迟
**What goes wrong:** 新启动的容器在 Docker 网络中可能需要几秒才被 DNS 解析
**Why it happens:** Docker 内置 DNS 的更新不是即时的
**How to avoid:** 健康检查的重试机制自然覆盖了 DNS 延迟（120 秒超时足够）
**Warning signs:** 首次 wget/curl 立即失败但几秒后成功

### Pitfall 5: E2E 验证时机（在 nginx reload 之后）
**What goes wrong:** E2E 验证在 nginx reload 完成前执行，请求还走旧 upstream
**Why it happens:** nginx reload 是异步的，配置生效有微小延迟
**How to avoid:** reload 后短暂等待（1-2 秒）再执行 E2E 验证，或在验证函数中加入重试
**Warning signs:** E2E 验证首次失败但重试后成功

### Pitfall 6: 回滚脚本找不到旧容器
**What goes wrong:** `rollback-findclass.sh` 执行时旧容器已被停止/删除
**Why it happens:** 如果部署脚本正常完成，它会停止旧容器；或者旧容器被手动清理
**How to avoid:** 回滚脚本必须首先检查旧容器是否存在且在运行，如果不存在则给出明确错误信息，不要盲目执行
**Warning signs:** `docker inspect` 返回空/错误

## Code Examples

### blue-green-deploy.sh 核心骨架

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/manage-containers.sh" 2>/dev/null || true
# 注意：manage-containers.sh 末尾有 case 语句，source 时会执行子命令分发
# 需要确保 source 时不会触发子命令执行

# ... 函数定义 ...

main() {
  # 1. 读取当前活跃环境
  local active_env
  active_env=$(get_active_env)
  local target_env
  target_env=$(get_inactive_env)

  # 2. 构建镜像
  local apps_dir="${1:-.}"  # noda-apps 目录，默认当前目录
  local short_sha
  short_sha=$(git -C "$apps_dir" rev-parse --short HEAD)

  log_info "构建镜像: findclass-ssr:${short_sha}"
  docker compose -f "$PROJECT_ROOT/docker/docker-compose.app.yml" build findclass-ssr

  # 3. 添加 SHA 标签
  docker tag findclass-ssr:latest "findclass-ssr:${short_sha}"

  # 4. 停止旧的目标容器（如果存在）
  local target_container
  target_container=$(get_container_name "$target_env")
  if [ "$(is_container_running "$target_container")" = "true" ]; then
    docker stop -t 30 "$target_container"
    docker rm "$target_container"
  fi

  # 5. 启动新容器
  run_container "$target_env" "findclass-ssr:${short_sha}"

  # 6. HTTP 健康检查
  if ! http_health_check "$target_container"; then
    log_error "健康检查失败，保持当前环境: $active_env"
    # 不切换流量，不停止旧容器
    exit 1
  fi

  # 7. 切换流量
  update_upstream "$target_env"
  if ! docker exec "$NGINX_CONTAINER" nginx -t; then
    log_error "nginx 配置验证失败"
    update_upstream "$active_env"  # 回滚 upstream
    exit 1
  fi
  reload_nginx
  set_active_env "$target_env"

  # 8. E2E 验证
  if ! e2e_verify "$target_env"; then
    log_error "E2E 验证失败，执行自动回滚"
    # 自动回滚
    update_upstream "$active_env"
    docker exec "$NGINX_CONTAINER" nginx -t
    reload_nginx
    set_active_env "$active_env"
    exit 1
  fi

  log_success "蓝绿部署完成: $active_env -> $target_env (镜像: findclass-ssr:${short_sha})"
}

main "$@"
```

### source manage-containers.sh 的问题与解决

**问题：** `manage-containers.sh` 末尾有 `case "${1:-}" in ... esac` 子命令分发（第 531-540 行）。直接 `source` 时，`${1:-}` 会是调用脚本的第一个参数，可能导致意外行为。

**解决方案（三选一）：**

1. **提取函数文件**（推荐）：将 `manage-containers.sh` 中的函数提取到一个单独的 `scripts/lib/containers.sh` 文件中（无 case 分发），`manage-containers.sh` 和部署脚本都 source 这个函数文件
2. **条件 source**：在 source 前临时保存/恢复位置参数
3. **重构 manage-containers.sh**：在 case 分发前加 `[ "${BASH_SOURCE[0]}" != "${0}" ] && return 0` 检测是否被 source

**推荐方案 3**，最小改动：

```bash
# manage-containers.sh 末尾，case 语句前添加：
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # 直接执行时走子命令分发
  case "${1:-}" in
    init)    cmd_init "$@" ;;
    # ...
  esac
fi
```

### rollback-findclass.sh 核心逻辑

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/manage-containers.sh"  # 需要先解决 source 问题

main() {
  local active_env
  active_env=$(get_active_env)

  # "上一环境"就是回滚目标
  local rollback_env
  if [ "$active_env" = "blue" ]; then
    rollback_env="green"
  else
    rollback_env="blue"
  fi

  local rollback_container
  rollback_container=$(get_container_name "$rollback_env")

  # 检查回滚目标容器
  if [ "$(is_container_running "$rollback_container")" != "true" ]; then
    log_error "回滚目标容器 $rollback_container 未运行，无法回滚"
    exit 1
  fi

  # 验证回滚目标健康
  log_info "验证回滚目标容器健康状态..."
  if ! http_health_check "$rollback_container" 10 3; then
    log_error "回滚目标容器 $rollback_container 不健康"
    exit 1
  fi

  # 切换流量
  log_info "回滚流量: $active_env -> $rollback_env"
  update_upstream "$rollback_env"
  if ! docker exec "$NGINX_CONTAINER" nginx -t; then
    log_error "nginx 配置验证失败"
    update_upstream "$active_env"
    exit 1
  fi
  reload_nginx
  set_active_env "$rollback_env"

  # E2E 验证
  if ! e2e_verify "$rollback_env"; then
    log_error "回滚后 E2E 验证失败 — 请手动检查"
    exit 1
  fi

  log_success "回滚完成: $active_env -> $rollback_env"
}

main "$@"
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `findclass-ssr:latest` 标签 | Git SHA 短哈希标签 | Phase 22 | 可追溯每次部署对应的代码版本 |
| Docker inspect healthcheck | HTTP 直检（docker exec wget） | Phase 22 D-01 | 直接验证应用层就绪，不依赖 Docker healthcheck 状态 |
| 手动部署（deploy-apps-prod.sh） | 蓝绿自动部署脚本 | Phase 22 | 零停机 + 自动回滚保护 |

**Deprecated/outdated:**
- `deploy-apps-prod.sh` 的镜像保存/回滚机制（save_app_image_tags/rollback_app）：被蓝绿部署的容器级别回滚替代，旧脚本保留为手动回退（Phase 25）

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | nginx:1.25-alpine 容器内包含 curl 命令 | Architecture Patterns - Pattern 3 | 如果没有 curl，E2E 验证需要改用 wget 或在宿主机通过 curl 访问 nginx |
| A2 | `docker compose build` 后镜像自动标记为 `findclass-ssr:latest`（与 compose image 字段一致） | Architecture Patterns - Pattern 4 | 如果产出名称不同，`docker tag` 命令需要调整 |
| A3 | `git rev-parse --short HEAD` 在 noda-apps 仓库中可用（部署脚本在 noda-apps 目录执行） | Architecture Patterns - Pattern 4 | 如果 noda-apps 不是 git 仓库或没有 .git，SHA 获取会失败 |

**验证建议：**
- A1：在实现阶段用 `docker exec noda-infra-nginx which curl` 验证
- A2：在实现阶段用 `docker compose build` 后 `docker images findclass-ssr` 验证
- A3：在实现阶段确认 noda-apps 的 git 仓库结构

## Open Questions (RESOLVED)

1. **TEST-03 参数与 D-02 不一致** — RESOLVED: 以 CONTEXT.md D-02 为准，计划已采用 30 次 x 4 秒 = 120 秒
   - What we know: REQUIREMENTS.md 要求"10 次每次 5 秒"（50 秒），CONTEXT.md D-02 建议"120 秒，30 次 x 4 秒"
   - What's unclear: 哪个参数是最终标准
   - Recommendation: 以 CONTEXT.md D-02 为准（它是对需求的专业修正），实现时使用 30 次 x 4 秒 = 120 秒超时

2. **source manage-containers.sh 的 case 分发问题** — RESOLVED: Plan 22-01 Task 1 实现 BASH_SOURCE guard
   - What we know: `manage-containers.sh` 末尾有 `case "${1:-}" in ... esac`，source 时会执行
   - What's unclear: 最佳解决方式（提取函数文件 vs 条件检测 vs 重构）
   - Recommendation: 在 case 语句前加 `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` 检测（最小改动）

3. **E2E 验证的具体路径** — RESOLVED: Plan 22-01 Task 2 采用 nginx 容器内 curl + wget fallback
   - What we know: 需要通过 nginx 验证完整请求链路
   - What's unclear: 用 nginx 容器内 curl 访问容器名（内部路径），还是用宿主机 curl 通过 nginx 访问
   - Recommendation: 用 `docker exec nginx curl http://findclass-ssr-{color}:3001/api/health`（内部路径，不依赖外部网络）

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker Compose | 构建镜像 | 已确认 | v2.40.3 | -- |
| git | 获取 SHA | 已确认 | -- | -- |
| wget (BusyBox) | 容器内 HTTP 检查 | 已确认（node:20-alpine 内置） | BusyBox wget | -- |
| curl (nginx 容器内) | E2E 验证 | 待验证 [ASSUMED] | -- | 改用 wget 或宿主机 curl |
| envsubst | prepare_env_file | 已确认（manage-containers.sh 已使用） | gettext | -- |

**Missing dependencies with no fallback:**
- 无阻塞性缺失依赖

**Missing dependencies with fallback:**
- nginx 容器内 curl：如果不可用，改用 `docker exec nginx wget --spider`（BusyBox wget 在 alpine 中必定可用）

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | 无自动化测试框架（纯 bash 脚本） |
| Config file | 无 |
| Quick run command | `bash -n scripts/blue-green-deploy.sh`（语法检查） |
| Full suite command | 手动集成测试 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PIPE-02 | 镜像携带 Git SHA 短哈希标签 | manual-only | `docker images findclass-ssr \| grep -v latest` | N/A |
| PIPE-03 | 构建失败时脚本中止 | manual-only | 构建一个会失败的 Dockerfile，验证脚本退出码 | N/A |
| TEST-03 | HTTP 健康检查重试验证 | manual-only | 启动容器后执行脚本，观察健康检查日志 | N/A |
| TEST-04 | E2E 验证 nginx 链路 | manual-only | 部署后检查 nginx 访问日志 | N/A |
| TEST-05 | 失败时不切换流量 | manual-only | 模拟健康检查失败，验证 upstream 未变更 | N/A |

**说明：** bash 部署脚本不适合自动化单元测试。验证通过 bash -n 语法检查 + 手动集成测试 + dry-run 模式。

### Sampling Rate
- **Per task commit:** `bash -n scripts/blue-green-deploy.sh && bash -n scripts/rollback-findclass.sh`
- **Per wave merge:** 手动集成测试
- **Phase gate:** 完整部署流程手动验证

### Wave 0 Gaps
- 无自动化测试框架需求 — bash 脚本通过 `bash -n` 语法检查 + 手动集成测试验证

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | -- |
| V3 Session Management | no | -- |
| V4 Access Control | yes | 脚本需要 root/sudo 执行部分操作（set_active_env 需要 sudo） |
| V5 Input Validation | yes | SHA 值验证、环境参数验证（validate_env） |
| V6 Cryptography | no | -- |

### Known Threat Patterns for Bash Deployment Scripts

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 镜像标签注入 | Tampering | SHA 值来自 git rev-parse，不受外部输入控制 |
| 竞态条件（upstream 切换） | Tampering | 原子文件写入（tmpfile + mv），已有模式 |
| 环境变量泄露 | Information Disclosure | env 文件使用 tmpfs，用后即删（rm -f） |

## Sources

### Primary (HIGH confidence)
- `scripts/manage-containers.sh` — 完整源码分析，函数接口和行为已验证
- `scripts/deploy/deploy-apps-prod.sh` — 现有部署模式参考
- `docker/docker-compose.app.yml` — 构建配置和镜像名定义
- `config/nginx/snippets/upstream-findclass.conf` — upstream 当前配置
- `docker/env-findclass-ssr.env` — 环境变量模板
- 本机验证: `git rev-parse --short HEAD`, `docker compose version`, `node:20-alpine` 工具可用性

### Secondary (MEDIUM confidence)
- CONTEXT.md D-02 建议的健康检查参数（120s/30x4s）— 需要在实际部署中验证 SSR 冷启动时间

### Tertiary (LOW confidence)
- nginx:1.25-alpine 中包含 curl [ASSUMED] — 需要在实现时验证

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有工具已在项目代码中验证
- Architecture: HIGH — 函数接口来自 Phase 21 产出的源码分析
- Pitfalls: HIGH — 基于 CLAUDE.md 记录的实际问题和 bash 语义分析

**Research date:** 2026-04-15
**Valid until:** 2026-05-15（bash/Docker/Nginx 稳定技术，30 天有效）
