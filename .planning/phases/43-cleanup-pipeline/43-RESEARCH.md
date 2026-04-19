# Phase 43: 清理共享库 + Pipeline 集成 - Research

**Researched:** 2026-04-19
**Domain:** Docker/Jenkins 部署后清理自动化 + 共享库架构
**Confidence:** HIGH

## Summary

Phase 43 需要新建 `scripts/lib/cleanup.sh` 共享库（提供 Docker build cache/容器/卷/网络清理、node_modules 清理、备份文件清理、磁盘快照等函数），然后增强 `pipeline_cleanup()`（pipeline-stages.sh:411）和 `pipeline_infra_cleanup()`（pipeline-stages.sh:883）集成新库。4 个 Jenkinsfile（findclass-ssr, noda-site, keycloak, infra）本身不需要修改——它们调用的是 pipeline-stages.sh 中的函数，修改函数即可自动生效。

CLEANUP-RESEARCH.md 已有完整的函数模板和命令研究（11 章），本 phase 的核心工作是**集成**而非**研究**——把已有模板适配到现有代码结构中。关键集成点：pipeline-stages.sh 第 19 行 source image-cleanup.sh 后追加 source cleanup.sh；pipeline_cleanup() 第 441 行后追加 cleanup_after_deploy 调用；pipeline_infra_cleanup() 第 905 行后追加清理调用。

**Primary recommendation:** 创建 cleanup.sh 时严格遵循现有 Source Guard 模式（`_NODA_CLEANUP_LOADED`），提供 `cleanup_after_deploy()` 高层 wrapper + `cleanup_after_infra_deploy()` infra 专用 wrapper，通过 pipeline-stages.sh 头部统一 source，各函数内部通过环境变量控制跳过。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** cleanup.sh 与 image-cleanup.sh 并存不合并。职责分离：image-cleanup.sh 专注镜像保留策略（cleanup_by_tag_count, cleanup_by_date_threshold, cleanup_dangling），cleanup.sh 专注部署后全面清理（build cache, containers, volumes, node_modules, temp files, backups）
- **D-02:** pipeline_cleanup() 同时 source 两个库（image-cleanup.sh + cleanup.sh），不互相依赖
- **D-03:** cleanup.sh 提供 `cleanup_after_deploy()` 高层 wrapper 函数，内部按顺序执行所有清理步骤。pipeline_cleanup() 和 pipeline_infra_cleanup() 只需调用这一个函数
- **D-04:** wrapper 内部可通过环境变量控制跳过某些步骤（如 `SKIP_BUILD_CACHE_CLEANUP=true`），但默认全部执行
- **D-05:** `disk_snapshot()` 输出纯文本到 Jenkins 构建日志（df -h + docker system df）。不写入独立文件，不使用 JSON 格式
- **D-06:** 部署前（Deploy 阶段前）和清理后（Cleanup 阶段末尾）各输出一次快照，人工对比
- **D-07:** Plan 43-03 通过手动触发 4 个 Pipeline（findclass-ssr, noda-site, keycloak, infra）做端到端验证，检查构建日志中清理输出和磁盘快照对比
- **D-08:** 不编写独立测试脚本，验证在真实 Pipeline 环境中进行

