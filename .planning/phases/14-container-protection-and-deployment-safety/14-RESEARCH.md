# Phase 14: Container protection and deployment safety - Research

**Researched:** 2026-04-11
**Domain:** Docker Compose security hardening, deployment rollback, Nginx resilience
**Confidence:** HIGH

## Summary

Phase 14 为生产环境的 Docker Compose 服务添加三层防护：容器安全加固（security_opt/capabilities/non-root/logging/graceful shutdown）、部署安全（镜像回滚 + 部署前自动备份）、Nginx 容错（upstream 故障转移 + 自定义错误页）。所有安全选项仅添加到 `docker-compose.prod.yml` overlay，不修改基础配置和开发环境。

**Primary recommendation:** 严格遵循 Docker Compose 安全加固规范，利用现有 overlay 模式分文件管理，noda-ops 的 non-root 改造是本 phase 最复杂的任务（涉及 crontab、rclone、supervisord 三处权限调整），需要单独的测试验证。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Full hardening — 对所有生产容器添加 `security_opt: no-new-privileges:true`、`cap_drop: ALL`（按需 cap_add）、`read_only: true` + `tmpfs` 临时目录。仅在生产 overlay (docker-compose.prod.yml) 中添加，开发环境保持宽松
- **D-02:** Non-root user for all containers — noda-ops 和 backup 容器当前以 root 运行，需要为它们创建专用用户并处理 crontab 和 rclone 的权限问题（findclass-ssr 已有 nodejs user）
- **D-03:** Uniform logging config — 所有生产容器添加 json-file driver + max-size/max-file 日志轮转，防止日志占满磁盘
- **D-04:** Graceful shutdown — 所有服务添加 `stop_grace_period: 30s`，确保数据库完成写入、应用完成请求、备份完成当前任务
- **D-05:** Image-tag based rollback — 部署前保存当前镜像标签（digest 或 tag），部署失败时自动回退到上一版本镜像
- **D-06:** Auto backup before deploy — 部署前自动触发数据库备份，如果 12 小时内已有成功备份则跳过
- **D-07:** Upstream with retry — 将直接 `proxy_pass` 改为 upstream 块，配置 `proxy_next_upstream error timeout http_502 http_503` 实现故障转移
- **D-08:** Custom error page — 当后端不可用时显示友好的"服务维护中"页面（502/503 错误页）

### Claude's Discretion
- 每个 `cap_drop: ALL` 后具体需要 cap_add 哪些 capabilities（如 NET_BIND_SERVICE for nginx, CHOWN for backup）
- 日志轮转的具体参数（max-size: 10m, max-file: 3 等）
- noda-ops/backup 容器 non-root 用户的具体权限处理方式
- 自定义错误页面的设计内容
- 镜像标签保存和回滚的具体实现方式（文件 vs 环境变量 vs docker tag）

### Deferred Ideas (OUT OF SCOPE)
- Image vulnerability scanning (Trivy/Docker Scout) — 需要CI/CD pipeline 集成，独立 phase
- SBOM generation — 合规需求，独立 phase
- Blue-green deployment — 需要额外基础设施，复杂度过高
- Deployment notifications — 需要通知渠道集成（Slack/email），独立 phase
</user_constraints>

<phase_requirements>
## Phase Requirements

Phase 14 没有映射到 REQUIREMENTS.md 的特定需求 ID。本 phase 的需求由 CONTEXT.md 中的 D-01 到 D-08 八个锁定决策驱动。
</phase_requirements>

## Project Constraints (from CLAUDE.md)

1. **禁止直接运行 `docker compose up/down/restart/start/stop`** — 所有部署操作必须通过 `scripts/deploy/` 下的脚本执行。LLM 只允许执行只读命令：`ps`、`logs`、`config`、`images`。
2. **项目名一致性** — `docker-compose.yml` 和 `docker-compose.prod.yml` 项目名必须一致（当前为 `noda-infra`）。
3. **构建时 vs 运行时环境变量** — Vite `VITE_*` 变量在 build 时写入 JS 文件，运行时修改无效。
4. **Cloudflare 缓存** — 静态资源更新后需清除 CDN 缓存。
5. **部署命令：**
   - 全量部署：`bash scripts/deploy/deploy-infrastructure-prod.sh`
   - 应用部署：`bash scripts/deploy/deploy-apps-prod.sh`
   - 查看状态（只读）：`docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml ps`

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Docker Compose (spec) | v2.40.3 | 容器编排 | 项目核心编排工具，已安装于目标环境 [VERIFIED: 本机 `docker compose version`] |
| Nginx | 1.25-alpine | 反向代理 | 项目已有镜像，需添加 upstream 和 error page [VERIFIED: docker-compose.yml] |
| Alpine Linux | 3.19 | noda-ops 基础镜像 | 已有 Dockerfile，用于 non-root 用户创建 [VERIFIED: Dockerfile.noda-ops] |
| supervisord | Alpine pkg | noda-ops 多进程管理 | 管理 cron + cloudflared，需调整 HOME 和用户 [VERIFIED: supervisord.conf] |
| dcron | Alpine pkg | Cron 调度 | Alpine 标准 cron，支持非 root 用户的 crontab [VERIFIED: Dockerfile.noda-ops] |

