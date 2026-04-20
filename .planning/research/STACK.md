# Stack Research: Docker 镜像瘦身优化 (v1.10)

**Domain:** Docker Compose 单服务器基础设施 — 镜像体积优化
**Researched:** 2026-04-20
**Confidence:** HIGH（基于代码实际分析 + Docker 官方最佳实践）

## 当前镜像体积现状

| 镜像 | 基础镜像 | 预估体积 | 主要膨胀源 |
|------|---------|---------|-----------|
| findclass-ssr | node:22-slim + Python3 + Chromium + patchright | ~2GB | Chromium (~400MB), Python 运行时 (~200MB), patchright 浏览器 (~350MB), node_modules |
| noda-site | node:20-alpine + serve | ~180MB | Node.js 运行时仅为静态文件服务 |
| noda-ops | alpine:3.21 + pg17-client + cloudflared + doppler | ~120MB | 合理，已是 Alpine 基础 |
| backup | postgres:17-alpine | ~80MB | 合理，官方镜像 |
| test-verify | postgres:15-alpine | ~80MB | 版本不统一（15 vs 17） |

**优化目标：** findclass-ssr 降至 ~300MB，noda-site 消除独立容器

## Recommended Stack

### 核心变更 1: findclass-ssr — 剥离 Python/Chromium（减重 ~1.5GB）

#### 关键发现

代码分析表明 `crawl-skykiwi.py` 虽然导入了 `StealthySession`，但实际运行路径使用 `Fetcher.get()`（HTTP 直连模式）。`create_stealthy_session()` 函数已定义但当前主流程不调用。这意味着 **Chromium、Python 运行时、patchright 浏览器在运行时完全不需要**。

#### 推荐方案: 移除 Python/Chromium，保留 Fetcher-only 路径

| 变更 | 说明 | 节省 |
|------|------|------|
| 基础镜像 node:22-slim → node:22-alpine | 从 Debian slim (~240MB) 降到 Alpine (~55MB) | ~185MB |
| 移除 Python3 + pip + venv | 不再安装 Python 运行时 | ~200MB |
| 移除 Chromium (apt install) | 不再需要系统 Chromium | ~400MB |
| 移除 patchright install chromium | 不再需要 Playwright 浏览器 | ~350MB |
| 移除 pip install scrapling 等 | Fetcher-only 模式无需这些包 | ~100MB |

#### 技术细节: Fetcher 不需要浏览器

`scrapling.fetchers.Fetcher` 底层使用 `httpx` 做 HTTP 请求，不启动任何浏览器进程。只有 `StealthyFetcher` / `StealthySession` 需要 Playwright + Chromium。当前代码已明确注释 "使用 Fetcher 直连（skykiwi 不需要 StealthySession 浏览器模式）"。

**注意事项:**
- 如果未来需要 `StealthySession`（如遇到反爬机制），应将爬虫拆为独立容器，而非放回 findclass-ssr
- 移除 Python 后，`scripts/` 目录中的 `.py` 文件将无法在容器内运行，需确认是否有其他入口调用
- `llm_extract.py`、`llm_filter.py`、`db_import.py` 等脚本需要确认是否有 API 端点调用

#### Alpine 兼容性验证

findclass-ssr 的 Node.js 依赖需验证 Alpine (musl libc) 兼容性。主要关注点：
- **Prisma/Drizzle ORM**: 纯 JS 实现，Alpine 兼容（MEDIUM confidence — 需构建验证）
- **better-sqlite3 等 native 模块**: 如使用需 Alpine build-tools（需确认）
- **Vite 构建产物**: 纯 JS，Alpine 完全兼容

**兼容性策略:** 构建阶段 (Stage 1) 保持 `node:22-alpine`，运行阶段 (Stage 2) 改为 `node:22-alpine`。若遇到 native 模块问题，备选方案为 `node:22-slim`（仍可省去 Python/Chromium）。

### 核心变更 2: noda-site — 消除独立容器（减重 ~180MB + 64MB 内存）

#### 推荐方案: 由现有 Nginx 直接服务静态文件，移除 noda-site 容器

