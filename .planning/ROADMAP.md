# Roadmap: Noda 基础设施

## Milestones

- **v1.0 完整备份系统** -- Phases 1-9 (shipped 2026-04-06) -- [详情](milestones/v1.0-ROADMAP.md)
- **v1.1 基础设施现代化** -- 29 commits (shipped 2026-04-11) -- [详情](milestones/v1.1-MILESTONE.md)
- **v1.2 基础设施修复与整合** -- Phases 10-14 (shipped 2026-04-11) -- [详情](milestones/v1.2-ROADMAP.md)
- **v1.3 安全收敛与分组整理** -- Phases 15-18 (shipped 2026-04-12) -- [详情](milestones/v1.3-ROADMAP.md)
- **v1.4 CI/CD 零停机部署** -- Phases 19-25 (shipped 2026-04-16) -- [详情](milestones/v1.4-ROADMAP.md)
- **v1.5 开发环境本地化 + 基础设施 CI/CD** -- Phases 26-30 (shipped 2026-04-17) -- [详情](milestones/v1.5-ROADMAP.md)
- **v1.6 Jenkins Pipeline 强制执行** -- Phases 31-34 (shipped 2026-04-18)

## Phases

**Phase Numbering:**
- Integer phases (35-38): Planned v1.7 milestone work
- Decimal phases (35.1, 35.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 35: 共享库建设** - 提取 3 个共享库文件（deploy-check.sh, platform.sh, image-cleanup.sh），消除多处重复代码 (completed 2026-04-18)
- [x] **Phase 36: 蓝绿部署统一** - 合并两个蓝绿部署脚本为参数化入口，精简 rollback-findclass.sh (completed 2026-04-19)
- [x] **Phase 37: 清理与重命名** - 删除不可用的验证脚本，消除 health.sh 命名混淆 (completed 2026-04-19)
- [x] **Phase 38: 质量保证** - ShellCheck 零 error + shfmt 统一格式化 (completed 2026-04-19)

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

<details>
<summary>v1.5 开发环境本地化 + 基础设施 CI/CD (Phases 26-30) -- SHIPPED 2026-04-17</summary>

- [x] **Phase 26: 宿主机 PostgreSQL 安装与配置** -- Homebrew 安装 PostgreSQL 17.9 + 开发数据库初始化 (completed 2026-04-16)
- [x] **Phase 27: 开发容器清理与 Docker Compose 简化** -- 移除 dev 容器，精简 compose overlay (completed 2026-04-16)
- [x] **Phase 28: Keycloak 蓝绿部署基础设施** -- Keycloak 蓝绿容器管理 + upstream 切换 (completed 2026-04-17)
- [x] **Phase 29: 统一基础设施 Jenkins Pipeline** -- Jenkinsfile.infra 参数化部署基础设施服务 (completed 2026-04-17)
- [x] **Phase 30: 一键开发环境脚本** -- setup-dev.sh 幂等安装开发环境 (completed 2026-04-17)

</details>

<details>
<summary>v1.6 Jenkins Pipeline 强制执行 (Phases 31-34) -- SHIPPED 2026-04-18</summary>

### v1.6 Jenkins Pipeline 强制执行 (Shipped 2026-04-18)

**Milestone Goal:** 所有容器只能通过 Jenkins Pipeline 上线，禁止直接 docker compose / shell 脚本部署

- [x] **Phase 31: Docker Socket 权限收敛 + 文件权限锁定** -- Docker socket 属组收敛到 jenkins，部署脚本仅 jenkins 可执行 (completed 2026-04-18)
- [x] **Phase 32: sudoers 白名单 + Break-Glass 紧急机制** -- 管理员只读 docker 命令 + 紧急部署受控入口 (completed 2026-04-18)
- [x] **Phase 33: 审计日志系统** -- auditd 内核审计 + Jenkins Audit Trail + 日志轮转 (completed 2026-04-18)
- [x] **Phase 34: Jenkins 权限矩阵 + 统一管理脚本** -- Matrix Auth 插件 + setup-docker-permissions.sh 一站式管理 (completed 2026-04-18)

</details>

### v1.7 代码精简与规整 (Shipped 2026-04-19)

**Milestone Goal:** 在不影响现有功能的前提下，消除重复代码、合并冗余脚本、统一代码风格，使代码库更简洁易维护

#### Phase 35: 共享库建设
**Goal**: 所有消费者脚本通过 source 引用统一的共享库文件，消除跨文件的函数定义重复
**Depends on**: Nothing（本里程碑首个阶段）
**Requirements**: LIB-01, LIB-02, LIB-03
**Success Criteria** (what must be TRUE):
  1. `scripts/lib/deploy-check.sh` 存在且包含 `http_health_check()` 和 `e2e_verify()` 函数，4 个原调用方文件不再内联定义这些函数
  2. `scripts/lib/platform.sh` 存在且包含 `detect_platform()` 函数，8 个原调用方文件改为 source 该库
  3. `scripts/lib/image-cleanup.sh` 存在且包含 3 个独立清理函数（cleanup_by_tag_count/cleanup_by_date_threshold/cleanup_dangling），3 个原调用方文件改为 source 该库
  4. 所有共享库文件包含 Source Guard 防止重复加载，通过函数参数传递差异化的超时/重试配置
**Plans**: 3 plans

Plans:
- [x] 35-01-PLAN.md — 提取 deploy-check.sh 共享库（http_health_check + e2e_verify，4 个消费者迁移）
- [x] 35-02-PLAN.md — 提取 platform.sh 共享库（detect_platform，8 + 1 个消费者迁移）
- [x] 35-03-PLAN.md — 提取 image-cleanup.sh 共享库（3 个清理函数，3 个消费者迁移，依赖 35-01）

#### Phase 36: 蓝绿部署统一
**Goal**: findclass-ssr 和 keycloak 的蓝绿部署通过单一参数化脚本执行，消除 95% 重复逻辑
**Depends on**: Phase 35（需要 deploy-check.sh 中的共享函数）
**Requirements**: BLUE-01, BLUE-02
**Success Criteria** (what must be TRUE):
  1. `scripts/blue-green-deploy.sh` 通过环境变量（SERVICE_IMAGE、SERVICE_PORT、HEALTH_PATH 等）参数化支持 findclass-ssr 和 keycloak 两种服务
  2. 旧 `scripts/keycloak-blue-green-deploy.sh` 保留为向后兼容 wrapper，调用新脚本并传递正确参数
  3. `scripts/rollback-findclass.sh` 使用 `scripts/lib/deploy-check.sh` 中的共享函数，不再包含内联的健康检查逻辑
  4. findclass-ssr 蓝绿部署通过统一脚本执行，行为与重构前一致（零停机、自动回滚）
**Plans**: 2 plans

Plans:
- [x] 36-01-PLAN.md — 合并蓝绿部署脚本为统一参数化入口（IMAGE_SOURCE/CLEANUP_METHOD 分支 + findclass/keycloak wrapper）
- [x] 36-02-PLAN.md — 回滚脚本参数化（rollback-deploy.sh 统一脚本 + findclass/keycloak wrapper）

#### Phase 37: 清理与重命名
**Goal**: 代码库不再包含不可用的遗留脚本，文件命名不再引起混淆
**Depends on**: Nothing（独立于其他阶段，但建议在 Phase 36 后执行以避免合并冲突）
**Requirements**: CLEAN-01, CLEAN-02
**Success Criteria** (what must be TRUE):
  1. `scripts/verify/` 目录下 5 个一次性验证脚本已删除，目录不存在或为空
  2. `scripts/backup/lib/health.sh` 重命名为 `scripts/backup/lib/db-health.sh`，所有 source 引用路径已更新
  3. 项目中无任何文件引用已删除的 verify 脚本或旧的 health.sh 路径
**Plans**: 2 plans

Plans:
- [x] 37-01-PLAN.md — 删除 scripts/verify/ 下 5 个不可用的验证脚本 + 更新 deploy 脚本引用
- [x] 37-02-PLAN.md — 重命名 backup/lib/health.sh 为 db-health.sh 并更新 source 路径（per D-01）

#### Phase 38: 质量保证
**Goal**: scripts/ 目录下所有 .sh 文件通过 ShellCheck 零 error 检查并有一致的代码风格
**Depends on**: Phase 35, Phase 36, Phase 37（在所有代码变更完成后执行）
**Requirements**: QUAL-01, QUAL-02
**Success Criteria** (what must be TRUE):
  1. `shellcheck scripts/**/*.sh` 输出零 error 级别问题（warning 可通过 .shellcheckrc 抑制）
  2. `shfmt` 格式化后所有 .sh 文件风格一致（缩进、引号、空格等）
  3. `.shellcheckrc` 配置文件存在，记录项目级抑制规则和解释
**Plans**: 2 plans

Plans:
- [x] 38-01-PLAN.md — 安装 shfmt + 创建 .editorconfig 和 .shellcheckrc 配置文件
- [x] 38-02-PLAN.md — shfmt 批量格式化 + ShellCheck/bash-n 双重验证（依赖 38-01）

## Progress

**Execution Order:**
Phases execute in numeric order: 35 -> 36 -> 37 -> 38

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 35. 共享库建设 | v1.7 | 3/3 | Complete | 2026-04-18 |
| 36. 蓝绿部署统一 | v1.7 | 2/2 | Complete | 2026-04-19 |
| 37. 清理与重命名 | v1.7 | 2/2 | Complete | 2026-04-19 |
| 38. 质量保证 | v1.7 | 2/2 | Complete | 2026-04-19 |
