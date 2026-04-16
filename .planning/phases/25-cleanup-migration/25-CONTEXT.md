# Phase 25: 清理与迁移 - Context

**Gathered:** 2026-04-16
**Status:** Ready for planning

<domain>
## Phase Boundary

旧部署脚本保留为手动回退入口，部署文档更新反映 Jenkins Pipeline 优先，里程碑状态归档为已完成。

范围包括：
- 旧部署脚本标记为手动回退（ENH-04）
- CLAUDE.md 部署命令章节更新为 Jenkins Pipeline 优先
- ROADMAP.md 和 PROJECT.md 反映 v1.4 里程碑完成状态

</domain>

<decisions>
## Implementation Decisions

### 旧脚本标记方式
- **D-01:** `deploy-infrastructure-prod.sh` 和 `deploy-apps-prod.sh` 添加文件头注释块，明确标注为"手动回退方案，Jenkins Pipeline 是主要部署方式"
- **D-02:** 不添加运行时警告 — 脚本行为不变，仅通过文件头注释和文档说明角色
- **D-03:** 同样检查 `deploy-findclass-zero-deps.sh`（已标记 deprecated），确认无需额外处理

### CLAUDE.md 更新范围
- **D-04:** 仅更新"部署命令"章节 — Jenkins Pipeline 为主，旧脚本标注为手动回退
- **D-05:** 不重写整个 CLAUDE.md，其他章节（架构、部署规则、修复记录等）保持不变
- **D-06:** 新的部署章节应包含：Jenkins 手动触发步骤、旧脚本回退用法、查看状态的只读命令

### 里程碑归档格式
- **D-07:** ROADMAP.md 中 v1.4 归档格式与 v1.0~v1.3 一致：折叠块 + 统计信息（phases/plans/commits）+ 主要成果列表
- **D-08:** PROJECT.md 更新：Current Milestone 标记为 shipped，Requirements 中 Active 项移至 Validated
- **D-09:** STATE.md 更新：milestone 状态改为 completed

### Claude's Discretion
- 注释块的具体措辞
- CLAUDE.md 部署章节的具体排版
- 归档统计数据的收集方式（git log 命令等）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 需要修改的文件
- `CLAUDE.md` §"部署命令" — 需要更新的目标章节
- `.planning/ROADMAP.md` — v1.4 里程碑归档目标
- `.planning/PROJECT.md` — 里程碑状态更新目标
- `.planning/STATE.md` — 项目状态更新目标

### 需要标记的脚本
- `scripts/deploy/deploy-infrastructure-prod.sh` — 基础设施部署脚本（添加回退注释）
- `scripts/deploy/deploy-apps-prod.sh` — 应用部署脚本（添加回退注释）
- `scripts/deploy/deploy-findclass-zero-deps.sh` — 已废弃脚本（确认状态）

### 归档格式参考
- `.planning/ROADMAP.md` — v1.0~v1.3 已有里程碑的折叠块格式
- `.planning/milestones/v1.0-ROADMAP.md` — v1.0 详细归档示例
- `.planning/milestones/v1.1-MILESTONE.md` — v1.1 详细归档示例
- `.planning/milestones/v1.2-ROADMAP.md` — v1.2 详细归档示例

### Pipeline 产出（确认已完成）
- `jenkins/Jenkinsfile` — 9 阶段 Pipeline（已实现）
- `scripts/pipeline-stages.sh` — Pipeline 阶段函数库（已实现）
- `scripts/blue-green-deploy.sh` — 蓝绿部署脚本（已实现）

### 需求文档
- `.planning/REQUIREMENTS.md` — ENH-04 需求定义
- `.planning/ROADMAP.md` Phase 25 — 成功标准

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `.planning/milestones/` — 已有里程碑归档模板，可复用格式
- `scripts/deploy/` — 旧部署脚本目录，Phase 25 需要添加注释

### Established Patterns
- 里程碑归档使用 HTML 折叠块 `<details><summary>` 格式
- 统计信息包含：phases 数、plans 数、commits 数、files changed 数
- CLAUDE.md 部署规则已明确禁止直接运行 docker compose 命令

### Integration Points
- CLAUDE.md 部署命令章节与 Jenkins Pipeline 实际流程对齐
- ROADMAP.md 归档后作为历史参考
- PROJECT.md 状态更新为下个里程碑做准备

</code_context>

<specifics>
## Specific Ideas

- 注释块可参考标准格式：`# NOTE: This script is retained as a manual fallback...`
- CLAUDE.md 新部署章节应包含实际命令示例（如 Jenkins "Build Now" 步骤）
- v1.4 归档统计数据需从 git log 收集（Phase 19-24 的 commit 范围）

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 25-cleanup-migration*
*Context gathered: 2026-04-16*
