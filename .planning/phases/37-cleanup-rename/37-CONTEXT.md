# Phase 37: 清理与重命名 - Context

**Gathered:** 2026-04-19
**Status:** Ready for planning

<domain>
## Phase Boundary

删除 `scripts/verify/` 下 5 个不可用的一次性验证脚本，重命名 `scripts/backup/lib/health.sh` 为 `db-health.sh` 消除命名混淆。代码库不再包含不可用的遗留脚本，文件命名不再引起混淆。

</domain>

<decisions>
## Implementation Decisions

### 命名选择
- **D-01:** `scripts/backup/lib/health.sh` 重命名为 `scripts/backup/lib/db-health.sh`（与 ROADMAP 一致，强调"数据库健康"语义）

### 文档引用更新范围
- **D-02:** 仅更新源码中的 source 引用路径。docs/ 和 .planning/ 中的历史引用保留不动（不影响运行，属于历史记录）

### Claude's Discretion
- 验证脚本删除后是否移除空的 `scripts/verify/` 目录
- 重命名时是否更新文件内的自注释（如 `# 健康检查库` → `# 数据库健康检查库`）
- 删除前是否需要逐个确认脚本确实不可用

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 需求定义
- `.planning/REQUIREMENTS.md` §CLEAN-01, CLEAN-02 — 清理与重命名的具体需求
- `.planning/ROADMAP.md` §Phase 37 — Phase 成功标准

### 架构分析
- `.planning/research/FEATURES.md` — D-05（health.sh 重命名决策）和 A-01（不合并理由）
- `.planning/research/ARCHITECTURE.md` §七 — backup/lib/health.sh 不应合并的理由
- `.planning/research/PITFALLS.md` — health.sh 条件加载逻辑和 readonly 变量陷阱

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Phase 35 已提取 `scripts/lib/deploy-check.sh`、`scripts/lib/platform.sh`、`scripts/lib/image-cleanup.sh` — 本 phase 无需新增共享库

### Established Patterns
- Source guard 模式（Phase 35 建立）— 重命名 health.sh 不需要添加新的 source guard，只需更新路径
- 文件重命名在 Phase 35 迁移消费者时已有模式：`source` 路径替换

### Integration Points
- `scripts/backup/backup-postgres.sh:24` — 唯一 source `backup/lib/health.sh` 的源码文件
- `scripts/verify/` 下 5 个脚本 — 独立脚本，无其他源码 source 它们
- `scripts/lib/health.sh`（Docker 容器健康检查）— 本 phase 不涉及，保持不动

</code_context>

<specifics>
## Specific Ideas

- 5 个 verify 脚本硬编码旧架构路径（localhost:8080、旧容器名等），已无法在生产环境运行
- `db-health.sh` 比原名 `health.sh` 更精确反映功能（PG 连接 + 磁盘空间检查）
- docs/ 和 .planning/ 中有 21+ 个文件引用 verify 脚本和旧 health.sh 路径，全部保留不动

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 37-cleanup-rename*
*Context gathered: 2026-04-19*
