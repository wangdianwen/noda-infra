# Technology Stack: Pre-Prod Environment

**Project:** Noda Infrastructure - Pre-Prod Verification Environment
**Researched:** 2026-05-08
**Mode:** Ecosystem (Incremental Stack Additions)

## Design Principle

Pre-prod 环境的设计原则是 **复用现有基础设施、最小化增量变更、与现有 overlay + 蓝绿部署模式保持一致**。不引入新组件，仅扩展现有 Docker Compose/Nginx/Jenkins/Cloudflare 配置。

## Recommended Stack Changes

### 1. Docker Compose: Pre-Prod 应用层

**决策：不创建新的 Compose 文件，沿用现有 `docker-compose.app.yml` 的 `docker run` 蓝绿模式**

| 组件 | 现有 (Prod) | 增量 (Pre-Prod) | 变更方式 |
|------|-------------|-----------------|----------|
| noda-apps 容器 | `noda-apps-blue/green` via `docker run` | `noda-apps-preprod-blue/green` via `docker run` | 参数化 `manage-containers.sh`，通过 `SERVICE_NAME` 前缀区分 |
| Active Env 文件 | `/opt/noda/active-env` | `/opt/noda/active-env-preprod` | `ACTIVE_ENV_FILE` 环境变量 |
| Upstream 文件 | `upstream-findclass.conf` | `upstream-findclass-preprod.conf`（新建） | `UPSTREAM_CONF` 环境变量 |
| Env 模板 | `env-noda-apps.env` | `env-noda-apps-preprod.env`（新建） | `get_env_template()` 函数路径推导 |

**Why NOT 用 Docker Compose overlay：**

现有的 noda-apps 蓝绿部署完全基于 `docker run`（见 `manage-containers.sh` 的 `run_container()` 函数），不通过 `docker compose up` 管理。Pre-prod 应沿用同一套参数化脚本，通过环境变量区分 prod 和 preprod，而不是引入 Compose overlay。这与 v1.4 建立的蓝绿部署架构一致。

**为什么不需要新的 `docker-compose.preprod.yml`：**
- 现有应用层（noda-apps, noda-auth, noda-admin）全部通过 `manage-containers.sh` + `blue-green-deploy.sh` 管理，不通过 `docker compose up`
- Docker Compose 文件仅用于 `docker compose build` 构建镜像（`docker-compose.app.yml`）
- Pre-prod 使用相同镜像，构建逻辑不需要变更

### 2. PostgreSQL: 同实例新数据库

| 组件 | 配置 | 变更方式 |
|------|------|----------|
| `noda_preprod` 数据库 | 同一 PostgreSQL 17.9 实例 | 修改 `scripts/init-databases.sh`，在 `REQUIRED_DBS` 数组中添加 `"noda_preprod:Pre-production Application Database"` |
| 数据库用户 | 复用 `${POSTGRES_USER}` | 无变更 — 开发环境已验证同用户多数据库可行 |
| 连接字符串 | `postgresql://...@noda-infra-postgres-prod:5432/noda_preprod` | `env-noda-apps-preprod.env` 中配置 |

**Why NOT 独立 PostgreSQL 实例：**
- 单服务器资源受限，额外 PG 实例增加 ~300MB 基础内存
- pre-prod 验证需要真实数据结构，同实例不同库完全隔离（无 schema 泄漏风险）
- 备份系统已经按实例备份，无需额外配置

### 3. Keycloak: 同实例新 Realm

| 组件 | 配置 | 变更方式 |
|------|------|----------|
| `noda-preprod` realm | 同一 Keycloak 26.2.3 实例 | Keycloak Admin Console 手动创建或通过 realm export/import |
| `noda-frontend-preprod` client | redirect URI 指向 `pre.class.noda.co.nz` | 新建 client，配置 Google OAuth redirect URI |
| Google OAuth | 添加 `pre.class.noda.co.nz` 和 `pre.auth.noda.co.nz` 到 Authorized redirect URIs | Google Cloud Console 修改 OAuth 2.0 Client |

**Why NOT 独立 Keycloak 实例：**
- 内存开销（~1GB/实例），单服务器无法承受
- Keycloak 已有蓝绿部署，再加 pre-prod 实例使管理复杂度指数增长
- Realm 级别隔离已满足 pre-prod 验证需求（独立用户、独立 client、独立 session）