### Claude's Discretion
- cleanup.sh 中各清理函数的具体签名和参数设计
- cleanup_after_deploy() 内部的执行顺序
- 环境变量覆盖的具体命名和默认值
- 函数内的日志格式和输出细节
- pipeline_cleanup() / pipeline_infra_cleanup() 修改的具体行数和结构
- 是否需要 cleanup_after_infra_deploy() 作为 infra 专用 wrapper

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DOCK-01 | Pipeline 部署成功后自动清理 Docker build cache（`docker buildx prune --filter until=24h`） | cleanup_docker_build_cache() 函数，保留 24h 热缓存 [VERIFIED: CLEANUP-RESEARCH.md 二.1] |
| DOCK-02 | Pipeline 部署成功后自动清理已停止的容器（`docker container prune -f`） | cleanup_stopped_containers() 函数，使用 `--filter until=24h` [VERIFIED: CLEANUP-RESEARCH.md 二.3] |
| DOCK-03 | Pipeline 部署成功后自动清理未使用的匿名卷（`docker volume prune -f`，不含 `--all`） | cleanup_anonymous_volumes() 函数，绝对不加 `--all` [VERIFIED: CLEANUP-RESEARCH.md 二.5] |
| DOCK-04 | Pipeline 部署前后记录磁盘用量对比（`df -h` + `docker system df`） | disk_snapshot() 函数，Deploy 前 + Cleanup 后各一次 [VERIFIED: CLEANUP-RESEARCH.md 五] |
| CACHE-01 | Jenkins workspace 中 findclass-ssr/noda-site 的 `node_modules` 在部署成功后清理 | cleanup_node_modules() 函数，删除 $WORKSPACE/noda-apps/node_modules [VERIFIED: CLEANUP-RESEARCH.md 三.3] |
| FILE-01 | 清理 `infra-pipeline/` 目录下超过 N 天的旧备份文件（默认 30 天） | cleanup_old_infra_backups() 函数，find + mtime [VERIFIED: CLEANUP-RESEARCH.md 四.4] |
| FILE-02 | Pipeline 结束后清理 `deploy-failure-*.log` 临时日志文件 | cleanup_jenkins_temp_files() 函数 [VERIFIED: CLEANUP-RESEARCH.md 四.2] |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Docker build cache 清理 | 宿主机 Docker | -- | `docker buildx prune` 必须在宿主机执行，Jenkins 通过 sh 步骤调用 |
| Docker 容器/卷/网络清理 | 宿主机 Docker | -- | 所有 docker prune 命令在宿主机 Docker daemon 上执行 |
| node_modules 清理 | Jenkins Workspace | -- | Jenkins agent workspace 文件系统，通过 rm -rf 清理 |
| 备份文件清理 | 宿主机文件系统 | -- | `docker/volumes/backup/infra-pipeline/` 在宿主机 bind mount |
| 磁盘快照监控 | Jenkins 日志 | -- | 输出到 Jenkins 构建日志，人工对比 |
| Pipeline 清理编排 | Jenkins Pipeline (groovy) | shell 函数 | Jenkinsfile 调用 pipeline-stages.sh 函数，函数内部编排清理步骤 |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Bash | 5.x | Shell 函数库 | 项目所有共享库基于 Bash，Jenkins sh 步骤执行 [VERIFIED: 项目代码] |
| Docker CLI | 24+ | docker prune 系列命令 | `docker buildx prune --filter until=Nh` 需要 Docker 24+ [VERIFIED: CLEANUP-RESEARCH.md 二] |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| log.sh (现有) | -- | 日志输出 | cleanup.sh 所有函数依赖 log_info/log_success/log_error [VERIFIED: scripts/lib/log.sh] |
| image-cleanup.sh (现有) | -- | 镜像清理 | 与 cleanup.sh 并存，pipeline_cleanup() 同时 source 两个库 [VERIFIED: scripts/lib/image-cleanup.sh] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| 分步 prune 命令 | `docker system prune -f` | system prune 缺乏细粒度控制，无法区分 build cache 时间过滤；不符合项目分步清理风格 [VERIFIED: CLEANUP-RESEARCH.md 二.6] |
| cleanup.sh 独立库 | 合并到 image-cleanup.sh | 职责分离更清晰；image-cleanup 专注镜像策略，cleanup 专注部署后全面清理 [VERIFIED: CONTEXT.md D-01] |

## Architecture Patterns

### System Architecture Diagram

