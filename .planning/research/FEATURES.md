# Docker 镜像瘦身优化 -- Feature 研究

**Domain:** Docker 镜像体积优化
**Researched:** 2026-04-20
**Confidence:** HIGH（基于镜像实际大小分析、Dockerfile 代码审查、static-web-server GitHub 验证）

## 当前镜像现状

| 镜像 | 当前大小 | 基础镜像 | 主要体积来源 |
|------|----------|----------|-------------|
| findclass-ssr | **5.02 GB** | node:22-slim | Python 3 + pip + Chromium + patchright 浏览器（约 3GB） |
| noda-site | **218 MB** | node:20-alpine + npm serve | Node.js 运行时（~180MB）仅用于 serve 静态文件 |
| noda-ops | **336 MB** | alpine:3.21 | cloudflared 二进制 + postgresql17-client + doppler |
| backup | 未构建 | postgres:17-alpine | postgres 客户端工具 + rclone + dcron |
| test-verify | 未构建 | postgres:**15**-alpine | postgres 客户端工具 + rclone（版本与 backup 不一致） |

**总潜在优化空间：约 4.5 GB**（findclass-ssr 占 80% 以上）

---

## Table Stakes（必须做的优化）

这些是 Docker 镜像优化的基本要求。不做 = 镜像不专业、部署慢、磁盘浪费。

### TS-1: 多阶段构建确保构建依赖不泄漏到运行时

| 属性 | 说明 |
|------|------|
| 适用镜像 | findclass-ssr, noda-site |
| 为什么必须做 | 当前 findclass-ssr 的 Stage 2 已经是 node:22-slim，但仍然包含了完整的 node_modules（含 devDependencies）。noda-site 构建阶段用了完整的 node:20-alpine |
| 复杂度 | LOW -- findclass-ssr 已有多阶段，只需确保运行时阶段不复制 devDependencies |
| 实施要点 | 在 builder 阶段运行 `pnpm prune --prod`，运行时阶段只复制生产依赖 |
| 预期收益 | 中等（~200-500MB，取决于 devDependencies 占比） |
| 置信度 | HIGH |

### TS-2: 分离 Python/Chromium 爬虫到独立容器

| 属性 | 说明 |
|------|------|
| 适用镜像 | findclass-ssr（5.02GB -- 项目最大瓶颈） |
| 为什么必须做 | 主 API 服务不应该包含 ~3GB 的 Chromium 浏览器运行时。爬虫是定时任务，不是实时服务。每次部署 findclass-ssr 都要推送/拉取包含 Chromium 的巨大镜像 |
| 复杂度 | **HIGH** -- 需要拆分容器、调整爬虫调用方式、可能涉及网络通信方式变更 |
| 实施要点 | 两种方案：(A) 独立爬虫容器，API 通过 HTTP 调用；(B) 独立定时任务容器，直接连数据库写入 |
| 预期收益 | **巨大（~3GB）** -- findclass-ssr 从 5GB 降到 ~2GB |
| 置信度 | HIGH |

### TS-3: 替换 npm serve 为轻量静态文件服务器

| 属性 | 说明 |
|------|------|
| 适用镜像 | noda-site（218MB 用 Node.js 服务静态 HTML） |
| 为什么必须做 | 用 ~180MB 的 Node.js 运行时服务纯静态文件是资源浪费。nginx:alpine 才 76.5MB，专门为静态文件设计的 Rust 服务器只需 5-10MB |
| 复杂度 | LOW -- 只需更换 Dockerfile 的运行时阶段 |
| 实施要点 | 替换为 `joseluisq/static-web-server`（scratch 镜像，4MB 二进制）或直接用 nginx:alpine |
| 预期收益 | 大（~200MB 降到 ~15-30MB，减少 85-95%） |
| 置信度 | HIGH |

### TS-4: 统一基础镜像版本

| 属性 | 说明 |
|------|------|
| 适用镜像 | backup（postgres:17-alpine）vs test-verify（postgres:15-alpine） |
| 为什么必须做 | 不同版本的基础镜像意味着 Docker 不能共享层缓存，浪费磁盘和拉取时间 |
| 复杂度 | LOW -- 仅需修改 Dockerfile 的 FROM 行 |
| 实施要点 | 将 test-verify 的 `postgres:15-alpine` 改为 `postgres:17-alpine`，验证 SQL 兼容性 |
| 预期收益 | 小（~100-200MB 共享层缓存） |
| 置信度 | HIGH |

