# Phase 50: findclass-ssr 瘦身执行 - Context

**Gathered:** 2026-04-21
**Status:** Skipped

<domain>
## Phase Boundary

原定执行 Phase 49 决策（完全移除 Python/Chromium/patchright）。经重新评估，爬虫是 findclass 核心功能，不能移除 Python。Phase 50 和依赖的 Phase 51 整体跳过。

</domain>

<decisions>
## Implementation Decisions

### 跳过决策
- **D-01:** Phase 49 决策（方案 A：完全移除 Python/Chromium）基于错误前提 — 当时记录"用户确认可以放弃定时爬虫"，但实际爬虫（crawl_board()）是 findclass 的核心数据来源
- **D-02:** 爬虫使用 Fetcher.get()（纯 HTTP），不需要 Chromium，但需要 Python 运行时（crawl-skykiwi.py + db_import.py）
- **D-03:** Phase 50 整体跳过 — findclass-ssr 不做任何变更，避免破坏核心爬虫功能
- **D-04:** Phase 51（SSR 深度优化）也跳过 — 依赖 Phase 50 完成，且 Alpine 切换需要 Python 完全移除

### 未来路径
- **D-05:** 如需瘦身，应走"部分移除"路线：只移除 Chromium + patchright（节省 ~1.5-2GB），保留 Python + 爬虫 + LLM
- **D-06:** 如需恢复完整爬虫能力（含绕 Cloudflare），走方案 B：独立 findclass-crawler 容器（参见 REQUIREMENTS.md CRAWL-01/CRAWL-02）

### Claude's Discretion
- 无 — 跳过决策已明确

</decisions>

<canonical_refs>
## Canonical References

### Phase 49 审计
- `.planning/phases/49-findclass-ssr/49-DECISION.md` — 原决策文档（方案 A，需修订）
- `.planning/phases/49-findclass-ssr/49-RESEARCH.md` — 完整 Python 脚本审计
- `.planning/phases/49-findclass-ssr/49-CONTEXT.md` — 原决策条件和标准

### 需求定义
- `.planning/REQUIREMENTS.md` §SSR-03, SSR-04, CRAWL-01, CRAWL-02 — 相关需求（SSR-03/04 暂缓，CRAWL-01/02 可能未来需要）

### Dockerfile
- `deploy/Dockerfile.findclass-ssr` — 当前 Dockerfile（不修改）
- `docker/docker-compose.app.yml` — 当前服务配置（不修改）

</canonical_refs>

<code_context>
## Existing Code Insights

### 保留的组件
- Python 运行时（apt-get install python3 python3-pip python3-venv）— 核心爬虫需要
- Chromium — 仅 StealthySession 使用，日常不用，但暂不移除以保持稳定
- crawl-skykiwi.py + db_import.py — 核心爬虫脚本
- crawl-scheduler.ts — 定时调度器
- 4 个 crawl API 端点 — 查询爬虫数据

### Integration Points
- findclass-ssr 是 findclass 核心服务，任何变更都有高风险
- crawl_board() 依赖 Python 子进程（spawn），修改需在 noda-apps 仓库操作

</code_context>

<specifics>
## Specific Ideas

- 未来如需瘦身，推荐"最小改动"方案：仅移除 Chromium + patchright（节省 ~1.5-2GB），不碰 Python 爬虫
- CRAWL-01/CRAWL-02（独立爬虫容器）可作为未来里程碑重新评估

</specifics>

<deferred>
## Deferred Ideas

- SSR-03/SSR-04 需求暂缓 — 等待更好的时机或独立爬虫容器方案
- Phase 51（Alpine 切换 + devDeps 清理）暂缓 — 依赖 Python 移除
- findclass-ssr 镜像体积优化作为独立未来里程碑考虑

</deferred>

---
*Phase: 50-findclass-ssr-skip*
*Context gathered: 2026-04-21*