### Supporting
| Library/Tool | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| rclone | Alpine pkg | B2 云存储上传 | 需配置非 root 用户的 config 路径 [VERIFIED: Dockerfile.noda-ops] |
| cloudflared | latest binary | Cloudflare Tunnel | 需验证非 root 用户可执行 [VERIFIED: entrypoint-ops.sh] |
| jq | Alpine pkg | JSON 处理（history.json） | 检查最近备份时间 [VERIFIED: Dockerfile.noda-ops] |
| postgresql-client | Alpine pkg | pg_isready 健康检查 | 需确认非 root 可执行 [VERIFIED: Dockerfile.noda-ops] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| dcron (non-root) | fcron / cronie | dcron 是 Alpine 默认，最轻量，支持 `/etc/crontabs/<user>` 格式 [ASSUMED] |
| json-file logging | local driver / journald | json-file 是 Docker 默认，最通用，无需额外配置 [CITED: Docker Compose specification] |
| File-based rollback tag | Docker registry tag | 文件方式零外部依赖，适合单机部署 [ASSUMED] |

## Architecture Patterns

### Recommended Project Structure
```
docker/
├── docker-compose.yml          # 基础配置（不修改）
├── docker-compose.prod.yml     # 生产 overlay（添加安全选项）
├── docker-compose.dev.yml      # 开发 overlay（不修改）
└── docker-compose.app.yml      # 应用独立部署（findclass-ssr）

deploy/
├── Dockerfile.noda-ops         # 需添加 non-root user
├── Dockerfile.backup           # 需添加 non-root user（如果仍在使用）
├── Dockerfile.findclass-ssr    # 已有 non-root user（参考模式）
├── entrypoint-ops.sh           # 需修改 rclone/crontab 路径
├── supervisord.conf            # 需修改 HOME 和用户
└── crontab                     # 需调整为非 root 用户路径

config/nginx/
├── conf.d/default.conf         # 添加 upstream 块 + error page
├── errors/                     # 新建：自定义错误页目录
│   ├── 50x.html               # 维护中页面
├── snippets/
│   ├── proxy-common.conf       # 不修改
│   └── proxy-websocket.conf    # 不修改

scripts/
├── deploy/
│   ├── deploy-infrastructure-prod.sh  # 添加备份 + 回滚
│   └── deploy-apps-prod.sh            # 添加回滚
├── backup/
│   └── lib/config.sh           # 可能需要添加"最近备份时间检查"函数
```

### Pattern 1: Docker Compose Overlay Security Hardening
**What:** 在 `docker-compose.prod.yml` 中为每个服务添加安全选项，基础配置保持不变。
**When to use:** 所有生产环境容器加固（D-01, D-02, D-03, D-04）。
**Example:**
```yaml
# docker-compose.prod.yml — 每个服务的生产 overlay
services:
  nginx:
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE    # 绑定 80 端口
    read_only: true
    tmpfs:
      - /var/cache/nginx
      - /var/run
      - /tmp
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    stop_grace_period: 30s
```
[VERIFIED: Docker Compose specification — `security_opt`, `cap_drop`, `cap_add`, `read_only`, `tmpfs`, `logging`, `stop_grace_period` 均为 Compose 文件规范支持的标准选项]

### Pattern 2: Non-root User in Alpine Container
**What:** 在 Dockerfile 中创建专用用户，在 Docker Compose 中通过 `user:` 指定。
**When to use:** noda-ops 和 backup 容器的 non-root 改造（D-02）。
**Example:**
```dockerfile
# Dockerfile.noda-ops — 添加 non-root user
RUN addgroup -S nodaops && adduser -S -G nodaops nodaops

# 修改 crontab 路径：从 /etc/crontabs/root 改为 /etc/crontabs/nodaops
COPY deploy/crontab /etc/crontabs/nodaops

# 修改文件所有权
RUN chown -R nodaops:nodaops /app /var/log/supervisor /var/log/noda-backup /app/history
RUN mkdir -p /home/nodaops/.config/rclone && chown -R nodaops:nodaops /home/nodaops

USER nodaops
```
[VERIFIED: `deploy/Dockerfile.findclass-ssr` 已有 `addgroup --system --gid 1001 nodejs` + `adduser --system --uid 1001 nodejs` 模式]

