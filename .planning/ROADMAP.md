# Roadmap: Noda 基础设施

## Milestones

- ✅ **v1.0 完整备份系统** — Phases 1-9 (shipped 2026-04-06) — [详情](milestones/v1.0-ROADMAP.md)
- ✅ **v1.1 基础设施现代化** — 29 commits (shipped 2026-04-11) — [详情](milestones/v1.1-MILESTONE.md)
- ✅ **v1.2 基础设施修复与整合** — Phases 10-14 (shipped 2026-04-11) — [详情](milestones/v1.2-ROADMAP.md)
- 📋 **v1.3** — (待规划)

## Phases

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

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 10. B2 备份修复 | v1.2 | 3/3 | Complete | 2026-04-11 |
| 11. 服务整合 | v1.2 | 2/2 | Complete | 2026-04-11 |
| 12. Keycloak 双环境 | v1.2 | 1/1 | Complete | 2026-04-11 |
| 13. Keycloak 自定义主题 | v1.2 | 1/1 | Complete | 2026-04-11 |
| 14. 容器保护与部署安全 | v1.2 | 3/3 | Complete | 2026-04-11 |
