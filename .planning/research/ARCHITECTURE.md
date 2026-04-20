# Architecture Research: Docker 镜像瘦身优化

**Domain:** Docker Compose 基础设施镜像体积优化
**Researched:** 2026-04-20
**Confidence:** HIGH（基于完整代码库审计 + Dockerfile 逐行分析）

---

## 一、现状镜像分析

### 1.1 当前镜像清单与体积估算

| 镜像 | 基础镜像 | 预估体积 | 主要膨胀源 |
|------|---------|---------|-----------|
| findclass-ssr | `node:22-slim` | ~800MB-1.2GB | Chromium + Python + patchright 浏览器 + node_modules |
| noda-site | `node:20-alpine` + `serve` | ~120-150MB | Node.js 运行时 + npm serve（仅服务静态文件） |
| noda-ops | `alpine:3.21` | ~80-120MB | 合理，但 wget/gnupg 可能多余 |
| backup (废弃) | `postgres:17-alpine` | ~300MB | 已被 noda-ops 替代，可删除 |
| test-verify | `postgres:15-alpine` | ~300MB | 版本不统一（PG15 vs PG17） |

### 1.2 findclass-ssr 是最大优化目标

findclass-ssr Dockerfile（`deploy/Dockerfile.findclass-ssr`）包含四个运行时：

1. **Node.js 22** — API 服务器 + SSR 渲染（核心功能）
2. **Python 3** — 爬虫脚本（`scrapling` 库）
3. **Chromium** — `apt-get install chromium`（系统包）
4. **patchright 浏览器** — `python3 -m patchright install chromium`（独立下载）

**体积分析：**
- Chromium 系统包：~300-400MB
- patchright 独立下载的 Chromium：~300-400MB（`PLAYWRIGHT_BROWSERS_PATH=0` 对 patchright 无效，代码注释已承认）
- Python 运行时 + pip 包：~100-150MB
- Node.js 运行时 + node_modules：~200-300MB
- 应用代码本身：~20-50MB

**结论：findclass-ssr 镜像中约 60-70% 的体积来自 Python/Chromium 爬虫运行时，而这些代码在每次 HTTP 请求中都不需要。**

### 1.3 noda-site 用 Node.js serve 静态文件是浪费

noda-site Dockerfile（`deploy/Dockerfile.noda-site`）使用 `node:20-alpine` + `npm install -g serve` 来服务纯静态文件。整个 Node.js 运行时（约 50MB）+ npm + serve 包只是为了替代一个简单的 HTTP 文件服务器。

---

## 二、推荐架构

### 2.1 系统概览

```
优化前:
┌─────────────────────────────────────┐
│  findclass-ssr (node:22-slim)       │
│  ┌─────────┐ ┌─────────┐ ┌────────┐│
│  │ Node.js │ │ Python  │ │Chromium││
│  │ API+SSR │ │Crawler  │ │x2      ││
│  │ +Static │ │+scrapling││(sys+pw)││
│  └─────────┘ └─────────┘ └────────┘│
│  体积: ~800MB-1.2GB                 │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│  noda-site (node:20-alpine)         │
│  ┌─────────┐ ┌─────────┐           │
│  │ Node.js │ │  serve  │           │
│  │ runtime │ │  npm包  │           │
│  └─────────┘ └─────────┘           │
│  体积: ~120-150MB                   │
└─────────────────────────────────────┘

优化后:
┌──────────────────────────┐  ┌─────────────────────────────┐
│ findclass-ssr             │  │ findclass-crawler (新增)     │
│ (node:22-alpine)          │  │ (python:3.12-slim)          │
│ ┌─────────┐ ┌──────────┐ │  │ ┌─────────┐ ┌────────────┐ │
│ │ Node.js │ │ 静态文件 │ │  │ │ Python  │ │Chromium    │ │
│ │ API+SSR │ │ 内嵌服务 │ │  │ │scrapling│ │(仅 1 份)   │ │
│ └─────────┘ └──────────┘ │  │ └─────────┘ └────────────┘ │
│ 体积: ~250-350MB          │  │ 体积: ~400-500MB            │
│ -60~70%                   │  │ (独立扩展/调度)              │
└──────────────────────────┘  └─────────────────────────────┘

┌──────────────────────────┐
│ noda-site (nginx:alpine) │
│ ┌─────────┐              │
│ │  Nginx  │              │
│ │ 内嵌服务│              │
│ └─────────┘              │
│ 体积: ~25-30MB           │
│ -80%                     │
└──────────────────────────┘
```