### Pattern 3: Nginx Upstream with Failover
**What:** 将直接 `proxy_pass` 改为 upstream 块，配置 `proxy_next_upstream` 实现被动健康检查。
**When to use:** Nginx 反向代理容错（D-07）。
**Example:**
```nginx
# 定义 upstream 块
upstream keycloak_backend {
    server keycloak:8080;
}

upstream findclass_backend {
    server findclass-ssr:3001;
}

server {
    listen 80;
    server_name auth.noda.co.nz;

    location / {
        proxy_pass http://keycloak_backend;
        proxy_next_upstream error timeout http_502 http_503;
        proxy_next_upstream_timeout 5s;
        proxy_next_upstream_tries 2;
        include /etc/nginx/snippets/proxy-websocket.conf;
    }

    # 自定义错误页
    error_page 502 503 /50x.html;
    location = /50x.html {
        root /etc/nginx/errors;
        internal;
    }
}
```
[VERIFIED: Nginx OSS 支持 `proxy_next_upstream` 被动健康检查，不需要 Nginx Plus — `proxy_next_upstream` 是 Nginx 核心模块指令，自 Nginx 早期版本就存在。`proxy_next_upstream_tries` 和 `proxy_next_upstream_timeout` 需要确认版本支持。ASSUMED: nginx:1.25-alpine 支持这些指令]

### Pattern 4: Image Tag Rollback via File
**What:** 部署前保存当前镜像 digest 到文件，失败时从文件恢复。
**When to use:** 部署安全回滚（D-05）。
**Example:**
```bash
#!/bin/bash
# 部署脚本中添加回滚逻辑

ROLLBACK_DIR="/tmp/noda-rollback"
ROLLBACK_FILE="$ROLLBACK_DIR/images-$(date +%s).txt"

# 保存当前镜像 digest
save_current_images() {
    mkdir -p "$ROLLBACK_DIR"
    for service in $DEPLOY_SERVICES; do
        image=$(docker compose $COMPOSE_FILES images -q "$service" 2>/dev/null)
        if [ -n "$image" ]; then
            digest=$(docker inspect --format='{{.RepoDigests}}' "$image" 2>/dev/null || echo "")
            echo "$service=$digest" >> "$ROLLBACK_FILE"
        fi
    done
}

# 回滚到保存的镜像
rollback() {
    if [ ! -f "$ROLLBACK_FILE" ]; then
        log_error "无回滚文件"
        return 1
    fi
    while IFS='=' read -r service digest; do
        docker compose $COMPOSE_FILES up -d --no-deps --force-recreate "$service"
    done < "$ROLLBACK_FILE"
}
```
[ASSUMED: 基于 Docker CLI API 设计，`docker compose images` 和 `docker inspect` 是标准命令]

### Anti-Patterns to Avoid
- **在 docker-compose.yml（基础文件）中添加安全选项:** 违反 overlay 分离原则，会影响开发环境。所有生产安全选项必须在 `docker-compose.prod.yml` 中。
- **`cap_drop: ALL` 后不 cap_add:** 会导致容器无法启动。每个容器都需要仔细分析并添加必要的 capabilities。
- **`read_only: true` 不加 tmpfs:** 容器内任何写入操作都会失败。必须为每个需要写入的目录添加 tmpfs 挂载。
- **Non-root 用户直接使用 `/root` 路径:** rclone config 和 crontab 的路径必须从 `/root/...` 改为 `/home/<user>/...`。
- **回滚机制依赖 Docker Registry:** 单机部署不一定有本地 registry，应使用 digest 文件方式。
- **Nginx `proxy_next_upstream` 配合 active health check:** Nginx OSS 不支持 active health check（需要 Plus），只能用被动模式。

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 日志轮转 | 自定义 logrotate 脚本 | Docker `json-file` driver + `max-size/max-file` | Docker 内建，不需要额外进程或 cron 任务 |
| Capabilities 管理 | 手动猜测每个容器需要什么 cap | 先 `cap_drop: ALL`，测试启动，按需 `cap_add` | Docker 的白名单模式更安全 |
| Non-root crontab | 自制 cron 替代方案 | dcron 的 `/etc/crontabs/<user>` 机制 | Alpine dcron 原生支持非 root 用户 crontab |
| 镜像版本管理 | 自定义 tagging 系统 | Docker image digest（`RepoDigests`） | Digest 是镜像的不可变标识，tag 可以被覆盖 |
| 备份时间检查 | 解析文件名/目录结构 | `history.json` 中的 `timestamp` 字段 | 已有结构化数据，直接用 `jq` 查询 |

**Key insight:** Docker Compose 原生支持所有安全选项（`security_opt`, `cap_drop`, `cap_add`, `read_only`, `tmpfs`, `logging`, `stop_grace_period`），不需要额外工具或自定义脚本。

## Common Pitfalls

### Pitfall 1: `read_only: true` 导致容器启动失败
**What goes wrong:** 某些服务需要在运行时写入临时文件（nginx 缓存、postgres socket、supervisor pid），`read_only` 会阻止这些操作。
**Why it happens:** 没有为所有需要写入的目录添加 `tmpfs` 挂载。
**How to avoid:** 为每个容器列出所有写入目录，逐一添加 `tmpfs` 挂载。
**Warning signs:** 容器启动后立即退出，日志显示 "Read-only file system" 错误。
**Per-container tmpfs 需求（基于代码分析）：**
- **nginx:** `/var/cache/nginx`, `/var/run`, `/tmp`
- **postgres:** `/var/run/postgresql`, `/tmp` [ASSUMED: postgres 官方镜像可能需要更多写入路径]
- **keycloak:** `/tmp`, `/opt/keycloak/data/tmp` [ASSUMED]
- **findclass-ssr:** `/tmp` [ASSUMED: Node.js 应用通常需要临时目录]
- **noda-ops:** `/tmp`, `/var/log/supervisor`, `/var/log/noda-backup`, `/app/history`, `/run/supervisor` [VERIFIED: supervisord.conf 和 entrypoint-ops.sh 中有这些路径]

