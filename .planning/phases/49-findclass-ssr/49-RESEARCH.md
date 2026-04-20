# Phase 49: findclass-ssr 爬虫审计与决策 - Research

**Researched:** 2026-04-20
**Domain:** Python 爬虫调用链路审计 + Python/Chromium 移除决策
**Confidence:** HIGH

## Summary

本阶段的核心目标是审计 findclass-ssr 容器中所有 Python 脚本的调用链路，并基于代码证据做出「完全移除」或「分离为独立容器」的最终决策。

经过对 noda-apps 仓库的完整源码审计，发现以下关键事实：

**StealthySession（需 Chromium）的实际使用情况：** StealthySession 仅在 `crawl-skykiwi.py` 的 `--re-analyze` 模式（L698-730）中使用。该模式用于重新分析单个 URL 的帖子详情页，不参与日常定时抓取流程。日常定时抓取（`crawl_board()` 函数 L494-599）完全使用 `Fetcher.get()`（纯 HTTP 请求，不需要浏览器）。此外，`re-tag-regions.ts` 脚本也会通过 `spawn('python3', ['scripts/crawl-skykiwi.py', '--re-analyze', ...])` 触发 StealthySession，但这是一个手动运行的维护脚本，不是自动定时任务。

**crawl-scheduler.ts 的 spawn 调用链路：** `crawl-scheduler.ts` 中只有一处 `spawn('python3', ...)` 调用（L253），参数固定为 `['crawl-skykiwi.py', '--board', 'tutoring']`。该调用由 `node-cron` 每天 9:00 NZST 触发（加随机延迟 0-8h），也可通过 API 端点 `POST /api/crawl/trigger` 手动触发。

**Python 脚本完整调用链：** 共 6 个 Python 脚本 — `crawl-skykiwi.py`（主入口）、`llm_filter.py`（LLM 过滤）、`llm_extract.py`（LLM 详情提取）、`llm_quality_gate.py`（质量关卡）、`db_import.py`（数据库导入）、`retrofix_data_quality.py`（回溯修复，独立运行）。`crawl-skykiwi.py` 在 `main()` 中依次调用 `llm_filter` → `llm_extract` → `llm_quality_gate` → `db_import`，形成完整的管道。

**关键决策依据：** 日常定时抓取流程完全使用 `Fetcher.get()`（不需要 Chromium），StealthySession 仅用于手动触发的 `--re-analyze` 模式。根据 CONTEXT.md D-06 的判断标准（代码证据直接判断，不需要运行时观察），StealthySession 不在日常自动流程中使用。

**Primary recommendation:** 审计结论明确 — StealthySession 不在定时抓取流程中使用。如果 `--re-analyze` 功能可以暂时放弃或迁移到独立工具，则完全移除 Python/Chromium（节省约 3GB，Phase 50 执行）。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 克隆 noda-apps 仓库到本地进行完整源码审计，获取第一手调用链路数据
- **D-02:** 聚焦审计范围 — 只审计 Python 脚本和 crawl-scheduler.ts，不涉及前端和其他无关代码
- **D-03:** 审计产出为 RESEARCH.md 文档（GSD 标准流程），记录完整调用链路和运行频率
- **D-04:** 审计内容必须包含：每个 Python 脚本的功能、调用方、是否有 API 端点直接触发、实际运行频率
- **D-05:** 审计完成后再做最终决策，不预先承诺移除或分离
- **D-06:** 决策条件以 StealthySession 是否实际使用为准 — 如果代码证据显示 StealthySession 仅在条件分支中存在但从未实际触发（无调用记录、无配置引用），则视为未使用
- **D-07:** 判断方式为代码证据直接判断，不需要在生产环境观察运行时行为
- **D-08:** 如果 StealthySession 未实际使用 → 完全移除 Python/Chromium（最大节省 ~3GB）
- **D-09:** 如果 StealthySession 有实际使用 → 分离为独立爬虫容器（保留完整能力）
- **D-10:** 新爬虫容器加入现有 docker-compose.app.yml，与 findclass-ssr 在同一 Docker Compose 项目中
- **D-11:** 爬虫触发方式：crawl-scheduler.ts 通过 HTTP POST 调用爬虫容器（spawn → HTTP fetch）
- **D-12:** crawl-scheduler.ts 改造范围最小化 — 只改调用方式（spawn → HTTP fetch），不重写调度逻辑
- **D-13:** 爬虫容器单实例运行，不采用蓝绿部署（爬虫是后台任务，不需要零停机切换）

