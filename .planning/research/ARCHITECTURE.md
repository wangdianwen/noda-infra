# Architecture Research: Shell 脚本精简重构

**Domain:** Shell 脚本库架构、蓝绿部署框架、库依赖管理
**Researched:** 2026-04-18
**Confidence:** HIGH（基于完整代码库审计，无外部依赖需验证）

---

## 一、现状架构

### 1.1 当前目录结构

```
scripts/
├── lib/                          # 通用库（2 文件）
│   ├── log.sh                    # 34 行 — 带颜色日志（info/success/error/warn）
│   └── health.sh                 # 70 行 — 容器健康检查轮询
│
├── backup/lib/                   # 备份专用库（12 文件）
│   ├── log.sh                    # 87 行 — 日志（info/warn/error/success + progress + json + structured）
│   ├── health.sh                 # 358 行 — PG 连接检查 + 磁盘空间检查 + 数据库大小
│   ├── config.sh                 # 374 行 — 配置加载/验证/访问函数
│   ├── constants.sh              # 75 行 — 退出码 + 测试/监控/校验常量
│   ├── util.sh                   # 86 行 — 时间戳、权限、清理、校验和、格式化
│   ├── db.sh                     # 389 行 — 数据库备份操作
│   ├── cloud.sh                  # 243 行 — B2 云存储操作
│   ├── restore.sh                # 379 行 — 数据库恢复操作
│   ├── alert.sh                  # 163 行 — 告警通知
│   ├── metrics.sh                # 209 行 — 性能指标收集
│   ├── verify.sh                 # 233 行 — 备份验证
│   └── test-verify.sh            # 362 行 — 自动化验证测试
│
├── blue-green-deploy.sh          # 297 行 — findclass-ssr 蓝绿部署
├── keycloak-blue-green-deploy.sh # 297 行 — keycloak 蓝绿部署
├── rollback-findclass.sh         # 200 行 — findclass-ssr 紧急回滚
├── manage-containers.sh          # 659 行 — 蓝绿容器管理（8 子命令）
├── pipeline-stages.sh            # 1108 行 — Jenkins Pipeline 函数库
├── setup-jenkins.sh              # 1029 行 — Jenkins 安装/卸载
├── setup-jenkins-pipeline.sh     # 490 行 — Jenkins Pipeline 配置
├── prepare-jenkins-pipeline.sh   # 375 行 — Jenkins Pipeline 准备
├── setup-postgres-local.sh       # 539 行 — 宿主机 PG 安装
├── setup-docker-permissions.sh   # 333 行 — Docker 权限配置
├── apply-file-permissions.sh     # 409 行 — 文件权限应用
├── undo-permissions.sh           # 279 行 — 权限回退
├── break-glass.sh                # 324 行 — 紧急访问
├── init-databases.sh             # 91 行 — 数据库初始化
├── setup-keycloak-full.sh        # 186 行 — Keycloak 完整设置
├── install-auditd-rules.sh       # 310 行 — 审计规则安装
├── install-sudo-log.sh           # 298 行 — sudo 日志配置
├── install-sudoers-whitelist.sh  # 298 行 — sudoers 白名单
├── verify-sudoers-whitelist.sh   # 154 行 — sudoers 验证
│
├── deploy/                       # 部署脚本（旧版手动回退）
│   ├── deploy-apps-prod.sh       # 168 行 — 应用部署
│   ├── deploy-infrastructure-prod.sh
│   └── ...
│
├── utils/                        # 工具脚本
│   ├── decrypt-secrets.sh
│   └── validate-docker.sh
│
├── verify/                       # 一次性验证脚本（5 文件）
│   ├── quick-verify.sh
│   ├── verify-apps.sh
│   ├── verify-findclass.sh
│   ├── verify-infrastructure.sh
│   └── verify-services.sh
│
├── jenkins/                      # Jenkins 相关
│
└── backup/                       # 备份子系统
    ├── backup-postgres.sh
    ├── restore-postgres.sh
    ├── verify-restore.sh
    ├── test-verify-weekly.sh
    ├── lib/                      # 12 个库文件（见上）
    ├── tests/                    # 12 个测试脚本
    ├── templates/                # 文档模板
    └── docker/                   # 测试用 Dockerfile
```

