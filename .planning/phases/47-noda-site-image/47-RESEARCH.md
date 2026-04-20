# Phase 47: noda-site 镜像优化 - Research

**Researched:** 2026-04-20
**Domain:** Docker 多阶段构建 + nginx 静态文件服务 + 蓝绿部署
**Confidence:** HIGH

## Summary

将 noda-site 运行时从 Node.js `serve`（node:20-alpine + serve@14）切换到 `nginx:1.25-alpine`。核心改动集中在 3 个文件：Dockerfile（重写 runner 阶段）、docker-compose.app.yml（健康检查和资源限制调整）、Jenkinsfile（健康检查命令和启动参数优化）。

关键技术验证已完成：nginx 非 root 用户可以在端口 3000 上运行（端口 > 1024 不需要特权）；`read_only: true` + `tmpfs /tmp` 组合正常工作；BusyBox wget 支持 `--spider` 但**必须使用 127.0.0.1 而非 localhost**（IPv6 解析问题）。

**Primary recommendation:** 重写 Dockerfile runner 阶段为 nginx:1.25-alpine，自定义 nginx.conf 指向 /tmp 写入临时文件和 PID，用 `try_files $uri $uri/ /index.html` 实现 SPA fallback。Jenkinsfile 必须新增 `CONTAINER_HEALTH_CMD` 和 `CONTAINER_MEMORY` 环境变量，否则蓝绿部署的健康检查会失败。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** SPA fallback -- 所有未匹配路径返回 index.html，与当前 `serve -s dist` 行为完全一致
- **D-02:** 容器内 nginx 不设置缓存头 -- 外层 nginx（default.conf）已处理缓存策略（静态资源 1 年 + immutable，HTML no-cache），避免两层缓存冲突
- **D-03:** 不启用 gzip 压缩 -- Cloudflare + 外层 nginx 已处理压缩，容器内无需重复
- **D-04:** HTTP 健康检查 -- 使用 `curl` 或 `wget`（BusyBox）请求 `http://localhost:3000/`，验证 nginx 正常响应
- **D-05:** 非 root 运行 -- 以 nginx 用户运行，需配置可写目录（`/var/cache/nginx`、`/var/run` 等）
- **D-06:** 不仅修改 Dockerfile，还优化 Pipeline -- 包括 pnpm 构建缓存挂载、缩短健康检查等待时间、降低资源限制
- **D-07:** pnpm 构建缓存 -- 挂载主机 pnpm store 作为构建缓存，加速重复构建
- **D-08:** 缩短健康检查等待 -- nginx 启动比 Node.js 更快，可缩短 start_period 和检查间隔
- **D-09:** 降低资源限制 -- 当前 64MB 内存限制，nginx 运行时可以进一步降低

### Claude's Discretion
- HEALTHCHECK 具体命令（curl vs wget，取决于 nginx:alpine 可用工具）
- 非 root 运行的具体配置方式（tmpfs 挂载路径、nginx.conf user 指令）
- 资源限制的具体数值
- 健康检查超时参数的具体调整值
- pnpm 缓存挂载的具体实现方式