### 4. Nginx: 新增 Pre-Prod Server Blocks

**决策：新建 `conf.d/preprod.conf`，复用现有 snippets 模式**

| 文件 | 变更 |
|------|------|
| `config/nginx/snippets/upstream-findclass-preprod.conf`（新建） | Pre-prod upstream 变量，初始指向 `noda-apps-preprod-blue:3000` 等 |
| `config/nginx/conf.d/preprod.conf`（新建） | 4 个 server block，结构与 prod 相同但域名不同 |
| `config/nginx/conf.d/default.conf` | 无变更 — prod 配置保持不变 |
| `config/nginx/nginx.conf` | 无变更 — `include /etc/nginx/conf.d/*.conf` 自动加载新文件 |

**Pre-prod upstream 变量（`upstream-findclass-preprod.conf`）：**
```nginx
# noda-apps pre-prod upstream 变量
# 使用 resolver 127.0.0.11 动态解析 DNS
# 由 update_upstream() 在蓝绿切换时更新
set $findclass_preprod_upstream noda-apps-preprod-blue:3000;
set $www_preprod_upstream noda-apps-preprod-blue:3002;
set $auth_app_preprod_upstream noda-apps-preprod-blue:3004;
set $admin_preprod_upstream noda-apps-preprod-blue:3006;
set $admin_api_preprod_upstream noda-apps-preprod-blue:3011;
```

**Pre-prod server blocks 需包含的域名：**

| Server Block | 域名 | Upstream | 备注 |
|--------------|------|----------|------|
| FindClass pre-prod | `pre.class.noda.co.nz` | `$findclass_preprod_upstream` | 与 prod 结构相同 |
| Auth pre-prod | `pre.auth.noda.co.nz` | `$auth_app_preprod_upstream` + `$keycloak_upstream` | Keycloak 共享，auth app 用 pre-prod |
| WWW pre-prod | `pre.noda.co.nz` | `$www_preprod_upstream` | 无 `www.` 前缀 |
| Admin pre-prod | `pre.admin.noda.co.nz` | `$admin_preprod_upstream` | 仅内网（hosts 文件） |

**Why NOT 用 Nginx map 变量动态路由：**
- 现有模式是独立 server block + upstream include，团队已熟悉
- map 动态路由增加调试复杂度，pre-prod 域名有限（4个），不值得引入 map
- 每个环境的 upstream 文件独立管理，蓝绿切换互不干扰

**关键点：Auth pre-prod server block 的 Keycloak 路由**
- Keycloak 共享 prod 实例，`$keycloak_upstream` 不需要 preprod 版本
- pre-prod auth server block 的 `/` location 需要同时 `include upstream-keycloak.conf`（共享）和 `upstream-findclass-preprod.conf`（pre-prod 独有）
- 但 Keycloak realm 通过 `KEYCLOAK_REALM=noda-preprod` 环境变量区分，不需要独立 Keycloak upstream

### 5. Cloudflare Tunnel: 添加 Pre-Prod 域名路由

**决策：在 Cloudflare Dashboard 中添加 ingress 规则**

| 步骤 | 操作 | 位置 |
|------|------|------|
| 1 | 在 Cloudflare DNS 添加 CNAME 记录 | `pre.class.noda.co.nz` → tunnel UUID |
| 2 | 在 Cloudflare DNS 添加 CNAME 记录 | `pre.auth.noda.co.nz` → tunnel UUID |
| 3 | 在 Cloudflare DNS 添加 CNAME 记录 | `pre.noda.co.nz` → tunnel UUID |
| 4 | 在 Cloudflare Tunnel 配置添加 ingress 规则 | 三个域名 → `http://noda-nginx:80` |
| 5 | `pre.admin.noda.co.nz` 不经过 Cloudflare | 仅通过 `/etc/hosts` 内网访问 |

**Why 通过 Dashboard 而非本地 config.yml：**
- 实际运行使用 `--token` 模式（见 `supervisord.conf` 第23行），路由规则在 Cloudflare Dashboard 管理
- 本地 `config/cloudflare/config.yml` 仅作参考，未被 `cloudflared` 加载
- `--token` 模式下修改路由无需重启容器，Dashboard 修改即时生效