### 1.2 库依赖关系图（当前）

```
┌──────────────────────────────────────────────────────────────────┐
│                    顶层脚本（source 消费者）                        │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  blue-green-deploy.sh ─────┐                                     │
│  keycloak-blue-green ──────┤                                     │
│  rollback-findclass.sh ────┼── source ──> scripts/lib/log.sh     │
│  manage-containers.sh ─────┤              scripts/lib/health.sh  │
│  pipeline-stages.sh ───────┤                                     │
│  deploy-apps-prod.sh ──────┤                                     │
│  setup-*.sh, install-*.sh ─┘                                     │
│                                                                  │
│  backup-postgres.sh ─────── source ──> scripts/backup/lib/*.sh   │
│  restore-postgres.sh ──────            （独立库链）               │
│  verify-restore.sh ────────                                      │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘

scripts/lib/ （通用库）          scripts/backup/lib/ （备份专用库）
├── log.sh (34行)                ├── log.sh (87行) ─── 重复 + 增强
└── health.sh (70行)             ├── health.sh (358行) ── 完全不同的功能
                                 ├── constants.sh (75行)
                                 ├── config.sh (374行)
                                 ├── util.sh (86行)
                                 └── ... (8个专用库)
```

### 1.3 关键发现：重复代码清单

| 重复函数 | 出现位置 | 行数/次 | 总行数 | 差异点 |
|---------|---------|---------|--------|--------|
| `http_health_check()` | blue-green-deploy.sh, keycloak-blue-green-deploy.sh, pipeline-stages.sh, rollback-findclass.sh | ~25行 x 4 | ~100 | URL 端口/路径参数化 |
| `e2e_verify()` | blue-green-deploy.sh, keycloak-blue-green-deploy.sh, pipeline-stages.sh, rollback-findclass.sh | ~45行 x 4 | ~180 | 端口/路径参数化 |
| `log_*()` 函数组 | scripts/lib/log.sh vs scripts/backup/lib/log.sh | 34行 vs 87行 | 121 | backup 版多 progress/json/structured |
| 常量定义 | blue-green-deploy.sh, keycloak-blue-green-deploy.sh | 各 ~15行 | ~30 | HEALTH_CHECK_MAX_RETRIES 等 |
| `cleanup_old_images()` | blue-green-deploy.sh, pipeline-stages.sh, keycloak-blue-green-deploy.sh | ~30行 x 3 | ~90 | 参数/策略不同 |

**总重复代码量：约 520 行**（占 scripts/ 总量 ~5%）

---

## 二、推荐目标架构

### 2.1 重构后的目录结构

```
scripts/
├── lib/                              # 统一通用库（合并后）
│   ├── log.sh                        # 统一日志（合并两个 log.sh）
│   ├── health.sh                     # 容器健康检查（不变）
│   ├── http-check.sh                 # [新增] HTTP 健康检查 + E2E 验证
│   └── image-cleanup.sh              # [新增] 镜像清理函数
│
├── backup/lib/                       # 备份专用库（保留，仅修改 log 依赖）
│   ├── config.sh                     # 不变
│   ├── constants.sh                  # 不变
│   ├── util.sh                       # 不变
│   ├── db.sh                         # 改 source ../lib/log.sh
│   ├── cloud.sh                      # 改 source ../lib/log.sh
│   ├── restore.sh                    # 改 source ../lib/log.sh
│   ├── alert.sh                      # 改 source ../lib/log.sh
│   ├── metrics.sh                    # 改 source ../lib/log.sh
│   ├── verify.sh                     # 改 source ../lib/log.sh
│   ├── test-verify.sh                # 改 source ../lib/log.sh
│   ├── health.sh                     # 保留（功能完全不同，仅名相同）
│   └── [log.sh 删除]                 # 指向 scripts/lib/log.sh
│
├── blue-green-deploy.sh              # [重写] 通用蓝绿部署入口
├── rollback-findclass.sh             # [重写] 复用 http-check.sh
├── manage-containers.sh              # 不变（已参数化良好）
├── pipeline-stages.sh                # [精简] 删除 http_health_check/e2e_verify 内联副本
└── ...
```

