# Stack Research: v1.5 开发环境本地化 + 基础设施 CI/CD

**Domain:** 本地 PostgreSQL 安装、Jenkins 数据库备份集成、Keycloak 蓝绿部署、统一基础设施 Pipeline
**Researched:** 2026-04-17
**Confidence:** HIGH

## 关键发现：Jenkins 不使用 H2 数据库

**Jenkins 核心数据全部存储在文件系统中（$JENKINS_HOME），使用 XML + XStream 序列化，不使用任何关系型数据库。** Jenkins 的 database 插件（H2/PostgreSQL）是供其他插件（如 JUnit SQL Storage）使用的库插件，安装率极低（H2 0.043%），不是 Jenkins 核心功能。

这意味着 PROJECT.md 中的 "Jenkins H2 -> PostgreSQL 迁移" 需要重新理解：
- 不是数据库迁移，而是利用本地 PostgreSQL 改善 Jenkins $JENKINS_HOME 的备份策略
- 当前 Jenkins 备份依赖文件系统快照/tar，可以改用 pg_dump 备份 Jenkins 元数据到本地 PG（如果使用了 database 插件）
- **更实际的做法**：本地 PostgreSQL 供 Jenkins 可选插件使用，同时将 Jenkins $JENKINS_HOME 目录纳入现有 pg_dump 备份框架的目录备份范围

## Recommended Stack

### 1. 本地 macOS PostgreSQL (Homebrew)

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| PostgreSQL | 17.9 (Homebrew) | 本地开发数据库 + Jenkins 备份元数据存储 | 与 Docker 容器 postgres:17.9 版本完全一致，pg_dump/pg_restore 无版本兼容问题 | HIGH |
| Homebrew postgresql@17 | stable 17.9 | macOS 安装源 | 官方 Homebrew formula，支持 Apple Silicon (Sequoia/Sonoma)，废弃日期 2029-11-08 | HIGH |

**安装与配置：**

```bash
# 安装
brew install postgresql@17

# 添加到 PATH
echo 'export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# 启动服务
brew services start postgresql@17

# 验证
postgres --version  # 预期: postgres (PostgreSQL) 17.9
```

**关键路径（Apple Silicon）：**
- 数据目录: `/opt/homebrew/var/postgresql@17/`
- 配置文件: `/opt/homebrew/var/postgresql@17/postgresql.conf`
- 客户端认证: `/opt/homebrew/var/postgresql@17/pg_hba.conf`
- Socket: `/opt/homebrew/var/postgresql@17/`

**数据库创建（开发环境）：**

```bash
# 创建开发数据库（替代 Docker postgres-dev 容器）
createdb noda_dev

# 创建 Keycloak 开发数据库
createdb keycloak_dev

# 创建 Jenkins 元数据数据库（如果使用 database 插件）
createdb jenkins_metadata

# 创建用户（如需与 Docker 环境保持一致的用户名/密码）
psql postgres -c "CREATE USER noda WITH PASSWORD 'dev_password';"
psql postgres -c "GRANT ALL PRIVILEGES ON DATABASE noda_dev TO noda;"
psql postgres -c "GRANT ALL PRIVILEGES ON DATABASE keycloak_dev TO noda;"
```

**pg_hba.conf 配置（本地信任认证）：**

```
# 默认 Homebrew 配置已允许本地 trust 认证，无需修改
# 验证：psql postgres 应直接连接
```

**postgresql.conf 调优（开发环境默认值足够）：**

```
listen_addresses = 'localhost'    # 仅本地连接
port = 5432                       # 标准端口
max_connections = 100             # 默认值，开发环境足够
shared_buffers = 128MB            # 开发机器默认值
log_statement = 'all'             # 开发环境：记录所有 SQL（可选）
```

### 2. 移除 postgres-dev / keycloak-dev Docker 容器

**当前状态（docker-compose.dev.yml）：**
- `postgres-dev`: postgres:17.9, 端口 5433, 数据卷 `postgres_dev_data`
- `keycloak-dev`: keycloak:26.2.3, 端口 18080/19000, 依赖 postgres-dev

**移除后的替代方案：**

