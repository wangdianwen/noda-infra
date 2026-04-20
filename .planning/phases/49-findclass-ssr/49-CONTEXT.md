# Phase 49: findclass-ssr 爬虫审计与决策 - Context

**Gathered:** 2026-04-20
**Status:** Ready for planning

<domain>
## Phase Boundary

完整审计 findclass-ssr 中所有 Python 脚本的调用链路，制定 Python/Chromium/patchright 移除或分离的最终方案。本阶段只做审计和决策，不执行代码变更（执行在 Phase 50）。

**涉及需求：** SSR-01, SSR-02

**前置条件：** 无（独立阶段，但必须在 Phase 50 之前完成）

</domain>

<decisions>
## Implementation Decisions

### 审计方式
- **D-01:** 克隆 noda-apps 仓库到本地进行完整源码审计，获取第一手调用链路数据
- **D-02:** 聚焦审计范围 — 只审计 Python 脚本和 crawl-scheduler.ts，不涉及前端和其他无关代码
- **D-03:** 审计产出为 RESEARCH.md 文档（GSD 标准流程），记录完整调用链路和运行频率
- **D-04:** 审计内容必须包含：每个 Python 脚本的功能、调用方、是否有 API 端点直接触发、实际运行频率

### 移除 vs 分离决策
- **D-05:** 审计完成后再做最终决策，不预先承诺移除或分离
- **D-06:** 决策条件以 StealthySession 是否实际使用为准 — 如果代码证据显示 StealthySession 仅在条件分支中存在但从未实际触发（无调用记录、无配置引用），则视为未使用
- **D-07:** 判断方式为代码证据直接判断，不需要在生产环境观察运行时行为
- **D-08:** 如果 StealthySession 未实际使用 → 完全移除 Python/Chromium（最大节省 ~3GB）
- **D-09:** 如果 StealthySession 有实际使用 → 分离为独立爬虫容器（保留完整能力）

### 独立容器架构（条件决策，仅在分离时适用）
- **D-10:** 新爬虫容器加入现有 docker-compose.app.yml，与 findclass-ssr 在同一 Docker Compose 项目中
- **D-11:** 爬虫触发方式：crawl-scheduler.ts 通过 HTTP POST 调用爬虫容器（spawn → HTTP fetch）
- **D-12:** crawl-scheduler.ts 改造范围最小化 — 只改调用方式（spawn → HTTP fetch），不重写调度逻辑
- **D-13:** 爬虫容器单实例运行，不采用蓝绿部署（爬虫是后台任务，不需要零停机切换）

### Claude's Discretion
- noda-apps 仓库的克隆位置和克隆后清理
- 审计文档的具体格式和结构
- RESEARCH.md 中调用链路图的展示方式
- 决策分析的深度和细节

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 需求定义
- `.planning/REQUIREMENTS.md` §SSR-01, SSR-02 — 本 phase 的两个核心需求
- `.planning/ROADMAP.md` §Phase 49 — 目标、依赖、成功标准

### 研究文档（已存在，含初步分析）
- `.planning/research/ARCHITECTURE.md` — 镜像体积分析、爬虫架构分析、分离方案草案
- `.planning/research/FEATURES.md` — Fetcher.get() vs StealthySession 使用分析

### Dockerfile（审计目标）
- `deploy/Dockerfile.findclass-ssr` — findclass-ssr Dockerfile，Stage 2 包含 Python + Chromium 安装

### Docker Compose（集成点）
- `docker/docker-compose.app.yml` — findclass-ssr 服务定义（如分离，爬虫容器将加入此文件）

### 前序 Phase 决策
- `.planning/phases/47-noda-site-image/47-CONTEXT.md` — noda-site 镜像优化经验
- `.planning/phases/48-docker-hygiene/48-CONTEXT.md` — Docker 最佳实践（.dockerignore、COPY --chown）

### 源码仓库（需克隆）
- noda-apps 仓库 — Python 脚本（crawl-skykiwi.py, llm_extract.py, db_import.py）和 crawl-scheduler.ts 所在位置

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `docker/docker-compose.app.yml` — 已有的 docker-compose 文件，新容器可加入
- `scripts/blue-green-deploy.sh` — 蓝绿部署参数化框架（如需要可复用，但爬虫容器决定不用蓝绿）
- `scripts/lib/health.sh` — wait_container_healthy() 函数，可用于爬虫容器健康检查

### Established Patterns
- Docker Compose overlay 模式：基础 + prod + dev 三层配置
- 蓝绿部署参数化：SERVICE_NAME/SERVICE_PORT/HEALTH_PATH
- Jenkins Pipeline 部署：每个服务有独立 Jenkinsfile
- 容器安全：read_only + cap_drop:ALL + tmpfs 最小权限
- 非 root 运行：所有自建容器使用专用用户

### Integration Points
- `deploy/Dockerfile.findclass-ssr` line 71-76 — Python + Chromium 安装（审计/移除目标）
- `deploy/Dockerfile.findclass-ssr` line 123-130 — Python 依赖和脚本复制（审计/移除目标）
- `docker/docker-compose.app.yml` — findclass-ssr 服务定义，如分离则添加爬虫容器服务
- noda-apps `crawl-scheduler.ts` — spawn('python3', ...) 调用点（审计核心目标）

### 已知信息（来自研究文档）
- findclass-ssr 镜像体积 5.02GB，其中 Python/Chromium/patchright 占 ~3GB
- crawl-skykiwi.py 主流程使用 Fetcher.get()（HTTP-only，不需要浏览器）
- StealthySession（需 Chromium）仅在直连失败或绕 Cloudflare 时使用
- PLAYWRIGHT_BROWSERS_PATH=0 对 patchright 无效（Dockerfile 注释已承认）
- Python 依赖 scrapling/patchright 需要 manylinux wheels，不支持 Alpine

</code_context>

<specifics>
## Specific Ideas

- 审计时重点关注：StealthySession 的代码路径是否有配置开关、是否有运行时调用痕迹
- 研究文档已推荐 python:3.12-slim 作为独立爬虫容器基础镜像（不用 Alpine，因为 manylinux 兼容性）
- 爬虫容器与 findclass-ssr 通过 Docker 内部网络通信（已在同一 docker-compose 项目中）
- crawl-scheduler.ts 改造应保持现有超时和错误处理逻辑不变，只替换 spawn 为 fetch

</specifics>

<deferred>
## Deferred Ideas

- findclass-ssr Alpine 切换 — Phase 51（依赖 Python 完全移除）
- findclass-ssr devDependencies 清理 — Phase 51
- COPY 层顺序优化 — Phase 51
- 爬虫容器具体实现和部署 — Phase 50（如果分离）
- Jenkins Pipeline 适配爬虫容器部署 — Phase 50

</deferred>

---
*Phase: 49-findclass-ssr*
*Context gathered: 2026-04-20*
