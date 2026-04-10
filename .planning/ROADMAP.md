# Roadmap: Noda 基础设施

## Milestones

- ✅ **v1.0 完整备份系统** — Phases 1-9 (shipped 2026-04-06) — [详情](milestones/v1.0-ROADMAP.md)
- ✅ **v1.1 基础设施现代化** — 29 commits (shipped 2026-04-11) — [详情](milestones/v1.1-MILESTONE.md)
- 🚧 **v1.2 基础设施修复与整合** — Phases 10-13 (in progress)

## Phases

**Phase Numbering:**
- Integer phases (1-9): v1.0 + v1.1 里程碑已完成
- Integer phases (10-13): v1.2 里程碑当前工作
- Decimal phases (10.1, 10.2): 紧急插入（标记 INSERTED）

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 10: B2 备份修复** - 调查并修复自 4/8 起中断的 B2 备份，修复磁盘检查和验证下载
- [ ] **Phase 11: 服务整合** - findclass-ssr 目录迁移 + Docker Compose 分组标签
- [ ] **Phase 12: Keycloak 双环境** - 独立 dev 实例 + 密码登录 + 开发热重载
- [ ] **Phase 13: Keycloak 自定义主题** - Noda 品牌登录页 + 自定义 Logo

<details>
<summary>✅ v1.0 完整备份系统 + v1.1 基础设施现代化 (Phases 1-9) - SHIPPED 2026-04-11</summary>

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

## Phase Details

### Phase 10: B2 备份修复
**Goal**: 生产环境备份恢复正常，所有备份功能端到端可用，数据保护承诺得到兑现
**Depends on**: Nothing (最高优先级，独立修复)
**Requirements**: BFIX-01, BFIX-02, BFIX-03
**Success Criteria** (what must be TRUE):
  1. 备份自动上传到 B2 并在 B2 控制台中可见最近一次成功备份（中断根因已定位并修复）
  2. 磁盘空间不足时备份前发出告警且不执行备份（避免空间不足导致备份失败）
  3. 验证测试能成功从 B2 下载备份文件并完成 pg_restore --list 校验（下载路径和认证均正常）
**Plans**: TBD

Plans:
- [ ] 10-01: TBD

### Phase 11: 服务整合
**Goal**: findclass-ssr 相关文件归入统一目录结构，Docker 容器分组清晰可辨
**Depends on**: Nothing (独立工作，与 Phase 10 无依赖)
**Requirements**: GROUP-01, GROUP-02
**Success Criteria** (what must be TRUE):
  1. findclass-ssr 所有相关文件（Dockerfile、配置）位于 noda-apps/ 目录下，`docker compose config` 输出路径正确且服务正常启动
  2. `docker compose ps --format json` 显示所有容器带有 noda-apps 分组标签，可通过 `docker compose ps --filter label=project=noda-apps` 过滤查看
**Plans**: TBD

Plans:
- [ ] 11-01: TBD

### Phase 12: Keycloak 双环境
**Goal**: 开发者拥有独立的 Keycloak 开发环境，可安全测试配置变更而不影响生产数据
**Depends on**: Nothing (复用已有 PostgreSQL dev 实例)
**Requirements**: KCDEV-01, KCDEV-02, KCDEV-03
**Success Criteria** (what must be TRUE):
  1. `docker compose -f docker-compose.yml -f docker-compose.dev.yml up keycloak-dev` 可启动独立的开发 Keycloak 实例，使用 18080 端口，连接独立的 keycloak_dev 数据库（与 prod 数据完全隔离）
  2. 开发环境支持密码登录（无需 Google OAuth 即可测试），可在 Admin Console 创建测试用户并登录
  3. 修改主题文件后在开发环境刷新浏览器即可看到变化（禁用主题缓存，无需重启容器）
**Plans**: TBD

Plans:
- [ ] 12-01: TBD

### Phase 13: Keycloak 自定义主题
**Goal**: 生产环境登录页展示 Noda 品牌，用户看到的是品牌化界面而非默认 Keycloak 样式
**Depends on**: Phase 12 (需要 dev 环境进行主题热重载迭代)
**Requirements**: THEME-01, THEME-02
**Success Criteria** (what must be TRUE):
  1. 访问 auth.noda.co.nz 登录页时显示 Noda 品牌样式（自定义颜色、字体、按钮风格），而非默认 Keycloak 界面
  2. 登录页显示 Noda Logo（替换默认 Keycloak Logo），Logo 文件从宿主机 volume 挂载并受 Git 管理
  3. 开发环境修改 CSS 后刷新浏览器即可看到变化（热重载验证通过，开发效率高于生产环境）
**Plans**: TBD
**UI hint**: yes

## Progress

**Execution Order:**
Phases execute in numeric order: 10 -> 11 -> 12 -> 13

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 10. B2 备份修复 | v1.2 | 0/? | Not started | - |
| 11. 服务整合 | v1.2 | 0/? | Not started | - |
| 12. Keycloak 双环境 | v1.2 | 0/? | Not started | - |
| 13. Keycloak 自定义主题 | v1.2 | 0/? | Not started | - |