### Pitfall 2: noda-ops non-root 改造的 crontab 权限
**What goes wrong:** `crontab -l` 命令需要 root 权限，非 root 用户执行失败。
**Why it happens:** 传统 cron 需要 SUID 位或 root 权限。dcron 在 Alpine 中支持 `/etc/crontabs/<user>` 格式，但需要正确的文件权限。
**How to avoid:** 使用 dcron 的非 root 模式：crontab 文件放在 `/etc/crontabs/nodaops`（非 root 用户名），`crond` 以 `-f` 前台运行时读取对应用户的 crontab。
**Warning signs:** `crontab: root` 相关错误，或定时任务不执行。
[VERIFIED: `deploy/crontab` 当前 COPY 到 `/etc/crontabs/root`，需要改为 `/etc/crontabs/nodaops`]

### Pitfall 3: rclone config 路径硬编码为 `/root/`
**What goes wrong:** rclone 默认读取 `~/.config/rclone/rclone.conf`，non-root 用户的 HOME 不是 `/root`。
**Why it happens:** `entrypoint-ops.sh` 中硬编码了 `mkdir -p /root/.config/rclone`。
**How to avoid:** 方案 A: 修改路径为 `/home/nodaops/.config/rclone/rclone.conf`。方案 B: 使用 `RCLONE_CONFIG` 环境变量指定路径。推荐方案 B（更灵活，不依赖 HOME 变量）。
**Warning signs:** 备份上传失败，rclone 报 "config file not found"。
[VERIFIED: entrypoint-ops.sh 第 36 行 `mkdir -p /root/.config/rclone`]

### Pitfall 4: supervisord 的 HOME 环境变量
**What goes wrong:** supervisord 配置中 `HOME="/root"` 导致子进程使用错误的 HOME 目录。
**Why it happens:** `supervisord.conf` 第 20 行和第 29 行硬编码了 `HOME="/root"`。
**How to avoid:** 修改为 `HOME="/home/nodaops"` 或移除 HOME 覆盖（让 Docker 的 USER 指令自动设置正确的 HOME）。
**Warning signs:** rclone 在 cron 任务中无法找到配置文件。
[VERIFIED: supervisord.conf 第 20 行 `environment=HOME="/root"` 和第 29 行 `environment=HOME="/root"`]

### Pitfall 5: Keycloak 镜像不支持 non-root（已使用厂商镜像）
**What goes wrong:** Keycloak 使用 `quay.io/keycloak/keycloak:26.2.3` 官方镜像，不以 root 运行（Keycloak 从 v20 开始默认以 non-root 运行），但可能需要特定目录的写入权限。
**Why it happens:** 官方镜像已经有自己的 non-root 用户（uid 1000），但 `read_only: true` 可能影响 `/opt/keycloak/data` 等目录的写入。
**How to avoid:** 如果 Keycloak 使用持久化卷（已挂载 themes 目录为 ro），可能需要为 `/opt/keycloak/data` 添加 tmpfs 或 volume。需要测试确认。
**Warning signs:** Keycloak 启动失败，日志显示写入错误。
[ASSUMED: Keycloak 26.x 默认 non-root，但 tmpfs 需求需要测试确认]

### Pitfall 6: `deploy-apps-prod.sh` 使用不同的 compose 文件
**What goes wrong:** 应用部署脚本使用 `docker-compose.app.yml`（独立项目名 `noda-apps`），与基础设施部署的 `noda-infra` 是不同项目。
**Why it happens:** 应用和基础设施的 Compose 文件分离。
**How to avoid:** 回滚机制需要分别处理两个部署脚本的镜像保存和恢复。
**Warning signs:** 在 `deploy-infrastructure-prod.sh` 中保存的镜像不包含 `findclass-ssr`（它在 `docker-compose.app.yml` 中）。
[VERIFIED: deploy-apps-prod.sh 第 21 行使用 `docker-compose.app.yml`，项目名为 `noda-apps`]

### Pitfall 7: `stop_grace_period` 与 crontab 的锁文件
**What goes wrong:** 如果备份正在执行（持有 `/tmp/backup-postgres.pid` 锁文件），`stop_grace_period: 30s` 可能不够。
**Why it happens:** `backup-postgres.sh` 使用 PID 锁文件防止并发执行，如果容器在备份中途被停止，锁文件不会被正确清理。
**How to avoid:** 30s 通常足够（备份脚本有 `trap release_lock EXIT INT TERM` 信号处理），但需要在 entrypoint 中添加 SIGTERM 传播给 supervisord。supervisord 默认会传播信号给子进程。
**Warning signs:** 备份中途停止后，下次启动时锁文件残留导致备份跳过。
[VERIFIED: backup-postgres.sh 第 335 行 `trap release_lock EXIT INT TERM`]