| 方案 | 说明 | 效果 |
|------|------|------|
| **推荐: Nginx 直接服务** | 构建产物通过 volume 挂载到 nginx 容器，由 nginx 直接服务静态文件 | 消除整个容器 + 64MB 内存 |
| 备选: nginx:alpine 替代 serve | Dockerfile 多阶段构建，运行阶段改为 nginx:alpine | ~25MB 镜像（vs 180MB） |

**为什么推荐消除容器而非优化镜像:**

1. **项目已有 Nginx 容器**: `noda-infra-nginx` 已在 Docker Compose 中运行，noda.co.nz 的请求当前是 `nginx → noda-site:3000` 的代理转发
2. **纯静态文件**: noda-site 只服务预渲染 HTML + JS/CSS/图片，无服务端逻辑
3. **prerender 在构建时完成**: Puppeteer/Chromium 只在构建阶段使用，运行时完全不需要
4. **资源节约**: 单服务器架构，每个容器都有 64MB 内存开销

#### 实施方案

```
构建产物 (noda-apps/apps/site/dist/)
  → Docker volume 或 bind mount
  → nginx 容器内 /usr/share/nginx/noda-site/
  → nginx server block 直接 root 指令服务
```

**Nginx 配置变更:**
```nginx
# 当前（代理到 noda-site 容器）
proxy_pass http://noda_site_backend;

# 优化后（直接服务静态文件）
root /usr/share/nginx/noda-site;
try_files $uri $uri/ /index.html;
```

**构建流程变更:**
- Jenkins Pipeline 增加 noda-site 构建步骤
- 构建产物复制到 nginx volume
- 移除 `docker-compose.app.yml` 中的 `noda-site` 服务定义
- 移除 `upstream-noda-site.conf`

### 核心变更 3: test-verify — 统一 PostgreSQL 版本（节省磁盘缓存）

| 变更 | 说明 |
|------|------|
| postgres:15-alpine → postgres:17-alpine | 与 backup 镜像统一基础镜像版本 |

Docker 镜像层共享机制：相同基础镜像只存储一份。统一为 postgres:17-alpine 后两个镜像共享底层，减少磁盘占用。

### 核心变更 4: noda-ops — 微调（已较优）

noda-ops 镜像已经是 Alpine 基础且依赖合理，仅做以下审查：

| 包 | 是否必需 | 说明 |
|----|---------|------|
| bash | 必需 | 脚本使用 bash |
| curl | 可选 | wget 可替代，但两者都有实际使用 |
| wget | 必需 | 下载 cloudflared 二进制 |
| jq | 必需 | 备份脚本 JSON 解析 |
| coreutils | 必需 | date、sha256sum 等命令 |
| rclone | 必需 | B2 云存储上传 |
| dcron | 必需 | 定时任务调度 |
| supervisor | 必需 | 多进程管理 |
| ca-certificates | 必需 | HTTPS 证书 |
| postgresql17-client | 必需 | pg_dump 备份 |
| gnupg | 必需 | 加密操作 |
| age | 必需 | 密钥备份加密 |
| doppler | 必需 | 密钥管理 CLI |

**结论:** noda-ops 依赖全部必需，不做移除。可考虑的优化是将 `wget` 和 `curl` 合并为只保留一个（建议保留 `curl`，功能更通用），但这属于微优化（节省 <1MB）。

## 多阶段构建最佳实践（适用所有镜像）

### 模式: 分离构建依赖与运行时

```dockerfile
# Stage 1: 构建（使用完整镜像）
FROM node:22-alpine AS builder
# 安装所有构建工具
# 编译 TypeScript
# 打包前端

# Stage 2: 运行时（最小镜像）
FROM node:22-alpine AS runner
# 仅复制构建产物
# 不复制 node_modules 源码
# 不复制构建工具
```

### Dockerfile 优化清单

