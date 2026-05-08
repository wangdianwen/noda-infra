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
- **v1.10 Docker 镜像瘦身优化** -- Phases 47-52 (shipped 2026-04-21) -- [详情](milestones/v1.10-ROADMAP.md)

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

### v1.11 Pre-Prod 验证环境 + 安全上线流程 (In Progress)

**Milestone Goal:** 在 prod 之前增加 pre-prod 验证环境作为上线守门员，所有代码必须先在 pre-prod 验证通过后才能 promote 到 prod。

- [x] **Phase 53: 数据库 + Keycloak + Doppler 密钥隔离** - 创建 noda_preprod 数据库、noda-preprod realm、Doppler pre config
- [x] **Phase 54: Nginx 路由 + Cloudflare DNS** - 配置 pre-prod 域名路由和 upstream
- [ ] **Phase 55: 蓝绿部署脚本参数化 + 容器规范** - manage-containers.sh 支持 preprod + Docker 网络隔离
- [ ] **Phase 56: Jenkins Pipeline + 安全防护** - 双 Pipeline + upstream 写入防护 + 并发锁

<details>
<summary>v1.10 Docker 镜像瘦身优化 (Phases 47-52) -- SHIPPED 2026-04-21</summary>

**Milestone Goal:** 全面优化所有自建 Docker 镜像体积，减少构建时间、磁盘占用和部署带宽

- [x] **Phase 47: noda-site 镜像优化** - nginx:1.25-alpine 替代 Node.js，~218MB -> ~25MB (completed 2026-04-20)
- [x] **Phase 48: 全局 Docker 卫生实践** - .dockerignore + COPY --chown + 基础镜像统一 (completed 2026-04-20)
- [x] **Phase 49: findclass-ssr 爬虫审计与决策** - Python 调用链路审计完成 (completed 2026-04-20)
- [x] **Phase 50: findclass-ssr 瘦身执行** - 跳过：爬虫是核心功能 (skipped 2026-04-21)
- [x] **Phase 51: findclass-ssr 深度优化** - 跳过：依赖 Phase 50 (skipped 2026-04-21)
- [x] **Phase 52: 基础设施镜像清理** - noda-ops 多阶段构建 + backup 层合并 (completed 2026-04-21)

</details>

## Phase Details

### Phase 53: 数据库 + Keycloak + Doppler 密钥隔离
**Goal**: Pre-prod 拥有独立的数据库、认证 realm 和密钥配置，与 prod 完全隔离
**Depends on**: Phase 52 (v1.10 完成)
**Requirements**: INFRA-01, INFRA-02, INFRA-03, SEC-01
**Success Criteria** (what must be TRUE):
  1. noda_preprod 数据库存在且可通过独立用户连接（SELECT 查询返回成功）
  2. Keycloak noda-preprod realm 可登录，Google OAuth redirect URIs 包含 pre.class.noda.co.nz 和 pre.auth.noda.co.nz
  3. Doppler pre config 包含指向 noda_preprod 的 DATABASE_URL 和指向 noda-preprod 的 KEYCLOAK_REALM
  4. Doppler pre config 的 service token 可独立拉取密钥，不依赖 prd config
**Plans**: 3 plans

Plans:
**Wave 1**
- [x] 53-01-PLAN.md — 创建 noda_preprod 数据库和独立用户（INFRA-01）
- [x] 53-02-PLAN.md — 创建 Keycloak noda-preprod realm + client + Google OAuth（INFRA-02, INFRA-03）

**Wave 2** *(blocked on Wave 1 completion)*
- [x] 53-03-PLAN.md — Doppler pre config + secrets.sh 参数化 + pre-prod env 模板 + 隔离验证（SEC-01）

### Phase 54: Nginx 路由 + Cloudflare DNS
**Goal**: Pre-prod 域名可从外部访问，Nginx 正确路由到 pre-prod upstream（无后端时返回 502 即为正确）
**Depends on**: Phase 53
**Requirements**: INFRA-04, INFRA-05, INFRA-06
**Success Criteria** (what must be TRUE):
  1. curl https://pre.class.noda.co.nz 返回 502 Bad Gateway（路由正确但无 pre-prod 后端运行）
  2. curl https://pre.auth.noda.co.nz 返回 Keycloak 登录页（共享 Keycloak 实例，realm 正确路由）
  3. curl https://pre.noda.co.nz 和 https://pre.admin.noda.co.nz 可达（返回预期状态码）
  4. Nginx pre-prod upstream 变量名包含 preprod 前缀，不与 prod upstream 变量冲突
