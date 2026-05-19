# Roadmap: Noda Infrastructure - v1.12 迁移到 iStoreOS (r4s)

**里程碑**: v1.12
**目标**: 将所有 Docker 服务从 Mac 迁移到 r4s (iStoreOS)，Jenkins 保留在 Mac 通过 SSH 远程部署
**阶段数**: 5
**粒度**: fine
**覆盖率**: 24/24 requirements mapped

## Phases

- [x] **Phase 58: 基础设施迁移** - PostgreSQL、Keycloak、Nginx、noda-ops 容器迁移到 r4s (completed 2026-05-17)
- [x] **Phase 59: 应用服务迁移** - findclass-ssr、noda-admin、noda-auth 容器迁移到 r4s (completed 2026-05-18)
- [ ] **Phase 60: CI/CD 改造** - Jenkins Pipeline 改造为 SSH 远程部署
- [x] **Phase 61: 备份与网络迁移** - cronjob 和 Cloudflare Tunnel 迁移到 r4s (completed 2026-05-19)
- [ ] **Phase 62: 切换与验证** - 全链路验证、清理和回滚方案

## Phase Details

### Phase 58: 基础设施迁移

**目标**: 所有基础设施容器（PostgreSQL、Keycloak、Nginx、noda-ops）在 r4s 上正常运行，数据完整迁移

**依赖**: Phase 57（环境准备已完成）

**需求**: INFRA-01, INFRA-02, INFRA-03, INFRA-04, INFRA-05

**Success Criteria** (必须达成):

1. PostgreSQL 数据从 Mac 完整迁移到 r4s，无数据丢失（表结构、数据、序列都验证通过）
2. Keycloak 在 r4s 上启动，所有 realm、客户端、用户配置与 Mac 环境一致
3. Nginx 在 r4s 上正常监听 80/443 端口，upstream 配置指向 r4s 容器
4. noda-ops 容器在 r4s 上运行，Cloudflare Tunnel 能连接到 r4s
5. 所有基础设施容器加入 noda-network 外部网络，容器间可通过 DNS 互相访问

Plans:

- [x] 58-01-PLAN.md — PostgreSQL 环境验证、停服备份、SSH 管道数据迁移、完整性验证
- [x] 58-02-PLAN.md — Keycloak docker run 启动 + Nginx compose up 启动及代理验证
- [x] 58-03-PLAN.md — noda-ops 镜像构建传输 + 启动验证 + 全部基础设施服务就绪确认

### Phase 59: 应用服务迁移

**目标**: 所有应用容器（findclass-ssr prod/pre-prod、noda-admin、noda-auth）在 r4s 上正常运行

**依赖**: Phase 58

**需求**: APP-01, APP-02, APP-03, APP-04

**Success Criteria** (必须达成):

1. findclass-ssr prod 容器在 r4s 上启动，HTTP 健康检查返回 200
2. findclass-ssr pre-prod 容器在 r4s 上启动，可连接 noda_preprod 数据库和 noda-preprod realm
3. noda-admin 管理后台在 r4s 上启动，可正常访问
4. noda-auth 认证应用在 r4s 上启动，OAuth 登录流程正常
5. 所有应用容器通过 Nginx 反向代理可从外部访问（暂未切换 Cloudflare）

Plans:
**Wave 1**

- [x] 59-01-PLAN.md — 配置 r4s 应用服务部署环境（扩展 r4s overlay、删除未使用文件、传输 monorepo 镜像）

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 59-02-PLAN.md — 启动 prod 应用容器并验证所有服务（数据库连接、健康检查、nginx 路由）

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 59-03-PLAN.md — 启动 pre-prod 应用容器并验证数据库隔离和访问

**Cross-cutting constraints:**

- 容器健康检查通过（docker inspect 返回 healthy）
- HTTP 健康检查返回 200（/api/health 端点）

### Phase 60: CI/CD 改造

**目标**: Jenkins Pipeline 从本地 docker compose 改为 SSH 远程部署到 r4s

**依赖**: Phase 59

**需求**: CICD-01, CICD-02, CICD-03, CICD-04

**Success Criteria** (必须达成):

1. Jenkinsfile 应用部署 Pipeline 改造为 SSH 远程执行 docker compose 命令
2. Docker 镜像在 Mac 构建后通过 docker save/load 传输到 r4s 并加载成功
3. Jenkinsfile 基础设施部署 Pipeline 同步改造为 SSH 远程部署
4. SSH 远程部署 Pipeline 端到端验证通过（构建 → 传输 → 部署 → 健康检查）

Plans:
**Wave 1**

- [ ] 60-01-PLAN.md — 创建 SSH 远程操作封装层（remote-ops.sh）+ pipeline-stages.sh/health.sh 支持框架