### 2.2 统一日志库：合并方案

**策略：** 将 backup/lib/log.sh 的增强功能合并到 scripts/lib/log.sh，删除 backup/lib/log.sh。

```bash
# scripts/lib/log.sh — 合并后的统一日志库

# === 基础颜色常量 ===
_GREEN='\033[0;32m'; _YELLOW='\033[1;33m'
_RED='\033[0;31m';   _BLUE='\033[0;34m'
_NC='\033[0m'

# === 基础日志函数（原有） ===
log_info()    { echo -e "${_YELLOW}info  $*${_NC}"; }
log_success() { echo -e "${_GREEN}ok    $*${_NC}"; }
log_error()   { echo -e "${_RED}fail  $*${_NC}" >&2; }
log_warn()    { echo -e "${_YELLOW}warn  $*${_NC}"; }

# === 增强日志函数（来自 backup/lib/log.sh） ===
log_progress() {
  local current=$1 total=$2 message=$3
  local percent=$((current * 100 / total))
  echo "progress [$current/$total] ($percent%) $message"
}

log_structured() {
  local level=$1 stage=$2 database=$3 message=$4 details="${5:-}"
  local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [$level] [$stage] [$database] $message"
  [[ -n "$details" ]] && echo "Details: $details"
}
```

**影响范围：** backup/lib/ 下 7 个 source log.sh 的文件都需要改路径。改动是机械性的搜索替换。

### 2.3 HTTP 健康检查 + E2E 验证：统一方案

**策略：** 提取到 `scripts/lib/http-check.sh`，通过环境变量参数化端口和路径。

```bash
# scripts/lib/http-check.sh — HTTP 健康检查 + E2E 验证（统一版）
# 依赖：scripts/lib/log.sh
# 环境变量控制：
#   SERVICE_PORT  — 服务端口（默认 3001）
#   HEALTH_PATH   — 健康检查路径（默认 /api/health）

# http_health_check - 容器内 HTTP 健康检查
# 参数：
#   $1: 容器名
#   $2: 最大重试次数（默认 30）
#   $3: 重试间隔秒数（默认 4）
# 环境变量：SERVICE_PORT, HEALTH_PATH
http_health_check() {
  local container="$1"
  local max_retries="${2:-${HEALTH_CHECK_MAX_RETRIES:-30}}"
  local interval="${3:-${HEALTH_CHECK_INTERVAL:-4}}"
  local port="${SERVICE_PORT:-3001}"
  local path="${HEALTH_PATH:-/api/health}"
  local attempt=0

  log_info "HTTP 健康检查: $container (最多 ${max_retries} 次, 间隔 ${interval}s)"

  while [ $attempt -lt $max_retries ]; do
    attempt=$((attempt + 1))
    if docker exec "$container" wget --quiet --tries=1 --spider \
       "http://localhost:${port}${path}" 2>/dev/null; then
      log_success "$container — HTTP 健康检查通过 (第 ${attempt}/${max_retries} 次)"
      return 0
    fi
    [ $attempt -lt $max_retries ] && sleep "$interval"
  done

  log_error "$container — HTTP 健康检查失败 (${max_retries} 次尝试)"
  log_info "最近容器日志:"
  docker logs "$container" --tail 20 2>&1 | sed 's/^/  /'
  return 1
}

# e2e_verify - 通过 nginx 容器验证完整请求链路
# 参数：
#   $1: 目标环境 (blue 或 green) — 需要 get_container_name（来自 manage-containers.sh）
#   $2: 最大重试次数（默认 5）
#   $3: 重试间隔秒数（默认 2）
# 环境变量：SERVICE_PORT, HEALTH_PATH, NGINX_CONTAINER
e2e_verify() {
  local target_env="$1"
  local max_retries="${2:-${E2E_MAX_RETRIES:-5}}"
  local interval="${3:-${E2E_INTERVAL:-2}}"
  # get_container_name 来自 manage-containers.sh，调用者必须已 source
  local container_name; container_name=$(get_container_name "$target_env")
  local port="${SERVICE_PORT:-3001}"
  local path="${HEALTH_PATH:-/api/health}"
  # ... curl/wget 双模式检测逻辑（同现有实现）
}
```

