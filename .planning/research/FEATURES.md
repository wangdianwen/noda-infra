# Feature Landscape

**Domain:** 基础设施运维 -- 本地开发环境 + 基础设施 CI/CD Pipeline 扩展
**Researched:** 2026-04-17
**Confidence:** MEDIUM-HIGH（基于代码库深度分析 + 领域知识）
**Supersedes:** v1.4 FEATURES.md（CI/CD 零停机部署，已全部实现）

---

## Table Stakes

缺少会让系统不完整、不安全或不符合项目架构方向的功能。

| # | Feature | Why Expected | Complexity | Notes |
|---|---------|--------------|------------|-------|
| T1 | **宿主机 PostgreSQL 安装与配置** | 开发环境用 Docker 跑开发数据库是反模式（启动慢、资源浪费、端口冲突）；项目目标是 Docker Compose 精简为纯线上业务 | Low | Homebrew `brew install postgresql@17`，版本与生产对齐；需要创建 `noda_dev`、`keycloak_dev`、`jenkins` 三个数据库和对应用户 |
| T2 | **Jenkins H2 → 本地 PG 迁移** | H2 是嵌入式数据库，Jenkins 官方文档明确标注 "not recommended for production"；数据丢失风险高，不支持并发访问；项目核心价值 "数据库永不丢失" 应覆盖 Jenkins 数据 | Med | 需要停止 Jenkins、创建 PG 数据库和用户、配置 JDBC 连接、验证；项目已有 `init-databases.sh` 模式可复用 |
| T3 | **移除 postgres-dev / keycloak-dev 容器** | `docker-compose.dev.yml` 中 5433 端口的 postgres-dev 和 18080 端口的 keycloak-dev 占用资源；本地 PG 安装后完全多余；与 "Docker 纯线上业务" 目标矛盾 | Low | 删除 `docker-compose.dev.yml` 中的两个服务定义；`init-dev/*.sql` 逻辑迁移到本地 PG 初始化脚本 |
| T4 | **统一基础设施 Pipeline** | 当前只有应用层 Pipeline（findclass-ssr、noda-site），基础设施变更完全手动 `deploy-infrastructure-prod.sh`；这是运维自动化的核心缺失 | Med | 参考 `Jenkinsfile` 的 9 阶段结构，`choice` 参数选择服务；参数化分发到服务特定逻辑 |
| T5 | **Keycloak 蓝绿部署** | 生产环境 Keycloak 升级/重启当前会导致认证中断（`deploy-infrastructure-prod.sh` 先 `down` 再 `up`）；蓝绿是零停机的标准做法，项目已在 findclass-ssr/noda-site 上验证可行 | High | 复用 findclass-ssr 蓝绿框架（manage-containers.sh + upstream include 切换），但 Keycloak 有 session 状态和 schema migration 需要特殊处理 |
| T6 | **部署前自动备份 + 健康检查 + 回滚** | 基础设施 Pipeline 的核心安全网；`deploy-infrastructure-prod.sh` 已实现但 Pipeline 中缺失；与核心价值 "数据库永不丢失" 对齐 | Low | 复用 `check_backup_freshness()`、`wait_container_healthy()`、`http_health_check()` |
| T7 | **人工确认门禁** | 基础设施变更风险高（尤其是 Keycloak/PostgreSQL），必须有人确认再执行不可逆操作 | Low | Jenkins `input` 步骤，与现有 Pipeline 模式一致 |

## Differentiators

提升运维效率和系统可靠性的增值功能。

| # | Feature | Value Proposition | Complexity | Notes |
|---|---------|-------------------|------------|-------|
| D1 | **本地开发环境一键安装脚本** | 新开发者或新机器上 5 分钟搭建完整开发环境（PG + Node.js + pnpm + 环境变量 + 数据库初始化），降低上手门槛 | Med | 类似 `setup-jenkins.sh` 的子命令模式；需要检测 macOS/Linux 差异、检测已安装组件、幂等操作 |
| D2 | **服务特定的 Pipeline 阶段智能分发** | 不同基础设施服务有不同的更新策略（postgres 需要 dump/restore 测试，keycloak 需要蓝绿切换，nginx 只需 reload），参数化 Pipeline 需要智能分发避免巨型 if-else | Med | `when` 条件基于 `params.SERVICE_NAME` 选择执行路径；用函数分发模式，每个服务一个 `pipeline_deploy_<service>()` 函数 |
| D3 | **开发数据库种子数据自动化** | 本地 PG 初始化时自动创建表结构和测试数据，开发者无需手动操作 | Low | 复用现有 `init-dev/02-seed-data.sql`，但需要等 Prisma migration 先执行；脚本应检测表是否存在再插入 |
| D4 | **Jenkins PG 数据纳入 B2 备份体系** | Jenkins 迁移到 PG 后，Jenkins 数据应纳入现有的自动备份流程，避免成为盲区 | Low | `backup-postgres.sh` 中添加 jenkins 数据库到备份列表；恢复脚本同步更新 |
| D5 | **Pipeline 服务状态仪表板** | Jenkins Stage View 中展示所有基础设施服务状态，替代手动 `docker ps` | Low | Pipeline preflight 阶段输出结构化状态信息；Jenkins 内置 stage view 已足够 |

