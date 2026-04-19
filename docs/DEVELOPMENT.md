<!-- generated-by: gsd-doc-writer -->

# 开发指南

本指南面向需要在本地搭建 Noda 基础设施开发环境的开发者，涵盖环境搭建、构建命令、代码规范和部署脚本的使用方法。

## 本地环境搭建

### 前置条件

| 依赖 | 版本要求 | 用途 |
|------|---------|------|
| Docker Engine | >= 20.x | 容器运行时 |
| Docker Compose | >= 2.x（V2 插件） | 多容器编排 |
| Doppler CLI | 3.x+ | 密钥拉取（仅生产环境需要） |
| age | 1.3+ | Doppler 备份加密 |
| PostgreSQL 客户端 | 可选 | 本地数据库调试 |

### 快速开始（一键搭建）

如果你是首次搭建 Noda 开发环境，使用一键脚本即可完成本地 PostgreSQL 安装和数据库初始化：

```bash
bash setup-dev.sh
```

脚本自动执行以下步骤：
1. 检查 Homebrew 是否安装
2. 安装 PostgreSQL 17（与生产版本匹配）
3. 创建开发数据库（noda_dev, keycloak_dev）
4. 验证环境状态

脚本支持重复运行——已安装的组件会被跳过，不会破坏现有数据。

> **单独管理 PostgreSQL：** 如需更精细的 PG 管理（状态查看、数据库初始化、卸载），使用 `bash scripts/setup-postgres-local.sh <install|status|init-db|uninstall>`。

### 步骤 1：克隆仓库

```bash
git clone <仓库地址> noda-infra
cd noda-infra
```

### 步骤 2：配置环境变量

生产环境使用 Doppler 云端密钥管理（项目 `noda`，环境 `prd`），本地开发使用 `config/secrets.local.yaml`（已加入 `.gitignore`）。

密钥文件中的变量：

- `cloudflare_tunnel_token` — Cloudflare Tunnel 令牌（开发环境可选）
- `google_oauth_client_id` / `google_oauth_client_secret` — Google OAuth 凭据（可选）

Docker Compose 通过环境变量注入其他配置（在 `docker-compose.yml` 中引用）：

- `POSTGRES_USER` / `POSTGRES_PASSWORD` — 数据库凭据
- `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` — Keycloak 管理员凭据
- `B2_ACCOUNT_ID` / `B2_APPLICATION_KEY` / `B2_BUCKET_NAME` — B2 云备份存储配置
- `SMTP_HOST` / `SMTP_PORT` / `SMTP_USER` / `SMTP_PASSWORD` / `SMTP_FROM` — 邮件服务配置（生产环境）

生产部署时，通过 `scripts/lib/secrets.sh` 的 `load_secrets()` 函数从 Doppler 拉取密钥并导出为环境变量。

### 步骤 3：创建 Docker 网络

```bash
docker network create noda-network
```

### 步骤 4：启动开发环境

使用双文件覆盖模式启动开发环境：

```bash
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d
```

开发环境与生产环境的主要差异：

| 配置项 | 开发环境 | 生产环境 |
|--------|---------|---------|
| Compose 文件 | `docker-compose.yml` + `docker-compose.dev.yml` | `docker-compose.yml` + `docker-compose.prod.yml` |
| PostgreSQL 端口 | `5433:5432`（开发容器），生产端口不暴露 | `5432:5432`（内部网络） |
| Nginx 端口 | `8081:80` | `80:80` |
| Keycloak `KC_HOSTNAME` | 空（允许 localhost 访问） | `https://auth.noda.co.nz` |
| Keycloak `KC_PROXY` | `none` | `edge` |
| findclass-ssr 端口 | `3002:3001` | 内部网络 |
| Cloudflare Tunnel | 禁用（通过 `profiles: [dev]`） | 自动启动 |
| 资源限制 | 无限制 | CPU/内存限额 |

### 本地开发数据库（PostgreSQL）

开发环境使用本地 PostgreSQL（Homebrew 安装），不再需要 Docker 开发数据库容器。

**首次搭建**使用一键脚本：

```bash
bash setup-dev.sh
```

**日常管理**使用专用脚本：

```bash
bash scripts/setup-postgres-local.sh status    # 查看状态
bash scripts/setup-postgres-local.sh init-db   # 重建开发数据库
bash scripts/setup-postgres-local.sh uninstall # 卸载 PostgreSQL
```

### 独立开发环境（仅 PostgreSQL，Docker 备选）

如果需要 Docker 方式的数据库环境，可以使用独立 Compose 配置：

```bash
docker compose -f docker/docker-compose.dev-standalone.yml up -d
```

此配置使用独立的 `noda-dev` 项目名和网络（`noda-dev-network`），默认凭据为 `dev_user` / `dev_password_change_me`，数据库 `noda_dev`，端口 `5433`。

### 简化版环境（无需构建）

`docker-compose.simple.yml` 提供无需构建镜像的最小化配置，包含 PostgreSQL（prod + dev）、Keycloak、Nginx 和 Cloudflare Tunnel，所有凭据使用默认值。适用于快速验证或初次搭建。

