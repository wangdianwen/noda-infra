# Phase 36: 蓝绿部署统一 - Research

**Researched:** 2026-04-18
**Domain:** Bash 脚本重构 — 蓝绿部署参数化合并
**Confidence:** HIGH

## Summary

本阶段将两个蓝绿部署脚本（`blue-green-deploy.sh` 164 行 + `keycloak-blue-green-deploy.sh` 189 行）合并为一个参数化脚本。经过逐行对比分析，两个脚本的 `main()` 函数结构高度一致，差异仅集中在 5 个维度：(1) 镜像获取方式（build vs pull）(2) 健康检查超时参数 (3) 镜像清理策略 (4) Keycloak compose 迁移检查 (5) 日志中的服务名。这些差异全部可以通过环境变量参数化消除。

`rollback-findclass.sh`（102 行）已使用 `deploy-check.sh` 共享函数，但硬编码了端口 `3001` 和路径 `/api/health`。参数化后可同时服务 findclass-ssr 和 keycloak 两个服务。Phase 35 提取的 3 个共享库（`deploy-check.sh`、`image-cleanup.sh`、`platform.sh`）已全部就绪，本阶段可直接复用。

**Primary recommendation:** 创建统一的 `blue-green-deploy.sh`，通过 `IMAGE_SOURCE`（build/pull/none）和 `CLEANUP_METHOD`（tag-count/dangling/none）环境变量区分服务行为，旧脚本改为 thin wrapper（~15 行），`rollback-findclass.sh` 改为参数化通用脚本。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 构建步骤内置到统一脚本中，通过 `IMAGE_SOURCE` 环境变量区分模式（build / pull / none）。findclass-ssr 用 build 模式（docker compose build + tag），keycloak 用 pull 模式（docker pull），无需 Jenkinsfile 改动
- **D-02:** 清理策略通过 `CLEANUP_METHOD` 环境变量参数化（tag-count / dangling / none）。findclass-ssr 默认 tag-count，keycloak wrapper 传 dangling。`CLEANUP_IMAGE_NAME` 和 `CLEANUP_KEEP_COUNT` 控制保留策略
- **D-03:** `rollback-findclass.sh` 改为参数化脚本，复用 manage-containers.sh 的 SERVICE_NAME/SERVICE_PORT/HEALTH_PATH 等环境变量，消除硬编码端口和路径
- **D-04:** 创建 `rollback-keycloak.sh` 作为 wrapper 脚本，设置 keycloak 参数后调用统一回滚脚本。回滚能力覆盖两个服务

### Claude's Discretion
- 统一脚本的具体环境变量命名（除已决定的 IMAGE_SOURCE、CLEANUP_METHOD 外）
- wrapper 脚本的具体实现方式（直接 exec 还是 source + 调用）
- 构建步骤中的 SHA 标签逻辑是否需要参数化
- keycloak compose 迁移检查逻辑是否纳入统一脚本

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BLUE-01 | 合并 `blue-green-deploy.sh` 和 `keycloak-blue-green-deploy.sh` 为统一参数化脚本，通过环境变量区分服务，保留旧脚本作为向后兼容 wrapper | 逐行差异分析已完成（见下方 Architecture Patterns），5 个差异维度均可通过环境变量控制 |
| BLUE-02 | 更新 `rollback-findclass.sh` 使用 `deploy-check.sh` 共享函数，消除硬编码 | rollback-findclass.sh 已 source deploy-check.sh（BLUE-02 部分完成），仅需消除 "3001" 和 "/api/health" 硬编码 |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| 蓝绿部署流程控制 | 宿主机脚本层 | — | bash 脚本在宿主机执行，控制 Docker 容器生命周期 |
| 镜像获取（build/pull） | 宿主机脚本层 | — | Docker CLI 命令在宿主机执行 |
| 容器启停管理 | 宿主机脚本层 | manage-containers.sh | run_container/update_upstream 等核心操作已抽象 |
| 流量切换 | Nginx 层 | 宿主机脚本层 | 通过修改 upstream 配置文件 + nginx -s reload |
| 健康检查 | Docker 网络层 | Nginx 容器 | 通过 nginx 容器 wget 访问目标容器 |
| 回滚操作 | 宿主机脚本层 | — | 反向执行流量切换 |

## Standard Stack

### Core