| 功能 | 当前（Docker） | 新方案（本地） |
|------|---------------|---------------|
| 开发数据库 | postgres-dev 容器 (:5433) | Homebrew PostgreSQL (:5432) |
| Keycloak 开发 | keycloak-dev 容器 (:18080) | 本地 `kc.sh start-dev`（可选）或直接用生产 Keycloak 测试 |
| 开发数据库种子数据 | init-dev/ SQL 脚本 | psql 直接导入本地 PG |

**docker-compose.dev.yml 简化后保留：**
- nginx 开发端口覆盖 (8081)
- cloudflared profile 禁用
- keycloak 开发环境覆盖（KC_HOSTNAME="" 等）

### 3. Jenkins 数据库备份集成

**核心结论：Jenkins 不需要数据库迁移。**

Jenkins 2.541.3 的所有核心数据存储在 `$JENKINS_HOME` 目录（/var/lib/jenkins）：
- `config.xml` — Jenkins 全局配置
- `jobs/` — Job 定义和构建记录
- `plugins/` — 插件安装和配置
- `secrets/` — 加密密钥（必须单独安全备份）
- `users/` — 用户配置
- `workflow-libs/` — Shared Libraries

**推荐备份策略（利用现有基础设施）：**

| 组件 | 备份方式 | 集成 |
|------|---------|------|
| Jenkins $JENKINS_HOME | tar + 上传 B2 | 纳入 noda-ops 备份容器或 cron 脚本 |
| PostgreSQL 生产数据库 | pg_dump（现有） | 不变 |
| 本地开发 PG | 无需备份 | 开发数据可重建 |

**Jenkins 备份脚本（新增到 noda-ops 或独立 cron）：**

```bash
#!/bin/bash
# Jenkins $JENKINS_HOME 备份
# 注意：需要先执行 Jenkins Quiet Period 或使用 --quiet mode
# 参考：https://www.jenkins.io/doc/book/system-administration/backing-up/

JENKINS_HOME="/var/lib/jenkins"
BACKUP_DIR="/tmp/jenkins_backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# 1. 备份关键目录（排除 workspace、cache、tools）
tar czf "${BACKUP_DIR}/jenkins-${TIMESTAMP}.tar.gz" \
  --exclude='*/workspace/*' \
  --exclude='*/cache/*' \
  --exclude='*/tools/*' \
  --exclude='*.log' \
  -C /var/lib jenkins

# 2. 单独备份 master.key（绝不能放入常规备份）
# 存储到安全位置（如 B2 的独立路径或离线存储）
cp "${JENKINS_HOME}/secrets/master.key" "/secure/location/master.key.${TIMESTAMP}"

# 3. 上传 B2（复用现有 B2 配置）
# b2 upload-file noda-backups "${BACKUP_DIR}/jenkins-${TIMESTAMP}.tar.gz" ...
```

### 4. Keycloak 蓝绿部署

| Component | Mechanism | Confidence |
|-----------|-----------|------------|
| Keycloak 蓝绿容器 | `docker run` 启动 keycloak-blue/keycloak-green | HIGH |
| Nginx upstream 切换 | 修改 `upstream-keycloak.conf` + `nginx -s reload` | HIGH |
| 健康检查 | HTTP GET `http://keycloak-{color}:8080/health/ready` | HIGH |
| 状态文件 | `/opt/noda/active-env-keycloak` | HIGH |

**关键配置：Keycloak 蓝绿共享同一个数据库**

两个 Keycloak 实例（blue/green）都连接同一个 PostgreSQL 数据库（keycloak database）。这是安全的，因为：

1. **Keycloak 设计就是多实例共享数据库** — 生产模式默认使用 `jdbc-ping` 栈通过数据库发现集群节点
2. **蓝绿切换期间短暂共存** — 新实例启动到切换完成通常 1-2 分钟，Infinispan 缓存会自动同步
3. **版本兼容性** — 蓝绿实例使用相同的 Keycloak 26.2.3 镜像，schema 一致

**但要注意缓存集群冲突：**

Keycloak 生产模式（`start`）默认启用分布式缓存。如果蓝绿两个实例同时运行，它们会自动组成 Infinispan 集群。这可能导致：
- 缓存一致性问题（如果版本不同）
- 短暂的 session 复制延迟

