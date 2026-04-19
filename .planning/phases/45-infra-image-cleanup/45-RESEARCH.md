# Phase 45: Infra Pipeline 镜像清理补全 - Research

**Researched:** 2026-04-19
**Domain:** Docker 镜像清理 / Jenkins Pipeline 集成
**Confidence:** HIGH

## Summary

Phase 45 是一个精确的"填补空缺"任务：infra Pipeline 的 `pipeline_infra_cleanup()` 函数中，nginx 和 noda-ops 的 case 分支当前输出"无需额外清理"，但实际上 noda-ops 每次 `docker compose build` 会产生带 SHA 标签的旧镜像堆积。需要为 noda-ops 添加 `cleanup_by_date_threshold` 调用，而 nginx 的情况不同——它使用外部预构建镜像，旧镜像由通用 wrapper 中的 `cleanup_dangling_images()` 覆盖。

所有基础设施已就绪：`image-cleanup.sh` 已在 `pipeline-stages.sh` 第 19 行 source，`cleanup_by_date_threshold` 函数已在 findclass-ssr 和 keycloak Pipeline 中验证过，`cleanup_after_infra_deploy()` 通用 wrapper 已在 Phase 43 建立。本 phase 的代码改动量极小（约 5 行），核心工作是验证。

**Primary recommendation:** 修改 `pipeline_infra_cleanup()` 的 case 分支，将 `nginx | noda-ops)` 拆分为两个独立分支，noda-ops 调用 `cleanup_by_date_threshold "noda-ops"`，nginx 保持不变（由通用 wrapper 处理 dangling）。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** noda-ops 使用 `cleanup_by_date_threshold("noda-ops")`，保留容器在用镜像 + latest 标签，删除所有其他旧 SHA 标签镜像。与 findclass-ssr、keycloak 统一策略
- **D-02:** 调用位置在 `pipeline_infra_cleanup()` 的 case 分支中，替换当前的 `"无需额外清理"` 为 `cleanup_by_date_threshold "noda-ops"`
- **D-03:** nginx 使用外部镜像 `nginx:1.25-alpine`，版本变更后旧镜像变 dangling。现有 `cleanup_after_infra_deploy()` 中的 `cleanup_dangling_images()` 已足够覆盖，不需要额外清理调用
- **D-04:** nginx 的 case 分支保持 `"无需额外清理"` 不变（dangling 清理由通用 wrapper 处理）
- **D-05:** 手动触发 noda-ops 和 nginx 两个 infra Pipeline 验证。检查构建日志中镜像清理输出和磁盘快照
- **D-06:** 验证 postgres_data 卷安全不受影响（确认匿名卷清理不加 `--all`）

### Claude's Discretion
- pipeline_infra_cleanup() 中 case 分支的具体代码修改
- 验证步骤的具体命令和日志检查项

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| IMG-01 | noda-ops 部署后旧镜像自动清理，只保留当前在用镜像 + latest | cleanup_by_date_threshold("noda-ops") 已验证，见"Code Examples" |
| IMG-02 | nginx 部署后旧镜像自动清理（dangling images） | cleanup_after_infra_deploy() 已含 cleanup_dangling_images()，见"标准清理路径" |
</phase_requirements>
</phase_requirements>
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| 镜像保留策略清理 | API / Backend (shell 脚本) | -- | cleanup_by_date_threshold 在 Jenkins Pipeline 中执行，操作宿主机 Docker daemon |
| Dangling images 清理 | API / Backend (shell 脚本) | -- | cleanup_dangling_images 在 cleanup.sh wrapper 中，由 Pipeline 调用 |
| Pipeline 执行控制 | CI/CD (Jenkins) | -- | Jenkinsfile.infra Cleanup 阶段触发 pipeline_infra_cleanup() |

## Standard Stack