## 构建命令

Noda 基础设施没有 `package.json`，所有构建和部署通过 Docker Compose 和 Shell 脚本完成。

### Docker Compose 命令

| 命令 | 说明 |
|------|------|
| `docker compose -f docker/docker-compose.yml up -d` | 启动基础服务（PostgreSQL + Keycloak + Nginx + noda-ops + findclass-ssr） |
| `docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d` | 启动开发环境 |
| `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d` | 启动生产环境（基础设施） |
| `docker compose -f docker/docker-compose.app.yml build findclass-ssr` | 构建 findclass-ssr 应用镜像 |
| `docker compose -f docker/docker-compose.app.yml up -d findclass-ssr` | 启动应用服务（独立部署） |
| `docker compose -f docker/docker-compose.app.yml down` | 停止并删除应用容器 |

### 部署脚本

| 脚本路径 | 用途 |
|---------|------|
| `scripts/deploy/deploy-infrastructure-prod.sh` | 生产环境完整部署。使用 3 个 compose 文件（base + prod + dev）启动所有服务（包括 findclass-ssr），自动执行 5 步：验证环境 → 停止旧容器并启动新容器 → 等待健康检查 → 初始化数据库 → 配置 Keycloak → 验证 |
| `scripts/deploy/deploy-apps-prod.sh` | 生产环境应用部署。验证基础设施 → 停止旧容器 → 构建并启动 findclass-ssr |
| `scripts/deploy/deploy-findclass-zero-deps.sh` | findclass-ssr 零依赖部署 |
| `scripts/deploy/migrate-production.sh` | 生产环境数据库迁移（含备份提醒和交互确认机制） |

### 运维脚本

| 脚本路径 | 用途 |
|---------|------|
| `scripts/init-databases.sh` | 初始化所有必要数据库（`noda_prod`、`keycloak`） |
| `scripts/setup-keycloak-full.sh` | Keycloak 完整初始化（创建 realm、client、Google Identity Provider） |
| `scripts/utils/validate-docker.sh` | Docker Compose 配置语法验证 |

### 验证脚本

| 脚本路径 | 用途 |
|---------|------|
| `scripts/verify/quick-verify.sh` | 快速验证（容器状态 + 数据统计 + API 测试） |
| `scripts/verify/verify-infrastructure.sh` | 基础设施服务状态验证 |
| `scripts/verify/verify-apps.sh` | 应用服务状态验证 |
| `scripts/verify/verify-services.sh` | 完整服务验证 |
| `scripts/verify/verify-findclass.sh` | findclass-ssr 专项验证 |

### 备份系统

备份系统运行在 `noda-ops` 容器内，由 `supervisord` 管理 cron 和 Cloudflare Tunnel 两个进程。

**核心脚本（`scripts/backup/`）：**

| 脚本路径 | 用途 |
|---------|------|
| `backup-postgres.sh` | PostgreSQL 完整备份流程（健康检查 → 备份 → 验证 → B2 云上传 → 清理） |
| `restore-postgres.sh` | 数据库恢复 |
| `verify-restore.sh` | 恢复验证 |
| `test-verify-weekly.sh` | 每周自动验证测试 |

**备份工具库（`scripts/backup/lib/`）：**

| 库文件 | 功能 |
|--------|------|
| `config.sh` | 配置加载和验证，含默认值 |
| `constants.sh` | 常量定义 |
| `db.sh` | 数据库操作封装 |
| `health.sh` | 健康检查 |
| `cloud.sh` | B2 云存储操作（rclone） |
| `metrics.sh` | 备份指标记录和历史清理 |
| `restore.sh` | 恢复操作 |
| `verify.sh` | 备份文件验证 |
| `test-verify.sh` | 验证测试逻辑 |
| `alert.sh` | 告警通知 |
| `log.sh` | 日志记录 |
| `util.sh` | 通用工具函数 |

备份通过 crontab 自动执行（配置文件 `deploy/crontab`，在 `noda-ops` 容器内运行）：

- 每天凌晨 3:00 执行备份
- 每周日凌晨 3:00 执行验证测试
- 每 6 小时清理历史记录（`metrics.sh cleanup`）
- 每天凌晨 4:00 清理 7 天前的备份文件

**旧版独立部署（已弃用）：** `deploy.sh` 和 `deploy/Dockerfile.backup` 用于独立部署备份服务（容器名 `opdev`），现已合并到 `noda-ops` 容器（使用 `Dockerfile.noda-ops`）。如需手动管理备份服务，参考 `docker/OPDEV_MANAGEMENT.md`。

## 代码风格与配置规范

本项目是基础设施配置仓库，主要包含 Docker Compose YAML、Shell 脚本、Nginx 配置和 Dockerfile。没有使用 ESLint、Prettier 等代码格式化工具。

### Shell 脚本规范

通过现有代码可以观察到以下约定：