**缓解方案：**

```bash
# 方案 A：使用 start-dev 模式（本地缓存，不发现其他节点）
# 优点：完全隔离，无集群问题
# 缺点：start-dev 放宽了安全限制，不适合生产
# 结论：不推荐

# 方案 B：保持 start 模式，短暂共存可接受（推荐）
# 两个同版本实例共享数据库 + 缓存集群是 Keycloak 设计的正常行为
# 切换完成后立即停掉旧实例
# 优点：与生产配置一致
# 结论：推荐

# 方案 C：新实例使用独立缓存配置
# 通过 KC_CACHE 和 KC_CACHE_STACK 环境变量控制
# 优点：完全控制缓存行为
# 缺点：增加配置复杂度
# 结论：仅在方案 B 出现问题时考虑
```

**Keycloak 蓝绿容器启动参数：**

```bash
# keycloak-blue
docker run -d \
  --name keycloak-blue \
  --network noda-network \
  --restart unless-stopped \
  -e KC_DB=postgres \
  -e KC_DB_URL=jdbc:postgresql://noda-infra-postgres-prod:5432/keycloak \
  -e KC_DB_USERNAME=${POSTGRES_USER} \
  -e KC_DB_PASSWORD=${POSTGRES_PASSWORD} \
  -e KC_HTTP_ENABLED=true \
  -e KC_HOSTNAME=https://auth.noda.co.nz \
  -e KC_PROXY=edge \
  -e KC_PROXY_HEADERS=xforwarded \
  -e KC_HEALTH_ENABLED=true \
  -e KEYCLOAK_ADMIN=${KEYCLOAK_ADMIN_USER} \
  -e KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD} \
  --label noda.service-group=infra \
  --label noda.environment=prod \
  --label noda.blue-green=blue \
  quay.io/keycloak/keycloak:26.2.3 start

# keycloak-green: 同上，修改 --name 和 label
```

**Nginx upstream 切换：**

当前 `upstream-keycloak.conf` 指向 `keycloak:8080`（Docker compose service name）。蓝绿模式下需要改为具体容器名：

```nginx
# upstream-keycloak.conf — 蓝绿切换前
upstream keycloak_backend {
    server keycloak:8080 max_fails=3 fail_timeout=30s;
}

# 蓝绿模式 — 切换到 blue
upstream keycloak_backend {
    server keycloak-blue:8080 max_fails=3 fail_timeout=30s;
}

# 蓝绿模式 — 切换到 green
upstream keycloak_backend {
    server keycloak-green:8080 max_fails=3 fail_timeout=30s;
}
```

**Keycloak 健康检查端点：**

Keycloak 26.x 在 `KC_HEALTH_ENABLED=true` 时提供：
- `http://localhost:8080/health/ready` — 就绪检查
- `http://localhost:8080/health/live` — 存活检查
- `http://localhost:8080/health/started` — 启动完成检查

如果没有启用健康检查，回退到 TCP 检查（当前 docker-compose.yml 的方式）。

### 5. 统一基础设施 Jenkins Pipeline

**现有模式分析：**

findclass-ssr 和 noda-site 的 Jenkinsfile 高度相似，区别仅在于 environment 变量：
- `SERVICE_NAME`
- `SERVICE_PORT`
- `UPSTREAM_NAME`
- `HEALTH_PATH`
- `ACTIVE_ENV_FILE`
- `DOCKERFILE`
- `UPSTREAM_CONF`

**基础设施服务部署参数：**

| Service | SERVICE_NAME | SERVICE_PORT | UPSTREAM_NAME | HEALTH_PATH | ACTIVE_ENV_FILE | DOCKERFILE |
|---------|-------------|-------------|---------------|-------------|-----------------|------------|
| postgres | N/A (compose) | 5432 | N/A | pg_isready | N/A | N/A |
| keycloak | keycloak | 8080 | keycloak_backend | /health/ready | /opt/noda/active-env-keycloak | N/A (使用官方镜像) |
| noda-ops | N/A (compose) | N/A | N/A | pg_isready (健康检查脚本) | N/A | deploy/Dockerfile.noda-ops |
| nginx | N/A (compose) | 80 | N/A | nginx -t | N/A | N/A (使用官方镜像) |

