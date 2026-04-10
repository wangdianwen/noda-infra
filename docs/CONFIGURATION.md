<!-- generated-by: gsd-doc-writer -->
# 配置指南

本文档详细描述 Noda 基础设施项目的所有配置项，包括环境变量、配置文件、密钥管理以及各环境的差异。

---

## 环境变量

环境变量是项目的主要配置方式。Docker Compose 文件通过 `${VAR}` 和 `${VAR:-default}` 语法引用这些变量。

### 基础设施核心变量

| 变量名 | 必填 | 默认值 | 说明 |
|--------|------|--------|------|
| `POSTGRES_USER` | 是 | — | PostgreSQL 超级用户名 |
| `POSTGRES_PASSWORD` | 是 | — | PostgreSQL 超级用户密码（生产环境必须修改） |
| `POSTGRES_DB` | 是 | — | PostgreSQL 默认数据库名 |
| `KEYCLOAK_ADMIN_USER` | 是 | — | Keycloak 管理员用户名 |
| `KEYCLOAK_ADMIN_PASSWORD` | 是 | — | Keycloak 管理员密码（生产环境必须修改） |
| `KEYCLOAK_DB_PASSWORD` | 是 | — | Keycloak 数据库连接密码 |

### Cloudflare Tunnel 变量

| 变量名 | 必填 | 默认值 | 说明 |
|--------|------|--------|------|
| `CLOUDFLARE_TUNNEL_TOKEN` | 是 | — | Cloudflare Tunnel 认证 Token，用于建立安全隧道连接 |

<!-- VERIFY: Cloudflare Tunnel Token 从 Cloudflare Zero Trust Dashboard 获取 -->

### 备份系统变量（noda-ops 容器）

| 变量名 | 必填 | 默认值 | 说明 |
|--------|------|--------|------|
| `B2_ACCOUNT_ID` | 是 | — | Backblaze B2 账户 ID |
| `B2_APPLICATION_KEY` | 是 | — | Backblaze B2 Application Key（仅限指定 bucket） |
| `B2_BUCKET_NAME` | 否 | `noda-backups` | B2 存储桶名称 |
| `B2_PATH` | 否 | `backups/postgres/` | B2 存储桶内的备份路径 |
| `ALERT_EMAIL` | 否 | （空） | 备份告警接收邮箱 |

### 邮件服务变量（SMTP - 用于密码重置）

| 变量名 | 必填 | 默认值 | 说明 |
|--------|------|--------|------|
| `SMTP_HOST` | 否 | — | SMTP 服务器地址 |
| `SMTP_PORT` | 否 | `587` | SMTP 服务器端口 |
| `SMTP_FROM` | 否 | — | 发件人地址 |
| `SMTP_USER` | 否 | — | SMTP 认证用户名 |
| `SMTP_PASSWORD` | 否 | — | SMTP 认证密码 |

<!-- VERIFY: SMTP 服务的实际配置值取决于邮件服务提供商 -->

### 应用变量（findclass-ssr 容器）

| 变量名 | 必填 | 默认值 | 说明 |
|--------|------|--------|------|
| `RESEND_API_KEY` | 否 | （空） | Resend 邮件 API 密钥 |

### 构建时变量（Dockerfile ARG）

findclass-ssr 的 `VITE_*` 变量在 `docker build` 阶段写入前端 JS 文件，**运行时环境变量无法覆盖**。修改这些值后必须重新构建镜像。

| 变量名 | 必填 | 默认值 | 说明 |
|--------|------|--------|------|
| `VITE_KEYCLOAK_URL` | 是 | `https://auth.noda.co.nz` | 前端使用的 Keycloak URL |
| `VITE_KEYCLOAK_REALM` | 是 | `noda` | Keycloak Realm 名称 |
| `VITE_KEYCLOAK_CLIENT_ID` | 是 | `noda-frontend` | Keycloak Client ID |

> **重要提醒**：`VITE_*` 变量在构建时写入 JavaScript 文件，修改后必须重新构建镜像。仅修改运行时环境变量不会影响前端行为。

---

## 配置文件

项目使用多层配置文件体系，按功能分散在不同目录。

### 环境变量文件

| 文件路径 | 用途 | 提交到 Git |
|----------|------|-----------|
| `config/environments/.env.example` | 变量模板和文档 | 是 |
| `config/environments/.env.production.template` | 生产环境模板 | 是 |
| `config/environments/.env.production` | 生产环境实际值（需从 `.env.production.template` 创建） | 否 |
| `docker/.env` | Docker Compose 主配置 | 否（含敏感信息） |
| `scripts/backup/.env.backup` | 备份系统专用配置 | 否（含 B2 密钥） |
| `scripts/backup/templates/.env.backup` | 备份配置模板 | 是 |