| Library/Script | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| manage-containers.sh | 现有 | 蓝绿容器生命周期管理 | 已参数化多服务支持，提供 run_container/update_upstream 等核心函数 [VERIFIED: 代码库] |
| deploy-check.sh | Phase 35 | HTTP 健康检查 + E2E 验证 | http_health_check() 和 e2e_verify() 已提取为共享函数 [VERIFIED: 代码库] |
| image-cleanup.sh | Phase 35 | 镜像清理策略 | cleanup_by_tag_count/cleanup_dangling/cleanup_by_date_threshold 三个独立策略 [VERIFIED: 代码库] |
| log.sh | 现有 | 日志输出 | log_info/log_success/log_error/log_warn [VERIFIED: 代码库] |
| health.sh | 现有 | 容器健康状态轮询 | wait_container_healthy() [VERIFIED: 代码库] |

### Supporting

| Library/Script | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| platform.sh | Phase 35 | 平台检测 | 需要 macOS/Linux 条件分支时 |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| 环境变量参数化 | 配置文件（YAML/JSON） | 配置文件增加解析依赖（需 jq/yq），环境变量是 bash 脚本的事实标准 |
| thin wrapper (exec) | thick wrapper (source + 函数调用) | exec 方式更简单，隔离性好，推荐使用 |

## Architecture Patterns

### 两个蓝绿脚本的精确差异分析

两个脚本 `main()` 函数的流程完全一致，差异点如下：

```
blue-green-deploy.sh (findclass-ssr)    keycloak-blue-green-deploy.sh (keycloak)
========================================    ========================================
1. 文件头 source 列表                        差异：keycloak 多了 source .env 和 source health.sh
2. 常量定义                                  差异：健康检查重试次数不同（30 vs 45）
3. 服务参数覆盖                              差异：keycloak 有 15+ 行 export 覆盖
4. 前置检查                                  完全相同
5. 活跃环境读取                              完全相同
6. compose 迁移检查                          差异：仅 keycloak 有此步骤
7. 镜像获取                                  差异：build + SHA tag（7步）vs pull（6步）
8. 停旧启新                                  完全相同
9. HTTP 健康检查                              差异：端口/路径不同（已通过 SERVICE_PORT/HEALTH_PATH 参数化）
10. 切换流量                                 完全相同
11. E2E 验证                                 完全相同（参数化）
12. 镜像清理                                 差异：cleanup_by_tag_count vs cleanup_dangling
13. 完成日志                                 差异：服务名和镜像信息
```

**量化结果：**
- 完全相同的代码块：前置检查、活跃环境读取、停旧启新、切换流量 = ~60 行
- 参数化后可统一的代码块：健康检查、E2E 验证、完成日志 = ~30 行
- 需要条件分支的代码块：镜像获取、清理策略、compose 迁移检查 = ~25 行
- 常量/参数定义：~40 行（合并后 ~15 行）

### 关键环境变量映射

统一脚本需要的参数化变量（与 manage-containers.sh 现有环境变量对齐）：

| 环境变量 | findclass-ssr 默认值 | keycloak 值 | 来源 |
|----------|---------------------|-------------|------|
| SERVICE_NAME | findclass-ssr | keycloak | manage-containers.sh |
| SERVICE_PORT | 3001 | 8080 | manage-containers.sh |
| UPSTREAM_NAME | findclass_backend | keycloak_backend | manage-containers.sh |
| HEALTH_PATH | /api/health | /realms/master | manage-containers.sh |
| ACTIVE_ENV_FILE | /opt/noda/active-env | /opt/noda/active-env-keycloak | manage-containers.sh |
| UPSTREAM_CONF | upstream-findclass.conf | upstream-keycloak.conf | manage-containers.sh |
| SERVICE_GROUP | apps | infra | manage-containers.sh |
| IMAGE_SOURCE | build | pull | **新增（D-01）** |
| CLEANUP_METHOD | tag-count | dangling | **新增（D-02）** |
| CLEANUP_IMAGE_NAME | findclass-ssr | keycloak | **新增（D-02）** |
| CLEANUP_KEEP_COUNT | 5 | — | **新增（D-02）** |
| CONTAINER_MEMORY | 512m | 1g | manage-containers.sh |
| CONTAINER_MEMORY_RESERVATION | 128m | 512m | manage-containers.sh |
| CONTAINER_READONLY | true | false | manage-containers.sh |
| CONTAINER_CMD | — | start | manage-containers.sh |
| EXTRA_DOCKER_ARGS | — | -v themes:ro --tmpfs data | manage-containers.sh |
| ENVSUBST_VARS | 5 个变量 | 9 个变量 | manage-containers.sh |
| CONTAINER_HEALTH_CMD | node fetch | bash tcp echo | manage-containers.sh |
| HEALTH_CHECK_MAX_RETRIES | 30 | 45 | 脚本常量 |
| COMPOSE_MIGRATION_CONTAINER | — | noda-infra-keycloak-prod | **新增（discretion）** |

### 镜像获取的 3 种模式

