# Phase 52: 基础设施镜像清理 - Research

**Researched:** 2026-04-21
**Domain:** Docker 多阶段构建 + 镜像精简
**Confidence:** HIGH

## Summary

本阶段的核心工作是将 `noda-ops` Dockerfile 从单阶段构建改为多阶段构建（builder pattern），将 `wget` 和 `gnupg` 隔离在构建阶段，运行时镜像仅包含必需二进制文件。同时合并 `backup` Dockerfile 的多个 RUN 指令减少层数。

研究已通过代码审计确认：`curl` 在 noda-ops 的所有运行时脚本中均未被直接调用（仅存在于 Dockerfile 的 `apk add` 中），可安全移除。`jq` 被 alert.sh、db.sh、metrics.sh、verify.sh 广泛使用。`coreutils` 被 db.sh 中的 `numfmt --to=iec` 使用（GNU coreutils 独有，BusyBox 不含）。所有其他运行时依赖（bash、rclone、dcron、supervisor、ca-certificates、postgresql17-client、age）均有明确用途。

**Primary recommendation:** 使用多阶段构建，builder 阶段安装 wget/gnupg 下载 cloudflared 二进制和 doppler CLI，运行时阶段 `FROM alpine:3.21` 只安装运行必需的包 + COPY 二进制。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** noda-ops Dockerfile 改为多阶段构建（builder pattern），wget 和 gnupg 隔离在构建阶段，运行时镜像不含这两个包
- **D-02:** 构建阶段安装 wget/gnupg，用于下载 cloudflared 二进制和 doppler CLI（含 GPG key 验证），完成后通过 COPY --from=builder 仅传递二进制文件
- **D-03:** 运行时阶段重新 FROM alpine:3.21，只安装运行时必需的包：bash、jq、coreutils、rclone、dcron、supervisor、ca-certificates、postgresql17-client、age、doppler（二进制直接 COPY）
- **D-04:** 移除 curl — backup 脚本中未发现直接调用，健康检查使用 pg_isready，cloudflared/doppler 自带网络能力
- **D-05:** 保留 jq — alert.sh、db.sh、metrics.sh、verify.sh 大量使用（JSON 解析）
- **D-06:** 保留 coreutils — db.sh 使用 numfmt（GNU coreutils 独有，BusyBox 不含）
- **D-07:** 保留其他所有运行时依赖（bash、rclone、dcron、supervisor、ca-certificates、postgresql17-client、age）
- **D-08:** 合并 backup Dockerfile 的 4 个 RUN 指令为 1 个 RUN（apk add + mkdir + touch + chmod 全部合并），减少镜像层数
- **D-09:** 保留现有 COPY 指令不变（Phase 48 已优化 COPY --chown）

### Claude's Discretion
- 多阶段构建的具体 Dockerfile 结构（构建阶段的包列表、文件路径）
- RUN 指令合并的具体顺序和格式
- 是否同时优化 test-verify Dockerfile（如果发现可改进点）

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| INFRA-01 | noda-ops 依赖审计（确认 wget/gnupg/coreutils 运行时是否必需，非必需移到构建阶段） | 代码审计确认 curl 可移除、wget 仅用于构建时下载、gnupg 仅用于 doppler GPG 验证、coreutils 运行时必需 |
| INFRA-02 | backup Dockerfile 清理（移除冗余层、统一 RUN 指令、添加 .dockerignore） | 当前 4 个 RUN 可合并为 1 个；curl 也可移除；.dockerignore 已在 Phase 48 创建 |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| noda-ops Dockerfile 多阶段构建 | Docker 构建 | - | 纯构建时优化，不改变运行时行为 |
| backup Dockerfile 层合并 | Docker 构建 | - | 纯构建时优化，不改变运行时行为 |
| 运行时依赖验证 | 容器运行时 | - | 需验证脚本在新镜像中正常工作 |
| 备份/健康检查功能验证 | 容器运行时 | - | 核心功能不能因镜像精简而受影响 |

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Alpine Linux | 3.21 | noda-ops 基础镜像 | 项目现有基础镜像，轻量（~5MB），与现有脚本兼容 [VERIFIED: Dockerfile.noda-ops] |
| PostgreSQL Alpine | 17-alpine | backup 基础镜像 | 提供 pg_dump/pg_restore/pg_isready，与生产 PostgreSQL 版本一致 [VERIFIED: Dockerfile.backup] |
| Docker BuildKit | 内置 | 多阶段构建引擎 | Docker 23+ 默认启用，支持 COPY --from=builder [ASSUMED] |