### Nginx 配置

| 文件路径 | 说明 |
|----------|------|
| `config/nginx/nginx.conf` | Nginx 主配置（worker 进程数、日志格式、gzip 压缩） |
| `config/nginx/conf.d/default.conf` | 虚拟主机配置（域名路由规则） |
| `config/nginx/snippets/proxy-common.conf` | 通用代理头设置（Host、X-Forwarded-*） |
| `config/nginx/snippets/proxy-websocket.conf` | 带 WebSocket 支持的代理头设置 |

Nginx 路由规则概览：
- `auth.noda.co.nz` -> 代理到 `keycloak:8080`
- `class.noda.co.nz` / `localhost` -> 代理到 `findclass-ssr:3001`
- `/health` -> 返回 200 健康检查响应

### Cloudflare Tunnel 配置

| 文件路径 | 说明 |
|----------|------|
| `config/cloudflare/config.yml` | Tunnel 入站规则（域名到服务的映射） |

Tunnel ID: `9cab5df3-a546-48fb-9dc5-eacb48c56ff8` <!-- VERIFY: Tunnel ID 来自 Cloudflare Dashboard -->

入站规则：
- `noda.co.nz` -> `http://noda-nginx:80`
- `auth.noda.co.nz` -> `http://keycloak:8080`
- `localhost.noda.co.nz` -> `http://noda-nginx:80`
- `health.noda.co.nz` -> `http://noda-nginx:80`
- 默认规则 -> 返回 404

### 备份系统配置

| 文件路径 | 说明 |
|----------|------|
| `deploy/crontab` | 备份定时任务（crontab 格式） |
| `deploy/supervisord.conf` | noda-ops 容器进程管理配置 |
| `deploy/entrypoint-ops.sh` | noda-ops 容器启动脚本 |

定时备份计划：
- 每天凌晨 3:00 执行数据库备份
- 每周日凌晨 3:00 执行验证测试
- 每 6 小时清理旧历史记录
- 每天凌晨 4:00 清理超过 7 天的备份文件

### PostgreSQL 配置

| 文件路径 | 说明 |
|----------|------|
| `docker/services/postgres/conf/` | PostgreSQL 自定义配置目录（当前为空，使用默认配置） |
| `docker/services/postgres/init/` | 数据库初始化脚本 |
| `docker/services/postgres/backup/` | 备份目录挂载点 |
| `docker/services/postgres/backup/wal-archive/` | WAL 归档目录 |

### 密钥管理文件

| 文件路径 | 说明 | 提交到 Git |
|----------|------|-----------|
| `config/secrets.sops.yaml` | SOPS 加密的密钥存储 | 是（加密后） |
| `config/secrets.local.yaml` | 本地明文密钥（开发用） | 否 |
| `config/keys/git-age-key.txt` | age 加密私钥（用于 SOPS 解密） | 否 |

`secrets.sops.yaml` 中存储的密钥：
- `cloudflare_tunnel_token` - Cloudflare Tunnel Token
- `postgres_password` - PostgreSQL 密码
- `keycloak_admin_password` - Keycloak 管理员密码
- `google_oauth_client_id` - Google OAuth 客户端 ID
- `google_oauth_client_secret` - Google OAuth 客户端密钥

---

## Docker Compose 文件结构

项目使用 Docker Compose Overlay 模式，基础配置 + 环境覆盖：

| 文件 | 用途 |
|------|------|
| `docker/docker-compose.yml` | 基础配置（所有环境共享） |
| `docker/docker-compose.prod.yml` | 生产环境覆盖 |
| `docker/docker-compose.dev.yml` | 开发环境覆盖 |
| `docker/docker-compose.dev-standalone.yml` | 独立开发数据库（无其他服务） |
| `docker/docker-compose.simple.yml` | 简化版一键部署 |
| `docker/docker-compose.app.yml` | 应用层服务（findclass-ssr） |

### 使用方式

```bash
# 生产环境（基础设施 + 应用）
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d

# 开发环境
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d

# 单独部署应用
docker compose -f docker/docker-compose.app.yml up -d --build
```

---

## 必填与可选设置

### 启动时必须配置的变量

以下变量缺失会导致服务启动失败或功能异常：

