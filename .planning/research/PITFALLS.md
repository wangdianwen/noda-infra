# Pitfalls Research: Docker 镜像瘦身优化

**Domain:** 生产环境 Docker 镜像体积优化（Node.js、Python/Chromium、静态站点、Alpine 基础镜像）
**Researched:** 2026-04-20
**Confidence:** HIGH（基于代码库完整审计 + Docker 官方文档 Context7 验证 + pip wheel 兼容性实测；WebSearch 配额耗尽，部分生态数据来自训练知识，已标注）

---

## Critical Pitfalls

### Pitfall 1: findclass-ssr 切换 Alpine 后 Python 原生扩展无法安装

**What goes wrong:**
findclass-ssr 运行时包含 Python 爬虫（patchright/scrapling），其依赖 lxml、orjson、greenlet 等包含 C 扩展的包。这些包在 PyPI 上只提供 `manylinux` 格式的预编译 wheel（针对 glibc）。Alpine 使用 musl libc，需要 `musllinux` 格式的 wheel。

**实测验证（2026-04-20）：**
- `lxml==6.0.3`：PyPI 无 `musllinux_1_1_aarch64` wheel，只有 `manylinux2014` wheel。Alpine 上最新可用的 musllinux 版本仅到 `5.2.2`
- `orjson==3.11.8`：PyPI 无 `musllinux` wheel，最新可用 musllinux 版本仅到 `3.9.12`
- `greenlet==3.3.0`：PyPI 无 `musllinux` wheel，aarch64 平台最新版本仅到 `3.2.5`

在 Alpine 上安装这些包会触发从源码编译，需要安装 `gcc musl-dev libxml2-dev libxslt-dev` 等构建工具链，编译时间长且可能失败。

**Why it happens:**
manylinux 是 Python 打包标准（PEP 599），假设 glibc 环境。PEP 656 引入了 musllinux 标准，但很多包的 CI 不构建 musllinux wheel，尤其是小众或更新频率高的包。Alpine 的 musl libc 与 glibc 二进制不兼容，manylinux wheel 无法直接加载。

**Consequences:**
- `pip install` 失败或耗时极长（编译 lxml 需要数分钟）
- 编译依赖使镜像体积不降反升（需要保留 gcc 等构建工具，或增加复杂的多阶段构建）
- 运行时可能出现 musl 特有的微妙 bug（DNS 解析、线程调度、内存分配差异）

**How to avoid:**
1. **findclass-ssr 保持 `node:22-slim`（Debian-based）**：当前 Dockerfile 第 69 行已经是 `FROM node:22-slim AS runner`，这是正确的选择。Python 原生依赖 + Chromium 在 Debian 上开箱即用
2. **分离 Python 爬虫为独立容器**：如果需要瘦身，将 Python 爬虫拆分为独立的 `python:3.12-slim` 容器，主 Node.js 容器使用 `node:22-alpine`。这样两边都使用各自最佳的 base image
3. **如果必须在 Alpine 上运行 Python**：用 `pip download --platform musllinux_1_1_aarch64` 预检每个依赖的 wheel 可用性，对缺少 musllinux wheel 的包准备从源码编译的完整工具链

**Warning signs:**
- `pip install` 日志中出现 `Building wheel for lxml/orjson/greenlet`（源码编译）
- Docker 构建时间突然增加数分钟
- `ImportError: Error loading shared library` 运行时错误

**Phase to address:**
findclass-ssr 优化阶段 -- 决定是否分离 Python 爬虫

---

### Pitfall 2: Chromium 在 read_only 容器中的沙箱和共享内存问题

**What goes wrong:**
当前 `docker-compose.app.yml` 第 71-74 行配置了 `read_only: true` 和有限 tmpfs：

```yaml
read_only: true
tmpfs:
  - /tmp
  - /app/scripts/logs
```

Chromium 在此环境下需要：
1. **写入 `/dev/shm`**（共享内存，默认 64MB，Chromium 需要至少 256MB）
2. **写入用户数据目录**（默认 `~/.config/chromium` 或 `/tmp` 下）
3. **用户命名空间**（用于沙箱，`--no-sandbox` 可绕过但降低安全性）

如果 Python 爬虫被分离为独立容器，新容器也面临同样的问题。