### TS-5: 优化层缓存顺序

| 属性 | 说明 |
|------|------|
| 适用镜像 | findclass-ssr, noda-ops, backup |
| 为什么必须做 | 依赖文件（package.json, requirements.txt）变更频率远低于源码。先复制依赖文件再复制源码，可以最大化缓存命中 |
| 复杂度 | LOW -- 仅调整 Dockerfile 中 COPY/RUN 指令的顺序 |
| 实施要点 | findclass-ssr 已部分做到（requirements.txt 先复制），但 node_modules 的复制顺序可以进一步优化 |
| 预期收益 | 中等（构建时间减少 30-50%，镜像体积无变化） |
| 置信度 | HIGH |

---

## Differentiators（差异化优化）

这些优化不是必须的，但能显著提升运维效率。

### D-1: 使用 static-web-server 替代 npm serve（noda-site）

| 属性 | 说明 |
|------|------|
| 适用镜像 | noda-site |
| 价值主张 | Rust 编写，4MB 静态二进制，scratch 镜像，HTTP/2 + TLS + 压缩 + CORS 全支持 |
| 复杂度 | LOW |
| 实施要点 | `FROM joseluisq/static-web-server:2` + COPY dist 到 `/public` |
| 预期收益 | noda-site 从 218MB 降到 ~15-20MB（包含静态文件），减少 90%+ |
| 置信度 | HIGH -- GitHub 2.2k stars，活跃维护（v2.42.0, 2026-03-28），Docker scratch 镜像 |

**推荐 Dockerfile 变更：**
```dockerfile
# Stage 1: 构建（保持不变）
FROM node:20-alpine AS builder
# ... 构建步骤不变

# Stage 2: 轻量运行时（替换 node:20-alpine + serve）
FROM joseluisq/static-web-server:2
COPY --from=builder /app/apps/site/dist /public
EXPOSE 3000
```

### D-2: findclass-ssr 从 node:22-slim 降级到 node:22-alpine

| 属性 | 说明 |
|------|------|
| 适用镜像 | findclass-ssr（分离爬虫后） |
| 价值主张 | alpine 基础镜像比 slim 小约 70MB（180MB vs 250MB），且攻击面更小 |
| 复杂度 | **MEDIUM** -- 需要验证 Node.js 应用在 musl libc 下运行正常，特别是原生模块 |
| 实施要点 | 切换到 alpine 后测试：(1) Hono 框架兼容性；(2) Drizzle ORM 的 pg 驱动；(3) pnpm workspace 符号链接解析 |
| 预期收益 | 小到中等（~70MB，分离爬虫后才有意义） |
| 置信度 | MEDIUM -- 需要验证原生依赖兼容性 |

### D-3: noda-ops 审查并精简依赖

| 属性 | 说明 |
|------|------|
| 适用镜像 | noda-ops（336MB） |
| 价值主张 | 336MB 的 alpine 镜像偏大，可能有冗余依赖 |
| 复杂度 | LOW |
| 实施要点 | 审查当前安装的包（见下方分析表） |
| 预期收益 | 小（~10-30MB） |
| 置信度 | MEDIUM -- 需要确认哪些工具实际被脚本使用 |

**noda-ops 当前依赖分析：**

| 包 | 大小估算 | 是否必要 | 说明 |
|----|---------|---------|------|
| bash | ~5MB | 是 | 脚本依赖 |
| curl | ~3MB | 是（与 wget 二选一） | 健康检查用，但 compose 用 wget |
| wget | ~2MB | 否（可用 curl 替代） | compose 健康检查用 wget --spider |
| jq | ~2MB | 是 | JSON 解析 |
| coreutils | ~10MB | 待确认 | sha256sum 等工具 |
| rclone | ~30MB | 是 | B2 备份上传 |
| dcron | ~1MB | 是 | 定时任务 |
| supervisor | ~5MB | 是 | 进程管理 |
| ca-certificates | ~1MB | 是 | HTTPS 证书 |
| postgresql17-client | ~30MB | 是 | pg_dump 备份 |
| gnupg | ~15MB | 待确认 | 可能用于加密 |
| age | ~3MB | 待确认 | 加密工具 |
| doppler | ~20MB | 是 | 密钥备份 |
| cloudflared | ~40MB | 是 | Tunnel |

### D-4: 使用 .dockerignore 排除不必要文件