## Anti-Features

明确不构建的功能。

| # | Anti-Feature | Why Avoid | What to Do Instead |
|---|-------------|-----------|-------------------|
| A1 | **外部 Infinispan 集群** | 项目是单服务器架构，引入 Infinispan 集群是过度工程化；Keycloak 用户量小，session 丢失的影响极低 | 接受 Keycloak 切换时短暂 session 丢失（用户重新登录一次）；在 Pipeline Switch 阶段添加警告日志 |
| A2 | **Docker Compose profiles** | 项目已使用 overlay 模式（base + dev + prod），profiles 是另一套机制，混用增加复杂度 | 继续使用 overlay 模式；移除 dev 容器后 docker-compose.dev.yml 简化为仅 nginx 开发配置 |
| A3 | **PostgreSQL 主从复制** | 单服务器架构不需要复制；增加运维复杂度 | 依赖 B2 备份 + 本地备份恢复机制 |
| A4 | **Jenkins Shared Libraries** | 项目只有 3-4 个 Pipeline（findclass-ssr、noda-site、infra），Shared Libraries 是过度抽象 | 直接在 Jenkinsfile 中写逻辑，通过 `source scripts/pipeline-stages.sh` 复用函数 |
| A5 | **动态服务发现（Extended Choice Parameter 插件）** | 自动检测可部署服务列表需要额外 Jenkins 插件，增加依赖 | 使用原生 `choice` 参数静态列出 4 个服务 |
| A6 | **本地 Keycloak 安装** | 开发环境直接用生产 Keycloak 测试，本地安装 Keycloak 增加维护成本 | PROJECT.md 已明确列为 Out of Scope |
| A7 | **PostgreSQL 蓝绿部署** | 数据库状态在 Docker volume 上，蓝绿无意义（两个容器挂同一个卷 = 同一个数据库） | 滚动更新（停止 → 备份 → 启动新版本）+ 备份恢复机制；短暂停机可接受 |
| A8 | **Jenkins Configuration as Code (JCasC)** | 单服务器单一 Jenkinsfile 场景下，JCasC 配置比手动初始化更复杂 | 保持 groovy init 脚本自动化 + 手动 UI 配置 |

## Feature Dependencies

依赖关系决定实现顺序。

```
[T1: 宿主机 PG 安装]
    |
    +--> [T2: Jenkins H2 → PG 迁移]（依赖本地 PG 可用 + jenkins 数据库已创建）
    |
    +--> [T3: 移除 postgres-dev 容器]（依赖本地 PG 替代开发数据库）
    |      |
    |      +--> [T3b: 移除 keycloak-dev 容器]（依赖 postgres-dev 移除，keycloak-dev 连接 postgres-dev）
    |
    +--> [D3: 种子数据自动化]（依赖本地 PG 初始化流程稳定）
    |
    +--> [D4: Jenkins PG 备份]（依赖 T2 完成）

[蓝绿部署框架]（已存在: manage-containers.sh + upstream include）
    |
    +--> [T5: Keycloak 蓝绿部署]
    |      |
    |      +--> [upstream-keycloak.conf 动态切换]（类似 upstream-findclass.conf）
    |      +--> [env-keycloak.env 模板]（类似 env-findclass-ssr.env）
    |      +--> [ACTIVE_ENV_FILE=/opt/noda/active-env-keycloak]
    |
    +--> [T4: 统一基础设施 Pipeline]
           |
           +--> [T6: 备份检查 + 健康检查 + 回滚]（复用现有函数）
           +--> [T7: 人工确认门禁]（Jenkins input 步骤）
           +--> [D2: 服务特定阶段分发]（when 条件 + 函数分发）

[D1: 一键安装脚本]（独立，可在任何时间点完成，依赖 T1 流程稳定）
```

### 关键依赖链

