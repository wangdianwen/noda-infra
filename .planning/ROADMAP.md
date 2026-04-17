# Roadmap: Noda 基础设施

## Milestones

- **v1.0 完整备份系统** -- Phases 1-9 (shipped 2026-04-06) -- [详情](milestones/v1.0-ROADMAP.md)
- **v1.1 基础设施现代化** -- 29 commits (shipped 2026-04-11) -- [详情](milestones/v1.1-MILESTONE.md)
- **v1.2 基础设施修复与整合** -- Phases 10-14 (shipped 2026-04-11) -- [详情](milestones/v1.2-ROADMAP.md)
- **v1.3 安全收敛与分组整理** -- Phases 15-18 (shipped 2026-04-12) -- [详情](milestones/v1.3-ROADMAP.md)
- **v1.4 CI/CD 零停机部署** -- Phases 19-25 (shipped 2026-04-16) -- [详情](milestones/v1.4-ROADMAP.md)
- **v1.5 开发环境本地化 + 基础设施 CI/CD** -- Phases 26-30 (shipped 2026-04-17) -- [详情](milestones/v1.5-ROADMAP.md)
- **v1.6 Jenkins Pipeline 强制执行** -- Phases 31-34 (in progress)

## Phases

**Phase Numbering:**
- Integer phases (1-34): Planned milestone work
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

<details>
<summary>v1.5 开发环境本地化 + 基础设施 CI/CD (Phases 26-30) -- SHIPPED 2026-04-17</summary>

- [x] **Phase 26: 宿主机 PostgreSQL 安装与配置** -- Homebrew 安装 PostgreSQL 17.9 + 开发数据库初始化 (completed 2026-04-16)
- [x] **Phase 27: 开发容器清理与 Docker Compose 简化** -- 移除 dev 容器，精简 compose overlay (completed 2026-04-16)
- [x] **Phase 28: Keycloak 蓝绿部署基础设施** -- Keycloak 蓝绿容器管理 + upstream 切换 (completed 2026-04-17)
- [x] **Phase 29: 统一基础设施 Jenkins Pipeline** -- Jenkinsfile.infra 参数化部署基础设施服务 (completed 2026-04-17)
- [x] **Phase 30: 一键开发环境脚本** -- setup-dev.sh 幂等安装开发环境 (completed 2026-04-17)

</details>

### v1.6 Jenkins Pipeline 强制执行 (In Progress)

**Milestone Goal:** 所有容器只能通过 Jenkins Pipeline 上线，禁止直接 docker compose / shell 脚本部署

- [x] **Phase 31: Docker Socket 权限收敛 + 文件权限锁定** -- Docker socket 属组收敛到 jenkins，部署脚本仅 jenkins 可执行 (completed 2026-04-18)
- [ ] **Phase 32: sudoers 白名单 + Break-Glass 紧急机制** -- 管理员只读 docker 命令 + 紧急部署受控入口
- [ ] **Phase 33: 审计日志系统** -- auditd 内核审计 + Jenkins Audit Trail + 日志轮转
- [ ] **Phase 34: Jenkins 权限矩阵 + 统一管理脚本** -- Matrix Auth 插件 + setup-docker-permissions.sh 一站式管理

## Phase Details

### Phase 31: Docker Socket 权限收敛 + 文件权限锁定
**Goal**: 仅 jenkins 用户可通过 Docker socket 执行 docker 命令，部署脚本仅 jenkins 可执行，且权限配置在服务器重启后持久保留
**Depends on**: Nothing (v1.6 第一个 Phase)
**Requirements**: PERM-01, PERM-02, PERM-03, PERM-04, PERM-05, JENKINS-01, JENKINS-02
**Success Criteria** (what must be TRUE):
  1. `sudo -u jenkins docker ps` 返回容器列表（jenkins 用户可正常执行 docker 命令）
  2. `sudo -u admin docker ps` 返回 permission denied（非 jenkins 用户无法直接执行 docker 命令）
  3. 服务器重启或 Docker 服务重启后，Docker socket 属组仍为 root:jenkins（systemd override 持久化）
  4. 所有 4 个 Jenkins Pipeline（findclass-ssr、noda-site、keycloak、infra）端到端正常运行
  5. 备份脚本（noda-ops 容器内 + 宿主机 docker exec）正常工作