| 优化项 | 说明 | 适用镜像 |
|--------|------|---------|
| `--no-install-recommends` | 跳过推荐的 apt 包（Debian 基础镜像） | findclass-ssr（如保留 slim） |
| `rm -rf /var/lib/apt/lists/*` | 清理 apt 缓存 | findclass-ssr（如保留 slim） |
| `rm -rf /var/cache/apk/*` | 清理 apk 缓存 | 所有 Alpine 镜像 |
| `.dockerignore` | 排除 .git、node_modules、.env | 所有镜像 |
| `--mount=type=cache` | BuildKit 缓存加速 npm install | 所有 Node.js 镜像 |
| `npm ci --production` | 只安装生产依赖 | noda-site（如保留容器） |
| COPY 分层 | 先复制 package.json + lock，再复制源码 | 所有镜像 |

### findclass-ssr 特定优化

当前 Dockerfile 的问题：运行阶段复制了完整的 `node_modules`（包含开发依赖）。优化方案：

```dockerfile
# Stage 2: 运行时
FROM node:22-alpine AS runner
# 方案 A: 使用 npm prune 删除 devDependencies
COPY --from=builder /app/node_modules ./node_modules
# 然后在 builder 阶段最后一步执行 npm prune --production

# 方案 B: 使用 node:22-alpine + npm install --production（更可控）
# 在 builder 阶段单独安装生产依赖
```

**推荐方案 B**: 在 builder 阶段做两次 install — 一次完整（用于构建），一次 `--production`（用于运行时复制）。

## Supporting Libraries

| 库/工具 | 版本 | 用途 | 使用场景 |
|---------|------|------|---------|
| nginx:1.25-alpine | 1.25 | 静态文件服务 + 反向代理 | 替代 noda-site 容器服务静态文件 |
| node:22-alpine | 22.x | findclass-ssr 运行时基础镜像 | 替代 node:22-slim |
| postgres:17-alpine | 17.9 | 统一数据库镜像版本 | test-verify 版本统一 |
| BuildKit | 内置 | Docker 构建缓存和高级特性 | `--mount=type=cache` 加速构建 |

## Alternatives Considered

| 推荐 | 备选 | 不选备选的原因 |
|------|------|--------------|
| Nginx 直接服务 noda-site 静态文件 | nginx:alpine 替代 serve（保留容器） | 已有 nginx 容器，加一个只服务静态文件的容器是浪费 |
| node:22-alpine | node:22-slim | Alpine 小 185MB；无 native 模块依赖时 Alpine 完全够用 |
| node:22-alpine | gcr.io/distroless/nodejs22 | distroless 无 shell，健康检查用 wget 需额外处理；项目已有 Alpine 经验，收益不显著 |
| 移除 Python 运行时 | Python 独立容器（微服务分离） | 当前爬虫脚本实际不需要浏览器，Fetcher 是纯 HTTP，放容器外运行或独立定时任务即可 |
| 移除 Python 运行时 | 保留 Python 但用 venv + 精简 | 仍然包含 ~600MB 的 Chromium + patchright，不符合瘦身目标 |
| 统一 postgres:17-alpine | 保持 postgres:15-alpine | 版本不统一导致 Docker 无法共享基础层，浪费磁盘 |

## What NOT to Use

| 避免 | 原因 | 替代方案 |
|------|------|---------|
| serve (npm) 作为静态文件服务器 | 引入完整 Node.js 运行时仅服务静态文件，~180MB vs nginx:alpine ~25MB | nginx 直接服务 |
| Caddy 替代 nginx | 项目已有完善的 nginx 配置体系（upstream、蓝绿切换、proxy snippets），迁移成本远大于收益 | 继续使用 nginx |
| darkhttpd | 功能过于简陋（无 gzip、无缓存控制），不适合生产环境 | nginx |
| static-web-server (sws) | 需要引入新组件学习，且当前架构 nginx 完全胜任 | nginx |
| distroless 基础镜像 | 无 shell 导致健康检查、调试困难；项目需要 wget/curl 健康检查 | node:22-alpine |
| Chromium + patchright 在 findclass-ssr 中 | 代码分析表明当前只用 Fetcher（HTTP），不需要浏览器；如需浏览器应独立容器 | 移除，或独立爬虫容器 |
| 多个 Python 爬虫脚本打进 findclass-ssr | SSR 服务和爬虫职责不同，生命周期不同（爬虫是定时任务，SSR 是常驻服务） | 分离架构 |