```bash
# IMAGE_SOURCE=build: findclass-ssr 模式
# 1. docker compose build findclass-ssr
# 2. docker tag findclass-ssr:latest findclass-ssr:${SHORT_SHA}
# 3. 镜像 = findclass-ssr:${SHORT_SHA}

# IMAGE_SOURCE=pull: keycloak 模式
# 1. docker pull $SERVICE_IMAGE
# 2. 镜像 = $SERVICE_IMAGE

# IMAGE_SOURCE=none: 跳过镜像获取（直接使用已有镜像）
# 1. 无操作
# 2. 镜像 = $SERVICE_IMAGE 或 ${SERVICE_NAME}:latest
```

### 回滚脚本参数化

`rollback-findclass.sh` 当前硬编码值及其参数化替代：

| 硬编码 | 行号 | 参数化替代 |
|--------|------|-----------|
| `"3001"` | 62, 85 | `${SERVICE_PORT}` |
| `"/api/health"` | 62, 85 | `${HEALTH_PATH}` |
| `"10"`（重试次数） | 62 | `${ROLLBACK_HEALTH_RETRIES:-10}` |
| `"3"`（重试间隔） | 62 | `${ROLLBACK_HEALTH_INTERVAL:-3}` |
| `"5"`（E2E 重试次数） | 85 | `${ROLLBACK_E2E_RETRIES:-5}` |
| `"2"`（E2E 重试间隔） | 85 | `${ROLLBACK_E2E_INTERVAL:-2}` |

注：rollback-findclass.sh 已经 source 了 `deploy-check.sh` 和 `manage-containers.sh`（BLUE-02 的部分工作已在 Phase 35 完成），只需要消除硬编码值。

### 调用方分析

| 调用方 | 被调用脚本 | 调用方式 | 合并后影响 |
|--------|-----------|---------|-----------|
| `pipeline-stages.sh:606` | `keycloak-blue-green-deploy.sh` | `bash "$PROJECT_ROOT/scripts/keycloak-blue-green-deploy.sh"` | keycloak wrapper 透明代理，无需改动 pipeline-stages.sh |
| 手动部署 | `blue-green-deploy.sh` | 直接执行 | wrapper 透明代理，体验不变 |
| 手动回滚 | `rollback-findclass.sh` | 直接执行 | 参数化后向后兼容（使用 manage-containers.sh 默认值） |
| `pipeline-stages.sh:588-607` | `pipeline_deploy_keycloak()` | 设置环境变量后 bash 调用 | 调用 keycloak wrapper，行为不变 |

**关键发现：Jenkinsfile 不直接调用这两个脚本。** Jenkinsfile 通过 `pipeline-stages.sh` 间接调用。`pipeline_deploy_keycloak()` 函数在 pipeline-stages.sh:606 行 `bash` 调用 `keycloak-blue-green-deploy.sh`。

### Recommended Project Structure

```
scripts/
├── blue-green-deploy.sh          # 统一参数化蓝绿部署脚本（新）
├── blue-green-deploy-findclass.sh # findclass wrapper（旧脚本改为 wrapper）
├── blue-green-deploy-keycloak.sh  # keycloak wrapper（旧脚本改为 wrapper，原名 keycloak-blue-green-deploy.sh）
├── rollback-deploy.sh            # 统一参数化回滚脚本（新）
├── rollback-findclass.sh         # findclass 回滚 wrapper（旧脚本改为 wrapper）
├── rollback-keycloak.sh          # keycloak 回滚 wrapper（新）
├── manage-containers.sh          # 容器生命周期管理（不变）
└── lib/
    ├── deploy-check.sh           # HTTP 健康检查 + E2E 验证（Phase 35，不变）
    ├── image-cleanup.sh          # 镜像清理（Phase 35，不变）
    ├── health.sh                 # 容器健康轮询（不变）
    ├── log.sh                    # 日志（不变）
    └── platform.sh               # 平台检测（Phase 35，不变）
```

### Pattern 1: Wrapper 脚本模式

**What:** 旧脚本保留为 thin wrapper，设置服务专属环境变量后 exec 统一脚本
**When to use:** 所有向后兼容的脚本迁移场景

**findclass-ssr wrapper 示例（原 blue-green-deploy.sh 改写）：**
```bash
#!/bin/bash
set -euo pipefail
# findclass-ssr 蓝绿部署 wrapper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# findclass-ssr 专属参数
export IMAGE_SOURCE="${IMAGE_SOURCE:-build}"
export CLEANUP_METHOD="${CLEANUP_METHOD:-tag-count}"
export CLEANUP_IMAGE_NAME="${CLEANUP_IMAGE_NAME:-findclass-ssr}"
export CLEANUP_KEEP_COUNT="${CLEANUP_KEEP_COUNT:-5}"
export COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/../docker/docker-compose.app.yml}"

exec "$SCRIPT_DIR/blue-green-deploy.sh" "$@"
```

