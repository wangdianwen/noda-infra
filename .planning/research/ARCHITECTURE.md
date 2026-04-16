# Architecture Research: v1.5 开发环境本地化 + 基础设施 CI/CD

**Domain:** 单服务器 Docker Compose 基础设施，Jenkins CI/CD 蓝绿部署
**Researched:** 2026-04-17
**Confidence:** HIGH（基于项目代码库完整分析 + 现有架构文档）

---

## 一、系统总览

### 1.1 当前架构（v1.4 已交付）

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops) → nginx:80
                                                          │
                            ┌─────────────────────────────┼──────────────────────┐
                            │                             │                      │
                  class.noda.co.nz             auth.noda.co.nz           noda.co.nz
                            │                             │                      │
                    findclass_backend              keycloak_backend        noda_site_backend
                            │                             │                      │
                  findclass-ssr-{color}:3001     keycloak:8080            noda-site-{color}:3000
                  （蓝绿 docker run）            （compose 单容器）        （蓝绿 docker run）

宿主机:
  Jenkins (systemd, port 8888) — H2 内嵌数据库
  PostgreSQL 17.9 — 仅 Docker 容器内运行

Docker Compose 项目：
  noda-infra  — postgres, keycloak, nginx, noda-ops（compose 管理）
  noda-apps   — findclass-ssr, noda-site（docker run 蓝绿管理）
  共享网络：noda-network (external)
```

### 1.2 目标架构（v1.5）

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops) → nginx:80
                                                          │
                            ┌─────────────────────────────┼──────────────────────┐
                            │                             │                      │
                  class.noda.co.nz             auth.noda.co.nz           noda.co.nz
                            │                             │                      │
                    findclass_backend          keycloak_backend          noda_site_backend
                            │                             │                      │
                  findclass-ssr-{color}:3001   keycloak-{color}:8080    noda-site-{color}:3000
                  （蓝绿 docker run）          （蓝绿 docker run）       （蓝绿 docker run）
                                                        ↑ 新增

宿主机:
  Jenkins (systemd, port 8888)
    └── 连接 → 宿主机 PostgreSQL (Homebrew, port 5432)
                ├── jenkins_db     ← Jenkins 数据库（替代 H2）
                ├── noda_dev       ← 本地开发数据库
                └── （直接备份，更安全）

Docker 容器 PostgreSQL（生产）:
                ├── noda_prod       ← findclass-ssr 生产数据
                └── keycloak_db     ← Keycloak 生产数据

  无 postgres-dev 容器   ← 移除
  无 keycloak-dev 容器   ← 移除
  无 docker-compose.dev.yml ← 大幅简化/移除
```

### 1.3 变更范围总览

| 变更类型 | 组件 | 影响 |
|----------|------|------|
| **新增** | 宿主机 PostgreSQL (Homebrew) | Jenkins + 本地开发数据库 |
| **新增** | Jenkinsfile.infra | 基础设施统一 Pipeline |
| **新增** | Keycloak 蓝绿部署 | upstream-keycloak.conf 动态切换 |
| **新增** | setup-dev.sh | 一键开发环境安装 |
| **修改** | Jenkins H2 → PG 迁移 | Jenkins 配置变更 |
| **修改** | pipeline-stages.sh | 参数化支持基础设施服务 |
| **修改** | manage-containers.sh | Keycloak 蓝绿容器管理 |
| **移除** | postgres-dev 容器 | docker-compose.dev.yml |
| **移除** | keycloak-dev 容器 | docker-compose.dev.yml |
| **移除/简化** | docker-compose.dev.yml | 大幅裁剪或完全移除 |

---

## 二、组件边界

### 2.1 新增组件

| 组件 | 职责 | 运行位置 | 与现有系统集成点 |
|------|------|---------|----------------|
| 宿主机 PostgreSQL | Jenkins 持久化 + 本地开发数据库 | 宿主机 (Homebrew) | Jenkins JDBC 连接；本地开发工具直连 |
| Jenkinsfile.infra | 基础设施服务统一部署 Pipeline | Jenkins agent | 调用 pipeline-stages.sh + manage-containers.sh |
| keycloak-{color} 蓝绿容器 | Keycloak 零停机部署 | Docker (docker run) | noda-network；nginx upstream 切换 |
| setup-dev.sh | 一键配置开发环境 | 宿主机 | 安装 Homebrew PG、创建数据库、配置 Jenkins |

### 2.2 修改组件

| 组件 | 修改内容 | 修改范围 |
|------|---------|---------|
| `pipeline-stages.sh` | 添加 `pipeline_infra_deploy`、`pipeline_infra_health_check` 等函数 | 中等 — 新增函数，不修改现有函数 |
| `manage-containers.sh` | Keycloak 服务参数支持（端口 8080、健康检查方式不同） | 小 — 已有 SERVICE_PORT/HEALTH_PATH 参数化 |
| `upstream-keycloak.conf` | 从静态 `keycloak:8080` 改为动态 `keycloak-{color}:8080` | 小 — 格式与 findclass/noda-site 一致 |
| `docker-compose.dev.yml` | 移除 postgres-dev、keycloak-dev 定义 | 中等 — 大量删除 |
| `docker-compose.yml` | keycloak 服务保持定义（作为蓝绿 init 来源） | 小 — 可能微调 |

