# Noda Infrastructure - Claude 项目指南

## 项目概述

Noda 基础设施仓库，管理 Docker Compose 部署配置。包含 PostgreSQL、Nginx（noda-static）、SeaweedFS、noda-api（Go 聚合 API）、noda-jobs（Go 调度守护进程）、noda-ops（备份 + Cloudflare Tunnel）。运行时零 Node（2026-09-12 S5 静态化终态）：全部前端为静态导出入 SeaweedFS 桶。Keycloak 已于 2026-09-12 下线（认证在 Go authapi），noda-frontend SSR 同期退役。

## 架构

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops 容器) → noda-static-prod (nginx) → Docker 内部服务
  *.noda.co.nz/*        → noda-static-prod → SeaweedFS 桶 noda-static（sites/<product>/ 静态站）
  class.noda.co.nz/api/* → noda-static-prod → noda-api-prod:3001      (Go API)
  snagme.noda.co.nz/api/*→ noda-static-prod → noda-api-prod:3015      (Go snagmeapi + /api/snagme/img 图片代理)
  auth.noda.co.nz       → noda-static-prod → noda-api-prod:3004      (Go authapi)
  admin.noda.co.nz/api/* → noda-static-prod → noda-api-prod:3011     (Go adminapi)
  noda.co.nz            → noda-static-prod → SeaweedFS 桶（www 静态）
  cron 状态             → noda-jobs-prod:3016（唯一 scheduler；admin cronjobs 页经 adminapi cron-pull 直连）
```

| 服务 | 端口 | 备注 |
|------|------|------|
| PostgreSQL | 5432 | 数据持久化在 `noda-infra_postgres_data` 卷 |
| noda-api-prod | 3001/3004/3007/3010/3011/3012/3014/3015 | Go API 八 listener（gin；3015 = snagmeapi） |
| noda-jobs-prod | 3016 | Go 调度守护进程（noda-api 同镜像换 entrypoint）：全部产品 cron（爬虫/lifecycle/nearby/snagme-tick）；:3016 只读状态 + 手动触发 |
| noda-static-prod | 80/81/443 | nginx 边缘路由，七站点静态由 SeaweedFS 桶伺服（网络别名 noda-infra-nginx） |
| seaweedfs | 8333/9333 | S3 对象存储：桶 `noda-static`（静态站/头像/爬虫图片） |
| noda-ops | 8080 (healthcheck) | 备份 cron（DB/B2/Doppler/filesystem）+ Cloudflare Tunnel |

## 部署规则

### 禁止直接使用 Docker Compose 命令

**严禁 LLM 直接运行 `docker compose up/down/restart/start/stop` 等命令来上线/下线服务。**

所有服务部署、重启、下线操作必须通过项目脚本执行：

| 操作 | 脚本 |
|------|------|
| 全量部署（基础设施+应用） | `bash scripts/deploy/deploy-infrastructure-prod.sh` |
| 部署应用（后端容器 + 产品静态站） | Jenkins `noda-apps` Pipeline（参数 PRODUCT + LAYER；normal: preprod 验证 + 人工批准；fast: hotfix 直发） |

> legacy 单容器手动回退已于 2026-09-10 全部移除（脚本 + 旧容器均删）。紧急回退：`docker run` 启动保留在 r4s 的 `noda-apps:56fd05aa` 镜像（挂载 noda-network、env 参照 git 历史中 env-noda-apps.env），或用 pipeline 重发上一个 SHA 的三容器镜像。

允许的 docker compose 命令仅限只读操作：`ps`、`logs`、`config`、`images`。

### 项目名一致性
- `docker-compose.yml` 和 `docker-compose.prod.yml` 项目名必须一致（当前为 `noda-infra`）
- 不一致会创建重复容器和空数据卷

### 构建时 vs 运行时环境变量
前端 `NEXT_PUBLIC_*` 变量在构建时写入 JS 产物，运行时环境变量对静态站无效。
**修改前端配置必须重新构建并发布静态站（Jenkins `infra-deploy` SERVICE=<product>-static），不能只改运行时环境变量。**

### Cloudflare 缓存
静态资源更新后需要清除 CDN 缓存。静态资源 URL 包含 hash，但 index.html 会被缓存。

## 历史修复记录（已归档）

Google 登录 8080 修复（Keycloak 时代，2026-04）、Phase 16 端口收敛、
preprod 双容器负载均衡等记录随 Keycloak/SSR 退役已从本文件移除——
完整历史见 git log 本文件旧版本。仅沉淀跨时代仍适用的方法论：

### 调试方法论
1. 用 Chrome DevTools MCP 跟踪完整 redirect chain 与 cookie domain，不要只验证单一端点
2. 问题表象所在层不一定等于根因所在层（逐层往下查）
3. 构建期烤入产物的值无法用运行时环境变量覆盖（静态导出同理：`NEXT_PUBLIC_*` 改了必须重发静态站）
4. compose 项目名不一致会创建重复容器与空数据卷（当前 `noda-infra`，勿改）
5. macOS 单文件 bind mount 在文件被重写后 inode 失联——改 nginx conf 后需 force-recreate preprod-noda-static

## 环境对照

| | Prod（R4S，root@192.168.100.1，Jenkins 经 r4s-ssh-key） | Pre-prod（Mac 本机） |
|---|---|---|
| 数据库 | `noda_prod` | `noda_preprod` |
| 站点 | `*.noda.co.nz` | `*-preprod.noda.co.nz` |
| nginx | `noda-static-prod`（conf.d/*.conf） | `preprod-noda-static`（liuyao-local.conf，模板为 liuyao-local.conf.example，改后 cp/同步并 force-recreate） |
| 桶 | R4S seaweedfs `noda-static` | Mac seaweedfs-stg `noda-static` |

## 常见问题
- **发布后页面没更新**：① CF CDN 缓存（HTML 短缓存 5-15 分钟）② `NEXT_PUBLIC_*` 变更需重新构建+发布静态站 ③ 浏览器强刷
- **登录异常**：认证在 Go authapi（:3004），会话在 `auth_sessions` 表；Google OAuth PKCE 直连，回调域名须在 Google Console 白名单
- **cron 任务**：唯一 scheduler 在 `noda-jobs-prod:3016`（`docker exec noda-jobs-prod wget -qO- 127.0.0.1:3016/status`）；admin cronjobs 页经 adminapi cron-pull 直连该端口