**Why it happens:**
- `read_only: true` 使整个文件系统只读，只有 tmpfs 挂载点可写
- Chromium 默认使用 `/dev/shm` 进行进程间通信，64MB 不够会导致崩溃（`session deleted because of page crash`）
- Docker 的 `--shm-size` 参数控制 `/dev/shm` 大小，docker-compose 中通过 `shm_size` 设置
- Chromium 的沙箱机制（SuidSandbox、NamespaceSandbox）在 Docker 容器中可能不可用

**Consequences:**
- Chromium 启动失败或随机崩溃
- 爬虫静默失败（patchright 超时）
- 生产环境中难以复现（本地开发没有 `read_only`）

**How to avoid:**
1. **如果分离爬虫容器**：新容器必须配置 `shm_size: '256m'`，不需要 `read_only: true`（爬虫容器可以不用只读文件系统）
2. **如果保持合一容器**：在 `docker-compose.app.yml` 中添加 `shm_size: '256m'`，并确认 `/tmp` tmpfs 足够大
3. **传递 `--no-sandbox` 参数**：在 patchright 启动参数中添加 `args=["--no-sandbox", "--disable-setuid-sandbox"]`。在 Docker 容器内这是可接受的安全折衷
4. **设置 `PLAYWRIGHT_BROWSERS_PATH`**：确保浏览器二进制文件路径在可写目录下（`/tmp` 或 tmpfs）

**Warning signs:**
- Chromium 日志：`Running as root without --no-sandbox is not supported`
- `Browser closed unexpectedly` 或 `Target closed` 错误
- `/dev/shm` 空间不足的 dmesg 日志

**Phase to address:**
Python 爬虫分离阶段（无论分离与否都需要解决）

---

### Pitfall 3: noda-site 从 serve 换 nginx 后健康检查和蓝绿部署端口不匹配

**What goes wrong:**
当前 noda-site 使用 `serve -s dist -l 3000`（Node.js serve），健康检查和蓝绿部署都基于端口 3000：

- `Jenkinsfile.noda-site` 第 14 行：`SERVICE_PORT = "3000"`
- `manage-containers.sh` 第 657 行：`SERVICE_PORT=3000`
- `upstream-noda-site.conf`：`server noda-site-blue:3000`
- `docker-compose.app.yml` 第 100 行：`wget --quiet --tries=1 --spider http://localhost:3000/`
- `Dockerfile.noda-site` 第 59 行：`HEALTHCHECK ... wget ... http://localhost:3000/`

如果切换到 `nginx:alpine` 静态文件服务：
- nginx 默认监听端口 80（不是 3000）
- Dockerfile 的 `HEALTHCHECK` URL 需要改为 `http://localhost:80/`
- Compose 健康检查需要改为 80 端口
- Jenkinsfile 的 `SERVICE_PORT` 需要改为 `"80"`
- nginx upstream 配置的端口需要改为 80
- `manage-containers.sh` 中 noda-site 的默认端口需要更新

**Why it happens:**
端口 3000 是 Node.js serve 的默认配置，nginx 默认是 80。端口变更影响 6 个不同位置的配置文件，容易遗漏。

**Consequences:**
- 健康检查失败导致容器被标记为 unhealthy
- 蓝绿部署的 `wait_container_healthy` 超时（检查错误端口）
- nginx upstream 无法连接到新容器
- Pipeline 部署失败但回滚也可能失败（如果旧镜像已被清理）

**How to avoid:**
1. **统一端口变量**：noda-site 的新 Dockerfile 中 nginx 监听端口应通过环境变量控制，或在所有配置中统一改为 80
2. **逐一检查所有引用端口 3000 的位置**：`grep -rn "3000" --include="*.yml" --include="*.conf" --include="*.sh" --include="Jenkinsfile*"` 并确认哪些是 noda-site 相关的
3. **蓝绿部署测试**：修改后必须通过 Jenkins Pipeline 完整走一遍部署流程，不能只验证 `docker build`
4. **保留端口 3000 的选项**：在 nginx 配置中 `listen 3000` 而非 80，保持与现有蓝绿架构兼容，减少修改范围

**Warning signs:**
- `docker inspect` 显示容器 `unhealthy`
- Jenkins Pipeline Health Check 阶段超时
- nginx 日志无请求（upstream 端口错误）

**Phase to address:**
noda-site 优化阶段 -- 替换 serve 为 nginx 时

---

### Pitfall 4: 多阶段构建 COPY 遗漏运行时依赖

