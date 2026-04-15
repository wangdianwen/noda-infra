# Roadmap: Noda 基础设施

## Milestones

- ✅ **v1.0 完整备份系统** — Phases 1-9 (shipped 2026-04-06) — [详情](milestones/v1.0-ROADMAP.md)
- ✅ **v1.1 基础设施现代化** — 29 commits (shipped 2026-04-11) — [详情](milestones/v1.1-MILESTONE.md)
- ✅ **v1.2 基础设施修复与整合** — Phases 10-14 (shipped 2026-04-11) — [详情](milestones/v1.2-ROADMAP.md)
- ✅ **v1.3 安全收敛与分组整理** — Phases 15-18 (shipped 2026-04-12)
- 🚧 **v1.4 CI/CD 零停机部署** — Phases 19-25 (in progress)

## Phases

**Phase Numbering:**
- Integer phases (1-25): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

<details>
<summary>✅ v1.0 完整备份系统 + v1.1 基础设施现代化 (Phases 1-9) — SHIPPED 2026-04-11</summary>

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
<summary>✅ v1.2 基础设施修复与整合 (Phases 10-14) — SHIPPED 2026-04-11</summary>

- [x] Phase 10: B2 备份修复 (3/3 plans) — completed 2026-04-11
- [x] Phase 11: 服务整合 (2/2 plans) — completed 2026-04-11
- [x] Phase 12: Keycloak 双环境 (1/1 plans) — completed 2026-04-11
- [x] Phase 13: Keycloak 自定义主题 (1/1 plans) — completed 2026-04-11
- [x] Phase 14: 容器保护与部署安全 (3/3 plans) — completed 2026-04-11

</details>

<details>
<summary>✅ v1.3 安全收敛与分组整理 (Phases 15-18) — SHIPPED 2026-04-12</summary>

- [x] **Phase 15: PostgreSQL 客户端升级** — completed 2026-04-12
- [x] **Phase 16: Keycloak 端口收敛** — completed 2026-04-11
- [x] **Phase 17: 端口安全加固** — completed 2026-04-11
- [x] **Phase 18: 容器标签分组** — completed 2026-04-11

</details>

### 🚧 v1.4 CI/CD 零停机部署 (In Progress)

**Milestone Goal:** Jenkins + 蓝绿部署实现编译失败不 down 站，自动回滚保护

- [x] **Phase 19: Jenkins 安装与基础配置** — 宿主机原生安装 Jenkins LTS，可操作 Docker daemon (completed 2026-04-14)
- [x] **Phase 20: Nginx 蓝绿路由基础** — 将 upstream 定义抽离为独立 include 文件，支持动态切换 (completed 2026-04-15)
- [x] **Phase 21: 蓝绿容器管理** — docker run 独立管理蓝绿容器，状态文件追踪活跃环境 (completed 2026-04-15)
- [x] **Phase 22: 蓝绿部署核心流程** — 完整的蓝绿部署脚本（容器启停 + 健康检查 + nginx 切换 + 回滚） (completed 2026-04-15)
- [ ] **Phase 23: Pipeline 集成与测试门禁** — Jenkinsfile 八阶段 Pipeline + lint/test 质量门禁
- [ ] **Phase 24: Pipeline 增强特性** — 部署前备份检查 + CDN 缓存清除 + 镜像清理
- [ ] **Phase 25: 清理与迁移** — 旧脚本保留为手动回退 + CLAUDE.md 文档更新

## Phase Details

### Phase 19: Jenkins 安装与基础配置
**Goal**: 管理员可以在宿主机上安装、启动、获取初始密码、卸载 Jenkins，Jenkins 可直接操作 Docker
**Depends on**: Phase 18（前一里程碑，基础设施就绪）
**Requirements**: JENK-01, JENK-02, JENK-03, JENK-04
**Success Criteria** (what must be TRUE):
  1. 管理员运行 `setup-jenkins.sh install` 后 Jenkins 服务启动，systemctl status jenkins 显示 active (running)
  2. Jenkins 用户可以通过 `docker ps` 列出当前运行的容器（已在 docker 组中）
  3. 管理员可从日志或文件中获取初始管理员密码并完成首次登录
  4. 管理员运行 `setup-jenkins.sh uninstall` 后 Jenkins 进程消失、相关文件全部清除
