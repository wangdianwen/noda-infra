# Project Research Summary

**Project:** Noda Infrastructure -- Docker 镜像瘦身优化 (v1.10)
**Domain:** Docker Compose 单服务器基础设施 -- 镜像体积优化
**Researched:** 2026-04-20
**Confidence:** HIGH

## Executive Summary

Noda 单服务器 Docker Compose 基础设施的镜像总体积约 2.5-5GB（取决于计数方式），其中 findclass-ssr 占 80% 以上（约 5GB）。代码审计揭示了一个关键发现：findclass-ssr 容器包含完整的 Python 运行时 + Chromium 浏览器 + patchright 浏览器（约 3GB），但实际爬虫主流程仅使用 `Fetcher.get()`（纯 HTTP 请求），`StealthySession`（需要浏览器）虽然已定义但未在主流程中调用。这意味着约 60% 的镜像体积是运行时完全不需要的死重。

研究的核心建议分两条主线：(1) **findclass-ssr 剥离 Python/Chromium**，将爬虫脚本移至独立的定时任务容器（或直接移除浏览器依赖保留 Fetcher-only 模式），主容器从 node:22-slim 切换到 node:22-alpine，预计从 5GB 降至 300-400MB；(2) **noda-site 消除 Node.js 运行时**，用 nginx 直接服务纯静态文件（或用 static-web-server ~4MB 替换 serve），从 218MB 降至 15-30MB 或完全消除容器。noda-ops 已是最优状态，仅建议微调构建工具清理。test-verify 的 PostgreSQL 15 与生产环境 17 版本不统一，需对齐以共享 Docker 层缓存。

关键风险集中在四个方面：(1) Python 原生依赖（lxml/orjson/greenlet）无 musllinux wheel，findclass-ssr 的 Node.js 容器不能切 Alpine 必须在分离 Python 后才能切；(2) noda-site 的端口 3000 被 6 个文件引用（蓝绿部署、Jenkins Pipeline、健康检查、nginx upstream），迁移时必须逐一更新或保持端口不变；(3) 蓝绿部署的镜像命名约定（SERVICE_NAME:latest + :git_sha）不能被 Dockerfile 路径或构建上下文变更打破；(4) 双层 nginx（外部反代 + 内部静态文件服务）的安全头和 gzip 可能冲突。

## Key Findings

### Recommended Stack

镜像优化的核心不是引入新技术，而是正确选择基础镜像和架构模式。findclass-ssr 的 Python/Chromium 分离后，Node.js 运行时可以安全切换到 Alpine（无原生模块依赖）。爬虫容器（如需浏览器功能）应使用 python:3.12-slim（Debian-based），因为 scrapling 的 C 扩展需要 manylinux wheel，Alpine 上会编译失败。noda-site 的 static-web-server（Rust 编写，scratch 镜像 4MB）是比 nginx:alpine 更极致的选择，但 STACK 和 ARCHITECTURE 研究出现分歧：STACK 推荐 Nginx 直接服务（已有 nginx 容器，零新组件），ARCHITECTURE 推荐保留 noda-site 容器但换 nginx:alpine 运行时。**综合判断：推荐 ARCHITECTURE 的方案（保留容器 + nginx:alpine 运行时），保持端口 3000 和蓝绿部署兼容性。**

**Core technologies:**
- **node:22-alpine:** findclass-ssr 运行时基础镜像（分离 Python 后） -- 比 slim 小 ~185MB，无原生模块依赖时完全兼容
- **python:3.12-slim:** 独立爬虫容器基础镜像（如需分离） -- manylinux wheel 原生兼容，避免 Alpine 编译问题
- **nginx:1.25-alpine:** noda-site 运行时替代 -- 从 180MB Node.js 降至 ~25MB，项目已有 nginx 经验
- **postgres:17-alpine:** test-verify 镜像统一 -- 与 backup 容器共享基础层，消除版本不一致

### Expected Features