### Core
| Library/Component | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| image-cleanup.sh | 已存在 (Phase 37 建立) | cleanup_by_date_threshold() 函数 | noda-ops 镜像清理的核心函数，已在 findclass-ssr/keycloak Pipeline 验证 [VERIFIED: 代码库] |
| cleanup.sh | 已存在 (Phase 43 建立) | cleanup_after_infra_deploy() wrapper | 通用清理入口，已含 dangling images / containers / networks / volumes 清理 [VERIFIED: 代码库] |
| pipeline-stages.sh | 当前版本 | pipeline_infra_cleanup() 函数 | 修改目标，line 891-917 [VERIFIED: 代码库] |
| Jenkinsfile.infra | 当前版本 | Infra Pipeline Cleanup 阶段 | 调用 pipeline_infra_cleanup()，无需修改 [VERIFIED: 代码库] |

### Supporting
| Library/Component | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| log.sh | 已存在 | 日志输出 | 所有清理函数依赖 |
| manage-containers.sh | 已存在 | 容器管理辅助函数 | is_container_running 等 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| cleanup_by_date_threshold | cleanup_by_tag_count | tag_count 保留最近 N 个标签，不检查容器使用状态；date_threshold 按容器使用状态清理更精确（Phase 37 已修复） |

**Installation:** 无需安装新依赖，所有库已在项目中。

## Architecture Patterns

### System Architecture Diagram

```
Jenkinsfile.infra Cleanup 阶段
        |
        v
pipeline_infra_cleanup(service)
        |
        +-- case service
        |     |
        |     +-- keycloak --> cleanup_dangling()          [已有]
        |     |
        |     +-- nginx -------> log_info "无需额外清理"    [不变，dangling 由 wrapper 处理]
        |     |
        |     +-- noda-ops ----> cleanup_by_date_threshold("noda-ops")  [本 phase 新增]
        |     |
        |     +-- postgres ----> log_info "无需额外清理"    [已有]
        |
        v
cleanup_after_infra_deploy(service)    [Phase 43 已建立]
        |
        +-- cleanup_docker_build_cache()     (noda-ops only)
        +-- cleanup_old_infra_backups()
        +-- cleanup_dangling_images()        <--- nginx 的旧镜像在此清理
        +-- cleanup_stopped_containers()
        +-- cleanup_unused_networks()
        +-- cleanup_anonymous_volumes()      <--- 安全：不加 --all，保护 postgres_data
        +-- cleanup_jenkins_temp_files()
        +-- disk_snapshot("清理后")
```

### Recommended Project Structure
```
scripts/
├── lib/
│   ├── image-cleanup.sh    # cleanup_by_date_threshold() — 本 phase 调用目标
│   ├── cleanup.sh          # cleanup_after_infra_deploy() — 通用 wrapper
│   └── log.sh              # 日志函数
├── pipeline-stages.sh      # pipeline_infra_cleanup() — 修改目标
jenkins/
└── Jenkinsfile.infra       # 无需修改
```

### Pattern 1: Case 分支服务特定清理 + 通用 Wrapper
**What:** `pipeline_infra_cleanup()` 先做服务特定清理（case 分支），再调用通用 `cleanup_after_infra_deploy()` wrapper。两阶段设计确保每个服务的特殊需求得到满足，通用清理不遗漏。
**When to use:** 所有 infra Pipeline 清理场景
**Example:**
```bash
# Source: pipeline-stages.sh:891-917 (当前代码 + 本 phase 修改后)
pipeline_infra_cleanup()
{
    local service="$1"

    # 服务特定清理
    case "$service" in
        keycloak)
            cleanup_dangling
            ;;
        nginx)
            log_info "$service 无需额外清理（dangling 清理由通用 wrapper 处理）"
            ;;
        noda-ops)
            cleanup_by_date_threshold "noda-ops"   # <-- 本 phase 新增
            ;;
        postgres)
            log_info "PostgreSQL 无需额外清理"
            ;;
    esac

    # === 通用清理（所有服务共享）===
    cleanup_after_infra_deploy "$service" "${WORKSPACE:-$PWD}"
}
```

