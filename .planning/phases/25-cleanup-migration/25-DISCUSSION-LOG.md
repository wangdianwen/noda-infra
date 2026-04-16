# Phase 25: 清理与迁移 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-16
**Phase:** 25-cleanup-migration
**Areas discussed:** 旧脚本标记方式, CLAUDE.md 更新范围, 里程碑归档细节

---

## 旧脚本标记方式

| Option | Description | Selected |
|--------|-------------|----------|
| 文件头注释 | 脚本开头添加注释块，标注为手动回退方案。不改变运行时行为。 | ✓ |
| 注释 + 运行时警告 | 文件头注释 + 运行时 echo 警告信息 | |
| 仅文档说明 | 不修改脚本本身，仅在 CLAUDE.md 中标注角色 | |

**User's choice:** 文件头注释（推荐）
**Notes:** 用户选择最小侵入方式 — 仅添加注释块，不改变脚本运行时行为

---

## CLAUDE.md 更新范围

| Option | Description | Selected |
|--------|-------------|----------|
| 仅更新部署章节 | 只更新"部署命令"章节：Jenkins Pipeline 为主，旧脚本标注为回退 | ✓ |
| 更新部署 + 清理过时内容 | 同时清理其他过时的历史修复记录等 | |
| 全量重写 | 重新整理整个 CLAUDE.md 结构 | |

**User's choice:** 仅更新部署章节（推荐）
**Notes:** 用户选择最小更新范围 — 只动部署章节，其他章节保持不变

---

## 里程碑归档细节

| Option | Description | Selected |
|--------|-------------|----------|
| 与已有里程碑格式一致 | 折叠块 + 统计信息 + 主要成果列表，与 v1.0~v1.3 格式对齐 | ✓ |
| 增加 Git SHA 范围 | 额外记录每个 Phase 的 Git SHA 范围便于追溯 | |
| 简洁标记 | 只标记 v1.4 为 shipped，不详细记录 | |

**User's choice:** 与已有里程碑格式一致（推荐）
**Notes:** 保持文档一致性，复用已有归档模板

---

## Claude's Discretion

- 注释块的具体措辞
- CLAUDE.md 部署章节的具体排版
- 归档统计数据的收集方式

## Deferred Ideas

None — discussion stayed within phase scope
