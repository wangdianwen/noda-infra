# Roadmap: Noda 基础设施

## Milestones

- **v1.0 完整备份系统** -- Phases 1-9 (shipped 2026-04-06) -- [详情](milestones/v1.0-ROADMAP.md)
- **v1.1 基础设施现代化** -- 29 commits (shipped 2026-04-11) -- [详情](milestones/v1.1-MILESTONE.md)
- **v1.2 基础设施修复与整合** -- Phases 10-14 (shipped 2026-04-11) -- [详情](milestones/v1.2-ROADMAP.md)
- **v1.3 安全收敛与分组整理** -- Phases 15-18 (shipped 2026-04-12) -- [详情](milestones/v1.3-ROADMAP.md)
- **v1.4 CI/CD 零停机部署** -- Phases 19-25 (shipped 2026-04-16) -- [详情](milestones/v1.4-ROADMAP.md)
- **v1.5 开发环境本地化 + 基础设施 CI/CD** -- Phases 26-30 (shipped 2026-04-17) -- [详情](milestones/v1.5-ROADMAP.md)
- **v1.6 Jenkins Pipeline 强制执行** -- Phases 31-34 (shipped 2026-04-18)
- **v1.7 代码精简与规整** -- Phases 35-38 (shipped 2026-04-19) -- [详情](milestones/v1.7-ROADMAP.md)
- **v1.8 密钥管理集中化** -- Phases 39-42 (shipped 2026-04-19)
- **v1.9 部署后磁盘清理自动化** -- Phases 43-46 (shipped 2026-04-20) -- [详情](milestones/v1.9-MILESTONE.md)
- **v1.10 Docker 镜像瘦身优化** -- Phases 47-52 (in progress)

## Phases

<details>
<summary>v1.0 完整备份系统 + v1.1 基础设施现代化 (Phases 1-9) -- SHIPPED 2026-04-11</summary>

v1.0 (shipped 2026-04-06): 9 phases, 16 plans, 23 tasks
- 完整的本地备份流程（健康检查 -> 备份 -> 验证 -> 清理）
- B2 云存储集成（自动上传、重试、校验、清理）
- 一键恢复脚本（列出、下载、恢复、验证）
- 每周自动验证测试（4 层验证机制）
- 监控与告警系统（结构化日志、邮件告警、指标追踪）

v1.1 (shipped 2026-04-11): 29 commits, 134 files changed
- findclass-ssr 三合一服务（SSR + API + 静态文件）
- Keycloak Google 登录 5 层修复
- PostgreSQL prod/dev 双实例
- noda-ops 容器合并
- 全量文档更新与历史遗留清理

</details>

<details>
<summary>v1.2 基础设施修复与整合 (Phases 10-14) -- SHIPPED 2026-04-11</summary>

- [x] Phase 10: B2 备份修复 (3/3 plans) -- completed 2026-04-11
- [x] Phase 11: 服务整合 (2/2 plans) -- completed 2026-04-11
- [x] Phase 12: Keycloak 双环境 (1/1 plans) -- completed 2026-04-11
- [x] Phase 13: Keycloak 自定义主题 (1/1 plans) -- completed 2026-04-11
- [x] Phase 14: 容器保护与部署安全 (3/3 plans) -- completed 2026-04-11

</details>

<details>
<summary>v1.3 安全收敛与分组整理 (Phases 15-18) -- SHIPPED 2026-04-12</summary>

- [x] **Phase 15: PostgreSQL 客户端升级** -- completed 2026-04-12
- [x] **Phase 16: Keycloak 端口收敛** -- completed 2026-04-11
- [x] **Phase 17: 端口安全加固** -- completed 2026-04-11
- [x] **Phase 18: 容器标签分组** -- completed 2026-04-11

</details>

<details>
<summary>v1.4 CI/CD 零停机部署 (Phases 19-25) -- SHIPPED 2026-04-16</summary>

- [x] **Phase 19: Jenkins 安装与基础配置** (completed 2026-04-14)
- [x] **Phase 20: Nginx 蓝绿路由基础** (completed 2026-04-15)
- [x] **Phase 21: 蓝绿容器管理** (completed 2026-04-15)
- [x] **Phase 22: 蓝绿部署核心流程** (completed 2026-04-15)
- [x] **Phase 23: Pipeline 集成与测试门禁** (completed 2026-04-15)
- [x] **Phase 24: Pipeline 增强特性** (completed 2026-04-15)
- [x] **Phase 25: 清理与迁移** (completed 2026-04-16)

</details>

<details>
<summary>v1.5 开发环境本地化 + 基础设施 CI/CD (Phases 26-30) -- SHIPPED 2026-04-17</summary>