### 2.2 组件职责划分

| 组件 | 职责 | 镜像基础 | 体积变化 |
|------|------|---------|---------|
| **findclass-ssr** | API 服务器 + SSR 渲染 + 静态文件 | `node:22-alpine` | -60~70%（移除 Python/Chromium） |
| **findclass-crawler**（新增） | Python 爬虫执行 | `python:3.12-slim` | 新镜像 ~400-500MB |
| **noda-site** | 静态 Landing Page | `nginx:1.25-alpine` | -80%（移除 Node.js） |
| **noda-ops** | 备份 + Cloudflare Tunnel | `alpine:3.21`（不变） | 小幅精简 |
| **test-verify** | 备份验证测试 | `postgres:17-alpine`（统一版本） | 版本统一 |

---

## 三、findclass-ssr 拆分策略（核心优化）

### 3.1 Python 爬虫分离方案

**发现：** crawl-skykiwi.py 的主流程使用 `Fetcher.get()`（轻量 HTTP 请求，不需要浏览器），`StealthySession`（需要 Chromium）仅在直连失败或需要绕过 Cloudflare 时使用。

**推荐方案：独立爬虫容器 + HTTP API 通信**

```
Node.js API (findclass-ssr)
    │
    ├─ 定时触发 → HTTP POST → findclass-crawler:8080/crawl
    │                              │
    │                              ├─ Fetcher.get() (默认，轻量)
    │                              └─ StealthySession (回退，需 Chromium)
    │
    └─ 手动触发 → POST /api/crawl/trigger → HTTP 转发 → crawler
```

**为什么选 HTTP API 而不是消息队列或共享卷：**
- 单服务器架构，消息队列（Redis/RabbitMQ）是过度工程化
- HTTP 直接调用，延迟最低，调试最简单
- 与现有 `crawl-scheduler.ts` 的 `spawn('python3', ...)` 改动最小——只需把 spawn 改为 HTTP 调用
- 爬虫容器可以独立重启、扩缩、调试

**crawl-scheduler.ts 改造：**

```typescript
// 改造前: spawn('python3', ['crawl-skykiwi.py', '--board', 'tutoring'])
// 改造后: HTTP 调用爬虫容器

private async executeCrawlViaHttp(): Promise<CrawlResult> {
  const response = await fetch('http://findclass-crawler:8080/crawl', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ board: 'tutoring' }),
    signal: AbortSignal.timeout(CrawlScheduler.SPAWN_TIMEOUT),
  });
  // ...处理响应
}
```

### 3.2 爬虫容器设计

**推荐使用 `python:3.12-slim` 而非 `alpine`：**

| 方案 | 体积 | 兼容性 |
|------|------|--------|
| `python:3.12-slim` (Debian) | ~150MB 基础 | scrapling/patchright 依赖 manylinux wheels，Debian 原生兼容 |
| `python:3.12-alpine` | ~50MB 基础 | scrapling 依赖需要编译，Alpine 经常缺 C 库导致 pip install 失败 |

**爬虫 Dockerfile 草案：**

```dockerfile
# Stage 1: 依赖安装
FROM python:3.12-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN python3 -m patchright install chromium

# Stage 2: 运行时
FROM python:3.12-slim AS runner

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium && \
    rm -rf /var/lib/apt/lists/*

# 复制 Python 包
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# 复制 patchright 浏览器
COPY --from=builder /root/.cache/ms-playwright /root/.cache/ms-playwright

ENV PLAYWRIGHT_BROWSERS_PATH=0
ENV CHROMIUM_PATH=/usr/bin/chromium

WORKDIR /app
COPY scripts/ .

EXPOSE 8080
CMD ["python3", "-m", "http.server", "8080"]  # 或 FastAPI
```

