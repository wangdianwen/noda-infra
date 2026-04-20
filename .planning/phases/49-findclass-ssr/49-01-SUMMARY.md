---
phase: 49-findclass-ssr
plan: 01
subsystem: infra
tags: [docker, python, chromium, patchright, audit, decision]

# Dependency graph
requires:
  - phase: 49-CONTEXT
    provides: "决策条件 D-06/D-07/D-08 和审计范围定义"
provides:
  - "49-DECISION.md 决策文档 -- 方案 A 完全移除 Python/Chromium 的完整影响分析和 Phase 50 执行指引"
  - "49-RESEARCH.md 审计完整性验证 -- SSR-01 全部要求覆盖确认"
affects: [phase-50-ssr-removal, phase-51-ssr-deep]

# Tech tracking
tech-stack:
  added: []
  patterns: [python-removal-audit-pattern, dockerfile-line-level-change-list]

key-files:
  created:
    - .planning/phases/49-findclass-ssr/49-DECISION.md
  modified:
    - .planning/phases/49-findclass-ssr/49-RESEARCH.md

key-decisions:
  - "方案 A（完全移除 Python/Chromium/patchright）-- StealthySession 不在日常定时流程中使用，D-06/D-07/D-08 标准全部满足"
  - "Phase 50 按 6 步顺序移除：Dockerfile 清理 → docker-compose 清理 → crawl-scheduler 改造 → API 端点处理 → re-tag-regions 处理 → 构建验证"
  - "crawl_executions 表历史数据保留，crawl API 只读端点评估保留"

patterns-established:
  - "Dockerfile 精确行号级变更清单 -- 为 Phase 50 执行提供无歧义的操作指引"
  - "决策文档引用 CONTEXT.md 决策 ID（D-06/D-07/D-08）确保可追溯性"

requirements-completed: [SSR-01, SSR-02]

# Metrics
duration: 2min
completed: 2026-04-20
---

# Phase 49 Plan 01: 爬虫审计验证与决策文档 Summary

**验证 RESEARCH.md 审计完整性并产出方案 A（完全移除 Python/Chromium）决策文档，含 Dockerfile 行号级变更清单和 Phase 50 六步执行指引**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-20T19:37:54Z
- **Completed:** 2026-04-20T19:40:22Z
- **Tasks:** 2
- **Files modified:** 1 (created)

## Accomplishments
- 验证 49-RESEARCH.md 审计覆盖 SSR-01 全部要求：6 个 Python 脚本独立章节、2 处 spawn 调用点、4 个 API 端点关系、StealthySession 使用分析
- 创建 49-DECISION.md 决策文档，明确选择方案 A（完全移除 Python/Chromium/patchright）
- 产出 Dockerfile 精确行号级变更清单（L67/L71-76/L84-86/L121-130）和 docker-compose.app.yml 变更清单
- 制定 Phase 50 六步执行指引和风险评估

## Task Commits

Each task was committed atomically:

1. **Task 1+2: 审计完整性验证 + 决策文档** - `56c4f7f` (docs)

## Files Created/Modified
- `.planning/phases/49-findclass-ssr/49-DECISION.md` - 方案 A 决策文档，含影响分析、Dockerfile 行号级变更清单、docker-compose 变更清单、Phase 50 执行指引

## Decisions Made
- 方案 A（完全移除）而非方案 B（分离独立容器）-- 因为 StealthySession 仅在手动触发的 --re-analyze 模式中使用，日常定时抓取完全使用 Fetcher.get()
- Phase 50 可考虑将 findclass-ssr 内存限制从 1G 降至 512M（移除 Python 运行时后内存需求显著减少）
- crawl_executions 表历史数据保留不删除

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- 49-DECISION.md 已为 Phase 50 提供完整执行输入：Dockerfile 行号级变更清单 + docker-compose 变更清单 + 六步执行指引
- Phase 50 执行移除后，Phase 51 可进行 Alpine 切换 + devDependencies 清理 + COPY 层优化
- Phase 50 需在 noda-apps 仓库操作 crawl-scheduler.ts 和 re-tag-regions.ts

## Self-Check: PASSED

| Item | Status |
|------|--------|
| .planning/phases/49-findclass-ssr/49-DECISION.md | FOUND |
| .planning/phases/49-findclass-ssr/49-01-SUMMARY.md | FOUND |
| Commit 56c4f7f | FOUND |

---
*Phase: 49-findclass-ssr*
*Completed: 2026-04-20*
