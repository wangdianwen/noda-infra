# Phase 43: 清理共享库 + Pipeline 集成 - Context

**Gathered:** 2026-04-19
**Status:** Ready for planning

<domain>
## Phase Boundary

新建 `scripts/lib/cleanup.sh` 共享库（Docker/Node.js/文件清理函数 + 磁盘快照），增强 `pipeline_cleanup()` 和 `pipeline_infra_cleanup()` 集成 cleanup.sh，部署后自动清理所有构建残留和缓存。

**涉及需求：** DOCK-01, DOCK-02, DOCK-03, DOCK-04, CACHE-01, FILE-01, FILE-02

**前置条件：** Phase 42 已完成 — Pipeline 和共享库体系已建立（image-cleanup.sh、deploy-check.sh 等已存在）

**Plans:**
- 43-01: 新建 scripts/lib/cleanup.sh 共享库（Docker/Node.js/文件清理函数 + 磁盘快照）
- 43-02: 增强 pipeline_cleanup() 和 pipeline_infra_cleanup()（集成 cleanup.sh）
- 43-03: 验证与测试（手动触发 Pipeline 验证清理效果）

</domain>

<decisions>
## Implementation Decisions

### 库关系：cleanup.sh 与 image-cleanup.sh
- **D-01:** cleanup.sh 与 image-cleanup.sh 并存不合并。职责分离：image-cleanup.sh 专注镜像保留策略（cleanup_by_tag_count, cleanup_by_date_threshold, cleanup_dangling），cleanup.sh 专注部署后全面清理（build cache, containers, volumes, node_modules, temp files, backups）
- **D-02:** pipeline_cleanup() 同时 source 两个库（image-cleanup.sh + cleanup.sh），不互相依赖

### Pipeline 调用方式
- **D-03:** cleanup.sh 提供 `cleanup_after_deploy()` 高层 wrapper 函数，内部按顺序执行所有清理步骤。pipeline_cleanup() 和 pipeline_infra_cleanup() 只需调用这一个函数
- **D-04:** wrapper 内部可通过环境变量控制跳过某些步骤（如 `SKIP_BUILD_CACHE_CLEANUP=true`），但默认全部执行

### 磁盘快照格式
- **D-05:** `disk_snapshot()` 输出纯文本到 Jenkins 构建日志（df -h + docker system df）。不写入独立文件，不使用 JSON 格式
- **D-06:** 部署前（Deploy 阶段前）和清理后（Cleanup 阶段末尾）各输出一次快照，人工对比

### 验证策略
- **D-07:** Plan 43-03 通过手动触发 4 个 Pipeline（findclass-ssr, noda-site, keycloak, infra）做端到端验证，检查构建日志中清理输出和磁盘快照对比
- **D-08:** 不编写独立测试脚本，验证在真实 Pipeline 环境中进行

### Claude's Discretion
- cleanup.sh 中各清理函数的具体签名和参数设计
- cleanup_after_deploy() 内部的执行顺序
- 环境变量覆盖的具体命名和默认值
- 函数内的日志格式和输出细节
- pipeline_cleanup() / pipeline_infra_cleanup() 修改的具体行数和结构
- 是否需要 cleanup_after_infra_deploy() 作为 infra 专用 wrapper

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 需求定义
- `.planning/REQUIREMENTS.md` §DOCK-01~04, CACHE-01, FILE-01~02 — Phase 43 涉及的所有需求
- `.planning/ROADMAP.md` §Phase 43 — 目标、依赖、成功标准

### 研究文档（核心参考）
- `.planning/research/CLEANUP-RESEARCH.md` — 完整的清理命令研究、函数设计模板、安全考量、功能矩阵。**必须阅读**，包含所有 Docker/Node.js/文件清理命令的详细说明和推荐策略

### 前序 Phase 决策
- `.planning/phases/35-shared-libs/35-CONTEXT.md` — 共享库模式（Source Guard、独立函数、scripts/lib/ 目录）
- `.planning/phases/37-cleanup-rename/37-CONTEXT.md` — 代码清理与重命名模式

### 现有实现
- `scripts/lib/image-cleanup.sh` — 现有镜像清理库（与 cleanup.sh 并存）
- `scripts/pipeline-stages.sh` — `pipeline_cleanup()` (line 411) 和 `pipeline_infra_cleanup()` (line 883)，需要增强
- `scripts/lib/log.sh` — 日志函数库（cleanup.sh 依赖）
- `jenkins/Jenkinsfile.findclass-ssr` — Cleanup 阶段调用模式参考
- `jenkins/Jenkinsfile.infra` — Infra Pipeline Cleanup 阶段

### 项目级配置
- `.planning/PROJECT.md` — 已锁定决策（log.sh 不合并、Source Guard 模式等）
- `.planning/STATE.md` — v1.9 研究决策（build cache 24h、volume prune 不加 --all 等）

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/lib/image-cleanup.sh` — 3 个镜像清理函数（cleanup_by_tag_count, cleanup_by_date_threshold, cleanup_dangling），cleanup.sh 与之并存
- `scripts/lib/log.sh` — log_info/log_success/log_error/log_warn，cleanup.sh 必须依赖
- `scripts/lib/platform.sh` — detect_platform()，可能用于条件化清理逻辑
- `scripts/lib/deploy-check.sh` — Source Guard 模式参考
- `scripts/backup/lib/config.sh` — Source Guard 模式参考（`_NODA_CONFIG_LOADED`）

### Established Patterns
- Source Guard: `if [[ -n "${_NODA_<LIBRARY>_LOADED:-}" ]]; then return 0; fi; _NODA_<LIBRARY>_LOADED=1`
- 函数参数传递（位置参数，非环境变量）
- `|| true` 确保失败不传播
- 环境变量提供默认值覆盖：`VAR="${VAR:-default}"`

### Integration Points
- `scripts/pipeline-stages.sh:411` — `pipeline_cleanup()` 需增强（添加 cleanup_after_deploy 调用）
- `scripts/pipeline-stages.sh:883` — `pipeline_infra_cleanup()` 需增强（添加清理调用）
- `jenkins/Jenkinsfile.findclass-ssr` — Cleanup 阶段（添加部署前磁盘快照）
- `jenkins/Jenkinsfile.infra` — Cleanup 阶段（添加备份文件清理 + 磁盘快照）
- `jenkins/Jenkinsfile.keycloak` — Cleanup 阶段（添加通用清理）
- `jenkins/Jenkinsfile.noda-site` — Cleanup 阶段（添加 node_modules 清理）
- 新文件：`scripts/lib/cleanup.sh` — 放入现有 scripts/lib/ 目录

</code_context>

<specifics>
## Specific Ideas

- CLEANUP-RESEARCH.md 第十一章有完整的 cleanup.sh 函数模板（9 个函数 + 磁盘快照函数），planner 可直接参考
- 功能矩阵（第八章）定义了各 Pipeline 需要的清理项：findclass-ssr/noda-site 需要全部清理，keycloak 只需 dangling/containers/networks/volumes，infra 需要备份清理
- 安全红线（第七章）：postgres_data 命名卷绝对不清理、蓝绿 standby 镜像不清理、只用 `docker volume prune -f` 不加 `--all`
- Jenkins 已配置 `buildDiscarder(logRotator(numToKeepStr: '20'))`，无需变更
- pnpm store prune 属于 Phase 44（每 7 天定期清理），不在本 phase 范围内

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 43-cleanup-pipeline*
*Context gathered: 2026-04-19*