**关键优化：** 使用多阶段构建，pip install 在 builder 阶段完成，runner 阶段只复制 site-packages，不包含 pip 缓存和编译工具。

### 3.3 爬虫容器技术选型

| 方案 | 优点 | 缺点 | 推荐 |
|------|------|------|------|
| **Flask/FastAPI 封装** | 标准化 API 接口，健康检查方便 | 需要额外依赖 | 推荐 FastAPI |
| **原始 Python HTTP** | 零额外依赖 | 无路由/错误处理/健康检查 | 不推荐 |
| **保留 spawn 模式** | 改动最小 | 必须共享文件系统，无法独立调度 | 不推荐 |

**推荐 FastAPI** 因为：轻量（fastapi + uvicorn < 10MB），提供自动健康检查端点，与 Node.js HTTP 调用天然兼容。

### 3.4 对 Jenkins Pipeline 的影响

| 变更点 | 影响范围 | 改动量 |
|--------|---------|--------|
| findclass-ssr Pipeline | 移除 Python/Chromium 构建步骤 | 小 |
| 新增 crawler Pipeline | 新 Jenkinsfile，蓝绿或直接部署 | 中 |
| docker-compose.app.yml | 新增 findclass-crawler 服务定义 | 中 |
| upstream-findclass.conf | 无变更（爬虫不走 nginx） | 无 |
| crawl-scheduler.ts | spawn 改为 HTTP fetch | 小 |

**注意：** 爬虫容器不需要蓝绿部署。爬虫是后台定时任务，没有在线用户，停机几秒重启不影响体验。直接 `docker compose up -d` 即可。

---

## 四、noda-site 优化方案

### 4.1 推荐方案：Nginx 直接服务静态文件

**为什么选 Nginx 而不是 Caddy 或其他：**
- 项目已经在使用 `nginx:1.25-alpine` 作为反向代理，运维团队熟悉
- 不引入新技术栈，维护成本为零
- `nginx:1.25-alpine` 镜像约 25-30MB vs `node:20-alpine` + serve 约 120-150MB
- Nginx 的静态文件服务性能远优于 Node.js serve

**优化后 Dockerfile：**

```dockerfile
# Stage 1: 构建
FROM node:20-alpine AS builder

WORKDIR /app
COPY . .
RUN corepack enable && corepack prepare pnpm@latest --activate
RUN pnpm install --frozen-lockfile --ignore-scripts --filter @noda-apps/site...

RUN apk add --no-cache chromium
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

RUN cd packages/design-tokens && pnpm run build
RUN cd apps/site && pnpm run build

# Stage 2: 运行时（Nginx 替代 Node.js serve）
FROM nginx:1.25-alpine AS runner

# 移除默认配置
RUN rm /etc/nginx/conf.d/default.conf

# 复制自定义 nginx 配置（仅静态文件服务）
COPY --from=builder /app/apps/site/dist /usr/share/nginx/html

# 超轻量 nginx 配置
COPY deploy/nginx-site.conf /etc/nginx/conf.d/default.conf

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=10s \
  CMD wget --quiet --tries=1 --spider http://localhost:3000/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
```

**配合的 nginx-site.conf：**

```nginx
server {
    listen 3000;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # SPA 路由回退
    location / {
        try_files $uri $uri/ /index.html;
    }

    # 静态资源长缓存（Vite 带 hash）
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # gzip 压缩
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/javascript image/svg+xml;
}
```

### 4.2 对现有架构的影响

| 变更点 | 影响 |
|--------|------|
| docker-compose.app.yml | `noda-site` 服务定义改为 `build` 指向新 Dockerfile |
| upstream-noda-site.conf | 无变更，仍然代理到 `noda-site:3000` |
| nginx 外层代理 | 无变更，`noda_site_backend` upstream 不变 |
| 蓝绿部署 | 无影响，端口 3000 不变 |