### Deferred Ideas (OUT OF SCOPE)
- HYGIENE-02（COPY --chown 替代 RUN chown）属于 Phase 48 范围，不在本 Phase 中实施
- findclass-ssr Alpine 切换和 Python 分离属于 Phase 49-51 范围
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SITE-01 | noda-site 运行时从 node:20-alpine + serve 切换到 nginx:1.25-alpine（保持端口 3000，蓝绿部署兼容） | Dockerfile 重写 runner 阶段 + 自定义 nginx.conf + 非 root 配置已验证 |
| SITE-02 | 多阶段构建保留 Puppeteer prerender 构建阶段，运行时仅包含静态文件 + nginx | builder 阶段完全保留，仅替换 runner 阶段基础镜像 |
| SITE-03 | Jenkins Pipeline noda-site 部署流程适配新 Dockerfile（构建参数、健康检查） | Jenkinsfile 需新增 CONTAINER_HEALTH_CMD + 优化健康检查参数 + pnpm 缓存 |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| SPA 静态文件服务 | 容器内 nginx | -- | nginx 直接从本地文件系统提供 HTML/JS/CSS |
| 缓存策略 | 外层 nginx (default.conf) | Cloudflare CDN | 外层 nginx 已配置 1 年 + immutable，容器内不重复 |
| 压缩 | Cloudflare CDN | 外层 nginx | Cloudflare 自动压缩，容器内无需 gzip |
| 健康检查 | Docker HEALTHCHECK | manage-containers.sh | Dockerfile 定义命令，manage-containers.sh 轮询状态 |
| 蓝绿切换 | manage-containers.sh | upstream-noda-site.conf | 通过修改 upstream 指向的容器名实现流量切换 |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| nginx | 1.25-alpine | 静态文件服务 + SPA fallback | 与外层 nginx 版本一致，可共享镜像层缓存（76.5MB） |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| BusyBox wget | 1.36.1 (内置) | 容器健康检查 | HEALTHCHECK CMD 中使用 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| nginx:1.25-alpine | nginxinc/nginx-unprivileged:alpine | unprivileged 镜像预配置非 root，但引入额外依赖且与现有 nginx 镜像不共享层 |
| BusyBox wget (HEALTHCHECK) | curl (内置) | curl 也可用，但 wget --spider 不下载内容更轻量 |

**Installation:**
无需额外安装 -- nginx:1.25-alpine 包含所有需要的工具（nginx, wget, curl,BusyBox）。

**Version verification:**
```
nginx:1.25-alpine = nginx/1.25.5, Alpine 3.19.1, BusyBox 1.36.1
```
[VERIFIED: docker run --rm nginx:1.25-alpine sh -c 'nginx -v && cat /etc/os-release | head -1']

## Architecture Patterns

### System Architecture Diagram

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel → 外层 nginx (noda-infra-nginx)
                                                    │
                                                    │ proxy_pass http://noda_site_backend
                                                    ↓
                                              upstream-noda-site.conf
                                                    │
                                                    │ server noda-site-{color}:3000
                                                    ↓
                                         容器内 nginx (nginx:1.25-alpine, port 3000)
                                              │                    │
                                              │ try_files          │ /usr/share/nginx/html
                                              │ $uri /index.html   │ (静态文件)
                                              ↓                    ↓
                                         SPA 路由处理         静态资源 (JS/CSS/img)
```

### Recommended Project Structure
```
deploy/
├── Dockerfile.noda-site          # 多阶段构建（builder + nginx runner）
└── nginx/                        # 新增：容器内 nginx 配置
    ├── nginx.conf                # 主配置（非 root + 日志/PID 指向 /tmp）
    └── default.conf              # server 块（SPA fallback + 端口 3000）
```

### Pattern 1: 多阶段构建保留 builder + 替换 runner

**What:** 保留 Stage 1 (builder) 完整的 pnpm + Chromium prerender 构建流程，仅替换 Stage 2 (runner) 基础镜像。

**When to use:** 静态站点需要复杂构建（prerender）但运行时只需静态文件服务。

**Example:**
```dockerfile
# Stage 1: 完全保留（node:20-alpine + pnpm + chromium prerender）
FROM node:20-alpine AS builder
# ... 不变 ...

# Stage 2: 轻量运行时（nginx:1.25-alpine）
FROM nginx:1.25-alpine AS runner

# 移除默认 nginx 配置
RUN rm /etc/nginx/conf.d/default.conf

# 复制自定义 nginx 配置
COPY --from=deploy/nginx/nginx.conf /etc/nginx/nginx.conf
COPY --from=deploy/nginx/default.conf /etc/nginx/conf.d/default.conf

# 复制构建产物（--chown 属于 Phase 48 范围，这里用 RUN chown）
COPY --from=builder /app/apps/site/dist /usr/share/nginx/html

# 确保 nginx 用户可写
RUN chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx

