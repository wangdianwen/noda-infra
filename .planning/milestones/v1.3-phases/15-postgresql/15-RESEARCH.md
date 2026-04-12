# Phase 15: PostgreSQL 客户端升级 - Research

**Researched:** 2026-04-12
**Domain:** PostgreSQL 客户端版本匹配 + Docker 内部网络 SSL 配置
**Confidence:** HIGH

## Summary

Phase 15 解决两个独立但相关的问题：(1) noda-ops 容器内的 pg_dump 版本（当前 16.11）与 PostgreSQL 服务端版本（17.9）不匹配，需要升级 Alpine 基础镜像和客户端包；(2) 备份脚本中所有 PostgreSQL 客户端调用（psql、pg_dump、pg_dumpall、pg_restore、pg_isready）均未显式设置 sslmode，可能在升级后因默认 sslmode=prefer 导致不必要的 SSL 协商尝试。

**核心变更**：Dockerfile 从 `alpine:3.19` 升级到 `alpine:3.21`，包名从 `postgresql-client` 改为 `postgresql17-client`；所有备份脚本中的 PG 客户端命令添加 `sslmode=disable`（通过环境变量 `PGSSLMODE=disable` 或逐行参数两种方案可选）。

**Primary recommendation:** 采用环境变量方案（docker-compose.yml 中设置 `PGSSLMODE: disable`），仅修改 2 个文件（Dockerfile + docker-compose.yml），避免逐行修改 20+ 个调用点，降低出错风险。

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PG-01 | pg_dump 版本匹配服务端 17.x（noda-ops Dockerfile 升级 Alpine 3.21 + postgresql17-client） | Alpine 3.21 提供 postgresql17-client 17.9-r0，与服务端 postgres:17.9 主版本一致 |
| PG-02 | 备份脚本显式设置 sslmode=disable（防止 PG17 默认 sslmode=require 导致 Docker 内部连接静默失败） | PG17 默认 sslmode 仍为 prefer（非 require），但 prefer 会先尝试 SSL 再降级，对 Docker 内部无意义连接增加延迟和警告。通过环境变量 PGSSLMODE=disable 全局禁用 |
</phase_requirements>

## Standard Stack

### Core
| Library/Package | Version | Purpose | Why Standard |
|-----------------|---------|---------|--------------|
| Alpine Linux | 3.21 | noda-ops 容器基础镜像 | Alpine 3.21 是当前稳定版，提供 postgresql17-client 包 [VERIFIED: Alpine package index] |
| postgresql17-client | 17.9-r0 | pg_dump / pg_isready / psql 客户端工具 | 与服务端 postgres:17.9 主版本匹配 [VERIFIED: Alpine package index] |
| PostgreSQL server | 17.9 | 数据库服务端 | docker-compose.yml 已使用 `image: postgres:17.9` [VERIFIED: codebase] |

### Supporting
| Library/Package | Version | Purpose | When to Use |
|-----------------|---------|---------|-------------|
| PGSSLMODE env var | N/A | 全局控制 PG 客户端 SSL 行为 | Docker 内部网络通信不需要 SSL |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| PGSSLMODE 环境变量 | 每个命令行添加 `sslmode=disable` 参数 | 环境变量方案只需改 docker-compose.yml，参数方案需改 20+ 个调用点，维护成本高 |
| Alpine 3.21 | Alpine edge | edge 滚动更新不稳定，3.21 是稳定版，足以提供 PG17 客户端 |
| 升级 PG 客户端 | 保持 PG16 客户端 | PG16 pg_dump 对 PG17 服务端有兼容性风险，官方建议客户端版本 >= 服务端版本 |

**Installation:**
```dockerfile
# Dockerfile 变更
FROM alpine:3.21
RUN apk add --no-cache postgresql17-client
```

