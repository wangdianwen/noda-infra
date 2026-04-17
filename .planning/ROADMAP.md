# Roadmap: Noda 基础设施

## Milestones

- **v1.0 完整备份系统** -- Phases 1-9 (shipped 2026-04-06) -- [详情](milestones/v1.0-ROADMAP.md)
- **v1.1 基础设施现代化** -- 29 commits (shipped 2026-04-11) -- [详情](milestones/v1.1-MILESTONE.md)
- **v1.2 基础设施修复与整合** -- Phases 10-14 (shipped 2026-04-11) -- [详情](milestones/v1.2-ROADMAP.md)
- **v1.3 安全收敛与分组整理** -- Phases 15-18 (shipped 2026-04-12) -- [详情](milestones/v1.3-ROADMAP.md)
- **v1.4 CI/CD 零停机部署** -- Phases 19-25 (shipped 2026-04-16) -- [详情](milestones/v1.4-ROADMAP.md)
- **v1.5 开发环境本地化 + 基础设施 CI/CD** -- Phases 26-30 (in progress)

## Phases

**Phase Numbering:**
- Integer phases (1-30): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

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

### v1.4 CI/CD 零停机部署 (Shipped 2026-04-16)

**Milestone Goal:** Jenkins + 蓝绿部署实现编译失败不 down 站，自动回滚保护

- [x] **Phase 19: Jenkins 安装与基础配置** -- 宿主机原生安装 Jenkins LTS，可操作 Docker daemon (completed 2026-04-14)
- [x] **Phase 20: Nginx 蓝绿路由基础** -- 将 upstream 定义抽离为独立 include 文件，支持动态切换 (completed 2026-04-15)
- [x] **Phase 21: 蓝绿容器管理** -- docker run 独立管理蓝绿容器，状态文件追踪活跃环境 (completed 2026-04-15)
- [x] **Phase 22: 蓝绿部署核心流程** -- 完整的蓝绿部署脚本（容器启停 + 健康检查 + nginx 切换 + 回滚） (completed 2026-04-15)
- [x] **Phase 23: Pipeline 集成与测试门禁** -- Jenkinsfile 九阶段 Pipeline + lint/test 质量门禁 (completed 2026-04-15)
- [x] **Phase 24: Pipeline 增强特性** -- 部署前备份检查 + CDN 缓存清除 + 镜像清理 (completed 2026-04-15)
- [x] **Phase 25: 清理与迁移** -- 旧脚本保留为手动回退 + 文档更新 + 里程碑归档 (completed 2026-04-16)

</details>

### v1.5 开发环境本地化 + 基础设施 CI/CD (In Progress)

**Milestone Goal:** 本地 PostgreSQL 替代 Docker 开发数据库，Docker Compose 精简为纯线上业务；同时为基础设施服务创建统一 Jenkins Pipeline

- [x] **Phase 26: 宿主机 PostgreSQL 安装与配置** -- Homebrew 安装 PostgreSQL 17.9 + 开发数据库初始化 (completed 2026-04-16)
- [x] **Phase 27: 开发容器清理与 Docker Compose 简化** -- 移除 dev 容器，精简 compose overlay (completed 2026-04-16)
- [x] **Phase 28: Keycloak 蓝绿部署基础设施** -- Keycloak 蓝绿容器管理 + upstream 切换 (completed 2026-04-17)
- [x] **Phase 29: 统一基础设施 Jenkins Pipeline** -- Jenkinsfile.infra 参数化部署基础设施服务 (completed 2026-04-17)
- [ ] **Phase 30: 一键开发环境脚本** -- setup-dev.sh 幂等安装开发环境

## Phase Details

### Phase 26: 宿主机 PostgreSQL 安装与配置
**Goal**: 开发者可以在宿主机上运行与生产版本完全一致的 PostgreSQL 17.9，本地开发和数据导出不再依赖 Docker 容器
**Depends on**: Phase 25（前一里程碑已完成）
**Requirements**: LOCALPG-01, LOCALPG-02, LOCALPG-03, LOCALPG-04
**Success Criteria** (what must be TRUE):
  1. 开发者运行 `brew services list` 可见 postgresql@17 状态为 started，版本为 17.9
  2. 开发者可通过 `psql -d noda_dev` 和 `psql -d keycloak_dev` 连接到本地开发数据库
  3. 重启电脑后 PostgreSQL 自动启动，无需手动干预
  4. postgres_dev_data Docker volume 中的数据已成功导出并导入到本地 PostgreSQL
**Plans:** 1/2 plans complete

Plans:
- [x] 26-01-PLAN.md -- 创建 setup-postgres-local.sh 脚本（install/init-db/status/uninstall 子命令）
- [ ] 26-02-PLAN.md -- 添加 migrate-data 子命令（从 Docker volume 迁移数据到本地 PG）

### Phase 27: 开发容器清理与 Docker Compose 简化
**Goal**: docker-compose.dev.yml 不再包含数据库和认证服务，Docker Compose overlay 仅保留生产部署必需配置
**Depends on**: Phase 26（本地 PostgreSQL 就绪，可替代 dev 容器）
**Requirements**: CLEANUP-01, CLEANUP-02, CLEANUP-03, CLEANUP-04, CLEANUP-05
**Success Criteria** (what must be TRUE):
  1. `docker compose -f docker-compose.yml -f docker-compose.dev.yml config` 输出中不包含 postgres-dev 和 keycloak-dev 服务
  2. deploy-infrastructure-prod.sh 的 EXPECTED_CONTAINERS 和 START_SERVICES 列表不再包含 dev 服务
  3. docker-compose.dev-standalone.yml 已移除或合并，不存在孤立的 compose 文件
  4. 现有生产服务（postgres-prod、keycloak、nginx、noda-ops）部署不受影响
