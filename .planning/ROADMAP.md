# Roadmap: Noda 基础设施

## Milestones

- ✅ **v1.0 完整备份系统** — Phases 1-9 (shipped 2026-04-06) — [详情](milestones/v1.0-ROADMAP.md)
- ✅ **v1.1 基础设施现代化** — 29 commits (shipped 2026-04-11) — [详情](milestones/v1.1-MILESTONE.md)
- ✅ **v1.2 基础设施修复与整合** — Phases 10-14 (shipped 2026-04-11) — [详情](milestones/v1.2-ROADMAP.md)
- 🚧 **v1.3 安全收敛与分组整理** — Phases 15-18 (in progress)

## Phases

**Phase Numbering:**
- Integer phases (1-18): Planned milestone work
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

### 🚧 v1.3 安全收敛与分组整理 (In Progress)

**Milestone Goal:** 消除所有端口直接暴露，统一通过 nginx 代理，完成容器分组

- [ ] **Phase 15: PostgreSQL 客户端升级** — pg_dump 版本匹配 + sslmode 显式设置
- [x] **Phase 16: Keycloak 端口收敛** — nginx 统一反代 + 端口移除 + dev 复用线上认证 (completed 2026-04-11)
- [x] **Phase 17: 端口安全加固** — dev PostgreSQL 端口绑定 localhost + Keycloak 管理端口收敛 (completed 2026-04-11)
- [ ] **Phase 18: 容器标签分组** — noda.environment 标签 + 命名规范统一

## Phase Details

### Phase 15: PostgreSQL 客户端升级
**Goal**: 备份系统使用与服务器匹配的 pg_dump 17.x 客户端，且备份连接不会因 PG17 默认 sslmode 而静默失败
**Depends on**: 无（独立变更，风险最低）
**Requirements**: PG-01, PG-02
**Success Criteria** (what must be TRUE):
  1. noda-ops 容器内 `pg_dump --version` 输出 17.x（与服务端 17.9 主版本一致）
  2. 备份脚本执行时无 sslmode 警告或连接失败
  3. 现有备份流程（健康检查 -> 备份 -> 上传 B2）端到端正常完成
**Plans**: 1 plan

Plans:
- [ ] 15-01-PLAN.md — 升级 Dockerfile (Alpine 3.21 + PG17 client) + 添加 PGSSLMODE=disable 环境变量

### Phase 16: Keycloak 端口收敛
**Goal**: auth.noda.co.nz 流量统一经过 nginx 反向代理到 Keycloak，Docker 不再直接暴露 Keycloak 端口
**Depends on**: Phase 15（独立，但按顺序执行以避免并行部署冲突）
**Requirements**: KC-01, KC-02, KC-03
**Success Criteria** (what must be TRUE):
  1. auth.noda.co.nz 流量经过 nginx 反向代理到达 Keycloak（Cloudflare Dashboard 路由指向 nginx 服务）
  2. Docker Compose 不再暴露 Keycloak 8080 和 9000 端口到宿主机
  3. 浏览器访问 auth.noda.co.nz 正常显示 Keycloak 登录页且 Google OAuth 登录流程完整可用
  4. 开发环境可通过 auth.noda.co.nz 完成认证（localhost redirect URI 已配置）
**Plans**: 1 plan

Plans:
- [x] 16-01-PLAN.md — Cloudflare Tunnel 路由改为 nginx + Keycloak 端口移除 + 健康检查统一 + 部署验证

### Phase 17: 端口安全加固
**Goal**: 开发用 PostgreSQL 仅本地可访问，Keycloak 管理端口不再外部暴露
**Depends on**: Phase 16（SEC-02 Keycloak 9000 端口在 KC-02 中一并完成，本 Phase 确认收敛）
**Requirements**: SEC-01, SEC-02
**Success Criteria** (what must be TRUE):
  1. postgres-dev 5433 端口仅绑定 127.0.0.1，外部网络无法直接连接
  2. Keycloak 9000 管理端口不在 docker-compose ports 中暴露到宿主机
  3. 本地开发通过 127.0.0.1:5433 正常连接 dev 数据库
**Plans**: 1 plan

Plans:
- [x] 17-01-PLAN.md — 修改 3 个 compose 文件端口绑定 127.0.0.1 + 部署后验证

### Phase 18: 容器标签分组
**Goal**: 所有容器携带统一的环境标签，可通过 docker ps --filter 按环境筛选
**Depends on**: Phase 17（最后执行，涉及所有 compose 文件修改，避免与前期文件变更冲突）
**Requirements**: GRP-01, GRP-02
**Success Criteria** (what must be TRUE):
  1. 所有容器拥有 noda.environment=prod 或 noda.environment=dev 标签
  2. docker ps --filter label=noda.environment=prod 仅显示生产容器，docker ps --filter label=noda.environment=dev 仅显示开发容器
  3. 标签命名统一为 noda.service-group（无 noda-apps/apps 不一致）
**Plans**: 1 plan

Plans:
- [ ] 18-01-PLAN.md — 修复标签不一致 + 添加环境标签（5 个 compose 文件）

## Progress

**Execution Order:**
Phases execute in numeric order: 15 → 16 → 17 → 18

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 10. B2 备份修复 | v1.2 | 3/3 | Complete | 2026-04-11 |
| 11. 服务整合 | v1.2 | 2/2 | Complete | 2026-04-11 |
| 12. Keycloak 双环境 | v1.2 | 1/1 | Complete | 2026-04-11 |
| 13. Keycloak 自定义主题 | v1.2 | 1/1 | Complete | 2026-04-11 |
| 14. 容器保护与部署安全 | v1.2 | 3/3 | Complete | 2026-04-11 |
| 15. PostgreSQL 客户端升级 | v1.3 | 0/1 | Planning complete | - |
| 16. Keycloak 端口收敛 | v1.3 | 1/1 | Complete   | 2026-04-11 |
| 17. 端口安全加固 | v1.3 | 1/1 | Complete    | 2026-04-11 |
| 18. 容器标签分组 | v1.3 | 0/? | Not started | - |