**Must have (table stakes):**
- **TS-2: 分离 Python/Chromium 爬虫** -- findclass-ssr 5GB 的 60% 来自不需要的浏览器运行时，这是整个里程碑的核心价值
- **TS-3/D-1: noda-site 替换 npm serve** -- 218MB 的 Node.js 运行时仅服务纯静态文件，必须优化
- **TS-4: test-verify 统一到 postgres:17-alpine** -- PG15 vs PG17 版本不统一，备份验证可能不可靠
- **TS-5: 优化层缓存顺序** -- 先复制依赖声明再复制源码，Docker 最佳实践

**Should have (competitive):**
- **D-2: findclass-ssr 降级到 alpine** -- 依赖 TS-2 完成后才能安全切换，额外节省 ~70MB
- **TS-1: prune devDependencies** -- 多阶段构建中运行时只复制生产依赖
- **D-3: noda-ops 精简构建工具** -- wget/gnupg 仅构建时需要，运行时不需要

**Defer (v2+):**
- **Dive 工具集成** -- CI 中镜像效率评分作为质量门禁
- **多架构构建** -- 当前服务器 x86，暂不需要 ARM 支持
- **static-web-server 迁移** -- noda-site 换 nginx:alpine 已足够，static-web-server 是更极致但非必要的选择

### Architecture Approach

核心架构模式是"单一职责容器"：findclass-ssr 当前违反了这个原则，混合了 Node.js + Python + Chromium 三个运行时。分离后，每个容器只做一件事 -- Node.js 负责 API + SSR，Python 负责（按需）爬虫，Nginx 负责静态文件服务。爬虫调用链从 `spawn('python3', ...)` 改为 `HTTP POST http://findclass-crawler:8080/crawl`，保持 API 接口不变。

**Major components:**
1. **findclass-ssr（瘦身后）** -- Node.js API + SSR + 静态文件，基础镜像 node:22-alpine，体积 ~300-400MB
2. **findclass-crawler（新增，可选）** -- Python 爬虫 + FastAPI 封装，基础镜像 python:3.12-slim，按需运行
3. **noda-site（重构后）** -- Nginx 静态文件服务，基础镜像 nginx:1.25-alpine，保持端口 3000 兼容蓝绿部署
4. **noda-ops（微调）** -- 构建工具移至 builder 阶段，运行时精简

### Critical Pitfalls

1. **Python manylinux wheel 不兼容 Alpine（Critical）** -- lxml/orjson/greenlet 最新版本无 musllinux wheel。findclass-ssr 的 Node.js 容器在分离 Python 前不能切 Alpine。分离后 Node.js 容器无 Python 依赖，可以安全切 Alpine。

2. **noda-site 端口 3000 被 6 个文件引用（Critical）** -- Jenkinsfile.noda-site、manage-containers.sh、upstream-noda-site.conf、docker-compose.app.yml 健康检查、Dockerfile HEALTHCHECK。迁移时必须保持 `listen 3000` 或逐一更新所有引用。推荐保持 3000 端口减少变更范围。

3. **蓝绿部署镜像命名约定不能打破（Critical）** -- SERVICE_NAME:latest + SERVICE_NAME:git_sha 的约定被 image-cleanup.sh、manage-containers.sh、blue-green-deploy.sh 依赖。Dockerfile 路径变更必须同步所有 Jenkinsfile 和 docker-compose.app.yml。

4. **双层 nginx 安全头冲突（Moderate）** -- noda-site 内部 nginx 和外部 nginx 都可能设置安全头、gzip。内部 nginx 应最小配置（仅静态文件服务），安全头和 gzip 由外部 nginx 统一管理。