| 属性 | 说明 |
|------|------|
| 适用镜像 | 所有自建镜像 |
| 价值主张 | 减少 Docker 构建上下文大小，加速构建 |
| 复杂度 | LOW |
| 实施要点 | 确保每个构建上下文都有 .dockerignore，排除 .git, node_modules, .env, test 等 |
| 预期收益 | 小（加速构建，不减少镜像体积） |
| 置信度 | HIGH |

### D-5: 清理包管理器缓存

| 属性 | 说明 |
|------|------|
| 适用镜像 | 所有镜像 |
| 价值主张 | 确保 apt/apk/pip 缓存在同一 RUN 层中清理 |
| 复杂度 | LOW |
| 实施要点 | noda-ops 的 `rm -rf /var/cache/apk/*` 已有。backup 镜像缺少清理步骤 |
| 预期收益 | 小（~5-10MB） |
| 置信度 | HIGH |

### D-6: 使用 COPY --chown 合并层

| 属性 | 说明 |
|------|------|
| 适用镜像 | findclass-ssr, noda-site |
| 价值主张 | `COPY --chown=user:group` 替代 `COPY + RUN chown`，减少一个镜像层 |
| 复杂度 | LOW |
| 实施要点 | 替换 `COPY ... RUN chown -R` 为 `COPY --chown=nodejs:nodejs` |
| 预期收益 | 极小（一个层） |
| 置信度 | HIGH |

---

## Anti-Features（不应该做的优化）

### AF-1: distroless 基础镜像

| 属性 | 说明 |
|------|------|
| 为什么想用 | 更小的镜像体积，更小的攻击面 |
| 为什么不该用 | (1) 没有 shell，调试困难（`docker exec -it` 不可用）；(2) 没有 wget/curl，健康检查需要额外处理；(3) 现有项目已有完善的健康检查和调试流程；(4) 收益有限（alpine 已经很精简） |
| 替代方案 | 继续使用 alpine 基础镜像，已经足够精简 |

### AF-2: docker build --squash

| 属性 | 说明 |
|------|------|
| 为什么想用 | 将所有层合并为一个，减少镜像体积 |
| 为什么不该用 | (1) 需要 BuildKit 实验性功能支持；(2) 破坏层缓存机制，每次构建都要完整推送；(3) 官方不推荐用于生产；(4) 在多阶段构建中收益极小 |
| 替代方案 | 使用多阶段构建，确保最终阶段只包含必要文件 |

### AF-3: 单一基础镜像统一所有服务

| 属性 | 说明 |
|------|------|
| 为什么想用 | "所有镜像都基于 debian:slim" 看似简化维护 |
| 为什么不该用 | 不同服务有不同需求：Node.js 服务需要 node 基础，备份服务需要 postgres 客户端，运维服务需要 alpine 工具。强行统一反而增加体积 |
| 替代方案 | 按服务类型选择最优基础镜像，同类服务（backup/test-verify）统一版本 |

### AF-4: Chromium 保留在 findclass-ssr 中但"压缩"

| 属性 | 说明 |
|------|------|
| 为什么想用 | 不想拆分容器，觉得可以"优化"Chromium 安装 |
| 为什么不该用 | Chromium 本身就是 ~700MB，patchright 的浏览器二进制也很大，这不是层缓存能解决的。根本问题是架构：爬虫不属于实时 API 服务 |
| 替代方案 | 将爬虫拆分到独立容器（TS-2） |

### AF-5: 在 CI/CD 中每次重建镜像不缓存

| 属性 | 说明 |
|------|------|
| 为什么想用 | "确保镜像最新"，`--no-cache` |
| 为什么不该用 | 完全绕过 Docker 层缓存机制，每次都要从零构建。findclass-ssr 完整构建可能需要 10+ 分钟 |
| 替代方案 | 优化 Dockerfile 层顺序（TS-5），依赖变更时才重建依赖层 |

---

## Feature Dependencies

```
[TS-2: 分离 Python/Chromium 爬虫]
    |
    +--blocks--> [D-2: findclass-ssr 降级到 alpine]
    |              （分离爬虫前，slim 是必要的因为需要 Python manylinux wheels）
    |
    +--enables--> [TS-1: prune devDependencies]
                    （分离后 node_modules 体量显著减小，prune 收益更明显）

[TS-3: 替换 npm serve] --same_as--> [D-1: static-web-server]
    （TS-3 是需求，D-1 是具体实现方案）

[TS-4: 统一基础镜像版本] --independent--> [所有其他优化]

[D-3: noda-ops 精简依赖] --independent--> [所有其他优化]

[D-4: .dockerignore] --independent--> [所有其他优化]

[TS-5: 层缓存顺序] --independent--> [所有其他优化]

[D-5: 清理缓存] --independent--> [所有其他优化]

[D-6: COPY --chown] --independent--> [所有其他优化]
```