**What goes wrong:**
findclass-ssr 的当前 Dockerfile 第 92-131 行有大量 `COPY --from=builder` 指令。优化过程中如果遗漏了任何运行时依赖：

- **遗漏 `package.json`**：Node.js 无法解析模块路径
- **遗漏符号链接重建**：第 109-112 行的 `ln -s` 创建的 workspace 解析链接，pnpm workspace 依赖这些链接查找 `@noda-apps/*` 包
- **遗漏 `tsconfig.base.json`**：如果运行时需要类型检查（不常见但 SSR 可能需要）
- **遗漏 Python 虚拟环境或 site-packages**：如果 Python 依赖安装位置不在 `scripts/` 下
- **遗漏 patchright 浏览器二进制**：`python3 -m patchright install chromium` 下载的 Chromium 二进制文件（约 200-400MB），如果 Python 爬虫被分离但遗漏了浏览器安装

**Why it happens:**
- pnpm workspace 的依赖解析依赖符号链接结构，而 Docker 的 `COPY` 指令默认不保留符号链接的目标，只复制链接本身
- `node_modules` 中的嵌套依赖可能在 builder 阶段被 hoisted，运行时结构不同
- 多阶段构建的心理盲区：开发者只复制自己写的代码的产物，忘记依赖也需要精确复制

**Consequences:**
- 运行时 `MODULE_NOT_FOUND` 错误
- SSR 渲染失败（白屏）
- Python 爬虫运行时 ImportError
- 只在特定请求路径下触发（不是所有请求都用到所有模块）

**How to avoid:**
1. **构建后验证脚本**：`docker run --rm findclass-ssr:latest node -e "require('./apps/findclass/api/dist/api.js')"` 验证所有模块可加载
2. **比对构建产物**：构建后 `docker run --rm builder ls -laR /app/ > /tmp/builder.txt` 和 `docker run --rm runner ls -laR /app/ > /tmp/runner.txt` 比对文件列表
3. **使用 `COPY --from=builder /app /app` 全量复制**：如果不确定精确需要哪些文件，先全量复制验证运行正常，再逐步删除不需要的文件
4. **Python 依赖测试**：`docker run --rm findclass-ssr:latest python3 -c "import scrapling; import patchright"`

**Warning signs:**
- 容器启动后 `docker logs` 显示 `Cannot find module`
- SSR 页面返回 500 错误
- 特定 API 端点返回 500（依赖了被遗漏的模块）

**Phase to address:**
findclass-ssr 多阶段优化阶段

---

### Pitfall 5: 蓝绿部署镜像命名策略被破坏

**What goes wrong:**
当前蓝绿部署流程（`blue-green-deploy.sh` 第 98-111 行）使用以下镜像命名策略：

```bash
# 构建产生 latest 标签
docker compose -f "$COMPOSE_FILE" build "$SERVICE_NAME"
# 给 latest 打上 git SHA 标签
docker tag "${SERVICE_NAME}:latest" "${SERVICE_NAME}:${short_sha}"
deploy_image="${SERVICE_NAME}:${short_sha}"
```

然后 `run_container` 使用 `deploy_image` 启动新容器。如果 Dockerfile 优化改变了构建上下文或输出：

- **Dockerfile 路径变更**：`Jenkinsfile.noda-site` 第 18 行硬编码 `DOCKERFILE = "deploy/Dockerfile.noda-site"`。如果文件名或路径变了，Pipeline 找不到 Dockerfile
- **构建上下文变更**：`docker-compose.app.yml` 中 `context: ../../noda-apps` 和 `dockerfile: ../noda-infra/deploy/Dockerfile.findclass-ssr`。如果 noda-site 改为不依赖 noda-apps 构建上下文，compose build 会失败
- **镜像标签不一致**：如果优化后使用不同的 `--tag` 参数，`cleanup_by_tag_count` 可能找不到旧镜像进行清理
- **回滚镜像丢失**：`cleanup_by_tag_count` 保留最近 5 个标签（`CLEANUP_KEEP_COUNT=5`）。如果优化过程中重新构建了多次，旧的回滚镜像可能被清理

**Why it happens:**
蓝绿部署的镜像管理逻辑（`image-cleanup.sh`、`manage-containers.sh`、`blue-green-deploy.sh`）都假设镜像名为 `${SERVICE_NAME}:latest` + `${SERVICE_NAME}:${git_sha}`。改变这个假设会影响整个部署链路。

