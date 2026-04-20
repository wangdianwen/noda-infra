# Requirements: v1.10 Docker 镜像瘦身优化

**Defined:** 2026-04-20
**Core Value:** 全面优化所有自建 Docker 镜像体积，减少构建时间、磁盘占用和部署带宽

## v1.10 Requirements

### SITE — noda-site 镜像优化

- [x] **SITE-01**: noda-site 运行时从 node:20-alpine + serve 切换到 nginx:1.25-alpine（保持端口 3000，蓝绿部署兼容）
- [x] **SITE-02**: 多阶段构建保留 Puppeteer prerender 构建阶段，运行时仅包含静态文件 + nginx
- [x] **SITE-03**: Jenkins Pipeline noda-site 部署流程适配新 Dockerfile（构建参数、健康检查）

### HYGIENE — 全局 Docker 最佳实践

- [x] **HYGIENE-01**: 所有自建 Dockerfile 添加/更新 .dockerignore（排除 .git、.planning、node_modules、worktrees）
- [x] **HYGIENE-02**: 所有 COPY 指令使用 --chown 替代单独 RUN chown（减少镜像层数）
- [x] **HYGIENE-03**: test-verify 基础镜像从 postgres:15-alpine 统一到 postgres:17-alpine（与 backup 共享层缓存）

### SSR — findclass-ssr 核心瘦身

- [x] **SSR-01**: 审计 findclass-ssr 中所有 Python 脚本的调用链路（crawl-skykiwi.py、llm_extract.py、db_import.py 等），确认是否有 API 端点直接调用
- [x] **SSR-02**: 根据审计结果，制定 Python/Chromium/patchright 移除或分离方案（直接移除 vs 独立容器）
- [ ] **SSR-03**: 执行 Python/Chromium/patchright 运行时移除（估计 5GB → ~2GB，节省 ~3GB）
- [ ] **SSR-04**: 移除后端到端验证：API 健康检查、SSR 渲染、静态文件服务、爬虫功能（如保留）

### SSR-DEEP — findclass-ssr 深度优化（依赖 SSR 完成）

- [ ] **SSR-DEEP-01**: 评估 findclass-ssr 从 node:22-slim 切换到 node:22-alpine 的兼容性（native 模块验证）
- [ ] **SSR-DEEP-02**: 清理构建阶段 devDependencies（pnpm prune --prod 或等效方案）
- [ ] **SSR-DEEP-03**: 优化 COPY 层顺序（低频变更依赖在前，高频变更源码在后）

### INFRA — 基础设施镜像清理

- [ ] **INFRA-01**: noda-ops 依赖审计（确认 wget/gnupg/coreutils 运行时是否必需，非必需移到构建阶段）
- [ ] **INFRA-02**: backup Dockerfile 清理（移除冗余层、统一 RUN 指令、添加 .dockerignore）

## Future Requirements

### 待 SSR 审计后决定

- **CRAWL-01**: 如需保留爬虫能力 — 创建独立 findclass-crawler 容器（FastAPI + patchright + Chromium）
- **CRAWL-02**: crawl-scheduler.ts 从 spawn('python3', ...) 改为 HTTP fetch 调用爬虫容器

### 长期优化

- **ALPINE-01**: findclass-ssr 切 Alpine（依赖 Python 完全移除 + native 模块验证）
- **CACHE-01**: Docker BuildKit 缓存挂载（--mount=type=cache）加速构建

## Out of Scope

| Feature | Reason |
|---------|--------|
| 消除 noda-site 容器（nginx 直接挂载 volume） | 蓝绿部署端口 3000 被 6 个文件引用，变更风险高 |
| findclass-ssr 强制切 Alpine | Python wheel 不兼容（lxml/orjson/greenlet 无 musllinux），需先移除 Python |
| 修改蓝绿部署镜像命名约定 | image-cleanup.sh、blue-green-deploy.sh、manage-containers.sh 共同依赖 |
| 引入 Docker registry | 当前使用本地镜像管理，满足单服务器需求 |
| 多架构构建（arm64/amd64） | 当前仅在 amd64 服务器运行 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| SITE-01 | Phase 47 | Complete |
| SITE-02 | Phase 47 | Complete |
| SITE-03 | Phase 47 | Complete |
| HYGIENE-01 | Phase 48 | Complete |
| HYGIENE-02 | Phase 48 | Complete |
| HYGIENE-03 | Phase 48 | Complete |
| SSR-01 | Phase 49 | Complete |
| SSR-02 | Phase 49 | Complete |
| SSR-03 | Phase 50 | Pending |
| SSR-04 | Phase 50 | Pending |
| SSR-DEEP-01 | Phase 51 | Pending |
| SSR-DEEP-02 | Phase 51 | Pending |
| SSR-DEEP-03 | Phase 51 | Pending |
| INFRA-01 | Phase 52 | Pending |
| INFRA-02 | Phase 52 | Pending |

**Coverage:**
- v1.10 requirements: 15 total
- Mapped to phases: 15
- Unmapped: 0

---
*Requirements defined: 2026-04-20*
*Last updated: 2026-04-20 — traceability updated after roadmap creation*