USER nginx

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=3s --retries=3 --start-period=3s \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:3000/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
```

### Pattern 2: 非 root nginx 配置

**What:** 自定义 nginx.conf 将 PID、日志、临时文件都指向 /tmp（tmpfs 挂载），避免写入只读文件系统。

**When to use:** Docker `read_only: true` + 非 root 运行。

**Example -- deploy/nginx/nginx.conf:**
```nginx
pid /tmp/nginx.pid;
error_log /tmp/error.log notice;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    access_log /tmp/access.log;

    # 所有临时文件写入 /tmp（tmpfs 挂载）
    client_body_temp_path /tmp/client_temp;
    proxy_temp_path       /tmp/proxy_temp_path;
    fastcgi_temp_path     /tmp/fastcgi_temp;
    uwsgi_temp_path       /tmp/uwsgi_temp;
    scgi_temp_path        /tmp/scgi_temp;

    include /etc/nginx/conf.d/*.conf;
}
```

**Example -- deploy/nginx/default.conf:**
```nginx
server {
    listen 3000;
    server_name localhost;
    root /usr/share/nginx/html;
    index index.html;

    # SPA fallback（等价于 serve -s）
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

### Pattern 3: BuildKit 缓存挂载（pnpm store）

**What:** 使用 `--mount=type=cache` 在 builder 阶段缓存 pnpm store，加速重复构建。

**When to use:** Jenkins Pipeline 中多次构建同一服务。

**Example:**
```dockerfile
# 在 builder 阶段
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    corepack enable && corepack prepare pnpm@latest --activate && \
    pnpm install --frozen-lockfile --ignore-scripts --filter @noda-apps/site...
```

### Anti-Patterns to Avoid
- **容器内 nginx 设置缓存头:** 外层 default.conf 已处理（静态 1y+immutable，HTML no-cache），两层缓存会冲突 [VERIFIED: config/nginx/conf.d/default.conf line 130-145]
- **容器内 nginx 开启 gzip:** Cloudflare + 外层 nginx 已处理压缩，容器内 gzip 浪费 CPU
- **HEALTHCHECK 使用 `localhost`:** BusyBox wget 将 localhost 解析为 IPv6 (::1) 导致连接失败，必须使用 `127.0.0.1` [VERIFIED: docker run 测试]
- **使用 `node -e fetch(...)` 健康检查:** nginx 容器内无 Node.js，必须使用 wget/curl [VERIFIED: nginx:1.25-alpine 无 node]
- **nginx 监听端口 80:** 非 root 用户不能绑定 < 1024 端口，必须使用 3000（> 1024）

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SPA 路由 fallback | 自定义 URL 重写规则 | `try_files $uri $uri/ /index.html` | nginx 原生指令，久经考验 |
| 非 root 容器配置 | 手动创建用户和目录权限 | nginx:1.25-alpine 自带 nginx 用户 (UID=101) | 镜像预配置，权限正确 |
| MIME 类型映射 | 手动维护 MIME 列表 | `include /etc/nginx/mime.types` | nginx 自带完整 MIME 映射表 |

**Key insight:** nginx:1.25-alpine 已包含所有必需组件（nginx、wget、curl、mime.types、nginx 用户），不需要额外安装任何东西。

## Common Pitfalls

### Pitfall 1: BusyBox wget IPv6 解析问题
**What goes wrong:** HEALTHCHECK 使用 `wget --quiet --tries=1 --spider http://localhost:3000/` 失败
**Why it happens:** BusyBox wget 将 `localhost` 解析为 IPv6 (::1)，nginx 只监听 IPv4 的 3000 端口
**How to avoid:** 健康检查 URL 使用 `http://127.0.0.1:3000/` 而非 `http://localhost:3000/`
**Warning signs:** 健康检查一直报 `Connection refused` 但 nginx 进程正常
[VERIFIED: docker run --rm nginx:1.25-alpine 测试确认]

### Pitfall 2: manage-containers.sh 默认健康检查命令不兼容
**What goes wrong:** 蓝绿部署新容器后健康检查永远失败
**Why it happens:** run_container() 默认健康检查命令是 `node -e fetch(...)`（manage-containers.sh line 204），nginx 容器内无 Node.js
**How to avoid:** Jenkinsfile.noda-site 必须设置 `CONTAINER_HEALTH_CMD` 环境变量覆盖默认值
**Warning signs:** 容器启动成功但 Docker healthcheck 一直 `starting` → `unhealthy`
[VERIFIED: scripts/manage-containers.sh line 204 默认值分析]

### Pitfall 3: nginx 日志路径权限问题
**What goes wrong:** nginx 启动时出现 `open() "/var/log/nginx/access.log" failed (13: Permission denied)`
**Why it happens:** `/var/log/nginx/` 目录归 root 所有，nginx 用户无写入权限；且日志文件是符号链接指向 /dev/stdout
**How to avoid:** 自定义 nginx.conf 将 `access_log` 和 `error_log` 指向 /tmp/（tmpfs 可写）
**Warning signs:** nginx 启动时有 `[alert]` 日志但进程正常运行（不影响功能，但不优雅）
[VERIFIED: docker run 测试确认]

### Pitfall 4: --tmpfs /app/scripts/logs 对 nginx 无用
**What goes wrong:** 无实际危害，但浪费内存
**Why it happens:** manage-containers.sh run_container() 硬编码 `--tmpfs /app/scripts/logs`（findclass-ssr 专用路径），对 nginx 容器无意义
**How to avoid:** 不需要处理 -- Docker 对不存在的 tmpfs 目标目录不会报错，只是创建空目录。可以通过 EXTRA_DOCKER_ARGS 覆盖，但不是必须的
[VERIFIED: manage-containers.sh line 219 硬编码分析]

### Pitfall 5: nginx.conf 全局 user 指令冲突
**What goes wrong:** 自定义 nginx.conf 保留 `user nginx;` 指令但 Dockerfile 使用 `USER nginx`
**Why it happens:** Docker `USER nginx` 已经以 nginx 用户身份运行进程，nginx.conf 的 `user` 指令尝试切换用户但权限不足
**How to avoid:** 自定义 nginx.conf 中移除 `user` 指令（不写 user 行等同于以当前用户运行）
[ASSUMED - 基于常见 nginx 非 root 配置最佳实践]

## Code Examples

### 完整的 Dockerfile.noda-site（重写后）

```dockerfile
# ============================================
# NODA Site 容器 - 多阶段构建
# ============================================
# 镜像名: noda-site:latest
# 功能: 纯静态文件服务（预渲染 HTML + 静态资源）
# 运行时: nginx:1.25-alpine（~25MB，对比 node:20-alpine + serve ~218MB）
# ============================================

# ----------------------------------------
# Stage 1: 构建依赖和产出（完全保留）
# ----------------------------------------
FROM node:20-alpine AS builder

WORKDIR /app

# 复制整个项目（pnpm workspace 需要完整的包结构）
COPY . .

# 启用 pnpm 并安装依赖（使用 BuildKit 缓存挂载加速重复构建，per D-07）
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    corepack enable && corepack prepare pnpm@latest --activate && \
    pnpm install --frozen-lockfile --ignore-scripts --filter @noda-apps/site...

# 安装 Chromium 供 prerender Puppeteer 使用
RUN apk add --no-cache chromium
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# 构建 design-tokens（site 依赖其 CSS 输出）
RUN cd packages/design-tokens && pnpm run build

# 构建 site（包含 prerender）
RUN cd apps/site && pnpm run build

# ----------------------------------------
# Stage 2: nginx 轻量运行时
# ----------------------------------------
FROM nginx:1.25-alpine AS runner

# 移除默认 nginx 配置
RUN rm /etc/nginx/conf.d/default.conf

# 复制自定义 nginx 配置（非 root + 日志/PID 指向 /tmp）
COPY deploy/nginx/nginx.conf /etc/nginx/nginx.conf
COPY deploy/nginx/default.conf /etc/nginx/conf.d/default.conf

# 仅复制构建产物
COPY --from=builder /app/apps/site/dist /usr/share/nginx/html

# 设置目录权限（Phase 48 可优化为 COPY --chown）
RUN chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx

USER nginx

EXPOSE 3000

# 健康检查（注意：使用 127.0.0.1 而非 localhost，BusyBox wget IPv6 问题）
HEALTHCHECK --interval=10s --timeout=3s --retries=3 --start-period=3s \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:3000/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
```

### Jenkinsfile.noda-site 关键修改

```groovy
environment {
    // ... 现有参数不变 ...
    SERVICE_NAME = "noda-site"
    SERVICE_PORT = "3000"
    HEALTH_PATH = "/"
    // 新增：覆盖 manage-containers.sh 默认健康检查命令
    CONTAINER_HEALTH_CMD = "wget --quiet --tries=1 --spider http://127.0.0.1:3000/ || exit 1"
    // 新增：nginx 运行时内存更低
    CONTAINER_MEMORY = "32m"
    CONTAINER_MEMORY_RESERVATION = "8m"
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| node:20-alpine + serve@14 | nginx:1.25-alpine | Phase 47 | 镜像体积从 ~218MB 降至 ~25MB |
| Node.js 健康检查 | BusyBox wget --spider | Phase 47 | 无需 Node.js 运行时 |
| start_period: 10s | start_period: 3s | Phase 47 | nginx 启动 < 1 秒，减少等待 |
| 64MB 内存限制 | 32MB 内存限制 | Phase 47 | nginx 静态文件服务内存极低 |
| pnpm install 无缓存 | BuildKit --mount=type=cache | Phase 47 | 重复构建加速（per D-07） |

**Deprecated/outdated:**
- `serve` npm 包作为静态文件服务器：在容器化场景中，nginx 更轻量、更快、更安全
- Node.js 运行时用于纯静态文件服务：完全不必要，浪费约 190MB 镜像空间

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | nginx.conf 中不写 `user` 指令时，nginx 以当前用户（Docker USER）运行 | 非 root 配置 | 低 -- 如果需要 user 指令，可以添加 `user nginx;` 但需确保 nginx 用户有足够权限 |
| A2 | pnpm store 缓存挂载能显著加速构建（BUILDKIT_CACHE） | Pipeline 优化 | 低 -- 即使缓存无效，构建只是变慢，不会失败 |
| A3 | 32MB 内存限制足够 nginx 运行（静态文件服务无复杂逻辑） | 资源限制 | 中 -- 如果并发量突增可能 OOM，需监控 |
| A4 | prerender 构建产物 `dist/` 目录结构与 `serve -s` 兼容（即所有路由的 HTML 文件都在根目录或子目录中） | SPA fallback | 低 -- `try_files $uri $uri/ /index.html` 是标准 SPA 模式，与 prerender 产物兼容 |

## Open Questions (RESOLVED)

1. **pnpm 缓存挂载的构建上下文路径问题** -- RESOLVED
   - What we know: Dockerfile 的构建上下文是 `../../noda-apps`（docker-compose.app.yml），但 `deploy/nginx/` 配置文件在 noda-infra 仓库
   - What's unclear: `pipeline_build()` 使用 `docker build -f "$dockerfile" "$apps_dir"` 构建时，COPY 指令的源路径相对于 `$apps_dir`（noda-apps 目录），而不是 Dockerfile 所在目录
   - Recommendation: 方案一：nginx 配置文件 COPY 到 builder 阶段，再从 builder 阶段 COPY 到 runner 阶段。方案二：将 nginx 配置内联写入 Dockerfile（用 HEREDOC）。方案三：在 pipeline_build() 中将 nginx 配置文件复制到 noda-apps 目录。**推荐方案三**，最简单
   - **RESOLVED:** 采纳方案三 -- Plan 02 Task 2 在 Jenkinsfile Build 阶段 pipeline_build() 调用前将 nginx 配置文件复制到 noda-apps/deploy/nginx/，构建后清理

2. **manage-containers.sh 的 health-start-period 是 60s 硬编码** -- RESOLVED
   - What we know: run_container() line 236 硬编码 `--health-start-period 60s`，但 nginx 启动只需 < 1 秒
   - What's unclear: 是否有其他服务依赖 60s 的 start_period
   - Recommendation: 不修改 manage-containers.sh（影响所有服务），通过 EXTRA_DOCKER_ARGS 或在 Jenkinsfile 中单独处理
   - **RESOLVED:** 采纳推荐方案 -- 不修改 manage-containers.sh 通用脚本，60s start_period 对 nginx 无害（只是多等几秒），通过 Jenkinsfile CONTAINER_HEALTH_CMD 覆盖健康检查命令

## Environment Availability

> 本阶段依赖 Docker 构建和运行环境。

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker Engine | 镜像构建 + 容器运行 | -- | -- | -- |
| nginx:1.25-alpine 镜像 | runner 基础镜像 | -- | 1.25.5 | -- |
| Docker BuildKit | pnpm 缓存挂载 | -- | v0.30.1 | -- |
| Jenkins | Pipeline 执行 | -- | -- | -- |

**注:** 本地开发环境无法完整验证（noda-apps 源码不在本地），所有 Docker 测试在 nginx:1.25-alpine 基础镜像上完成。

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Docker + curl/wget 手动验证 |
| Config file | 无独立测试框架 |
| Quick run command | `docker build -t noda-site:test -f deploy/Dockerfile.noda-site ../noda-apps && docker run --rm -p 3000:3000 noda-site:test` |
| Full suite command | 蓝绿部署全流程手动验证 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SITE-01 | nginx:1.25-alpine 容器在端口 3000 提供 SPA 服务 | smoke | `curl -sf http://localhost:3000/` | -- Wave 0 |
| SITE-01 | 非 root 用户运行 | smoke | `docker exec noda-site-blue id` | -- Wave 0 |
| SITE-01 | read_only + tmpfs 正常工作 | smoke | `docker run --read-only --tmpfs /tmp noda-site:test` | -- Wave 0 |
| SITE-02 | builder 阶段 prerender 产出正确 | build | `docker build --target builder ...` | -- Wave 0 |
| SITE-03 | Pipeline 蓝绿部署全流程 | integration | Jenkins Build Now | -- Wave 0 |

### Sampling Rate
- **Per task commit:** `docker build + docker run --rm 健康检查`
- **Per wave merge:** 蓝绿部署手动验证
- **Phase gate:** Jenkins Pipeline 全流程 green

### Wave 0 Gaps
- [ ] 构建验证脚本（docker build + run + 健康检查 + 非 root 验证）
- [ ] 蓝绿部署端到端验证（需要服务器环境）

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | 静态站点无需认证 |
| V3 Session Management | no | 静态站点无会话 |
| V4 Access Control | yes | 非 root 运行 + read_only + cap_drop ALL |
| V5 Input Validation | no | 纯静态文件服务，无用户输入 |
| V6 Cryptography | no | TLS 由 Cloudflare 处理 |

### Known Threat Patterns for nginx Static File Serving

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 路径遍历 | Tampering | nginx `root` + `try_files` 限制在 /usr/share/nginx/html 内 |
| 信息泄露 | Information Disclosure | 非 root + read_only + 无 debug 输出 |
| DoS (慢速攻击) | Denial of Service | Cloudflare 前置防护 + nginx keepalive_timeout 65s |

## Sources

### Primary (HIGH confidence)
- nginx:1.25-alpine 镜像实测 -- 端口绑定、非 root 运行、wget/curl 可用性、目录权限
- scripts/manage-containers.sh -- run_container() 健康检查默认值分析 (line 204)
- config/nginx/conf.d/default.conf -- 外层 nginx 缓存策略分析 (line 130-145)
- deploy/Dockerfile.noda-site -- 当前 Dockerfile 结构分析
- docker/docker-compose.app.yml -- noda-site 服务配置分析
- jenkins/Jenkinsfile.noda-site -- Pipeline 参数分析

### Secondary (MEDIUM confidence)
- nginx 非 root 运行最佳实践 -- 基于 Docker 官方 nginx 镜像文档和社区实践
- pnpm BuildKit 缓存挂载 -- 基于 Docker BuildKit 官方文档

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- nginx:1.25-alpine 已通过实际 Docker 测试验证
- Architecture: HIGH -- 所有集成点已通过代码分析确认
- Pitfalls: HIGH -- BusyBox wget IPv6 问题和健康检查兼容性已实测验证

**Research date:** 2026-04-20
**Valid until:** 2026-05-20（nginx 配置模式稳定，30 天有效）