### 2.3 不变组件

| 组件 | 理由 |
|------|------|
| `docker-compose.app.yml` | 应用服务（findclass-ssr, noda-site）配置不变 |
| `docker-compose.prod.yml` | 生产 overlay 不变（Keycloak 生产配置保持） |
| `Jenkinsfile`（findclass-ssr） | 现有 Pipeline 不变 |
| `Jenkinsfile.noda-site` | 现有 Pipeline 不变 |
| `nginx/conf.d/default.conf` | server blocks 不变，`proxy_pass http://keycloak_backend` 引用不变 |
| `scripts/lib/health.sh` | 通用健康检查函数不变 |
| `scripts/lib/log.sh` | 日志函数不变 |

---

## 三、集成点详细分析

### 3.1 本地 PostgreSQL + Jenkins 连接

**现状：** Jenkins 使用内嵌 H2 数据库（文件存储在 `/var/lib/jenkins/`）。

**目标：** Jenkins 连接宿主机 PostgreSQL。

**网络拓扑：**

```
宿主机进程空间
┌───────────────────────────────────────────────────┐
│  Jenkins (systemd, port 8888)                      │
│    └── JDBC → localhost:5432/jenkins_db            │
│                                                     │
│  PostgreSQL (Homebrew, port 5432)                   │
│    ├── jenkins_db  ← Jenkins 持久化                │
│    └── noda_dev    ← 本地开发用                     │
│                                                     │
│  Docker Engine                                      │
│    ├── noda-network (bridge)                        │
│    │   ├── noda-infra-postgres-prod:5432 (容器内)  │
│    │   ├── noda-infra-keycloak-{color}:8080        │
│    │   └── ...                                     │
│    └── 宿主机 PG 不在 Docker 网络内               │
└───────────────────────────────────────────────────┘
```

**关键设计决策：宿主机 PostgreSQL 不加入 Docker 网络。**

理由：
1. Jenkins 运行在宿主机，通过 `localhost:5432` 直接连接最简单
2. Docker 容器内的服务（findclass-ssr）不需要访问宿主机 PG — 它们连 Docker 容器内的 postgres-prod
3. 避免 Docker 网络配置复杂化（宿主机 PG 加入 bridge 网络需要额外配置）

**Jenkins 连接配置（`/etc/default/jenkins` 或 systemd override）：**

```bash
# Jenkins 启动参数添加
JAVA_OPTS="-Djenkins.model.Jenkins.loadAgentPlugins=false"
# 实际数据库切换需要安装 database 插件或通过 JCasC 配置
```

**重要说明：** Jenkins 的数据存储模型以文件系统（XML + JSON）为主，H2 仅用于部分插件和 fingerprint。所谓 "Jenkins H2 → PG 迁移" 在 Jenkins 2.x 中实际是指：
1. 安装 PostgreSQL 插件（用于 fingerprint 和 build records 外置存储）
2. 部分 Jenkins 数据（credentials、build history）仍在文件系统中
3. 真正的 Jenkins 元数据迁移到 PG 需要额外的数据库插件配置

**需确认：** 项目描述的 "Jenkins 从 H2 迁移到本地 PG" 具体指什么。如果仅是让 Jenkins 的 fingerprint/build records 存到 PG（推荐），操作较简单。如果要让所有 Jenkins 数据（jobs、config）也存到 PG，这需要 Jenkins Configuration as Code (JCasC) + 远程存储插件，复杂度显著增加。

### 3.2 移除 postgres-dev / keycloak-dev

**现状：**

```
docker-compose.dev.yml 定义：
├── postgres-dev     — 端口 127.0.0.1:5433:5432，连接 noda-network
├── keycloak-dev     — 端口 127.0.0.1:18080:8080，连接 postgres-dev
└── nginx dev 覆盖   — 端口 8081:80
```

**目标：**

```
docker-compose.dev.yml:
├── postgres-dev     → 移除（本地开发用宿主机 PG）
├── keycloak-dev     → 移除（开发环境直接连生产 Keycloak）
└── nginx dev 覆盖   → 保留（可能仍需要本地端口映射）
```

**影响分析：**

| 依赖 postgres-dev 的组件 | 移除后如何工作 |
|-------------------------|---------------|
| keycloak-dev 的数据库 | keycloak-dev 本身也被移除，无需处理 |
| 本地开发工具（如 Prisma Studio） | 连接宿主机 PG 的 noda_dev 数据库 |
| findclass-ssr 本地开发 | 连接宿主机 PG 的 noda_dev 或 Docker 容器的 postgres-prod |

**关键：** `docker-compose.dev.yml` 中 nginx 的 dev overlay（端口 8081:80）可能仍需要保留，取决于本地开发流程。但如果本地开发不再需要 Docker nginx（开发直接 `pnpm dev`），则整个 dev overlay 可以移除。

**网络影响：** 移除 postgres-dev 和 keycloak-dev 不影响 noda-network。这两个容器虽然是网络成员，但移除后 noda-network 中剩余的服务（postgres-prod, keycloak-prod, nginx, noda-ops）完全自洽。

