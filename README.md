<!-- generated-by: gsd-doc-writer -->

# noda-infra

Noda 项目的基础设施仓库，通过 Docker Compose 管理生产环境的数据库、认证、反向代理和应用服务的部署配置。

---

## 安装

```bash
# 克隆仓库
git clone https://github.com/wangdianwen/noda-infra.git
cd noda-infra

# 复制并编辑环境变量
cp config/environments/.env.example config/environments/.env
# 编辑 .env 文件，填入实际密码和密钥
```

前置要求：

- Docker 29.1.3+
- Docker Compose v2.40.3+
- SOPS 3.12.2 + age 1.3.1（密钥加密，生产环境需要）

## 快速开始

1. **创建外部网络**（首次部署需要）：

   ```bash
   docker network create noda-network
   ```

2. **配置环境变量**：

   ```bash
   cp config/environments/.env.example docker/.env
   # 编辑 docker/.env，填入实际的密码、Token 等敏感信息
   ```

3. **启动基础设施**（PostgreSQL + Keycloak + Nginx + noda-ops）：

   ```bash
   # 开发环境
   docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d

   # 生产环境
   docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d
   ```

4. **构建并启动应用服务**（findclass-ssr）：

   ```bash
   docker compose -f docker/docker-compose.app.yml build findclass-ssr
   docker compose -f docker/docker-compose.app.yml up -d findclass-ssr
   ```

## 服务概览

| 服务 | 镜像/版本 | 端口 | 说明 |
|------|-----------|------|------|
| PostgreSQL | `postgres:17.9` | 5432（生产） | 数据库，数据持久化在 `postgres_data` 卷 |
| Keycloak | `quay.io/keycloak/keycloak:26.2.3` | 8080, 9000 | 认证服务，通过 Cloudflare Tunnel 暴露为 `auth.noda.co.nz` |
| Nginx | `nginx:1.25-alpine` | 80（内部） | 反向代理，将 `class.noda.co.nz` 路由到 findclass-ssr |
| findclass-ssr | 自构建 | 3001 | SSR + API + 静态文件，三合一应用服务 |
| noda-ops | 自构建 | - | 运维工具集（PostgreSQL 备份 + Cloudflare Tunnel） |

## 流量架构

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops 容器) → Docker 内部网络
  class.noda.co.nz → nginx:80 → findclass-ssr:3001 (SSR + API + 静态文件)
  auth.noda.co.nz  → keycloak:8080
```

## 目录结构

```
noda-infra/
├── config/             # 配置文件
│   ├── environments/   # 环境变量模板（.env.example, .env.production.template）
│   ├── nginx/          # Nginx 配置（nginx.conf, conf.d/, snippets/）
│   └── cloudflare/     # Cloudflare Tunnel 配置
├── deploy/             # Docker 构建文件
│   ├── Dockerfile.findclass-ssr   # 应用镜像构建
│   ├── Dockerfile.noda-ops        # 运维工具镜像构建
│   └── Dockerfile.backup          # 备份服务镜像构建
├── docker/             # Docker Compose 编排文件
│   ├── docker-compose.yml         # 基础服务定义
│   ├── docker-compose.prod.yml    # 生产环境覆盖
│   ├── docker-compose.dev.yml     # 开发环境覆盖
│   └── docker-compose.app.yml     # 应用服务（findclass-ssr）
├── scripts/            # 运维脚本
│   ├── deploy/         # 部署脚本（deploy-infrastructure-prod.sh 等）
│   ├── backup/         # 备份脚本（backup-postgres.sh）
│   ├── verify/         # 验证脚本（verify-infrastructure.sh）
│   └── utils/          # 工具脚本
├── services/           # 服务专用配置
│   ├── postgres/       # PostgreSQL 初始化脚本
│   ├── keycloak/       # Keycloak 自定义主题
│   ├── nginx/          # Nginx 辅助配置
│   ├── findclass/      # Findclass 应用配置
└── docs/               # 项目文档
```

## 常用命令

```bash
# 查看所有服务状态
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml ps

# 查看服务日志
docker compose -f docker/docker-compose.yml logs -f <service-name>

# 重建并启动应用（修改前端代码后）
docker compose -f docker/docker-compose.app.yml build findclass-ssr --no-cache
docker compose -f docker/docker-compose.app.yml up -d findclass-ssr

# 数据库备份
scripts/backup/backup-postgres.sh
```

## 重要注意事项

- **构建时环境变量**：`VITE_*` 变量在 `docker build` 阶段写入 JS 文件，运行时环境变量仅影响 SSR 服务端。修改前端配置必须重新构建镜像。
- **项目名一致性**：`docker-compose.yml` 和 `docker-compose.prod.yml` 的 `name` 必须一致（当前为 `noda-infra`），否则会创建重复容器和空数据卷。
- **Cloudflare 缓存**：静态资源 URL 包含 hash 可自动更新，但 `index.html` 会被 CDN 缓存，部署后可能需要手动清除缓存。

## 文档

- [架构文档](docs/architecture.md) — 系统架构和安全设计原则
- [部署指南](docs/DEPLOYMENT_GUIDE.md) — 完整的生产/开发环境部署流程
- [密钥管理](docs/secrets-management.md) — SOPS + age 密钥加密方案
- [Keycloak 脚本](docs/KEYCLOAK_SCRIPTS.md) — Keycloak 配置和 realm 初始化脚本

## 许可证

本项目为私有仓库，不对外开源。