**基础设施 Pipeline 架构决策：**

基础设施服务与应用服务的部署模式有本质区别：

| 维度 | 应用服务 (findclass-ssr, noda-site) | 基础设施服务 (postgres, keycloak, nginx, noda-ops) |
|------|-------------------------------------|-------------------------------------------------|
| 部署模式 | 蓝绿切换（零停机） | 滚动替换（短暂停机可接受） |
| 构建需求 | 需要 docker build | 使用官方镜像，无需构建 |
| 测试需求 | pnpm lint/test | 无源码测试 |
| Nginx 集成 | upstream 切换 | keycloak 需要，其他不需要 |
| 数据持久化 | 无状态 | 有状态（PG 数据卷、Keycloak DB） |
| 备份要求 | 部署前备份时效检查 | 部署前强制备份（必须） |

**推荐：创建 `Jenkinsfile.infra` 统一 Pipeline**

```groovy
// 统一基础设施部署 Pipeline
// 参数化选择服务: postgres / keycloak / noda-ops / nginx
// 每个服务有独立的部署逻辑，共享备份检查和回滚机制

pipeline {
    agent any

    parameters {
        choice(name: 'SERVICE', choices: ['keycloak', 'postgres', 'noda-ops', 'nginx'],
               description: '选择要部署的基础设施服务')
        string(name: 'IMAGE_TAG', defaultValue: 'latest',
               description: '镜像标签（keycloak/nginx 使用官方标签，其他使用 latest）')
    }

    // 每个服务根据 SERVICE 参数加载不同的环境变量
    // 具体逻辑在 scripts/pipeline-infra-stages.sh 中实现
}
```

**各服务部署策略：**

| 服务 | 策略 | 步骤 |
|------|------|------|
| **postgres** | 停止-启动（有停机） | 备份 -> 停止容器 -> 拉取新镜像 -> 启动 -> 健康检查 -> 验证 |
| **keycloak** | 蓝绿切换（零停机） | 备份 -> 启动新容器 -> 健康检查 -> 切换 upstream -> 停旧容器 |
| **noda-ops** | 停止-启动（短暂停机） | 构建 -> 停止容器 -> 启动新容器 -> 健康检查 -> 验证 |
| **nginx** | 停止-启动（短暂停机） | 停止容器 -> 拉取新镜像 -> 启动 -> 健康检查 -> 验证 upstream |

### 6. 本地开发环境一键安装脚本

**需要安装的工具：**

| Tool | Install Method | Purpose | Required |
|------|---------------|---------|----------|
| PostgreSQL 17 | `brew install postgresql@17` | 本地开发数据库 | Yes |
| Docker Desktop | `brew install --cask docker` | 容器运行时 | Yes |
| Node.js (LTS) | `brew install node` 或 `nvm` | 前端开发 | Conditional |
| pnpm | `npm install -g pnpm` | 包管理器 | Conditional |
| Java 21 (Temurin) | `brew install --cask temurin@21` | Jenkins 本地测试（可选） | No |
| gettext | `brew install gettext` | envsubst 工具（manage-containers.sh 依赖） | Yes |
| jq | `brew install jq` | JSON 处理（部署脚本可能依赖） | Recommended |
| git | macOS 内置或 `xcode-select --install` | 版本控制 | Yes |

**一键安装脚本结构：**