**Consequences:**
- Pipeline Build 阶段失败（Dockerfile 路径错误）
- 部署成功但旧镜像被意外清理，无法回滚
- `run_container` 启动失败（镜像名格式不匹配）

**How to avoid:**
1. **保持 Dockerfile 路径不变**：如果必须重命名，同步更新 `docker-compose.app.yml` 和所有 Jenkinsfile 中的路径
2. **保持镜像命名约定**：`SERVICE_NAME:latest` + `SERVICE_NAME:git_sha` 的约定不应改变
3. **优化前后各运行一次完整 Pipeline**：验证蓝绿部署全流程正常
4. **保留回滚镜像**：优化过程中不要清理旧镜像，至少保留一个可回滚的版本

**Warning signs:**
- `docker compose build` 报错 `failed to solve: failed to read dockerfile`
- `docker tag` 报错 `Error: No such image`
- `cleanup_by_tag_count` 日志显示 "清理了所有旧镜像"（包括可能需要回滚的）

**Phase to address:**
每个镜像优化的验证阶段

---

### Pitfall 6: Alpine 的 DNS 解析差异导致服务间通信失败

**What goes wrong:**
如果 findclass-ssr 的 Node.js 运行时切换到 Alpine（`node:22-alpine`），musl 的 DNS 解析器与 glibc 有关键差异：

1. **无 DNS 缓存**：每次 `getaddrinfo()` 都直接查询 DNS 服务器
2. **不支持 `/etc/nsswitch.conf`**：无法配置解析顺序
3. **串行 AAAA/A 查询**：不并行查询 IPv6 和 IPv4，DNS 解析更慢
4. **对 `/etc/resolv.conf` 选项的有限支持**：`options rotate`、`options timeout` 等被忽略

findclass-ssr 运行时需要连接：
- PostgreSQL（`noda-infra-postgres-prod:5432`）-- Docker 内部 DNS
- Keycloak（`http://noda-infra-nginx`）-- Docker 内部 DNS
- 外部 API（ReSend、Anthropic）-- 外部 DNS

Docker 内部 DNS 通常不会出问题（解析非常简单），但外部 DNS 查询可能在网络不稳定时表现不同。

**Why it happens:**
Node.js 的 `dns.lookup()` 使用操作系统的 `getaddrinfo()`，在 Alpine 上走 musl 实现。`dns.resolve()` 使用 c-ares 库，不受影响。大多数 Node.js 代码（包括 HTTP 客户端）默认使用 `dns.lookup()`。

**Consequences:**
- 间歇性 `EAI_AGAIN` 错误（DNS 解析超时）
- 外部 API 调用延迟增加
- 在网络压力大时更容易出现连接失败

**How to avoid:**
1. **findclass-ssr 保持 `node:22-slim`**：避免引入 musl DNS 问题
2. **如果 Node.js 部分必须用 Alpine**：设置 `NODE_OPTIONS='--dns-result-order=ipv4first'`，跳过 IPv6 查询
3. **分离后 Node.js 容器无外部 DNS 需求**：如果 Node.js 容器只连接 Docker 内部服务（PostgreSQL、Keycloak），Alpine 的 DNS 差异影响极小

**Warning signs:**
- Node.js 日志中出现 `getaddrinfo EAI_AGAIN`
- 外部 API 调用偶尔超时
- 仅在 Alpine 镜像中出现，slim 镜像正常

**Phase to address:**
findclass-ssr 基础镜像决策阶段

---

### Pitfall 7: noda-site 切换 nginx 后 CSP 和安全头丢失

**What goes wrong:**
当前 `config/nginx/conf.d/default.conf` 第 110-161 行为 noda-site 定义了完整的安全头：

```nginx
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
```

以及 gzip 压缩和缓存策略（Vite 带 hash 资源 1 年缓存，HTML 不缓存）。

如果 noda-site 容器内部改为 nginx 服务静态文件，而外部 nginx 仍然做反向代理：

1. **双重 nginx 问题**：请求经过两层 nginx（外部 nginx 反代 -> 内部 nginx 静态文件），安全头可能在任一层被覆盖
2. **缓存策略冲突**：内部 nginx 和外部 nginx 可能设置不同的缓存头
3. **gzip 双重压缩**：如果两层都启用 gzip，可能导致性能问题或内容损坏

**Why it happens:**
nginx 的 `add_header` 指令在 location 块中会覆盖上层 server 块的同名 header。两层 nginx 之间没有协调机制。