1. **T1 → T2**：Jenkins 迁移必须等 PG 安装完成并验证
2. **T1 → T3**：本地 PG 替代 postgres-dev 后才能安全移除容器
3. **T3 → T3b**：keycloak-dev 的 `depends_on: postgres-dev`，必须同时或先移除 postgres-dev
4. **upstream-keycloak → T5**：需要 `upstream-keycloak.conf` 切换机制（类似 upstream-findclass.conf）
5. **T5 + T4**：Keycloak 蓝绿是基础设施 Pipeline 的一个子流程
6. **T2 → D4**：Jenkins 迁移到 PG 后才能纳入备份体系

### 并行化机会

- T1（PG 安装）和 upstream-keycloak 抽离可以并行
- T3（移除 dev 容器）和 T5（Keycloak 蓝绿准备）可以并行
- D1（一键脚本）独立于所有其他 Feature

## 各 Feature 详细分析

### T1: 宿主机 PostgreSQL 安装与配置

**当前状态：** 生产 PG 在 Docker 容器 `noda-infra-postgres-prod` 中（postgres:17.9），开发 PG 在 `noda-infra-postgres-dev` 容器中（端口 5433）。

**需要的数据库和用户：**

| 数据库 | 用途 | 认证方式 |
|--------|------|---------|
| `noda_dev` | 开发环境应用数据库（findclass-ssr / Prisma） | trust（本地）或 md5 |
| `keycloak_dev` | Keycloak 开发数据库（实际可能不需要，因为 keycloak-dev 也被移除） | trust（本地） |
| `jenkins` | Jenkins CI/CD 数据（替代 H2） | md5（密码认证） |

**关键决策：**
- 本地 PG 监听 `localhost:5432`（默认端口），不与 Docker 容器冲突（Docker 容器在内部网络，端口不暴露到宿主机）
- 生产 PG 继续在 Docker 容器中运行，完全隔离
- 开发环境用 trust 认证（无需密码），Jenkins 用 md5 认证

**Complexity: Low** -- Homebrew 安装标准化，数据库创建脚本可复用 `init-databases.sh` 模式。

### T2: Jenkins H2 → 本地 PostgreSQL 迁移

**当前状态：** Jenkins LTS 安装在宿主机（`/var/lib/jenkins`），使用默认 H2 嵌入式数据库。

**迁移路径：**
1. 停止 Jenkins 服务 (`sudo systemctl stop jenkins`)
2. 备份 `$JENKINS_HOME` 目录
3. 在本地 PG 中创建 `jenkins` 数据库和用户
4. 下载 PostgreSQL JDBC 驱动到 `$JENKINS_HOME/lib/`
5. 修改 Jenkins 数据库配置（通过 `JAVA_OPTS` 系统属性或 `jenkins.model.JenkinsLocationConfiguration.xml`）
6. 启动 Jenkins，验证功能正常

**停机时间：** 5-15 分钟。Jenkins 非关键服务，可接受。

**数据风险：** Jenkins 大部分配置存储在 XML 文件中（`$JENKINS_HOME/*.xml`、`jobs/` 目录），不在 H2 数据库中。H2 主要存储 fingerprint 和部分 Plugin 数据。对于新建的 Jenkins 实例（v1.4 刚安装），H2 中几乎没有需要迁移的数据。

**Complexity: Med** -- 操作步骤清晰但需要验证 Jenkins 所有功能正常。

**Confidence: MEDIUM** -- Jenkins H2 到 PG 迁移的具体配置项需要参考 Jenkins 当前版本的文档确认。

### T3: 移除 postgres-dev / keycloak-dev 容器

**当前状态（docker-compose.dev.yml）：**
- `postgres-dev`：端口 5433，init-dev 脚本创建 noda_dev、keycloak_dev、findclass_dev
- `keycloak-dev`：端口 18080/19000，`depends_on: postgres-dev`，使用 `start-dev` 模式

**影响矩阵：**

| 依赖方 | 影响 | 解决方案 |
|--------|------|---------|
| 本地开发 PG 连接（5433 端口） | 端口不再存在 | 改为连接 localhost:5432（本地 PG） |
| keycloak-dev 容器 | 整个容器被移除 | 开发环境用生产 Keycloak（auth.noda.co.nz），PROJECT.md 已列为 Out of Scope |
| `docker-compose.dev-standalone.yml` | 引用 postgres-dev | 同步移除或标记废弃 |
| `deploy-infrastructure-prod.sh` | EXPECTED_CONTAINERS 和 START_SERVICES 引用 postgres-dev | 移除引用 |
| 种子数据脚本 `init-dev/*.sql` | 不再被 Docker 自动执行 | 迁移到本地 PG 初始化脚本 |