**CNAME 记录格式：**
```
pre.class   CNAME  9cab5df3-a546-48fb-9dc5-eacb48c56ff8.cfargotunnel.com
pre.auth    CNAME  9cab5df3-a546-48fb-9dc5-eacb48c56ff8.cfargotunnel.com
pre         CNAME  9cab5df3-a546-48fb-9dc5-eacb48c56ff8.cfargotunnel.com
```

### 6. Jenkins Pipeline: 参数化 Pipeline + Promote

**决策：双 Pipeline 模式（而非单 Pipeline 参数化）**

| Pipeline | 文件 | 功能 |
|----------|------|------|
| noda-apps-preprod | `Jenkinsfile.noda-apps-preprod`（新建） | Build -> Test -> Deploy Pre-prod -> Health -> Switch -> Verify |
| noda-apps-promote | `Jenkinsfile.noda-apps-promote`（新建） | Read Pre-prod Image -> Deploy Prod -> Health -> Switch -> Verify -> CDN Purge |
| noda-apps（现有） | `Jenkinsfile.noda-apps`（不变） | 直接部署到 prod（紧急 hotfix 用） |

**Why 双 Pipeline 而非单 Pipeline 参数化：**

| 考量 | 双 Pipeline | 单 Pipeline 参数化 |
|------|-------------|-------------------|
| 可读性 | 每个文件职责单一，易于审查 | 需要 `when` 条件分支，逻辑复杂 |
| 安全性 | Promote Pipeline 可独立配置权限 | prod 和 pre-prod 权限混合 |
| 构建历史 | Pre-prod 和 Promote 构建历史独立可追溯 | 所有构建混在一个历史中 |
| 复用 | 共享 `pipeline-stages.sh` 函数 | 函数内部需要 `if/else` 分支 |
| 风险 | 低 — 新增文件，不修改现有 Pipeline | 高 — 修改生产 Pipeline，可能引入回归 |

**Promote Pipeline 核心逻辑：**
```
1. 读取 /opt/noda/active-env-preprod 确认 pre-prod 活跃环境
2. docker inspect 获取 pre-prod 活跃容器的镜像 digest
3. 用同一镜像执行 prod 蓝绿部署（调用 blue-green-deploy.sh）
4. 不重新构建，直接 docker run 使用 pre-prod 验证过的镜像
```

**Jenkins Job 注册：**
- 新建 `scripts/jenkins/init.groovy.d/10-pipeline-job-noda-apps-preprod.groovy`
- 新建 `scripts/jenkins/init.groovy.d/13-pipeline-job-noda-apps-promote.groovy`
- 复用现有 `03-pipeline-job.groovy` 的模板结构

### 7. 蓝绿部署脚本: 参数化扩展

**决策：现有 `manage-containers.sh` 已完全参数化，仅需 wrapper 脚本**

| Wrapper | 职责 | 环境变量覆盖 |
|---------|------|-------------|
| `scripts/deploy-preprod.sh`（新建） | Pre-prod 蓝绿部署入口 | `SERVICE_NAME=noda-apps-preprod`, `ACTIVE_ENV_FILE=/opt/noda/active-env-preprod`, `UPSTREAM_CONF=.../upstream-findclass-preprod.conf` |
| `scripts/promote-to-prod.sh`（新建） | Promote 入口 | 读取 pre-prod 镜像 + 调用现有 prod 蓝绿部署 |

**为什么不需要修改 `manage-containers.sh`：**
- `run_container()` 已通过环境变量参数化（SERVICE_NAME, SERVICE_PORT, ACTIVE_ENV_FILE 等）
- `update_upstream()` 已通过 `UPSTREAM_CONF` 环境变量参数化
- `get_env_template()` 通过 SERVICE_NAME 自动推导 env 模板路径
- Docker labels 已参数化（`noda.blue-green=${env}`, `com.docker.compose.service=${SERVICE_NAME}`）

**需要修改的唯一一处：`update_upstream()` 函数中的 noda-apps upstream 内容**

当前 `update_upstream()` 硬编码了 prod 的 upstream 变量名（`$findclass_upstream`, `$www_upstream` 等）。Pre-prod 需要不同的变量名（`$findclass_preprod_upstream` 等）。解决方案：

