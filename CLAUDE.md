# Noda Infrastructure - Claude 项目指南

## 项目概述

Noda 基础设施仓库，管理 Docker Compose 部署配置。包含 PostgreSQL、Keycloak、Nginx、Cloudflare Tunnel、findclass-ssr 等服务。

## 架构

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops 容器) → nginx → Docker 内部服务
  class.noda.co.nz → nginx → findclass-ssr (SSR + API + 静态文件)
  auth.noda.co.nz  → nginx → keycloak:8080 (容器内部)
```

| 服务 | 端口 | 备注 |
|------|------|------|
| PostgreSQL | 5432 | 数据持久化在 `noda-infra_postgres_data` 卷 |
| Keycloak | 8080 (内部) | 不暴露外部端口，通过 nginx 反向代理访问 |
| findclass-ssr | 3001 | SSR + 静态文件，通过 nginx 代理 |
| noda-ops | - | 备份 + Cloudflare Tunnel |
| Nginx | 80 | 反向代理（所有外部流量统一入口） |

## 部署规则

### 禁止直接使用 Docker Compose 命令

**严禁 LLM 直接运行 `docker compose up/down/restart/start/stop` 等命令来上线/下线服务。**

所有服务部署、重启、下线操作必须通过项目脚本执行：

| 操作 | 脚本 |
|------|------|
| 全量部署（基础设施+应用） | `bash scripts/deploy/deploy-infrastructure-prod.sh` |
| 部署应用（findclass-ssr） | `bash scripts/deploy/deploy-apps-prod.sh` |

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
| 1 | 前端构建 | JS 中 Keycloak URL 硬编码为 `localhost:8080`（构建时未传 `VITE_KEYCLOAK_URL`） | `deploy/Dockerfile.findclass-ssr` 添加 ARG |
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

### findclass-ssr 镜像重建

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

通过 Jenkins UI 手动触发蓝绿部署 Pipeline：

1. 浏览器访问 Jenkins（默认 http://\<server-ip\>:8888）
2. 点击 `findclass-deploy` 任务
3. 点击 "Build Now" 按钮
4. Pipeline 自动执行 9 阶段：Pre-flight -> Build -> Test -> Deploy -> Health Check -> Switch -> Verify -> CDN Purge -> Cleanup
5. 查看 Stage View 确认各阶段状态

### 紧急回退：手动部署脚本

Jenkins 不可用时，可使用旧部署脚本手动部署：

```bash
# 全量部署（基础设施 + 应用）
bash scripts/deploy/deploy-infrastructure-prod.sh

# 仅部署应用（findclass-ssr）
bash scripts/deploy/deploy-apps-prod.sh
```

### 查看状态（只读，允许直接使用）

```bash
# Docker Compose 容器状态
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml ps