### 3.3 统一基础设施 Pipeline（Jenkinsfile.infra）

**现状：** 两个独立 Jenkinsfile 处理应用部署：
- `jenkins/Jenkinsfile` — findclass-ssr 蓝绿部署（9 阶段）
- `jenkins/Jenkinsfile.noda-site` — noda-site 蓝绿部署（8 阶段）

两者都通过 `source scripts/pipeline-stages.sh` 调用共享函数。

**目标：** 新增 `jenkins/Jenkinsfile.infra`，支持通过参数选择部署哪个基础设施服务。

**参数化设计：**

```
Jenkinsfile.infra 参数：
├── SERVICE (choice): postgres | keycloak | noda-ops | nginx
├── ACTION (choice): deploy | restart | stop
└── CONFIRM (boolean): 人工确认门禁（默认 true）
```

**与现有 pipeline-stages.sh 的关系：**

现有 `pipeline-stages.sh` 的函数已经高度参数化（通过环境变量 `SERVICE_NAME`, `SERVICE_PORT`, `UPSTREAM_NAME` 等）。基础设施 Pipeline 需要新增的函数：

| 函数 | 用途 | 适用的基础设施服务 |
|------|------|------------------|
| `pipeline_infra_preflight` | 检查基础设施服务前置条件 | 所有 |
| `pipeline_infra_deploy` | docker compose up 重建服务 | postgres, noda-ops, nginx |
| `pipeline_infra_health_check` | 健康检查（compose 管理的容器） | 所有 |
| `pipeline_infra_backup` | 部署前自动备份（仅 postgres） | postgres |
| `pipeline_infra_rollback` | 回滚到之前状态 | 所有 |
| `pipeline_keycloak_deploy` | Keycloak 蓝绿部署（docker run） | keycloak |

**基础设施服务部署策略差异：**

| 服务 | 部署方式 | 有状态 | 停机容忍 | 特殊处理 |
|------|---------|--------|---------|---------|
| postgres | docker compose up --force-recreate | 有状态（数据卷） | 不容忍 | 部署前必须备份 + 验证 |
| keycloak | docker run 蓝绿 | 有状态（DB 在 postgres 中） | 零停机 | upstream 切换 |
| nginx | docker compose up --force-recreate | 无状态 | 极短（reload 期间） | reload 前验证配置 |
| noda-ops | docker compose up --force-recreate | 无状态 | 容忍（Tunnel 自动重连） | 无 |

**参数化 pipeline-stages.sh 的方式：**

现有代码已经通过环境变量实现了参数化。例如 `Jenkinsfile.noda-site` 通过设置 `SERVICE_NAME=noda-site` 等变量复用了 `pipeline-stages.sh` 的所有函数。基础设施 Pipeline 可以用同样的方式：

```groovy
// Jenkinsfile.infra 中的 Keycloak 部署 stage
environment {
    SERVICE_NAME = "keycloak"
    SERVICE_PORT = "8080"
    UPSTREAM_NAME = "keycloak_backend"
    HEALTH_PATH = "/health/ready"
    ACTIVE_ENV_FILE = "/opt/noda/active-env-keycloak"
    UPSTREAM_CONF = "${WORKSPACE}/config/nginx/snippets/upstream-keycloak.conf"
    DOCKERFILE = "keycloak"  // 标记为基础设施服务，不需要构建
}
```

### 3.4 Keycloak 蓝绿部署

**这是 v1.5 最复杂的集成点。**

**现状：**

```
upstream-keycloak.conf（静态）:
  upstream keycloak_backend {
      server keycloak:8080 max_fails=3 fail_timeout=30s;
  }

keycloak 服务（docker-compose.yml 定义）:
  container_name: noda-infra-keycloak-prod
  networks: noda-network (alias: keycloak)
  depends_on: postgres (service_healthy)
  command: start
```

**目标：**

```
upstream-keycloak.conf（动态）:
  upstream keycloak_backend {
      server keycloak-blue:8080 max_fails=3 fail_timeout=30s;
  }
  或
  upstream keycloak_backend {
      server keycloak-green:8080 max_fails=3 fail_timeout=30s;
  }

keycloak 蓝绿容器:
  keycloak-blue  → docker run, --network-alias keycloak-blue
  keycloak-green → docker run, --network-alias keycloak-green
```

**Keycloak 蓝绿部署的核心挑战：数据库 schema 迁移。**

Keycloak 在启动时自动运行数据库 schema 迁移（Liquibase）。如果 blue 和 green 容器版本不同，新版本启动时可能修改共享数据库的 schema，导致旧版本崩溃。

**解决方案：同版本配置变更（不涉及版本升级）时，蓝绿安全。**

当前项目的 Keycloak 部署场景是配置变更（hostname、proxy 设置、环境变量），而非版本升级。这意味着：
- blue 和 green 使用相同的 Keycloak 镜像（26.2.3）
- 数据库 schema 不会变
- 两个容器可以安全地连接同一个数据库

**但如果未来要升级 Keycloak 版本，蓝绿部署就会遇到 schema 冲突。** 因此需要记录这个限制。