---

## 五、noda-ops 精简方案

### 5.1 当前依赖审计

noda-ops Dockerfile 安装了以下 Alpine 包：

| 包 | 是否必要 | 原因 |
|----|---------|------|
| bash | 是 | 备份脚本使用 bash 语法 |
| curl | 是 | Doppler 安装、健康检查 |
| wget | **否** | 仅在 Dockerfile 中下载 cloudflared 和 Doppler，运行时不使用 |
| jq | 是 | backup-postgres.sh 中 JSON 解析 |
| coreutils | 是 | stat/date 等命令的 GNU 版本 |
| rclone | 是 | B2 备份上传 |
| dcron | 是 | 定时任务执行 |
| supervisor | 是 | 进程管理 |
| ca-certificates | 是 | HTTPS 证书链 |
| postgresql17-client | 是 | pg_dump/pg_restore |
| gnupg | **可优化** | 仅 Doppler apk 仓库验证用 |
| age | 是 | Doppler 密钥备份加密 |
| doppler | 是 | 密钥备份 |

### 5.2 推荐优化

```dockerfile
FROM alpine:3.21

# 构建阶段：下载二进制文件
RUN apk add --no-cache wget gnupg && \
    # 安装 cloudflared
    ARCH=$(uname -m) && \
    ... cloudflared 下载 ... && \
    # 安装 Doppler
    ... Doppler 安装 ... && \
    # 清理构建工具
    apk del wget gnupg

# 运行时依赖（不含 wget/gnupg）
RUN apk add --no-cache \
    bash curl jq coreutils rclone \
    dcron supervisor ca-certificates \
    postgresql17-client age
```

**预估节省：** wget (~2MB) + gnupg (~15MB) = ~17MB。体积节省有限，但减少了攻击面。

---

## 六、test-verify 镜像版本统一

### 6.1 当前问题

| 镜像 | PostgreSQL 版本 | 用途 |
|------|----------------|------|
| noda-ops (backup) | `postgresql17-client` | 备份/恢复 |
| test-verify | `postgres:15-alpine` | 备份验证测试 |

**不一致：** 生产用 PG17，验证测试用 PG15。`pg_restore` 版本不匹配可能导致验证结果不可靠。

### 6.2 推荐

将 `Dockerfile.test-verify` 从 `postgres:15-alpine` 改为 `postgres:17-alpine`，与生产环境保持一致。

---

## 七、多镜像共享层优化

### 7.1 共享基础镜像策略

| 镜像 | 当前基础 | 推荐基础 | 共享层 |
|------|---------|---------|--------|
| findclass-ssr | `node:22-slim` (Debian) | `node:22-alpine` | 与 noda-site builder 共享 alpine 层 |
| noda-site builder | `node:20-alpine` | `node:22-alpine` | 统一 Node 版本，共享 alpine 层 |
| noda-site runner | `node:20-alpine` | `nginx:1.25-alpine` | 与主 nginx 共享 alpine 层 |
| noda-ops | `alpine:3.21` | 不变 | — |
| findclass-crawler | 新增 | `python:3.12-slim` | 独立（Debian，manylinux 兼容） |

**关键点：** 将所有能统一到 Alpine 的镜像统一到 `alpine:3.21`，Docker 层缓存可在镜像间共享。

### 7.2 findclass-ssr 从 node:22-slim 改为 node:22-alpine 的可行性

| 方面 | slim (Debian) | alpine | 评估 |
|------|-------------|--------|------|
| Node.js 运行时 | 原生 glibc | musl libc | Node.js 官方 Alpine 镜像已处理兼容性 |
| npm 原生模块 | manylinux 兼容 | 需要编译 | 项目主要用 JS/TS，无原生模块 |
| SSR 渲染 | 正常 | 正常 | Vite 构建产物是纯 JS |
| 体积 | ~200MB | ~50MB | 节省 ~150MB |

**结论：findclass-ssr 可以安全切换到 `node:22-alpine`，因为 Python/Chromium 移除后不再需要 Debian 的 manylinux 兼容性。**