### Claude's Discretion
- noda-apps 仓库的克隆位置和克隆后清理
- 审计文档的具体格式和结构
- RESEARCH.md 中调用链路图的展示方式
- 决策分析的深度和细节

### Deferred Ideas (OUT OF SCOPE)
- findclass-ssr Alpine 切换 — Phase 51（依赖 Python 完全移除）
- findclass-ssr devDependencies 清理 — Phase 51
- COPY 层顺序优化 — Phase 51
- 爬虫容器具体实现和部署 — Phase 50（如果分离）
- Jenkins Pipeline 适配爬虫容器部署 — Phase 50
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SSR-01 | 审计 findclass-ssr 中所有 Python 脚本的调用链路（crawl-skykiwi.py、llm_extract.py、db_import.py 等），确认是否有 API 端点直接调用 | 完整审计完成 — 见下方「Python 脚本调用链路完整审计」。API 端点通过 crawl-scheduler.ts 间接调用 Python，无直接 Python 执行路径 |
| SSR-02 | 根据审计结果，制定 Python/Chromium/patchright 移除或分离方案（直接移除 vs 独立容器） | 审计结论 + 决策建议 — 见下方「决策分析」。StealthySession 仅在 --re-analyze 模式中使用，定时抓取完全用 Fetcher.get() |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| 定时爬虫调度 | API / Backend | — | crawl-scheduler.ts 运行在 Node.js API 进程中，使用 node-cron 定时 |
| Python 爬虫执行 | API / Backend（当前同容器） | — | 当前 spawn 同进程内 python3；分离后为独立容器 |
| LLM 过滤/提取/质量检查 | API / Backend（Python 脚本） | — | 由 crawl-skykiwi.py 顺序调用，纯 Python 代码 |
| 数据库写入 | API / Backend | — | db_import.py 直接连接 PostgreSQL |
| StealthySession 浏览器爬取 | API / Backend（仅 --re-analyze） | — | 需 Chromium，仅手动触发的再分析模式 |

## Standard Stack

### Core（审计目标，当前已安装）
| 组件 | 版本 | 用途 | 备注 |
|------|------|------|------|
| Python 3 | 系统包 | 爬虫脚本运行时 | Dockerfile L72-76 apt-get install |
| Chromium | 系统包 | StealthySession 浏览器 | Dockerfile L74，约 300-400MB |
| patchright | pip 安装 | Chromium 自动化库 | `python3 -m patchright install chromium` L127，独立下载约 300-400MB |
| scrapling[fetchers] | >=0.4.5 | HTTP + 浏览器爬虫框架 | requirements.txt，包含 Fetcher.get() 和 StealthySession |
| anthropic | >=0.86.0 | LLM API 客户端 | requirements.txt，llm_filter/llm_extract/llm_quality_gate 使用 |
| psycopg[binary] | >=3.1.0 | PostgreSQL 客户端 | requirements.txt，db_import.py 使用 |
| beautifulsoup4 | >=4.12.0 | HTML 解析 | requirements.txt |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| 移除全部 Python | 分离为独立容器 | 分离保留全部能力但增加维护复杂度；移除节省更多但放弃 --re-analyze 和手动爬虫触发 |

## Architecture Patterns

### 系统架构图 — 当前调用链路