**Keycloak 蓝绿容器配置：**

```bash
# manage-containers.sh 已有参数化支持
SERVICE_NAME=keycloak \
SERVICE_PORT=8080 \
UPSTREAM_NAME=keycloak_backend \
HEALTH_PATH="/health/ready" \
ACTIVE_ENV_FILE=/opt/noda/active-env-keycloak \
UPSTREAM_CONF=$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf \
  manage-containers.sh init
```

**Keycloak 容器的特殊需求（与 findclass-ssr 不同）：**

| 需求 | findclass-ssr | Keycloak |
|------|--------------|----------|
| 数据库连接 | 通过环境变量传入 | 通过环境变量传入 |
| Dockerfile 构建 | 需要（从 noda-apps 构建） | 不需要（直接使用官方镜像） |
| 环境变量数量 | 8 个 | 15+ 个（数据库、hostname、proxy、SMTP 等） |
| 健康检查方式 | wget HTTP 检查 | TCP 检查（`echo > /dev/tcp/localhost/8080`） |
| 启动时间 | ~30s | ~60s（start_period） |
| 资源需求 | 512M limit | 1G limit |
| compose 依赖 | 无 | depends_on postgres:healthy |

**env 模板方案：** 参照 `docker/env-findclass-ssr.env` 模式，创建 `docker/env-keycloak.env`：

```bash
# docker/env-keycloak.env
KC_DB=postgres
KC_DB_URL=jdbc:postgresql://noda-infra-postgres-prod:5432/keycloak_db
KC_DB_USERNAME=${POSTGRES_USER}
KC_DB_PASSWORD=${POSTGRES_PASSWORD}
KC_HTTP_ENABLED=true
KC_HOSTNAME=https://auth.noda.co.nz
KC_HOSTNAME_STRICT=false
KC_PROXY=edge
KC_PROXY_HEADERS=xforwarded
KC_HEALTH_ENABLED=true
KEYCLOAK_ADMIN=${KEYCLOAK_ADMIN_USER}
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}
KC_MAIL_HOST=${SMTP_HOST}
KC_MAIL_PORT=${SMTP_PORT}
KC_MAIL_FROM=${SMTP_FROM}
KC_SMTP_AUTH=true
KC_SMTP_USER=${SMTP_USER}
KC_SMTP_PASSWORD=${SMTP_PASSWORD}
KC_SMTP_SSL=false
KC_SMTP_STARTTLS=true
```

**状态文件管理：**

```
/opt/noda/
├── active-env              ← findclass-ssr 蓝绿状态（已有）
├── active-env-noda-site    ← noda-site 蓝绿状态（已有）
└── active-env-keycloak     ← Keycloak 蓝绿状态（新增）
```

每个服务独立的状态文件，互不干扰。这与 `manage-containers.sh` 的 `ACTIVE_ENV_FILE` 参数化设计完全一致。

### 3.5 一键开发环境设置（setup-dev.sh）

**目标：** 新开发者克隆仓库后运行一个脚本，即可获得完整的本地开发环境。

**脚本结构：**

```
setup-dev.sh
├── 1. 检查前置依赖（Homebrew, Docker）
├── 2. 安装宿主机 PostgreSQL（Homebrew）
├── 3. 启动 PostgreSQL 服务（brew services start postgresql@17）
├── 4. 创建本地开发数据库（noda_dev, keycloak_dev）
├── 5. 复制 .env.example → .env（提示填写密码）
├── 6. 创建 noda-network（docker network create）
├── 7. 启动基础设施（docker compose up -d postgres nginx）
├── 8. 配置 Jenkins 连接本地 PG（可选）
└── 9. 验证环境就绪
```

**与现有脚本的关系：**

| 现有脚本 | setup-dev.sh 复用方式 |
|---------|---------------------|
| `scripts/setup-jenkins.sh install` | 直接调用（Jenkins 安装） |
| `scripts/deploy/deploy-infrastructure-prod.sh` | 参考但不同（dev 环境只启动部分服务） |
| `services/postgres/init/*.sql` | 参考创建数据库（但连接宿主机 PG 而非 Docker PG） |

**关键配置：本地开发环境的数据库选择。**

本地开发时，应用连接哪个 PostgreSQL？

| 方案 | 连接目标 | 优点 | 缺点 |
|------|---------|------|------|
| A. 连接 Docker postgres-prod | `noda-infra-postgres-prod:5432` | 数据与生产一致 | Docker 容器必须运行；端口不暴露，需要 docker exec 访问 |
| B. 连接宿主机 PG | `localhost:5432/noda_dev` | 不依赖 Docker | 需要维护两套数据 |
| C. 暴露 Docker PG 端口 | `localhost:5433`（dev overlay） | 简单 | 已决定移除 dev overlay |

**推荐方案 A：** 本地开发时，通过 `docker compose up postgres` 启动生产 PostgreSQL 容器（不加 prod overlay），应用容器通过 noda-network 连接。这避免了维护两套数据的问题。

但 Jenkins 的数据库必须用宿主机 PG（Jenkins 在宿主机运行，Docker 网络外的 `noda-infra-postgres-prod` 无法直接从宿主机访问，除非暴露端口）。