### Supporting
| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| cloudflared | latest (2026.3.0) | Cloudflare Tunnel 客户端 | 运行时必需，从 builder 阶段 COPY [VERIFIED: GitHub API] |
| Doppler CLI | latest (3.75.3) | 密钥管理 | 运行时必需，从 builder 阶段 COPY [VERIFIED: GitHub API] |
| jq | Alpine apk | JSON 解析 | alert.sh/metrics.sh/db.sh 依赖 [VERIFIED: codebase grep] |
| coreutils (GNU) | Alpine apk | numfmt 等工具 | db.sh 依赖 numfmt 格式化大小 [VERIFIED: db.sh:353] |

## Architecture Patterns

### System Architecture Diagram

```
noda-ops 多阶段构建数据流:

Stage 1: builder (alpine:3.21)
    │
    ├─ apk add wget gnupg (临时安装)
    │
    ├─ wget → /usr/local/bin/cloudflared
    │   (从 GitHub releases 下载二进制)
    │
    └─ wget + apk add doppler → /usr/bin/doppler
        (从 Doppler 官方仓库下载，含 GPG key 验证)
    │
    ▼ COPY --from=builder (仅传递二进制文件)
    │
Stage 2: runner (alpine:3.21 全新基础)
    │
    ├─ apk add: bash, jq, coreutils, rclone, dcron,
    │            supervisor, ca-certificates,
    │            postgresql17-client, age
    │
    ├─ COPY: cloudflared, doppler (从 builder)
    │
    ├─ COPY: 脚本、配置、crontab (从构建上下文)
    │
    └─ USER nodaops → CMD entrypoint.sh
```

```
backup Dockerfile 优化:

当前 (4 RUN):
    RUN apk add ... ──┐
    RUN chmod +x ...  ├─→ 合并为 1 RUN
    RUN mkdir + touch ├──→ apk add + mkdir + chmod
    RUN mkdir         ┘

优化后 (1 RUN):
    RUN apk add ... && \
        mkdir -p ... && \
        touch ... && \
        chmod ...
```

### Recommended Project Structure
```
deploy/
├── Dockerfile.noda-ops     # 主要优化目标: 多阶段构建
├── Dockerfile.backup       # 层合并目标: RUN 合并
├── Dockerfile.noda-site    # 参考: 已有多阶段构建模式 (Phase 47)
├── Dockerfile.findclass-ssr # 不涉及
├── entrypoint-ops.sh       # noda-ops 启动脚本（不修改）
├── entrypoint.sh           # backup 启动脚本（不修改）
├── crontab                 # 定时任务（不修改）
└── supervisord.conf        # 进程管理（不修改）
```

### Pattern 1: Alpine 多阶段构建（下载外部二进制）
**What:** builder 阶段安装临时下载工具，下载完成后仅传递二进制到运行时阶段
**When to use:** 当运行时镜像不需要下载工具但需要外部二进制时
**Example:**
```dockerfile
# Stage 1: 构建阶段
FROM alpine:3.21 AS builder

# 安装临时下载工具
RUN apk add --no-cache wget gnupg

# 下载 cloudflared
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then CLOUDFLARED_ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ]; then CLOUDFLARED_ARCH="arm64"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}" \
         -O /usr/local/bin/cloudflared && \
    chmod +x /usr/local/bin/cloudflared

# 下载 Doppler CLI
RUN wget -q -t3 'https://packages.doppler.com/public/cli/rsa.8004D9FF50437357.key' \
       -O /etc/apk/keys/cli@doppler-8004D9FF50437357.rsa.pub && \
    echo 'https://packages.doppler.com/public/cli/alpine/any-version/main' | \
      tee -a /etc/apk/repositories && \
    apk add doppler

# Stage 2: 运行时阶段
FROM alpine:3.21

# 只安装运行时必需的包（无 wget/gnupg/curl）
RUN apk add --no-cache \
    bash \
    jq \
    coreutils \
    rclone \
    dcron \
    supervisor \
    ca-certificates \
    postgresql17-client \
    age

# 从 builder 传递二进制文件
COPY --from=builder /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY --from=builder /usr/bin/doppler /usr/bin/doppler

# ... 其余指令不变
```
*Source: 基于 Docker 多阶段构建官方文档 [ASSUMED], 项目现有 Dockerfile.noda-site (Phase 47) 模式 [VERIFIED]*