**保留的 dev.yml 内容：** `nginx` 开发配置（端口 8081）和 `keycloak` 生产容器的开发覆盖（环境变量覆盖）应保留，不依赖 postgres-dev。

**Complexity: Low** -- 主要是删除配置 + 更新引用。

### T4: 统一基础设施 Pipeline

**当前状态：** 两个应用 Pipeline（`Jenkinsfile` for findclass-ssr，`Jenkinsfile.noda-site` for noda-site），基础设施通过 `deploy-infrastructure-prod.sh` 手动执行。

**目标：** `jenkins/Jenkinsfile.infra`，通过 `choice` 参数选择服务。

**参数设计：**

```groovy
parameters {
    choice(name: 'SERVICE',
           choices: ['keycloak', 'postgres', 'nginx', 'noda-ops'],
           description: '选择要部署的基础设施服务')
    booleanParam(name: 'SKIP_BACKUP', defaultValue: false,
                 description: '跳过部署前备份检查（仅在确认备份充足时使用）')
}
```

**服务特定阶段差异：**

| 阶段 | postgres | keycloak | nginx | noda-ops |
|------|----------|----------|-------|----------|
| Pre-flight | 备份检查 + PG 连通性 | 备份检查 + 当前 Keycloak 健康 | 备份检查 + nginx 配置验证 | 备份检查 + noda-ops 容器存在 |
| Deploy | `docker compose up -d --force-recreate --no-deps` | 蓝绿：新容器启动 → 健康检查 → upstream 切换 | `docker compose up -d --force-recreate --no-deps` + reload | `docker compose up -d --force-recreate --no-deps` |
| Health Check | `pg_isready` via `docker exec` | HTTP 8080 TCP 检查 | HTTP 80 端口可达 | PG 连通性检查 |
| Verify | SQL 查询（`SELECT 1`） | 登录页 HTTP 200 | 反向代理正常 | 备份脚本可执行 |
| Switch | N/A（滚动更新） | upstream 切换 + nginx reload | N/A（已 reload） | N/A（滚动更新） |
| Rollback | 回退到之前镜像 digest | 回退 upstream + 停新容器 | 回退到之前镜像 | 回退到之前镜像 |

**注意：** postgres、nginx、noda-ops 使用滚动更新（有短暂停机）。只有 Keycloak 使用蓝绿部署（零停机）。这是合理的权衡 -- postgres 不可蓝绿（数据库状态在卷上），nginx 停机极短（reload 秒级），noda-ops 非面向用户。

**Complexity: Med** -- Pipeline 结构清晰，服务特定逻辑需要仔细实现。

### T5: Keycloak 蓝绿部署

**当前状态：** Keycloak 生产容器 `noda-infra-keycloak-prod`，upstream 硬编码 `keycloak:8080`。

**架构调整：**

1. **upstream-keycloak.conf 动态化**（当前内容：`server keycloak:8080`）：
   ```
   upstream keycloak_backend {
       server keycloak-blue:8080 max_fails=3 fail_timeout=30s;
   }
   ```

2. **manage-containers.sh 参数化复用**（已支持）：
   ```bash
   SERVICE_NAME=keycloak \
   SERVICE_PORT=8080 \
   UPSTREAM_NAME=keycloak_backend \
   HEALTH_PATH=/health \
   ACTIVE_ENV_FILE=/opt/noda/active-env-keycloak \
   UPSTREAM_CONF=config/nginx/snippets/upstream-keycloak.conf \
   scripts/manage-containers.sh init
   ```

3. **env-keycloak.env 模板**（大量环境变量）：
   ```
   KC_DB=postgres
   KC_DB_URL=jdbc:postgresql://postgres:5432/keycloak
   KC_DB_USERNAME=${POSTGRES_USER}
   KC_DB_PASSWORD=${POSTGRES_PASSWORD}
   KC_HOSTNAME=https://auth.noda.co.nz
   KC_PROXY=edge
   KC_PROXY_HEADERS=xforwarded
   # ... SMTP 等配置
   ```

**Session 处理策略：**

| 方案 | 复杂度 | 用户体验 | 推荐 |
|------|--------|---------|------|
| 接受 session 丢失 | Low | 切换时活跃用户需重新登录 | 推荐 |
| 外部 Infinispan 集群 | High | 完全无感 | 过度工程化 |
| JDBC-based session persistence | Med | 数据库 IO 延迟增加 | 不值得 |

**结论：** 单服务器 + 小用户量，接受 session 丢失。Pipeline Switch 阶段记录警告日志。

