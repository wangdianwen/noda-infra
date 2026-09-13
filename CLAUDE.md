# Noda Infrastructure - Claude 项目指南

## 项目概述

Noda 基础设施仓库，管理 Docker Compose 部署配置。包含 PostgreSQL、Keycloak、Nginx、Cloudflare Tunnel、noda-apps 等服务。

## 架构

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops 容器) → noda-static-prod (nginx) → Docker 内部服务
  class.noda.co.nz/api/*   → noda-static-prod → noda-api-prod:3001      (Go API)
  class.noda.co.nz/*       → noda-static-prod → noda-frontend-prod:3000 (Next.js SSR)
  liuyao.noda.co.nz/api/*  → noda-static-prod → noda-api-prod:3007
  noda.co.nz               → noda-static-prod 镜像内静态文件 (/var/www/noda.co.nz)
  auth.noda.co.nz          → noda-static-prod → noda-frontend-prod:3004 (+ keycloak:8080)
```

| 服务 | 端口 | 备注 |
|------|------|------|
| PostgreSQL | 5432 | 数据持久化在 `noda-infra_postgres_data` 卷 |
| Keycloak | 8080 (内部) | 不暴露外部端口，通过 nginx 反向代理访问 |
| noda-api-prod | 3001/3004/3007/3010/3011/3012/3014/3015 | Go API 多服务（gin；3015 = snagme-api） |
| noda-frontend-prod | 3000/3004/3005/3006/3012 | Next.js SSR 5 应用 |
| noda-static-prod | 80/81/443 | nginx 边缘路由 + www 静态（网络别名 noda-infra-nginx） |
| noda-ops | - | 备份 + Cloudflare Tunnel |
| Nginx | 80 | 反向代理（所有外部流量统一入口） |

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
Vite 的 `VITE_*` 变量在 `docker build` 时写入 JS 文件，运行时环境变量只影响 SSR 服务端。
**修改前端配置必须重新构建镜像，不能只改运行时环境变量。**

### Cloudflare 缓存
静态资源更新后需要清除 CDN 缓存。静态资源 URL 包含 hash，但 index.html 会被缓存。

## Google 登录 8080 端口问题修复记录（2026-04-10）

### 发现的 5 层问题

| # | 层 | 问题 | 修复文件 |
|---|---|------|----------|
| 1 | 前端构建 | JS 中 Keycloak URL 硬编码为 `localhost:8080`（构建时未传 `VITE_KEYCLOAK_URL`） | `noda-apps 仓 infra/docker/Dockerfile.noda-apps` 添加 ARG |
| 2 | Nginx 路由 | `/auth/` 被代理到 Keycloak，覆盖了应用 `/auth/callback` | `config/nginx/conf.d/default.conf` 移除 `/auth/` 代理 |
| 3 | SSR 中间件 | `url.startsWith('/auth')` 跳过了 `/auth/callback`，不渲染 SPA | `noda-apps/.../ssr-middleware.ts` 移除跳过条件 |
| 4 | Keycloak 配置 | v1 hostname 选项废弃，`KC_HOSTNAME_PORT` 不生效 | `docker-compose.yml` 改为 `KC_HOSTNAME: "https://auth.noda.co.nz"` |
| 5 | 项目名冲突 | `docker-compose.prod.yml` 项目名 `noda-prod` 与 `noda-infra` 冲突 | 统一为 `noda-infra` |

### 根因链路

```
浏览器加载 JS → Keycloak URL = localhost:8080（构建时硬编码）
  → 登录请求发到 localhost（cookie 设在 localhost 域）
  → Keycloak 重定向到 auth.noda.co.nz
  → cookie 不跨域 → cookie_not_found 错误
```

### 修复要点

**Dockerfile（永久修复）：**
```dockerfile
ARG VITE_KEYCLOAK_URL=https://auth.noda.co.nz
ARG VITE_KEYCLOAK_REALM=noda
ARG VITE_KEYCLOAK_CLIENT_ID=noda-frontend
```

**Keycloak v2 Hostname SPI：**
- `KC_HOSTNAME: "https://auth.noda.co.nz"` — 完整 URL，端口从 scheme 推导
- `KC_PROXY: "edge"` — 必须保留，否则 cookie 缺少 Secure 标记
- `KC_PROXY_HEADERS: "xforwarded"` — 读取 Cloudflare X-Forwarded 头
- 不要使用 `KC_HOSTNAME_PORT`、`KC_HOSTNAME_STRICT_HTTPS`（v1 废弃选项）

**部署脚本：**
- `deploy-infrastructure-prod.sh` 需使用 `-f base -f prod` 双文件
- 需清理旧项目名容器避免端口冲突

### 调试方法论

1. **用 Chrome DevTools MCP 跟踪网络请求**，检查 redirect chain 和 cookie domain
2. 不要只验证 Keycloak OIDC 端点，要跟踪完整登录链路
3. 问题表象（Keycloak :8080）不一定等于根因（前端 localhost:8080）
4. 构建产物中的硬编码值无法通过运行时环境变量覆盖

### 附加修复

- `lru-cache` ESM 兼容问题：Dockerfile 中 sed 修复 named export
- API 入口文件路径修正：`dist/api/src/api.js` → `dist/api.js`

## Phase 16 端口收敛 + OAuth 修复记录（2026-04-12）

### 端口收敛

- Keycloak 移除 `ports:` 段（8080/9000），仅通过 nginx 反向代理访问
- auth.noda.co.nz 流量：Cloudflare → nginx → keycloak:8080（Docker 内部网络）
- 健康检查从 `localhost:9000` 改为 `localhost:8080` TCP 检查

### OAuth 登录修复（3 层问题）

| # | 问题 | 根因 | 修复 |
|---|------|------|------|
| 1 | keycloak-js 默认 `responseMode='fragment'` | 回调参数在 URL hash 中，PKCE 无法交换 token | `keycloak.init({ responseMode: 'query' })` |
| 2 | Keycloak 容器 `KC_PROXY=none` | 容器未重建，compose 配置未生效；导致 cookie 缺少 Secure 标记 | `docker compose up --force-recreate keycloak` |
| 3 | nginx `X-Frame-Options: SAMEORIGIN` | 阻止 Keycloak SSO iframe 被 class.noda.co.nz 嵌入 | 改为 `ALLOW-FROM` + `CSP frame-ancestors` |

### noda-apps 镜像重建

shared 包 `"type": "module"` + `"main": "./src/index.ts"` 导致 Node.js 无法加载。Dockerfile 中添加：
1. `tsc --build` 编译 TypeScript
2. Node.js 脚本修复 ESM 扩展名（目录导入 → `./dir/index.js`，文件导入 → `./file.js`）
3. 重写 `package.json` 指向 `./dist/` 编译产物

### Docker 构建注意事项

- `docker compose build` 可能使用 BuildKit 缓存导致 Dockerfile 修改未生效
- 关键修改后用 `docker build --no-cache` 直接构建验证
- `tsc --build` 增量编译受 `tsconfig.tsbuildinfo` 影响，Dockerfile 中无需处理（每次全新构建）
- tsc 的 `moduleResolution: "bundler"` 不会添加 `.js` 扩展名，需要后处理

## 部署命令

### 主要部署方式：Jenkins Pipeline

通过 Jenkins UI 手动触发部署 Pipeline（http://localhost:8080）：

| Job | Jenkinsfile | 用途 | 阶段 |
|-----|-------------|------|------|
| **noda-apps** | `jenkins/Jenkinsfile.apps` | 产品应用发布。PRODUCT 必选单产品（class / www / admin / liuyao / nearby / auth / comment / snagme，无 all；snagme 仅 LAYER=api）；LAYER=all（前后端一起，含 noda-static 反代镜像顺带刷新）/ api（仅后端 Go API）/ static（仅前端：静态站构建 + mc mirror 入 SeaweedFS 桶 sites/\<product\>/，prod+stg 双桶）；DEPLOY_MODE=normal（preprod 验证 + 人工批准后发 prod）/ fast（Test 通过直发 prod，仅限 hotfix） | Pre-flight → Build → [Deploy Pre-prod ‖ Test] → Human Approval → Deploy Prod → Publish Static → Verify（产品维度 E2E）→ CDN Purge |
| **noda-infra** | `jenkins/Jenkinsfile.infra` | 公共基础设施镜像发布。SERVICE 必选其一（无 all）：nginx（构建 noda-static 反代镜像并传输 r4s 后重建容器）/ seaweedfs / noda-ops / postgres（先备份 + 人工确认） | Pre-flight → Backup（仅 postgres）→ Human Approval（仅 postgres）→ Deploy → Health Check → Verify |

**部署流程（Build Once，人工验证后上线，normal 模式）：**
1. 触发 `noda-apps`（选择 PRODUCT + LAYER）— 自动构建并部署到 pre-prod
2. 人工在 pre-prod 环境验证（如 `https://class-preprod.noda.co.nz/`）
3. 在 Jenkins UI 点击 "deploy_prod" 确认上线（其余选项：rebuild_preprod / abort）
4. Pipeline 自动完成 prod 部署（停旧启新）

**LAYER=static（仅前端）行为：** 容器阶段（Build/Pre-prod/Approval/Deploy Prod）全部
跳过——Test 通过即执行 Publish Static（桶发布即时生效，stg 桶同步提供 preprod 验证），
随后产品维度 E2E + CDN Purge，全程无人工卡点。DEPLOY_MODE 参数对 static 不生效。

**双 Pipeline 验收记录（2026-09-13，job 全新重建从 #1 起）：**

| 测试 | 构建 | 结果 | 备注 |
|------|------|------|------|
| noda-infra 全骨架（seaweedfs） | infra #4 | ✅ | #1-3 失败为修复过程：POSIX 进替换语法 → minio/mc 拉取 → 匿名策略，均已修 |
| noda-apps 前端全链路（class/static） | apps #5 | ✅ | Go 测试 → 桶发布（prod+stg）→ 哨兵 → 产品 E2E，全程无人值守 |
| 同 Pipeline 不同参数并发 | apps #5 ∥ #6 | ✅ | 两构建重叠执行互不干扰（ws-1/ws-2 槽位 + publish-<product> 锁） |
| www 前端（修正探针后复测） | apps #7 | ✅ | www.noda.co.nz 是 301 域，探针改探规范域 noda.co.nz |
| noda-apps 后端全链路（class/api） | apps #8 → #11 | ✅（以 snagme 复验） | #8 被 apps 仓 snagme go.mod 遗漏阻塞（挡板生效，未动线上）；go.mod 修复后以 #11 走通完整路径：Build → 产品级 Go 测试 → preprod → API 批准 → prod → E2E |
| snagme 接入全链路（PRODUCT=snagme, LAYER=api） | apps #11→#13→#15→#17 | ✅ | 连续迭代修复三个问题后全流程贯通：#17 真实完成 prod 切换（传输 0ef8d69 → 容器重建 → nginx 重载）；严格探针（/api/snagme/status）如实报告了并发 nearby 发布覆盖导致的 502——**api 为全产品单体容器，并发 normal 发布最后部署者通吃**（锁保证过程不损坏），待并发窗口关闭后重跑一次即收敛 |
| ⚠️ input 批准返回形状漂移 | apps #9/#11/#12/#15 | 已修复 | UI=Map / 空参批准=null / API submit 无 submit 字段=Rejected——归一化为「显式 abort/rebuild 外一律视为批准」（9815fd6），abort 语义不变 |

重构期间修掉的三个存量 bug：① Jenkins sh=POSIX 模式 bash 不支持进程替换 `<(...)`；② 静态发布哨兵校验在 mc alias 删除之后执行，必然失败（旧 infra-deploy #80 FAILURE 根因）；③ seaweedfs 桶初始化远程拉 minio/mc 被 r4s registry mirror 拒绝（改本地 mc + 中继）。

| 同服务互斥（两个 class 并发触发） | apps #19 ∥ #20 | ✅ | #20 在 build-class 锁上等待 72s，#19 结束后自动接棒；不同产品并发不受影响 |
| prod 实际收敛 | — | ✅ | #18（nearby/api，≥0ef8d69 镜像）落地后，边缘 /api/snagme/status 返回真实 scanner 数据——snagme 链路正式在线 |
| 发布快照 + 静态站一键回滚 | apps #31 + 本地演练 | ✅ | #31 发布产生 sites/snagme-prev/（51 对象）→ 实跑 `pipeline_rollback_static_site snagme`：prod 回滚 51=51 对象数一致、stg 同步回滚、中继容器/alias 全部清理、公网 200。演练后线上内容与回滚前一致（同 commit 重发布） |
| UI 一键回滚任务（noda-rollback） | rollback #1 snagme/static | ✅ | Jenkins CPS 解析通过 → seed 幂等建 job → REST 触发+批准 → 门禁 5s → 桶回滚 51=51 → E2E 通过 → CDN 清除 → 公网 200 → r4s 无残留锁。api/all 路径同引擎（锚点镜像 + apps-prod 锁），审批页明示全产品影响 |
| N 层快照轮转 + 深度回滚 | apps #34 + rollback #2 | ✅ | #34 发布日志「快照轮转 snagme-prev → snagme-prev2」，桶内 main/-prev/-prev2 三前缀各 51 对象；rollback #2 以 ROLLBACK_DEPTH=2 从 sites/snagme-prev2/ 回滚 51=51，公网 200 |
| 锁属主语义 + 全 stage 超时 | infra #6/#7/#8 + apps #31 | ✅ | #6 自锁/#7 复活锁双实证后定稿：锁内 owner(BUILD_URL) 三态判定（自锁幂等通过/死属主抢破/无主孤儿 3min 抢破）+ 每 stage options.timeout（卡死自动失败走 post 释放）；#8 全绿复验 |

**Snagme 接入说明（2026-09-13 上线，Trade Me 捡漏监控）：**
- 采集侧：r4s 宿主 crontab → Go monitor `crawl-snagme`（noda-jobs:multi 容器，白天
  8 分钟一拍 + 夜间降频）→ Postgres `snagme_*` 表（TS launchd 常驻已退役，运维手册
  snagme/deploy/README.md）。
- 后端：`snagme/api` Go 模块经 noda-api 组合根接入（`:3015`），`PRODUCT=snagme
  &LAYER=api` 发布；nginx `/api/*` 反代 :3015。
- 前端：dashboard 为 Next.js `output:'export'` 静态导出（数据全部客户端同源 fetch
  Go API），`LAYER=static` 桶发布 sites/snagme/，`/listing/<id>` 深链 404=200 回
  app-shell 壳。**https://snagme.noda.co.nz/ 已上线**（公网 E2E 全绿）。
- 发布入口：`noda-apps?PRODUCT=snagme&LAYER=static`（前端）/ `LAYER=api`（后端）。

**并行与清理：**
- 并行规则（2026-09-13 定稿，Queue Gate 队列门禁）：**同一服务不允许并行**——
  两个 Pipeline 首阶段 `Queue Gate` 经 `pipeline_queue_gate` 取 `build-<service>` 锁
  （最长等 900s），后触发者在门禁处**排队、不做任何实际构建工作**，先到者完成自动接棒
  （实测 #24/#26 零空窗接棒）；不同服务并行互不影响（实测 class ∥ snagme 同时跑）。
  normal 模式在 Human Approval **前主动释放**队列锁（审批挂起不阻塞后续发布），
  Deploy Prod/Rebuild 前重新获取。跨维度锁（apps-prod / apps-preprod /
  publish-\<product\> / infra-core）互不阻塞。
- 锁属主语义（2026-09-13，#6/#7 双实证后定稿）：mkdir 锁目录内写 `owner`（BUILD_URL），
  `acquire_deploy_lock` 三态判定——属主=本构建→幂等通过（跨阶段重取不再自锁 #6）；
  属主构建已结束（查 Jenkins API building:false）→立即抢破（中止瞬间在途 mkdir
  "复活"的锁一个轮询周期自愈，#7 门禁空等 15min 根治）；属主在跑→正常等待。
  API 不可达时不误抢，30min 陈旧自愈仍为最后兜底。注意锁目录非空，释放必须 rm -rf。
- 全 stage 超时（2026-09-13）：两 Pipeline 每个 stage 设 declarative `options.timeout`
  （门禁 20m / 构建 45m / 部署 30m / 审批 6h / Rebuild Pre-prod 60m 等）——
  卡死构建在 stage 边界自动失败并走 post 释放锁，不再无限占用 workspace 槽位
  infra-core 仅在 noda-infra Deploy→post 持有（动共享设施时互斥）
- 旧 cleanup job（每周清理）已删除：构建后清理内建于两个 Pipeline 的 post 阶段（镜像保留、registry retention + GC、桶 mirror --remove 收敛）
- Lockable Resources 插件未安装（重构时已从 init 脚本移除创建逻辑）——互斥完全由 r4s mkdir 锁承担，插件层面无残留资源

**Pre-prod 访问（通过 /etc/hosts）：**
```
# 在本地 /etc/hosts 添加（SERVER_IP 替换为服务器 IP）
<SERVER_IP> class.noda.test auth.noda.test www.noda.test admin.noda.test
```
- 主应用: `http://class.noda.test/`
- 认证: `http://auth.noda.test/`
- 官网: `http://www.noda.test/`
- 管理后台: `http://admin.noda.test/`
- 数据库: `noda_preprod`（独立，不污染生产数据）

### Jenkins API 远程触发（curl Runbook）

Jenkins 运行在本机 `http://localhost:8080`，可通过 curl 直接触发 Pipeline。

**凭据：** `scripts/jenkins/config/jenkins-admin.env`

```bash
# 加载凭据
source scripts/jenkins/config/jenkins-admin.env
JENKINS_URL="http://localhost:8080"

# 获取 CSRF Crumb（每次请求前必须获取，需要 cookie jar）
curl -sf -c /tmp/jenkins-cookies -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  "$JENKINS_URL/crumbIssuer/api/json" > /tmp/crumb.json
CRUMB=$(python3 -c "import json; print(json.load(open('/tmp/crumb.json'))['crumb'])")

# 触发应用发布（PRODUCT + LAYER 必选；fast 模式追加 &DEPLOY_MODE=fast，仅限 hotfix）
curl -s -b /tmp/jenkins-cookies -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  -X POST -H "Jenkins-Crumb: $CRUMB" \
  "$JENKINS_URL/job/noda-apps/buildWithParameters?PRODUCT=class&LAYER=api"

# 触发基础设施发布（参数：nginx / seaweedfs / noda-ops / postgres）
curl -s -b /tmp/jenkins-cookies -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  -X POST -H "Jenkins-Crumb: $CRUMB" \
  "$JENKINS_URL/job/noda-infra/buildWithParameters?SERVICE=seaweedfs"

# 查询构建状态（将 N 替换为实际构建号）
curl -sf -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  "$JENKINS_URL/job/noda-apps/N/api/json" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print('building:', d['building'], 'result:', d.get('result','running'))"

# 查看构建日志（最后 100 行）
curl -sf -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  "$JENKINS_URL/job/noda-apps/N/consoleText" | tail -100

# 列出所有 Pipeline 任务
curl -sf -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  "$JENKINS_URL/api/json" | \
  python3 -c "import sys,json; [print(j['name']) for j in json.load(sys.stdin)['jobs']]"

# 人工批准 Human Approval（normal 模式停在这里；ACTION 可选 deploy_prod/rebuild_preprod/abort）
curl -sf -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  "$JENKINS_URL/job/noda-apps/N/wfapi/describe" | \
  python3 -c "import sys,json; [print(s['name'], s['status']) for s in json.load(sys.stdin)['stages']]"
# ⚠️ 批准必须用 /submit 并带 ACTION 参数——/proceedEmpty 不提交 choice，
# DEPLOY_ACTION 为空会静默跳过 Deploy Prod（构建仍显示完成但 prod 未切换）
curl -s -b /tmp/jenkins-cookies -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" \
  -X POST -H "Jenkins-Crumb: $CRUMB" \
  -d "ACTION=deploy_prod" \
  "$JENKINS_URL/job/noda-apps/N/input/<inputId>/submit"
```

**注意事项：**
- HTTP 201 = 构建已排队（成功）
- HTTP 200 + `building: True` = 构建进行中
- 构建号从 `nextBuildNumber` 获取（触发后减 1 即为刚排队的构建号）
- 参数化构建用 `buildWithParameters?PARAM=value`

### 紧急回退：手动部署脚本

Jenkins 不可用时的回退手段：

```bash
# 全量部署（基础设施 + 应用）
bash scripts/deploy/deploy-infrastructure-prod.sh

# 仅部署应用（legacy 单容器回退；三容器拆分后仅作应急回滚用，
# 脚本与旧容器均已删除；回退用保留镜像 noda-apps:56fd05aa 或 pipeline 重发上一 SHA
```

### 查看状态（只读，允许直接使用）

```bash
# Docker Compose 容器状态
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml ps

# 应用容器状态
docker ps --filter name=noda-apps
```

<!-- GSD:project-start source:PROJECT.md -->
## Project

**Noda 基础设施项目**

Noda 项目基础设施仓库，通过 Docker Compose 管理生产环境的数据库、认证、反向代理和应用服务部署。

**技术栈：**
- Docker Compose（多环境 overlay + 独立项目分离）
- PostgreSQL 17.9（prod/dev 双实例）
- Keycloak 26.2.3（Google OAuth + 品牌主题）
- Nginx 1.25-alpine（反向代理 + 故障转移）
- Cloudflare Tunnel（外部访问）
- Backblaze B2 云存储（备份）
- noda-apps（Node.js SSR + API 多应用服务）

**Core Value:** 数据库永不丢失。即使发生服务器崩溃、误删除、数据库损坏等灾难，也能从最近12小时内的备份中恢复数据。
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended Stack
### Core: Jenkins CI/CD Server
| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Jenkins LTS | 2.541.3 | CI/CD 控制器 | 最新 LTS (2026-03-18)，包含安全修复，稳定可靠 | HIGH |
| OpenJDK 21 (Eclipse Temurin) | 21.x | Jenkins 运行时 | Jenkins 官方推荐 JDK，2.541.x LTS 最低要求 Java 17+，Java 21 是当前最优选择 | HIGH |
| Jenkins Pipeline (workflow-aggregator) | 608.v67378e9d3db_1 | Pipeline 引擎 | Declarative Pipeline 语法，89.7% 安装率，Jenkins 标配 | HIGH |
### Jenkins 原生安装（宿主机）
# 前置：安装 Java 21
# 添加 Jenkins apt 源 (LTS)
# systemd 管理
# 将 jenkins 用户加入 docker 组
# 验证（重启 Jenkins 后）
### 部署策略：Pre-prod 验证 + 直接替换
| Component | Mechanism | Confidence |
|-----------|-----------|------------|
| Pre-prod 验证 + 直接替换 | 先部署到 pre-prod 验证，通过后停旧 prod 容器启新 | HIGH |
| 健康检查网关 | 复用现有 `wait_container_healthy` 函数 + HTTP E2E curl 检查 | HIGH |
### 必要的 Jenkins 插件
| Plugin | Version | Purpose | Why Needed | Confidence |
|--------|---------|---------|------------|------------|
| Pipeline (workflow-aggregator) | 608.v67378e9d3db_1 | Declarative Pipeline 引擎 | Jenkinsfile 执行，标准安装包含 | HIGH |
| Git | 最新稳定版 | SCM 集成 | 从 Git 仓库拉取代码和 Jenkinsfile | HIGH |
| Pipeline: Stage View | 最新稳定版 | Pipeline 可视化 | 阶段视图，查看每阶段状态 | HIGH |
| Credentials Binding | 最新稳定版 | 凭据管理 | 安全使用 Docker Hub 凭据、数据库密码等 | HIGH |
| Timestamper | 最新稳定版 | 构建日志时间戳 | 部署调试时精确到秒的日志 | MEDIUM |
| Plugin | Why NOT Needed |
|--------|----------------|
| Docker Pipeline (docker-workflow) | 我们不需要 Jenkins 在容器内构建；Jenkins 在宿主机直接调用 `docker compose` 命令 |
| Blue Ocean | 已不再积极维护，经典 UI + Stage View 足够 |
| Kubernetes | 单服务器部署，无 K8s |
| GitHub Integration | 手动触发部署，不需要 PR hook |
### Pipeline as Code: Jenkinsfile
### 自动回滚机制（2026-09-13 现行架构）
| 场景 | 回滚动作 | 触发条件 |
|------|---------|---------|
| 构建失败/中止 | post 兜底释放全部锁 + 清理镜像，线上不动 | 构建结果非 SUCCESS |
| prod 容器健康检查失败 | `_rollback_prod_containers` 自动回到 `:rollback` 锚点镜像并 reload nginx | `wait_container_healthy` 超时 |
| 桶发布不完整 | 对账重试补传（幂等 mirror），绝不 rm --recursive | 对象计数/哨兵校验不符 |
| 人工回滚前端 | `noda-rollback` 任务 SCOPE=static（桶快照，N 层深度可选） | 手动触发 |
| 人工回滚后端 | `noda-rollback` 任务 SCOPE=api（rollback 锚点，全产品生效） | 手动触发 |
| 边缘反代镜像回滚 | 重新触发 `noda-infra SERVICE=nginx` | 手动触发 |

### 静态站多层快照（2026-09-13 打磨）
- 发布时自动轮转：`snap(N)←snap(N-1)←...←snap(1)←主前缀`（prod+stg 双桶同步）
- 层数 `MAX_STATIC_SNAPSHOTS`（默认 2）：`sites/<product>-prev/`=上一次发布，`-prev2/`=上两次
- 快照前缀不在 nginx 改写映射内，公网不可达；轮转失败仅告警不阻塞发布
- 回滚深度在 `noda-rollback` 任务以 ROLLBACK_DEPTH 参数暴露（1/2）
- 确认恢复后下次发布会重新快照（回滚本身不产生新快照层）

### 人工一键回滚：noda-rollback 任务（2026-09-13，UI 可点）
- 入口：Jenkins UI（或 curl）`noda-rollback`，参数 PRODUCT（8 产品）+ SCOPE + ROLLBACK_DEPTH（1/2）
  - `static`：桶回滚 `sites/<product>-prev/` 快照 → 主前缀，**只影响本产品**（`pipeline_rollback_static_site`）
  - `api`：noda-api 容器回到 `rollback` 锚点镜像——⚠️ 后端全产品单体，**影响所有产品**
  - `all`：两者；边缘反代镜像不在此回滚（走 noda-infra SERVICE=nginx）
- 安全：与发布共用 `build-<product>` 队列锁（同产品排队互斥）；桶回滚持 `publish-<product>`、
  容器回滚持 `apps-prod`；审批前释放队列锁；post 兜底全释放；回滚后自动公网探针 + CDN 清除
- api env 自愈：r4s `/tmp` 为 tmpfs（重启即清 `/tmp/prod-api.env`），缺失时从 Doppler 重建
- 首次发布前无锚点/快照时任务会明确报错（不会盲目动线上）；确认恢复后下次发布会重新快照
- 实测：#1 snagme/static 走 UI 任务全绿（门禁 5s → 批准 → 回滚 51=51 对象 → E2E 通过 → 公网 200）

### E2E 健康检查
| Check | Method | URL | Expected |
|-------|--------|-----|----------|
| 容器健康 | `docker inspect` | Docker healthcheck | `healthy` |
| HTTP API | `curl` | `http://noda-apps-prod:3000/api/health` | HTTP 200 |
| 外部可达性 | `curl` | `https://class.noda.co.nz/api/health` | HTTP 200 |
## Docker Compose 变更
## Alternatives Considered
### Jenkins 安装方式
| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| 宿主机 apt 安装 | Docker 容器运行 | Docker-in-Docker 需挂载 `/var/run/docker.sock`，权限模型复杂；Jenkins 容器内执行 `docker compose` 命令需要额外工具安装；网络隔离导致与 Docker Compose 服务通信困难 |
| Jenkins LTS | Jenkins Weekly | Weekly 版本更新频繁但不保证稳定性，生产环境必须用 LTS |
| | GitHub Actions | 需要公网可访问的 runner，单服务器架构不适合；且项目已有手动部署流程，迁移成本高 |
| | GitLab CI | 需要安装 GitLab 实例，资源消耗远大于 Jenkins；项目不需要 GitLab 的完整 DevOps 平台功能 |
### 部署实现方案
| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| Pre-prod 验证 + 直接替换 | Docker 负载均衡（两个容器同时运行） | 单服务器资源有限，两个实例同时运行会超出内存限制；且应用有状态（SSR session），负载均衡可能导致不一致 |
| | Traefik 自动路由 | 需要引入新的反向代理组件，替代现有 Nginx 架构，改动范围过大 |
| | Docker Compose `scale` + Nginx 负载均衡 | 与应用架构不匹配（SSR 有状态），且单服务器资源受限 |
### CI/CD 触发方式
| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| 手动触发 | Git push 自动触发 | 项目更新频率低（周级别），手动触发更可控；自动触发需要配置 webhook + Jenkins 与 GitHub 的集成，增加攻击面 |
| | 定时触发 | 无意义，代码变更不频繁 |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Jenkins Docker 容器安装 | Docker-in-Docker 权限管理复杂，与宿主机 Docker socket 交互需要特殊处理 | 宿主机 apt 原生安装 |
| Blue Ocean UI 插件 | 已停止维护，社区推荐使用经典 UI + Stage View | Pipeline Stage View |
| Jenkins Scripted Pipeline | CPS 变换导致 `NotSerializableException` 频发，调试困难 | Declarative Pipeline |
| Shared Libraries | 项目规模小（一个 Jenkinsfile），引入 Shared Libraries 是过度工程化 | 直接在 Jenkinsfile 中写所有逻辑 |
| Docker Pipeline 插件 | 设计用于 Pipeline 中运行 Docker 容器作为构建环境，不是用于管理宿主机的 Docker Compose 服务 | 直接 `sh 'docker compose ...'` 命令 |
| Jenkins Configuration as Code (JCasC) | 单服务器、单一 Jenkinsfile 场景下，JCasC 配置比手动初始化更复杂 | 手动初始化 Jenkins + 在 UI 中配置必要参数 |
## Stack Patterns by Variant
- 每次部署前用 `docker image tag` 保存当前镜像为 `noda-apps:rollback`
- 回滚时直接启动使用 rollback tag 的容器
- 不依赖 Docker registry，纯本地镜像管理
- 复用 Pipeline 框架，参数化服务名
## Version Compatibility
| Component | Version | Compatible With | Notes |
|-----------|---------|-----------------|-------|
| Jenkins LTS 2.541.x | 2.541.3 | Java 17, 21, 25 | 2.555.1+ 仅支持 Java 21/25，当前选 Java 21 最安全 |
| OpenJDK 21 | 21.x | Jenkins 2.541.x | 使用 Eclipse Temurin 发行版 |
| Pipeline Plugin | 608.v67378e9d3db_1 | Jenkins 2.479.3+ | 随 LTS 一起更新即可 |
| Docker Compose | v2 (已安装) | Jenkins `sh` 步骤 | Jenkins 以 jenkins 用户执行 docker compose，需要 docker 组权限 |
| Nginx | 1.25-alpine | `nginx -s reload` | 需要从 Jenkins 通过 `docker exec` 发送 reload 信号 |
## Installation
# ============================================
# Jenkins 宿主机安装（一次性）
# ============================================
# 1. 安装 Java 21
# 2. 安装 Jenkins LTS
# 3. 配置 Jenkins 用户权限
# 4. 可选：修改 Jenkins 端口（如果 8080 与其他服务冲突）
# 添加:
# [Service]
# Environment="JENKINS_PORT=8080"
# 5. 启动 Jenkins
# 6. 获取初始密码
# 7. 浏览器访问 http://<server-ip>:8080
#    - 安装建议插件
#    - 创建管理员用户
#    - 额外安装: Pipeline Stage View（通常已包含）
# ============================================
# Jenkins 卸载（如果需要）
# ============================================
## 与现有架构的集成点
| 现有组件 | 集成方式 | 变更范围 |
|---------|---------|---------|
| `config/nginx/conf.d/default.conf` | upstream 使用 `include` 引用配置文件 | 小 — upstream include |
| `scripts/lib/health.sh` | Pipeline 直接复用 `wait_container_healthy` | 无变更 |
| `deploy-apps-prod.sh` | 逻辑迁移到 Jenkinsfile | 脚本已删除（2026-09-10 切换稳定后） |
| `scripts/deploy/deploy-apps-prod.sh` | 保留作为无 Jenkins 时的手动部署入口 | 已删除；回退用保留镜像 noda-apps:56fd05aa |
| `scripts/lib/log.sh` | Pipeline 中通过 `sh` 步骤调用 | 无变更 |
## Sources
- [Jenkins LTS Changelog](https://www.jenkins.io/changelog-stable/) — 确认 2.541.3 为最新 LTS (2026-03-18)，HIGH confidence
- [Jenkins Linux 安装文档](https://www.jenkins.io/doc/book/installing/linux/) — Debian/Ubuntu apt 安装步骤，HIGH confidence
- [Jenkins Java 支持策略](https://www.jenkins.io/doc/book/platform-information/support-policy-java/) — 2.541.x 支持 Java 17/21/25，HIGH confidence
- [Jenkins Pipeline 文档](https://www.jenkins.io/doc/book/pipeline/) — Declarative Pipeline 语法参考，HIGH confidence
- [Jenkins Docker Pipeline 集成](https://www.jenkins.io/doc/book/pipeline/docker/) — 确认不需要 Docker Pipeline 插件，HIGH confidence
- [Jenkins Pipeline 最佳实践](https://www.jenkins.io/doc/book/pipeline/pipeline-best-practices/) — 使用 `sh` 而非 Groovy 逻辑，HIGH confidence
- [Jenkins systemd 服务管理](https://www.jenkins.io/doc/book/system-administration/systemd-services/) — 配置 Jenkins 服务，HIGH confidence
- [Pipeline Plugin (workflow-aggregator)](https://plugins.jenkins.io/workflow-aggregator/) — 版本 608.v67378e9d3db_1，89.7% 安装率，HIGH confidence
- [Docker Pipeline Plugin (docker-workflow)](https://plugins.jenkins.io/docker-workflow/) — 确认不适合本场景，HIGH confidence
- 项目代码: `docker/docker-compose.apps-prod.yml`, `config/nginx/conf.d/default.conf`, `scripts/deploy/deploy-apps-prod.sh` — 现有架构分析
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, or `.github/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

## 运维操作规则

### 禁止手动操作生产容器

**严禁 LLM 手动执行 `docker stop/rm/run` 等命令操作生产容器。** 所有容器部署、重启、重建必须通过 Jenkins Pipeline 或项目脚本执行。

| 操作 | 正确方式 |
|------|----------|
| 重建 noda-ops | `Jenkins noda-infra?SERVICE=noda-ops` |
| 重建 nginx | `Jenkins noda-infra?SERVICE=nginx` |
| 部署应用 | `Jenkins noda-apps`（参数 PRODUCT + LAYER） |
| 爬虫抓取 | noda-api 内置 cron（每天 09:00 tutoring / 周一 10:00 hobby NZST）；`CRON_ENABLED=false` 可关闭。旧 python 爬虫链路（Jenkins run-crawler-temp / noda-ops crawl-skykiwi.py）已于 2026-09 退役 |

**允许的只读操作：** `docker ps`、`docker logs`、`docker exec`（查看状态）、`docker inspect`、`curl` 健康检查。
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