**修正方案：** Jenkins 连接宿主机 PG（localhost:5432/jenkins_db），本地开发应用连接 Docker postgres-prod（通过 noda-network），两者各取所需。

---

## 四、数据流

### 4.1 基础设施 Pipeline 部署流（新增）

```
开发者手动触发 Jenkins Job "infra-deploy"
    │  参数: SERVICE=keycloak, ACTION=deploy
    │
    ▼
Jenkins 读取参数 → 确定部署策略
    │
    ├─ SERVICE=postgres ──── compose 滚动替换（有状态）
    │   │
    │   ├─ 部署前备份（pg_dump）
    │   ├─ docker compose up --force-recreate postgres
    │   ├─ 等待 healthcheck（pg_isready）
    │   ├─ 人工确认门禁（input 步骤）
    │   └─ 完成
    │
    ├─ SERVICE=keycloak ──── 蓝绿部署（零停机）
    │   │
    │   ├─ 读取 active-env-keycloak
    │   ├─ docker run keycloak-{target_color}
    │   ├─ 等待 healthcheck（TCP :8080）
    │   ├─ update upstream-keycloak.conf → nginx reload
    │   ├─ E2E 验证（curl auth.noda.co.nz/health）
    │   ├─ 人工确认门禁
    │   └─ 停止旧容器
    │
    ├─ SERVICE=nginx ──────── compose 滚动替换（无状态）
    │   │
    │   ├─ nginx -t 验证新配置
    │   ├─ docker compose up --force-recreate nginx
    │   ├─ E2E 验证
    │   └─ 完成
    │
    └─ SERVICE=noda-ops ──── compose 滚动替换（无状态）
        │
        ├─ docker compose up --force-recreate noda-ops
        ├─ healthcheck（pg_isready 检查 postgres 连接）
        └─ 完成
```

### 4.2 Jenkins H2 → PG 迁移流（新增）

```
迁移前:
  Jenkins → H2 文件 (/var/lib/jenkins/db/*.h2.db)
  备份 → Jenkins home 目录 tar

迁移步骤:
  1. 安装宿主机 PostgreSQL (Homebrew)
     └── brew install postgresql@17
     └── brew services start postgresql@17

  2. 创建 Jenkins 数据库
     └── createdb jenkins_db
     └── createuser jenkins

  3. 备份 Jenkins home
     └── systemctl stop jenkins
     └── tar czf jenkins-home-backup.tar.gz /var/lib/jenkins/

  4. 安装 Jenkins PostgreSQL 插件
     └── Jenkins UI → Manage Plugins → 安装 PostgreSQL Plugin

  5. 配置 Jenkins 数据库连接
     └── Manage Jenkins → System → Database
     └── JDBC URL: jdbc:postgresql://localhost:5432/jenkins_db
     └── Driver: org.postgresql.Driver

  6. 重启 Jenkins
     └── systemctl start jenkins

  7. 验证
     └── 检查 Jenkins 日志确认连接成功
     └── 确认 jobs 和 builds 正常

迁移后:
  Jenkins → localhost:5432/jenkins_db (PostgreSQL)
  备份 → pg_dump jenkins_db（纳入现有 B2 备份流程）
```

### 4.3 现有请求路由流（不变）

```
浏览器 → class.noda.co.nz
    → Cloudflare CDN → Tunnel → nginx:80
    → upstream findclass_backend (from upstream-findclass.conf)
    → findclass-ssr-{color}:3001
    → 内部连接 noda-infra-postgres-prod:5432/noda_prod
    → 内部连接 keycloak-{color}:8080（v1.5 蓝绿后）

浏览器 → auth.noda.co.nz
    → Cloudflare CDN → Tunnel → nginx:80
    → upstream keycloak_backend (from upstream-keycloak.conf)
    → keycloak-{color}:8080
    → 内部连接 postgres:5432/keycloak_db
```

---

## 五、架构模式

### Pattern 1: 多服务蓝绿统一框架（已验证，扩展应用）

**内容：** `manage-containers.sh` + `pipeline-stages.sh` 通过环境变量参数化，支持任意服务的蓝绿部署。

**已有验证：** findclass-ssr 和 noda-site 成功复用同一框架。

**扩展到 Keycloak：**
```bash
SERVICE_NAME=keycloak \
SERVICE_PORT=8080 \
UPSTREAM_NAME=keycloak_backend \
HEALTH_PATH="/health/ready" \
ACTIVE_ENV_FILE=/opt/noda/active-env-keycloak \
UPSTREAM_CONF=$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf \
IMAGE_NAME="quay.io/keycloak/keycloak:26.2.3" \
  manage-containers.sh start blue
```

**使用条件：** 无状态或状态在外部（数据库）的服务。

**权衡：** 每个服务需要独立的 env 模板文件和状态文件，但框架代码完全复用。

### Pattern 2: 基础设施分层部署（新增）

**内容：** 基础设施服务根据有状态性分为不同部署策略：
- 有状态（postgres）：部署前备份 + compose 滚动替换 + 人工确认
- 半有状态（keycloak）：蓝绿部署（状态在 postgres 中）
- 无状态（nginx, noda-ops）：compose 滚动替换

