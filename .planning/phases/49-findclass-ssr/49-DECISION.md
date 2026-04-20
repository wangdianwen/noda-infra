# Phase 49 决策文档：Python/Chromium 完全移除

**决策日期:** 2026-04-20
**决策状态:** 已确认
**审计依据:** 49-RESEARCH.md（完整源码审计）
**执行阶段:** Phase 50

---

## 决策结论

**选定方案：方案 A -- 完全移除 Python/Chromium/patchright**

决策依据（引用 CONTEXT.md 决策 ID）：
- D-06 标准：StealthySession 不在日常定时抓取流程中使用 -- **确认满足**（代码证据：crawl_board() L494-599 使用 Fetcher.get()，`--re-analyze` 模式 L698-730 使用 StealthySession，仅手动触发）
- D-07 标准：代码证据直接判断 -- **确认满足**（逐行源码审查，无运行时猜测）
- D-08 指令：StealthySession 未使用 → 完全移除 -- **适用**
- 用户明确确认：可以放弃定时爬虫和 LLM 处理能力

---

## 审计完整性验证（SSR-01）

Task 1 验证结论：**49-RESEARCH.md 审计覆盖 SSR-01 全部要求，无遗漏。**

| 验证项 | 状态 | 详情 |
|--------|------|------|
| 6 个 Python 脚本独立章节 | 通过 | 每个脚本均有功能/调用方/Chromium 依赖/API 端点关系 |
| 2 处 spawn('python3', ...) 调用点 | 通过 | crawl-scheduler.ts L253 + re-tag-regions.ts L52-53 |
| 4 个 API 端点与 Python 关系 | 通过 | trigger(间接调用) + status/history/stats(不调用) |
| StealthySession 使用分析 | 通过 | 仅 --re-analyze 模式(L698-730)，日常 Fetcher.get() |

---

## 影响范围

### 功能影响

| 功能 | 影响 | 处理方式 |
|------|------|----------|
| 定时爬虫（crawl-scheduler.ts cron） | 废弃 | Phase 50 移除调度逻辑 |
| POST /api/crawl/trigger | 废弃 | Phase 50 返回 501 或移除端点 |
| GET /api/crawl/status\|history\|stats | 只读端点 | Phase 50 评估是否保留（无 Python 依赖，可能仍可返回数据库数据） |
| --re-analyze 模式 | 废弃 | 无替代方案 |
| re-tag-regions.ts 维护脚本 | 废弃 | 无替代方案 |
| LLM 过滤/提取/质量检查 | 废弃 | 无替代方案 |
| db_import.py | 废弃 | crawl_executions 表数据保留但不再新增 |

### Dockerfile 变更清单（Phase 50 执行）

基于 deploy/Dockerfile.findclass-ssr 精确行号：

| 行号 | 当前内容 | Phase 50 操作 |
|------|----------|---------------|
| L67 注释 | `# Stage 2: 运行镜像（Debian slim，兼容 Python manylinux wheels）` | 更新注释，移除 Python 相关说明 |
| L71-76 | `RUN apt-get install python3 python3-pip python3-venv chromium` | **删除整段** -- Python/Chromium 安装 |
| L84-86 | `ENV PLAYWRIGHT_BROWSERS_PATH=0` / `ENV CHROMIUM_PATH=/usr/bin/chromium` | **删除** -- 不再需要 |
| L121-130 | Python 爬虫运行时（requirements.txt + pip install + patchright install + scripts COPY） | **删除整段** |
| L133 | `RUN chown -R nodejs:nodejs /app` | 保留，但后续 Phase 51 可能改用 COPY --chown |

### docker-compose.app.yml 变更清单

| 配置项 | 当前值 | Phase 50 操作 |
|--------|--------|---------------|
| `tmpfs: /app/scripts/logs` | Python 爬虫日志目录 | **删除此 tmpfs 条目** |
| `ANTHROPIC_AUTH_TOKEN` | Python LLM 脚本使用 | **删除环境变量** |
| `ANTHROPIC_BASE_URL` | Python LLM 脚本使用 | **删除环境变量** |
| `ANTHROPIC_API_KEY` | Python LLM 脚本使用 | **删除环境变量** |
| memory limit `1G` | 包含 Python 运行时 | Phase 50 可考虑降低至 512M（移除 ~3GB 运行时后内存占用显著减少） |

### 预期效果

| 指标 | 当前 | 移除后 | 改善 |
|------|------|--------|------|
| 镜像体积 | 5.02GB | ~1.5-2.0GB | 节省 ~3GB |
| 攻击面 | Python + Chromium + patchright | 纯 Node.js | 显著减少 |
| 内存占用 | ~512MB-1G | ~256-512MB | 减少约 50% |
| 构建时间 | 包含 pip install + patchright install | 纯 Node.js | 减少约 2-3 分钟 |

---

## Phase 50 执行指引

### 移除步骤（按依赖顺序）

1. **Dockerfile 清理** -- 删除 Python/Chromium 安装（L71-76）、pip 依赖（L121-130）、Chromium 环境变量（L84-86）、更新注释（L67）
2. **docker-compose.app.yml 清理** -- 删除 ANTHROPIC_* 环境变量（3 项）、/app/scripts/logs tmpfs 条目
3. **crawl-scheduler.ts 改造** -- 移除 cron 调度逻辑和 spawn 调用（需在 noda-apps 仓库操作）
4. **crawl API 端点处理** -- trigger 返回 501 或移除，status/history/stats 评估保留
5. **re-tag-regions.ts 处理** -- 废弃或标记为不可用
6. **构建验证** -- docker build + 健康检查 + 镜像体积确认

### 不移除的内容

- crawl_executions 表（历史数据保留）
- crawl API 只读端点（如不依赖 Python 可保留）
- DATABASE_URL 环境变量（Node.js API 仍需连接数据库）

### Phase 51 后续优化（移除完成后）

- findclass-ssr 基础镜像从 node:22-slim 切换到 node:22-alpine（节省额外 ~100MB）
- devDependencies 清理
- COPY 层顺序优化
- COPY --chown 替代 RUN chown

---

## 假设确认

| # | 假设 | 确认状态 | 证据来源 |
|---|------|----------|----------|
| A1 | crawl-scheduler.ts 是唯一自动触发 Python 的调度器 | 已确认 | RESEARCH.md 调用链路审计 -- 全局搜索 spawn.*python3 仅 2 处，只有 crawl-scheduler.ts 是定时调度 |
| A2 | re-tag-regions.ts 很少使用，可以废弃 | 已确认 | 用户决策（D-08）：放弃定时爬虫 = 放弃全部 Python 能力 |
| A3 | Python/Chromium 占约 3GB | 已确认 | RESEARCH.md 体积分析 -- 5.02GB → 预计 ~1.5-2.0GB |
| A4 | 未来不需要在 findclass-ssr 容器内运行 Python | 已确认 | 用户选择方案 A -- 如需恢复，走独立容器方案 |

---

## 风险评估

| 风险 | 可能性 | 影响 | 缓解措施 |
|------|--------|------|----------|
| 未来需要恢复爬虫功能 | 低 | 中 | 独立容器方案 B 仍可作为新阶段实施 |
| crawl_executions 表历史数据查询受影响 | 低 | 低 | 只读端点如不依赖 Python 可保留 |
| 遗漏其他 Python 调用点 | 极低 | 中 | 全局搜索已确认仅 2 处 spawn 调用 |