**How to avoid:**
1. **内部 nginx 只做静态文件服务，不设置安全头**：安全头由外部 nginx 统一管理（当前配置已存在）
2. **内部 nginx 不启用 gzip**：压缩由外部 nginx 统一处理
3. **或者绕过外部 nginx**：noda-site 直接通过 Cloudflare Tunnel 暴露，不再经过外部 nginx。但这需要重新配置 Tunnel 路由
4. **最简方案**：内部 nginx 最小配置（`server { listen 3000; root /app/dist; }`），所有安全和缓存策略在外部 nginx 管理

**Warning signs:**
- HTTP 响应头中出现重复的 header
- `curl -I https://noda.co.nz/` 显示安全头缺失
- PageSpeed Insights 报告缺少 gzip

**Phase to address:**
noda-site nginx 配置阶段

---

### Pitfall 8: patchright 浏览器二进制在多阶段构建中遗漏

**What goes wrong:**
当前 Dockerfile.findclass-ssr 第 127 行：

```dockerfile
RUN python3 -m patchright install chromium
```

这会下载约 200-400MB 的 Chromium 浏览器二进制文件。`PLAYWRIGHT_BROWSERS_PATH=0`（第 85 行）本意是使用系统 Chromium，但注释说"对 patchright 无效"。

如果优化多阶段构建，将 Python 安装放在 builder 阶段，运行时阶段需要知道浏览器二进制文件的确切安装位置：

- patchright 默认安装到 `~/.cache/ms-playwright/` 或 `PLAYWRIGHT_BROWSERS_PATH` 指定的路径
- 以 `nodejs` 用户（UID 1001）运行时，缓存目录在 `/home/nodejs/.cache/`
- 如果构建阶段以 root 运行但运行时以 nodejs 运行，路径和权限不匹配

**Why it happens:**
patchright 是 Playwright 的 fork，浏览器安装机制与标准 Playwright 相同但版本号不同。`PLAYWRIGHT_BROWSERS_PATH=0` 在 Playwright 中表示"使用系统浏览器"，但 patchright 可能不尊重这个环境变量。

**Consequences:**
- `patchright` 运行时报错 `Executable doesn't exist`
- 浏览器下载在构建阶段完成但运行时找不到（路径不同）
- 镜像体积没有减少（浏览器二进制仍然很大）

**How to avoid:**
1. **在运行时阶段直接安装浏览器**（当前做法）：保持 `RUN python3 -m patchright install chromium` 在 runner 阶段，不放在 builder
2. **如果必须多阶段复制**：先用 `docker run` 查明安装路径，然后精确 COPY
3. **分离爬虫后**：Python 爬虫容器使用 `mcr.microsoft.com/playwright/python` 预构建镜像（已包含 Chromium），不需要手动安装
4. **验证安装路径**：`docker run --rm findclass-ssr:latest python3 -c "from patchright.sync_api import sync_playwright; print(sync_playwright().chromium.executable_path)"` （需要实际启动浏览器，在 CI 中可简化为检查文件存在性）

**Warning signs:**
- `browserType.launch: Executable doesn't exist at /home/nodejs/.cache/ms-playwright/chromium-*/chrome-linux/chrome`
- Docker 构建日志中 patchright install 步骤缺失
- 运行时 `ls /home/nodejs/.cache/ms-playwright/` 为空

**Phase to address:**
findclass-ssr Python 爬虫分离或优化阶段

---

## Moderate Pitfalls

### Pitfall 9: noda-ops 从 Alpine 切换基础镜像的必要性存疑

**What goes wrong:**
noda-ops 已经使用 `alpine:3.21`（Dockerfile.noda-ops 第 8 行），体积约 306MB。看起来不小，但主要是 `postgresql17-client`（~50MB）、`rclone`（~30MB）、`cloudflared`（~40MB）等必要工具。如果错误地追求更小体积而删除必要工具，会导致备份或 Tunnel 功能失效。

**Prevention:**
noda-ops 的优化重点不是切换基础镜像（已经是 Alpine），而是审查 `apk add` 列表中是否有不必要的包。例如 `wget` 和 `curl` 是否可以只保留一个。

### Pitfall 10: Docker BuildKit 缓存导致 Dockerfile 修改未生效

**What goes wrong:**
CLAUDE.md 中已记录此问题："docker compose build 可能使用 BuildKit 缓存导致 Dockerfile 修改未生效"。多阶段构建尤其容易受影响，因为 builder 阶段的层可能被复用。

