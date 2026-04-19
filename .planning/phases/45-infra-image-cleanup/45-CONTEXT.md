# Phase 45: Infra Pipeline 镜像清理补全 - Context

**Gathered:** 2026-04-19
**Status:** Ready for planning

<domain>
## Phase Boundary

补全 infra Pipeline 中 noda-ops 和 nginx 的旧镜像清理逻辑，确保所有服务部署后无残留镜像堆积。

**涉及需求：** IMG-01, IMG-02

**前置条件：** Phase 43 已完成 — cleanup.sh 和 image-cleanup.sh 已建立，cleanup_by_date_threshold 已修复为"保留容器在用镜像 + latest"

**Plans:**
- 45-01: pipeline_infra_cleanup 增加 noda-ops/nginx 镜像清理调用
- 45-02: 手动触发 infra Pipeline 端到端验证

</domain>

<decisions>
## Implementation Decisions

### noda-ops 镜像清理策略
- **D-01:** noda-ops 使用 `cleanup_by_date_threshold("noda-ops")`，保留容器在用镜像 + latest 标签，删除所有其他旧 SHA 标签镜像。与 findclass-ssr、keycloak 统一策略
- **D-02:** 调用位置在 `pipeline_infra_cleanup()` 的 case 分支中，替换当前的 `"无需额外清理"` 为 `cleanup_by_date_threshold "noda-ops"`

### nginx 镜像清理策略
- **D-03:** nginx 使用外部镜像 `nginx:1.25-alpine`，版本变更后旧镜像变 dangling。现有 `cleanup_after_infra_deploy()` 中的 `cleanup_dangling_images()` 已足够覆盖，不需要额外清理调用
- **D-04:** nginx 的 case 分支保持 `"无需额外清理"` 不变（dangling 清理由通用 wrapper 处理）

### 验证范围
- **D-05:** 手动触发 noda-ops 和 nginx 两个 infra Pipeline 验证。检查构建日志中镜像清理输出和磁盘快照
- **D-06:** 验证 postgres_data 卷安全不受影响（确认匿名卷清理不加 `--all`）

### Claude's Discretion
- pipeline_infra_cleanup() 中 case 分支的具体代码修改
- 验证步骤的具体命令和日志检查项

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 需求定义
- `.planning/ROADMAP.md` §Phase 45 — 目标、依赖、成功标准（IMG-01, IMG-02）
- `.planning/REQUIREMENTS.md` — v1.9 需求文档

### 前序 Phase 决策
- `.planning/phases/43-cleanup-pipeline/43-CONTEXT.md` — cleanup.sh 与 image-cleanup.sh 并存策略、cleanup_after_infra_deploy() wrapper、Source Guard 模式
- `.planning/phases/35-shared-libs/35-CONTEXT.md` — 共享库模式

### 现有实现（必须阅读）
- `scripts/lib/image-cleanup.sh` — `cleanup_by_date_threshold()` 函数，Phase 45 的核心调用目标
- `scripts/lib/cleanup.sh` — `cleanup_after_infra_deploy()` wrapper，line 260-298
- `scripts/pipeline-stages.sh` §`pipeline_infra_cleanup()` line 891-917 — **修改目标**
- `scripts/pipeline-stages.sh` §`pipeline_infra_deploy_noda_ops()` line 675-692 — noda-ops 构建方式（docker compose build）
- `jenkins/Jenkinsfile.infra` — Infra Pipeline Cleanup 阶段

### 项目级配置
- `.planning/PROJECT.md` — 已锁定决策（Source Guard 模式、镜像清理策略）
- `.planning/STATE.md` — v1.9 研究决策

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/lib/image-cleanup.sh:cleanup_by_date_threshold()` — noda-ops 镜像清理的核心函数，已在 findclass-ssr 和 keycloak Pipeline 中验证
- `scripts/lib/cleanup.sh:cleanup_after_infra_deploy()` — infra 部署后通用清理 wrapper，已包含 dangling images、containers、networks、volumes 清理
- `scripts/lib/cleanup.sh:cleanup_dangling_images()` — nginx 场景的 dangling images 清理，已被通用 wrapper 调用

### Established Patterns
- Source Guard: `if [[ -n "${_NODA_<LIBRARY>_LOADED:-}" ]]; then return 0; fi`
- image-cleanup.sh 与 cleanup.sh 并存不合并（职责分离：镜像保留策略 vs 部署后全面清理）
- `pipeline_infra_cleanup()` 先做服务特定清理（case 分支），再调用通用 wrapper
- `|| true` 确保清理失败不传播

### Integration Points
- `scripts/pipeline-stages.sh:898-905` — `pipeline_infra_cleanup()` case 分支，`nginx | noda-ops)` 当前输出"无需额外清理"，需修改 noda-ops 分支添加 `cleanup_by_date_threshold` 调用
- `scripts/pipeline-stages.sh:916` — `cleanup_after_infra_deploy()` 通用清理调用（已存在，无需修改）
- `docker/docker-compose.yml:61-66` — noda-ops 服务定义，`image: noda-ops:latest`，`build: dockerfile: deploy/Dockerfile.noda-ops`

### 关键代码：当前 pipeline_infra_cleanup() 的 case 分支
```bash
nginx | noda-ops)
    log_info "$service 无需额外清理"
    ;;
```
需改为：
```bash
nginx)
    log_info "$service 无需额外清理（dangling 清理由通用 wrapper 处理）"
    ;;
noda-ops)
    cleanup_by_date_threshold "noda-ops"
    ;;
```

</code_context>

<specifics>
## Specific Ideas

- noda-ops 每次构建产生新的 SHA 标签镜像（docker compose build），latest 始终指向最新。旧 SHA 标签堆积是磁盘占用的主要来源
- nginx 是外部预构建镜像（nginx:1.25-alpine），本地无多版本标签。版本升级时旧镜像变 dangling，由 `cleanup_dangling_images()` 覆盖
- cleanup_by_date_threshold 已在 Phase 37 修复为按容器使用状态清理（而非按时间），比 cleanup_by_tag_count 更精确
- 需确认 pipeline-stages.sh 已 source image-cleanup.sh（通过 cleanup.sh 或直接 source）

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 45-infra-image-cleanup*
*Context gathered: 2026-04-19*