**keycloak wrapper 示例（原 keycloak-blue-green-deploy.sh 改写）：**
```bash
#!/bin/bash
set -euo pipefail
# Keycloak 蓝绿部署 wrapper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Keycloak 专属参数
export SERVICE_NAME="${SERVICE_NAME:-keycloak}"
export SERVICE_PORT="${SERVICE_PORT:-8080}"
export UPSTREAM_NAME="${UPSTREAM_NAME:-keycloak_backend}"
export HEALTH_PATH="${HEALTH_PATH:-/realms/master}"
export ACTIVE_ENV_FILE="${ACTIVE_ENV_FILE:-/opt/noda/active-env-keycloak}"
export UPSTREAM_CONF="${UPSTREAM_CONF:-$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf}"
export SERVICE_GROUP="${SERVICE_GROUP:-infra}"
export IMAGE_SOURCE="${IMAGE_SOURCE:-pull}"
export SERVICE_IMAGE="${SERVICE_IMAGE:-quay.io/keycloak/keycloak:26.2.3}"
export CLEANUP_METHOD="${CLEANUP_METHOD:-dangling}"
export CONTAINER_MEMORY="${CONTAINER_MEMORY:-1g}"
export CONTAINER_MEMORY_RESERVATION="${CONTAINER_MEMORY_RESERVATION:-512m}"
export CONTAINER_READONLY="${CONTAINER_READONLY:-false}"
export CONTAINER_CMD="${CONTAINER_CMD:-start}"
export CONTAINER_HEALTH_CMD="${CONTAINER_HEALTH_CMD:-bash -c 'echo > /dev/tcp/localhost/8080'}"
export EXTRA_DOCKER_ARGS="${EXTRA_DOCKER_ARGS:--v $PROJECT_ROOT/docker/services/keycloak/themes:/opt/keycloak/themes/noda:ro --tmpfs /opt/keycloak/data}"
export ENVSUBST_VARS='${POSTGRES_USER} ${POSTGRES_PASSWORD} ${KEYCLOAK_ADMIN_USER} ${KEYCLOAK_ADMIN_PASSWORD} ${SMTP_HOST} ${SMTP_PORT} ${SMTP_FROM} ${SMTP_USER} ${SMTP_PASSWORD}'
export HEALTH_CHECK_MAX_RETRIES="${HEALTH_CHECK_MAX_RETRIES:-45}"
export COMPOSE_MIGRATION_CONTAINER="${COMPOSE_MIGRATION_CONTAINER:-noda-infra-keycloak-prod}"

exec "$SCRIPT_DIR/blue-green-deploy.sh" "$@"
```

### Pattern 2: 统一脚本的条件分支模式

**What:** 统一脚本内部根据 IMAGE_SOURCE / CLEANUP_METHOD 等环境变量选择执行路径
**When to use:** 镜像获取、清理策略等分支逻辑

```bash
# 镜像获取逻辑
case "${IMAGE_SOURCE:-build}" in
  build)
    docker compose -f "$COMPOSE_FILE" build "$SERVICE_NAME"
    docker tag "$SERVICE_NAME:latest" "$SERVICE_NAME:${short_sha}"
    deploy_image="$SERVICE_NAME:${short_sha}"
    ;;
  pull)
    docker pull "$SERVICE_IMAGE"
    deploy_image="$SERVICE_IMAGE"
    ;;
  none)
    deploy_image="${SERVICE_IMAGE:-${SERVICE_NAME}:latest}"
    ;;
  *)
    log_error "未知 IMAGE_SOURCE: $IMAGE_SOURCE（支持 build/pull/none）"
    exit 1
    ;;
esac

# 清理逻辑
case "${CLEANUP_METHOD:-none}" in
  tag-count)
    cleanup_by_tag_count "${CLEANUP_IMAGE_NAME:-$SERVICE_NAME}" "${CLEANUP_KEEP_COUNT:-5}"
    ;;
  dangling)
    cleanup_dangling
    ;;
  none)
    log_info "镜像清理: 跳过（CLEANUP_METHOD=none）"
    ;;
esac
```

### Pattern 3: .env 加载条件化

**What:** keycloak 需要 .env 文件（envsubst 需要 POSTGRES_USER 等变量），findclass-ssr 不需要
**When to use:** 统一脚本的初始化阶段

```bash
# 条件加载 .env（keycloak 需要，findclass-ssr 通过 env 文件模板处理）
if [ -f "$PROJECT_ROOT/docker/.env" ]; then
    set -a
    source "$PROJECT_ROOT/docker/.env"
    set +a
fi
```

