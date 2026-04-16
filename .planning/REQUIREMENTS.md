# Requirements: Noda Infrastructure v1.5

**Defined:** 2026-04-17
**Core Value:** 数据库永不丢失。即使发生服务器崩溃、误删除、数据库损坏等灾难，也能从最近12小时内的备份中恢复数据。

## v1.5 Requirements

### 本地 PostgreSQL (LOCALPG)

- [ ] **LOCALPG-01**: 开发者可通过 Homebrew 安装 PostgreSQL 17.9（与生产版本匹配），包含 pg_dump/pg_restore 工具
- [ ] **LOCALPG-02**: 安装脚本自动创建开发数据库和用户，提供 noda_dev / keycloak_dev 等开发用数据库
- [ ] **LOCALPG-03**: PostgreSQL 配置为 brew services 自动启动，开发者重启电脑后无需手动启动
- [ ] **LOCALPG-04**: 现有 postgres_dev_data Docker volume 中的开发数据可导出并导入到本地 PostgreSQL

### 开发容器清理 (CLEANUP)

- [ ] **CLEANUP-01**: 移除 docker-compose.dev.yml 中的 postgres-dev 服务定义
- [ ] **CLEANUP-02**: 移除 docker-compose.dev.yml 中的 keycloak-dev 服务定义
- [ ] **CLEANUP-03**: 简化或移除 docker-compose.dev.yml（仅保留必要 dev overlay）
- [ ] **CLEANUP-04**: 更新 deploy-infrastructure-prod.sh 中的 EXPECTED_CONTAINERS 和 START_SERVICES 列表
- [ ] **CLEANUP-05**: 清理 docker-compose.dev-standalone.yml（如果不再需要则移除）

### 基础设施 Pipeline (PIPELINE)

- [ ] **PIPELINE-01**: 创建 Jenkinsfile.infra，通过 Jenkins choice 参数选择目标服务（postgres/keycloak/nginx/noda-ops）
- [ ] **PIPELINE-02**: pipeline-stages.sh 新增基础设施服务专用部署函数（pipeline_deploy_postgres / pipeline_deploy_keycloak / pipeline_deploy_nginx / pipeline_deploy_noda_ops）
- [ ] **PIPELINE-03**: 每个服务使用独立部署策略：postgres=停启+备份恢复、keycloak=蓝绿零停机、nginx=重建、noda-ops=重建
- [ ] **PIPELINE-04**: 部署 postgres/keycloak 前自动执行 pg_dump 全量备份，备份失败则中止部署
- [ ] **PIPELINE-05**: 部署后自动执行健康检查（postgres: pg_isready、keycloak: HTTP /health/ready、nginx: HTTP 200、noda-ops: 容器 running）
- [ ] **PIPELINE-06**: 健康检查失败时自动回滚到部署前状态（恢复备份 / 切回旧容器）
- [ ] **PIPELINE-07**: 关键操作前设置 Jenkins input 步骤，等待人工确认后才执行（如重启 postgres）

### Keycloak 蓝绿部署 (KCBLUE)

- [ ] **KCBLUE-01**: 创建 env-keycloak.env 模板和 /opt/noda/active-env-keycloak 状态文件，支持蓝绿容器命名（keycloak-blue / keycloak-green）
- [ ] **KCBLUE-02**: 将 Keycloak upstream 从 default.conf 内嵌改为 snippets/upstream-keycloak.conf 独立文件，支持 nginx -s reload 切换
- [ ] **KCBLUE-03**: manage-containers.sh 扩展支持 Keycloak 蓝绿容器生命周期（create/start/stop/switch）
- [ ] **KCBLUE-04**: Keycloak 从 docker-compose service 迁移到 docker run 管理（仅 compose 用于 build/init），与 findclass-ssr 模式一致

### 开发者体验 (DEVEX)

- [ ] **DEVEX-01**: 创建 setup-dev.sh 一键安装脚本，自动完成 Homebrew PG 安装 + 数据库初始化 + 配置
- [ ] **DEVEX-02**: 脚本幂等设计——重复运行不会破坏现有数据或配置
- [ ] **DEVEX-03**: 自动检测 Apple Silicon (/opt/homebrew) vs Intel (/usr/local)，适配 Homebrew 路径差异

## Future Requirements

### 基础设施监控

- **MONITOR-01**: 基础设施服务部署历史记录查询
- **MONITOR-02**: 部署失败自动通知（邮件/Slack）

### 高级部署

- **ADVDEPLOY-01**: postgres 主从切换（零停机升级）
- **ADVDEPLOY-02**: nginx 配置变更自动测试（nginx -t 集成）

## Out of Scope

| Feature | Reason |
|---------|--------|
| Jenkins H2 → PostgreSQL 迁移 | Jenkins 核心数据使用 XML 文件存储，不使用 H2 数据库 |
| skykiwi-crawler Pipeline | 单次任务容器（restart: "no"），手动触发足够 |
| 本地安装 Keycloak | 开发环境直接用生产 Keycloak 测试即可 |
| Prisma 7 迁移 | 依赖 noda-apps 仓库变更 |
| Docker Compose profiles | overlay 模式已满足需求 |
| Keycloak 版本升级蓝绿 | 版本升级涉及 schema migration 不兼容，不能蓝绿；当前仅 26.2.3 配置变更 |
| Intel Mac 支持 | 当前开发者全部使用 Apple Silicon，未来按需添加 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| LOCALPG-01 | Phase 26 | Pending |
| LOCALPG-02 | Phase 26 | Pending |
| LOCALPG-03 | Phase 26 | Pending |
| LOCALPG-04 | Phase 26 | Pending |
| CLEANUP-01 | Phase 27 | Pending |
| CLEANUP-02 | Phase 27 | Pending |
| CLEANUP-03 | Phase 27 | Pending |
| CLEANUP-04 | Phase 27 | Pending |
| CLEANUP-05 | Phase 27 | Pending |
| KCBLUE-01 | Phase 28 | Pending |
| KCBLUE-02 | Phase 28 | Pending |
| KCBLUE-03 | Phase 28 | Pending |
| KCBLUE-04 | Phase 28 | Pending |
| PIPELINE-01 | Phase 29 | Pending |
| PIPELINE-02 | Phase 29 | Pending |
| PIPELINE-03 | Phase 29 | Pending |
| PIPELINE-04 | Phase 29 | Pending |
| PIPELINE-05 | Phase 29 | Pending |
| PIPELINE-06 | Phase 29 | Pending |
| PIPELINE-07 | Phase 29 | Pending |
| DEVEX-01 | Phase 30 | Pending |
| DEVEX-02 | Phase 30 | Pending |
| DEVEX-03 | Phase 30 | Pending |

**Coverage:**
- v1.5 requirements: 23 total
- Mapped to phases: 23
- Unmapped: 0

---
*Requirements defined: 2026-04-17*
*Last updated: 2026-04-17 after roadmap creation*