### Pattern 2: RUN 指令合并
**What:** 将多个相关 RUN 指令合并为一个，减少镜像层数
**When to use:** Dockerfile 中有多个顺序执行的 RUN，且中间状态不需要缓存
**Example:**
```dockerfile
# Before: 4 个 RUN
RUN apk add --no-cache bash curl jq ...
RUN chmod +x /app/entrypoint.sh
RUN mkdir -p /var/log/noda-backup && touch ... && chmod ...
RUN mkdir -p /app/history

# After: 1 个 RUN
RUN apk add --no-cache bash jq coreutils rclone dcron ca-certificates && \
    mkdir -p /var/log/noda-backup /app/history && \
    touch /var/log/noda-backup/backup.log /var/log/noda-backup/test.log && \
    chmod 666 /var/log/noda-backup/*.log && \
    chmod +x /app/entrypoint.sh
```

### Anti-Patterns to Avoid
- **在运行时阶段保留构建工具:** wget/gnupg 仅在构建阶段使用，不能泄漏到运行时。Docker 多阶段构建自动丢弃构建阶段的文件系统，但必须确保 COPY --from=builder 只传递目标二进制
- **合并不相关的 RUN 指令:** 如果两个 RUN 指令的变更频率差异很大（如系统包安装 vs 应用代码复制），分开可以更好利用 Docker 层缓存。但 backup Dockerfile 的所有 RUN 都是初始化性质的，变更频率相同，合并合理
- **忘记 COPY --chmod 权限:** cloudflared 二进制需要在 COPY 后保持 +x 权限。当前方案在 builder 阶段已 `chmod +x`，COPY 会保留权限 [ASSUMED]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| GPG key 验证 | 自定义签名校验脚本 | gnupg + Doppler 官方仓库 | 已有成熟流程，官方仓库保证完整性 [VERIFIED: 现有 Dockerfile] |
| 大小格式化 | 自定义字节格式化函数 | GNU coreutils numfmt | db.sh 已使用 numfmt --to=iec，BusyBox 无此功能 [VERIFIED: db.sh:353] |
| JSON 解析 | 自定义 JSON 解析 | jq | alert.sh/metrics.sh/db.sh/verify.sh 全部依赖 jq [VERIFIED: codebase grep] |

## Common Pitfalls

### Pitfall 1: Doppler CLI 路径不确定
**What goes wrong:** Doppler 通过 `apk add` 安装后，二进制路径可能不是 `/usr/bin/doppler`
**Why it happens:** Alpine 包管理器将二进制安装到不同位置
**How to avoid:** 在 builder 阶段使用 `which doppler` 或 `command -v doppler` 确认路径，或使用 `ls -la /usr/bin/doppler` 验证
**Warning signs:** COPY --from=builder 步骤报 "file not found"
**缓解方案:** 在 builder 阶段末尾添加 `RUN ls -la /usr/bin/doppler /usr/local/bin/cloudflared` 验证路径

### Pitfall 2: Doppler CLI 的 apk 包依赖
**What goes wrong:** Doppler apk 包可能有共享库依赖，直接 COPY 二进制可能缺少 .so 文件
**Why it happens:** `apk add doppler` 安装的不只是一个二进制文件
**How to avoid:** 两种方案：(a) 使用 `ldd /usr/bin/doppler` 检查动态链接依赖，确保运行时包含所需 .so；(b) 改用从 GitHub releases 直接下载静态编译的二进制 tarball
**Warning signs:** 容器启动时 doppler 报 "not found" 或 "shared library" 错误
**缓解方案:** 推荐方案 (b)：从 GitHub releases 下载 tarball（`doppler_3.75.3_linux_amd64.tar.gz`），解压得到静态二进制，COPY 更可靠 [VERIFIED: GitHub API 确认有 tarball 格式]

### Pitfall 3: backup Dockerfile 合并后 curl 丢失
**What goes wrong:** backup Dockerfile 当前安装了 curl，如果在合并 RUN 时移除 curl，可能影响某些未审计的脚本
**Why it happens:** 脚本审计可能遗漏某些边缘调用
**How to avoid:** 已通过 grep 确认 backup 脚本中无 curl 调用，但 backup Dockerfile 不属于本 phase 的 curl 移除范围（D-04 仅针对 noda-ops）。backup Dockerfile 可考虑一并移除 curl
**Warning signs:** backup 容器中某脚本执行报 "curl: not found"