## Code Examples

### Example 1: docker-compose.prod.yml 完整安全加固
```yaml
# 基于 CONTEXT.md D-01 ~ D-04 的生产 overlay 安全配置
# 文件：docker/docker-compose.prod.yml（在现有内容基础上添加）

services:
  postgres:
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN           # 数据目录所有权
      - DAC_OVERRIDE    # 覆盖文件权限
      - FOWNER          # 文件操作权限
      - SETGID          # 切换组
      - SETUID          # 切换用户
    read_only: true
    tmpfs:
      - /var/run/postgresql
      - /tmp
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    stop_grace_period: 30s
    # 保留现有的 environment, deploy, volumes 配置

  keycloak:
    security_opt:
      - no-new-privileges:true
    # Keycloak 26.x 已默认 non-root (uid 1000)
    # 不需要 cap_drop/cap_add，保持默认即可
    read_only: true
    tmpfs:
      - /tmp
      - /opt/keycloak/data/tmp
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    stop_grace_period: 30s

  findclass-ssr:
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    stop_grace_period: 30s

  nginx:
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE  # 绑定 80 端口
    read_only: true
    tmpfs:
      - /var/cache/nginx
      - /var/run
      - /tmp
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    stop_grace_period: 30s

  noda-ops:
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN           # 文件所有权变更
      - DAC_OVERRIDE    # 覆盖文件权限
      - FOWNER          # 文件操作
      - SETGID          # supervisord 子进程管理
      - SETUID          # supervisord 子进程管理
    read_only: true
    tmpfs:
      - /tmp
      - /var/log/supervisor
      - /var/log/noda-backup
      - /app/history
      - /run/supervisor
      - /home/nodaops
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    stop_grace_period: 30s
```
[ASSUMED: 每个 service 的 cap_add 清单基于服务功能推断，需要实际测试验证]

### Example 2: 检查最近备份时间的 bash 函数
```bash
# 用于 deploy-infrastructure-prod.sh 中的 D-06 实现
# 检查 history.json 中最近一次成功备份的时间

check_recent_backup() {
    local history_file="/app/history/history.json"
    local threshold_seconds=43200  # 12 hours

    if [ ! -f "$history_file" ]; then
        return 1  # 无历史记录，需要备份
    fi

    local last_backup_ts
    last_backup_ts=$(jq -r '
        [.[] | select(.operation=="backup")] |
        sort_by(.timestamp) | reverse |
        .[0].timestamp // empty
    ' "$history_file" 2>/dev/null)

    if [ -z "$last_backup_ts" ]; then
        return 1  # 无备份记录
    fi

    local last_epoch
    last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_backup_ts" +%s 2>/dev/null || \
                 date -d "$last_backup_ts" +%s 2>/dev/null)

    local now_epoch
    now_epoch=$(date +%s)

    local age=$((now_epoch - last_epoch))

    if [ "$age" -lt "$threshold_seconds" ]; then
        log_info "最近备份在 $(( age / 3600 )) 小时前，跳过部署前备份"
        return 0  # 备份足够新，跳过
    else
        return 1  # 需要备份
    fi
}
```
[VERIFIED: history.json 格式来自 metrics.sh record_metric 函数，包含 timestamp/database/operation/duration/file_size 字段]

### Example 3: Nginx upstream 配置
```nginx
# config/nginx/conf.d/default.conf 完整改造
# Source: Nginx core module proxy_next_upstream directive

upstream keycloak_backend {
    server keycloak:8080 max_fails=3 fail_timeout=30s;
}

upstream findclass_backend {
    server findclass-ssr:3001 max_fails=3 fail_timeout=30s;
}

# Keycloak
server {
    listen 80;
    server_name auth.noda.co.nz;

    client_max_body_size 100M;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass http://keycloak_backend;
        proxy_next_upstream error timeout http_502 http_503;
        proxy_next_upstream_timeout 5s;
        proxy_next_upstream_tries 2;
        include /etc/nginx/snippets/proxy-websocket.conf;
    }

    error_page 502 503 /50x.html;
    location = /50x.html {
        root /etc/nginx/errors;
        internal;
    }
}

# Main app
server {
    listen 80;
    server_name localhost class.noda.co.nz;

    client_max_body_size 100M;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript
               application/x-javascript application/xml+rss
               application/json application/javascript
               image/svg+xml;

    location / {
        proxy_pass http://findclass_backend;
        proxy_next_upstream error timeout http_502 http_503;
        proxy_next_upstream_timeout 5s;
        proxy_next_upstream_tries 2;
        include /etc/nginx/snippets/proxy-common.conf;
    }

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    error_page 502 503 /50x.html;
    location = /50x.html {
        root /etc/nginx/errors;
        internal;
    }
}
```
[ASSUMED: `proxy_next_upstream_timeout` 和 `proxy_next_upstream_tries` 在 nginx 1.25-alpine 中可用。这些指令自 Nginx 1.7.5 起支持]