```
Jenkinsfile (findclass-ssr / noda-site / keycloak)
    │
    ├─ stage('Deploy') ──> pipeline_deploy() ──> disk_snapshot("部署前")  [NEW]
    │
    └─ stage('Cleanup') ──> pipeline_cleanup()
                                │
                                ├─ [EXISTING] 停止非活跃蓝绿容器
                                ├─ [EXISTING] SHA 镜像日期清理 / dangling 清理
                                │
                                └─ [NEW] cleanup_after_deploy()
                                     ├─ cleanup_docker_build_cache(24)
                                     ├─ cleanup_stopped_containers(24)
                                     ├─ cleanup_unused_networks()
                                     ├─ cleanup_anonymous_volumes()
                                     ├─ cleanup_node_modules($WORKSPACE)
                                     ├─ cleanup_jenkins_temp_files($WORKSPACE)
                                     └─ disk_snapshot("清理后")

Jenkinsfile.infra
    │
    ├─ stage('Deploy') ──> pipeline_infra_deploy() ──> disk_snapshot("部署前")  [NEW]
    │
    └─ stage('Cleanup') ──> pipeline_infra_cleanup($SERVICE)
                                │
                                ├─ [EXISTING] 备份目录索引 + dangling 清理
                                │
                                └─ [NEW] cleanup_after_infra_deploy($SERVICE)
                                     ├─ cleanup_docker_build_cache(24)  [noda-ops only]
                                     ├─ cleanup_old_infra_backups($SERVICE, 30)
                                     ├─ cleanup_stopped_containers(24)
                                     ├─ cleanup_unused_networks()
                                     ├─ cleanup_anonymous_volumes()
                                     ├─ cleanup_jenkins_temp_files($WORKSPACE)
                                     └─ disk_snapshot("清理后")
```

### Recommended Project Structure

```
scripts/lib/
  log.sh              -- 日志函数（现有，不修改）
  image-cleanup.sh    -- 镜像清理（现有，不修改）
  cleanup.sh          -- 新增：综合清理（Docker + Node.js + 文件 + 磁盘快照）
  deploy-check.sh     -- 部署检查（现有，不修改）
  secrets.sh          -- 密钥管理（现有，不修改）
  platform.sh         -- 平台检测（现有，不修改）
  health.sh           -- 健康检查（现有，不修改）

scripts/
  pipeline-stages.sh  -- 修改：source cleanup.sh + 增强 pipeline_cleanup/pipeline_infra_cleanup
```

### Pattern 1: Source Guard + 统一 source 加载

**What:** 所有共享库使用 Source Guard 防止重复加载，pipeline-stages.sh 在头部统一 source 所有依赖库。

**When to use:** 新建 cleanup.sh 必须遵循此模式。

**Example:**

```bash
# cleanup.sh 头部
if [[ -n "${_NODA_CLEANUP_LOADED:-}" ]]; then
    return 0
fi
_NODA_CLEANUP_LOADED=1

# pipeline-stages.sh 头部（第 19 行之后追加）
source "$PROJECT_ROOT/scripts/lib/cleanup.sh"
```

[VERIFIED: scripts/lib/image-cleanup.sh:10-13, scripts/lib/deploy-check.sh:10-13]

### Pattern 2: 环境变量覆盖默认值

**What:** 清理参数通过环境变量提供默认值，允许 Pipeline 级别覆盖。

**When to use:** 所有可配置的保留策略。

**Example:**

```bash
BUILD_CACHE_RETENTION_HOURS="${BUILD_CACHE_RETENTION_HOURS:-24}"
CONTAINER_RETENTION_HOURS="${CONTAINER_RETENTION_HOURS:-24}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
```

[VERIFIED: CONTEXT.md D-04, pipeline-stages.sh:27-30 同模式]

### Pattern 3: 高层 Wrapper 函数

**What:** cleanup_after_deploy() 编排所有清理步骤，pipeline 函数只需调用一个 wrapper。

**When to use:** pipeline_cleanup() 和 pipeline_infra_cleanup() 的增强点。

**Example:**

```bash
cleanup_after_deploy()
{
    local workspace="${1:-$WORKSPACE}"

    # 可通过环境变量跳过特定步骤
    if [[ -z "${SKIP_BUILD_CACHE_CLEANUP:-}" ]]; then
        cleanup_docker_build_cache "$BUILD_CACHE_RETENTION_HOURS"
    fi
    # ... 更多步骤
}
```