```
                         Node.js API (findclass-ssr)
                         ┌─────────────────────────────────────────────────┐
                         │                                                 │
  node-cron ──────────>  │  crawl-scheduler.ts                            │
  每天 9:00 NZST         │    │                                           │
  (随机延迟 0-8h)         │    └──> spawn('python3', ['crawl-skykiwi.py',  │
                         │              '--board', 'tutoring'])            │
  POST /api/crawl/trigger┤         │                                      │
  (手动触发)             │         v                                      │
                         │    ┌─────────────────────────────────────┐     │
                         │    │ crawl-skykiwi.py (Python)            │     │
                         │    │   │                                   │     │
                         │    │   ├─> Fetcher.get(board_url)         │     │
                         │    │   │    (纯 HTTP，不需要 Chromium)     │     │
                         │    │   │                                   │     │
                         │    │   ├─> Fetcher.get(detail_url) x N   │     │
                         │    │   │    (逐条帖子详情页)                │     │
                         │    │   │                                   │     │
                         │    │   ├─> llm_filter.filter_course_posts │     │
                         │    │   │    (Anthropic Haiku 批量分类)      │     │
                         │    │   │                                   │     │
                         │    │   ├─> llm_extract.extract_course_    │     │
                         │    │   │    details (Anthropic Tool Use)   │     │
                         │    │   │                                   │     │
                         │    │   ├─> llm_quality_gate.quality_      │     │
                         │    │   │    gate_filter (二次过滤)          │     │
                         │    │   │                                   │     │
                         │    │   ├─> db_import.import_courses        │     │
                         │    │   │    (PostgreSQL upsert)            │     │
                         │    │   │                                   │     │
                         │    │   └─> stdout JSON (结果输出)           │     │
                         │    └─────────────────────────────────────┘     │
                         │                                                 │
  --re-analyze 模式 ───> │    crawl-skykiwi.py --re-analyze <url>         │
  (手动/脚本触发)         │         │                                      │
  re-tag-regions.ts ───> │         └─> StealthySession.fetch(url)         │
  (手动维护脚本)          │              (需要 Chromium!)                   │
                         │                                                 │
                         └─────────────────────────────────────────────────┘
                                                    │
                                                    v
                                              PostgreSQL
                                        (noda-infra-postgres-prod)
```

### 推荐 Project Structure（分离方案时适用）
```
noda-infra/
├── docker/
│   ├── docker-compose.app.yml       # 新增 findclass-crawler 服务（如分离）
│   └── ...
├── deploy/
│   └── Dockerfile.findclass-ssr     # 移除 Python/Chromium（Phase 50 执行）
└── .planning/
    └── phases/49-findclass-ssr/
        └── 49-RESEARCH.md            # 本文档
```

### Pattern 1: 定时爬虫调度模式
**What:** crawl-scheduler.ts 使用 node-cron 每天 9:00 NZST 触发，加 0-8h 随机延迟
**When to use:** 爬虫定时执行
**Example:**
```typescript
// Source: noda-apps/apps/findclass/api/src/scripts/crawl-scheduler.ts L72-94
this.scheduler = cron.schedule(
  '0 9 * * *',
  () => {
    const delay = this.getRandomDelay();
    this.pendingRandomDelayTimer = setTimeout(() => {
      this.executeWithRetry('cron');
    }, delay);
  },
  { timezone: 'Pacific/Auckland' },
);
```

### Pattern 2: spawn Python 子进程模式（当前）
**What:** Node.js 通过 child_process.spawn 调用 Python 脚本
**When to use:** 当前唯一的 Python 调用方式
**Example:**
```typescript
// Source: noda-apps/apps/findclass/api/src/scripts/crawl-scheduler.ts L251-280
const childProcess = spawn('python3', [...CrawlScheduler.SPAWN_ARGS], {
  cwd: '/app/scripts',
  env: { ...process.env, PYTHONPATH: '/app/scripts' },
});
```

### Pattern 3: 管道式处理链
**What:** crawl-skykiwi.py main() 中按顺序调用 llm_filter → llm_extract → llm_quality_gate → db_import
**When to use:** 每次抓取后的数据处理
**Example:**
```python
# Source: noda-apps/scripts/crawl-skykiwi.py L748-865
# 管道顺序:
# 1. llm_filter.filter_course_posts(results, board_name)
# 2. llm_extract.extract_course_details(course)  # 逐条
# 3. llm_quality_gate.quality_gate_filter(results)
# 4. db_import.import_courses(results)  # 当 DATABASE_URL 存在时
```