**Plans:** 3/3 plans complete

Plans:
- [x] 27-01-PLAN.md -- 清理 Docker Compose 配置文件（移除 dev 服务定义 + 删除 dev-standalone.yml）
- [x] 27-02-PLAN.md -- 更新部署脚本和本地 PG 脚本（移除 dev 引用 + 兼容性处理）
- [x] 27-03-PLAN.md -- 同步更新文档（移除 dev 容器过时引用）

### Phase 28: Keycloak 蓝绿部署基础设施
**Goal**: Keycloak 服务支持蓝绿零停机部署，管理员可通过 nginx upstream 切换在 blue/green 容器间平滑切换流量
**Depends on**: Phase 25（v1.4 蓝绿框架已验证，独立于 Phase 26/27）
**Requirements**: KCBLUE-01, KCBLUE-02, KCBLUE-03, KCBLUE-04
**Success Criteria** (what must be TRUE):
  1. keycloak-blue 和 keycloak-green 两个容器可独立创建和启动，共享 keycloak_db 数据库
  2. nginx 配置中 Keycloak upstream 通过 `include snippets/upstream-keycloak.conf` 引用，修改后 `nginx -s reload` 切换流量
  3. `/opt/noda/active-env-keycloak` 状态文件准确反映当前活跃的 Keycloak 环境（blue 或 green）
  4. manage-containers.sh 支持 Keycloak 蓝绿容器的 create/start/stop/switch 操作
  5. auth.noda.co.nz 在蓝绿切换期间保持可访问（零停机）
**Plans:** 3/3 plans complete

Plans:
- [x] 28-01-PLAN.md -- 创建 env-keycloak.env 模板 + upstream 蓝绿配置 + manage-containers.sh Keycloak 适配
- [x] 28-02-PLAN.md -- 创建 keycloak-blue-green-deploy.sh 部署脚本 + 更新 deploy-infrastructure-prod.sh
- [x] 28-03-PLAN.md -- 创建 Jenkinsfile.keycloak + 扩展 pipeline-stages.sh

### Phase 29: 统一基础设施 Jenkins Pipeline
**Goal**: 管理员可在 Jenkins 中选择目标基础设施服务（keycloak/nginx/noda-ops/postgres），Pipeline 自动执行备份、部署、健康检查和回滚
**Depends on**: Phase 28（Keycloak 蓝绿框架就绪）
**Requirements**: PIPELINE-01, PIPELINE-02, PIPELINE-03, PIPELINE-04, PIPELINE-05, PIPELINE-06, PIPELINE-07
**Success Criteria** (what must be TRUE):
  1. Jenkins 中存在 `infra-deploy` Pipeline 任务，可通过下拉菜单选择 keycloak/nginx/noda-ops/postgres 服务
  2. Pipeline 部署 keycloak 前自动执行 pg_dump 全量备份，备份失败则中止部署
  3. 每个服务使用匹配的部署策略：keycloak=蓝绿零停机、nginx=重建替换、noda-ops=重建替换、postgres=重启
  4. 部署后自动执行服务专属健康检查（keycloak: HTTP /health/ready、nginx: HTTP 200、noda-ops: 容器 running、postgres: pg_isready）
  5. 健康检查失败时自动回滚到部署前状态（Keycloak 切回旧容器、nginx/noda-ops 恢复旧镜像）
  6. 重启 PostgreSQL 等高风险操作前 Pipeline 暂停等待人工确认（30 分钟超时）
**Plans:** 3/3 plans complete

Plans:
- [x] 29-01-PLAN.md -- pipeline-stages.sh 基础设施函数（部署/备份/健康检查/回滚）
- [x] 29-02-PLAN.md -- Jenkinsfile.infra 统一 Pipeline（choice 参数 + 7 阶段 + input 门禁）
- [x] 29-03-PLAN.md -- deploy-infrastructure-prod.sh 精简（移除 nginx/noda-ops 逻辑）

### Phase 30: 一键开发环境脚本
**Goal**: 新开发者运行一个命令即可搭建完整的本地开发环境（PostgreSQL + 数据库初始化 + 配置）
**Depends on**: Phase 26（宿主机 PG 安装流程已验证）, Phase 27（dev 容器已清理）
**Requirements**: DEVEX-01, DEVEX-02, DEVEX-03
**Success Criteria** (what must be TRUE):
  1. 开发者运行 `bash setup-dev.sh` 后自动完成 Homebrew PostgreSQL 安装、数据库创建、用户配置
  2. 脚本重复运行不会破坏已有数据或覆盖已有配置（幂等性）
  3. 脚本在 Apple Silicon (/opt/homebrew) 和 Intel (/usr/local) Mac 上均可正常工作
**Plans:** 1 plan

Plans:
- [ ] 30-01-PLAN.md -- 创建 setup-dev.sh 一键脚本 + 更新 DEVELOPMENT.md 文档

## Progress

**Execution Order:**
Phases execute in numeric order: 26 -> 27 -> 28 -> 29 -> 30
（Phase 28 可与 Phase 26/27 并行执行）

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 26. 宿主机 PostgreSQL 安装与配置 | v1.5 | 1/2 | Complete    | 2026-04-16 |
| 27. 开发容器清理与 Docker Compose 简化 | v1.5 | 3/3 | Complete    | 2026-04-16 |
| 28. Keycloak 蓝绿部署基础设施 | v1.5 | 3/3 | Complete    | 2026-04-17 |
| 29. 统一基础设施 Jenkins Pipeline | v1.5 | 3/3 | Complete    | 2026-04-17 |
| 30. 一键开发环境脚本 | v1.5 | 0/1 | Not started | - |