**使用条件：** 混合有状态/无状态服务的基础设施管理。

**权衡：** 不同策略增加 Pipeline 复杂度，但每种策略都是对应服务的最优解。

### Pattern 3: 宿主机服务 + Docker 服务分层（新增）

**内容：** 将持久化服务（Jenkins DB、开发 DB）放到宿主机，运行时服务放到 Docker。

```
宿主机层：
  PostgreSQL (Homebrew) → jenkins_db, noda_dev（持久化，易备份）
  Jenkins (systemd) → CI/CD 编排

Docker 层：
  PostgreSQL (Docker) → noda_prod, keycloak_db（生产数据）
  Keycloak → 认证服务
  Nginx → 反向代理
  noda-ops → 备份 + Tunnel
```

**使用条件：** 单服务器，需要同时运行宿主机服务和容器服务。

**权衡：** 两套 PostgreSQL 实例增加运维复杂度，但实现了关注点分离（宿主机 PG 管开发/Jenkins，Docker PG 管生产数据）。

### Pattern 4: 参数化 Jenkinsfile 复用（已验证，扩展应用）

**内容：** 通过 Jenkins environment 块设置不同的环境变量，多个 Jenkinsfile 复用同一个 `pipeline-stages.sh`。

**已有验证：** `Jenkinsfile`（findclass-ssr）和 `Jenkinsfile.noda-site` 的结构几乎相同，差异仅在 environment 块。

**扩展到基础设施：** `Jenkinsfile.infra` 可以用 parameters 块动态设置 environment：

```groovy
parameters {
    choice(name: 'SERVICE', choices: ['postgres', 'keycloak', 'noda-ops', 'nginx'],
           description: '选择要部署的基础设施服务')
}
environment {
    SERVICE_NAME = "${params.SERVICE}"
    // 根据服务类型动态设置其他参数（在 script 块中）
}
```

---

## 六、反模式

### Anti-Pattern 1: Keycloak 蓝绿 + 版本升级同时进行

**错误做法：** 在蓝绿切换的同时升级 Keycloak 版本（如 26.2.3 → 27.x）。

**原因：** Keycloak 启动时自动运行 Liquibase schema 迁移。新版本的 green 容器启动后修改数据库 schema，可能导致仍在运行的旧版本 blue 容器崩溃。

**正确做法：** 版本升级和配置变更分开进行。蓝绿部署仅用于配置变更（同版本镜像）。版本升级使用 compose 滚动替换（先停旧容器、备份数据库、启动新容器、验证、人工确认）。

### Anti-Pattern 2: 宿主机 PG 和 Docker PG 使用相同端口

**错误做法：** 宿主机 PostgreSQL 监听 5432，同时 Docker postgres-prod 也映射到宿主机 5432。

**原因：** 端口冲突。当前 Docker postgres-prod 不暴露端口（生产安全），但如果未来需要暴露，必须使用不同端口。

**正确做法：** 宿主机 PG 监听 5432（默认），Docker postgres-prod 不暴露端口。需要从宿主机访问生产数据库时，通过 `docker exec` 连接。

### Anti-Pattern 3: 所有基础设施服务都用蓝绿部署

**错误做法：** postgres、nginx、noda-ops 全部用蓝绿模式部署。

**原因：**
- PostgreSQL 是有状态服务，数据卷只能挂载到一个容器。蓝绿意味着两个 PG 容器，但只有一个能拥有数据卷。
- Nginx 是流量路由器，蓝绿切换本身依赖它。
- noda-ops 更新频率极低，蓝绿的复杂度不值得。

**正确做法：** 只有 Keycloak 用蓝绿部署（状态在 postgres 中，容器本身无状态）。其他基础设施服务用 compose 滚动替换。

### Anti-Pattern 4: setup-dev.sh 包含生产凭据

**错误做法：** 在 setup-dev.sh 中硬编码生产数据库密码或 Cloudflare Tunnel token。

**原因：** 开发环境不应该接触生产凭据。

**正确做法：** setup-dev.sh 创建本地数据库时生成本地密码，或提示用户输入。使用 `.env.example` 模板，不包含实际密码。

### Anti-Pattern 5: 修改 docker-compose.yml 移除 keycloak 服务定义

**错误做法：** 把 keycloak 从 `docker-compose.yml` 中删除，完全用 docker run 管理。

**原因：** `docker-compose.yml` 是基础设施的基础定义，保持所有服务的声明有助于理解系统全貌。keycloak 的数据库连接、网络别名等配置在 compose 文件中有完整记录。

**正确做法：** keycloak 保留在 `docker-compose.yml` 中作为声明式定义，但实际运行用 docker run 蓝绿管理（与 findclass-ssr 模式一致）。init 阶段会从 compose 容器迁移到蓝绿容器。

---

## 七、网络拓扑变更

### 7.1 当前网络（v1.4）