**Prevention:**
关键修改后使用 `docker build --no-cache` 验证。或在 `docker compose build` 时加 `--no-cache` 参数。

### Pitfall 11: test-verify 容器使用 postgres:15-alpine 而非 postgres:17-alpine

**What goes wrong:**
`Dockerfile.test-verify` 第 1 行使用 `postgres:15-alpine`，而主备份容器（`Dockerfile.backup`）使用 `postgres:17-alpine`。版本不一致意味着：
- `pg_dump`/`pg_restore` 版本不匹配可能导致备份验证失败
- 两个镜像无法共享基础层，浪费磁盘空间

**Prevention:**
统一为 `postgres:17-alpine`，与主数据库和备份容器保持一致。

### Pitfall 12: pnpm workspace 的符号链接在 Docker COPY 中丢失

**What goes wrong:**
Dockerfile.findclass-ssr 第 109-112 行手动重建了符号链接：

```dockerfile
RUN mkdir -p node_modules/@noda-apps && \
    ln -s /app/packages/shared node_modules/@noda-apps/shared && \
    ln -s /app/packages/database node_modules/@noda-apps/database && \
    ln -s /app/packages/design-tokens node_modules/@noda-apps/design-tokens
```

如果优化时遗漏了这些链接重建，`require('@noda-apps/shared')` 会失败。pnpm 的 `node_modules` 结构与 npm 不同，依赖精确的符号链接树。

**Prevention:**
任何涉及 `COPY --from=builder` 的修改都必须验证这 3 个符号链接存在且指向正确。

### Pitfall 13: Docker 层缓存排序不当导致构建效率下降

**What goes wrong:**
Dockerfile.findclass-ssr 将 `COPY scripts/requirements.txt`（第 123 行）放在 `COPY scripts/`（第 130 行）之前，利用层缓存优化依赖安装。如果优化时改变了 COPY 顺序，每次代码变更都会重新安装 Python 依赖。

**Prevention:**
保持"先复制依赖声明文件 -> 安装依赖 -> 再复制源码"的模式。这是 Docker 最佳实践，不应为减少层数而合并这些步骤。

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| 不分离 Python 爬虫，只优化 Node.js 层 | 零架构变更，风险最低 | 主镜像仍然 1GB+（Chromium 占 400MB） | MVP 阶段可接受，长期不可接受 |
| `--no-sandbox` 运行 Chromium | 立即解决沙箱兼容问题 | 降低安全边界，容器逃逸风险增加 | read_only 容器 + 无 privileged 时勉强可接受 |
| 保持 serve 不换 nginx | 零风险，零改动 | noda-site 镜像约 150MB（node:alpine + serve）vs 25MB（nginx:alpine） | 永远可接受 -- 镜像差异对部署时间和磁盘影响有限 |
| 不统一 postgres 基础镜像版本 | 零改动 | test-verify 容器约 80MB 不必要的额外镜像层 | 应在本次优化中修复 |
| 全量 COPY node_modules 而非精确复制 | 构建成功率高 | 镜像体积未优化（包含 devDependencies） | 绝不可接受 -- 应使用 `--frozen-lockfile --prod` 或精确复制 |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| nginx 反代 -> noda-site(nginx) | 两层 nginx 都设置安全头，导致重复或覆盖 | 内部 nginx 只做静态文件服务，安全头由外部 nginx 统一管理 |
| Jenkins Pipeline + 镜像构建 | Dockerfile 路径变更后未同步 Jenkinsfile | `grep -r "Dockerfile" jenkins/` 确认所有引用 |
| 蓝绿部署 + 新镜像 | 新镜像健康检查端口/路径变更未更新 manage-containers.sh | 修改 SERVICE_PORT 和 HEALTH_PATH 后全量 Pipeline 测试 |
| Docker Compose + read_only | Chromium 写入 `/dev/shm` 失败但无明确错误 | 添加 `shm_size: '256m'` 和 `--no-sandbox` |
| patchright + 系统 Chromium | `PLAYWRIGHT_BROWSERS_PATH=0` 对 patchright 无效 | 使用 `python3 -m patchright install chromium` 单独安装 |
| Docker BuildKit + 多阶段 | 修改 builder 阶段但 runner 阶段使用了缓存的旧产物 | 关键修改后 `docker build --no-cache` 验证 |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Chromium /dev/shm 不足 | 页面崩溃、爬虫超时、`session deleted because of page crash` | `shm_size: '256m'` 在 compose 中配置 | 爬取页面数量增加或页面内存需求增大 |
| 多阶段构建复制了全部 node_modules | 镜像体积未减少，可能比优化前更大 | 精确复制运行时需要的文件，用 `du -sh` 比对每层 | 依赖数量增长时镜像膨胀 |
| Alpine 上 Python 从源码编译 | Docker 构建时间增加 5-10 分钟 | 使用 Debian-based 镜像或预检 musllinux wheel 可用性 | 依赖版本更新后编译失败 |
| nginx 双层反代 gzip 冲突 | 响应体乱码或 Content-Encoding 错误 | 内部 nginx 不启用 gzip | 外部 nginx 启用 gzip 时 |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Chromium `--no-sandbox` 在特权容器中 | 容器逃逸风险 | `read_only: true` + `cap_drop: ALL` + 非特权用户，`--no-sandbox` 仅在以上保护到位时使用 |
| 镜像中包含构建工具链（gcc、make） | 攻击者可编译提权工具 | 多阶段构建中构建工具链留在 builder 阶段，不进入 runner |
| Python pip 使用 `--break-system-packages` | 系统级包被覆盖 | 使用虚拟环境（`python3 -m venv`），或确保 Docker 容器内无所谓系统包 |
| noda-site nginx 配置暴露 `.git` 或隐藏文件 | 源码泄露 | nginx location 块中添加 `location ~ /\. { deny all; }` |