**Wave 2** *(blocked on Wave 1 completion)*

- [ ] 60-02-PLAN.md — 改造应用部署 Pipeline 函数（apps Pipeline）支持 r4s 远程部署
- [ ] 60-03-PLAN.md — 改造基础设施部署 Pipeline 函数（infra Pipeline）支持 r4s 远程部署

**Wave 3** *(blocked on Wave 2 completion)*

- [ ] 60-04-PLAN.md — Jenkins 配置 + Jenkinsfile 改造 + r4s 仓库同步 + 端到端验证

### Phase 61: 备份与网络迁移

**目标**: 所有备份 cronjob 和 Cloudflare Tunnel 从 Mac 迁移到 r4s

**依赖**: Phase 60

**需求**: BACKUP-01, BACKUP-02, BACKUP-03, BACKUP-04, BACKUP-05, NET-01, NET-02, NET-03

**Success Criteria** (必须达成):

1. pg_dump 每日备份在 r4s noda-ops 容器中正常运行，备份文件可验证
2. B2 云备份上传从 r4s 正常执行，备份文件在 B2 可查询到
3. Doppler 密钥每日备份 cronjob 在 r4s 上运行
4. 周验证测试 cronjob 在 r4s 上运行
5. Mac 上的旧备份和 cronjob 已清理确认
6. Cloudflare Tunnel 在 r4s 上运行，域名解析指向 r4s 公网 IP
7. Nginx 端口映射（80/443）在 r4s 上正常工作，不与软路由端口冲突
8. pre-prod 域名路由在 r4s Nginx 上正常工作

**Plans**: 4 plans

**Wave 1** (并行)
- [x] 61-01-PLAN.md — 验证 r4s 备份 cronjob（pg_dump + B2 + Doppler + 周验证）
- [x] 61-02-PLAN.md — 验证 Cloudflare Tunnel + Nginx 端口映射 + pre-prod 路由

**Wave 2** *(blocked on Wave 1)*
- [x] 61-03-PLAN.md — 停止 Mac 旧 noda-ops 容器，确认 r4s 独立运行

**Gap Closure**
- [x] 61-04-PLAN.md — 修复验证缺口（config.sh、DOPPLER_TOKEN、pre-prod hosts、周验证测试）

### Phase 62: 切换与验证

**目标**: 迁移完成后的全链路验证、清理和回滚方案确认

**依赖**: Phase 61

**需求**: SWITCH-01, SWITCH-02, SWITCH-03

**Success Criteria** (必须达成):

1. 全链路验证通过：浏览器 → Cloudflare → r4s Nginx → 各服务（prod + pre-prod）
2. Mac 上旧容器已停止并清理，不再占用端口和资源
3. 回滚方案已验证：如果 r4s 出问题，可以快速切回 Mac 运行

**Plans**: TBD

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 58. 基础设施迁移 | 3/3 | Complete    | 2026-05-17 |
| 59. 应用服务迁移 | 3/3 | Complete    | 2026-05-18 |
| 60. CI/CD 改造 | 4/4 | Complete    | 2026-05-19 |
| 61. 备份与网络迁移 | 4/4 | Complete    | 2026-05-19 |
| 62. 切换与验证 | 0/3 | Not started | - |

## Dependencies

```
Phase 57 (环境准备) ✅ 已完成
    ↓
Phase 58 (基础设施迁移)
    ↓
Phase 59 (应用服务迁移)
    ↓
Phase 60 (CI/CD 改造)
    ↓
Phase 61 (备份与网络迁移)
    ↓
Phase 62 (切换与验证)
```

## Milestone Context

**v1.12 迁移到 iStoreOS (r4s)**

将所有 Docker 服务从 Mac 迁移到 r4s (iStoreOS)，Jenkins 保留在 Mac 通过 SSH 远程部署。r4s 是 FriendlyARM NanoPi R4S，6核 ARM64，3.77 GiB RAM，64GB SD卡，运行 iStoreOS 24.10.6。

**关键约束**:

- Mac M4 和 r4s 都是 ARM64 — Docker 镜像可直接复用
- Jenkins 留在 Mac — 通过 SSH 远程部署到 r4s
- 迁移必须零数据丢失（PostgreSQL 数据迁移）
- 迁移必须零停机（r4s 先启动，再切换 Cloudflare）

**已完成的准备** (Phase 57):

- r4s 上 Docker 独立网桥创建（noda-network）
- r4s 上 Swap 文件创建（2GB OOM 缓冲）
- 所有容器内存限制配置
- Mac ↔ r4s SSH 免密部署密钥配置
- Docker Compose r4s overlay 文件创建

---
*Roadmap created: 2026-05-17*
*Last updated: 2026-05-19*