# 蓝绿容器状态
cat /opt/noda/active-env  # 当前活跃环境（blue/green）
docker ps --filter name=findclass-ssr  # 蓝绿容器列表
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
- findclass-ssr（Node.js SSR 三合一服务）

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
### Blue-Green Deployment: Nginx Upstream 切换方案
| Component | Mechanism | Confidence |
|-----------|-----------|------------|
| Nginx upstream 切换 | 修改 upstream 块中 server 地址 + `nginx -s reload` | HIGH |
| Docker Compose 蓝绿容器 | `docker-compose.app.yml` 中定义 `findclass-ssr-blue` 和 `findclass-ssr-green` 两个服务 | HIGH |
| 健康检查网关 | 复用现有 `wait_container_healthy` 函数 + HTTP E2E curl 检查 | HIGH |
### 必要的 Jenkins 插件
| Plugin | Version | Purpose | Why Needed | Confidence |
|--------|---------|---------|------------|------------|
| Pipeline (workflow-aggregator) | 608.v67378e9d3db_1 | Declarative Pipeline 引擎 | Jenkinsfile 执行，标准安装包含 | HIGH |
| Git | 最新稳定版 | SCM 集成 | 从 Git 仓库拉取代码和 Jenkinsfile | HIGH |
| Pipeline: Stage View | 最新稳定版 | Pipeline 可视化 | 阶段视图，查看每阶段状态 | HIGH |
| Credentials Binding | 最新稳定版 | 凭据管理 | 安全使用 Docker Hub 凭据、数据库密码等 | HIGH |
| Timestamper | 最新稳定版 | 构建日志时间戳 | 蓝绿部署调试时精确到秒的日志 | MEDIUM |
| Plugin | Why NOT Needed |
|--------|----------------|
| Docker Pipeline (docker-workflow) | 我们不需要 Jenkins 在容器内构建；Jenkins 在宿主机直接调用 `docker compose` 命令 |
| Blue Ocean | 已不再积极维护，经典 UI + Stage View 足够 |
| Kubernetes | 单服务器部署，无 K8s |
| GitHub Integration | 手动触发部署，不需要 PR hook |
### Pipeline as Code: Jenkinsfile
### 自动回滚机制
| 场景 | 回滚动作 | 触发条件 |
|------|---------|---------|
| 构建失败 | 不启动新容器，一切不变 | `docker compose build` 返回非零 |
| 新容器健康检查失败 | 切回旧 upstream，停新容器 | `wait_container_healthy` 超时 |
| E2E HTTP 检查失败 | 切回旧 upstream，停新容器 | curl 返回非 200 或超时 |
| 部署后人工确认回滚 | Pipeline `input` 步骤等待确认 | 手动触发 |
### E2E 健康检查
| Check | Method | URL | Expected |
|-------|--------|-----|----------|
| 容器健康 | `docker inspect` | Docker healthcheck | `healthy` |
| HTTP API | `curl` | `http://findclass-ssr-{color}:3001/api/health` | HTTP 200 |
| 外部可达性 | `curl` | `https://class.noda.co.nz/api/health` | HTTP 200 |
## Docker Compose 变更
# 当前（单容器）:
# 蓝绿部署（双容器，同一文件，同时只启动一个）:
## Alternatives Considered
### Jenkins 安装方式
| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| 宿主机 apt 安装 | Docker 容器运行 | Docker-in-Docker 需挂载 `/var/run/docker.sock`，权限模型复杂；Jenkins 容器内执行 `docker compose` 命令需要额外工具安装；网络隔离导致与 Docker Compose 服务通信困难 |
| Jenkins LTS | Jenkins Weekly | Weekly 版本更新频繁但不保证稳定性，生产环境必须用 LTS |
| | GitHub Actions | 需要公网可访问的 runner，单服务器架构不适合；且项目已有手动部署流程，迁移成本高 |
| | GitLab CI | 需要安装 GitLab 实例，资源消耗远大于 Jenkins；项目不需要 GitLab 的完整 DevOps 平台功能 |
### 蓝绿部署实现方案
| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| Nginx upstream 切换 | Docker 负载均衡（两个容器同时运行） | 单服务器资源有限，两个 findclass-ssr 实例同时运行会超出内存限制（每个 512MB limit）；且应用有状态（SSR session），负载均衡可能导致不一致 |
| | 端口直接替换（停旧启新） | 存在停机窗口（旧容器停 → 新容器启动 → 健康检查通过），不符合零停机目标 |
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
- 可以考虑让两个 findclass-ssr 实例同时运行一段时间
- 在 Nginx 切换后等待 30 秒再停旧容器，确保所有长连接完成
- 默认配置即可，因为当前方案已经是最保守的
- 每次部署前用 `docker image tag` 保存当前镜像为 `findclass-ssr:rollback`
- 回滚时直接 `docker compose up` 使用 rollback tag
- 不依赖 Docker registry，纯本地镜像管理
- 同样的蓝绿模式，定义 `noda-site-blue` 和 `noda-site-green`
- Nginx 的 `noda_site_backend` upstream 做同样的切换
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
# 4. 可选：修改 Jenkins 端口（如果 8080 与 Keycloak 冲突）
# 添加:
# [Service]
# Environment="JENKINS_PORT=8888"
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
| `docker-compose.app.yml` | 添加 blue/green 双服务定义 | 中等 — 重构 findclass-ssr 为两个服务 |
| `config/nginx/conf.d/default.conf` | upstream 改为 `include` 引用可切换文件 | 小 — 添加 upstream include |
| `scripts/lib/health.sh` | Pipeline 直接复用 `wait_container_healthy` | 无变更 |
| `deploy-apps-prod.sh` | 逻辑迁移到 Jenkinsfile，脚本保留作为回退 | 新增 Jenkinsfile，脚本不变 |
| `scripts/deploy/deploy-apps-prod.sh` | 保留作为无 Jenkins 时的手动部署入口 | 无变更 |
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
- 项目代码: `docker/docker-compose.app.yml`, `config/nginx/conf.d/default.conf`, `scripts/deploy/deploy-apps-prod.sh` — 现有架构分析
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

<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
