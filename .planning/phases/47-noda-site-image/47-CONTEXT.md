# Phase 47: noda-site 镜像优化 - Context

**Gathered:** 2026-04-20
**Status:** Ready for planning

<domain>
## Phase Boundary

将 noda-site 运行时从 Node.js `serve` 切换到 `nginx:1.25-alpine`，镜像体积从 ~218MB 降至 <30MB。保持端口 3000 和蓝绿部署全流程兼容。

**涉及需求：** SITE-01, SITE-02, SITE-03

**前置条件：** 无（独立阶段）

</domain>

<decisions>
## Implementation Decisions

### 容器内 nginx 配置
- **D-01:** SPA fallback — 所有未匹配路径返回 index.html，与当前 `serve -s dist` 行为完全一致
- **D-02:** 容器内 nginx 不设置缓存头 — 外层 nginx（default.conf）已处理缓存策略（静态资源 1 年 + immutable，HTML no-cache），避免两层缓存冲突
- **D-03:** 不启用 gzip 压缩 — Cloudflare + 外层 nginx 已处理压缩，容器内无需重复

### 健康检查与安全
- **D-04:** HTTP 健康检查 — 使用 `curl` 或 `wget`（BusyBox）请求 `http://localhost:3000/`，验证 nginx 正常响应
- **D-05:** 非 root 运行 — 以 nginx 用户运行，需配置可写目录（`/var/cache/nginx`、`/var/run` 等）

### Jenkins Pipeline 适配
- **D-06:** 不仅修改 Dockerfile，还优化 Pipeline — 包括 pnpm 构建缓存挂载、缩短健康检查等待时间、降低资源限制
- **D-07:** pnpm 构建缓存 — 挂载主机 pnpm store 作为构建缓存，加速重复构建
- **D-08:** 缩短健康检查等待 — nginx 启动比 Node.js 更快，可缩短 start_period 和检查间隔
- **D-09:** 降低资源限制 — 当前 64MB 内存限制，nginx 运行时可以进一步降低

### Claude's Discretion
- HEALTHCHECK 具体命令（curl vs wget，取决于 nginx:alpine 可用工具）
- 非 root 运行的具体配置方式（tmpfs 挂载路径、nginx.conf user 指令）
- 资源限制的具体数值
- 健康检查超时参数的具体调整值
- pnpm 缓存挂载的具体实现方式

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Dockerfile（主要修改目标）
- `deploy/Dockerfile.noda-site` — 当前 Dockerfile，需要重写 runner 阶段为 nginx:1.25-alpine

### Docker Compose 配置（需调整参数）
- `docker/docker-compose.app.yml` — noda-site 服务定义（健康检查命令、资源限制、tmpfs 配置）

### Jenkins Pipeline（需优化）
- `jenkins/Jenkinsfile.noda-site` — noda-site 蓝绿部署 Pipeline（构建参数、健康检查、pnpm 缓存）
- `scripts/pipeline-stages.sh` — Pipeline 共享函数（pipeline_build、pipeline_health_check 等）

### Nginx 配置
- `config/nginx/snippets/upstream-noda-site.conf` — upstream 配置，指向 noda-site-blue:3000
- `config/nginx/conf.d/default.conf` — 外层 nginx 配置，noda.co.nz 域名的缓存和代理设置

### 前序 Phase 决策
- `.planning/phases/46-nginx-blue-green/46-CONTEXT.md` — nginx DNS 解析和 reload 机制
- `.planning/phases/36-blue-green-unify/36-CONTEXT.md` — 蓝绿部署统一参数化

### 源码
- `noda-apps/apps/site/` — noda-site 源码（Vite + React + TypeScript + prerender）

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `config/nginx/snippets/upstream-noda-site.conf` — upstream 指向 `noda-site-blue:3000`，保持不变
- `scripts/blue-green-deploy.sh` — 蓝绿部署脚本已参数化，无需修改
- `scripts/lib/health.sh` — `wait_container_healthy()` 函数，基于 Docker healthcheck 状态，不依赖具体命令

### Established Patterns
- 蓝绿部署流程：Build → Deploy → Health Check → Switch → Verify，所有步骤通过 SERVICE_NAME/SERVICE_PORT/HEALTH_PATH 参数化
- Docker 健康检查：`docker-compose.app.yml` 定义，`wait_container_healthy()` 轮询
- 资源限制：当前 64MB 内存 + 0.25 CPU，只读文件系统 + tmpfs /tmp
- 非 root 运行：findclass-ssr 使用 adduser 模式，nginx 需要类似但不同（nginx 自带用户）

### Integration Points
- `jenkins/Jenkinsfile.noda-site` line 18: `DOCKERFILE = "deploy/Dockerfile.noda-site"` — Dockerfile 路径
- `jenkins/Jenkinsfile.noda-site` line 13-16: SERVICE_NAME/SERVICE_PORT/HEALTH_PATH — 部署参数
- `docker/docker-compose.app.yml`: noda-site 服务健康检查和资源限制定义
- 容器内 nginx 监听端口 3000（保持蓝绿兼容）

### 当前 Dockerfile 分析
- **Stage 1 (builder):** node:20-alpine + pnpm + Chromium (prerender) — 这个阶段保持不变
- **Stage 2 (runner):** node:20-alpine + serve@14 — 需要替换为 nginx:1.25-alpine
- 构建产物：`/app/apps/site/dist` — 预渲染 HTML + 静态资源（JS/CSS/img）
- 健康检查：wget http://localhost:3000/
- 非 root 用户：nodejs:1001

</code_context>

<specifics>
## Specific Ideas

- nginx:1.25-alpine 与项目已有 nginx 版本一致（主 nginx 用 1.25-alpine），可以共享层缓存
- SPA fallback 在 nginx 中用 `try_files $uri $uri/ /index.html` 实现
- nginx 非 root 运行需要：(1) 全局 nginx.conf 中 user 指令移除或改为 nginx (2) /var/cache/nginx 和 /var/run 需要可写（tmpfs 或目录权限）
- read_only: true + cap_drop: ALL 的安全配置已经在 docker-compose.app.yml 中，保持不变

</specifics>

<deferred>
## Deferred Ideas

- HYGIENE-02（COPY --chown 替代 RUN chown）属于 Phase 48 范围，不在本 Phase 中实施
- findclass-ssr Alpine 切换和 Python 分离属于 Phase 49-51 范围

</deferred>

---
*Phase: 47-noda-site-image*
*Context gathered: 2026-04-20*