| 变量 | 影响的服务 | 失败表现 |
|------|-----------|----------|
| `POSTGRES_USER` | PostgreSQL, Keycloak, findclass-ssr, noda-ops | 数据库连接失败 |
| `POSTGRES_PASSWORD` | PostgreSQL, Keycloak, findclass-ssr, noda-ops | 数据库认证失败 |
| `POSTGRES_DB` | PostgreSQL, Keycloak | 数据库不存在 |
| `KEYCLOAK_ADMIN_USER` | Keycloak | 管理员账户创建失败 |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak | 管理员账户创建失败 |
| `CLOUDFLARE_TUNNEL_TOKEN` | noda-ops (cloudflared) | 隧道无法连接（服务仍可启动，但外部不可访问） |

### 可选配置（有默认值）

| 变量 | 默认值 | 来源 |
|------|--------|------|
| `POSTGRES_USER` (noda-ops 健康检查) | `postgres` | `docker/docker-compose.yml` 第 65 行 |
| `B2_BUCKET_NAME` | `noda-backups` | `docker/docker-compose.yml` 第 72 行 |
| `B2_PATH` | `backups/postgres/` | `docker/docker-compose.yml` 第 73 行 |
| `ALERT_EMAIL` | （空） | `docker/docker-compose.yml` 第 74 行 |
| `RESEND_API_KEY` | （空） | `docker/docker-compose.app.yml` 第 36 行 |
| `PROD_POSTGRES_DB` | `noda_prod` | `docker/docker-compose.prod.yml` 第 18 行 |
| `DEV_POSTGRES_DB` | `noda_dev` | `docker/docker-compose.dev.yml` 第 15 行 |

---

## 环境差异

### 生产环境

- Docker Compose 项目名：`noda-infra`
- PostgreSQL 数据库名：`noda_prod`（通过 `PROD_POSTGRES_DB` 覆盖）
- Keycloak hostname：`https://auth.noda.co.nz`
- Keycloak 代理模式：`edge`（配合 Cloudflare Tunnel）
- PostgreSQL 暴露端口 `5432`（供外部连接）
- 资源限制：PostgreSQL 2 CPU / 2GB 内存，Keycloak 1 CPU / 1GB 内存
- SMTP 邮件服务：启用（密码重置等功能）

### 开发环境

- Docker Compose 项目名：`noda-infra`（基础配置继承）
- PostgreSQL 数据库名：`noda_dev`（通过 `DEV_POSTGRES_DB` 覆盖）
- PostgreSQL 暴露端口：`5433`（避免与生产环境冲突）
- Nginx 暴露端口：`8081`
- Keycloak hostname：空（允许 `localhost` 访问）
- Keycloak 代理模式：`none`
- Cloudflare Tunnel：禁用（`profiles: [dev]`）
- findclass-ssr 暴露端口：`3002`

### 独立开发环境

- Docker Compose 项目名：`noda-dev`
- 仅包含 PostgreSQL 开发数据库
- 独立网络：`noda-dev-network`（bridge 驱动）
- PostgreSQL 端口：`5433`

---

## 密钥管理

项目使用 **SOPS + age** 加密敏感信息，详见 [secrets-management.md](secrets-management.md)。

### 工作流程

```bash
# 编辑加密密钥
sops config/secrets.sops.yaml

# 设置解密密钥路径
export SOPS_AGE_KEY_FILE=config/keys/git-age-key.txt

# 查看解密内容（不修改文件）
sops --decrypt config/secrets.sops.yaml
```

### 安全规则

- 加密后的 `config/secrets.sops.yaml` 可以提交到 Git
- 明文密钥文件（`config/secrets.local.yaml`、`config/keys/`）不提交
- 部署脚本 (`scripts/deploy/deploy-infrastructure-prod.sh`) 自动处理解密
- `scripts/backup/.env.backup` 包含 B2 密钥，已在 `.gitignore` 中排除

---

## 首次配置步骤

1. 从模板创建环境变量文件：
   ```bash
   cp config/environments/.env.example config/environments/.env.production
   # 编辑 .env.production，填入实际的密码和 Token
   ```

2. 配置密钥管理：
   ```bash
   # 设置 SOPS age 密钥路径
   export SOPS_AGE_KEY_FILE=config/keys/git-age-key.txt
   # 编辑加密密钥
   sops config/secrets.sops.yaml
   ```

3. 配置备份系统（可选）：
   ```bash
   cp scripts/backup/templates/.env.backup scripts/backup/.env.backup
   # 编辑 .env.backup，填入 B2 凭据
   chmod 600 scripts/backup/.env.backup
   ```

4. 创建外部 Docker 网络：
   ```bash
   docker network create noda-network
   ```