5. **Chromium /dev/shm 不足导致崩溃（Moderate）** -- 当前 docker-compose.app.yml 配置 read_only: true + 64MB tmpfs。Chromium 需要至少 256MB /dev/shm。如果保留 Chromium（爬虫容器），必须配置 shm_size: '256m' 和 --no-sandbox。

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: 低风险快速收益（noda-site + test-verify + noda-ops 微调）
**Rationale:** 这三个优化互相独立，风险低，不需要架构变更，可以并行执行。noda-site 是最大的非架构性优化（218MB -> ~25MB），test-verify 是一行改动（PG15 -> PG17），noda-ops 是构建工具清理。先做这些积累信心和经验。
**Delivers:** noda-site 体积减少 ~85%，test-verify 版本统一，noda-ops 构建工具清理
**Addresses:** TS-3/D-1, TS-4, D-3, D-5
**Avoids:** Pitfall 1（不涉及 Python），Pitfall 3（保持端口 3000），Pitfall 4（不涉及 COPY 重构）
**Key constraint:** noda-site 必须保持端口 3000，内部 nginx 最小配置，蓝绿部署全流程验证

### Phase 2: findclass-ssr 瘦身核心（分离 Python/Chromium）
**Rationale:** 这是整个里程碑的核心价值（5GB -> ~2GB），但也是风险最高的改动。需要先确认爬虫调用方式的完整链路，然后决定是（A）直接移除 Python/Chromium 保留 Fetcher-only，还是（B）创建独立爬虫容器。推荐方案 A（移除，因为 StealthySession 未在主流程使用），方案 B 作为未来升级路径。
**Delivers:** findclass-ssr 体积减少 ~60%，移除 Python/Chromium 死重
**Addresses:** TS-2
**Avoids:** Pitfall 1（分离后 Node.js 可切 Alpine），Pitfall 5（保持镜像命名约定），Pitfall 8（彻底移除 patchright 而非复制）
**Key constraint:** crawl-scheduler.ts 的 spawn 调用必须处理（要么移除要么改为 HTTP），llm_extract.py/db_import.py 等脚本需确认是否有 API 端点调用

### Phase 3: 分离后优化（Alpine 切换 + devDependencies 清理）
**Rationale:** 依赖 Phase 2 完成。Python 分离后 findclass-ssr 不再需要 Debian 的 glibc（无 manylinux wheel 依赖），可以安全切换到 Alpine。同时执行 pnpm prune --prod 清理开发依赖。
**Delivers:** findclass-ssr 额外减少 ~200-300MB（Alpine -185MB + devDeps -50-100MB）
**Addresses:** D-2, TS-1
**Uses:** node:22-alpine, pnpm prune --prod
**Avoids:** Pitfall 6（Alpine DNS 差异 -- Node.js 容器仅连接 Docker 内部服务，影响极小）
**Key constraint:** 必须验证 Hono 框架、Drizzle ORM pg 驱动、pnpm workspace 符号链接在 Alpine 下的兼容性

### Phase 4: 卫生优化（.dockerignore + COPY --chown + 层缓存顺序）
**Rationale:** 锦上添花的小优化，不减少镜像体积但提升构建效率。每个都是几行改动，风险极低。可以在任何阶段穿插执行，单独列为 Phase 方便追踪。
**Delivers:** 构建加速（层缓存优化），Dockerfile 代码卫生
**Addresses:** TS-5, D-4, D-6
**Key constraint:** 无

### Phase Ordering Rationale

- Phase 1 先行：低风险高收益，不需要架构理解，适合建立优化信心
- Phase 2 是核心：最高风险最高收益，需要深入理解 crawl-scheduler.ts 和爬虫调用链路
- Phase 3 依赖 Phase 2：只有 Python 分离后才能安全切 Alpine（Pitfall 1）
- Phase 4 随时可以：独立的小优化，不影响其他阶段

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2:** 爬虫完整调用链路审计（crawl-scheduler.ts -> crawl-skykiwi.py -> llm_extract.py -> db_import.py -> API 端点），确认哪些脚本有 API 入口调用，不能简单移除
- **Phase 2:** 如果选择方案 B（独立爬虫容器），需要研究 FastAPI 封装 + Docker Compose 集成 + Jenkins Pipeline 新建
- **Phase 3:** node:22-alpine 下的 pnpm workspace 符号链接解析，需实际构建验证