### Anti-Patterns to Avoid
- **不要假设 Fetcher.get() 和 StealthySession 可以互换：** Fetcher.get() 是纯 HTTP 请求（快速、轻量），StealthySession 启动 Chromium 浏览器（重量级）。日常抓取只使用 Fetcher.get()。
- **不要忽略 --re-analyze 模式：** 虽然不在定时流程中，但 re-tag-regions.ts 维护脚本依赖它。如果完全移除 Python，该脚本需要重写或废弃。

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HTTP 爬虫 | 自己写 requests + 解析 | Fetcher.get() (scrapling) | 已在用，处理 cookie/重定向/编码 |
| LLM 提取 | 自己写解析规则 | Anthropic Tool Use | 已在用，结构化输出 |
| 去重检测 | 简单字符串匹配 | pg_trgm + tid 精确去重 | 已在用，三层优先级 |

## Runtime State Inventory

> 本阶段只做审计和决策，不执行代码变更。以下记录运行时状态供 Phase 50 参考。

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | crawl_executions 表（PostgreSQL）记录爬虫执行历史 | 移除 Python 后如停用爬虫，该表数据保留但不再新增记录 |
| Live service config | crawl-scheduler.ts 的 cron 表达式硬编码在代码中 | 无需外部配置变更 |
| OS-registered state | 无 | — |
| Secrets/env vars | DATABASE_URL（PostgreSQL 连接）、ANTHROPIC_AUTH_TOKEN/BASE_URL/API_KEY（LLM） | 移除 Python 后这些环境变量在 findclass-ssr 中不再需要；如分离到独立容器，需在容器中配置 |
| Build artifacts | findclass-ssr:latest 镜像包含 Python/Chromium | Phase 50 执行移除后需重新构建镜像 |

**Nothing found in category:** OS-registered state — 无操作系统级别的注册依赖。

## Common Pitfalls

### Pitfall 1: 误判 StealthySession 为「常用」
**What goes wrong:** 看到 `from scrapling.fetchers import StealthySession, Fetcher` 就认为 StealthySession 是核心功能
**Why it happens:** import 语句在文件顶部，容易误认为两个类都被频繁使用
**How to avoid:** 逐行追踪调用路径 — StealthySession 只在 `--re-analyze` 分支（L698-730）中通过 `create_stealthy_session()` 实例化
**Warning signs:** 代码中有 `# 使用 Fetcher 直连（skykiwi 不需要 StealthySession 浏览器模式）` 注释（L499）

### Pitfall 2: 忽略 re-tag-regions.ts 的 Python 依赖
**What goes wrong:** 只关注 crawl-scheduler.ts，忽略其他 spawn('python3', ...) 调用点
**Why it happens:** re-tag-regions.ts 是手动维护脚本，不在定时流程中
**How to avoid:** 全局搜索 `spawn.*python3` 找到所有调用点（已发现 2 处：crawl-scheduler.ts L253 和 re-tag-regions.ts L52-53）
**Warning signs:** 如果完全移除 Python，re-tag-regions.ts 将无法运行

### Pitfall 3: 认为 API 端点直接执行 Python
**What goes wrong:** 假设某个 API 路由直接 import 或执行 Python 代码
**Why it happens:** 对调用链路不够了解
**How to avoid:** 所有 Python 调用都通过 `child_process.spawn` 间接执行。API 端点 `POST /api/crawl/trigger` 只调用 `scheduler.triggerCrawl()`，后者通过 `spawnCrawler()` 调用 Python

## Python 脚本调用链路完整审计

### 脚本 1: crawl-skykiwi.py（主入口）

| 属性 | 详情 |
|------|------|
| **功能** | Skykiwi 论坛课程数据爬虫主入口 |
| **调用方** | crawl-scheduler.ts（定时+手动）、re-tag-regions.ts（手动维护） |
| **CLI 参数** | `--board tutoring/hobby`、`--incremental`、`--re-analyze <url>`、`--limit <n>`、`--from-cache <date>` |
| **运行频率** | 每天 1 次（定时），偶尔手动触发 |
| **需要 Chromium** | 仅 `--re-analyze` 模式（L698-730），日常 `--board` 模式不需要 |
| **API 端点直接调用** | 否 — 通过 spawn 间接调用 |
| **代码位置** | noda-apps/scripts/crawl-skykiwi.py |

**Fetcher.get() vs StealthySession 使用分析：**