- [x] **Phase 26: 宿主机 PostgreSQL 安装与配置** (completed 2026-04-16)
- [x] **Phase 27: 开发容器清理与 Docker Compose 简化** (completed 2026-04-16)
- [x] **Phase 28: Keycloak 蓝绿部署基础设施** (completed 2026-04-17)
- [x] **Phase 29: 统一基础设施 Jenkins Pipeline** (completed 2026-04-17)
- [x] **Phase 30: 一键开发环境脚本** (completed 2026-04-17)

</details>

<details>
<summary>v1.6 Jenkins Pipeline 强制执行 (Phases 31-34) -- SHIPPED 2026-04-18</summary>

- [x] **Phase 31: Docker Socket 权限收敛 + 文件权限锁定** (completed 2026-04-18)
- [x] **Phase 32: sudoers 白名单 + Break-Glass 紧急机制** (completed 2026-04-18)
- [x] **Phase 33: 审计日志系统** (completed 2026-04-18)
- [x] **Phase 34: Jenkins 权限矩阵 + 统一管理脚本** (completed 2026-04-18)

</details>

<details>
<summary>v1.7 代码精简与规整 (Phases 35-38) -- SHIPPED 2026-04-19</summary>

- [x] **Phase 35: 共享库建设** (3/3 plans) -- completed 2026-04-18
- [x] **Phase 36: 蓝绿部署统一** (2/2 plans) -- completed 2026-04-19
- [x] **Phase 37: 清理与重命名** (2/2 plans) -- completed 2026-04-19
- [x] **Phase 38: 质量保证** (2/2 plans) -- completed 2026-04-19

</details>

<details>
<summary>v1.8 密钥管理集中化 (Phases 39-42) -- SHIPPED 2026-04-19</summary>

- [x] **Phase 39: Doppler 基础设施搭建** (3/3 plans) -- completed 2026-04-19
- [x] **Phase 40: Jenkins Pipeline 集成** (3/3 plans) -- completed 2026-04-19
- [x] **Phase 41: 迁移与清理** (3/3 plans) -- completed 2026-04-19
- [x] **Phase 42: 备份与安全** (2/2 plans) -- completed 2026-04-19

</details>

<details>
<summary>v1.9 部署后磁盘清理自动化 (Phases 43-46) -- SHIPPED 2026-04-20</summary>

**Milestone Goal:** 每次 Pipeline 部署成功后，自动清理所有构建残留和缓存，保持系统磁盘占用最小

- [x] **Phase 43: 清理共享库 + Pipeline 集成** (3/3 plans) -- completed 2026-04-20
- [x] **Phase 44: Jenkins 维护清理 + 定期任务** (3/3 plans) -- completed 2026-04-20
- [x] **Phase 45: Infra Pipeline 镜像清理补全** (2/2 plans) -- completed 2026-04-20
- [x] **Phase 46: nginx 蓝绿部署支持** (1/1 plans) -- completed 2026-04-20

</details>

### v1.10 Docker 镜像瘦身优化 (In Progress)

**Milestone Goal:** 全面优化所有自建 Docker 镜像体积，减少构建时间、磁盘占用和部署带宽

- [ ] **Phase 47: noda-site 镜像优化** - 从 node:20-alpine 切换到 nginx:1.25-alpine，适配蓝绿部署
- [ ] **Phase 48: 全局 Docker 卫生实践** - .dockerignore、COPY --chown、基础镜像版本统一
- [ ] **Phase 49: findclass-ssr 爬虫审计与决策** - 审计 Python 调用链路，制定分离方案
- [ ] **Phase 50: findclass-ssr 瘦身执行** - 移除 Python/Chromium 死重，端到端验证
- [ ] **Phase 51: findclass-ssr 深度优化** - Alpine 切换、devDeps 清理、层缓存优化
- [ ] **Phase 52: 基础设施镜像清理** - noda-ops 依赖审计、backup Dockerfile 清理

## Phase Details

### Phase 47: noda-site 镜像优化
**Goal**: noda-site 运行时从 Node.js 切换到 nginx，镜像体积从 ~218MB 降至 ~25MB，蓝绿部署不受影响
**Depends on**: 无（独立阶段）
**Requirements**: SITE-01, SITE-02, SITE-03
**Success Criteria** (what must be TRUE):
  1. noda-site Dockerfile 使用 nginx:1.25-alpine 基础镜像，多阶段构建保留 Puppeteer prerender 阶段
  2. noda-site 容器在端口 3000 提供静态文件服务，蓝绿部署全流程（构建 -> 健康检查 -> 切换 -> 验证）正常工作
  3. Jenkins Pipeline noda-site 部署流程适配新 Dockerfile（构建参数、健康检查端点）并成功部署
  4. docker images 显示 noda-site 镜像体积 < 30MB
