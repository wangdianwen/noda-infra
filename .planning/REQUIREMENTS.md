# Requirements: Noda 基础设施迁移到 iStoreOS (r4s)

**Defined:** 2026-05-17
**Core Value:** 数据库永不丢失。迁移不改变核心功能，只改变运行位置。

## v1.12 Requirements

### 环境准备

- [ ] **ENV-01**: r4s 上创建 Docker 独立网桥（noda-network），端口映射避免与软路由冲突
- [ ] **ENV-02**: r4s 上创建 Swap 文件（建议 2GB）作为 OOM 缓冲，保护容器不被 kill
- [ ] **ENV-03**: 所有容器配置内存限制（deploy.resources.limits），适配 r4s 3.77 GiB 内存
- [ ] **ENV-04**: 配置 Mac ↔ r4s SSH 免密部署密钥（Jenkins 专用，非交互式）
- [ ] **ENV-05**: 确认 iStoreOS Docker 开机自启已配置，容器 restart: unless-stopped 生效

### 基础设施迁移

- [ ] **INFRA-01**: PostgreSQL 数据从 Mac 迁移到 r4s（pg_dump/pg_restore，零数据丢失）
- [ ] **INFRA-02**: Keycloak 配置迁移到 r4s（realm/主题/客户端配置保持不变）
- [ ] **INFRA-03**: Nginx 反向代理配置迁移到 r4s（upstream/SSL/路由规则保持不变）
- [ ] **INFRA-04**: noda-ops 容器迁移到 r4s（Cloudflare Tunnel + 备份 + Doppler + supervisord）
- [ ] **INFRA-05**: noda-network 外部网络在 r4s 上创建，所有服务加入同一网络

### 应用迁移

- [ ] **APP-01**: findclass-ssr prod 容器迁移到 r4s（构建仍在 Mac，镜像导出/导入到 r4s）
- [ ] **APP-02**: findclass-ssr pre-prod 容器迁移到 r4s（共享 PostgreSQL/Keycloak 基础设施）
- [ ] **APP-03**: noda-admin 管理后台迁移到 r4s
- [ ] **APP-04**: noda-auth 认证应用迁移到 r4s

### CI/CD 改造

- [ ] **CICD-01**: Jenkinsfile 改造 — 本地 `docker compose` 命令改为通过 SSH 远程在 r4s 上执行
- [ ] **CICD-02**: Docker 镜像构建流程调整 — Mac 构建镜像后通过 `docker save/load` 传输到 r4s
- [ ] **CICD-03**: Jenkins SSH 远程部署 Pipeline 验证（构建 → 传输 → 部署 → 健康检查 → 完成）
- [ ] **CICD-04**: 基础设施 Jenkins Pipeline（Jenkinsfile.infra）同步改造为 SSH 远程部署

### 备份与 Cronjob 迁移

- [ ] **BACKUP-01**: pg_dump 每日备份 cronjob 在 r4s noda-ops 容器中正常运行
- [ ] **BACKUP-02**: B2 云备份上传从 r4s 正常执行（Cloudflare Tunnel 确保 B2 可达）
- [ ] **BACKUP-03**: Doppler 密钥每日备份 cronjob 迁移到 r4s
- [ ] **BACKUP-04**: 周验证测试 cronjob 迁移到 r4s
- [ ] **BACKUP-05**: 旧 Mac 上的备份和 cronjob 清理确认

### 网络与域名

- [ ] **NET-01**: Cloudflare Tunnel 从 Mac 迁移到 r4s，域名解析指向 r4s
- [ ] **NET-02**: Nginx 端口映射（80/443）从 r4s 暴露，不与软路由端口冲突
- [ ] **NET-03**: pre-prod 域名路由（pre.class.noda.co.nz 等）在 r4s Nginx 上正常工作

### 切换与验证

- [ ] **SWITCH-01**: 迁移完成后全链路验证（浏览器 → Cloudflare → r4s Nginx → 各服务）
- [ ] **SWITCH-02**: Mac 上旧容器停止并清理，确认不再占用资源
- [ ] **SWITCH-03**: 回滚方案 — 如果 r4s 出问题，可以快速切回 Mac 运行

## v2 Requirements

### Deferred

- **MON-01**: r4s 容器资源监控告警（内存/CPU/磁盘使用率）
- **LOG-01**: 集中式日志收集（r4s 容器日志查询）
- **HA-01**: r4s 高可用方案（自动故障转移）
- **DISK-01**: 1TB 机械硬盘挂载（数据迁移到机械硬盘，SD 卡只存系统）

## Out of Scope

| Feature | Reason |
|---------|--------|
| r4s 上安装 Jenkins | 内存不够，Jenkins 留在 Mac |
| Docker Swarm/K8s | 单机部署，不需要编排工具 |
| 多架构镜像构建 | Mac M4 和 r4s 都是 ARM64，镜像直接复用 |
| iStoreOS 升级 | 不改变路由器固件版本，聚焦 Docker 迁移 |
| 数据库架构变更 | 只迁移位置，不改变数据库结构 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| ENV-01 | Phase 57 | Pending |
| ENV-02 | Phase 57 | Pending |
| ENV-03 | Phase 57 | Pending |
| ENV-04 | Phase 57 | Pending |
| ENV-05 | Phase 57 | Pending |
| INFRA-01 | Phase 58 | Pending |
| INFRA-02 | Phase 58 | Pending |
| INFRA-03 | Phase 58 | Pending |
| INFRA-04 | Phase 58 | Pending |
| INFRA-05 | Phase 58 | Pending |
| APP-01 | Phase 59 | Pending |
| APP-02 | Phase 59 | Pending |
| APP-03 | Phase 59 | Pending |
| APP-04 | Phase 59 | Pending |
| CICD-01 | Phase 60 | Pending |
| CICD-02 | Phase 60 | Pending |
| CICD-03 | Phase 60 | Pending |
| CICD-04 | Phase 60 | Pending |
| BACKUP-01 | Phase 61 | Pending |
| BACKUP-02 | Phase 61 | Pending |
| BACKUP-03 | Phase 61 | Pending |
| BACKUP-04 | Phase 61 | Pending |
| BACKUP-05 | Phase 61 | Pending |
| NET-01 | Phase 61 | Pending |
| NET-02 | Phase 61 | Pending |
| NET-03 | Phase 61 | Pending |
| SWITCH-01 | Phase 62 | Pending |
| SWITCH-02 | Phase 62 | Pending |
| SWITCH-03 | Phase 62 | Pending |

**Coverage:**
- v1.12 requirements: 29 total
- Mapped to phases: 29
- Unmapped: 0 ✓

---
*Requirements defined: 2026-05-17*
*Last updated: 2026-05-17 after initial definition*
