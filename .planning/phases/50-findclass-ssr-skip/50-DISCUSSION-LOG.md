# Phase 50: findclass-ssr 瘦身执行 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-21
**Phase:** 50-findclass-ssr-skip
**Areas discussed:** crawl API 端点处理, noda-apps 跨仓库操作, 内存限制调整, Jenkins Pipeline 适配

---

## crawl API 端点处理

| Option | Description | Selected |
|--------|-------------|----------|
| 全部移除 | 移除 4 个 crawl 端点 | |
| 保留只读端点 | trigger 返回 501，status/history/stats 保留 | |
| trigger 返回 501 | 折中方案 | |

**User's choice:** "爬虫是核心功能，不应该废弃" — 重新评估整个 Phase 50 前提

**Notes:** 用户指出 crawl_board() 是 findclass 核心数据来源，Phase 49 决策中"用户确认可以放弃定时爬虫"记录有误。

## 重新评估

| Option | Description | Selected |
|--------|-------------|----------|
| 保留基础爬虫 | 移除 Chromium/LLM，保留 Python 爬虫 | |
| 分离独立容器 | 走方案 B | |
| Node.js 重写 | 重写爬虫 | |
| 重新评估 | 重新评估 | ✓ |

**User's choice:** 重新评估

**Notes:** 确认爬虫是核心功能

## 最终方向

| Option | Description | Selected |
|--------|-------------|----------|
| 仅移除 Chromium | 最低风险，保留 Python 爬虫 | |
| 跳过 findclass-ssr 瘦身 | 转到其他阶段 | ✓ |
| 重新规划 Phase 50 | 修订决策 | |
| 暂缓 | 优先其他阶段 | |

**User's choice:** 跳过 findclass-ssr 瘦身

**Notes:** 用户不想对 findclass-ssr 做复杂变更。Phase 50 和 51 整体跳过。

## Claude's Discretion

无 — 所有决策由用户明确指定

## Deferred Ideas

- SSR-03/SSR-04 暂缓
- Phase 51（SSR 深度优化）暂缓
- 未来可考虑仅移除 Chromium 的最小方案
- CRAWL-01/CRAWL-02（独立爬虫容器）作为未来里程碑