[VERIFIED: CONTEXT.md D-03/D-04]

### Anti-Patterns to Avoid

- **直接在 Jenkinsfile 中写清理逻辑:** 所有清理逻辑必须在 cleanup.sh 中，Jenkinsfile 只调用 pipeline_* 函数 [CITED: 项目 CLAUDE.md "Jenkinsfile Declarative Pipeline" 决策]
- **使用 `docker system prune -a`:** 会删除蓝绿 standby 镜像，破坏回滚安全网 [VERIFIED: CLEANUP-RESEARCH.md 十.P1]
- **使用 `docker volume prune --all`:** 会删除 postgres_data 命名卷，威胁核心价值 [VERIFIED: CLEANUP-RESEARCH.md 十.P2]
- **在 cleanup.sh 中 source image-cleanup.sh:** 两个库独立，通过 pipeline-stages.sh 统一加载 [VERIFIED: CONTEXT.md D-02]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Docker 清理命令组合 | 自定义清理脚本 | `docker buildx prune` / `docker container prune` 等 | Docker 原生 prune 命令安全、幂等、有 `--filter` 支持 [VERIFIED: CLEANUP-RESEARCH.md 二] |
| 旧文件按时间删除 | 自定义时间比较逻辑 | `find -mtime +N -delete` | find 的 mtime 是 POSIX 标准，处理边界情况更可靠 [VERIFIED: CLEANUP-RESEARCH.md 四.4] |
| 磁盘用量查询 | 自定义 du 遍历 | `docker system df` + `df -h` | Docker 原生命令精确报告各类型资源占用 [VERIFIED: CLEANUP-RESEARCH.md 五] |

## Common Pitfalls

### Pitfall 1: disk_snapshot 部署前时机错误

**What goes wrong:** disk_snapshot("部署前") 放在 Cleanup 阶段开头而非 Deploy 阶段前，无法真实对比部署前后效果。
**Why it happens:** CONTEXT.md D-06 要求"部署前"和"清理后"各一次，但如果都在 Cleanup 阶段内执行，"部署前"的快照不准确。
**How to avoid:** disk_snapshot("部署前") 需要在 Deploy 阶段前执行（可在 pipeline_deploy() 开头或 pipeline_infra_deploy() 开头调用），disk_snapshot("清理后") 在 Cleanup 阶段末尾。
**Warning signs:** Jenkins 日志中两个快照时间戳非常接近（秒级差异而非分钟级）。

### Pitfall 2: pipeline-stages.sh source 顺序

**What goes wrong:** cleanup.sh 放在 log.sh 之前 source，导致 log_info 等函数未定义。
**Why it happens:** 忽略了 cleanup.sh 依赖 log.sh 的关系。
**How to avoid:** cleanup.sh 必须在 log.sh 之后 source（pipeline-stages.sh 第 15 行之后，建议第 19 行 image-cleanup.sh 之后）。
**Warning signs:** `command not found: log_info` 错误。

### Pitfall 3: cleanup_after_infra_deploy 对所有服务执行相同清理

**What goes wrong:** 对 postgres 服务也执行 `cleanup_docker_build_cache`，但 postgres 不产生 build cache。
**Why it happens:** 忽略了不同基础设施服务的构建方式差异（见 CLEANUP-RESEARCH.md 一.服务架构表）。
**How to avoid:** 使用条件判断，noda-ops 才执行 build cache 清理，keycloak/postgres/nginx 跳过。
**Warning signs:** 日志中出现 postgres/neginx 服务的 `docker buildx prune` 输出（虽然不会出错，但产生误导性日志）。

### Pitfall 4: deploy-failure-*.log 在失败时被删除

