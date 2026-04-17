# Roadmap: Noda 基础设施

## Milestones

- **v1.0 完整备份系统** -- Phases 1-9 (shipped 2026-04-06) -- [详情](milestones/v1.0-ROADMAP.md)
- **v1.1 基础设施现代化** -- 29 commits (shipped 2026-04-11) -- [详情](milestones/v1.1-MILESTONE.md)
- **v1.2 基础设施修复与整合** -- Phases 10-14 (shipped 2026-04-11) -- [详情](milestones/v1.2-ROADMAP.md)
- **v1.3 安全收敛与分组整理** -- Phases 15-18 (shipped 2026-04-12) -- [详情](milestones/v1.3-ROADMAP.md)
- **v1.4 CI/CD 零停机部署** -- Phases 19-25 (shipped 2026-04-16) -- [详情](milestones/v1.4-ROADMAP.md)
- **v1.5 开发环境本地化 + 基础设施 CI/CD** -- Phases 26-30 (shipped 2026-04-17) -- [详情](milestones/v1.5-ROADMAP.md)

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

<details>
<summary>v1.5 开发环境本地化 + 基础设施 CI/CD (Phases 26-30) -- SHIPPED 2026-04-17</summary>

- [x] **Phase 26: 宿主机 PostgreSQL 安装与配置** -- Homebrew 安装 PostgreSQL 17.9 + 开发数据库初始化 (completed 2026-04-16)
- [x] **Phase 27: 开发容器清理与 Docker Compose 简化** -- 移除 dev 容器，精简 compose overlay (completed 2026-04-16)
- [x] **Phase 28: Keycloak 蓝绿部署基础设施** -- Keycloak 蓝绿容器管理 + upstream 切换 (completed 2026-04-17)
- [x] **Phase 29: 统一基础设施 Jenkins Pipeline** -- Jenkinsfile.infra 参数化部署基础设施服务 (completed 2026-04-17)
- [x] **Phase 30: 一键开发环境脚本** -- setup-dev.sh 幂等安装开发环境 (completed 2026-04-17)

</details>