**关键设计决策：** `e2e_verify()` 依赖 `get_container_name()`（来自 manage-containers.sh），但不直接 source manage-containers.sh。调用者（blue-green-deploy.sh, pipeline-stages.sh）负责同时 source 两者。这种「依赖注入」模式避免了库之间的循环依赖。

### 2.4 镜像清理：统一方案

**策略：** 提取到 `scripts/lib/image-cleanup.sh`，合并三种清理策略。

```bash
# scripts/lib/image-cleanup.sh — 镜像清理（统一版）
# 依赖：scripts/lib/log.sh

# cleanup_sha_images - 清理超过指定天数的 SHA 标签镜像
# 参数：$1 = 保留天数（默认 7）
# 环境变量：SERVICE_NAME, IMAGE_RETENTION_DAYS
cleanup_sha_images() { ... }

# cleanup_dangling_images - 清理 dangling images
cleanup_dangling_images() { ... }

# cleanup_old_images - 综合清理（SHA + dangling）
# 官方镜像服务（SERVICE_IMAGE 已设置）仅清理 dangling
cleanup_old_images() {
  if [ -z "${SERVICE_IMAGE:-}" ]; then
    cleanup_sha_images "${1:-}"
  fi
  cleanup_dangling_images
}
```

### 2.5 蓝绿部署框架：统一入口

**策略：** 将 blue-green-deploy.sh 和 keycloak-blue-green-deploy.sh 合并为一个参数化脚本。

核心差异点和统一方式：

| 差异点 | findclass-ssr | keycloak | 统一方式 |
|--------|--------------|----------|---------|
| 镜像获取 | docker compose build + SHA tag | docker pull 官方镜像 | SERVICE_IMAGE 环境变量区分 |
| 端口 | 3001 | 8080 | SERVICE_PORT 环境变量 |
| 健康路径 | /api/health | /realms/master | HEALTH_PATH 环境变量 |
| 内存限制 | 512m | 1g | CONTAINER_MEMORY 环境变量 |
| 只读模式 | true | false | CONTAINER_READONLY 环境变量 |
| 额外参数 | 无 | 主题卷 + data tmpfs | EXTRA_DOCKER_ARGS 环境变量 |
| 健康检查超时 | 30x4=120s | 45x4=180s | HEALTH_CHECK_MAX_RETRIES 环境变量 |
| 旧容器迁移 | 无 | 检测 compose 容器 | 统一检测逻辑 |

**统一入口脚本逻辑：**

```bash
#!/bin/bash
# scripts/blue-green-deploy.sh — 通用蓝绿部署（统一版）
# 通过环境变量参数化支持 findclass-ssr, keycloak, 以及未来服务

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/http-check.sh"
source "$PROJECT_ROOT/scripts/lib/image-cleanup.sh"
source "$PROJECT_ROOT/scripts/manage-containers.sh"

# 加载 .env
[ -f "$PROJECT_ROOT/docker/.env" ] && { set -a; source "$PROJECT_ROOT/docker/.env"; set +a; }

main() {
  # 前置检查（Docker daemon + nginx + network）— 通用
  # 读取活跃环境 — 通用
  # 根据 SERVICE_IMAGE 是否设置：
  #   有 SERVICE_IMAGE → docker pull（Keycloak/官方镜像模式）
  #   无 SERVICE_IMAGE → docker build + SHA tag（findclass-ssr/源码构建模式）
  # 停旧目标容器 + run_container（通用）
  # http_health_check（通用，参数化）
  # update_upstream + nginx -t + reload_nginx（通用）
  # e2e_verify（通用，参数化）
  # cleanup_old_images（通用）
}
```