**What goes wrong:** 清理 deploy-failure-*.log 在 Cleanup 阶段执行，但如果 Pipeline 失败，Cleanup 阶段不会执行（failure post 中 archiveArtifacts 依赖这些文件）。
**Why it happens:** 混淆了"部署成功后清理"和"部署失败时保留"的场景。
**How to avoid:** cleanup_jenkins_temp_files() 只在 Cleanup 阶段（成功路径）执行。failure post 中 archiveArtifacts 先于 Cleanup 阶段，文件路径正确。当前架构已正确——Cleanup 只在成功时执行，failure post 独立处理失败日志。
**Warning signs:** 手动检查确认 Cleanup stage 不在 failure flow 中。

### Pitfall 5: find -mtime 在 macOS 和 Linux 上行为差异

**What goes wrong:** 开发环境（macOS BSD find）和生产环境（Linux GNU find）的 find 语法不完全兼容。
**Why it happens:** `find -mtime +N` 本身是 POSIX 兼容的，但日期计算可能需要跨平台处理。
**How to avoid:** cleanup_old_infra_backups() 使用标准 `find -mtime +N`（POSIX 兼容），不使用 GNU 特有选项。参考 image-cleanup.sh:67-71 的跨平台日期处理模式。
**Warning signs:** 本地测试通过但生产环境日期计算错误。

## Code Examples

### 现有 Source Guard 模式参考 (deploy-check.sh)

```bash
# Source: scripts/lib/deploy-check.sh:9-13
if [[ -n "${_NODA_DEPLOY_CHECK_LOADED:-}" ]]; then
    return 0
fi
_NODA_DEPLOY_CHECK_LOADED=1
```

### 现有 pipeline_cleanup() 完整结构 (pipeline-stages.sh:411-441)

```bash
# Source: scripts/pipeline-stages.sh:411-441
pipeline_cleanup()
{
    # 停掉非活跃容器，降低资源消耗
    local active_env
    active_env=$(get_active_env)
    local inactive_env
    if [ "$active_env" = "blue" ]; then
        inactive_env="green"
    else
        inactive_env="blue"
    fi
    local inactive_container
    inactive_container=$(get_container_name "$inactive_env")

    if [ "$(is_container_running "$inactive_container")" = "true" ]; then
        log_info "停止非活跃容器: $inactive_container"
        docker stop -t 10 "$inactive_container"
        docker rm "$inactive_container"
        log_success "非活跃容器已清理: $inactive_container"
    else
        log_info "无非活跃容器需要清理"
    fi

    # 官方镜像服务（Keycloak 等）不需要 SHA 镜像清理
    if [ -z "${SERVICE_IMAGE:-}" ]; then
        cleanup_by_date_threshold "${SERVICE_NAME:-findclass-ssr}" "${IMAGE_RETENTION_DAYS:-7}"
    else
        # 仅清理 dangling images
        cleanup_dangling
    fi

    # === NEW: 追加 cleanup_after_deploy 调用 ===
}
```

### 现有 pipeline_infra_cleanup() 完整结构 (pipeline-stages.sh:883-905)

```bash
# Source: scripts/pipeline-stages.sh:883-905
pipeline_infra_cleanup()
{
    local service="$1"

    # 创建备份目录索引（用于审计）
    ls -la "${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}/infra-pipeline/${service}/" 2>/dev/null || true

    case "$service" in
        keycloak)
            # 清理 dangling images（keycloak 使用 SERVICE_IMAGE，不会产生 SHA 标签）
            cleanup_dangling
            ;;
        nginx | noda-ops)
            log_info "$service 无需额外清理"
            ;;
        postgres)
            # 无额外清理
            log_info "PostgreSQL 无需额外清理"
            ;;
        *)
            log_info "未知服务: $service，跳过清理"
            ;;
    esac

    # === NEW: 追加 cleanup_after_infra_deploy 调用 ===
}
```

### pipeline-stages.sh 头部 source 加载顺序 (pipeline-stages.sh:15-19)