```bash
# 方案：通过 UPSTREAM_VARS_PREFIX 环境变量控制变量名前缀
UPSTREAM_VARS_PREFIX="${UPSTREAM_VARS_PREFIX:-}"
# prod: prefix 为空 → set $findclass_upstream ...
# preprod: prefix=preprod_ → set $findclass_preprod_upstream ...
```

### 8. Env 模板: Pre-Prod 环境变量

**新建 `docker/env-noda-apps-preprod.env`：**

```bash
NODE_ENV=production
DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@noda-infra-postgres-prod:5432/noda_preprod
DIRECT_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@noda-infra-postgres-prod:5432/noda_preprod
KEYCLOAK_URL=https://pre.auth.noda.co.nz
KEYCLOAK_INTERNAL_URL=http://noda-infra-nginx
KEYCLOAK_REALM=noda-preprod
KEYCLOAK_CLIENT_ID=noda-frontend-preprod
# ... 其余与 prod 相同
```

**Docker 构建参数（Dockerfile.noda-apps）：**
```dockerfile
ARG NEXT_PUBLIC_KEYCLOAK_URL=https://pre.auth.noda.co.nz
ARG NEXT_PUBLIC_KEYCLOAK_REALM=noda-preprod
ARG NEXT_PUBLIC_KEYCLOAK_CLIENT_ID=noda-frontend-preprod
```

注意：构建时参数和运行时环境变量都需要修改。`NEXT_PUBLIC_*` 变量在 build 阶段写入 JS 文件，运行时变量用于 SSR 服务端。

## Alternatives Considered

| 类别 | 推荐 | 替代方案 | 不选的原因 |
|------|------|---------|-----------|
| 应用容器管理 | `docker run` 参数化 | Docker Compose 新 overlay | 现有蓝绿架构基于 docker run，不改模式 |
| 数据库隔离 | 同实例新数据库 | 独立 PostgreSQL 容器 | 单服务器资源受限，~300MB 内存增量不可接受 |
| 认证隔离 | 同 Keycloak 新 Realm | 独立 Keycloak 实例 | 同上，~1GB 内存增量，且蓝绿管理复杂度翻倍 |
| Nginx 配置 | 新建 preprod.conf | map 变量动态路由 | 现有模式更简单可调试，4 个域名不值得用 map |
| Pipeline 架构 | 双 Pipeline 独立文件 | 单 Pipeline 参数化 | 安全性、可读性、构建历史追踪 |
| DNS 管理 | Cloudflare Dashboard | 本地 config.yml | 实际运行使用 --token 模式，本地文件不生效 |
| 镜像管理 | Promote 复用 pre-prod 镜像 | 重新构建 prod 镜像 | "Build once, deploy many" 原则，确保验证的镜像就是上线的镜像 |

## What NOT to Add

| 不添加 | 原因 | 用现有方案替代 |
|--------|------|--------------|
| Docker Compose profiles | 项目已用 overlay + docker run 模式，profiles 增加不必要的概念 | 环境变量参数化 |
| Docker Compose `include` 指令 | 仅当多个 Compose 文件需要合并时有用；本项目 noda-infra 和 noda-apps 已通过 external network 通信 | 保持现有 external network 模式 |
| 独立网络（preprod-network） | 网络隔离在单服务器上无安全价值，pre-prod 需要访问共享 PG/Keycloak | 共享 `noda-network` |
| Traefik / 自动服务发现 | 需要替代现有 Nginx 架构，改动范围过大 | Nginx 手动 server block |
| Jenkins Shared Libraries | 项目规模小（~3 个 Pipeline），引入 Shared Libraries 是过度工程化 | 每个 Jenkinsfile 独立管理 |
| Jenkins Promoted Builds Plugin | 已被 Pipeline `input` 步骤替代，且我们用 Promote Pipeline 模式 | 独立 Promote Pipeline + `input` 门禁 |
| Docker Registry（私有） | 单服务器本地构建，镜像不跨机器传输 | `docker tag` 本地管理 |

## Version Compatibility

| 组件 | 现有版本 | Pre-prod 增量 | 兼容性 |
|------|---------|-------------|--------|
| Docker Compose | v2（已安装） | 无变更 | 完全兼容 |
| PostgreSQL | 17.9 | 新增数据库 | 同实例，无版本问题 |
| Keycloak | 26.2.3 | 新增 realm | 同实例，无版本问题 |
| Nginx | 1.25-alpine | 新增配置文件 | `include *.conf` 自动加载 |
| Jenkins LTS | 2.541.3 | 新增 Pipeline Job | 标准 Declarative Pipeline |
| Cloudflare Tunnel | `cloudflared` latest | 新增 DNS 记录 + ingress 规则 | Dashboard 操作，无版本依赖 |
| `manage-containers.sh` | 当前 | `update_upstream()` 增加变量名前缀参数 | 向后兼容（默认值保持 prod 行为） |