---

## "Looks Done But Isn't" Checklist

- [ ] **镜像体积减少**: `docker images` 显示更小体积，但运行时模块加载失败 -- 用 `docker run --rm <image> node -e "require('./path')"` 验证所有关键路径
- [ ] **健康检查通过**: `docker ps` 显示 healthy，但实际 HTTP 请求返回 500 -- `curl http://localhost:PORT/api/health` 端到端验证
- [ ] **蓝绿部署成功**: 新容器启动正常，但 nginx upstream 端口不匹配导致 502 -- 切换后 `curl -H "Host: class.noda.co.nz" http://localhost/api/health` 验证
- [ ] **Python 爬虫分离**: 独立容器构建成功，但 patchright 找不到 Chromium 二进制 -- `docker run --rm <image> python3 -c "from patchright.sync_api import sync_playwright"` 验证
- [ ] **noda-site nginx 配置**: 静态文件可访问，但缺少 gzip 或安全头 -- `curl -I https://noda.co.nz/` 检查响应头
- [ ] **CDN 缓存清除**: Pipeline CDN Purge 阶段成功，但旧版本 index.html 仍在 CDN 缓存中 -- 部署后在无痕窗口验证新版本
- [ ] **Docker 层缓存有效**: 第二次构建很快，但第一次构建因为缓存未命中而极慢 -- 全新机器上测试完整构建

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Python wheel 不兼容 Alpine（P1） | LOW | 回退到 `node:22-slim`，或使用 `python:slim` 分离容器 |
| Chromium 沙箱崩溃（P2） | LOW | 添加 `shm_size` 和 `--no-sandbox`，重新部署 |
| 端口不匹配（P3） | LOW | 统一端口配置，重新构建和部署 |
| COPY 遗漏依赖（P4） | MEDIUM | 回退到全量 COPY，逐步精简 |
| 镜像命名破坏（P5） | MEDIUM | 恢复旧 Dockerfile 路径，手动 `docker tag` 修复 |
| DNS 解析失败（P6） | LOW | 回退到 slim 镜像，或设置 `--dns-result-order=ipv4first` |
| 安全头丢失（P7） | LOW | 修复 nginx 配置，`nginx -s reload` 即可 |
| patchright 浏览器遗漏（P8） | MEDIUM | 重新构建镜像，确保浏览器在 runner 阶段安装 |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Python wheel 不兼容（P1） | findclass-ssr 基础镜像选型 | `pip download --platform musllinux` 预检，确认保持 slim |
| Chromium 沙箱（P2） | Python 爬虫分离/优化 | `docker run` 启动爬虫并抓取一个页面验证 |
| 端口不匹配（P3） | noda-site nginx 迁移 | Jenkins Pipeline 完整流程验证 |
| COPY 遗漏（P4） | findclass-ssr 多阶段优化 | `docker run` 验证所有模块可加载 |
| 镜像命名（P5） | 每个镜像优化的验证 | `docker images` 确认标签格式正确 |
| DNS 差异（P6） | Node.js 容器基础镜像选型 | 保持 slim 即可规避 |
| 安全头（P7） | noda-site nginx 配置 | `curl -I` 验证响应头 |
| patchright 浏览器（P8） | Python 爬虫分离 | `python3 -c "from patchright..."` 验证 |

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| findclass-ssr 基础镜像决策 | P1: Python wheel 不兼容 | 保持 `node:22-slim`，或分离 Python 为独立 `python:3.12-slim` 容器 |
| Python 爬虫分离 | P2: Chromium /dev/shm + P8: 浏览器路径 | 使用 `mcr.microsoft.com/playwright/python` 预构建镜像 |
| noda-site serve -> nginx | P3: 端口不匹配 + P7: 安全头 | 保持端口 3000，最小 nginx 配置，安全头由外部 nginx 管理 |
| 多阶段构建优化 | P4: COPY 遗漏 + P12: 符号链接 | 先全量 COPY 验证，再逐步精简 |
| 基础镜像版本统一 | P11: postgres 版本不一致 | 统一为 `postgres:17-alpine` |
| 蓝绿部署验证 | P5: 镜像命名 | 每个镜像优化后运行完整 Pipeline |