```bash
# Source: scripts/pipeline-stages.sh:15-19
source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/manage-containers.sh"
source "$PROJECT_ROOT/scripts/lib/secrets.sh"
source "$PROJECT_ROOT/scripts/lib/deploy-check.sh"
source "$PROJECT_ROOT/scripts/lib/image-cleanup.sh"
# NEW: source "$PROJECT_ROOT/scripts/lib/cleanup.sh"
```

### Jenkinsfile Cleanup 阶段调用模式（4 个 Pipeline 统一）

```groovy
// Source: jenkins/Jenkinsfile.findclass-ssr:153-161
stage('Cleanup') {
    steps {
        sh '''
            source scripts/lib/log.sh
            source scripts/pipeline-stages.sh
            pipeline_cleanup
        '''
    }
}

// Source: jenkins/Jenkinsfile.infra:106-114
stage('Cleanup') {
    steps {
        sh '''
            source scripts/lib/log.sh
            source scripts/pipeline-stages.sh
            pipeline_infra_cleanup "$SERVICE"
        '''
    }
}
```

### disk_snapshot 部署前时机问题（关键集成点）

**当前 Deploy 阶段调用模式：**

```groovy
// jenkins/Jenkinsfile.findclass-ssr Deploy 阶段
stage('Deploy') {
    steps {
        sh '''
            source scripts/lib/log.sh
            source scripts/pipeline-stages.sh
            pipeline_deploy "$TARGET_ENV" "$GIT_SHA"
        '''
    }
}
```

**方案选择：** disk_snapshot("部署前") 放在 pipeline_deploy() / pipeline_infra_deploy() 函数内部开头（最简单），或在 Jenkinsfile 的 Deploy stage 前新增一个 sh 步骤。推荐放在 pipeline 函数内部，避免修改 Jenkinsfile。

[VERIFIED: 所有 4 个 Jenkinsfile 源码已审查]

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| 无 build cache 清理 | `docker buildx prune --filter until=24h` | Phase 43 (本次) | 每次部署回收 500MB+ build cache |
| 无 node_modules 清理 | `rm -rf $WORKSPACE/noda-apps/node_modules` | Phase 43 (本次) | 每次回收 200-500MB |
| 无备份文件清理 | `find -mtime +30 -delete` | Phase 43 (本次) | 防止 infra-pipeline 备份无限增长 |
| `docker system prune` 一键清理 | 分步 prune 各资源类型 | Phase 43 (本次) | 细粒度控制 + 可追溯日志 |

**Deprecated/outdated:**
- `docker system prune -a --volumes`: 风险过高，会删除蓝绿 standby 镜像和命名卷
- `cleanup_dangling()` in image-cleanup.sh: 继续保留，cleanup.sh 的 `cleanup_dangling_images()` 功能等价但使用 `docker image prune -f`

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | 4 个 Jenkinsfile 不需要修改，修改 pipeline-stages.sh 中的函数即可 | Architecture Patterns | MEDIUM — 需确认 disk_snapshot("部署前") 的放置位置不影响 Jenkinsfile |
| A2 | cleanup_after_infra_deploy() 需要作为独立 wrapper（而非复用 cleanup_after_deploy + 参数） | Architecture Patterns | LOW — 两种方案都可行，infra 专用 wrapper 更清晰 |
| A3 | disk_snapshot("部署前") 放在 pipeline_deploy() / pipeline_infra_deploy() 内部开头 | Code Examples | MEDIUM — 可能导致快照包含旧部署的残留而非干净的"部署前"状态 |

## Open Questions

1. **disk_snapshot("部署前") 放置位置的最终决策**
   - What we know: CONTEXT.md D-06 要求"部署前"和"清理后"各一次
   - What's unclear: "部署前"是指 pipeline_deploy() 开头还是 Jenkinsfile Deploy stage 开头
   - Recommendation: 放在 pipeline_deploy() 开头和 pipeline_infra_deploy() 开头——最简单且不修改 Jenkinsfile