### Pattern 2: cleanup_by_date_threshold 安全清理策略
**What:** 按容器使用状态决定保留哪些镜像，而非按时间或数量。始终保留：正在被容器使用的镜像 ID + latest 标签对应的镜像 ID。
**When to use:** 每次构建产生新 SHA 标签的本地构建镜像（noda-ops, findclass-ssr）
**Example:**
```bash
# Source: image-cleanup.sh:59-123
# 核心逻辑：
# 1. 收集所有容器引用的镜像 ID（精确匹配容器名前缀）
# 2. 始终保留 latest 标签镜像 ID
# 3. 删除不在 in_use_ids 中的非 latest 标签镜像
# 4. 清理 dangling images

cleanup_by_date_threshold "noda-ops"
# 结果：保留 noda-ops:latest + noda-ops 容器当前使用的镜像，删除所有旧 SHA 标签
```

### Anti-Patterns to Avoid
- **在通用 wrapper 中调用 cleanup_by_date_threshold:** wrapper 是所有服务共享的，不应包含服务特定逻辑。服务特定清理必须在 case 分支中。
- **对 nginx 调用 cleanup_by_date_threshold:** nginx 是外部预构建镜像（nginx:1.25-alpine），本地只有一个标签，没有 SHA 标签堆积问题。调用 cleanup_by_date_threshold 虽不会出错但完全多余。
- **在 case 分支中重复调用通用 wrapper 已有的清理:** 如 dangling images、stopped containers 等——通用 wrapper 已覆盖，不要重复调用。

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 镜像保留策略 | 自定义 docker rmi 逻辑 | cleanup_by_date_threshold | 已处理容器使用状态检测、latest 保留、dangling 清理等边界情况 |
| 通用部署后清理 | 手动串联多个 docker prune 命令 | cleanup_after_infra_deploy | 已建立 8 步清理流程 + 磁盘快照 |

**Key insight:** 本 phase 改动量极小（约 5 行代码修改），核心价值在于正确理解现有架构并找到精确的集成点。

## Common Pitfalls

### Pitfall 1: 合并 nginx 和 noda-ops 分支
**What goes wrong:** 当前 `nginx | noda-ops)` 是合并的 case 分支。如果不拆分，给 noda-ops 添加 cleanup_by_date_threshold 会导致 nginx 也执行该调用（虽然不会出错但多余）。
**Why it happens:** 原本两者确实不需要额外清理，现在 noda-ops 需要了。
**How to avoid:** 拆分为两个独立分支，如 CONTEXT.md 代码示例所示。
**Warning signs:** 如果 nginx Pipeline 日志中出现 "镜像清理: 清理 nginx 未使用的旧镜像..." 就说明分支没拆分。

### Pitfall 2: 忘记 image-cleanup.sh 已 source
**What goes wrong:** 试图在 pipeline-stages.sh 中添加新的 source 语句。
**Why it happens:** 不熟悉代码结构。
**How to avoid:** 已确认 `pipeline-stages.sh:19` 有 `source "$PROJECT_ROOT/scripts/lib/image-cleanup.sh"`，函数可直接调用。
**Warning signs:** ShellCheck 或 runtime 报 "command not found: cleanup_by_date_threshold"。

### Pitfall 3: 验证时触发 postgres Pipeline
**What goes wrong:** 验证范围是 noda-ops 和 nginx（D-05），不需要验证 postgres。postgres Pipeline 涉及数据库重启和人工确认，风险高且与镜像清理无关。
**Why it happens:** Jenkinsfile.infra 支持 3 种服务，可能顺手都触发。
**How to avoid:** 验证 plan 中只触发 noda-ops 和 nginx 两个 Pipeline。
**Warning signs:** 验证 plan 中出现 postgres 相关操作。

### Pitfall 4: 验证时未检查 postgres_data 卷安全
**What goes wrong:** D-06 要求确认 postgres_data 卷安全，但如果只看构建日志不检查 docker volume ls，可能漏掉异常。
**Why it happens:** 过于关注镜像清理输出，忽略了卷安全验证。
**How to avoid:** 验证步骤中明确包含 `docker volume ls | grep postgres_data` 命令。
**Warning signs:** 验证步骤中无 postgres_data 相关检查。