**Plans**: 3 plans

Plans:
- [x] 31-01-PLAN.md — 创建 undo-permissions.sh 回滚脚本 + 修改 setup-jenkins.sh 为 socket 属组方式
- [x] 31-02-PLAN.md — 创建 apply-file-permissions.sh 一站式权限应用脚本
- [x] 31-03-PLAN.md — macOS 跨平台适配（gap closure: UAT 6 个 blocker 修复）

### Phase 32: sudoers 白名单 + Break-Glass 紧急机制
**Goal**: 权限锁定后管理员仍可通过受控路径进行只读调试和紧急部署，所有操作留有审计痕迹
**Depends on**: Phase 31
**Requirements**: BREAK-01, BREAK-02, BREAK-03, BREAK-04
**Success Criteria** (what must be TRUE):
  1. 管理员可通过 `sudo docker ps/logs/inspect/stats/top` 执行只读调试命令
  2. 管理员执行 `sudo docker run/rm/compose up/down/exec` 被拒绝（写入命令不可执行）
  3. Break-Glass 脚本在 Jenkins 正常运行时拒绝执行（防止滥用）
  4. Break-Glass 脚本在 Jenkins 不可用时，验证通过后可执行紧急部署，且操作被记录到审计日志
**Plans**: 2 plans

Plans:
- [ ] 32-01-PLAN.md — sudoers 白名单安装/验证脚本（install-sudoers-whitelist.sh + verify-sudoers-whitelist.sh）
- [ ] 32-02-PLAN.md — Break-Glass 紧急部署脚本（break-glass.sh: Jenkins 健康检查 + PAM 认证 + 审计日志）

### Phase 33: 审计日志系统
**Goal**: 所有 docker 命令执行和 Jenkins Pipeline 操作被完整记录，日志不可篡改且不会占满磁盘
**Depends on**: Phase 31
**Requirements**: AUDIT-01, AUDIT-02, AUDIT-03, AUDIT-04
**Success Criteria** (what must be TRUE):
  1. `ausearch -k docker-cmd` 可查询到所有 docker 命令执行记录（含用户、时间、命令参数）
  2. auditd 日志文件权限为 root 只读，普通用户无法修改或删除
  3. Jenkins Audit Trail 插件记录 Pipeline 触发事件（谁在什么时候触发了什么 Job）
  4. sudo 操作被记录到独立日志文件（通过 sudoers Defaults logfile 配置）
**Plans**: 3 plans

Plans:
- [ ] 33-01: TBD
- [ ] 33-02: TBD

### Phase 34: Jenkins 权限矩阵 + 统一管理脚本
**Goal**: Jenkins 内部权限细化（管理员全权限/普通用户只触发），权限配置可通过统一脚本一键 apply/verify/rollback
**Depends on**: Phase 32, Phase 33
**Requirements**: JENKINS-03, JENKINS-04
**Success Criteria** (what must be TRUE):
  1. 非 admin 用户可以触发 Pipeline 运行但不能修改 Job 配置或访问 Script Console
  2. `setup-docker-permissions.sh apply` 一键配置所有权限（socket + 文件 + sudoers + auditd）
  3. `setup-docker-permissions.sh verify` 输出全部 PASS 的权限检查结果
  4. `setup-docker-permissions.sh rollback` 可恢复到权限收敛前的状态
**Plans**: 3 plans

Plans:
- [ ] 34-01: TBD
- [ ] 34-02: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 31 -> 32 -> 33 -> 34

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 31. Docker Socket 权限收敛 | v1.6 | 3/3 | Complete | 2026-04-18 |
| 32. sudoers + Break-Glass | v1.6 | 0/2 | Planned | - |
| 33. 审计日志系统 | v1.6 | 0/? | Not started | - |
| 34. Jenkins 权限矩阵 + 统一脚本 | v1.6 | 0/? | Not started | - |