**Version verification:**
- Alpine 3.21 postgresql17-client: 17.9-r0 (built 2026-03-11) [VERIFIED: https://pkgs.alpinelinux.org/packages?name=postgresql17-client&branch=v3.21]
- Alpine 3.19 postgresql16-client: 16.11-r0 (当前使用) [VERIFIED: https://pkgs.alpinelinux.org/packages?name=postgresql-client&branch=v3.19]

## Architecture Patterns

### Current Architecture
```
noda-ops 容器 (Alpine 3.19 + PG16 client)
  ├── 备份脚本 (scripts/backup/)
  │   ├── backup-postgres.sh (主脚本, 7步流程)
  │   ├── lib/db.sh (备份操作)
  │   ├── lib/health.sh (健康检查)
  │   ├── lib/verify.sh (验证)
  │   ├── lib/test-verify.sh (每周测试)
  │   ├── lib/restore.sh (恢复)
  │   └── lib/config.sh (配置)
  ├── Cloudflare Tunnel
  └── HEALTHCHECK (pg_isready)
       ↓ Docker internal network (noda-network)
  postgres 容器 (postgres:17.9)
```

### Target Architecture
```
noda-ops 容器 (Alpine 3.21 + PG17 client, PGSSLMODE=disable)
  ├── 备份脚本 (不变)
  ├── Cloudflare Tunnel
  └── HEALTHCHECK (pg_isready, 受 PGSSLMODE 影响)
       ↓ Docker internal network (noda-network)
  postgres 容器 (postgres:17.9)
```

### Affected Files Inventory
```
deploy/
├── Dockerfile.noda-ops          # FROM alpine:3.19 → 3.21, postgresql-client → postgresql17-client

docker/
├── docker-compose.yml           # (可选) 添加 PGSSLMODE=disable 环境变量

scripts/backup/                   # (仅当选择参数方案时修改)
├── lib/db.sh                    # 4 个调用点 (psql, pg_dump, pg_dumpall, psql)
├── lib/health.sh                # 5 个调用点 (pg_isready x2, psql x3 容器路径)
├── lib/verify.sh                # 1 个调用点 (pg_restore)
├── lib/test-verify.sh           # 9 个调用点 (psql x6, pg_restore x1, psql x2)
├── lib/restore.sh               # 5 个调用点 (psql pg_params, pg_restore pg_params)
└── test-verify-weekly.sh        # 1 个调用点 (pg_isready)
```

### Pattern: 环境变量方案 (推荐)
**What:** 通过 docker-compose.yml 环境变量 `PGSSLMODE=disable` 全局控制所有 PG 客户端命令的 SSL 行为
**When to use:** 容器内所有 PG 连接都走 Docker 内部网络，无需 SSL
**Example:**
```yaml
# docker-compose.yml noda-ops environment 添加:
environment:
  PGSSLMODE: disable
```
所有 PostgreSQL 客户端工具（psql、pg_dump、pg_dumpall、pg_restore、pg_isready）都会读取 `PGSSLMODE` 环境变量 [CITED: PostgreSQL 17 docs libpq-envars]。

### Pattern: 参数方案 (备选)
**What:** 每个 PG 客户端命令显式添加 `sslmode=disable` 参数
**When to use:** 需要精细控制每个连接的 SSL 行为时
**Example:**
```bash
# 修改前:
PGPASSWORD=$POSTGRES_PASSWORD pg_dump -h noda-infra-postgres-prod -U postgres -Fc -f "$backup_file" "$db_name"

# 修改后:
PGPASSWORD=$POSTGRES_PASSWORD pg_dump "host=noda-infra-postgres-prod user=postgres sslmode=disable" -Fc -f "$backup_file" "$db_name"
```

### Anti-Patterns to Avoid
- **逐行修改 20+ 个命令**: 容易遗漏或引入语法错误，应使用环境变量全局覆盖
- **使用 connection string URI 格式**: 当前脚本使用 `-h -U -p` 参数格式，混用 URI 格式会导致代码风格不一致
- **升级到 Alpine edge**: edge 是滚动更新分支，不适合生产环境
- **只改 Dockerfile 不改 sslmode**: 即使 PG17 默认仍是 `prefer`（非 `require`），SSL 协商尝试会产生不必要的延迟和日志噪音

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SSL 配置管理 | 自定义 SSL 开关逻辑 | PGSSLMODE 环境变量 | libpq 原生支持，所有客户端工具自动读取 |
| 版本检测 | 自定义版本检查脚本 | pg_dump --version | 官方工具自带版本输出 |
| 连接参数传递 | 自定义连接参数解析 | libpq 环境变量 + 命令行参数 | PostgreSQL 客户端原生支持 |

**Key insight:** PostgreSQL 客户端工具有完善的环境变量和参数体系，不需要自定义任何连接管理逻辑。

## Common Pitfalls

### Pitfall 1: Alpine 版本与 PG 包名不匹配
**What goes wrong:** Alpine 3.19 中 `postgresql-client` 安装 PG16，没有 `postgresql17-client` 包
**Why it happens:** Alpine 的 PG 包按主版本号命名，`postgresql-client` 只是默认版本的元包
**How to avoid:** 使用 Alpine 3.21 + `postgresql17-client`（版本化包名）
**Warning signs:** `pg_dump --version` 显示 16.x 而非 17.x

### Pitfall 2: pg_isready 不受 PGPASSWORD 影响
**What goes wrong:** pg_isready 不需要密码也能运行，但 `PGSSLMODE` 环境变量对 pg_isready 同样生效
**Why it happens:** pg_isready 使用 libpq 连接，读取所有 libpq 环境变量
**How to avoid:** 设置 `PGSSLMODE=disable` 后 pg_isready 也会跳过 SSL，行为一致
**Warning signs:** 无，环境变量方案天然覆盖 pg_isready

### Pitfall 3: HEALTHCHECK 中的 pg_isready 被遗漏
**What goes wrong:** Dockerfile.noda-ops 中 HEALTHCHECK 直接调用 `pg_isready`，如果使用参数方案修改脚本但遗漏 HEALTHCHECK，可能导致健康检查超时
**Why it happens:** HEALTHCHECK 是 Dockerfile 中的 CMD 指令，不在脚本文件中
**How to avoid:** 环境变量方案自动覆盖 HEALTHCHECK 中的 pg_isready；参数方案需要额外修改 HEALTHCHECK 命令
**Warning signs:** Docker 健康检查超时或失败

### Pitfall 4: PG17 sslmode 默认值误解
**What goes wrong:** REQUIREMENTS.md 提到 "PG17 默认 sslmode=require"，但实际 PG17 默认仍是 `prefer`
**Why it happens:** PostgreSQL 社区曾讨论将默认值改为 `require`（计划在 PG18），但 PG17 未实施
**How to avoid:** 即使默认是 `prefer`（先尝试 SSL 再降级），Docker 内部网络中显式 `disable` 仍是最佳实践，消除 SSL 协商的延迟和潜在警告
**Warning signs:** 备份日志中出现 SSL 相关警告信息

### Pitfall 5: 宿主机路径调用点被遗漏
**What goes wrong:** health.sh 和 restore.sh 有两条代码路径：容器内（直接调用 psql/pg_dump）和宿主机（docker exec），sslmode 只修改了容器路径
**Why it happens:** 宿主机路径使用 `docker exec postgres-container psql`，PG 客户端运行在 postgres 容器内，不受 noda-ops 的 PGSSLMODE 影响
**How to avoid:** `docker exec` 方式运行在 postgres 服务端容器内，该容器内 PG 客户端与服务器是同一版本（17.9），连接 localhost 不走网络，sslmode 不重要。只需确保 noda-ops 容器内的调用正确即可
**Warning signs:** 宿主机路径主要用于手动恢复操作，自动化备份均在容器内运行

## Code Examples

### Dockerfile 变更
```dockerfile
# Source: [VERIFIED: Alpine package index + codebase analysis]
# 修改前:
FROM alpine:3.19
RUN apk add --no-cache \
    bash curl wget jq coreutils rclone dcron \
    supervisor ca-certificates postgresql-client gnupg \
    && rm -rf /var/cache/apk/*

# 修改后:
FROM alpine:3.21
RUN apk add --no-cache \
    bash curl wget jq coreutils rclone dcron \
    supervisor ca-certificates postgresql17-client gnupg \
    && rm -rf /var/cache/apk/*
```

### docker-compose.yml 环境变量方案
```yaml
# Source: [CITED: PostgreSQL 17 docs - libpq environment variables]
# noda-ops service environment 添加:
noda-ops:
  environment:
    # ... 现有变量 ...
    PGSSLMODE: disable  # Docker 内部网络无需 SSL
```

### pg_dump 调用变更（仅当选择参数方案时）
```bash
# Source: [CITED: PostgreSQL 17 docs - pg_dump connection options]
# 修改前 (db.sh line 64):
PGPASSWORD=$POSTGRES_PASSWORD pg_dump -h noda-infra-postgres-prod -U postgres -Fc -f "$backup_file" "$db_name"

# 修改后 (参数方案):
PGPASSWORD=$POSTGRES_PASSWORD pg_dump "host=noda-infra-postgres-prod user=postgres sslmode=disable" -Fc -f "$backup_file" "$db_name"
```

### 宿主机路径说明
```bash
# health.sh 中的宿主机路径 (line 70, 105, 124, 353)
# 这些使用 docker exec postgres-container psql ...
# 客户端运行在 postgres:17.9 容器内，版本已匹配，无需修改
# sslmode 对 localhost 连接无影响，无需修改
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Alpine 3.19 + postgresql-client (PG16) | Alpine 3.21 + postgresql17-client (PG17) | 需要 Phase 15 完成 | pg_dump 版本与服务端匹配，避免兼容性警告 |
| 无 sslmode 设置 | PGSSLMODE=disable | 需要 Phase 15 完成 | Docker 内部连接跳过 SSL 协商，减少延迟和警告 |
| PG16 默认 sslmode=prefer | PG17 默认 sslmode=prefer | PG17 未改变默认值 | 仍建议显式 disable，消除 prefer 的 SSL 尝试 |

**Deprecated/outdated:**
- Alpine 3.19 中的 `postgresql-client` 元包：安装 PG16 客户端，与服务端 17.9 不匹配
- PostgreSQL v1 sslmode 行为：PG17 仍使用 v1 默认值 prefer，但 PG18 计划改为 require

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | PGSSLMODE 环境变量被 pg_isready 读取 | Architecture Patterns | 如果不读取，HEALTHCHECK 需要单独添加参数 |
| A2 | 宿主机路径（docker exec 方式）不需要 sslmode 修改 | Common Pitfalls | 如果 postgres 容器内客户端也尝试 SSL，可能影响手动恢复操作 |
| A3 | Alpine 3.21 中 cloudflared 安装脚本仍然正常工作 | Dockerfile 变更 | Alpine 版本升级可能影响 glibc/musl 兼容性，但 cloudflared 是静态链接二进制 |
| A4 | PostgreSQL 17 客户端可以 dump 17.9 服务端的所有特性 | Standard Stack | 两者主版本一致（17.x），完全兼容 |

**If this table is empty:** All claims in this research were verified or cited -- no user confirmation needed.

## Open Questions

1. **环境变量 vs 参数方案选择**
   - What we know: 环境变量方案只改 2 个文件（Dockerfile + compose），参数方案改 8 个文件 20+ 个调用点
   - What's unclear: 用户是否有偏好
   - Recommendation: 强烈推荐环境变量方案（PGSSLMODE=disable），更简单、更安全、更易维护

2. **Alpine 3.21 是否影响其他依赖**
   - What we know: Alpine 3.21 是当前稳定版，所有其他包（bash、curl、rclone、supervisor 等）都可用
   - What's unclear: 是否有包版本变更影响现有功能
   - Recommendation: 升级后运行完整备份流程验证（健康检查 -> 备份 -> 验证 -> 上传 B2）

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | 构建 noda-ops 镜像 | 需在生产服务器验证 | -- | -- |
| Alpine 3.21 镜像 | Dockerfile base | 需验证可拉取 | 3.21 | -- |
| postgresql17-client | pg_dump 等工具 | 需验证可安装 | 17.9-r0 | -- |
| 生产服务器访问 | 部署验证 | 需通过部署脚本 | -- | -- |

**Missing dependencies with no fallback:**
- 需要在生产服务器上执行部署脚本来重建 noda-ops 镜像

**Missing dependencies with fallback:**
- 无

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell 脚本 (bash) |
| Config file | 无独立配置，验证通过端到端备份流程 |
| Quick run command | `docker exec noda-ops pg_dump --version` (验证版本) |
| Full suite command | `bash scripts/deploy/deploy-infrastructure-prod.sh` + 手动触发备份 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PG-01 | pg_dump --version 输出 17.x | smoke | `docker exec noda-ops pg_dump --version` | N/A (运行时验证) |
| PG-01 | 备份脚本成功执行 pg_dump | integration | 手动触发备份流程或等待 cron | N/A |
| PG-02 | 备份连接无 sslmode 警告 | smoke | 检查备份日志无 SSL 警告 | N/A |
| PG-02 | HEALTHCHECK pg_isready 正常 | smoke | `docker inspect noda-ops --format='{{.State.Health.Status}}'` | N/A |

### Sampling Rate
- **Per task commit:** `docker exec noda-ops pg_dump --version`
- **Per wave merge:** 部署后验证完整备份流程
- **Phase gate:** 端到端备份（健康检查 -> 备份 -> 验证 -> 上传 B2）正常完成

### Wave 0 Gaps
- 无 -- 此 Phase 不需要新的测试文件，验证通过部署后的运行时检查完成

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | PostgreSQL 用户名+密码认证（docker-compose 环境变量注入） |
| V3 Session Management | no | 不涉及会话管理 |
| V4 Access Control | yes | Docker 网络隔离（noda-network），容器间通信 |
| V5 Input Validation | no | 不涉及用户输入 |
| V6 Cryptography | yes | 显式禁用 SSL（sslmode=disable），因为使用 Docker 内部网络 |

### Known Threat Patterns for Docker Internal PostgreSQL

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 网络嗅探 | Information Disclosure | Docker 内部网络加密（默认） + sslmode=disable 仅限内部网络 |
| 未授权访问 | Tampering | Docker 网络隔离 + 密码认证 |
| 客户端版本不匹配导致的数据损坏 | Tampering | PG17 客户端匹配 PG17 服务端（本 Phase 修复） |

## Sources

### Primary (HIGH confidence)
- Alpine package index (pkgs.alpinelinux.org) - postgresql17-client 17.9-r0 在 Alpine 3.21 x86_64 main 仓库
- Alpine package index (pkgs.alpinelinux.org) - postgresql-client 在 Alpine 3.19 安装 PG16
- Codebase 文件分析 - Dockerfile.noda-ops, docker-compose.yml, 所有备份脚本库
- PostgreSQL 17 官方文档 - libpq 环境变量 (PGSSLMODE)

### Secondary (MEDIUM confidence)
- PostgreSQL 17 官方文档 - sslmode 默认值为 prefer（非 require）

### Tertiary (LOW confidence)
- 无

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Alpine 包版本通过官方仓库验证
- Architecture: HIGH - 所有受影响文件和调用点通过代码库 grep 验证
- Pitfalls: HIGH - 基于代码库实际结构分析

**Research date:** 2026-04-12
**Valid until:** 2026-05-12 (Alpine 3.21 稳定，不会短期内变化)