Phases with standard patterns (skip research-phase):
- **Phase 1:** noda-site nginx 迁移和 test-verify 版本更新都是标准 Dockerfile 修改，文档充分
- **Phase 4:** .dockerignore 和层缓存顺序是 Docker 基础最佳实践

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | 基于项目代码实际分析 + Docker Hub 镜像体积数据 + pip wheel 兼容性实测验证 |
| Features | HIGH | 基于完整 Dockerfile 审计 + crawl-skykiwi.py 代码分析，Fetcher vs StealthySession 的结论有代码注释佐证 |
| Architecture | HIGH | 基于完整代码库审计，crawl-scheduler.ts 的 spawn 调用链路已追踪，蓝绿部署影响已评估 |
| Pitfalls | HIGH | Python manylinux 兼容性通过 pip download --platform 实测验证；其他 Pitfall 基于代码审计推导 |

**Overall confidence:** HIGH

### Gaps to Address

- **findclass-ssr 实际镜像体积分歧：** STACK 报告 ~2GB，FEATURES 报告 ~5GB。差异可能来自 docker images 输出 vs 构建上下文大小。需要在规划阶段用 `docker images findclass-ssr --format "{{.Size}}"` 获取准确数值
- **noda-site 优化方案分歧：** STACK 推荐由现有 Nginx 直接服务静态文件（消除容器），ARCHITECTURE 推荐保留容器换 nginx:alpine 运行时。两种方案各有优劣，需要在规划阶段根据蓝绿部署兼容性做最终决策。当前推荐 ARCHITECTURE 方案（保持容器 + 端口 3000）
- **llm_extract.py / db_import.py 调用链路：** 研究确认了 crawl-skykiwi.py 使用 Fetcher，但未完全确认其他 Python 脚本是否有独立的 API 端点调用。Phase 2 规划时必须审计
- **static-web-server vs nginx:alpine 最终选择：** static-web-server（4MB scratch）更极致，但引入新组件。nginx:alpine（~25MB）与现有架构一致。对于 218MB 的优化目标两者差距不大，推荐保守选择 nginx:alpine

## Sources

### Primary (HIGH confidence)
- 项目代码: `deploy/Dockerfile.findclass-ssr` -- Python/Chromium 依赖逐行分析
- 项目代码: `noda-apps/scripts/crawl-skykiwi.py` -- Fetcher vs StealthySession 使用分析（代码注释确认 Fetcher-only）
- 项目代码: `deploy/Dockerfile.noda-site` -- serve 静态文件服务分析
- 项目代码: `deploy/Dockerfile.noda-ops` -- Alpine 包依赖审计
- 项目代码: `scripts/backup/docker/Dockerfile.test-verify` -- PG15 版本不匹配确认
- 项目代码: `config/nginx/conf.d/default.conf` -- noda-site 安全头和 gzip 配置
- 项目代码: `jenkins/Jenkinsfile.noda-site` -- 端口 3000 引用
- Context7: Docker 官方文档 -- Alpine 镜像兼容性、多阶段构建最佳实践、glibc/musl 选择指南
- pip wheel 兼容性实测 -- lxml/orjson/greenlet 最新版本无 musllinux wheel（pip download --platform 验证）

### Secondary (MEDIUM confidence)
- Docker Hub: node:22-alpine vs node:22-slim 镜像体积对比 -- 基于训练数据，未实时验证
- Docker Hub: nginx:1.25-alpine 镜像体积 -- 基于训练数据
- Scrapling GitHub: Fetcher 底层使用 httpx -- 基于训练知识，未通过 WebSearch 验证
- Chromium Docker read_only 兼容性 -- 基于训练知识和 Playwright 文档

### Tertiary (LOW confidence)
- 具体镜像体积数值（不同架构和版本有差异）-- 需在目标服务器上 `docker images` 实测
- patchright PLAYWRIGHT_BROWSERS_PATH=0 行为 -- 基于 Dockerfile 注释推断

---
*Research completed: 2026-04-20*
*Ready for roadmap: yes*