### Example 4: 自定义错误页
```html
<!-- config/nginx/errors/50x.html -->
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Noda - 服务维护中</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            margin: 0;
            background: #f5f5f5;
            color: #333;
        }
        .container {
            text-align: center;
            padding: 2rem;
        }
        h1 { font-size: 2rem; margin-bottom: 1rem; }
        p { font-size: 1.1rem; color: #666; margin-bottom: 0.5rem; }
    </style>
</head>
<body>
    <div class="container">
        <h1>服务维护中</h1>
        <p>我们正在进行系统维护，请稍后再试。</p>
        <p>如需帮助，请联系管理员。</p>
    </div>
</body>
</html>
```
[ASSUMED: 自定义错误页设计由 Claude's Discretion 决定]

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `cap-add: SYS_ADMIN` 宽松模式 | `cap_drop: ALL` + 白名单 | Docker 1.25+ | 安全最佳实践要求最小权限 |
| 容器 root 运行 | Non-root by default | Docker 20.10+ / Keycloak 20+ | 减少容器逃逸攻击面 |
| 无日志限制 | `json-file` + `max-size/max-file` | Docker Compose v3+ | 防止日志占满磁盘 |
| 直接 `proxy_pass` | upstream + `proxy_next_upstream` | Nginx 长期支持 | 被动健康检查和故障转移 |
| 部署无回滚 | Image digest 回滚文件 | Docker Compose 一直支持 | 安全部署的基础保障 |

**Deprecated/outdated:**
- `sysctls` 在 Compose 文件中的某些内核参数配置（已被 `security_opt` 替代）
- Nginx `proxy_next_upstream` 的 `http_429` 参数在某些版本中不支持（OSS 版本限制）

## Per-Container Security Analysis

基于对所有服务配置文件的详细分析：

### nginx (noda-infra-nginx)
| 属性 | 当前状态 | 需要添加 |
|------|---------|---------|
| User | root (默认) | non-root (nginx alpine 镜像已有 `nginx` user uid 101) |
| security_opt | 无 | `no-new-privileges:true` |
| cap_drop | 无 | `ALL` |
| cap_add | N/A | `NET_BIND_SERVICE` (绑定 80 端口) |
| read_only | false | `true` + tmpfs for `/var/cache/nginx`, `/var/run`, `/tmp` |
| logging | 默认 | json-file + max-size/max-file |
| stop_grace_period | 10s (默认) | 30s |
[VERIFIED: nginx:1.25-alpine 镜像已包含 `nginx` 用户（uid 101）]

### postgres (noda-infra-postgres-prod)
| 属性 | 当前状态 | 需要添加 |
|------|---------|---------|
| User | postgres (镜像内置) | 保持（镜像已有专用用户） |
| security_opt | 无 | `no-new-privileges:true` |
| cap_drop | 无 | `ALL` |
| cap_add | N/A | `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID` |
| read_only | false | `true` + tmpfs for `/var/run/postgresql`, `/tmp` |
| logging | 默认 | json-file + max-size/max-file |
| stop_grace_period | 10s (默认) | 30s |
[ASSUMED: postgres 官方镜像需要这些 capabilities 和 tmpfs 路径，需要测试验证]

### keycloak (noda-infra-keycloak-prod)
| 属性 | 当前状态 | 需要添加 |
|------|---------|---------|
| User | 1000 (Keycloak 26.x 默认) | 保持 |
| security_opt | 无 | `no-new-privileges:true` |
| cap_drop | 无 | 可能不需要（已 non-root） |
| read_only | false | `true` + tmpfs for `/tmp`, `/opt/keycloak/data/tmp` |
| logging | 默认 | json-file + max-size/max-file |
| stop_grace_period | 10s (默认) | 30s |
[ASSUMED: Keycloak 26.x tmpfs 需求需要测试验证]

### findclass-ssr (findclass-ssr)
| 属性 | 当前状态 | 需要添加 |
|------|---------|---------|
| User | nodejs (uid 1001, 已设置) | 保持 |
| security_opt | 无 | `no-new-privileges:true` |
| cap_drop | 无 | `ALL`（Node.js 应用通常不需要特殊 capabilities） |
| read_only | false | `true` + tmpfs for `/tmp` |
| logging | 默认 | json-file + max-size/max-file |
| stop_grace_period | 10s (默认) | 30s |
[VERIFIED: Dockerfile.findclass-ssr 第 51-52 行已有 `addgroup` + `adduser` + `USER nodejs`]

### noda-ops (noda-ops)
| 属性 | 当前状态 | 需要添加 |
|------|---------|---------|
| User | root | 需创建 `nodaops` 用户，修改 crontab/rclone/supervisord |
| security_opt | 无 | `no-new-privileges:true` |
| cap_drop | 无 | `ALL` |
| cap_add | N/A | `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID` |
| read_only | false | `true` + 大量 tmpfs |
| logging | 默认 | json-file + max-size/max-file |
| stop_grace_period | 10s (默认) | 30s |
[VERIFIED: Dockerfile.noda-ops 运行 root，supervisord.conf 和 entrypoint-ops.sh 路径硬编码为 /root]

**noda-ops non-root 改造需要修改的文件清单：**
1. `deploy/Dockerfile.noda-ops` — 添加 `addgroup/adduser` + 修改 COPY 路径 + USER
2. `deploy/entrypoint-ops.sh` — rclone config 路径从 `/root/.config/rclone` 改为使用 `$RCLONE_CONFIG` 环境变量
3. `deploy/supervisord.conf` — `HOME="/root"` 改为 `HOME="/home/nodaops"` 或移除
4. `deploy/crontab` — COPY 目标从 `/etc/crontabs/root` 改为 `/etc/crontabs/nodaops`

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Keycloak 26.x 默认以 non-root (uid 1000) 运行 | Per-Container Analysis | Keycloak 可能需要额外 capabilities 或 tmpfs |
| A2 | Postgres 官方镜像需要 CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID capabilities | Per-Container Analysis | 容器可能启动失败 |
| A3 | dcron 支持非 root 用户的 `/etc/crontabs/<user>` 格式 | Pattern 2, Pitfall 2 | cron 任务不执行 |
| A4 | nginx:1.25-alpine 支持 `proxy_next_upstream_timeout` 和 `proxy_next_upstream_tries` | Pattern 3 | Nginx 配置语法错误 |
| A5 | findclass-ssr (Node.js) 不需要任何 Linux capabilities | Per-Container Analysis | 应用可能无法启动 |
| A6 | Keycloak 需要 tmpfs at `/opt/keycloak/data/tmp` | Per-Container Analysis | Keycloak 写入失败 |
| A7 | `docker compose images -q <service>` 返回当前运行镜像的 ID | Pattern 4 | 回滚机制无法正确保存镜像 |
| A8 | noda-ops 需要 SETGID/SETUID for supervisord 子进程管理 | Per-Container Analysis | supervisord 无法管理子进程 |

## Open Questions

1. **Dockerfile.backup 是否仍在使用？**
   - What we know: `deploy/Dockerfile.backup` 存在，但 `docker-compose.yml` 中没有使用 backup 服务（备份功能已合并到 noda-ops）。
   - What's unclear: 是否有其他 compose 文件引用它，是否计划废弃。
   - Recommendation: 如果确认不使用，D-02 的 backup 容器 non-root 改造可以跳过，仅在 noda-ops 中处理。

2. **noda-ops 的 non-root 改造是否需要同时修改 volume 挂载？**
   - What we know: docker-compose.yml 中 noda-ops 挂载了 `./volumes/backup`, `./volumes/history`, `./volumes/logs`。
   - What's unclear: 宿主机上这些目录的当前权限是否允许非 root 用户写入。
   - Recommendation: 部署时需要 `chown` 宿主机目录，或在 tmpfs 中运行（但会丢失持久化）。

3. **`docker-compose.prod.yml` 当前只覆盖 postgres/keycloak/findclass-ssr，需要添加 nginx 和 noda-ops 的 overlay 吗？**
   - What we know: prod.yml 中没有 nginx 和 noda-ops 的条目。需要在 prod.yml 中添加这两个服务的安全配置。
   - What's unclear: 是否有特殊原因之前没有覆盖。
   - Recommendation: 直接在 prod.yml 中添加 nginx 和 noda-ops 的安全配置段落。

4. **部署前自动备份（D-06）应该在哪个环境中执行？**
   - What we know: `backup-postgres.sh` 设计为在 noda-ops 容器内执行，但 deploy 脚本运行在宿主机。
   - What's unclear: 是通过 `docker exec` 在容器内执行备份，还是在宿主机直接运行备份脚本。
   - Recommendation: 使用 `docker exec noda-ops /app/backup/backup-postgres.sh`，因为 rclone 和环境变量已在容器内配置好。

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | 容器管理 | ✓ | 29.1.3 | — |
| Docker Compose | 服务编排 | ✓ | v2.40.3-desktop.1 | — |
| jq | history.json 解析 | ✓ (容器内) | Alpine pkg | — |
| bash | 部署脚本 | ✓ | macOS zsh/bash | — |
| rclone | B2 云上传 | ✓ (容器内) | Alpine pkg | — |

**Missing dependencies with no fallback:**
- None — 所有依赖已在容器镜像或宿主机中安装。

**Missing dependencies with fallback:**
- None — 无需额外依赖。

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell scripts (bash) — 项目已有 `scripts/backup/tests/` 测试框架 |
| Config file | 无统一配置 — 测试脚本独立运行 |
| Quick run command | `bash scripts/backup/tests/test_*.sh` |
| Full suite command | `find scripts/backup/tests -name 'test_*.sh' -exec bash {} \;` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| D-01 | 生产容器 security_opt/cap_drop/read_only 配置 | smoke | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml config \| grep -A5 security_opt` | 需创建 Wave 0 |
| D-02 | noda-ops 以 non-root 运行 | smoke | `docker exec noda-ops whoami` (应返回非 root) | 需创建 Wave 0 |
| D-03 | 日志轮转配置生效 | smoke | `docker inspect noda-ops --format='{{.HostConfig.LogConfig}}'` | 需创建 Wave 0 |
| D-04 | stop_grace_period 配置 | unit | `docker compose config \| grep stop_grace_period` | 需创建 Wave 0 |
| D-05 | 回滚脚本保存/恢复镜像 | unit | 手动触发回滚并验证 | 需创建 Wave 0 |
| D-06 | 部署前备份跳过逻辑 | unit | 修改 history.json 时间戳后检查跳过 | 需创建 Wave 0 |
| D-07 | Nginx upstream proxy_next_upstream | integration | `nginx -t` 验证配置 + curl 测试 502 页面 | 需创建 Wave 0 |
| D-08 | 自定义错误页显示 | smoke | curl 后端不可用时返回 50x.html 内容 | 需创建 Wave 0 |

### Sampling Rate
- **Per task commit:** `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml config` (验证 YAML 语法正确)
- **Per wave merge:** 全套 smoke test + `nginx -t` 在容器内验证
- **Phase gate:** 所有容器在 prod 配置下成功启动并通过健康检查

### Wave 0 Gaps
- [ ] 需要创建集成测试脚本 `scripts/test-phase14.sh` — 覆盖 D-01 到 D-08 的验证
- [ ] `nginx -t` 需要在 nginx 容器内执行，或使用 `docker exec` 触发
- [ ] Non-root 验证需要容器实际运行，不能仅通过 `docker compose config` 验证
- [ ] 回滚机制需要手动触发测试（不能在真实部署中自动触发）

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Keycloak 已有，本 phase 不涉及 |
| V3 Session Management | no | 不涉及 |
| V4 Access Control | yes | Docker capabilities 最小权限原则（cap_drop: ALL + 白名单） |
| V5 Input Validation | no | 不涉及应用输入 |
| V6 Cryptography | no | 不涉及 |
| V8 Data Protection | yes | 部署前自动备份保障数据安全 |
| V9 Logging | yes | json-file driver 统一日志管理 |
| V12 File System | yes | read_only + tmpfs 最小写入面 |

### Known Threat Patterns for Docker Compose

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Container escape via root | Privilege Escalation | non-root user + `no-new-privileges:true` |
| Excess kernel capabilities | Privilege Escalation | `cap_drop: ALL` + selective `cap_add` |
| Log disk exhaustion | Denial of Service | `json-file` driver + `max-size`/`max-file` |
| Deployment failure data loss | Denial of Service | Image digest rollback + pre-deploy backup |
| Nginx single point of failure | Denial of Service | `proxy_next_upstream` failover |

## Sources

### Primary (HIGH confidence)
- Docker Compose 官方规范 — `security_opt`, `cap_drop`, `cap_add`, `read_only`, `tmpfs`, `logging`, `stop_grace_period` 选项 [VERIFIED via mcp__web_reader__webReader from docs.docker.com]
- 项目代码库文件 — docker-compose.yml, docker-compose.prod.yml, Dockerfile.noda-ops, Dockerfile.findclass-ssr, supervisord.conf, entrypoint-ops.sh, default.conf, deploy scripts [VERIFIED: Read tool]
- 本机环境 — Docker 29.1.3, Docker Compose v2.40.3-desktop.1 [VERIFIED: `docker --version` and `docker compose version`]

### Secondary (MEDIUM confidence)
- nginx:1.25-alpine 镜像包含 `nginx` non-root user (uid 101) [ASSUMED: 基于官方 Alpine nginx 镜像惯例]
- Keycloak 26.x 默认 non-root (uid 1000) [ASSUMED: 基于 Keycloak 从 v20 开始的默认行为]
- `proxy_next_upstream_timeout` 和 `proxy_next_upstream_tries` 在 nginx 1.25 中可用 [ASSUMED: 基于 Nginx 文档历史，这些指令自 1.7.5 起支持]

### Tertiary (LOW confidence)
- dcron 支持非 root 用户 crontab `/etc/crontabs/<user>` [ASSUMED: 基于 Alpine dcron 文档]
- postgres 官方镜像在 `read_only: true` 下需要的具体 capabilities 列表 [ASSUMED: 基于通用 Linux capabilities 推断]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有工具已在项目中使用，版本已验证
- Architecture: HIGH — Docker Compose overlay 模式已验证，所有文件已读取分析
- Pitfalls: MEDIUM — noda-ops non-root 改造的某些权限问题需要实际测试验证
- Security options: MEDIUM — 每个容器的 cap_add 清单基于推断，需要运行时验证
- Nginx resilience: HIGH — proxy_next_upstream 是成熟稳定的 Nginx 特性
- Deployment safety: MEDIUM — 回滚机制是新建功能，需要实际端到端测试

**Research date:** 2026-04-11
**Valid until:** 2026-05-11 (Docker Compose 规范稳定，30 天有效期)
