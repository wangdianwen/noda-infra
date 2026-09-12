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

4. **部署应用服务**（后端 Go API 容器 + 各产品静态站）：

   ```bash
   # 通过 Jenkins noda-apps Pipeline 发布（PRODUCT 单选产品 + LAYER=all/api/static；
   # DEPLOY_MODE=normal: preprod 验证 + 人工批准后发 prod，fast: 仅限 hotfix 直发）
   # 后端镜像由 noda-apps 仓 infra/docker/Dockerfile.{noda-api,noda-frontend,noda-static} 构建，
   # 前端静态站经 mc mirror 发布到 SeaweedFS 桶 sites/<product>/（prod+stg 双桶）
   ```

## 服务概览

| 服务 | 镜像/版本 | 端口 | 说明 |
|------|-----------|------|------|
| PostgreSQL | `postgres:17.9` | 5432（内部） | 数据库，数据持久化在 `postgres_data` 卷 |
| noda-api-prod | `noda-api:<commit-sha>` | 3001/3007/3010/3011 | Go API 多模块（class/liuyao/email/admin + auth/comment API），内置 crawl 调度 cron |
| noda-static-prod | `noda-static:<commit-sha>` | 80/81/443 | nginx 边缘路由（反代 Go API + 从 SeaweedFS 桶伺服各产品静态站，网络别名 noda-infra-nginx） |
| SeaweedFS | r4s 数据盘 | 8333（内部） | 对象存储，桶 `noda-static`（prod）/ `noda-static-stg`（本机 preprod），匿名只读 |
| noda-ops | 自构建 | - | 运维工具集（PostgreSQL 备份 + Doppler 密钥备份 + Cloudflare Tunnel） |

> 已退役：Keycloak（2026-09-12 下线，OAuth 走 auth 应用直连）、noda-frontend Node 容器（2026-09-12 退役，五站页面静态化入桶）、Remark42（评论由 comment 应用接管，`docker-compose.remark42.yml` 仅存档）。

## 流量架构

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops 容器) → noda-static-prod (nginx 边缘)
  class.noda.co.nz/api/*   → noda-api-prod:3001            (Go API)
  class.noda.co.nz/*       → SeaweedFS 桶 sites/class/     (静态壳 + app-shell 兜底)
  liuyao.noda.co.nz/api/*  → noda-api-prod:3007
  liuyao.noda.co.nz/*      → SeaweedFS 桶 sites/liuyao/
  noda.co.nz               → SeaweedFS 桶 sites/www/
  admin.noda.co.nz         → SeaweedFS 桶 sites/admin/ + noda-api-prod:3011
  auth.noda.co.nz          → SeaweedFS 桶 sites/auth/      (Go authapi 承接 API)
  comments.noda.co.nz      → SeaweedFS 桶 sites/comment/   (Go commentapi 承接 API)
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
│   ├── docker-compose.apps-prod.yml    # 应用容器参考定义
│   ├── docker-compose.preprod-local.yml# 本地 preprod 栈（postgres + api + static + seaweedfs-stg）
│   └── docker-compose.remark42.yml     # （已退役存档）Remark42 评论服务
├── scripts/            # 运维脚本
│   ├── backup/         # 备份与恢复脚本（backup-postgres.sh, restore-postgres.sh）
│   ├── deploy/         # 部署脚本（deploy-infrastructure-prod.sh；三容器部署入口）
│   ├── jenkins/        # Jenkins 初始化配置
│   └── lib/            # 共享库（log.sh, health.sh, secrets.sh）
├── services/           # 服务专用配置
│   ├── postgres/       # PostgreSQL 初始化脚本和配置（init/, conf/）
│   └── keycloak/       # （已退役存档）Keycloak realm 配置
└── jenkins/            # Jenkinsfile（noda-apps / noda-infra Pipeline）
```

## 常用命令

```bash
# 查看所有服务状态
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml ps

# 查看服务日志
docker compose -f docker/docker-compose.yml logs <service-name>

# 部署应用（走 Jenkins noda-apps Pipeline）
# Jenkins UI 触发 noda-apps：PRODUCT 单选产品 + LAYER（all/api/static）+ DEPLOY_MODE（normal/fast）

# 重建公共基础设施（走 Jenkins noda-infra Pipeline）
# Jenkins UI 触发 noda-infra：SERVICE 单选（nginx / seaweedfs / noda-ops / postgres）

# 数据库备份
scripts/backup/backup-postgres.sh
```

## CI/CD（Jenkins Pipeline）

Jenkins 运行在本机 `http://localhost:8080`，仅两个手动触发的 Pipeline：

| Job | Jenkinsfile | 职责 | 参数 |
|-----|-------------|------|------|
| **noda-apps** | `jenkins/Jenkinsfile.apps` | 产品应用发布 | `PRODUCT` 必选单产品（class/www/admin/liuyao/nearby/auth/comment）；`LAYER` = all（一起）/ api（后端）/ static（前端）；`DEPLOY_MODE` = normal（preprod 验证 + 人工批准）/ fast（hotfix 直发） |
| **noda-infra** | `jenkins/Jenkinsfile.infra` | 公共基础设施镜像发布 | `SERVICE` 必选其一：nginx（构建反代镜像并重建容器）/ seaweedfs / noda-ops / postgres（备份 + 人工确认） |

- 前端静态站发布 = 构建 `out/` 后 `mc mirror` 入 SeaweedFS 桶 `sites/<product>/`（prod + stg 双桶同步收敛）。
- 允许并行构建：前端按产品隔离（`publish-<product>` 锁 + 产品维度中继），后端容器切换按 `apps-prod`/`apps-preprod` 锁互斥，noda-infra 核心服务按 `infra-core` 锁串行——跨 Pipeline 互不阻塞。
- 完整触发示例见 `CLAUDE.md` 的「Jenkins API 远程触发（curl Runbook）」。

## 重要注意事项

- **构建时环境变量**：`NEXT_PUBLIC_*` 变量在 `docker build` 阶段写入 JS 产物，运行时环境变量仅影响 SSR 服务端。修改前端配置必须重新构建镜像。
- **项目名一致性**：`docker-compose.yml` 和 `docker-compose.prod.yml` 的 `name` 必须一致（当前为 `noda-infra`），否则会创建重复容器和空数据卷。
- **Cloudflare 缓存**：静态资源 URL 包含 hash 可自动更新，但 `index.html` 会被 CDN 缓存，部署后可能需要手动清除缓存。

## 许可证

本项目为私有仓库，不对外开源。