### Pitfall 4: 多阶段构建后 HEALTHCHECK 依赖缺失
**What goes wrong:** HEALTHCHECK 使用 pg_isready，如果 postgresql17-client 在运行时阶段未正确安装，健康检查会失败
**Why it happens:** 多阶段构建重写 Dockerfile 时可能遗漏运行时包
**How to avoid:** 确保 D-03 中列出的所有运行时包都出现在第二阶段的 `apk add` 中
**Warning signs:** 容器启动后持续报告 unhealthy

### Pitfall 5: crond 权限问题
**What goes wrong:** 现有 Dockerfile 有 `RUN chmod 755 /usr/sbin/crond` 确保非 root 用户可执行。多阶段构建后此步骤必须在运行时阶段
**Why it happens:** crond 权限修改是针对运行时文件系统的
**How to avoid:** 确保 `chmod 755 /usr/sbin/crond` 出现在运行时阶段（在 `apk add dcron` 之后）

## Code Examples

### noda-ops 多阶段构建完整 Dockerfile 模板
```dockerfile
# ============================================
# Noda Ops - 运维工具集容器（多阶段构建）
# ============================================
# Stage 1: 构建阶段 - 下载外部二进制
# Stage 2: 运行时阶段 - 最小依赖
# ============================================

# --- Stage 1: 构建阶段 ---
FROM alpine:3.21 AS builder

# 安装构建时下载工具
RUN apk add --no-cache wget gnupg

# 下载 cloudflared 二进制
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then CLOUDFLARED_ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ]; then CLOUDFLARED_ARCH="arm64"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}" \
         -O /usr/local/bin/cloudflared && \
    chmod +x /usr/local/bin/cloudflared && \
    cloudflared --version

# 下载 Doppler CLI（通过官方 apk 仓库 + GPG 验证）
RUN wget -q -t3 'https://packages.doppler.com/public/cli/rsa.8004D9FF50437357.key' \
       -O /etc/apk/keys/cli@doppler-8004D9FF50437357.rsa.pub && \
    echo 'https://packages.doppler.com/public/cli/alpine/any-version/main' | \
      tee -a /etc/apk/repositories && \
    apk add doppler

# 验证二进制存在
RUN ls -la /usr/local/bin/cloudflared /usr/bin/doppler

# --- Stage 2: 运行时阶段 ---
FROM alpine:3.21

# 仅安装运行时必需的包（无 wget/gnupg/curl）
RUN apk add --no-cache \
    bash \
    jq \
    coreutils \
    rclone \
    dcron \
    supervisor \
    ca-certificates \
    postgresql17-client \
    age \
    && rm -rf /var/cache/apk/*

# 从构建阶段传递二进制文件
COPY --from=builder /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY --from=builder /usr/bin/doppler /usr/bin/doppler

# 设置工作目录
WORKDIR /app

# 创建非 root 用户
RUN addgroup -S nodaops && adduser -S -G nodaops nodaops

# 修复 crond 权限
RUN chmod 755 /usr/sbin/crond

# 复制备份脚本
COPY --chown=nodaops:nodaops scripts/backup/ /app/backup/
RUN find /app/backup -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# 复制 crontab 配置
COPY --chown=nodaops:nodaops deploy/crontab /etc/crontabs/nodaops

# 复制 supervisord 配置
COPY --chown=nodaops:nodaops deploy/supervisord.conf /etc/supervisord.conf

# 复制启动脚本
COPY --chown=nodaops:nodaops deploy/entrypoint-ops.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 创建日志、运行和配置目录
RUN mkdir -p /var/log/supervisor /var/log/noda-backup /app/history /run/supervisor /home/nodaops/.config/rclone && \
    chown -R nodaops:nodaops /var/log/supervisor /var/log/noda-backup /app/history /run/supervisor /home/nodaops

EXPOSE 8080

USER nodaops

HEALTHCHECK --interval=1h --timeout=10s --start-period=30s --retries=3 \
    CMD pg_isready -h "${POSTGRES_HOST:-noda-infra-postgres-prod}" -U "${POSTGRES_USER:-postgres}" || exit 1

CMD ["/app/entrypoint.sh"]
```
*Source: 基于项目现有 Dockerfile.noda-ops + Docker 多阶段构建模式 [VERIFIED: codebase]*