## Stack Patterns by Variant

**如果 findclass-ssr 确有 native 模块依赖（如 better-sqlite3）:**
- 使用 `node:22-slim` 而非 `node:22-alpine`
- 仍然移除 Python/Chromium（节省 ~1GB）
- 预期体积从 ~2GB 降至 ~400MB

**如果未来需要 StealthySession 爬虫:**
- 创建独立的 `noda-crawler` 容器
- 基础镜像 `python:3.12-slim`
- 安装 scrapling[fetchers] + patchright + Chromium
- 通过 API 或消息队列与 findclass-ssr 通信
- 生命周期独立（按需启动或定时运行）

**如果 noda-site 需要 SSR（非纯静态）:**
- 保留 Node.js 容器
- 但改用 `node:22-alpine` 替代 `node:20-alpine`（与 findclass-ssr 统一 Node 版本）
- 移除 serve，使用 Node.js 内置 HTTP 或轻量框架

## Version Compatibility

| 组件 | 当前版本 | 目标版本 | 兼容性说明 |
|------|---------|---------|-----------|
| findclass-ssr 基础镜像 | node:22-slim | node:22-alpine | Node.js 版本不变，仅切换 OS。需验证 native 模块 |
| noda-site 基础镜像 | node:20-alpine | 消除容器 | N/A |
| test-verify 基础镜像 | postgres:15-alpine | postgres:17-alpine | PostgreSQL 客户端向后兼容，pg_dump 17 可备份 15 数据库 |
| nginx | nginx:1.25-alpine | 不变 | 仅修改配置添加静态文件服务 |
| patchright | 运行时安装 | 移除 | Fetcher 不依赖 patchright |

## Installation

无需安装新包。优化通过 Dockerfile 修改和架构调整实现。

```bash
# 验证 Alpine 兼容性（在本地测试）
docker build --no-cache -f deploy/Dockerfile.findclass-ssr -t findclass-ssr:test-alpine ../../noda-apps

# 验证镜像体积
docker images findclass-ssr:test-alpine --format "{{.Repository}}:{{.Tag}} {{.Size}}"

# 分析镜像层（需要 dive 工具）
dive findclass-ssr:test-alpine
```

## 预期优化效果

| 镜像 | 当前 | 优化后 | 节省 |
|------|------|--------|------|
| findclass-ssr | ~2GB | ~300-400MB | ~1.6GB |
| noda-site | ~180MB | 0（消除） | ~180MB + 64MB 内存 |
| test-verify | ~80MB | ~80MB（版本统一后共享层） | 磁盘缓存复用 |
| noda-ops | ~120MB | ~120MB | 不变（已优化） |
| backup | ~80MB | ~80MB | 不变 |
| **总计** | **~2.46GB** | **~0.5-0.6GB** | **~75% 减少** |

## Sources

- 项目代码: `deploy/Dockerfile.findclass-ssr` — Python/Chromium 依赖分析（HIGH confidence）
- 项目代码: `noda-apps/scripts/crawl-skykiwi.py` — Fetcher vs StealthySession 使用分析（HIGH confidence）
- 项目代码: `deploy/Dockerfile.noda-site` — serve 静态文件服务分析（HIGH confidence）
- 项目代码: `config/nginx/conf.d/default.conf` — nginx 已有 noda-site 代理配置（HIGH confidence）
- 项目代码: `deploy/Dockerfile.noda-ops` — 依赖审查（HIGH confidence）
- Docker Hub: node:22-alpine 镜像体积约 55MB（MEDIUM confidence — 基于训练数据，未实时验证）
- Docker Hub: node:22-slim 镜像体积约 240MB（MEDIUM confidence）
- Docker 官方文档: 多阶段构建最佳实践（HIGH confidence）
- Scrapling GitHub: Fetcher 使用 httpx，StealthyFetcher 使用 Playwright（MEDIUM confidence — 基于 WebSearch + 训练数据）

---
*Stack research for: Docker 镜像瘦身优化 (v1.10)*
*Researched: 2026-04-20*