---

## 八、数据流变更

### 8.1 爬虫调用链路变更

```
优化前:
Node.js crawl-scheduler
    → spawn('python3', ['crawl-skykiwi.py', ...])
    → 同容器内 Python 进程
    → stdout JSON 回 Node.js
    → 解析 → 写入数据库

优化后:
Node.js crawl-scheduler
    → HTTP POST http://findclass-crawler:8080/crawl
    → 爬虫容器 FastAPI 接收
    → 执行 Python 爬虫
    → HTTP JSON 响应回 Node.js
    → 解析 → 写入数据库
```

**关键差异：** spawn 的 stdout 捕获变为 HTTP 响应体。爬虫脚本的输出格式（JSON 数组到 stdout）保持不变，FastAPI 只是包装层。

### 8.2 静态文件服务链路（不变）

```
noda.co.nz → Cloudflare → nginx (main) → noda_site_backend → noda-site:3000
class.noda.co.nz → Cloudflare → nginx (main) → findclass_backend → findclass-ssr:3001
```

---

## 九、架构模式

### 模式 1: 职责分离容器（单一职责）

**原则：** 每个容器只做一件事，不同运行时不要混在同一个镜像中。

**当前违反：** findclass-ssr 混合了 Node.js + Python + Chromium 三个运行时。

**修复：** 将 Python 爬虫拆分为独立容器，Node.js 容器只负责 API + SSR。

### 模式 2: 构建时 vs 运行时严格分离

**原则：** 多阶段构建中，builder 阶段的所有工具链都不应该出现在 runner 阶段。

**当前违反：** noda-ops 的 wget/gnupg 在运行时镜像中仍然存在。

**修复：** 在 Dockerfile 中使用 `apk add` + `apk del` 模式，或将二进制下载移到独立 builder 阶段。

### 模式 3: 基础镜像统一

**原则：** 同类服务使用相同的基础镜像版本，最大化 Docker 层缓存共享。

**当前违反：** noda-site builder 用 node:20，findclass-ssr builder 用 node:22；test-verify 用 PG15，noda-ops 用 PG17。

**修复：** 统一到 alpine:3.21 + node:22-alpine + postgres:17-alpine。

---

## 十、反模式

### 反模式 1: "一切合一"镜像

**错误做法：** 在同一个镜像中安装多个运行时（Node.js + Python + 浏览器）。
**问题：** 镜像体积爆炸，构建缓慢，安全补丁面大，无法独立扩展。
**正确做法：** 每个运行时独立镜像，通过 HTTP API 或消息队列通信。

### 反模式 2: 用 Node.js 服务纯静态文件

**错误做法：** `npm install -g serve` 来服务预构建的 HTML/CSS/JS。
**问题：** Node.js 运行时约 50MB + serve 包，而 nginx 只需 7MB。
**正确做法：** 使用 nginx:alpine 直接服务静态文件，性能更好、体积更小。

### 反模式 3: 在运行时镜像中保留构建工具

**错误做法：** 在最终运行阶段保留 wget、gnupg、gcc 等构建时工具。
**问题：** 增加攻击面和镜像体积。
**正确做法：** 多阶段构建，builder 阶段安装工具，runner 阶段只复制产物。

---

## 十一、扩展性考虑

| 规模 | 架构调整 |
|------|---------|
| 当前（单服务器，低流量） | 拆分容器即可，不需要额外优化 |
| 中等流量 | 爬虫容器可独立扩缩，不影响 API 服务 |
| 高流量 | 爬虫容器可迁移到独立服务器，API 容器水平扩展 |

**扩展优先级：**
1. **第一瓶颈：** 爬虫执行阻塞 API 容器资源 — 拆分后独立调度，问题自然解决
2. **第二瓶颈：** noda-site 的 Node.js serve 内存开销 — 切换到 nginx 后内存从 ~30MB 降到 ~3MB

---

## 十二、集成点分析

### 12.1 变更的文件清单