**Plans**: 2 plans

**Wave 1**
- [x] 54-01-PLAN.md — 创建 Nginx pre-prod upstream 配置和 server blocks（INFRA-04, INFRA-05）

**Wave 2** *(blocked on Wave 1 completion)*
- [x] 54-02-PLAN.md — 配置 Cloudflare DNS + Tunnel 路由（INFRA-06）

### Phase 55: 蓝绿部署脚本参数化 + 容器规范
**Goal**: manage-containers.sh 支持 pre-prod 蓝绿部署，容器命名和状态文件与 prod 完全隔离
**Depends on**: Phase 54
**Requirements**: BLUE-01, BLUE-02, BLUE-03, BLUE-04, BLUE-05, BLUE-06, BLUE-07, SEC-03
**Success Criteria** (what must be TRUE):
  1. `manage-containers.sh start noda-apps-preprod blue` 可启动 pre-prod 蓝容器，容器名为 noda-apps-preprod-blue
  2. `manage-containers.sh switch noda-apps-preprod` 可执行 pre-prod 蓝绿切换，仅修改 pre-prod upstream 文件
  3. pre-prod 容器的 Docker 网络别名为 noda-apps-preprod，不与 prod 的 noda-apps 别名冲突
  4. pre-prod 容器环境变量指向 noda_preprod 数据库和 noda-preprod realm（连接 prod 数据库即失败）
  5. image-cleanup.sh 可正确识别和清理 pre-prod 容器的旧镜像
**Plans**: TBD

Plans:
- [ ] 55-01: manage-containers.sh 参数化（UPSTREAM_VARS_PREFIX + NODA_ENVIRONMENT）
- [ ] 55-02: pre-prod 环境变量模板 + 容器命名 + 状态文件 + wrapper 脚本
- [ ] 55-03: image-cleanup.sh 适配 pre-prod + Docker 网络别名隔离

### Phase 56: Jenkins Pipeline + 安全防护
**Goal**: Jenkins 自动化 pre-prod 部署和 promote 到 prod 的完整流程，具备安全防护机制
**Depends on**: Phase 55
**Requirements**: PIPE-01, PIPE-02, PIPE-03, PIPE-04, PIPE-05, SEC-02
**Success Criteria** (what must be TRUE):
  1. 触发 noda-apps-preprod Pipeline 可完成 Build -> Test -> Deploy -> Health -> Switch -> Verify 全流程
  2. 触发 noda-apps-promote Pipeline 可将 pre-prod 验证通过的同一镜像部署到 prod（Build Once / Promote Anywhere）
  3. Hotfix 紧急通道可直接触发现有 prod Pipeline 部署，跳过 pre-prod 验证
  4. pre-prod Pipeline 执行前验证 UPSTREAM_CONF 路径包含 "preprod"，防止误写 prod upstream
  5. prod 和 pre-prod Pipeline 的 Nginx reload 操作通过 lock() 互斥，不会并发冲突
**Plans**: TBD

Plans:
- [ ] 56-01: 创建 Jenkinsfile.noda-apps-preprod（pre-prod 部署 Pipeline）
- [ ] 56-02: 创建 Jenkinsfile.noda-apps-promote（promote to prod Pipeline）
- [ ] 56-03: Nginx upstream 写入防护 + Pipeline 并发锁 + Jenkins Job 初始化脚本

## Progress

**Execution Order:**
Phases execute in numeric order: 53 -> 54 -> 55 -> 56

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 53. 数据库 + Keycloak + Doppler | v1.11 | 3/3 | Complete   | 2026-05-08 |
| 54. Nginx 路由 + Cloudflare DNS | v1.11 | 1/2 | In Progress|  |
| 55. 蓝绿部署脚本参数化 | v1.11 | 0/3 | Not started | - |
| 56. Jenkins Pipeline + 安全防护 | v1.11 | 0/3 | Not started | - |