**Plans**: 2 plans

Plans:
- [x] 19-01-PLAN.md — setup-jenkins.sh 主脚本（7 个子命令：install/uninstall/status/show-password/restart/upgrade/reset-password）
- [x] 19-02-PLAN.md — Jenkins init.groovy.d 自动化脚本（管理员/插件/安全/Pipeline 作业）+ 管理员凭据模板

### Phase 20: Nginx 蓝绿路由基础
**Goal**: nginx 的 findclass upstream 定义从 default.conf 抽离到独立 include 文件，Pipeline 可通过重写该文件 + reload 切换流量指向
**Depends on**: Phase 19（按顺序执行，避免并行部署冲突）
**Requirements**: BLUE-02
**Success Criteria** (what must be TRUE):
  1. nginx 配置中 findclass 的 upstream 通过 `include snippets/upstream-findclass.conf` 引用
  2. 手动修改 include 文件内容后执行 `nginx -s reload`，流量无中断地指向新的后端地址
  3. class.noda.co.nz 现有访问不受影响（变更前后功能等价）
**Plans**: 1 plan

Plans:
- [x] 20-01-PLAN.md — 抽离三个 upstream include 文件 + 验证 nginx reload 切换

### Phase 21: 蓝绿容器管理
**Goal**: blue 和 green 两个 findclass-ssr 容器可以独立启停，通过状态文件追踪当前活跃环境
**Depends on**: Phase 20（nginx 已支持 upstream 动态切换）
**Requirements**: BLUE-01, BLUE-03, BLUE-04, BLUE-05
**Success Criteria** (what must be TRUE):
  1. 同一时刻存在 blue 和 green 两个 findclass-ssr 容器，均在 noda-network 网络上运行
  2. `/opt/noda/active-env` 文件内容为 `blue` 或 `green`，准确反映当前活跃环境
  3. 蓝绿容器通过 `docker run` 启动和管理（不通过 docker-compose.yml）
  4. nginx 可通过容器名 DNS 解析访问 blue 和 green 容器
**Plans**: 1 plan

Plans:
- [x] 21-01-PLAN.md — manage-containers.sh 蓝绿容器管理脚本（8 个子命令）+ env-findclass-ssr.env 环境变量文件

### Phase 22: 蓝绿部署核心流程
**Goal**: 管理员可通过脚本执行完整的蓝绿部署流程，包括构建新镜像、启动目标容器、健康检查、切换流量、验证、回滚
**Depends on**: Phase 21（蓝绿容器管理基础设施就绪）
**Requirements**: PIPE-02, PIPE-03, TEST-03, TEST-04, TEST-05
**Success Criteria** (what must be TRUE):
  1. 每次构建的镜像携带 Git SHA 短哈希标签（如 `findclass-ssr:abc1234`），不再使用 latest
  2. 新容器启动后自动执行 HTTP 健康检查（直接 curl 容器内部端点），最多重试 10 次每次间隔 5 秒
  3. 流量切换后通过 nginx 执行 E2E 验证（curl 外部可达性），确认完整请求链路正常
  4. 健康检查或 E2E 验证失败时，流量不切换、旧容器不停，自动保持当前活跃环境
  5. 构建阶段失败时脚本立即中止，不进入部署阶段
**Plans**: 2 plans

Plans:
- [x] 22-01: 蓝绿部署主脚本（blue-green-deploy.sh）— 构建 + 启动 + 健康检查 + 切换 + 验证
- [x] 22-02: 回滚脚本（rollback-findclass.sh）— 紧急手动回滚