2. **cleanup_after_infra_deploy vs cleanup_after_deploy + 参数**
   - What we know: infra Pipeline 需要的清理项不同于 app Pipeline（需要备份清理，部分不需要 build cache）
   - What's unclear: 是用一个函数 + 参数控制，还是两个独立 wrapper
   - Recommendation: 两个独立 wrapper（cleanup_after_deploy + cleanup_after_infra_deploy），职责更清晰

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker CLI | 所有 docker prune 命令 | 是 (生产) | 24+ | -- |
| docker buildx | cleanup_docker_build_cache | 是 (生产) | 随 Docker 安装 | -- |
| Bash 5.x | cleanup.sh 函数库 | 是 (生产) | 5.x | -- |
| find (GNU/BSD) | cleanup_old_infra_backups | 是 (生产) | GNU find | -- |
| Jenkins | Pipeline 执行环境 | 是 (生产) | LTS 2.541.x | -- |

**Missing dependencies with no fallback:**
- 无缺失依赖

**Missing dependencies with fallback:**
- 无

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | 手动 Pipeline 触发验证（无自动化测试框架） |
| Config file | 无 |
| Quick run command | 手动触发 Pipeline + 检查 Jenkins 构建日志 |
| Full suite command | 依次触发 4 个 Pipeline 并检查日志 |

### Phase Requirements -> Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DOCK-01 | build cache 清理（保留 24h） | manual-only | 手动触发 findclass-ssr Pipeline，检查日志中 `docker buildx prune` 输出 | N/A (Wave 0) |
| DOCK-02 | 已停止容器清理 | manual-only | 手动触发 Pipeline，检查日志中 `docker container prune` 输出 | N/A |
| DOCK-03 | 匿名卷清理（不含命名卷） | manual-only | 手动触发 Pipeline，检查日志；额外验证 `postgres_data` 卷仍存在 | N/A |
| DOCK-04 | 部署前后磁盘快照 | manual-only | 手动触发 Pipeline，检查日志中有"部署前"和"清理后"两个快照 | N/A |
| CACHE-01 | node_modules 清理 | manual-only | 手动触发 findclass-ssr Pipeline，检查日志中 node_modules 大小和清理输出 | N/A |
| FILE-01 | 旧备份文件清理 | manual-only | 手动触发 infra Pipeline（postgres），检查日志中备份清理输出 | N/A |
| FILE-02 | deploy-failure-*.log 清理 | manual-only | 成功部署后检查 workspace 中无 deploy-failure-*.log | N/A |

### Sampling Rate

- **Per task commit:** 无自动化测试（纯 shell 脚本）
- **Per wave merge:** 无自动化测试
- **Phase gate:** 手动触发 4 个 Pipeline 做端到端验证（Plan 43-03）

### Wave 0 Gaps

- 测试框架：无（CONTEXT.md D-08 明确不编写独立测试脚本）
- 所有验证通过手动 Pipeline 触发完成

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | yes | 所有 find/prune 命令使用固定参数，不接受外部输入 |
| V6 Cryptography | no | -- |
| V2 Authentication | no | -- |
| V4 Access Control | yes | Jenkins 用户权限控制 Pipeline 触发；docker 组权限控制清理命令执行 |

### Known Threat Patterns for Docker Cleanup

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| postgres_data 卷被误删 | Tampering/Destruction | 绝不使用 `--all` 标志；`docker volume prune -f` 只清理匿名卷 [VERIFIED: CLEANUP-RESEARCH.md 七] |
| 蓝绿 standby 镜像被删除 | Denial of Service | 不使用 `docker system prune -a`；使用 image-cleanup.sh 的按日期阈值清理 [VERIFIED: CLEANUP-RESEARCH.md 十.P1] |
| 清理命令在构建过程中运行 | Denial of Service | 清理只在 Cleanup 阶段执行（构建完成后）；`disableConcurrentBuilds()` 防止并发 [VERIFIED: Jenkinsfile 配置] |

## Integration Matrix: 需求 -> 函数 -> Pipeline 映射

