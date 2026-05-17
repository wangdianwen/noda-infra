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
- **v1.8 密钥管理集中化** -- Phases 39-42 (shipped 2026-04-19)
- **v1.9 部署后磁盘清理自动化** -- Phases 43-46 (shipped 2026-04-20) -- [详情](milestones/v1.9-MILESTONE.md)
- **v1.10 Docker 镜像瘦身优化** -- Phases 47-52 (shipped 2026-04-21) -- [详情](milestones/v1.10-ROADMAP.md)
- **v1.11 Pre-Prod 验证环境 + 蓝绿移除** -- Phases 53-56 (shipped 2026-05-10) -- [详情](milestones/v1.11-ROADMAP.md)
- **v1.12 迁移到 iStoreOS (r4s)** -- Phases 57-62 (in progress) -- [详情](milestones/v1.12-ROADMAP.md)

## Phases

### v1.12: 迁移到 iStoreOS (r4s)

- [ ] **Phase 57: 环境准备** - r4s Docker 网络与资源限制配置
- [ ] **Phase 58: 基础设施迁移** - PostgreSQL + Keycloak + Nginx + noda-ops 迁移
- [ ] **Phase 59: 应用迁移** - findclass-ssr + noda-admin + noda-auth 迁移
- [ ] **Phase 60: CI/CD 改造** - Jenkins SSH 远程部署到 r4s
- [ ] **Phase 61: 备份与网络迁移** - cronjob + B2 + Cloudflare Tunnel 迁移
- [ ] **Phase 62: 切换与验证** - 全链路验证 + Mac 清理 + 回滚方案

## Phase Details

### Phase 57: 环境准备
**Goal**: r4s 上 Docker 运行环境就绪（网络、Swap、内存限制、SSH 部署）
**Depends on**: Nothing（首阶段）
**Requirements**: ENV-01, ENV-02, ENV-03, ENV-04, ENV-05
**Success Criteria** (what must be TRUE):
  1. r4s 上创建 noda-network 独立网桥，所有容器加入该网络
  2. r4s 上创建 2GB Swap 文件，`swapon --show` 显示 Swap 已启用
  3. 所有 Docker Compose 服务配置内存限制（deploy.resources.limits），总计不超过 3.5 GiB
  4. Mac 可以 SSH 免密登录到 r4s（jenkins 用户专用密钥，无需交互）
  5. iStoreOS Docker 开机自启已配置，重启后容器自动恢复
Plans:
- [ ] 57-01-PLAN.md — r4s 初始化脚本集（网络/Swap/SSH/Docker 自启验证）
- [ ] 57-02-PLAN.md — Docker Compose r4s overlay + 环境变量模板

### Phase 58: 基础设施迁移
**Goal**: PostgreSQL、Keycloak、Nginx、noda-ops 容器在 r4s 上运行，数据完整迁移
**Depends on**: Phase 57
**Requirements**: INFRA-01, INFRA-02, INFRA-03, INFRA-04, INFRA-05
**Success Criteria** (what must be TRUE):
  1. PostgreSQL 数据从 Mac 迁移到 r4s，`pg_restore` 验证表和数据完整
  2. Keycloak realm/主题/客户端配置迁移到 r4s，用户可以正常登录
  3. Nginx 反向代理在 r4s 上运行，路由规则与 Mac 环境一致
  4. noda-ops 容器在 r4s 上运行，Cloudflare Tunnel 连接正常
  5. 所有服务加入 noda-network 网络，容器间可以互相访问
**Plans**: TBD

### Phase 59: 应用迁移
**Goal**: findclass-ssr、noda-admin、noda-auth 应用容器在 r4s 上运行
**Depends on**: Phase 58
**Requirements**: APP-01, APP-02, APP-03, APP-04
**Success Criteria** (what must be TRUE):
  1. findclass-ssr prod 容器在 r4s 上运行，健康检查通过
  2. findclass-ssr pre-prod 容器在 r4s 上运行，共享 prod 基础设施（PostgreSQL/Keycloak）
  3. noda-admin 管理后台在 r4s 上运行，可以正常访问
  4. noda-auth 认证应用在 r4s 上运行，OAuth 登录正常
**Plans**: TBD
**UI hint**: yes

### Phase 60: CI/CD 改造
**Goal**: Jenkins Pipeline 通过 SSH 远程部署到 r4s，镜像构建在 Mac 完成后传输
**Depends on**: Phase 59
**Requirements**: CICD-01, CICD-02, CICD-03, CICD-04
**Success Criteria** (what must be TRUE):
  1. Jenkinsfile.apps 改造完成，通过 SSH 在 r4s 上执行 `docker compose` 命令
  2. Docker 镜像在 Mac 上构建后，通过 `docker save/load` 传输到 r4s
  3. Jenkins Pipeline 验证通过：构建 → 传输镜像 → SSH 远程部署 → 健康检查 → 完成
  4. Jenkinsfile.infra 同步改造，基础设施部署通过 SSH 远程执行
**Plans**: TBD

### Phase 61: 备份与网络迁移
**Goal**: 备份 cronjob 和 Cloudflare Tunnel 在 r4s 上运行，域名解析指向 r4s
**Depends on**: Phase 60
**Requirements**: BACKUP-01, BACKUP-02, BACKUP-03, BACKUP-04, BACKUP-05, NET-01, NET-02, NET-03
**Success Criteria** (what must be TRUE):
  1. pg_dump 每日备份 cronjob 在 r4s noda-ops 容器中正常运行
  2. B2 云备份上传从 r4s 正常执行，备份文件可从 B2 下载验证
  3. Doppler 密钥每日备份 cronjob 在 r4s 上运行
  4. 周验证测试 cronjob 在 r4s 上运行，验证备份可恢复
  5. Mac 上旧备份和 cronjob 已清理，不再占用资源
  6. Cloudflare Tunnel 从 Mac 迁移到 r4s，域名解析指向 r4s
  7. Nginx 端口映射（80/443）从 r4s 暴露，不与软路由端口冲突
  8. pre-prod 域名路由在 r4s Nginx 上正常工作
**Plans**: TBD

### Phase 62: 切换与验证
**Goal**: 迁移完成，生产流量切换到 r4s，Mac 清理干净，回滚方案就绪
**Depends on**: Phase 61
**Requirements**: SWITCH-01, SWITCH-02, SWITCH-03
**Success Criteria** (what must be TRUE):
  1. 全链路验证通过：浏览器 → Cloudflare → r4s Nginx → 各服务，所有功能正常
  2. Mac 上旧容器停止并清理，Docker 资源释放（镜像、容器、卷、网络）
  3. 回滚方案验证通过：可以快速切回 Mac 运行（所有脚本和配置保留）
**Plans**: TBD

## Progress Table

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 57. 环境准备 | 0/2 | Planning | - |
| 58. 基础设施迁移 | 0/0 | Not started | - |
| 59. 应用迁移 | 0/0 | Not started | - |
| 60. CI/CD 改造 | 0/0 | Not started | - |
| 61. 备份与网络迁移 | 0/0 | Not started | - |
| 62. 切换与验证 | 0/0 | Not started | - |

**Total Progress:** 0/29 requirements complete