**数据库共享风险：**
- 蓝绿两个容器共享同一个 PostgreSQL `keycloak` 数据库
- Keycloak 启动时自动执行 schema migration
- **风险：** 新版本 schema migration 可能不兼容旧版本
- **缓解：** 部署前备份数据库，回滚时恢复备份；先启动新容器完成 migration，验证通过后再切换

**Complexity: High** -- session 管理、schema migration、大量环境变量配置、模板文件管理。

**Confidence: MEDIUM** -- Keycloak schema migration 在共享数据库上的行为需要实际测试验证。

### T7: 人工确认门禁

**放置位置：**

| 服务 | 门禁位置 | 理由 |
|------|---------|------|
| postgres | Deploy 之前 | 数据库变更不可逆，必须确认备份可用 |
| keycloak | Switch 之前 | 切换后活跃用户 session 丢失，需要确认 |
| nginx | Deploy 之前 | 反向代理中断影响所有服务 |
| noda-ops | 无门禁 | 备份服务变更影响小 |

**实现：** Jenkins `input` 步骤，超时 30 分钟自动中止。

**Complexity: Low** -- Jenkins 原生支持。

### D1: 本地开发环境一键安装脚本

**需要的组件：**

| 组件 | macOS | Linux | 验证 |
|------|-------|-------|------|
| PostgreSQL 17 | `brew install postgresql@17` | `sudo apt install postgresql-17` | `psql --version` |
| Node.js 21+ | `brew install node` | nodesource apt | `node --version` |
| pnpm | `npm install -g pnpm` | `npm install -g pnpm` | `pnpm --version` |
| 数据库初始化 | SQL 脚本 | SQL 脚本 | `\l` |
| 环境变量 | 生成 `.env` | 生成 `.env` | 连接测试 |

**脚本结构（参考 setup-jenkins.sh）：**

```
setup-dev-env.sh install     # 安装所有依赖（幂等）
setup-dev-env.sh init-db     # 初始化本地数据库
setup-dev-env.sh status      # 检查所有组件状态
setup-dev-env.sh reset       # 重置开发数据库（危险操作，需确认）
```

**Complexity: Med** -- macOS/Linux 差异处理和幂等性逻辑需要仔细设计。

## MVP Recommendation

**Phase 1 优先（基础设施层，解除 dev 容器依赖）：**
1. T1: 宿主机 PostgreSQL 安装与配置
2. T2: Jenkins H2 → PG 迁移
3. T3: 移除 postgres-dev / keycloak-dev 容器

**Phase 2 优先（Pipeline 层，运维自动化）：**
4. T4: 统一基础设施 Pipeline
5. T5: Keycloak 蓝绿部署

**Phase 3 优先（开发者体验层）：**
6. D1: 一键安装脚本

**Defer（后续 milestone）：**
- Keycloak session 持久化：用户量小，过度工程化
- Jenkins PG 备份恢复演练
- PostgreSQL 蓝绿部署：无意义（状态在卷上）
- 基础设施自动触发部署：手动触发已满足需求

## Sources

- 项目代码库分析（HIGH confidence）：
  - `docker/docker-compose.yml`、`docker/docker-compose.dev.yml`、`docker/docker-compose.prod.yml`、`docker/docker-compose.app.yml`
  - `scripts/manage-containers.sh`（蓝绿容器管理，支持多服务参数化）
  - `scripts/pipeline-stages.sh`（Pipeline 阶段函数库）
  - `scripts/setup-jenkins.sh`（Jenkins 安装脚本，可复用模式）
  - `jenkins/Jenkinsfile`、`jenkins/Jenkinsfile.noda-site`（现有 Pipeline 结构）
  - `config/nginx/snippets/upstream-keycloak.conf`（当前硬编码 upstream）
  - `config/nginx/snippets/upstream-findclass.conf`（蓝绿 upstream 切换参考）
  - `docker/services/postgres/init-dev/01-create-databases.sql`、`02-seed-data.sql`（开发数据库初始化）
  - `scripts/init-databases.sh`（数据库创建脚本模式）
  - `scripts/deploy/deploy-infrastructure-prod.sh`（当前手动部署流程）
- Jenkins H2 to PG 迁移：Jenkins 官方文档 + 社区实践，MEDIUM confidence
- Keycloak Infinispan session 管理：Keycloak 26.x 文档，MEDIUM confidence
- Homebrew PostgreSQL 安装：标准化流程，HIGH confidence

---
*Feature research for: Noda v1.5 开发环境本地化 + 基础设施 CI/CD*
*Researched: 2026-04-17*