**Keycloak 调用方式变为（与 pipeline_deploy_keycloak() 现有逻辑一致）：**

```bash
SERVICE_NAME=keycloak \
SERVICE_PORT=8080 \
UPSTREAM_NAME=keycloak_backend \
HEALTH_PATH=/realms/master \
ACTIVE_ENV_FILE=/opt/noda/active-env-keycloak \
UPSTREAM_CONF=$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf \
CONTAINER_MEMORY=1g \
CONTAINER_MEMORY_RESERVATION=512m \
CONTAINER_READONLY=false \
SERVICE_GROUP=infra \
SERVICE_IMAGE=quay.io/keycloak/keycloak:26.2.3 \
EXTRA_DOCKER_ARGS='-v .../themes:/opt/keycloak/themes/noda:ro --tmpfs /opt/keycloak/data' \
ENVSUBST_VARS='${POSTGRES_USER} ...' \
HEALTH_CHECK_MAX_RETRIES=45 \
bash scripts/blue-green-deploy.sh
```

### 2.6 重构后依赖关系图

```
┌───────────────────────────────────────────────────────────────────┐
│                       顶层脚本（source 消费者）                     │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  blue-green-deploy.sh ──┐                                         │
│  rollback-findclass.sh ─┤                                         │
│  manage-containers.sh ──┼── source ──> scripts/lib/log.sh        │
│  pipeline-stages.sh ────┤              scripts/lib/health.sh     │
│  deploy-*.sh ───────────┤              scripts/lib/http-check.sh │
│  setup-*.sh ────────────┘              scripts/lib/image-cleanup │
│                                                                   │
│  backup-postgres.sh ──── source ──> scripts/lib/log.sh (统一)    │
│  restore-postgres.sh ───               scripts/backup/lib/*.sh   │
│  verify-restore.sh ─────              （独立库链，log 指向统一版） │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘

scripts/lib/ （统一通用库）         scripts/backup/lib/ （备份专用库）
├── log.sh        ← 合并版         ├── config.sh      — 不变
├── health.sh     ← 不变           ├── constants.sh   — 不变
├── http-check.sh ← [新增]         ├── util.sh        — 不变
└── image-cleanup ← [新增]         ├── db.sh          — 改 source
                                   ├── cloud.sh       — 改 source
                                   ├── restore.sh     — 改 source
                                   ├── alert.sh       — 改 source
                                   ├── metrics.sh     — 改 source
                                   ├── verify.sh      — 改 source
                                   ├── test-verify.sh — 改 source
                                   └── health.sh      — 不变（功能不同）
```

---

## 三、组件边界与职责

| 组件 | 职责 | 依赖 | 消费者 |
|------|------|------|--------|
| `lib/log.sh` | 统一日志输出（基础 + 增强） | 无 | 所有脚本 |
| `lib/health.sh` | 容器 Docker healthcheck 轮询 | log.sh | manage-containers, deploy-* |
| `lib/http-check.sh` | HTTP 健康检查 + E2E 验证 | log.sh | blue-green-deploy, pipeline-stages, rollback |
| `lib/image-cleanup.sh` | 镜像清理（SHA + dangling） | log.sh | blue-green-deploy, pipeline-stages |
| `manage-containers.sh` | 蓝绿容器生命周期管理 | log.sh, health.sh | 所有蓝绿脚本 |
| `pipeline-stages.sh` | Jenkins Pipeline 函数 | log.sh, manage-containers, http-check, image-cleanup | Jenkinsfile |
| `blue-green-deploy.sh` | 通用蓝绿部署入口 | log.sh, http-check, image-cleanup, manage-containers | Jenkinsfile / 手动 |
| `backup/lib/*` | 备份子系统专用逻辑 | lib/log.sh（统一） | backup-postgres, restore-postgres |