```
noda-network (bridge, external)
├── noda-infra-postgres-prod  (postgres:5432)
├── noda-infra-keycloak-prod  (keycloak:8080, alias: keycloak)
├── noda-infra-nginx          (:80)
├── noda-ops
├── findclass-ssr-{color}     (:3001)
├── noda-site-{color}         (:3000)
└── skykiwi-crawler           (临时)

宿主机进程空间（不在 Docker 网络内）
├── Jenkins (:8888, H2)
└── （无 PostgreSQL）
```

### 7.2 目标网络（v1.5）

```
noda-network (bridge, external)
├── noda-infra-postgres-prod  (postgres:5432)
├── keycloak-{color}          (:8080, 无 alias 或按 color alias)  ← 变更
├── noda-infra-nginx          (:80)
├── noda-ops
├── findclass-ssr-{color}     (:3001)
├── noda-site-{color}         (:3000)
└── skykiwi-crawler           (临时)

宿主机进程空间（不在 Docker 网络内）
├── Jenkins (:8888, → localhost:5432/jenkins_db)  ← 变更
└── PostgreSQL (Homebrew, :5432)                   ← 新增
    ├── jenkins_db
    └── noda_dev

已移除：
├── postgres-dev              ← 移除
└── keycloak-dev              ← 移除
```

**关键变更：Keycloak 网络别名。**

当前 `docker-compose.yml` 中 keycloak 有网络别名 `keycloak`：
```yaml
networks:
  noda-network:
    aliases:
      - keycloak
```

蓝绿部署后，容器名变为 `keycloak-blue` 和 `keycloak-green`。upstream-keycloak.conf 指向容器名（如 findclass 的模式），不再依赖网络别名。

**但现有 findclass-ssr 的 `KEYCLOAK_INTERNAL_URL: http://noda-infra-keycloak-prod:8080` 使用的是容器名，不是别名。** 蓝绿后需要改为 `http://keycloak-{color}:8080`，这需要在 env-findclass-ssr.env 中动态替换。

**解决方案：** findclass-ssr 的 KEYCLOAK_INTERNAL_URL 也可以通过 nginx 反代统一处理：
- findclass-ssr 连接 `http://noda-infra-nginx/keycloak/` → nginx 内部路由到 keycloak-{color}
- 或者直接使用容器名，在 env 文件中用变量替换

推荐：保持现有模式，在 env-findclass-ssr.env 中用变量替换。蓝绿切换后更新 env 模板中的 keycloak 容器名。

---

## 八、文件变更清单

### 新增文件

| 文件 | 用途 | 依赖 |
|------|------|------|
| `jenkins/Jenkinsfile.infra` | 基础设施统一 Pipeline | pipeline-stages.sh |
| `docker/env-keycloak.env` | Keycloak 环境变量模板 | manage-containers.sh |
| `scripts/setup-dev.sh` | 一键开发环境设置 | setup-jenkins.sh |
| `config/nginx/snippets/upstream-keycloak.conf` | Keycloak upstream 动态切换 | nginx reload |

**注意：** `upstream-keycloak.conf` 已存在但内容是静态的，需要改为动态格式（与 upstream-findclass.conf 一致）。

### 修改文件

| 文件 | 修改内容 | 影响范围 |
|------|---------|---------|
| `config/nginx/snippets/upstream-keycloak.conf` | 从静态 `keycloak:8080` 改为动态 `keycloak-{color}:8080` | nginx 路由 |
| `scripts/pipeline-stages.sh` | 新增基础设施部署函数（不修改现有函数） | Pipeline |
| `docker/docker-compose.dev.yml` | 移除 postgres-dev、keycloak-dev，简化 nginx overlay | 开发环境 |
| `scripts/setup-jenkins.sh` | 添加 PG 迁移子命令 | Jenkins 管理 |
| `docker/env-findclass-ssr.env` | KEYCLOAK_INTERNAL_URL 改为动态 | 应用配置 |

### 删除内容（不移除文件，清空内容）

| 文件/内容 | 删除原因 |
|----------|---------|
| `docker-compose.dev.yml` 中 postgres-dev 服务定义 | 替代为宿主机 PG |
| `docker-compose.dev.yml` 中 keycloak-dev 服务定义 | 不再需要独立 dev Keycloak |
| `docker/volumes/postgres_dev_data`（Docker volume） | postgres-dev 移除后不再需要 |

---

## 九、构建顺序建议