### Dependency Notes

- **TS-2 阻塞 D-2:** 当前 findclass-ssr 使用 `node:22-slim`（Debian）是因为 Python manylinux wheels 需要 glibc。如果使用 `node:22-alpine`（musl libc），Python pip 安装 scrapling/patchright 可能失败。只有在分离爬虫后，才能安全切换到 alpine。
- **TS-2 放大 TS-1 收益:** 分离爬虫后，findclass-ssr 的 node_modules 不再包含 Python 相关依赖，`pnpm prune --prod` 的效果更显著。
- **TS-3 和 D-1 实质相同:** TS-3 是"替换 serve"的需求，D-1 是"用 static-web-server 替换"的具体实现方案。
- **D-4, D-5, D-6 互相独立:** 这些是小的"卫生"优化，可以随时做，不影响其他优化。

---

## MVP 定义

### Phase 1: 立即执行（低风险高收益）

这些优化互不依赖，可以并行执行。

- [ ] **TS-3/D-1: noda-site 替换为 static-web-server** -- 218MB -> ~15MB，90%+ 减少
- [ ] **TS-4: test-verify 统一到 postgres:17-alpine** -- 与 backup 共享层缓存
- [ ] **D-5: 清理包管理器缓存** -- backup 镜像缺少清理步骤
- [ ] **D-6: COPY --chown 合并层** -- findclass-ssr, noda-site

### Phase 2: 核心优化（高风险高收益）

这是整个里程碑的核心价值。

- [ ] **TS-2: 分离 Python/Chromium 爬虫** -- 5GB -> ~2GB，必须完成
  - 需要先确认爬虫调用方式和数据流
  - 设计新的容器架构（独立爬虫容器 vs 定时任务容器）

### Phase 3: 分离后优化（依赖 Phase 2）

- [ ] **D-2: findclass-ssr 降级到 alpine** -- 依赖爬虫已分离
- [ ] **TS-1: prune devDependencies** -- 分离后效果更好
- [ ] **D-3: noda-ops 精简依赖** -- 独立但优先级低
- [ ] **D-4: 审查 .dockerignore** -- 独立但优先级低

### Future Consideration

- [ ] **Dive 工具集成** -- 在 CI 中用 dive 分析镜像效率评分，作为质量门禁
- [ ] **多架构构建** -- 如需 ARM 支持（当前服务器是 x86，暂不需要）

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority | 预期体积变化 |
|---------|------------|---------------------|----------|-------------|
| TS-2: 分离爬虫 | HIGH | HIGH | **P1** | -3GB |
| TS-3/D-1: static-web-server | HIGH | LOW | **P1** | -200MB |
| TS-4: 统一基础镜像 | MEDIUM | LOW | **P1** | ~0（共享缓存） |
| TS-1: prune devDeps | MEDIUM | LOW | **P2** | -200~500MB |
| D-2: alpine 降级 | LOW | MEDIUM | **P2** | -70MB |
| D-3: noda-ops 精简 | LOW | LOW | **P2** | -10~30MB |
| TS-5: 层缓存顺序 | MEDIUM | LOW | **P2** | 0（加速构建） |
| D-4: .dockerignore | LOW | LOW | **P3** | 0（加速构建） |
| D-5: 清理缓存 | LOW | LOW | **P3** | -5~10MB |
| D-6: COPY --chown | LOW | LOW | **P3** | 极小 |

**Priority key:**
- **P1**: 必须完成，构成里程碑核心价值
- **P2**: 应该完成，但依赖 P1 或优先级较低
- **P3**: 可以做，锦上添花

---

## 各镜像优化策略汇总

### findclass-ssr (5.02GB -> 目标 ~1.5-2GB)

| 策略 | 预期减少 | 优先级 | 风险 |
|------|---------|--------|------|
| 分离 Python/Chromium 爬虫到独立容器 | ~3GB | P1 | HIGH（架构变更） |
| pnpm prune --prod | ~200-500MB | P2 | LOW |
| 降级到 node:22-alpine | ~70MB | P2 | MEDIUM（需验证兼容性） |
| COPY --chown 合并层 | 极小 | P3 | LOW |