**注意：** blue-green-deploy.sh 原来不加载 .env，keycloak-blue-green-deploy.sh 加载。统一脚本应该总是尝试加载 .env（如果文件存在）。这对 findclass-ssr 无害（它的 env 模板也需要这些变量），且是 manage-containers.sh 中 prepare_env_file() 所需。

### Anti-Patterns to Avoid

- **过度抽象：** 不要把 manage-containers.sh 的函数再包一层。统一脚本直接调用 run_container/update_upstream 等已有函数。
- **环境变量爆炸：** 不要引入超过必要数量的新环境变量。尽可能复用 manage-containers.sh 已有的变量名。
- **改变调用语义：** wrapper 脚本必须用 `exec` 调用统一脚本，保持进程号一致，确保信号传递和退出码正确。
- **重命名旧脚本文件：** CONTEXT.md 决定 "保留旧脚本作为向后兼容 wrapper"。旧文件名不变，内容改为 wrapper。

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 容器生命周期管理 | 自定义 docker run 逻辑 | manage-containers.sh run_container() | 已处理 env 模板、健康检查、内存限制、安全选项等 10+ 参数 |
| HTTP 健康检查 | 自定义 wget 循环 | deploy-check.sh http_health_check() | 已处理重试逻辑、日志输出、错误报告 |
| E2E 验证 | 自定义 curl 循环 | deploy-check.sh e2e_verify() | 已处理 curl/wget 备选方案 |
| 镜像清理 | 自定义 docker rmi 逻辑 | image-cleanup.sh 的 3 个清理函数 | 已处理 macOS/Linux 兼容、标签过滤、dangling 清理 |
| 流量切换 | 自定义 nginx 配置操作 | manage-containers.sh update_upstream() + reload_nginx() | 已处理原子写入、宿主机路径检测 |

**Key insight:** 统一脚本的职责是 "流程编排"，不是 "操作执行"。所有底层操作都已有共享库提供。统一脚本只需决定流程步骤和参数。

## Common Pitfalls

### Pitfall 1: .env 加载时序问题

**What goes wrong:** keycloak-blue-green-deploy.sh 在 source manage-containers.sh 之前加载 .env。如果统一脚本改变加载顺序，envsubst 变量可能未设置。
**Why it happens:** .env 中的变量（POSTGRES_USER 等）被 prepare_env_file() 的 envsubst 使用。
**How to avoid:** 统一脚本在 source manage-containers.sh 之前加载 .env，保持与 keycloak 脚本相同的时序。
**Warning signs:** `prepare_env_file` 输出的 env 文件包含未替换的 `${POSTGRES_USER}` 字面量。

### Pitfall 2: wrapper 中环境变量覆盖顺序

**What goes wrong:** wrapper 设置 `export SERVICE_PORT=8080`，但调用方也设置了 `SERVICE_PORT`。用 `${VAR:-default}` 会忽略 wrapper 的值。
**Why it happens:** findclass wrapper 不需要覆盖（使用 manage-containers.sh 默认值），keycloak wrapper 需要。两种场景的变量覆盖语义不同。
**How to avoid:** wrapper 中使用 `export VAR="${VAR:-value}"` 而非 `export VAR="value"`，允许调用方优先覆盖。
**Warning signs:** Jenkinsfile.keycloak 设置的 `HEALTH_CHECK_MAX_RETRIES=45` 被 wrapper 的硬编码值覆盖。

### Pitfall 3: COMPOSE_FILE 路径问题

**What goes wrong:** blue-green-deploy.sh 使用 `$PROJECT_ROOT/docker/docker-compose.app.yml` 构建 findclass-ssr。如果 IMAGE_SOURCE=build 时 COMPOSE_FILE 路径错误，构建失败。
**Why it happens:** keycloak 从不需要 compose build，所以 keycloak-blue-green-deploy.sh 不引用 COMPOSE_FILE。
**How to avoid:** 仅在 IMAGE_SOURCE=build 时引用 COMPOSE_FILE，并在该分支内验证文件存在。
**Warning signs:** `docker compose build` 报 "file not found" 错误。

### Pitfall 4: Git SHA 在 pull/none 模式下的处理

**What goes wrong:** blue-green-deploy.sh 从 `git -C "$apps_dir" rev-parse` 获取 SHA。keycloak 不需要 SHA（使用官方镜像标签）。如果统一脚本无条件要求 SHA，keycloak 部署会失败。
**Why it happens:** SHA 标签是 findclass-ssr 构建模式特有的需求。
**How to avoid:** 仅在 IMAGE_SOURCE=build 时获取 Git SHA，pull/none 模式跳过。
**Warning signs:** keycloak 部署报 "无法获取 Git SHA" 错误。