| 文件 | 变更类型 | 变更内容 |
|------|---------|---------|
| `deploy/Dockerfile.findclass-ssr` | 修改 | 移除 Python/Chromium/patchright，基础镜像改为 alpine |
| `deploy/Dockerfile.noda-site` | 重写 | Node.js serve 改为 nginx 静态服务 |
| `deploy/Dockerfile.noda-ops` | 修改 | wget/gnupg 移到构建阶段 |
| `scripts/backup/docker/Dockerfile.test-verify` | 修改 | PG15 → PG17 |
| `docker/docker-compose.app.yml` | 修改 | 新增 findclass-crawler 服务 |
| `config/nginx/snippets/upstream-findclass.conf` | 无变更 | — |
| `config/nginx/snippets/upstream-noda-site.conf` | 无变更 | — |
| `deploy/Dockerfile.findclass-crawler` | **新增** | Python 爬虫容器 |
| `deploy/nginx-site.conf` | **新增** | noda-site 内嵌 nginx 配置 |
| noda-apps: `crawl-scheduler.ts` | 修改 | spawn → HTTP fetch |
| noda-apps: 新增 FastAPI 封装 | **新增** | 爬虫 API 服务 |

### 12.2 向后兼容性

| 方面 | 兼容策略 |
|------|---------|
| API 接口 | `/api/crawl/trigger` 等接口不变，内部实现从 spawn 改为 HTTP |
| Nginx 路由 | 所有 upstream 配置不变 |
| 蓝绿部署 | findclass-ssr 蓝绿不受影响，crawler 不需要蓝绿 |
| Jenkins Pipeline | findclass-ssr Pipeline 需调整构建步骤；crawler 需新建 Pipeline |
| 环境变量 | 无新增环境变量需求 |

### 12.3 构建顺序

```
Phase 1: noda-site 优化（独立，无依赖）
  → Dockerfile 重写 + nginx 配置 + compose 更新 + 测试

Phase 2: noda-ops 精简（独立，无依赖）
  → Dockerfile 优化 + 测试

Phase 3: test-verify 版本统一（独立，无依赖）
  → Dockerfile 版本更新 + 测试

Phase 4: findclass-crawler 容器创建（前置：需 noda-apps 仓库配合）
  → 新 Dockerfile + FastAPI 封装 + compose 定义 + 测试

Phase 5: findclass-ssr 瘦身（依赖 Phase 4 完成后）
  → 移除 Python/Chromium + 基础镜像切换 + crawl-scheduler.ts 改造 + 测试
```

**关键依赖：** Phase 5 依赖 Phase 4，因为爬虫必须先有独立容器运行，才能从 findclass-ssr 中移除。其余 Phase 互相独立。

---

## 十三、Sources

- 项目代码: `deploy/Dockerfile.findclass-ssr` — 逐行分析 Python/Chromium 依赖 [HIGH confidence]
- 项目代码: `deploy/Dockerfile.noda-site` — Node.js serve 静态文件分析 [HIGH confidence]
- 项目代码: `deploy/Dockerfile.noda-ops` — Alpine 包依赖审计 [HIGH confidence]
- 项目代码: `scripts/backup/docker/Dockerfile.test-verify` — PG15 版本不匹配 [HIGH confidence]
- noda-apps: `scripts/crawl-skykiwi.py` — 爬虫 Fetcher vs StealthySession 使用分析 [HIGH confidence]
- noda-apps: `scripts/requirements.txt` — Python 依赖分析 [HIGH confidence]
- noda-apps: `apps/findclass/api/src/scripts/crawl-scheduler.ts` — spawn 调用链路 [HIGH confidence]
- Docker Hub: `node:22-alpine` vs `node:22-slim` 镜像体积对比 [HIGH confidence]
- Docker Hub: `nginx:1.25-alpine` 镜像体积 (~25MB) [HIGH confidence]
- Docker 多阶段构建最佳实践 [MEDIUM confidence — 基于训练数据，WebSearch 不可用]

---
*Architecture research for: Docker 镜像瘦身优化*
*Researched: 2026-04-20*