```bash
#!/bin/bash
# scripts/setup-local-dev.sh
# macOS 开发环境一键安装

set -euo pipefail

echo "=== Noda 开发环境安装 ==="

# 1. 检查 Homebrew
command -v brew >/dev/null 2>&1 || { echo "请先安装 Homebrew"; exit 1; }

# 2. 安装 PostgreSQL 17
brew install postgresql@17
brew services start postgresql@17

# 3. 创建开发数据库
/opt/homebrew/opt/postgresql@17/bin/createdb noda_dev 2>/dev/null || true
/opt/homebrew/opt/postgresql@17/bin/createdb keycloak_dev 2>/dev/null || true

# 4. 安装工具依赖
brew install gettext jq

# 5. 配置 PATH
grep -q 'postgresql@17' ~/.zshrc 2>/dev/null || \
  echo 'export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"' >> ~/.zshrc

# 6. 设置 .env 文件（从模板）
if [ ! -f docker/.env ]; then
  cp docker/.env.example docker/.env
  echo "请编辑 docker/.env 填入实际配置"
fi

# 7. 启动 Docker 服务（基础设施）
# 注意：不包含 postgres-dev 和 keycloak-dev
cd docker && docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

echo "=== 开发环境安装完成 ==="
```

## Alternatives Considered

### PostgreSQL 安装方式

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| Homebrew postgresql@17 | Postgres.app | Homebrew 是标准 macOS 包管理器，CI 环境也使用 Homebrew；Postgres.app 需要额外安装，版本管理不如 Homebrew 灵活 |
| Homebrew postgresql@17 | Docker 容器（保留 postgres-dev） | 违反 v1.5 目标——移除 Docker 开发容器，Docker Compose 简化为纯线上业务 |
| PostgreSQL 17 | PostgreSQL 18 (最新) | 生产 Docker 容器使用 postgres:17.9，本地版本必须与生产一致以避免 pg_dump 版本不兼容 |

### Keycloak 蓝绿部署方案

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| 蓝绿切换（与 findclass-ssr 相同模式） | 直接停止替换 | Keycloak 是认证服务，停机会导致所有依赖它的应用（findclass-ssr）登录中断 |
| 共享数据库 + 允许短暂缓存集群共存 | 使用独立数据库 | 增加运维复杂度（需维护两套数据库 schema 迁移），且 Keycloak 设计就是多实例共享数据库 |
| 官方镜像 + 环境变量 | 自定义 Dockerfile | 不需要修改 Keycloak 源码，只改配置（环境变量） |

### Jenkins 数据库方案

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| Jenkins $JENKINS_HOME 文件系统备份 + B2 | 安装 database-postgresql 插件迁移到 PG | Jenkins 核心不支持数据库存储（XML + XStream 文件系统设计），database 插件是给其他插件用的库，不是改变 Jenkins 存储后端 |
| 文件系统备份 | Jenkins thinBackup 插件 | thinBackup 是唯一还在维护的备份插件，但增加了 Jenkins 依赖；cron + tar 脚本更简单可控 |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Jenkins database-postgresql 插件 | Jenkins 核心不使用数据库存储 jobs/builds/config，安装此插件不会改变 Jenkins 存储后端 | 文件系统备份（tar + B2） |
| Jenkins database-h2 插件 | 安装率仅 0.043%，除非有特定插件需要否则无用 | 不安装，保持 Jenkins 默认文件系统存储 |
| `brew install postgresql`（无版本号） | 安装最新版（当前 18.x），与生产环境 17.x 不兼容 | `brew install postgresql@17` |
| Keycloak `start-dev` 模式用于蓝绿部署 | start-dev 禁用主题缓存、放宽安全限制，与生产配置不一致 | `start` 模式，接受短暂缓存集群共存 |
| 在本地 macOS 安装 Keycloak | PROJECT.md 已明确 Out of Scope | 本地开发直接用生产 Keycloak 测试 |
| Jenkins JCasC (Configuration as Code) | 增加配置复杂度，当前手动初始化足够 | 保持现有 setup-jenkins.sh 脚本 |

## Version Compatibility

| Component | Version | Compatible With | Notes |
|-----------|---------|-----------------|-------|
| Homebrew PostgreSQL | 17.9 | Docker postgres:17.9 | pg_dump/pg_restore 版本完全匹配 |
| Keycloak | 26.2.3 | PostgreSQL 17.x | 官方测试版本覆盖 14-18 |
| Jenkins LTS | 2.541.3 | Java 17, 21, 25 | 当前版本 |
| Jenkins LTS | 2.555.1 (2026-04) | Java 21, 25 only | 新 LTS，升级后需要 Java 21+ |
| OpenJDK 21 | 21.x | Jenkins 2.541.x 和 2.555.x | 安全选择，两个版本都支持 |
| Nginx | 1.25-alpine | upstream 切换 + reload | 无变更 |
| Docker Compose | v2 | 所有 compose 文件 | 无变更 |