| 函数 | 使用模式 | 需要 Chromium |
|------|---------|--------------|
| `crawl_board()` L494-599 | Fetcher.get() 纯 HTTP | 否 |
| `crawl_board_from_cache()` L602-634 | 本地缓存读取 | 否 |
| `main() --re-analyze 分支` L698-730 | StealthySession | **是** |

### 脚本 2: llm_extract.py

| 属性 | 详情 |
|------|------|
| **功能** | Anthropic Tool Use 两步提取（结构化字段 + 分类标签），含低置信度审核 |
| **调用方** | crawl-skykiwi.py main() L777-814，逐条调用 |
| **需要 Chromium** | 否 |
| **需要 LLM API** | 是 — Anthropic Haiku |
| **API 端点直接调用** | 否 |
| **代码位置** | noda-apps/scripts/llm_extract.py |

### 脚本 3: llm_filter.py

| 属性 | 详情 |
|------|------|
| **功能** | Anthropic Tool Use 批量分类帖子标题，过滤非课程帖 |
| **调用方** | crawl-skykiwi.py main() L748-773 |
| **需要 Chromium** | 否 |
| **需要 LLM API** | 是 — Anthropic Haiku |
| **API 端点直接调用** | 否 |
| **代码位置** | noda-apps/scripts/llm_filter.py |

### 脚本 4: llm_quality_gate.py

| 属性 | 详情 |
|------|------|
| **功能** | 入库前二次过滤（联系方式校验 + LLM 二次确认） |
| **调用方** | crawl-skykiwi.py main() L822-845 |
| **需要 Chromium** | 否 |
| **需要 LLM API** | 是 — Anthropic Haiku |
| **API 端点直接调用** | 否 |
| **代码位置** | noda-apps/scripts/llm_quality_gate.py |

### 脚本 5: db_import.py

| 属性 | 详情 |
|------|------|
| **功能** | 数据库导入：分类映射、质量评分、pg_trgm 排重、Profile 创建、Course upsert |
| **调用方** | crawl-skykiwi.py main() L856-865（当 DATABASE_URL 存在时）、retrofix_data_quality.py |
| **需要 Chromium** | 否 |
| **需要 LLM API** | 否 |
| **需要 DATABASE_URL** | 是 |
| **API 端点直接调用** | 否 |
| **代码位置** | noda-apps/scripts/db_import.py |

### 脚本 6: retrofix_data_quality.py

| 属性 | 详情 |
|------|------|
| **功能** | 数据质量回溯修复（清洗+评分+排重），独立维护脚本 |
| **调用方** | 手动运行（`python3 retrofix_data_quality.py --phase all`） |
| **需要 Chromium** | 否 |
| **需要 LLM API** | 否 |
| **需要 DATABASE_URL** | 是 |
| **API 端点直接调用** | 否 — 独立 CLI 工具 |
| **代码位置** | noda-apps/scripts/retrofix_data_quality.py |

### Node.js 调用点汇总

| 调用文件 | 行号 | spawn 参数 | 触发方式 | 频率 |
|---------|------|-----------|---------|------|
| crawl-scheduler.ts | L253 | `['crawl-skykiwi.py', '--board', 'tutoring']` | cron + API 手动 | 每天 1 次 |
| re-tag-regions.ts | L52-53 | `['scripts/crawl-skykiwi.py', '--re-analyze', url]` | 手动 CLI | 极少 |

### API 端点与爬虫关系

| API 端点 | 作用 | 是否调用 Python |
|---------|------|----------------|
| `POST /api/crawl/trigger` | 手动触发爬虫 | 是 — 通过 crawl-scheduler.ts → spawn python3 |
| `GET /api/crawl/status` | 查看调度器状态 | 否 — 只读内存状态 |
| `GET /api/crawl/history` | 查看执行历史 | 否 — 只读数据库 |
| `GET /api/crawl/stats` | 聚合统计 | 否 — 只读数据库 |

## 决策分析

### StealthySession 使用证据

| 证据 | 来源 | 说明 |
|------|------|------|
| import 语句 | L20 | `from scrapling.fetchers import StealthySession, Fetcher` |
| 封装函数 | L91-102 | `create_stealthy_session()` 定义 |
| 日常抓取注释 | L499 | `# 使用 Fetcher 直连（skykiwi 不需要 StealthySession 浏览器模式）` |
| --re-analyze 使用 | L698-730 | 仅在此分支中调用 `create_stealthy_session()` |
| re-tag-regions.ts | L52-53 | 通过 spawn 触发 --re-analyze 模式 |

