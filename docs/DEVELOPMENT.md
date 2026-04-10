<!-- generated-by: gsd-doc-writer -->

# 开发指南

本指南面向需要在本地搭建 Noda 基础设施开发环境的开发者，涵盖环境搭建、构建命令、代码规范和部署脚本的使用方法。

## 本地环境搭建

### 前置条件

| 依赖 | 版本要求 | 用途 |
|------|---------|------|
| Docker Engine | >= 20.x | 容器运行时 |
| Docker Compose | >= 2.x（V2 插件） | 多容器编排 |
| SOPS | 最新版 | 密钥解密（仅生产环境需要） |
| age | 最新版 | SOPS 密钥加密工具 |
| PostgreSQL 客户端 | 可选 | 本地数据库调试 |

### 步骤 1：克隆仓库

```bash
git clone <仓库地址> noda-infra
cd noda-infra
```

### 步骤 2：配置环境变量

创建 `.env` 文件（或使用 `config/secrets.local.yaml` 存储本地开发密钥）。生产环境使用 `config/secrets.sops.yaml` 加密存储。

关键变量（参考 `config/secrets.local.yaml` 结构）：

- `POSTGRES_USER` / `POSTGRES_PASSWORD` — 数据库凭据
- `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` — Keycloak 管理员凭据
- `CLOUDFLARE_TUNNEL_TOKEN` — Cloudflare Tunnel 令牌（开发环境可选）
- `B2_ACCOUNT_ID` / `B2_APPLICATION_KEY` / `B2_BUCKET_NAME` — B2 云备份存储配置

### 步骤 3：创建 Docker 网络

```bash
docker network create noda-network
```

### 步骤 4：启动开发环境

使用双文件覆盖模式启动开发环境：

```bash
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d
```

或者使用环境切换脚本一键操作：

```bash
bash scripts/utils/switch-env.sh dev
```

开发环境与生产环境的主要差异：

| 配置项 | 开发环境 | 生产环境 |
|--------|---------|---------|
| Compose 文件 | `docker-compose.yml` + `docker-compose.dev.yml` | `docker-compose.yml` + `docker-compose.prod.yml` |
| PostgreSQL 端口 | `5433:5432`（避免冲突） | `5432:5432` |
| Nginx 端口 | `8081:80` | `80:80` |
| Keycloak `KC_HOSTNAME` | 空（允许 localhost 访问） | `https://auth.noda.co.nz` |
| Keycloak `KC_PROXY` | `none` | `edge` |
| findclass-ssr 端口 | `3002:3001` | 内部网络 |
| 资源限制 | 无限制 | CPU/内存限额 |

### 独立开发环境（仅 PostgreSQL）

如果只需要数据库进行开发，无需启动完整基础设施：

```bash
docker compose -f docker/docker-compose.dev-standalone.yml up -d
```

此配置使用独立的 `noda-dev` 项目名和网络，默认凭据为 `dev_user` / `dev_password_change_me`，数据库 `noda_dev`，端口 `5433`。

## 构建命令

Noda 基础设施没有 `package.json`，所有构建和部署通过 Docker Compose 和 Shell 脚本完成。

### Docker Compose 命令

| 命令 | 说明 |
|------|------|
| `docker compose -f docker/docker-compose.yml up -d` | 启动基础服务（PostgreSQL + Keycloak + Nginx + noda-ops） |
| `docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d` | 启动开发环境 |
| `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d` | 启动生产环境 |
| `docker compose -f docker/docker-compose.app.yml build findclass-ssr` | 构建 findclass-ssr 应用镜像 |
| `docker compose -f docker/docker-compose.app.yml up -d findclass-ssr` | 启动应用服务 |
| `docker compose -f docker/docker-compose.app.yml down` | 停止并删除应用容器 |

### 部署脚本

| 脚本路径 | 用途 |
|---------|------|
| `scripts/deploy/deploy-infrastructure-prod.sh` | 生产环境基础设施完整部署（6 步自动化：验证 → 初始化数据库 → 停容器 → 启动 → 等待就绪 → 配置 Keycloak） |
| `scripts/deploy/deploy-apps-prod.sh` | 生产环境应用部署（验证基础设施 → 构建 → 启动 findclass-ssr） |
| `scripts/deploy/deploy-findclass.sh` | findclass-ssr 独立部署（含 sitemap 生成 + 镜像构建） |
| `scripts/deploy/deploy-findclass-zero-deps.sh` | findclass-ssr 零依赖部署 |
| `scripts/deploy/migrate-production.sh` | 生产环境数据库迁移（含备份提醒和确认机制） |

### 运维脚本

| 脚本路径 | 用途 |
|---------|------|
| `deploy.sh` | 备份系统部署（build / start / stop / restart / logs / status / clean） |
| `scripts/init-databases.sh` | 初始化所有必要数据库（keycloak, findclass_db, noda_prod 等） |
| `scripts/setup-keycloak-full.sh` | Keycloak 完整初始化（创建 realm、client、Google Identity Provider） |
| `scripts/utils/switch-env.sh` | 一键切换开发/生产环境（停止容器 → 加载变量 → 启动） |
| `scripts/utils/validate-all.sh` | 运行完整验证套件（目录结构、Docker 配置、环境变量） |
| `scripts/utils/decrypt-secrets.sh` | SOPS 密钥解密 |
| `scripts/utils/check-env.sh` | 环境变量检查 |