## Integration Points with Existing Architecture

| 现有组件 | 变更类型 | 变更范围 | 风险 |
|---------|---------|---------|------|
| `docker-compose.dev.yml` | 删除 postgres-dev / keycloak-dev 服务 | 中等 — 移除两个完整服务定义 | Low |
| `docker-compose.dev.yml` | 保留 nginx/cloudflared 覆盖 | 小 — 无结构性变更 | None |
| `config/nginx/snippets/upstream-keycloak.conf` | 支持蓝绿切换 | 小 — 容器名从 `keycloak` 改为 `keycloak-{color}` | Medium — 需要迁移现有 compose 管理的容器 |
| `scripts/manage-containers.sh` | 复用现有蓝绿框架 | 无变更 — 通过环境变量参数化 | None |
| `scripts/pipeline-stages.sh` | 新增基础设施部署函数 | 中等 — 新增 pipeline_infra_* 系列函数 | Low |
| `jenkins/Jenkinsfile.infra` | 新文件 | 新增 — 统一基础设施 Pipeline | None |
| `scripts/setup-local-dev.sh` | 新文件 | 新增 — 本地开发环境安装脚本 | None |
| `scripts/setup-jenkins.sh` | 新增备份步骤 | 小 — 在 install 子命令后添加备份 cron 配置 | Low |
| `services/postgres/init-dev/` | 废弃 | 移除 — 开发数据库种子数据改为本地 PG 直接导入 | Low |

## Sources

- [PostgreSQL 17 Release Notes](https://www.postgresql.org/docs/17/release.html) — 确认 17.9 为当前最新，HIGH confidence
- [Homebrew postgresql@17 Formula](https://formulae.brew.sh/formula/postgresql@17) — 版本 17.9，支持 Apple Silicon，废弃日期 2029-11-08，HIGH confidence
- [Jenkins Persistence Documentation](https://www.jenkins.io/doc/developer/persistence/) — Jenkins 使用文件系统（XML + XStream）存储所有核心数据，HIGH confidence
- [Jenkins Backup/Restore Documentation](https://www.jenkins.io/doc/book/system-administration/backing-up/) — 推荐文件系统备份，$JENKINS_HOME 目录结构，HIGH confidence
- [Jenkins Database Plugin](https://plugins.jenkins.io/database/) — 库插件，供其他插件使用，1.76% 安装率，HIGH confidence
- [Jenkins H2 Database Plugin](https://plugins.jenkins.io/database-h2/) — 0.043% 安装率，仅作为 database 插件的 H2 驱动，HIGH confidence
- [Jenkins Java Support Policy](https://www.jenkins.io/doc/book/platform-information/support-policy-java/) — 2.541.x 支持 Java 17/21/25，2.555.1+ 仅 Java 21/25，HIGH confidence
- [Jenkins LTS Changelog](https://www.jenkins.io/changelog-stable/) — 最新 LTS 2.555.1 (2026-04)，HIGH confidence
- [Keycloak Configuration](https://www.keycloak.org/server/configuration) — 配置方式（CLI/env/conf），生产模式默认启用分布式缓存，HIGH confidence
- [Keycloak Database Configuration](https://www.keycloak.org/server/db) — PostgreSQL 14-18 支持，JDBC 连接配置，HIGH confidence
- [Keycloak Caching](https://www.keycloak.org/server/caching) — Infinispan 分布式缓存，jdbc-ping 默认栈，多实例自动发现，HIGH confidence
- 项目代码: `docker/docker-compose.yml`, `docker/docker-compose.dev.yml`, `config/nginx/snippets/upstream-keycloak.conf`, `jenkins/Jenkinsfile`, `jenkins/Jenkinsfile.noda-site`, `scripts/manage-containers.sh`, `scripts/pipeline-stages.sh` — 现有架构分析

---
*Stack research for: Noda v1.5 开发环境本地化 + 基础设施 CI/CD*
*Researched: 2026-04-17*