### 组件边界原则

1. **lib/ 层零业务逻辑**：只提供纯工具函数（日志、检查、清理），不包含任何部署流程
2. **manage-containers.sh 是容器管理的唯一入口**：所有蓝绿容器操作通过此脚本
3. **backup/lib/ 独立性保持**：备份系统有自己独立的生命周期和配置体系，不与部署脚本耦合
4. **http-check.sh 不依赖 manage-containers.sh**：`e2e_verify()` 需要 `get_container_name()`，但通过调用者间接获取而非直接依赖

---

## 四、集成点识别

### 4.1 新增文件

| 文件 | 来源 | 内容 |
|------|------|------|
| `scripts/lib/http-check.sh` | 从 blue-green-deploy.sh 提取 | `http_health_check()` + `e2e_verify()` 参数化统一版 |
| `scripts/lib/image-cleanup.sh` | 从 pipeline-stages.sh 提取 | `cleanup_old_images()` + `cleanup_sha_images()` + `cleanup_dangling_images()` |

### 4.2 修改文件

| 文件 | 变更类型 | 具体改动 |
|------|---------|---------|
| `scripts/lib/log.sh` | 增强 | 合并 backup/lib/log.sh 的 `log_progress()` + `log_structured()` |
| `scripts/blue-green-deploy.sh` | 重写 | 改为参数化通用蓝绿部署，source http-check.sh + image-cleanup.sh |
| `scripts/keycloak-blue-green-deploy.sh` | **删除** | 功能合并入 blue-green-deploy.sh |
| `scripts/rollback-findclass.sh` | 精简 | 删除内联的 http_health_check/e2e_verify，source http-check.sh |
| `scripts/pipeline-stages.sh` | 精简 | 删除内联的 http_health_check/e2e_verify/cleanup_old_images，source http-check.sh + image-cleanup.sh |
| `scripts/backup/lib/log.sh` | **删除** | 内容已合并到 scripts/lib/log.sh |
| `scripts/backup/lib/db.sh` | 改 source 路径 | `source "$_DB_LIB_DIR/log.sh"` 改为指向 `scripts/lib/log.sh` |
| `scripts/backup/lib/cloud.sh` | 改 source 路径 | 同上模式 |
| `scripts/backup/lib/restore.sh` | 改 source 路径 | 同上模式 |
| `scripts/backup/lib/alert.sh` | 改 source 路径 | 同上模式 |
| `scripts/backup/lib/metrics.sh` | 改 source 路径 | 同上模式 |
| `scripts/backup/lib/verify.sh` | 改 source 路径 | 同上模式 |
| `scripts/backup/lib/test-verify.sh` | 改 source 路径 | 同上模式 |

### 4.3 不变文件