### 验证脚本

| 脚本路径 | 用途 |
|---------|------|
| `scripts/verify/quick-verify.sh` | 快速验证（容器状态 + 数据统计 + API 测试） |
| `scripts/verify/verify-infrastructure.sh` | 基础设施服务状态验证 |
| `scripts/verify/verify-apps.sh` | 应用服务状态验证 |
| `scripts/verify/verify-services.sh` | 完整服务验证 |
| `scripts/verify/verify-findclass.sh` | findclass-ssr 专项验证 |

### 备份系统

| 脚本路径 | 用途 |
|---------|------|
| `scripts/backup/backup-postgres.sh` | PostgreSQL 完整备份流程（健康检查 → 备份 → 验证 → B2 云上传 → 清理） |
| `scripts/backup/restore-postgres.sh` | 数据库恢复 |
| `scripts/backup/verify-restore.sh` | 恢复验证 |
| `scripts/backup/test-verify-weekly.sh` | 每周自动验证测试 |

备份通过 crontab 自动执行（部署在 `noda-ops` 容器内，由 `deploy/crontab` 配置）：

- 每天凌晨 3:00 执行备份
- 每周日凌晨 3:00 执行验证测试
- 每 6 小时清理历史记录
- 每天凌晨 4:00 清理 7 天前的备份文件

## 代码风格与配置规范

本项目是基础设施配置仓库，主要包含 Docker Compose YAML、Shell 脚本、Nginx 配置和 Dockerfile。没有使用 ESLint、Prettier 等代码格式化工具。

### Shell 脚本规范

通过现有代码可以观察到以下约定：

- 所有脚本使用 `set -euo pipefail` 或 `set -e` 开头
- 使用彩色日志函数：`log_info`、`log_success`、`log_warn`、`log_error`
- 注释使用中文，变量名和技术术语保持英文
- 脚本头部包含功能说明、用途和用法

### Docker Compose 规范

- 基础配置在 `docker-compose.yml`，环境特定配置通过覆盖文件实现
- 项目名保持一致：`noda-infra`（基础 + 生产）、`noda-apps`（应用）、`noda-dev`（独立开发）
- 服务间通过 `noda-network` 外部网络通信
- 所有服务配置 `restart: unless-stopped` 和健康检查

### Nginx 配置

- 主配置：`config/nginx/nginx.conf`
- 虚拟主机：`config/nginx/conf.d/default.conf`
- 可复用片段：`config/nginx/snippets/` 目录
- 每个域名独立 `server` 块，包含安全头和 gzip 配置

### Dockerfile 规范

- 使用多阶段构建减小镜像体积（参见 `deploy/Dockerfile.findclass-ssr`）
- 运行时使用非 root 用户（`nodejs:1001`）
- `VITE_*` 构建参数通过 `ARG` 声明，构建时写入 JS 文件，运行时环境变量无法覆盖
- 使用 Alpine 基础镜像

### 密钥管理

- 本地开发：`config/secrets.local.yaml`（已加入 `.gitignore`）
- 生产环境：`config/secrets.sops.yaml`（SOPS 加密，提交到 Git）
- 备份系统：`scripts/backup/.env.backup`（已加入 `.gitignore`）
- 解密密钥：`config/keys/` 目录（已加入 `.gitignore`）

## 分支管理

当前仓库只有 `main` 分支，没有文档化的分支命名规范。

从 Git 历史来看，提交信息遵循以下格式：

- `fix:` — 问题修复
- `docs:` — 文档更新
- `feat:` — 新功能（如有）

## 提交流程

本项目没有配置 `.github/` 目录，不存在 PR 模板或 GitHub Actions CI/CD 流水线。

### 手动部署流程

生产环境部署分为基础设施和应用两个独立步骤：

**1. 部署基础设施（PostgreSQL + Keycloak + Nginx）：**

```bash
bash scripts/deploy/deploy-infrastructure-prod.sh
```

此脚本自动执行：验证环境 → 初始化数据库 → 停止旧容器 → 启动新容器 → 等待就绪 → 配置 Keycloak。

**2. 部署应用（findclass-ssr）：**

```bash
bash scripts/deploy/deploy-apps-prod.sh
```

此脚本自动执行：验证基础设施 → 停止旧容器 → 构建并启动新容器。

### 关键注意事项

1. **构建时 vs 运行时变量**：`VITE_*` 前端变量在 `docker build` 时写入 JS 文件，修改前端配置必须重新构建镜像，不能只改运行时环境变量。
2. **项目名一致性**：`docker-compose.yml` 和 `docker-compose.prod.yml` 的项目名必须一致（`noda-infra`），否则会创建重复容器和空数据卷。
3. **Cloudflare 缓存**：静态资源更新后需要清除 CDN 缓存。静态资源 URL 包含 hash，但 `index.html` 会被缓存。
4. **密钥解密**：生产部署需要 SOPS 解密密钥文件（`config/keys/git-age-key.txt`）才能读取 `secrets.sops.yaml`。