### noda-site (218MB -> 目标 ~15-20MB)

| 策略 | 预期减少 | 优先级 | 风险 |
|------|---------|--------|------|
| 替换 npm serve 为 static-web-server | ~200MB | P1 | LOW |

### noda-ops (336MB -> 目标 ~300MB)

| 策略 | 预期减少 | 优先级 | 风险 |
|------|---------|--------|------|
| 审查精简依赖（wget/curl 二选一） | ~10-30MB | P2 | LOW |

### backup + test-verify

| 策略 | 预期减少 | 优先级 | 风险 |
|------|---------|--------|------|
| test-verify 统一到 postgres:17-alpine | 0（共享缓存） | P1 | LOW |
| backup 添加 apt/apk 缓存清理 | ~5-10MB | P3 | LOW |

---

## static-web-server 技术评估

**为什么选择 static-web-server 而非其他方案：**

| 方案 | 镜像大小 | TLS | 压缩 | SPA 支持 | 复杂度 |
|------|---------|-----|------|---------|--------|
| **static-web-server (Rust)** | **~5MB (scratch)** | 是 | Gzip/Brotli/Zstd | 是（fallback page） | 极低 |
| nginx:alpine | ~25MB | 是 | 是 | 是（需配置 try_files） | 中等 |
| Caddy | ~40MB | 是（自动 HTTPS） | 是 | 是 | 低 |
| npm serve (当前) | ~180MB | 否 | 否 | 否 | 低 |

**static-web-server 优势：**
- scratch 镜像，零 OS 层，攻击面极小
- 4MB 静态二进制，无依赖
- 活跃维护（v2.42.0, 2026-03-28 发布）
- Docker Hub 每日拉取量高，社区活跃（2.2k GitHub stars）
- 内置 CORS、压缩、缓存头、健康检查端点

**推荐 Dockerfile：**
```dockerfile
FROM node:20-alpine AS builder
# ... 构建步骤保持不变 ...

FROM joseluisq/static-web-server:2
COPY --from=builder /app/apps/site/dist /public
# 环境变量配置
ENV SERVER_PORT=3000
ENV SERVER_ROOT=/public
```

---

## 爬虫容器分离方案对比

### 方案 A: 独立爬虫服务容器（长期运行）

```
findclass-ssr (API)  --HTTP-->  skykiwi-crawler (独立容器)
     |                                |
     +-- 调用爬虫 API                    +-- 直接访问数据库
```

- 优点：解耦彻底，独立部署/扩缩容
- 缺点：多一个长期运行的容器，需要维护服务发现
- 适合：爬虫调用频率高（每小时多次）

### 方案 B: 定时任务容器（推荐）

```
skykiwi-crawler (cron 触发)  --直接-->  PostgreSQL
    |
    +-- docker run --rm 或 cron/systemd timer
    +-- 独立镜像：python:3.12-slim + chromium + scrapling
```

- 优点：只在需要时运行，不占用常驻内存；镜像体积不影响主服务部署
- 缺点：需要外部调度器（cron/systemd timer/Jenkins Pipeline）
- 适合：爬虫调用频率低（每天 1-2 次）

**推荐方案 B**，原因：
1. 从 noda-apps 代码看，爬虫是定时任务（`crawl-skykiwi.py`），不是实时 API 调用
2. 项目已有 Jenkins Pipeline 和 cron 基础设施
3. 单服务器资源有限，不需要常驻的爬虫服务
4. 与现有 backup 容器的 cron 模式一致

---

## Sources

- 项目代码审查：`deploy/Dockerfile.findclass-ssr`, `deploy/Dockerfile.noda-site`, `deploy/Dockerfile.noda-ops`, `deploy/Dockerfile.backup`, `scripts/backup/docker/Dockerfile.test-verify`
- Docker Compose 配置：`docker/docker-compose.yml`, `docker/docker-compose.app.yml`
- 当前镜像大小数据：`docker images` 输出（2026-04-20）
- [static-web-server GitHub](https://github.com/static-web-server/static-web-server) -- v2.42.0, 2.2k stars, 活跃维护, scratch 镜像
- [Docker 多阶段构建官方文档](https://docs.docker.com/build/building/multi-stage/) -- 多阶段构建最佳实践
- [Docker 构建缓存优化](https://docs.docker.com/build/cache/optimize/) -- 层缓存顺序最佳实践

---
*Feature research for: Docker 镜像瘦身优化*
*Researched: 2026-04-20*