## Code Examples

### 核心修改：pipeline_infra_cleanup() case 分支拆分

```bash
# 当前代码 (pipeline-stages.sh:898-905)
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

# 修改后
case "$service" in
    keycloak)
        cleanup_dangling
        ;;
    nginx)
        log_info "$service 无需额外清理（dangling 清理由通用 wrapper 处理）"
        ;;
    noda-ops)
        cleanup_by_date_threshold "noda-ops"
        ;;
    postgres)
        log_info "PostgreSQL 无需额外清理"
        ;;
    *)
        log_info "未知服务: $service，跳过清理"
        ;;
esac
```

### 验证命令

```bash
# 1. 部署前检查当前 noda-ops 镜像状态
docker images noda-ops --format '{{.Tag}} {{.ID}} {{.CreatedAt}}'

# 2. 触发 noda-ops infra Pipeline（通过 Jenkins API）
source scripts/jenkins/config/jenkins-admin.env
CRUMB=$(curl -sf -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  "http://localhost:8888/crumbIssuer/api/json" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])")
curl -sf -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  -X POST -H "$CRUMB" \
  "http://localhost:8888/job/infra-deploy/build-withParameters?SERVICE=noda-ops"

# 3. 部署后检查镜像（应该只剩 latest + 当前使用的 SHA）
docker images noda-ops --format '{{.Tag}} {{.ID}} {{.CreatedAt}}'

# 4. 确认 postgres_data 卷不受影响
docker volume ls | grep postgres_data
```

### noda-ops 镜像特征