### 判断结论

根据 CONTEXT.md D-06 标准（代码证据直接判断）：

**StealthySession 不在日常定时抓取流程中使用。** 日常 `--board tutoring` 模式完全使用 `Fetcher.get()`（纯 HTTP）。StealthySession 仅在 `--re-analyze` 模式中使用，该模式只在以下场景触发：
1. 手动通过 CLI 运行 `python3 crawl-skykiwi.py --re-analyze <url>`
2. 手动通过 `re-tag-regions.ts` 维护脚本调用

两者都是人工手动触发的维护操作，不是自动定时流程。

### 方案 A: 完全移除 Python/Chromium（推荐）

**适用条件：** StealthySession 不在日常流程中使用（已确认满足）

| 方面 | 影响 |
|------|------|
| 镜像体积 | 5.02GB → 约 1.5-2.0GB（节省约 3GB） |
| crawl-scheduler.ts | 删除或注释掉 cron 调度 + spawn 调用 |
| POST /api/crawl/trigger | 返回 501 或移除 |
| --re-analyze 功能 | 废弃（或未来在独立工具中实现） |
| re-tag-regions.ts | 废弃或重写为纯 Node.js 方案 |
| LLM 过滤/提取/质量检查 | 随 Python 一起移除（如需保留，需用 Node.js 重写） |
| db_import.py | 随 Python 一起移除（crawl-skykiwi.py 中已有条件判断：`if os.environ.get('DATABASE_URL')`） |
| Dockerfile 变更 | 移除 L71-76（Python + Chromium apt-get）、L123-130（pip + patchright + scripts COPY） |
| 环境变量清理 | 移除 PLAYWRIGHT_BROWSERS_PATH、CHROMIUM_PATH；ANTHROPIC_* 环境变量可移除 |
| tmpfs 清理 | 移除 `/app/scripts/logs` tmpfs 挂载 |

**优势：**
- 最大镜像体积节省（~3GB）
- 最简架构 — findclass-ssr 只包含 Node.js
- 消除 Python/Chromium 安全补丁面
- 解锁 Alpine 切换（Phase 51）

**劣势：**
- 放弃全部爬虫功能（定时抓取 + LLM 处理 + 数据库导入）
- 如需恢复爬虫，需要全新构建
- re-tag-regions.ts 维护脚本不可用

### 方案 B: 分离为独立爬虫容器

**适用条件：** 需要保留爬虫全部能力

| 方面 | 影响 |
|------|------|
| findclass-ssr 镜像 | 5.02GB → 约 1.5-2.0GB |
| 新增 findclass-crawler 镜像 | 约 400-500MB（python:3.12-slim + Chromium） |
| crawl-scheduler.ts 改造 | spawn → HTTP fetch（最小改动） |
| docker-compose.app.yml | 新增 findclass-crawler 服务 |
| Jenkins Pipeline | 新增 crawler 部署 Pipeline |
| 总镜像体积 | 5.02GB → 1.5-2.0GB + 0.4-0.5GB = 约 2.0-2.5GB |

**优势：**
- 保留全部爬虫能力
- findclass-ssr 独立部署，不依赖 Python
- 爬虫可独立重启/调试

**劣势：**
- 多一个容器维护
- 需要构建新的 Dockerfile + FastAPI 封装
- Jenkins Pipeline 适配工作
- 总镜像体积不如方案 A（多 400-500MB）

### 决策建议

根据 CONTEXT.md D-05（审计后再做决策）和 D-08（StealthySession 未使用 → 完全移除）：

**推荐方案 A（完全移除），条件满足：**
- D-06 标准：StealthySession 不在日常流程中使用 — **确认满足**
- D-07 标准：代码证据直接判断 — **确认满足**
- D-08 指令：StealthySession 未使用 → 完全移除 — **适用**

但最终决策需要人类确认：是否可以接受放弃 `--re-analyze` 和 LLM 处理能力？如果答案为「是」，执行方案 A；如果需要保留，执行方案 B。