### backup Dockerfile 优化模板
```dockerfile
FROM postgres:17-alpine

# 合并为单个 RUN：安装工具 + 创建目录 + 设置权限
RUN apk add --no-cache \
    bash \
    jq \
    coreutils \
    rclone \
    dcron \
    ca-certificates \
    && mkdir -p /var/log/noda-backup /app/history \
    && touch /var/log/noda-backup/backup.log \
             /var/log/noda-backup/test.log \
    && chmod 666 /var/log/noda-backup/*.log

WORKDIR /app

# 复制备份脚本
COPY scripts/backup/ /app/

# 复制 crontab 配置
COPY deploy/crontab /etc/crontabs/root

# 复制启动脚本
COPY deploy/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 设置环境变量
ENV BACKUP_DIR=/tmp/postgres_backups \
    HISTORY_DIR=/app/history \
    SCRIPT_DIR=/app

EXPOSE 8080

CMD ["/app/entrypoint.sh"]
```
*Source: 基于项目现有 Dockerfile.backup [VERIFIED: codebase]*

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| 单阶段 Dockerfile | 多阶段构建 (builder pattern) | Docker 17.05 (2017) | 构建工具不泄漏到运行时 |
| 多 RUN 指令 | 合并 RUN 减少层数 | Docker best practice | 减少镜像层数和大小 |
| curl 安装 "以防万一" | 按需审计依赖 | 持续 | 减少攻击面和镜像大小 |

**Deprecated/outdated:**
- `--no-cache` + `rm -rf /var/cache/apk/*` 重复：`--no-cache` 已阻止缓存写入，`rm` 是冗余操作 [ASSUMED]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | COPY --from=builder 会保留文件权限（chmod +x） | Architecture Patterns | 低 — 可通过 `RUN ls -la` 验证 |
| A2 | Doppler apk 包安装后二进制位于 `/usr/bin/doppler` | Code Examples | 中 — 需在 builder 阶段验证，Pitfall 1 有缓解方案 |
| A3 | Doppler CLI 二进制是静态链接，无额外 .so 依赖 | Common Pitfalls | 中 — 推荐改用 GitHub tarball 下载避免此问题 |
| A4 | `--no-cache` 已阻止 apk 缓存写入，`rm -rf /var/cache/apk/*` 冗余 | State of the Art | 低 — 即使错误也无害 |
| A5 | BuildKit 默认启用（Docker 23+） | Standard Stack | 低 — 项目使用 Docker Compose，BuildKit 通常已启用 |

## Open Questions (RESOLVED)

1. **Doppler CLI 安装方式选择** (RESOLVED: 使用官方 apk 仓库 + GPG 验证方式，与现有 Dockerfile 一致，Plan 52-01 action 中已采用)
   - What we know: 当前通过 Doppler 官方 apk 仓库 + GPG 验证安装。GitHub releases 提供了 tarball 格式（`doppler_3.75.3_linux_amd64.tar.gz`）
   - What's unclear: apk 安装的 doppler 是否有动态链接依赖，COPY 到新基础镜像是否能运行
   - Recommendation: 使用 GitHub releases tarball 下载（更可靠），或在 builder 阶段末尾用 `ldd` 检查依赖。建议先用 tarball 方式，参考 cloudflared 的下载模式，保持一致性
   - Resolution: Plan 52-01 使用官方 apk 仓库 + GPG 验证方式（与现有 Dockerfile 一致），在 builder 阶段验证二进制路径