### Pitfall 5: COMPOSE_MIGRATION_CONTAINER 仅 keycloak 需要

**What goes wrong:** 将 compose 迁移检查纳入统一脚本时，如果不参数化，findclass-ssr 部署会尝试停止不存在的 `noda-infra-keycloak-prod` 容器。
**Why it happens:** 迁移检查是 keycloak 特有的首次迁移逻辑（从 docker compose 管理到蓝绿架构）。
**How to avoid:** 仅当 `COMPOSE_MIGRATION_CONTAINER` 非空时执行迁移检查。
**Warning signs:** findclass-ssr 部署日志出现 "检测到 compose 容器 noda-infra-keycloak-prod" 信息。

### Pitfall 6: 回滚脚本的 SERVICE_NAME 默认值

**What goes wrong:** 如果 rollback 脚本使用 `SERVICE_NAME="${SERVICE_NAME:-findclass-ssr}"` 默认值，但 keycloak wrapper 忘记设置 `SERVICE_NAME=keycloak`，回滚会操作错误的容器。
**Why it happens:** manage-containers.sh 的默认值是 findclass-ssr，keycloak 回滚需要覆盖。
**How to avoid:** 回滚脚本在执行前验证 `SERVICE_NAME` 与实际运行容器匹配，或在 wrapper 中硬编码（不使用 `${VAR:-default}`）。
**Warning signs:** keycloak 回滚日志显示操作 `findclass-ssr-blue/green` 而非 `keycloak-blue/green`。

### Pitfall 7: pipeline-stages.sh 调用路径

**What goes wrong:** `pipeline_deploy_keycloak()` 在 pipeline-stages.sh:606 调用 `bash "$PROJECT_ROOT/scripts/keycloak-blue-green-deploy.sh"`。如果脚本被重命名，Pipeline 失败。
**Why it happens:** CONTEXT.md 决定保留旧脚本名作为 wrapper，所以此问题不应发生。但需要确认不意外重命名文件。
**How to avoid:** 旧文件名保持不变（`keycloak-blue-green-deploy.sh`），仅修改内容为 wrapper。
**Warning signs:** Jenkins Keycloak Pipeline 的 Deploy 阶段报 "No such file or directory"。

## Code Examples

### 统一蓝绿部署脚本核心结构

```bash
#!/bin/bash
set -euo pipefail
# ============================================
# 统一蓝绿部署脚本
# ============================================
# 通过环境变量参数化支持多服务蓝绿部署
# IMAGE_SOURCE: build（构建）| pull（拉取）| none（使用已有）
# CLEANUP_METHOD: tag-count | dangling | none
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/health.sh"

# 加载 .env（envsubst 需要数据库密码等环境变量）
if [ -f "$PROJECT_ROOT/docker/.env" ]; then
    set -a
    source "$PROJECT_ROOT/docker/.env"
    set +a
fi

source "$PROJECT_ROOT/scripts/manage-containers.sh"
source "$PROJECT_ROOT/scripts/lib/deploy-check.sh"
source "$PROJECT_ROOT/scripts/lib/image-cleanup.sh"

# 蓝绿部署参数（可通过 wrapper/环境变量覆盖）
HEALTH_CHECK_MAX_RETRIES="${HEALTH_CHECK_MAX_RETRIES:-30}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-4}"
E2E_MAX_RETRIES="${E2E_MAX_RETRIES:-5}"
E2E_INTERVAL="${E2E_INTERVAL:-2}"
IMAGE_SOURCE="${IMAGE_SOURCE:-build}"
CLEANUP_METHOD="${CLEANUP_METHOD:-none}"

main() {
  local apps_dir="${1:-.}"

  # 前置检查（两个脚本完全相同的部分）
  ...

  # 活跃环境读取（两个脚本完全相同的部分）
  ...

  # Compose 迁移检查（仅 keycloak）
  if [ -n "${COMPOSE_MIGRATION_CONTAINER:-}" ]; then
    if [ "$(is_container_running "$COMPOSE_MIGRATION_CONTAINER")" = "true" ]; then
      log_warn "检测到 compose 管理的旧容器: $COMPOSE_MIGRATION_CONTAINER"
      docker stop -t 30 "$COMPOSE_MIGRATION_CONTAINER"
      docker rm "$COMPOSE_MIGRATION_CONTAINER"
      log_success "compose 容器已停止并移除"
    fi
  fi

  # 镜像获取（按 IMAGE_SOURCE 分支）
  local deploy_image=""
  case "$IMAGE_SOURCE" in
    build)
      local short_sha
      short_sha=$(git -C "$apps_dir" rev-parse --short HEAD 2>/dev/null || true)
      [ -z "$short_sha" ] && { log_error "无法获取 Git SHA"; exit 1; }
      COMPOSE_FILE="${COMPOSE_FILE:-$PROJECT_ROOT/docker/docker-compose.app.yml}"
      docker compose -f "$COMPOSE_FILE" build "$SERVICE_NAME"
      docker tag "$SERVICE_NAME:latest" "$SERVICE_NAME:${short_sha}"
      deploy_image="$SERVICE_NAME:${short_sha}"
      ;;
    pull)
      docker pull "$SERVICE_IMAGE"
      deploy_image="$SERVICE_IMAGE"
      ;;
    none)
      deploy_image="${SERVICE_IMAGE:-${SERVICE_NAME}:latest}"
      ;;
  esac

  # 停旧启新（两个脚本完全相同）
  ...

  # HTTP 健康检查（已参数化）
  http_health_check "$target_container" "${SERVICE_PORT}" "${HEALTH_PATH}" ...

  # 切换流量（两个脚本完全相同）
  ...

  # E2E 验证（已参数化）
  e2e_verify "$target_env" "${SERVICE_PORT}" "${HEALTH_PATH}" ...

  # 镜像清理（按 CLEANUP_METHOD 分支）
  case "$CLEANUP_METHOD" in
    tag-count)
      cleanup_by_tag_count "${CLEANUP_IMAGE_NAME:-$SERVICE_NAME}" "${CLEANUP_KEEP_COUNT:-5}"
      ;;
    dangling)
      cleanup_dangling
      ;;
    none)
      log_info "镜像清理: 跳过"
      ;;
  esac
}

main "$@"
```

