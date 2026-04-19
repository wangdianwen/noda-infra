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
- **v1.9 部署后磁盘清理自动化** -- Phases 43-44 (in progress)

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

**Milestone Goal:** 在不影响现有功能的前提下，消除重复代码、合并冗余脚本、统一代码风格

- [x] **Phase 35: 共享库建设** (3/3 plans) -- completed 2026-04-18
- [x] **Phase 36: 蓝绿部署统一** (2/2 plans) -- completed 2026-04-19
- [x] **Phase 37: 清理与重命名** (2/2 plans) -- completed 2026-04-19
- [x] **Phase 38: 质量保证** (2/2 plans) -- completed 2026-04-19

</details>

<details>
<summary>v1.8 密钥管理集中化 (Phases 39-42) -- SHIPPED 2026-04-19</summary>

**Milestone Goal:** 将分散在多个 .env 文件中的敏感环境变量迁移到 Doppler 集中管理

- [x] **Phase 39: Doppler 基础设施搭建** (3/3 plans) -- completed 2026-04-19
- [x] **Phase 40: Jenkins Pipeline 集成** (3/3 plans) -- completed 2026-04-19
- [x] **Phase 41: 迁移与清理** (3/3 plans) -- completed 2026-04-19
- [x] **Phase 42: 备份与安全** (2/2 plans) -- completed 2026-04-19

</details>

### v1.9 部署后磁盘清理自动化 (In Progress)

**Milestone Goal:** 每次 Pipeline 部署成功后，自动清理所有构建残留和缓存，保持系统磁盘占用最小

- [ ] **Phase 43: 清理共享库 + Pipeline 集成** - 新建 cleanup.sh 共享库，增强 pipeline_cleanup/pipeline_infra_cleanup，部署后自动清理 Docker/Node.js/文件残留
- [ ] **Phase 44: Jenkins 维护清理 + 定期任务** - Jenkins 旧构建清理 + pnpm/npm 定期清理 cron
- [ ] **Phase 45: Infra Pipeline 镜像清理补全** - 补全 noda-ops/nginx 旧镜像清理逻辑，确保所有服务部署后无残留镜像

## Phase Details

### Phase 43: 清理共享库 + Pipeline 集成
**Goal**: Pipeline 每次部署成功后自动清理 Docker build cache、已停止容器、匿名卷、node_modules 和旧备份文件，并通过磁盘快照记录清理效果
**Depends on**: Phase 42 (v1.8 完成，Pipeline 和共享库体系已建立)
**Requirements**: DOCK-01, DOCK-02, DOCK-03, DOCK-04, CACHE-01, FILE-01, FILE-02
**Success Criteria** (what must be TRUE):
  1. Pipeline 部署成功后，超过 24 小时的 Docker build cache 被自动清理，日志记录清理前后磁盘占用
  2. Pipeline 部署成功后，已停止的容器和匿名卷被自动清理（命名卷如 postgres_data 不受影响）
  3. Pipeline 部署成功后，Jenkins workspace 中的 noda-apps/node_modules 被自动删除
  4. Pipeline 部署前后分别输出 `df -h` 和 `docker system df` 磁盘快照到日志，可对比清理效果
  5. infra-pipeline 目录下超过 30 天的旧备份文件被自动清理，deploy-failure-*.log 临时文件在部署成功后被删除
**Plans**: 3 plans

Plans:
- [ ] 43-01-PLAN.md -- 新建 scripts/lib/cleanup.sh 共享库（9 个清理函数 + 2 个 wrapper + 磁盘快照）
- [ ] 43-02-PLAN.md -- 增强 pipeline-stages.sh（source cleanup.sh + 4 处函数增强）
- [ ] 43-03-PLAN.md -- 手动触发 Pipeline 端到端验证

### Phase 44: Jenkins 维护清理 + 定期任务
**Goal**: 低频维护类清理自动化 -- Jenkins 旧构建记录定期清理、pnpm store 和 npm cache 定期 prune
**Depends on**: Phase 43 (cleanup.sh 共享库已建立，清理函数可直接复用)
**Requirements**: JENK-01, JENK-02, CACHE-02, CACHE-03
**Success Criteria** (what must be TRUE):
  1. Jenkins 保留最近 N 次构建记录，更早的 artifacts 和构建目录被自动删除
  2. Jenkins workspace 中已完成构建的工作目录被自动清理，释放磁盘空间
  3. pnpm store 每 7 天自动 prune 一次，可通过环境参数强制触发
  4. npm cache 每 7 天自动清理一次，与 pnpm store prune 同频率执行
**Plans**: TBD

Plans:
- [ ] 44-01: Jenkins 旧构建清理函数（cleanup.sh 扩展 + Pipeline 集成）
- [ ] 44-02: pnpm/npm 定期清理 cron 任务（crontab 配置 + 强制触发参数）

### Phase 45: Infra Pipeline 镜像清理补全
**Goal**: 补全 infra Pipeline 中 noda-ops 和 nginx 的旧镜像清理逻辑，确保所有服务部署后无残留镜像堆积
**Depends on**: Phase 43 (cleanup.sh 和 image-cleanup.sh 已建立，cleanup_by_date_threshold 已修复)
**Requirements**: IMG-01, IMG-02
**Success Criteria** (what must be TRUE):
  1. noda-ops 部署后旧镜像自动清理，只保留当前在用镜像 + latest
  2. nginx 部署后旧镜像自动清理（dangling images）
  3. 手动触发 infra Pipeline 验证清理日志包含镜像清理输出
  4. postgres_data 卷安全不受影响
**Plans**: 2 plans

Plans:
- [ ] 45-01-PLAN.md -- pipeline_infra_cleanup 增加 noda-ops/nginx 镜像清理调用
- [ ] 45-02-PLAN.md -- 手动触发 infra Pipeline 端到端验证

## Progress

**Execution Order:**
Phases execute in numeric order: 43 -> 44 -> 45

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 43. 清理共享库 + Pipeline 集成 | 0/3 | Planned | - |
| 44. Jenkins 维护清理 + 定期任务 | 0/2 | Not started | - |
| 45. Infra Pipeline 镜像清理补全 | 0/2 | Not started | - |