## Installation / Setup Steps

```bash
# ============================================
# Pre-Prod 环境搭建步骤（按顺序执行）
# ============================================

# 1. 创建数据库
bash scripts/init-databases.sh  # 添加 noda_preprod 到 REQUIRED_DBS 后执行

# 2. 创建 Keycloak realm
# 在 Keycloak Admin Console 手动操作：
#   - 创建 noda-preprod realm
#   - 创建 noda-frontend-preprod client
#   - 配置 Google OAuth redirect URI

# 3. 配置 Nginx
# 创建 upstream 和 server block 文件
# docker exec noda-infra-nginx nginx -t && docker exec noda-infra-nginx nginx -s reload

# 4. 配置 Cloudflare
# 在 Dashboard 添加 CNAME 记录 + Tunnel ingress 规则

# 5. 创建 env 模板
# 创建 docker/env-noda-apps-preprod.env

# 6. 注册 Jenkins Job
bash scripts/jenkins/apply-noda-platform-jobs.sh

# 7. 首次部署 Pre-prod
# Jenkins -> noda-apps-preprod -> Build Now
```

## File Changes Summary

| 文件 | 操作 | 说明 |
|------|------|------|
| `scripts/init-databases.sh` | 修改 | 添加 `noda_preprod` 到 REQUIRED_DBS |
| `config/nginx/snippets/upstream-findclass-preprod.conf` | 新建 | Pre-prod upstream 变量 |
| `config/nginx/conf.d/preprod.conf` | 新建 | Pre-prod server blocks（4 个域名） |
| `docker/env-noda-apps-preprod.env` | 新建 | Pre-prod 环境变量模板 |
| `scripts/manage-containers.sh` | 修改 | `update_upstream()` 增加 `UPSTREAM_VARS_PREFIX` 参数 |
| `scripts/deploy-preprod.sh` | 新建 | Pre-prod 蓝绿部署 wrapper |
| `scripts/promote-to-prod.sh` | 新建 | Promote to prod wrapper |
| `jenkins/Jenkinsfile.noda-apps-preprod` | 新建 | Pre-prod 部署 Pipeline |
| `jenkins/Jenkinsfile.noda-apps-promote` | 新建 | Promote to prod Pipeline |
| `scripts/jenkins/init.groovy.d/10-pipeline-job-noda-apps-preprod.groovy` | 新建 | Jenkins Job 注册 |
| `scripts/jenkins/init.groovy.d/13-pipeline-job-noda-apps-promote.groovy` | 新建 | Jenkins Job 注册 |

## Sources

- [Docker Compose Override Strategies](https://oneuptime.com/blog/post/2026-01-30-docker-compose-override-strategies/view) — overlay 模式验证，MEDIUM confidence
- [Docker Compose Include Directive](https://docs.docker.com/reference/compose-file/include/) — 确认不需要 include，本项目用 external network，HIGH confidence
- [Jenkins Deployment Patterns](https://www.jenkins.io/doc/pipeline/tour/deployment/) — Pipeline promotion 模式，HIGH confidence
- [Jenkins Build Once Deploy Many](https://www.reddit.com/r/devops/comments/gurei8/jenkins_build_once_deploy_many/) — Promote 复用镜像的社区最佳实践，MEDIUM confidence
- [Jenkins Multi-Environment Pipeline](https://kiranpawar.hashnode.dev/setting-up-a-jenkins-cicd-pipeline-for-multi-environment-deployment-devqaprod) — DEV/QA/Prod 多环境 Pipeline 模式，MEDIUM confidence
- 项目源码: `docker/docker-compose.app.yml`, `config/nginx/conf.d/default.conf`, `scripts/manage-containers.sh`, `scripts/blue-green-deploy.sh`, `jenkins/Jenkinsfile.noda-apps`, `deploy/supervisord.conf`, `config/cloudflare/config.yml` — 现有架构分析，HIGH confidence
