# Phase 37: 清理与重命名 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-19
**Phase:** 37-cleanup-rename
**Areas discussed:** 命名选择, 文档引用更新范围

---

## health.sh 命名选择

| Option | Description | Selected |
|--------|-------------|----------|
| db-health.sh | 强调"数据库健康"语义，与容器健康检查区分。ROADMAP 已锁定 | ✓ |
| precheck.sh | 强调"备份前检查"语义，研究阶段建议 | |
| backup-precheck.sh | 最精准但最长 | |

**User's choice:** db-health.sh（推荐）
**Notes:** 与 ROADMAP 一致，简洁且能消除混淆

---

## 文档引用更新范围

| Option | Description | Selected |
|--------|-------------|----------|
| 仅源码引用 | 更新 backup-postgres.sh source 路径 + 删除 5 个脚本。docs/ 和 .planning/ 保留 | ✓ |
| 源码 + docs/ | 源码 + 用户面向文档一起更新 | |
| 全部更新 | 所有 21+ 个文件引用全部更新 | |

**User's choice:** 仅源码引用（推荐）
**Notes:** docs/ 和 .planning/ 中是历史记录，不影响运行

---

## Claude's Discretion

- 验证脚本删除后是否移除空的 scripts/verify/ 目录
- 重命名时是否更新文件内自注释
- 删除前是否逐个确认脚本不可用

## Deferred Ideas

None — discussion stayed within phase scope