| 清理项 | cleanup.sh 函数 | findclass-ssr | noda-site | keycloak | infra |
|--------|----------------|:---:|:---:|:---:|:---:|
| Build cache | cleanup_docker_build_cache | YES | YES | NO | noda-ops: YES |
| 已停止容器 | cleanup_stopped_containers | YES | YES | YES | YES |
| 未使用网络 | cleanup_unused_networks | YES | YES | YES | YES |
| 匿名卷 | cleanup_anonymous_volumes | YES | YES | YES | YES |
| node_modules | cleanup_node_modules | YES | YES | NO | NO |
| 临时文件 | cleanup_jenkins_temp_files | YES | YES | YES | YES |
| 旧备份 | cleanup_old_infra_backups | NO | NO | NO | YES |
| 磁盘快照 | disk_snapshot | 2次 | 2次 | 2次 | 2次 |

[VERIFIED: CLEANUP-RESEARCH.md 八.功能矩阵]

## File Change Inventory

### 新建文件

| 文件 | 描述 |
|------|------|
| `scripts/lib/cleanup.sh` | 综合清理共享库（约 200-250 行） |

### 修改文件

| 文件 | 修改点 | 行号 | 描述 |
|------|--------|------|------|
| `scripts/pipeline-stages.sh` | source cleanup.sh | ~L19 | 头部追加 `source "$PROJECT_ROOT/scripts/lib/cleanup.sh"` |
| `scripts/pipeline-stages.sh` | pipeline_cleanup() | ~L441 | 函数末尾追加 `cleanup_after_deploy "$WORKSPACE"` 调用 |
| `scripts/pipeline-stages.sh` | pipeline_infra_cleanup() | ~L905 | 函数末尾追加 `cleanup_after_infra_deploy "$SERVICE" "$WORKSPACE"` 调用 |
| `scripts/pipeline-stages.sh` | pipeline_deploy() | ~L291 | 函数开头追加 `disk_snapshot "部署前"` 调用 |
| `scripts/pipeline-stages.sh` | pipeline_infra_deploy() | ~L589 | 函数开头追加 `disk_snapshot "部署前"` 调用 |

### 不修改的文件

| 文件 | 原因 |
|------|------|
| `jenkins/Jenkinsfile.findclass-ssr` | 调用 pipeline_cleanup()，函数内部增强即可 |
| `jenkins/Jenkinsfile.noda-site` | 同上 |
| `jenkins/Jenkinsfile.keycloak` | 同上 |
| `jenkins/Jenkinsfile.infra` | 调用 pipeline_infra_cleanup()，函数内部增强即可 |
| `scripts/lib/image-cleanup.sh` | 与 cleanup.sh 并存不合并 |
| `scripts/lib/log.sh` | cleanup.sh 依赖但不需要修改 |

## Sources

### Primary (HIGH confidence)
- CLEANUP-RESEARCH.md -- 完整的清理命令研究、函数模板、安全考量（11 章）
- scripts/pipeline-stages.sh -- 现有 pipeline_cleanup() 和 pipeline_infra_cleanup() 源码
- scripts/lib/image-cleanup.sh -- Source Guard 模式参考
- scripts/lib/deploy-check.sh -- Source Guard 模式参考
- scripts/lib/log.sh -- 日志函数 API
- jenkins/Jenkinsfile.* (4 个) -- Pipeline 调用模式

### Secondary (MEDIUM confidence)
- CONTEXT.md D-01~D-08 -- Phase 43 锁定决策
- STATE.md -- v1.9 研究决策（build cache 24h、volume prune 不加 --all 等）

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- 所有命令和模式在 CLEANUP-RESEARCH.md 中已验证
- Architecture: HIGH -- 集成点明确（pipeline-stages.sh 3 个位置），现有模式清晰
- Pitfalls: HIGH -- 已在生产环境运行中积累经验，CLEANUP-RESEARCH.md 十章详细记录
- Integration: HIGH -- 4 个 Jenkinsfile 和 pipeline-stages.sh 已完整审查

**Research date:** 2026-04-19
**Valid until:** 2026-05-19 (30 天，shell 脚本和 Docker API 稳定)