2. **backup Dockerfile 是否也移除 curl** (RESOLVED: 一并移除，属于 Claude's Discretion 范围，Plan 52-02 action 中已移除)
   - What we know: D-04 仅针对 noda-ops。backup 脚本中 grep 确认无 curl 调用
   - What's unclear: 是否在 Claude's Discretion 范围内同时优化
   - Recommendation: 一并移除，风险低且收益明确（减少攻击面）
   - Resolution: backup Dockerfile 一并移除 curl（Claude's Discretion 范围内），Plan 52-02 action 中 apk add 不含 curl

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | 镜像构建 | 是 | Docker 24+ (推断) | - |
| Docker Compose v2 | 构建编排 | 是 | v2 (已安装) | - |
| Docker BuildKit | 多阶段构建 | 是 | 默认启用 | - |
| 网络连接 (构建时) | 下载 cloudflared/doppler | 是 | - | 预构建二进制作 fallback |
| GitHub API | Release 下载 | 是 | - | - |

**Missing dependencies with no fallback:** 无

**Missing dependencies with fallback:** 无

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | 无独立测试框架（Docker 构建验证 + 功能性测试） |
| Config file | 无 |
| Quick run command | `docker build -f deploy/Dockerfile.noda-ops --target runner -t noda-ops:test .` |
| Full suite command | 构建验证 + 容器启动 + 健康检查 + 备份功能验证 |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| INFRA-01 | noda-ops 镜像中无 wget/gnupg/curl 包 | smoke | `docker run --rm noda-ops:test sh -c "which wget gnupg curl; echo 'exit:' \$?"` | 需 Wave 0 创建 |
| INFRA-01 | noda-ops 运行时二进制功能正常 | smoke | `docker run --rm noda-ops:test sh -c "cloudflared --version && doppler --version"` | 需 Wave 0 创建 |
| INFRA-01 | noda-ops 健康检查正常 | integration | `docker compose up noda-ops` → 等 30s → `docker inspect` health | 需 Wave 0 创建 |
| INFRA-02 | backup Dockerfile 构建成功 | smoke | `docker build -f deploy/Dockerfile.backup -t noda-backup:test .` | 需 Wave 0 创建 |
| INFRA-02 | backup Dockerfile 仅含 1 个 RUN 指令 | unit | `grep -c "^RUN" deploy/Dockerfile.backup` | 需 Wave 0 创建 |

### Sampling Rate
- **Per task commit:** `docker build` 验证构建成功
- **Per wave merge:** 全部镜像构建 + 运行时二进制可用性检查
- **Phase gate:** 完整功能验证（备份脚本运行 + 健康检查 + cloudflared 启动）

### Wave 0 Gaps
- [ ] 无独立测试文件 — 本 phase 以 Docker 构建验证为主，不需要 pytest/jest 框架
- [ ] 验证脚本：检查镜像中无构建工具残留（可内联在 task 步骤中）
- [ ] 无测试框架安装需求

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | 否 | - |
| V3 Session Management | 否 | - |
| V4 Access Control | 否 | - |
| V5 Input Validation | 否 | - |
| V6 Cryptography | 是 | Doppler CLI 下载使用 GPG key 验证（builder 阶段） |

### Known Threat Patterns for Docker Image Optimization

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 构建工具泄漏到运行时 | Tampering | 多阶段构建仅 COPY 目标二进制 [VERIFIED: best practice] |
| 未验证的外部二进制 | Tampering | Doppler 使用 GPG 验证；cloudflared 从官方 GitHub releases 下载 [VERIFIED: Dockerfile] |
| 最小权限原则违反 | Elevation | 运行时移除 curl/wget 减少攻击面 [VERIFIED: D-04] |

## Sources

### Primary (HIGH confidence)
- 项目代码审计: `deploy/Dockerfile.noda-ops`, `deploy/Dockerfile.backup`, `scripts/backup/lib/*.sh` — 所有依赖使用确认
- GitHub API (2026-04-21): Doppler CLI 3.75.3 release assets 确认有 tarball 格式
- GitHub API (2026-04-21): cloudflared 2026.3.0 release assets 确认有 linux amd64/arm64 二进制
- Phase 47 Dockerfile.noda-site — 多阶段构建参考实现

### Secondary (MEDIUM confidence)
- Docker 多阶段构建模式 — 社区广泛实践，项目内已有先例 (Dockerfile.noda-site)

### Tertiary (LOW confidence)
- Doppler CLI 二进制路径 `/usr/bin/doppler` — 需在构建时验证 [ASSUMED]
- BuildKit 默认启用 — 基于当前 Docker 版本推断 [ASSUMED]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 基于项目代码和 GitHub API 验证
- Architecture: HIGH — 基于项目已有先例 (Phase 47) 和代码审计
- Pitfalls: MEDIUM — Doppler 二进制路径和动态链接依赖需构建时验证

**Research date:** 2026-04-21
**Valid until:** 2026-05-21（Alpine/Docker 基础设施稳定）