### 统一回滚脚本核心结构

```bash
#!/bin/bash
set -euo pipefail
# ============================================
# 统一蓝绿回滚脚本
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/manage-containers.sh"
source "$PROJECT_ROOT/scripts/lib/deploy-check.sh"

main() {
  local active_env
  active_env=$(get_active_env)

  local rollback_env
  if [ "$active_env" = "blue" ]; then
    rollback_env="green"
  else
    rollback_env="blue"
  fi

  local rollback_container
  rollback_container=$(get_container_name "$rollback_env")

  # 前置检查...

  # 验证回滚目标容器健康（使用参数化端口和路径）
  if ! http_health_check "$rollback_container" "${SERVICE_PORT}" "${HEALTH_PATH}" \
       "${ROLLBACK_HEALTH_RETRIES:-10}" "${ROLLBACK_HEALTH_INTERVAL:-3}"; then
    log_error "回滚目标容器不健康，拒绝回滚"
    exit 1
  fi

  # 切换流量...
  # E2E 验证（使用参数化端口和路径）...
}

main "$@"
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| 两个独立的蓝绿部署脚本 | Phase 35 已提取共享库（deploy-check.sh, image-cleanup.sh） | Phase 35 (2026-04-18) | 重复代码已减少，但两个主脚本仍有 ~80% 流程代码重复 |
| blue-green-deploy.sh 内联健康检查逻辑 | source deploy-check.sh | Phase 35 (2026-04-18) | BLUE-02 部分完成 |
| rollback-findclass.sh 内联健康检查 | source deploy-check.sh | Phase 35 (2026-04-18) | BLUE-02 部分完成，但硬编码值未消除 |

**Deprecated/outdated:**
- `blue-green-deploy.sh` 和 `keycloak-blue-green-deploy.sh` 的完整独立版本将在本 Phase 后变为 wrapper

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | blue-green-deploy.sh 仅被手动调用，不被 Jenkinsfile 直接调用 | 调用方分析 | 如果有其他调用方，wrapper 需要兼容 |
| A2 | 统一脚本文件名为 `blue-green-deploy.sh`（覆盖原文件）| 文件结构 | 旧 wrapper 文件名需不同 |
| A3 | findclass-ssr wrapper 文件名改为 `blue-green-deploy-findclass.sh` | 文件结构 | 需更新文档引用 |

**处理方案：** A1 已通过 grep 全库搜索验证（仅 pipeline-stages.sh 引用 keycloak 版本，findclass 版本无脚本引用）。A2/A3 是 Claude's Discretion 范围，planner 可选择不同的文件命名策略。

## Open Questions

1. **统一脚本的文件名**
   - What we know: CONTEXT.md 说 "保留旧脚本作为向后兼容 wrapper"
   - What's unclear: 统一脚本叫什么名字？旧脚本改名还是改内容？
   - Recommendation: 方案 A — 统一脚本叫 `blue-green-deploy.sh`（覆盖原文件），旧 findclass 脚本改名为 `blue-green-deploy-findclass.sh` 作为 wrapper。方案 B — 新建统一脚本 `deploy-blue-green.sh`，旧两个文件都改内容为 wrapper。推荐方案 A，因为 findclass 手动调用者不需要改习惯。

2. **回滚脚本的统一命名**
   - What we know: D-04 要求创建 `rollback-keycloak.sh`
   - What's unclear: 统一回滚脚本叫什么？
   - Recommendation: `rollback-deploy.sh` 作为统一脚本，`rollback-findclass.sh` 和 `rollback-keycloak.sh` 作为 wrapper。

3. **pipeline-stages.sh 是否需要同步修改**
   - What we know: `pipeline_deploy_keycloak()` 直接 bash 调用 `keycloak-blue-green-deploy.sh`
   - What's unclear: wrapper 是否能完全透明代理
   - Recommendation: wrapper 用 `exec` 调用统一脚本，完全透明。pipeline-stages.sh 不需要改动。

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| bash | 统一脚本执行 | ✓ | — | — |
| docker | 容器操作 | ✓ | — | — |
| docker compose | 镜像构建（IMAGE_SOURCE=build） | ✓ | v2 | — |
| git | SHA 获取（IMAGE_SOURCE=build） | ✓ | — | — |
| envsubst | env 模板处理 | ✓ | — | — |
| ShellCheck | 语法验证 | 待确认 | — | `bash -n` 作为备选 |

**Missing dependencies with no fallback:**
- 无

**Missing dependencies with fallback:**
- ShellCheck: 可用 `bash -n` 做基础语法检查

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bash -n 语法检查 + 手动验证 |
| Config file | 无 |
| Quick run command | `bash -n scripts/blue-green-deploy.sh` |
| Full suite command | `bash -n scripts/blue-green-deploy.sh && bash -n scripts/rollback-deploy.sh` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BLUE-01 | 统一脚本接受环境变量参数化 | 语法检查 | `bash -n scripts/blue-green-deploy.sh` | Wave 0 |
| BLUE-01 | findclass wrapper 正确调用统一脚本 | 语法检查 | `bash -n scripts/blue-green-deploy-findclass.sh` | Wave 0 |
| BLUE-01 | keycloak wrapper 正确调用统一脚本 | 语法检查 | `bash -n scripts/keycloak-blue-green-deploy.sh` | Wave 0 |
| BLUE-02 | 回滚脚本不包含硬编码端口/路径 | grep 检查 | `grep -c '"3001"' scripts/rollback-deploy.sh` | Wave 0 |
| BLUE-02 | keycloak 回滚 wrapper 存在 | 文件检查 | `test -f scripts/rollback-keycloak.sh` | Wave 0 |

### Sampling Rate
- **Per task commit:** `bash -n` 对所有修改的 .sh 文件
- **Per wave merge:** 全部语法检查 + grep 硬编码检查
- **Phase gate:** 所有 .sh 文件通过 `bash -n` + 无硬编码端口/路径

### Wave 0 Gaps
- 无 — 项目无自动化测试框架，使用 `bash -n` + grep 即可满足验证需求

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | no | — |
| V5 Input Validation | yes | 环境变量通过 `${VAR:-default}` 模式验证 |
| V6 Cryptography | no | — |

### Known Threat Patterns for Bash Scripts

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 环境变量注入 | Tampering | `set -euo pipefail` + 明确的变量白名单 |
| 路径遍历 | Tampering | `SCRIPT_DIR` 使用 `cd` + `pwd` 规范化路径 |
| Shell 注入 | Tampering | 所有变量用双引号包裹，避免未引用扩展 |

## Sources

### Primary (HIGH confidence)
- 代码库直接分析：`blue-green-deploy.sh`、`keycloak-blue-green-deploy.sh`、`rollback-findclass.sh`、`manage-containers.sh`、`pipeline-stages.sh` — 逐行对比完成
- `deploy-check.sh`、`image-cleanup.sh` — Phase 35 产物验证
- `jenkins/Jenkinsfile.findclass-ssr`、`jenkins/Jenkinsfile.keycloak` — 调用链验证

### Secondary (MEDIUM confidence)
- CONTEXT.md 中的决策记录 — 用户确认的锁定决策

### Tertiary (LOW confidence)
- 无

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 全部为现有代码库文件，已逐一读取验证
- Architecture: HIGH — 逐行对比完成，差异点精确到行号
- Pitfalls: HIGH — 基于实际代码分析，非假设性

**Research date:** 2026-04-18
**Valid until:** 2026-05-18（或下次修改相关脚本前）
