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
