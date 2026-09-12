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
- Doppler CLI 3.x+（密钥管理，生产环境需要）

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
   # 生产环境
   docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d
   ```

4. **部署应用服务**（三容器：noda-api / noda-frontend / noda-static）：

   ```bash
   # 通过 Jenkins apps-deploy Pipeline 部署（normal: preprod 验证 + 人工批准后发 prod）
   # 镜像由 noda-apps 仓 infra/docker/Dockerfile.{noda-api,noda-frontend,noda-static} 构建
   ```

## 服务概览

| 服务 | 镜像/版本 | 端口 | 说明 |
|------|-----------|------|------|
| PostgreSQL | `postgres:17.9` | 5432（内部） | 数据库，数据持久化在 `postgres_data` 卷 |
| Keycloak | `quay.io/keycloak/keycloak:26.2.3` | 8080（内部） | 认证服务，通过 Cloudflare Tunnel 暴露为 `auth.noda.co.nz` |
| noda-api-prod | `noda-api:latest` | 3001/3007/3010/3011 | Go API 四服务（class/liuyao/email/admin），内置 crawl 调度 cron |
| noda-frontend-prod | `noda-frontend:latest` | 3000/3004/3005/3006/3012 | Next.js SSR 5 应用（class/auth/liuyao/admin/comment） |
| noda-static-prod | `noda-static:latest` | 80/81/443 | nginx 静态站（www）+ 反向代理（网络别名 noda-infra-nginx） |
| noda-ops | 自构建 | - | 运维工具集（PostgreSQL 备份 + Doppler 密钥备份 + Cloudflare Tunnel） |

## 流量架构

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops 容器) → noda-static-prod (nginx)
  class.noda.co.nz/api/*   → noda-api-prod:3001      (Go API)
  class.noda.co.nz/*       → noda-frontend-prod:3000 (Next.js SSR)
  noda.co.nz               → noda-static-prod 镜像内静态文件
  auth.noda.co.nz          → noda-frontend-prod:3004 / keycloak:8080
```

## 目录结构

```
noda-infra/
├── config/             # 配置文件
│   ├── environments/   # 环境变量模板（.env.example, .env.production.template）
│   ├── keys/           # 加密密钥
│   ├── nginx/          # Nginx 配置（nginx.conf, conf.d/, snippets/）
│   └── cloudflare/     # Cloudflare Tunnel 配置
├── deploy/             # Docker 构建文件
│   ├── Dockerfile.noda-ops        # 运维工具镜像（应用镜像在 noda-apps 仓 infra/docker/）
│   └── crontab                    # noda-ops 定时任务（备份/验证/Doppler）
├── docker/             # Docker Compose 编排文件
│   ├── docker-compose.yml              # 基础服务定义
│   ├── docker-compose.prod.yml         # 生产环境覆盖
│   ├── docker-compose.r4s.yml          # r4s 宿主机覆盖
│   ├── docker-compose.apps-prod.yml    # 应用三容器参考定义
│   ├── docker-compose.preprod-local.yml# 本地 preprod 栈
│   └── docker-compose.remark42.yml     # Remark42 评论服务
├── scripts/            # 运维脚本
│   ├── backup/         # 备份与恢复脚本（backup-postgres.sh, restore-postgres.sh）
│   ├── deploy/         # 部署脚本（deploy-infrastructure-prod.sh；三容器部署入口）
│   ├── jenkins/        # Jenkins 初始化配置
│   └── lib/            # 共享库（log.sh, health.sh, secrets.sh）
├── services/           # 服务专用配置
│   ├── postgres/       # PostgreSQL 初始化脚本和配置（init/, conf/）
│   └── keycloak/       # Keycloak realm 配置和初始化脚本
└── jenkins/            # Jenkinsfile（apps / infra / cleanup Pipeline）
```

## 常用命令

```bash
# 查看所有服务状态
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml ps

# 查看服务日志
docker compose -f docker/docker-compose.yml logs <service-name>

# 部署应用（三容器，走 Jenkins Pipeline）
# Jenkins UI 触发 apps-deploy（normal / fast 模式）

# 数据库备份
scripts/backup/backup-postgres.sh
```

## 重要注意事项

- **构建时环境变量**：`NEXT_PUBLIC_*` 变量在 `docker build` 阶段写入 JS 产物，运行时环境变量仅影响 SSR 服务端。修改前端配置必须重新构建镜像。
- **项目名一致性**：`docker-compose.yml` 和 `docker-compose.prod.yml` 的 `name` 必须一致（当前为 `noda-infra`），否则会创建重复容器和空数据卷。
- **Cloudflare 缓存**：静态资源 URL 包含 hash 可自动更新，但 `index.html` 会被 CDN 缓存，部署后可能需要手动清除缓存。

## 许可证

本项目为私有仓库，不对外开源。
