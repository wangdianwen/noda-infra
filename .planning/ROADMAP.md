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

### v1.8 密钥管理集中化 (Complete)

**Milestone Goal:** 将分散在多个 .env 文件中的敏感环境变量迁移到 Doppler 集中管理，与 Jenkins Pipeline 集成实现安全注入，备份到 Backblaze B2，并清理 Git 历史中的密钥泄露。

- [x] **Phase 39: Doppler 基础设施搭建** (3/3 plans) -- completed 2026-04-19
- [x] **Phase 40: Jenkins Pipeline 集成** (3/3 plans) -- completed 2026-04-19
- [x] **Phase 41: 迁移与清理** (3/3 plans) -- completed 2026-04-19
- [x] **Phase 42: 备份与安全** (2/2 plans) -- completed 2026-04-19

## Phase Details

### Phase 39: Doppler 基础设施搭建
**Goal**: Jenkins 宿主机可以通过 Doppler CLI 认证并拉取所有密钥
**Depends on**: Nothing (v1.8 第一个阶段)
**Requirements**: INFRA-01, INFRA-02, INFRA-03, INFRA-04
**Success Criteria** (what must be TRUE):
  1. Jenkins 宿主机上 `doppler --version` 返回有效版本号 >= 3.75（CLI 安装成功）
  2. `doppler secrets download --format=env --no-file --project noda --config prod` 输出包含所有 15 个预期密钥的 .env 格式内容（项目创建 + 密钥录入成功）
  3. 通过 Service Token 认证（非交互式）可以执行 `doppler secrets download`，无需手动登录
  4. Doppler 凭据（Service Token）已离线备份到密码管理器和 B2 加密快照
**Plans**: 3 plans

Plans:
- [ ] 39-01-PLAN.md -- Doppler CLI 安装脚本 + 宿主机安装验证
- [ ] 39-02-PLAN.md -- Doppler 项目创建 + 密钥导入 + Service Token + Jenkins Credentials
- [ ] 39-03-PLAN.md -- Doppler 密钥离线备份脚本（age 加密 + B2 上传）

### Phase 40: Jenkins Pipeline 集成
**Goal**: Jenkins Pipeline 启动时自动从 Doppler 拉取密钥，Docker Compose 和 docker build 都能正确获取所需环境变量
**Depends on**: Phase 39
**Requirements**: PIPE-01, PIPE-02, PIPE-03, PIPE-04
**Success Criteria** (what must be TRUE):
  1. pipeline-stages.sh 的 load_secrets() 在 DOPPLER_TOKEN 存在时从 Doppler 拉取密钥，不存在时回退 docker/.env
  2. 3 个 Jenkinsfile 的 environment 块包含 DOPPLER_TOKEN = credentials('doppler-service-token')，构建日志中 token 值被遮蔽
  3. 手动部署脚本（deploy-infrastructure-prod.sh、deploy-apps-prod.sh、blue-green-deploy.sh）都支持 Doppler 双模式
  4. VITE_* 构建参数保持 Dockerfile ARG 硬编码，不受 Doppler 影响
**Plans**: 3 plans

Plans:
- [x] 40-01-PLAN.md -- 创建 scripts/lib/secrets.sh 共享密钥加载库 + 改造 pipeline-stages.sh
- [x] 40-02-PLAN.md -- 3 个 Jenkinsfile 添加 DOPPLER_TOKEN credentials 注入
- [x] 40-03-PLAN.md -- 3 个手动部署脚本 Doppler 双模式支持

### Phase 41: 迁移与清理
**Goal**: 所有密钥已在 Doppler 验证通过后，删除明文 .env 文件和废弃的 SOPS 代码
**Depends on**: Phase 40
**Requirements**: MIGR-01, MIGR-02, MIGR-03, MIGR-04
**Success Criteria** (what must be TRUE):
  1. .env.production 和 docker/.env 中的所有密钥已录入 Doppler，且通过 `doppler secrets download` 验证完整
  2. 备份系统 scripts/backup/.env.backup 保持独立的明文文件不变，不受密钥管理迁移影响
  3. .env.production 和 docker/.env 明文文件已从文件系统删除，服务仍能通过 Doppler 正常部署
  4. scripts/utils/decrypt-secrets.sh 及所有 SOPS 相关代码和引用已清理干净
**Plans**: 3 plans

Plans:
- [x] 41-01-PLAN.md -- 密钥验证扩展 + secrets.sh Doppler-only 化 + backup 脚本公钥来源改造
- [x] 41-02-PLAN.md -- 脚本 SOPS 引用清理 + 文档更新 + .gitignore 清理
- [x] 41-03-PLAN.md -- 验证后删除明文文件和 SOPS 文件

### Phase 42: 备份与安全
**Goal**: Doppler 密钥有定期 B2 快照备份，Git 历史中的密钥泄露已清除
**Depends on**: Phase 41
**Requirements**: BACKUP-01, BACKUP-02
**Success Criteria** (what must be TRUE):
  1. cron 任务定期将 Doppler 密钥快照（`doppler secrets download` 输出）上传到 Backblaze B2
  2. Git 历史中 .env.production、.sops.yaml、config/secrets.sops.yaml 已被 git-filter-repo 清除，`git log --all -- .env.production` 不再显示内容
**Plans**: 2 plans

Plans:
- [x] 42-01-PLAN.md -- Doppler 密钥备份 cron 集成（rclone + Dockerfile + crontab + docker-compose）
- [x] 42-02-PLAN.md -- Git 历史敏感文件清理脚本（git-filter-repo 替代 BFG）

## Progress

**Execution Order:**
Phases execute in numeric order: 39 -> 40 -> 41 -> 42

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 39. Doppler 基础设施搭建 | 3/3 | Complete | 2026-04-19 |
| 40. Jenkins Pipeline 集成 | 3/3 | Complete | 2026-04-19 |
| 41. 迁移与清理 | 3/3 | Complete | 2026-04-19 |
| 42. 备份与安全 | 2/2 | Complete | 2026-04-19 |