| 文件 | 原因 |
|------|------|
| `scripts/lib/health.sh` | 功能无重叠（Docker healthcheck 轮询 vs HTTP 检查） |
| `scripts/backup/lib/health.sh` | 功能完全不同（PG 连接/磁盘/数据库大小） |
| `scripts/backup/lib/config.sh` | 备份专用配置体系 |
| `scripts/backup/lib/constants.sh` | 备份专用退出码 |
| `scripts/backup/lib/util.sh` | 备份专用工具函数 |
| `scripts/manage-containers.sh` | 已参数化良好，无需修改 |
| 所有 setup-*.sh, install-*.sh | 仅 source log.sh，无需改动 |
| scripts/verify/*.sh | 不 source 自定义库，不参与重构 |

### 4.4 构建顺序（依赖关系决定）

```
Phase 1: scripts/lib/log.sh（合并增强）
  | 所有后续改动依赖此文件
  v
Phase 2: scripts/lib/http-check.sh + scripts/lib/image-cleanup.sh（新增）
  | 依赖 log.sh
  v
Phase 3: scripts/backup/lib/*.sh（改 source 路径）— 可与 Phase 2 并行
  | 依赖 log.sh 合并版
  v
Phase 4: blue-green-deploy.sh（重写）+ 删除 keycloak-blue-green-deploy.sh
  | 依赖 http-check.sh + image-cleanup.sh
  v
Phase 5: rollback-findclass.sh + pipeline-stages.sh（精简内联副本）
  | 依赖 http-check.sh + image-cleanup.sh
```

---

## 五、架构模式

### 模式 1: Source Guard（防重复加载 + 防直接执行）

**已使用的模式：**

manage-containers.sh 底部（可 source 可执行）：
```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    init|start|stop|...) ... ;;
  esac
fi
```

pipeline-stages.sh 底部（仅 source）：
```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "pipeline-stages.sh 是函数库，不支持直接执行"
  exit 1
fi
```

backup/lib/config.sh 顶部（防重复加载）：
```bash
if [[ -n "${_NODA_CONFIG_LOADED:-}" ]]; then return 0; fi
_NODA_CONFIG_LOADED=1
```

**推荐：** 新增的 `http-check.sh` 和 `image-cleanup.sh` 使用仅 source 模式，因为它们总被其他脚本调用。

### 模式 2: 环境变量参数化（多态）

**已使用的模式：** manage-containers.sh 通过 SERVICE_NAME/SERVICE_PORT/UPSTREAM_NAME 等环境变量适配不同服务。

**扩展应用：** blue-green-deploy.sh 通过 SERVICE_IMAGE 是否设置来决定构建 vs 拉取模式。

```bash
# 参数化模式示例
deploy_service() {
  if [ -n "${SERVICE_IMAGE:-}" ]; then
    # 官方镜像模式：拉取
    docker pull "$SERVICE_IMAGE"
    local image="$SERVICE_IMAGE"
  else
    # 源码构建模式：构建 + SHA 标签
    docker build -t "${SERVICE_NAME}:${git_sha}" ...
    local image="${SERVICE_NAME}:${git_sha}"
  fi

  # 后续流程完全相同
  run_container "$target_env" "$image"
  http_health_check "$target_container"
  ...
}
```

### 模式 3: 跨目录库引用（动态路径计算）

**当前模式（backup/lib/ 内部）：**
```bash
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIB_DIR/constants.sh"
```

**推荐模式（跨目录引用统一库）：**
```bash
# backup/lib/db.sh 引用统一 log.sh
_DB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 计算上层路径：backup/lib/ -> backup/ -> scripts/ -> scripts/lib/
_UNIFIED_LIB="$(cd "$_DB_LIB_DIR/../../lib" && pwd)"

# 条件加载统一 log（避免重复 source）
if ! type log_info &>/dev/null; then
  source "$_UNIFIED_LIB/log.sh"
fi
```

这个模式的关键是使用 `cd` + `pwd` 组合获得绝对路径，避免相对路径在不同工作目录下失效。

---

## 六、Anti-Patterns

### Anti-Pattern 1: 函数复制粘贴替代 source

**当前问题：** http_health_check 和 e2e_verify 被 4 次复制到不同文件中，每次参数略有不同。

**后果：** 修改一处忘记同步其他 3 处，导致行为不一致。

**正确做法：** 提取到 `lib/http-check.sh`，通过参数和环境变量控制差异。

### Anti-Pattern 2: 命名相同但功能不同的文件

**当前问题：** `scripts/lib/health.sh`（Docker healthcheck 轮询）与 `scripts/backup/lib/health.sh`（PG 连接/磁盘检查）同名但功能完全不同。

**后果：** 开发者混淆，以为 backup/lib/health.sh 是 scripts/lib/health.sh 的增强版。

**正确做法：** 保持两文件存在但确保命名或注释明确区分。backup/lib/health.sh 已有清晰注释说明其功能。重构时确保 backup/ 子系统的脚本不会误 source scripts/lib/health.sh。

### Anti-Pattern 3: 全局变量污染

**当前问题：** 多个脚本 source 后在全局命名空间定义大量变量（EXIT_SUCCESS, HEALTH_CHECK_MAX_RETRIES 等）。

**后果：** 变量名冲突风险，readonly 变量重复定义导致 source 失败。

**正确做法：**
- 库文件使用 guard 防止重复加载（config.sh 的 `_NODA_CONFIG_LOADED` 模式）
- 常量使用命名前缀（如 `NODA_EXIT_SUCCESS` 而非 `EXIT_SUCCESS`）— 但当前规模下暂无冲突，低优先级
- 已有的 readonly 保护是正确的（backup/lib/constants.sh 使用 `readonly` + guard）

### Anti-Pattern 4: 副作用 source

**当前问题：** `source manage-containers.sh` 不仅定义函数，还执行了 NGINX_CONTAINER 等常量赋值。

**说明：** manage-containers.sh 当前的模式是合理的 — 常量赋值在全局作用域（source 时执行），函数定义也在全局作用域。这种模式在 shell 中是标准做法。需要注意新增库文件不要在 source 时执行任何有副作用的操作（如网络请求、文件写入）。

---

## 七、backup/lib/health.sh 不应合并的理由

两个 health.sh 功能完全不同：

| scripts/lib/health.sh | scripts/backup/lib/health.sh |
|----------------------|------------------------------|
| Docker 容器 healthcheck 状态轮询 | PostgreSQL 连接检查 |
| `wait_container_healthy()` | `check_postgres_connection()` |
| 依赖：无 | 依赖：constants.sh, config.sh |
| 消费者：部署脚本 | 消费者：备份脚本 |
| 端口/协议无关 | PG 特定协议 |

**结论：** 保留两文件，仅确保 backup/lib/health.sh 不被非备份脚本误 source。

---

## 八、verify/ 目录处理建议

```
scripts/verify/
├── quick-verify.sh          — 快速全服务验证（一键检查所有）
├── verify-apps.sh           — 应用服务验证
├── verify-findclass.sh      — findclass-ssr 验证
├── verify-infrastructure.sh — 基础设施验证
└── verify-services.sh       — 服务可达性验证
```

**建议：** 保留但标记为一次性验证工具。这些脚本不 source 任何自定义库（使用原生 echo），不参与本次重构。后续可考虑合并 quick-verify.sh 为唯一入口，其他作为子函数。

---

## 九、重构风险评估

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| backup/lib/ source 路径改动导致备份失败 | **高**（备份是核心价值） | 路径改动后完整运行 backup-postgres.sh 验证 |
| blue-green-deploy.sh 重写破坏部署流程 | **高** | 保留旧脚本作为回退（类似 deploy-apps-prod.sh 保留策略） |
| http-check.sh 参数化遗漏差异 | **中** | 对比 4 个现有版本的所有参数差异，确保环境变量覆盖完整 |
| cleanup_old_images 策略合并不兼容 | **中** | 三种策略都保留为独立函数，通过环境变量选择 |
| readonly 变量重复定义 | **低** | config.sh 已有 guard，constants.sh 使用 `if -z` 检查 |

---

## Sources

| 来源 | 置信度 | 用途 |
|------|--------|------|
| 完整代码库审计（2026-04-18） | HIGH | 所有 scripts/ 下 .sh 文件的逐行分析 |
| 依赖关系 grep 验证 | HIGH | `grep -rn "source.*\.sh"` 确认所有 source 链路 |
| 重复代码量化 | HIGH | `grep -rn "http_health_check\|e2e_verify\|cleanup_old"` 统计重复量 |
| 行数统计 | HIGH | `wc -l scripts/**/*.sh` 获取各文件规模 |

---
*Architecture research for: Shell 脚本精简重构*
*Researched: 2026-04-18*