---

## 优化优先级矩阵

基于风险和收益的分析：

| 优化项 | 预计体积节省 | 风险等级 | 实施复杂度 | 推荐顺序 |
|--------|------------|---------|-----------|---------|
| test-verify 统一 postgres:17-alpine | ~80MB（共享层） | 极低 | 极低（改一行） | 1 |
| noda-site serve -> nginx:alpine | ~120MB -> ~25MB | 中 | 中（端口+蓝绿+nginx配置） | 2 |
| noda-ops 审查 apk 依赖 | ~10-20MB | 低 | 低 | 3 |
| findclass-ssr 分离 Python 爬虫 | ~400MB（Chromium） | 高 | 高（新容器+网络+部署流程） | 4 |
| findclass-ssr 多阶段精简 node_modules | ~50-100MB | 中 | 中 | 5 |

---

## Sources

### HIGH confidence
- Dockerfile 完整审计：`deploy/Dockerfile.findclass-ssr`、`deploy/Dockerfile.noda-site`、`deploy/Dockerfile.noda-ops`、`deploy/Dockerfile.backup`、`scripts/backup/docker/Dockerfile.test-verify`
- Docker Compose 配置审计：`docker/docker-compose.app.yml`、`docker/docker-compose.yml`
- nginx 配置审计：`config/nginx/conf.d/default.conf`、`config/nginx/snippets/upstream-*.conf`
- Jenkins Pipeline 配置审计：`jenkins/Jenkinsfile.noda-site`
- 蓝绿部署脚本审计：`scripts/blue-green-deploy.sh`、`scripts/manage-containers.sh`、`scripts/blue-green-deploy-findclass.sh`
- [Context7: Docker 官方文档 -- Alpine 镜像兼容性](https://docs.docker.com/) -- musl vs glibc 差异、manylinux 兼容性说明，HIGH confidence
- [Context7: Docker 官方文档 -- 多阶段构建](https://docs.docker.com/) -- COPY --from 最佳实践，HIGH confidence
- [Context7: Docker 官方文档 -- glibc 和 musl 选择指南](https://docs.docker.com/) -- 明确推荐 Python + 原生依赖使用 glibc 镜像，HIGH confidence
- pip wheel 兼容性实测（`pip download --platform musllinux`）-- lxml/orjson/greenlet 最新版本无 musllinux wheel，HIGH confidence

### MEDIUM confidence
- Chromium Docker read_only 兼容性 -- 基于训练知识和 Playwright 文档，未通过 WebSearch 验证
- patchright `PLAYWRIGHT_BROWSERS_PATH=0` 行为 -- 基于 Dockerfile 注释（"对 patchright 无效"），实际行为未独立验证
- Alpine musl DNS 解析差异影响范围 -- 基于训练知识，Docker 内部 DNS 影响可能被低估

### LOW confidence
- 具体镜像体积数值（如 node:22-alpine ~130MB）-- 未在目标服务器上实测，不同架构和版本有差异

---
*Pitfalls research for: Noda v1.10 Docker 镜像瘦身优化*
*Researched: 2026-04-20*