## Code Examples

### crawl-scheduler.ts 中唯一的 spawn 调用
```typescript
// Source: noda-apps/apps/findclass/api/src/scripts/crawl-scheduler.ts L251-280
private spawnCrawler(): Promise<number> {
  return new Promise((resolve, reject) => {
    const childProcess = spawn('python3', [...CrawlScheduler.SPAWN_ARGS], {
      cwd: '/app/scripts',
      env: { ...process.env, PYTHONPATH: '/app/scripts' },
    });
    // ...
  });
}
// SPAWN_ARGS = ['crawl-skykiwi.py', '--board', 'tutoring']
```

### StealthySession 唯一使用位置（--re-analyze 模式）
```python
# Source: noda-apps/scripts/crawl-skykiwi.py L698-730
if args.re_analyze:
    for attempt in range(2):
        try:
            with create_stealthy_session(proxy=None, timeout_ms=15000, retries=1) as session:
                page = session.fetch(args.re_analyze)
                break
        except Exception as e:
            last_error = e
    else:
        # 代理回退
        proxy_url = get_proxy_url()
        if proxy_url:
            with create_stealthy_session(proxy=proxy_url, timeout_ms=60000, retries=3) as session:
                page = session.fetch(args.re_analyze)
```

### 日常抓取使用 Fetcher.get()（不需要 Chromium）
```python
# Source: noda-apps/scripts/crawl-skykiwi.py L494-599
def crawl_board(board_url, board_name, ...):
    # 使用 Fetcher 直连（skykiwi 不需要 StealthySession 浏览器模式）
    test_page = Fetcher.get(board_url)     # L502 — 纯 HTTP
    page = Fetcher.get(page_url)           # L522 — 纯 HTTP
    detail_page = Fetcher.get(detail_url)  # L567 — 纯 HTTP
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| 直接 Fetcher + 正则提取 | Fetcher + LLM 三步管道 | 2026-04 逐步演进 | LLM 处理需要 Anthropic API，增加 Python 依赖 |
| StealthySession 默认 | Fetcher.get() 优先 + StealthySession 回退 | 代码注释 L499 | 日常流程不再需要 Chromium |

**Deprecated/outdated:**
- `PLAYWRIGHT_BROWSERS_PATH=0`：对 patchright 无效（Dockerfile 注释 L85 已承认），导致安装了两份 Chromium

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | crawl-scheduler.ts 是唯一自动触发 Python 的调度器 | 调用链路审计 | 如有其他隐藏调度器，移除后爬虫不会被触发 |
| A2 | re-tag-regions.ts 很少使用，可以废弃或重写 | 决策分析 | 如该脚本仍在使用，移除 Python 会影响维护工作 |
| A3 | Dockerfile 中 Python/Chromium 占约 3GB | 体积分析 | 实际节省可能略有差异 |
| A4 | 未来不需要在 findclass-ssr 容器内运行 Python | 决策分析 | 如需恢复，需要重新添加或走方案 B |

**If this table is empty:** 不适用 — 有 4 项假设需要确认。

## Open Questions

1. **--re-analyze 功能是否需要保留？**
   - What we know: 仅在手动维护场景使用（re-tag-regions.ts），不在自动流程中
   - What's unclear: 是否有未记录的定期维护流程依赖它
   - Recommendation: 如果无定期维护依赖，建议废弃；如有，方案 B 保留

2. **定时爬虫是否需要继续运行？**
   - What we know: crawl-scheduler.ts 每天执行一次
   - What's unclear: 数据源（skykiwi 论坛）是否仍有新内容、用户是否仍依赖抓取数据
   - Recommendation: 如继续需要抓取 → 方案 B；如可以暂停或废弃 → 方案 A

3. **LLM 处理管道是否需要在 Node.js 中重新实现？**
   - What we know: 当前 Python 实现了三步 LLM 管道（过滤→提取→质量检查）
   - What's unclear: 是否有计划用 Node.js 重写
   - Recommendation: 不在本阶段决定 — 属于 Phase 50 执行细节或后续阶段

## Environment Availability

> 本阶段为纯审计阶段，无需外部依赖。Phase 50 执行时需要 Docker 构建环境。

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| noda-apps 源码 | 审计 | Yes | 本地 /Users/dianwenwang/Project/noda-apps | — |
| Docker | Phase 50 构建 | 跳过（本阶段不需要） | — | — |

**Step 2.6: SKIPPED（本阶段为纯代码审计，无外部依赖）**

## Validation Architecture

> nyquist_validation enabled in config.json

### Test Framework
| Property | Value |
|----------|-------|
| Framework | 无（审计阶段，无代码变更需要测试） |
| Config file | 无 |
| Quick run command | 无（只读审计） |
| Full suite command | 无 |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SSR-01 | Python 脚本调用链路审计完成 | manual-only（文档审计） | — | N/A |
| SSR-02 | 移除/分离方案文档化 | manual-only（决策文档） | — | N/A |

**Justification for manual-only:** 本阶段只做审计和决策，不写代码。验证标准是文档完整性和逻辑自洽性，不需要自动化测试。

### Wave 0 Gaps
- None — 本阶段无代码变更，现有测试基础设施不适用

## Security Domain

> security_enforcement: enabled（default）

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | 不涉及认证变更 |
| V3 Session Management | no | 不涉及会话管理 |
| V4 Access Control | no | 不涉及权限变更 |
| V5 Input Validation | no | 不涉及输入验证 |
| V6 Cryptography | no | 不涉及加密 |

**安全影响分析：** 移除 Python/Chromium 实际上**减少**了攻击面（消除 Chromium 漏洞面、Python 依赖链攻击风险）。本阶段无安全风险。

### Known Threat Patterns for Python/Chromium in Container

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Chromium 漏洞利用 | Tampering/Elevation | 移除 Chromium 消除此风险 |
| Python pip 供应链攻击 | Tampering | 移除 Python 消除此风险 |
| patchright 浏览器指纹 | Information Disclosure | 移除 patchright 消除此风险 |

## Sources

### Primary (HIGH confidence)
- noda-apps 代码: `scripts/crawl-skykiwi.py` — 完整源码审计，Fetcher.get() vs StealthySession 使用分析 [VERIFIED: 逐行代码审查]
- noda-apps 代码: `apps/findclass/api/src/scripts/crawl-scheduler.ts` — spawn 调用链路完整分析 [VERIFIED: 逐行代码审查]
- noda-apps 代码: `apps/findclass/api/src/routes/crawl.ts` — API 端点定义 [VERIFIED: 逐行代码审查]
- noda-apps 代码: `apps/findclass/api/src/api.ts` — 服务器启动流程，确认调度器自动启动 [VERIFIED: 逐行代码审查]
- noda-apps 代码: `scripts/llm_filter.py`, `scripts/llm_extract.py`, `scripts/llm_quality_gate.py`, `scripts/db_import.py`, `scripts/retrofix_data_quality.py` — 全部 Python 脚本审计 [VERIFIED: 逐行代码审查]
- noda-apps 代码: `apps/findclass/api/src/scripts/re-tag-regions.ts` — 第二个 spawn('python3', ...) 调用点 [VERIFIED: grep 搜索]
- noda-infra 代码: `deploy/Dockerfile.findclass-ssr` — Python/Chromium 安装位置确认 [VERIFIED: 逐行审查]
- noda-infra 代码: `docker/docker-compose.app.yml` — findclass-ssr 服务定义 [VERIFIED: 逐行审查]

### Secondary (MEDIUM confidence)
- `.planning/research/ARCHITECTURE.md` — 镜像体积分析（5.02GB，Python/Chromium 占 ~3GB） [CITED: 项目研究文档]
- `.planning/research/FEATURES.md` — Fetcher.get() vs StealthySession 初步分析 [CITED: 项目研究文档]

### Tertiary (LOW confidence)
- 无 — 所有发现均通过源码直接验证

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 全部通过源码逐行验证
- Architecture: HIGH — 调用链路通过 grep + 逐行审查完整追踪
- Pitfalls: HIGH — 基于实际代码分析，非假设
- 决策建议: HIGH — 基于 CONTEXT.md D-06/D-07/D-08 标准和代码证据

**Research date:** 2026-04-20
**Valid until:** 30 天（代码稳定，变更频率低）