### Phase 23: Pipeline 集成与测试门禁
**Goal**: 管理员可在 Jenkins 中手动触发 Pipeline，自动执行 lint + 单元测试 + 蓝绿部署全流程，构建日志在失败时自动归档
**Depends on**: Phase 22（蓝绿部署脚本验证通过）
**Requirements**: PIPE-01, PIPE-04, PIPE-05, TEST-01, TEST-02
**Success Criteria** (what must be TRUE):
  1. Jenkins Pipeline 按 Pre-flight -> Build -> Test -> Deploy -> Health Check -> Switch -> Verify -> Cleanup 八阶段执行
  2. Test 阶段执行 `pnpm lint`，lint 不通过则 Pipeline 中止，不进入部署
  3. Test 阶段执行 `pnpm test`，单元测试不通过则 Pipeline 中止，不进入部署
  4. Pipeline 通过手动触发执行（"Build Now" 按钮），不支持自动触发
  5. 部署失败时构建日志和容器日志自动归档到 Jenkins
**Plans**: 2 plans

Plans:
- [x] 23-01-PLAN.md — pipeline-stages.sh 阶段函数库 + Jenkinsfile 八阶段 Pipeline + 03-pipeline-job.groovy SCM 模式
- [ ] 23-02-PLAN.md — Pre-flight 环境检查增强 + lint/test 质量门禁强化 + 人工验证

### Phase 24: Pipeline 增强特性
**Goal**: Pipeline 在部署前检查备份时效性，部署后自动清除 CDN 缓存和旧镜像，提升部署安全性和磁盘空间管理
**Depends on**: Phase 23（Pipeline 基础流程可用）
**Requirements**: ENH-01, ENH-02, ENH-03
**Success Criteria** (what must be TRUE):
  1. Pipeline Pre-flight 阶段检查数据库备份是否在 12 小时内，超过 12 小时则阻止部署并报告原因
  2. 部署成功后 Pipeline 自动调用 Cloudflare API 清除 CDN 缓存（index.html 和静态资源 URL）
  3. Pipeline Cleanup 阶段自动清理超过 7 天的旧 Docker 镜像，释放磁盘空间
**Plans**: 2 plans

Plans:
- [ ] 24-01: 部署前备份检查 + CDN 缓存清除 + 旧镜像清理脚本集成

### Phase 25: 清理与迁移
**Goal**: 旧部署脚本保留为手动回退入口，部署文档更新反映新的 CI/CD 流程
**Depends on**: Phase 24（Pipeline 增强特性就绪）
**Requirements**: ENH-04
**Success Criteria** (what must be TRUE):
  1. deploy-infrastructure-prod.sh 和 deploy-apps-prod.sh 脚本仍然存在且可手动执行，作为紧急回退方案
  2. CLAUDE.md 部署命令章节更新为 Jenkins Pipeline 优先，旧脚本标注为手动回退
  3. ROADMAP.md 和 PROJECT.md 反映 v1.4 里程碑完成状态
**Plans**: 2 plans

Plans:
- [ ] 25-01: 旧脚本保留标记 + 文档更新 + 里程碑归档

## Progress

**Execution Order:**
Phases execute in numeric order: 19 → 20 → 21 → 22 → 23 → 24 → 25

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 19. Jenkins 安装与基础配置 | v1.4 | 2/2 | Complete    | 2026-04-14 |
| 20. Nginx 蓝绿路由基础 | v1.4 | 1/1 | Complete | 2026-04-15 |
| 21. 蓝绿容器管理 | v1.4 | 1/1 | Complete    | 2026-04-15 |
| 22. 蓝绿部署核心流程 | v1.4 | 2/2 | Complete    | 2026-04-15 |
| 23. Pipeline 集成与测试门禁 | v1.4 | 1/2 | In Progress|  |
| 24. Pipeline 增强特性 | v1.4 | 0/1 | Not started | - |
| 25. 清理与迁移 | v1.4 | 0/1 | Not started | - |