```
Phase 1: 宿主机 PostgreSQL 安装
  │  brew install postgresql@17
  │  创建 jenkins_db, noda_dev 数据库
  │  验证: psql 连接正常
  │
  ├─ 依赖：无
  └─ 风险：低（纯新增，不影响现有服务）

Phase 2: Jenkins H2 → PG 迁移
  │  安装 PostgreSQL 插件
  │  配置 JDBC 连接
  │  重启 Jenkins
  │  验证: Jenkins 正常启动，jobs/builds 完整
  │
  ├─ 依赖：Phase 1（宿主机 PG 必须先就绪）
  └─ 风险：中（Jenkins 可能短暂不可用，需要回滚方案）
  │  回滚方案：恢复 H2 配置，重启 Jenkins

Phase 3: 移除 postgres-dev / keycloak-dev
  │  编辑 docker-compose.dev.yml
  │  停止并移除旧容器
  │  清理 Docker volumes
  │  验证: docker compose config 正确
  │
  ├─ 依赖：Phase 1（开发数据库迁移到宿主机 PG）
  └─ 风险：低（仅移除开发环境容器，不影响生产）

Phase 4: Keycloak 蓝绿部署基础设施
  │  创建 docker/env-keycloak.env 模板
  │  修改 upstream-keycloak.conf 格式
  │  从 compose 单容器迁移到蓝绿 blue 容器
  │  验证: auth.noda.co.nz 正常访问
  │
  ├─ 依赖：无（可独立进行）
  └─ 风险：中（认证服务短暂中断 ~60-90s）

Phase 5: 统一基础设施 Pipeline
  │  编写 Jenkinsfile.infra
  │  扩展 pipeline-stages.sh
  │  配置 Jenkins Job
  │  测试各服务部署流程
  │  验证: 完整 Pipeline 端到端运行
  │
  ├─ 依赖：Phase 4（Keycloak 蓝绿基础设施）
  └─ 风险：低（Pipeline 变更，不直接修改运行中的服务）

Phase 6: 一键开发环境脚本
  │  编写 setup-dev.sh
  │  测试在干净环境下的执行
  │  验证: 新开发者可以一键配置环境
  │
  ├─ 依赖：Phase 1（宿主机 PG 安装逻辑可参考）
  └─ 风险：低（纯开发体验改善）
```

**Phase 排序理由：**
1. Phase 1 是基础 — 所有其他功能都依赖宿主机 PG
2. Phase 2 紧跟 Phase 1 — Jenkins 迁移是宿主机 PG 的主要消费者
3. Phase 3 在 Phase 1 之后 — 需要宿主机 PG 替代 postgres-dev
4. Phase 4 独立 — Keycloak 蓝绿与 PG 无关，但需要稳定后再接入 Pipeline
5. Phase 5 在 Phase 4 之后 — Pipeline 需要所有部署策略已验证
6. Phase 6 最后 — 开发环境脚本整合所有变更

---

## 十、可扩展性考虑

| 关注点 | 当前（~10 容器） | 增长（~20 容器） | 大型 |
|-------|----------------|----------------|------|
| 部署管理 | 独立 Jenkinsfile | 统一参数化 Pipeline | Shared Library |
| 蓝绿状态 | 宿主机文件（每服务一个） | 同上 | Consul/etcd |
| 数据库 | 单 PG 容器 + 宿主机 PG | 同上 | PG 集群 + 读写分离 |
| Jenkins 存储 | H2 → 单 PG | 单 PG 够用 | PG 集群 |
| 备份 | 单脚本 pg_dump | 同上 | WAL 归档 + PITR |

**当前阶段结论：** 单服务器架构，所有模式都是最简实现。宿主机 PG + Docker PG 的双层模式在单服务器上完全可行。

---

## 数据源

| 来源 | 置信度 | 用途 |
|------|--------|------|
| `docker/docker-compose.yml` | HIGH（直接读取） | 基础设施服务定义、keycloak 网络别名 |
| `docker/docker-compose.dev.yml` | HIGH（直接读取） | postgres-dev、keycloak-dev 定义、要移除的内容 |
| `docker/docker-compose.app.yml` | HIGH（直接读取） | 应用服务环境变量参考 |
| `docker/docker-compose.prod.yml` | HIGH（直接读取） | 生产 overlay、Keycloak SMTP 配置 |
| `config/nginx/conf.d/default.conf` | HIGH（直接读取） | keycloak_backend 引用方式 |
| `config/nginx/snippets/upstream-keycloak.conf` | HIGH（直接读取） | 当前静态 upstream 格式 |
| `config/nginx/snippets/upstream-findclass.conf` | HIGH（直接读取） | 蓝绿动态格式参考 |
| `config/nginx/snippets/upstream-noda-site.conf` | HIGH（直接读取） | 多服务蓝绿验证 |
| `jenkins/Jenkinsfile` | HIGH（直接读取） | 现有 Pipeline 结构 |
| `jenkins/Jenkinsfile.noda-site` | HIGH（直接读取） | 参数化 Pipeline 参考 |
| `scripts/pipeline-stages.sh` | HIGH（直接读取） | 共享函数库、扩展点 |
| `scripts/manage-containers.sh` | HIGH（直接读取） | 蓝绿容器管理、参数化设计 |
| `scripts/setup-jenkins.sh` | HIGH（直接读取） | Jenkins 安装逻辑 |
| `docker/env-findclass-ssr.env` | HIGH（直接读取） | env 模板格式参考 |
| `services/postgres/init/*.sql` | HIGH（直接读取） | 数据库初始化脚本 |
| `.planning/PROJECT.md` | HIGH（直接读取） | v1.5 里程碑目标 |
| Keycloak 数据库迁移机制 | MEDIUM（训练数据） | SPI migration strategy 配置 |
| Jenkins PostgreSQL 插件 | MEDIUM（训练数据） | 数据库连接配置方式 |

---

*Architecture research for: Noda v1.5 开发环境本地化 + 基础设施 CI/CD*
*Researched: 2026-04-17*