- 所有脚本使用 `set -euo pipefail` 或 `set -e` 开头（严格错误处理）
- 使用统一日志库 `scripts/lib/log.sh`，提供 `log_info`、`log_success`、`log_warn`、`log_error` 四个彩色日志函数
- 注释使用中文，变量名和技术术语保持英文
- 脚本头部包含功能说明、用途和用法注释
- 备份系统脚本按职责拆分到 `scripts/backup/lib/` 目录，每个库文件职责单一

### Docker Compose 规范

- 基础配置在 `docker-compose.yml`，环境特定配置通过覆盖文件实现
- 项目名保持一致：`noda-infra`（基础 + 生产 + 开发）、`noda-apps`（独立应用部署）、`noda-dev`（独立开发）
- 服务间通过 `noda-network` 外部网络通信
- 所有服务配置 `restart: unless-stopped` 和健康检查
- 生产环境通过 `deploy.resources` 设置 CPU/内存限额

### Nginx 配置

- 主配置：`config/nginx/nginx.conf`
- 虚拟主机：`config/nginx/conf.d/default.conf`
- 可复用片段：`config/nginx/snippets/proxy-common.conf`、`config/nginx/snippets/proxy-websocket.conf`
- 每个域名独立 `server` 块，包含安全头和 gzip 配置

### Dockerfile 规范

- 使用多阶段构建减小镜像体积（参见 `deploy/Dockerfile.findclass-ssr`）
- 运行时使用非 root 用户（`nodejs:1001`，uid/gid 1001）
- `VITE_*` 构建参数通过 `ARG` 声明，构建时写入 JS 文件，运行时环境变量无法覆盖
- 使用 Alpine 基础镜像（`node:20-alpine`、`alpine:3.19`、`postgres:17-alpine`）
- `noda-ops` 使用 `supervisord` 管理多进程（cron + cloudflared）

### PostgreSQL 生产配置

生产环境使用自定义 `postgresql.conf`（`services/postgres/conf/postgresql.conf`），主要配置：

- 内存：`shared_buffers = 256MB`，`effective_cache_size = 1GB`，`work_mem = 16MB`
- WAL 归档：`wal_level = replica`，`archive_mode = on`，支持 PITR（时间点恢复）
- 时区：`Pacific/Auckland`
- 初始化脚本：`services/postgres/init/` 创建数据库和 schema

### 密钥管理

- 本地开发：`config/secrets.local.yaml`（已加入 `.gitignore`）— 存储 Cloudflare Tunnel Token 和 Google OAuth 凭据
- 生产环境：Doppler 云端密钥管理（项目 `noda`，环境 `prd`）
- 备份系统：`scripts/backup/.env.backup`（已加入 `.gitignore`）— 旧版独立部署使用
- 生产部署：通过 `scripts/lib/secrets.sh` 的 `load_secrets()` 从 Doppler 拉取密钥

## 分支管理

当前仓库只有 `main` 分支，没有文档化的分支命名规范。

从 Git 历史来看，提交信息遵循 Conventional Commits 格式：

- `fix:` — 问题修复
- `docs:` — 文档更新
- `feat:` — 新功能
- `refactor:` — 代码重构
- `chore:` — 杂项维护

## 提交流程

本项目没有配置 `.github/` 目录，不存在 PR 模板或 GitHub Actions CI/CD 流水线。

### 手动部署流程

生产环境部署分为基础设施和应用两个独立步骤：

**1. 部署基础设施（PostgreSQL + Keycloak + Nginx + noda-ops + findclass-ssr）：**

```bash
bash scripts/deploy/deploy-infrastructure-prod.sh
```

此脚本自动执行：验证环境（检查 Docker）→ 停止旧容器 → 使用 3 个 compose 文件（base + prod + dev）启动所有服务 → 等待健康检查 → 初始化数据库 → 配置 Keycloak → 验证。

**2. 单独部署应用（findclass-ssr）：**

```bash
bash scripts/deploy/deploy-apps-prod.sh
```

此脚本自动执行：验证基础设施 → 停止旧容器 → 构建并启动新容器。

### 关键注意事项

1. **构建时 vs 运行时变量**：`VITE_*` 前端变量在 `docker build` 时写入 JS 文件，修改前端配置必须重新构建镜像，不能只改运行时环境变量。
2. **项目名一致性**：`docker-compose.yml` 和 `docker-compose.prod.yml` 的项目名必须一致（`noda-infra`），否则会创建重复容器和空数据卷。
3. **Cloudflare 缓存**：静态资源更新后需要清除 CDN 缓存。静态资源 URL 包含 hash，但 `index.html` 会被缓存。
4. **密钥管理**：生产部署需要设置 `DOPPLER_TOKEN` 环境变量，通过 `load_secrets()` 从 Doppler 拉取密钥。
5. **findclass-ssr 的 DATABASE_URL**：基础 compose 文件中数据库主机名为 `postgres`（服务名），而独立应用 compose（`docker-compose.app.yml`）中为 `noda-infra-postgres-prod`（容器名），需注意网络连通性。