```bash
# noda-ops 每次 docker compose build 产生：
# - noda-ops:latest  (指向最新构建)
# - noda-ops:<sha>   (每次构建的旧标签)
# 当前环境只有一个镜像（latest），因为没有多次构建历史：
# noda-ops:latest    613fb944cd77   306MB   Up (healthy)

# 多次部署后会堆积：
# noda-ops:latest    abc123...      306MB   当前在用
# noda-ops:a1b2c3d   def456...      305MB   旧版本 <- 应被清理
# noda-ops:e4f5g6h   789012...      304MB   旧版本 <- 应被清理
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| cleanup_by_tag_count（按数量保留） | cleanup_by_date_threshold（按容器使用状态保留） | Phase 37 | 更精确：不依赖固定数量，基于实际使用情况决定 |
| pipeline_infra_cleanup 仅 keycloak 清理 | 所有无 dangling 的服务跳过清理 | Phase 43 | noda-ops 的镜像堆积未被发现 |

**Deprecated/outdated:**
- cleanup_by_tag_count 第二个参数 retention_days 已弃用（保留参数兼容性但不再使用时间阈值逻辑）

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | cleanup_by_date_threshold 的容器名匹配 `grep "^${image_name}"` 对 noda-ops 有效 | Pattern 2 | 低：noda-ops 容器名就是 "noda-ops"，前缀匹配精确 [VERIFIED: docker ps 输出] |
| A2 | nginx 升级时旧版本镜像会变为 dangling | D-03 | 低：Docker pull 新版本 nginx:1.25-alpine 时，如果 digest 变化，旧镜像失去标签变 dangling [ASSUMED] |

## Open Questions

1. **是否需要预先制造 noda-ops 旧镜像来验证清理效果？**
   - What we know: 当前环境只有一个 noda-ops:latest，没有旧 SHA 标签
   - What's unclear: 验证时是否需要先多次构建产生旧镜像来验证 cleanup_by_date_threshold 实际执行了删除
   - Recommendation: 不需要。部署一次 noda-ops 后会产生新的 SHA 标签（旧的 latest digest 变成无标签），cleanup_by_date_threshold 会清理它。检查日志中 "删除 noda-ops:xxx" 或 "镜像清理: 无需清理" 输出即可

2. **nginx 版本升级验证是否在范围内？**
   - What we know: nginx 当前使用 1.25-alpine，无版本变更计划
   - What's unclear: 是否需要测试 nginx 版本升级后的 dangling 清理
   - Recommendation: 不需要。nginx 版本升级是低频操作，当前验证只需确认 Pipeline 日志中有 cleanup_dangling_images 输出

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | 镜像清理 | ✓ | 24.x+ | -- |
| Jenkins | Pipeline 执行 | ✓ | LTS | -- |
| ShellCheck | 代码质量检查 | 待确认 | -- | 手动检查 |
| bash | 脚本执行 | ✓ | macOS zsh/bash | -- |

**Missing dependencies with no fallback:** None

**Missing dependencies with fallback:** None

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | 手动验证（通过 Jenkins Pipeline 构建日志） |
| Config file | 无独立测试配置 |
| Quick run command | `shellcheck scripts/pipeline-stages.sh` |
| Full suite command | 手动触发 Jenkins Pipeline + 检查日志 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| IMG-01 | noda-ops 部署后清理旧镜像 | manual-only | `shellcheck scripts/pipeline-stages.sh` | N/A |
| IMG-02 | nginx 部署后清理 dangling images | manual-only | 通过 Jenkins 构建日志验证 | N/A |

**Manual-only justification:** 清理函数操作 Docker daemon 状态，需要真实 Docker 环境和 Jenkins Pipeline 上下文。单元测试无法模拟 docker images/ps/rmi 的完整交互。

### Sampling Rate
- **Per task commit:** `shellcheck scripts/pipeline-stages.sh`
- **Per wave merge:** 手动触发 Pipeline 验证
- **Phase gate:** noda-ops + nginx 两个 Pipeline 构建日志中确认清理输出

### Wave 0 Gaps
None -- 现有 ShellCheck 配置和手动验证流程覆盖本 phase 需求。

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | yes | case 分支限制服务名（nginx/noda-ops/postgres/keycloak） |
| V6 Cryptography | no | -- |

### Known Threat Patterns for Docker Cleanup

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 误删 postgres_data 命名卷 | Tampering | `docker volume prune -f` 不加 `--all`，只清理匿名卷 [VERIFIED: cleanup.sh:108] |
| 误删蓝绿回滚镜像 | Denial of Service | cleanup_by_date_threshold 保留容器在用镜像 ID [VERIFIED: image-cleanup.sh:66-77] |
| 清理失败导致 Pipeline 中断 | Denial of Service | 所有清理函数 `|| true` 确保失败不传播 [VERIFIED: image-cleanup.sh:106, cleanup.sh:39] |

## Sources

### Primary (HIGH confidence)
- `scripts/lib/image-cleanup.sh` — cleanup_by_date_threshold 函数实现，已完整阅读
- `scripts/lib/cleanup.sh` — cleanup_after_infra_deploy wrapper 实现，已完整阅读
- `scripts/pipeline-stages.sh` — pipeline_infra_cleanup 函数，已阅读 line 891-917
- `jenkins/Jenkinsfile.infra` — Infra Pipeline 结构，已完整阅读
- `docker/docker-compose.yml` — noda-ops 服务定义（image: noda-ops:latest, build 模式）

### Secondary (MEDIUM confidence)
- `docker images` 实际输出 — 当前环境只有 noda-ops:latest 一个镜像

### Tertiary (LOW confidence)
- nginx 版本升级时旧镜像变 dangling 的行为 — [ASSUMED]，基于 Docker 镜像标签机制推断

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有组件已存在且经过验证（Phase 37/43）
- Architecture: HIGH — 代码结构清晰，集成点明确（case 分支拆分）
- Pitfalls: HIGH — 基于实际代码分析，非推测
- Security: HIGH — postgres_data 保护机制已验证（cleanup.sh:108，不加 --all）

**Research date:** 2026-04-19
**Valid until:** 2026-05-19（稳定，无外部依赖变化）