**Plans**: 2 plans
Plans:
- [ ] 47-01-PLAN.md -- Dockerfile 重写 + nginx 配置文件（SITE-01, SITE-02）
- [ ] 47-02-PLAN.md -- Pipeline 适配 + docker-compose 配置更新（SITE-03）

### Phase 48: 全局 Docker 卫生实践
**Goal**: 所有自建 Dockerfile 遵循 Docker 最佳实践，减少镜像层数、加速构建、统一基础镜像版本
**Depends on**: 无（独立阶段）
**Requirements**: HYGIENE-01, HYGIENE-02, HYGIENE-03
**Success Criteria** (what must be TRUE):
  1. 所有自建 Dockerfile 的同级目录存在 .dockerignore，排除 .git、.planning、node_modules、worktrees
  2. 所有 COPY 指令使用 --chown 标志替代单独的 RUN chown，镜像层数不增加
  3. test-verify 基础镜像从 postgres:15-alpine 更新为 postgres:17-alpine，与 backup 容器共享层缓存
**Plans**: TBD

### Phase 49: findclass-ssr 爬虫审计与决策
**Goal**: 完整审计 findclass-ssr 中所有 Python 脚本的调用链路，制定 Python/Chromium 移除或分离的最终方案
**Depends on**: 无（独立阶段，但必须在 Phase 50 之前完成）
**Requirements**: SSR-01, SSR-02
**Success Criteria** (what must be TRUE):
  1. 所有 Python 脚本（crawl-skykiwi.py、llm_extract.py、db_import.py 等）的调用链路完整记录，确认哪些有 API 端点直接调用
  2. 产出明确的决策文档：Python/Chromium 是直接移除还是分离为独立容器，附理由和影响范围
  3. crawl-scheduler.ts 的 spawn('python3', ...) 调用处理方案确定（移除或改为 HTTP fetch）
**Plans**: TBD

### Phase 50: findclass-ssr 瘦身执行
**Goal**: 执行 Phase 49 制定的方案，移除 findclass-ssr 中 ~3GB 的 Python/Chromium 死重
**Depends on**: Phase 49
**Requirements**: SSR-03, SSR-04
**Success Criteria** (what must be TRUE):
  1. findclass-ssr 镜像不再包含 Python 运行时、Chromium 浏览器、patchright 浏览器，镜像体积减少 > 50%
  2. API 健康检查端点（/api/health）返回正常
  3. SSR 页面渲染功能正常（首页、课程页面等）
  4. 静态文件服务正常（CSS/JS/图片加载无 404）
  5. 如爬虫功能保留，crawl 相关 API 端点正常工作
**Plans**: TBD

### Phase 51: findclass-ssr 深度优化
**Goal**: 在 Python 分离完成后，进一步优化 findclass-ssr 镜像（Alpine 切换 + devDeps 清理 + 层缓存优化）
**Depends on**: Phase 50
**Requirements**: SSR-DEEP-01, SSR-DEEP-02, SSR-DEEP-03
**Success Criteria** (what must be TRUE):
  1. findclass-ssr 基础镜像从 node:22-slim 切换到 node:22-alpine，native 模块兼容性验证通过
  2. 运行时镜像不包含 devDependencies（pnpm prune --prod 或等效方案执行）
  3. Dockerfile COPY 层顺序优化：低频变更的依赖声明在前，高频变更的源码在后
  4. findclass-ssr 端到端功能验证通过（API + SSR + 静态文件）
**Plans**: TBD

### Phase 52: 基础设施镜像清理
**Goal**: noda-ops 和 backup Dockerfile 遵循精简最佳实践，构建工具不泄漏到运行时
**Depends on**: 无（独立阶段）
**Requirements**: INFRA-01, INFRA-02
**Success Criteria** (what must be TRUE):
  1. noda-ops 中 wget/gnupg/coreutils 等非必需运行时依赖移到构建阶段或确认必需性
  2. backup Dockerfile 冗余层合并、RUN 指令统一、.dockerignore 添加
  3. 两个镜像的现有功能（备份、B2 上传、健康检查）不受影响
**Plans**: TBD

## Progress

**Execution Order:**
Phase 47/48/52 可并行执行，Phase 49 先于 Phase 50，Phase 51 依赖 Phase 50。
建议执行顺序: 47 -> 48 -> 52 -> 49 -> 50 -> 51

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 47. noda-site 镜像优化 | v1.10 | 0/2 | Planned | - |
| 48. 全局 Docker 卫生实践 | v1.10 | 0/? | Not started | - |
| 49. findclass-ssr 爬虫审计与决策 | v1.10 | 0/? | Not started | - |
| 50. findclass-ssr 瘦身执行 | v1.10 | 0/? | Not started | - |
| 51. findclass-ssr 深度优化 | v1.10 | 0/? | Not started | - |
| 52. 基础设施镜像清理 | v1.10 | 0/? | Not started | - |
