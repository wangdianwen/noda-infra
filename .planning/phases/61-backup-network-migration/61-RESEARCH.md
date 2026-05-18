# Phase 61: 备份与网络迁移 - Research

**Researched:** 2026-05-19
**Domain:** 备份 Cronjob 验证 + Cloudflare Tunnel 迁移 + Pre-prod 网络路由
**Confidence:** HIGH

## Summary

本阶段的核心工作是验证 r4s noda-ops 容器中的 5 个备份 cronjob 功能正常、确认 Cloudflare Tunnel 在 r4s 上正常工作、验证 Nginx 端口映射和 pre-prod 域名路由，最后清理 Mac 上的旧 noda-ops 服务。

通过源码分析发现三个关键问题：(1) Cloudflare Tunnel 使用 token 模式运行，本地 config.yml 实际被忽略，Tunnel 配置由 Cloudflare Dashboard 远程管理；(2) config.yml 中的 `noda-nginx:81` 是死配置，实际 Tunnel 路由使用的是 Dashboard 上配置的 `nginx:80`（Docker 服务名，非 container_name）；(3) Pre-prod Nginx server blocks 使用 `*.noda.test` 域名（非 D-10 中提到的 `class.noda.dev`），r4s overlay 端口映射 8080:80 + 8443:443 需要与这些域名配合使用。

备份脚本体系完整（backup-postgres.sh 7 步流程 + backup-doppler-secrets.sh age 加密 + test-verify-weekly.sh 周验证），依赖环境变量全部通过 docker-compose.yml 注入。验证方法是通过 SSH 远程 docker exec 逐个手动触发 cronjob 脚本。

**Primary recommendation:** 严格按依赖关系串行验证（pg_dump -> B2 上传 -> Doppler -> 周验证），Tunnel 验证通过 cloudflared 日志 + 外部 curl 完成，pre-prod 通过 /etc/hosts + r4s:8080/8443 访问验证。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Cloudflare Tunnel 已在 r4s noda-ops 中运行，无需额外切换 DNS
- **D-02:** config.yml 保持现有配置（6 个域名全部指向 `http://noda-nginx:81`），但需验证 Docker 内部 DNS 解析
- **D-03:** Tunnel 域名路由配置不变（6 个域名）
- **D-04:** r4s noda-ops cronjob 可能未正常触发过，需手动触发验证
- **D-05:** 验证按依赖关系串行执行：pg_dump -> B2 上传 -> Doppler -> 周验证
- **D-06:** 通过 SSH 远程 docker exec 在 noda-ops 容器内执行备份脚本验证
- **D-07:** 备份文件保留策略保持 7 天
- **D-08:** B2 上传验证通过检查 rclone 是否成功上传
- **D-09:** 不需要从外部暴露 Nginx 高端口给外网
- **D-10:** Pre-prod 通过 r4s:8080 端口访问
- **D-11:** r4s 80 端口被 iStoreOS 占用，使用 8080
- **D-12:** Mac 旧 noda-ops 在 r4s 验证通过后清理
- **D-13:** Mac noda-ops 停止但不删除
- **D-14:** Mac cronjob 和 Tunnel 随容器停止而停止

### Claude's Discretion
- 手动触发验证的具体命令和参数
- Docker 内部 DNS 解析验证的具体方法
- B2 上传验证的检查方式
- pre-prod 访问验证的 curl 命令和预期响应
- 验证失败时的回退步骤

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BACKUP-01 | pg_dump 每日备份 cronjob 在 r4s noda-ops 容器中正常运行 | backup-postgres.sh 7 步流程分析 + 手动触发命令 |
| BACKUP-02 | B2 云备份上传从 r4s 正常执行 | rclone 配置 + B2 凭证验证 + 上传检查命令 |
| BACKUP-03 | Doppler 密钥每日备份 cronjob 迁移到 r4s | backup-doppler-secrets.sh 分析 + age 加密流程 |
| BACKUP-04 | 周验证测试 cronjob 迁移到 r4s | test-verify-weekly.sh 分析 + B2 下载 + pg_restore 验证 |
| BACKUP-05 | 旧 Mac 上的备份和 cronjob 清理确认 | Mac 容器停止策略 + 验证确认流程 |
| NET-01 | Cloudflare Tunnel 从 Mac 迁移到 r4s | token 模式分析 + 日志验证方法 |
| NET-02 | Nginx 端口映射从 r4s 暴露 | r4s overlay 端口映射分析 + Tunnel 内部网络路径 |
| NET-03 | pre-prod 域名路由在 r4s Nginx 上正常工作 | Nginx server blocks 分析 + /etc/hosts 配置方法 |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| pg_dump 备份 | noda-ops 容器 (r4s) | PostgreSQL 容器 | noda-ops 发起 pg_dump，PG 被动接受连接 |
| B2 云上传 | noda-ops 容器 (r4s) | Backblaze B2 外部服务 | rclone 在 noda-ops 内运行，上传到 B2 |
| Doppler 密钥备份 | noda-ops 容器 (r4s) | Doppler API + B2 | 下载密钥 -> age 加密 -> 上传 B2 |
| Cloudflare Tunnel | noda-ops 容器 (r4s) | Cloudflare Edge + Nginx | cloudflared 进程在 noda-ops 内，流量到 nginx:81 |
| Nginx 端口映射 | r4s 宿主机 | Nginx 容器 | r4s overlay 控制 8080:80/8081:81/8443:443 |
| Pre-prod 访问 | 开发者浏览器 -> r4s:8080/8443 | Nginx 容器 | /etc/hosts 指向 r4s IP，Nginx 按 server_name 路由 |
| Mac 旧服务清理 | Mac 宿主机 | — | docker stop noda-ops，验证不再运行 |

## Standard Stack

### Core (已安装，无需变更)
| Component | Version | Purpose | Confidence |
|-----------|---------|---------|------------|
| dcron | Alpine pkg | Cron 调度器，noda-ops 内部 | HIGH [VERIFIED: Dockerfile] |
| supervisord | Alpine pkg | 进程管理（cron + cloudflared） | HIGH [VERIFIED: supervisord.conf] |
| rclone | Alpine pkg | B2 云存储上传 | HIGH [VERIFIED: Dockerfile] |
| cloudflared | latest (多阶段构建) | Cloudflare Tunnel 客户端 | HIGH [VERIFIED: Dockerfile] |
| doppler CLI | latest (多阶段构建) | 密钥下载 | HIGH [VERIFIED: Dockerfile] |
| age | Alpine pkg | 密钥加密 | HIGH [VERIFIED: Dockerfile] |
| postgresql17-client | Alpine pkg | pg_dump/pg_restore | HIGH [VERIFIED: Dockerfile] |

### Supporting
| Component | Purpose | When to Use |
|-----------|---------|-------------|
| jq | JSON 解析（metadata 文件） | 备份脚本内部使用 |
| bash | 脚本运行时 | 所有备份脚本 |

**注意：** 本阶段不安装任何新包。所有工具已在 Phase 58 构建镜像时包含。

## Package Legitimacy Audit

本阶段不安装任何外部包。所有依赖已在 Phase 58 构建的 noda-ops 镜像中预装。

## Architecture Patterns

### System Architecture Diagram

```
                    外部用户
                       |
                  Cloudflare CDN
                       |
                Cloudflare Edge (DNS)
                       |
              Cloudflare Tunnel (token 模式)
                       |
         r4s noda-ops 容器 (cloudflared 进程)
                       |
          Docker 内部网络 (noda-network)
                       |
              r4s nginx:81 (noda-infra-nginx)
               /    |    \     \
    class.noda.co.nz auth   admin  www  (port 81 = prod)
              |       |      |     |
         noda-apps-prod:3000  keycloak:8080  noda-apps-prod:3002
                       |
    ┌──────────────────┤
    |                  |
  r4s:8080         r4s:8443
  (HTTP→redirect)  (HTTPS content)
    |                  |
  pre-prod server blocks (*.noda.test)
              |
         noda-apps-preprod:3000

   ┌─ noda-ops 容器内部 ──────────────┐
   |  supervisord                      |
   |  ├── crond (5 cronjobs)          |
   |  │   ├── 03:00 backup-postgres   |
   |  │   ├── 03:00 Sun test-verify   |
   |  │   ├── */6h metrics cleanup    |
   |  │   ├── 04:00 旧文件清理         |
   |  │   └── 03:30 doppler backup    |
   |  └── cloudflared (tunnel)        |
   └───────────────────────────────────┘
```

### Recommended Project Structure (不变)
```
deploy/
├── Dockerfile.noda-ops     # 镜像构建（已完成）
├── supervisord.conf         # 进程管理（cron + cloudflared）
├── crontab                  # 5 个 cronjob 定义
└── entrypoint-ops.sh       # 初始化脚本

scripts/backup/
├── backup-postgres.sh       # 主备份脚本
├── backup-doppler-secrets.sh # Doppler 密钥备份
├── test-verify-weekly.sh    # 周验证测试
└── lib/                     # 共享库

config/cloudflare/
└── config.yml               # Tunnel 本地配置（token 模式下未使用）

docker/
├── docker-compose.yml       # 基础服务定义
├── docker-compose.prod.yml  # 生产 overlay
└── docker-compose.r4s.yml   # r4s 端口映射 overlay
```

### Pattern 1: SSH Docker Exec 验证模式
**What:** 通过 SSH 远程在 r4s 的 noda-ops 容器内执行命令
**When to use:** 所有备份验证和 Tunnel 验证
**Example:**
```bash
# 手动触发 pg_dump 备份
ssh root@r4s 'docker exec noda-ops /app/backup/backup-postgres.sh'

# 检查 cron 日志
ssh root@r4s 'docker exec noda-ops tail -50 /var/log/noda-backup/backup.log'

# 验证 B2 上传
ssh root@r4s 'docker exec noda-ops rclone ls b2remote:noda-backups/backups/postgres/ --config /home/nodaops/.config/rclone/rclone.conf'

# 检查 cloudflared 日志
ssh root@r4s 'docker exec noda-ops tail -20 /var/log/noda-backup/cloudflared-error.log'

# Docker 内部 DNS 解析验证
ssh root@r4s 'docker exec noda-ops wget -qO- http://noda-infra-nginx:81/health || echo FAILED'
```
[VERIFIED: Phase 60 D-12 确认此模式]

### Pattern 2: Crontab 定义（deploy/crontab）
**What:** 5 个 cronjob 在镜像构建时 COPY 进容器
**When to use:** 所有定时备份任务
**Example:**
```
# 每天 03:00 - pg_dump 备份
0 3 * * * /app/backup/backup-postgres.sh >> /var/log/noda-backup/backup.log 2>&1

# 每周日 03:00 - 周验证测试
0 3 * * 0 /app/backup/test-verify-weekly.sh >> /var/log/noda-backup/test.log 2>&1

# 每 6 小时 - 历史记录清理
0 */6 * * * /app/backup/lib/metrics.sh cleanup 2>/dev/null || true

# 每天 04:00 - 旧备份文件清理
0 4 * * * find /tmp/postgres_backups -type f -name "*.dump" -mtime +7 -delete 2>/dev/null || true

# 每天 03:30 - Doppler 密钥备份
30 3 * * * /app/backup/backup-doppler-secrets.sh --project noda --config prd >> /var/log/noda-backup/doppler-backup.log 2>&1
```
[VERIFIED: deploy/crontab 文件]

### Anti-Patterns to Avoid
- **直接在 r4s 宿主机上运行 cron:** 备份脚本设计为在容器内运行（依赖 pg_dump、rclone 等容器内工具）
- **修改 config.yml 以为可以改变 Tunnel 路由:** token 模式下 config.yml 被忽略，路由由 Dashboard 控制
- **同时运行 Mac 和 r4s 的 noda-ops:** Cloudflare Tunnel 同时运行两个实例会导致连接竞争
- **跳过串行验证直接全部触发:** 备份脚本有锁机制，且依赖关系需要串行确认

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 备份调度 | 自定义调度器 | dcron + crontab | 已在 Dockerfile 中配置 |
| 进程管理 | 自定义启动脚本 | supervisord | 已管理 cron + cloudflared |
| B2 上传 | 自定义 HTTP 客户端 | rclone | 重试、校验和验证、增量同步 |
| 密钥加密 | 自定义加密方案 | age 公钥加密 | 审计过，密钥不落盘 |
| Tunnel 进程管理 | 自定义 daemon | cloudflared + supervisord | autorestart、日志分离 |

## Runtime State Inventory

本阶段涉及运行时状态变更：

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| **Stored data** | r4s `/tmp/postgres_backups/` — 备份文件可能为空（cron 未触发） | 手动触发验证后确认文件生成 |
| **Stored data** | r4s `/app/history/` — 历史指标 JSON 可能不存在 | 手动触发后确认 |
| **Live service config** | Cloudflare Dashboard Tunnel 路由 — 当前指向 `nginx:80`（Docker 服务名） | 需验证 r4s Docker 服务名 `nginx` 能解析到 `noda-infra-nginx` 容器 |
| **Live service config** | Mac noda-ops 容器 — 当前仅 Mac 上运行备份和 Tunnel | r4s 验证通过后 docker stop |
| **OS-registered state** | r4s crontab — 在容器内，容器运行即自动生效 | 无需 OS 级别注册 |
| **Secrets/env vars** | docker/.env — B2、Cloudflare、Doppler 凭证 | r4s 需要 Mac 相同的 .env 文件 |
| **Build artifacts** | noda-ops 镜像 — Phase 58 已在 r4s 上 | 确认镜像版本与 Mac 一致 |

**Mac 旧容器状态确认：**
- Mac 上当前仅有 `noda-infra-postgres-prod` 运行（7 days, healthy）
- Mac noda-ops 容器可能已停止（Phase 58 迁移后停止）

## Common Pitfalls

### Pitfall 1: Cloudflare Tunnel config.yml 死配置误判
**What goes wrong:** 修改 config.yml 中的 `noda-nginx:81`，期望改变 Tunnel 路由，但 token 模式下该文件被忽略
**Why it happens:** cloudflared token 模式从 Cloudflare Dashboard 拉取配置，不读本地文件
**How to avoid:** 通过 cloudflared 日志（`cloudflared-error.log`）查看实际生效的配置。修改路由需在 Dashboard 操作。
**Warning signs:** 日志中显示 `service: "http://nginx:80"` 而非 config.yml 中的 `noda-nginx:81`
**Confidence:** HIGH [VERIFIED: supervisord.conf 使用 `--token` 参数启动]

### Pitfall 2: Docker 服务名 vs 容器名 DNS 解析
**What goes wrong:** Tunnel 配置中使用 `nginx:80`（Docker Compose 服务名），但容器名是 `noda-infra-nginx`
**Why it happens:** Docker 内部 DNS 同时注册服务名（`nginx`）和容器名（`noda-infra-nginx`）。但在 r4s 上如果 docker compose 项目名不一致，DNS 名可能不同。
**How to avoid:** 在 r4s noda-ops 容器内测试 DNS 解析：`docker exec noda-ops wget -qO- http://nginx:80/health` 和 `docker exec noda-ops wget -qO- http://noda-infra-nginx:81/health`
**Warning signs:** cloudflared 日志出现 connection refused 或 DNS 解析失败
**Confidence:** HIGH [VERIFIED: docker-compose.yml 项目名 `noda-infra`，Docker DNS 注册 `nginx` 服务名]

### Pitfall 3: Tunnel 配置使用端口 80 但 Nginx prod 监听端口 81
**What goes wrong:** Dashboard 配置 `nginx:80`，但 Nginx prod server blocks 只监听 81 端口
**Why it happens:** Cloudflare Dashboard 配置是在早期版本创建的，当时 Nginx 可能监听 80 端口。后续改为 81 端口后 Dashboard 配置未更新。
**How to avoid:** 检查 cloudflared 日志中的实际连接状态。如果 Tunnel 连接 nginx:80 失败，需要在 Dashboard 更新为 `nginx:81`。
**Warning signs:** `curl https://class.noda.co.nz/api/health` 返回 502/503 或连接超时
**Confidence:** MEDIUM [ASSUMED: 需要在 r4s 环境中验证]

### Pitfall 4: Pre-prod 域名不匹配
**What goes wrong:** CONTEXT.md D-10 提到 `class.noda.dev`，但 Nginx 配置中 pre-prod server blocks 使用 `*.noda.test` 域名
**Why it happens:** CONTEXT.md 中的域名可能写错
**How to avoid:** 使用 Nginx 配置中实际的 `*.noda.test` 域名。/etc/hosts 应添加 `class.noda.test`、`auth.noda.test`、`www.noda.test`、`admin.noda.test`
**Warning signs:** curl 返回默认 404 或非预期内容
**Confidence:** HIGH [VERIFIED: default.conf 中 `server_name class.noda.test` 等]

### Pitfall 5: rclone 配置目录 tmpfs 权限问题
**What goes wrong:** rclone 配置写入 `/home/nodaops/.config/rclone/` 失败，因为 prod overlay 将 `/home/nodaops` 挂载为 tmpfs 并限制了权限
**Why it happens:** docker-compose.prod.yml 中 `tmpfs: /home/nodaops:uid=100,gid=101,mode=0700`
**How to avoid:** entrypoint-ops.sh 中已有回退逻辑（mkdir 失败后尝试 sudo mkdir）。验证时检查 rclone.conf 是否成功生成。
**Warning signs:** B2 上传失败，rclone 报配置文件不存在
**Confidence:** HIGH [VERIFIED: entrypoint-ops.sh 第 35-42 行有回退逻辑]

### Pitfall 6: Mac 和 r4s 同时运行 Tunnel 导致冲突
**What goes wrong:** 如果 Mac noda-ops 容器仍在运行 Cloudflare Tunnel，r4s 的 Tunnel 无法正常工作
**Why it happens:** Cloudflare Tunnel 使用唯一 token，两个实例会竞争连接
**How to avoid:** 验证 r4s Tunnel 正常工作后，立即停止 Mac noda-ops 容器
**Warning signs:** cloudflared 日志出现频繁重连或 connection dropped
**Confidence:** HIGH [VERIFIED: Cloudflare Tunnel 文档，token 模式仅允许一个活跃连接]

## Code Examples

### 手动触发 pg_dump 备份 (BACKUP-01)
```bash
# 在 r4s noda-ops 容器内触发完整备份
ssh root@r4s 'docker exec noda-ops /app/backup/backup-postgres.sh'

# Dry-run 模式（验证配置但不实际备份）
ssh root@r4s 'docker exec noda-ops /app/backup/backup-postgres.sh --dry-run'

# 查看备份结果
ssh root@r4s 'docker exec noda-ops ls -la /tmp/postgres_backups/'

# 查看备份日志
ssh root@r4s 'docker exec noda-ops cat /var/log/noda-backup/backup.log | tail -30'
```
[VERIFIED: backup-postgres.sh 支持 --dry-run 参数]

### 验证 B2 上传 (BACKUP-02)
```bash
# 列出 B2 上的备份文件
ssh root@r4s 'docker exec noda-ops rclone ls b2remote:noda-backups/backups/postgres/ \
  --config /home/nodaops/.config/rclone/rclone.conf'

# 检查 B2 连接性
ssh root@r4s 'docker exec noda-ops rclone lsd b2remote:noda-backups/ \
  --config /home/nodaops/.config/rclone/rclone.conf'
```
[VERIFIED: cloud.sh 使用 `setup_rclone_config()` + `rclone copy` + `verify_upload_checksum()`]

### 手动触发 Doppler 密钥备份 (BACKUP-03)
```bash
# Dry-run 模式（仅下载加密，不上传 B2）
ssh root@r4s 'docker exec noda-ops /app/backup/backup-doppler-secrets.sh --dry-run'

# 完整模式
ssh root@r4s 'docker exec noda-ops /app/backup/backup-doppler-secrets.sh --project noda --config prd'
```
[VERIFIED: backup-doppler-secrets.sh 支持 --dry-run]

### 手动触发周验证测试 (BACKUP-04)
```bash
# 执行完整周验证（下载 B2 备份 → 恢复到临时 DB → 验证数据）
ssh root@r4s 'docker exec noda-ops /app/backup/test-verify-weekly.sh'

# 指定数据库列表
ssh root@r4s 'docker exec noda-ops /app/backup/test-verify-weekly.sh --databases "keycloak_db findclass_db"'
```
[VERIFIED: test-verify-weekly.sh 支持 --databases 参数]

### Docker 内部 DNS 验证 (NET-01)
```bash
# 从 noda-ops 容器内测试 DNS 解析
ssh root@r4s 'docker exec noda-ops sh -c "wget -qO- http://nginx:80/health 2>/dev/null || echo nginx:80-FAILED"'
ssh root@r4s 'docker exec noda-ops sh -c "wget -qO- http://nginx:81/health 2>/dev/null || echo nginx:81-FAILED"'
ssh root@r4s 'docker exec noda-ops sh -c "wget -qO- http://noda-infra-nginx:81/health 2>/dev/null || echo noda-infra-nginx:81-FAILED"'

# 检查 cloudflared 日志中的实际配置
ssh root@r4s 'docker exec noda-ops tail -5 /var/log/noda-backup/cloudflared-error.log'
```

### Pre-prod 访问验证 (NET-03)
```bash
# 本地 /etc/hosts 添加（R4S_IP 替换为 r4s 实际 IP）
# R4S_IP class.noda.test
# R4S_IP auth.noda.test
# R4S_IP www.noda.test
# R4S_IP admin.noda.test

# HTTP 验证（通过 8080 端口，会 301 重定向到 HTTPS）
curl -k -I http://class.noda.test:8080/

# HTTPS 验证（通过 8443 端口）
curl -k https://class.noda.test:8443/api/health

# Auth 验证
curl -k https://auth.noda.test:8443/

# Admin 验证
curl -k https://admin.noda.test:8443/
```
[VERIFIED: r4s overlay 8080:80 + 8443:443, Nginx pre-prod server blocks 监听 80/443]

### Mac 旧 noda-ops 清理 (BACKUP-05)
```bash
# 1. 确认 r4s 完全正常后
# 2. 检查 Mac noda-ops 是否仍在运行
docker ps -a --filter name=noda-ops

# 3. 停止 Mac noda-ops（保留不删除）
docker stop noda-ops

# 4. 验证 Mac noda-ops 已停止
docker ps -a --filter name=noda-ops --format '{{.Names}} {{.Status}}'
# 预期: noda-ops Exited (0) ...

# 5. 验证 Cloudflare Tunnel 仍正常（走 r4s）
curl -s https://class.noda.co.nz/api/health
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Nginx 监听 80 端口 | Nginx 监听 81 端口（prod）+ 80/443（pre-prod） | 迁移期间 | Tunnel Dashboard 配置可能需要更新 |
| Mac 本地 cronjob | r4s Docker 内 cronjob | Phase 61 | 脚本不变，运行位置改变 |
| Mac Cloudflare Tunnel | r4s Cloudflare Tunnel | Phase 61 | token 模式，无需 DNS 变更 |

**注意：** Cloudflare Tunnel 使用 token 模式。Tunnel 的 ingress 规则由 Cloudflare Dashboard 远程管理，不依赖本地 config.yml 文件。如果 Dashboard 配置仍指向旧的 `nginx:80`，而 Nginx prod 监听的是 `81` 端口，则需要在 Dashboard 中更新为 `nginx:81`（或者确认 `nginx:80` 是否有对应的 server block 响应）。

## Assumptions Log

| # | Claim | Section | Risk if Wrong | Confidence |
|---|-------|---------|---------------|------------|
| A1 | Cloudflare Dashboard 配置使用 `nginx:80`（来自 cloudflared 日志），需要确认这是否在 r4s 上也能正确解析 | NET-01 | Tunnel 无法连接到 Nginx，所有域名不可达 | MEDIUM |
| A2 | r4s 上 docker compose 项目名与 Mac 一致为 `noda-infra`，确保 DNS 服务名 `nginx` 可解析 | NET-01 | Docker DNS 解析失败 | HIGH |
| A3 | r4s noda-ops 镜像与 Mac 镜像版本一致（Phase 58 构建） | BACKUP-01~04 | 脚本行为不一致 | HIGH |
| A4 | CONTEXT.md D-10 中 `class.noda.dev` 域名有误，实际应为 `class.noda.test`（Nginx 配置中确认） | NET-03 | pre-prod 访问域名错误，curl 验证失败 | HIGH |
| A5 | Mac noda-ops 容器已在 Phase 58 迁移后停止 | BACKUP-05 | Mac Tunnel 可能仍在运行，与 r4s 冲突 | MEDIUM |
| A6 | B2 凭证已在 r4s 的 .env 文件中正确配置 | BACKUP-02 | B2 上传失败 | HIGH |

## Open Questions (RESOLVED)

1. **Cloudflare Dashboard Tunnel 配置需要更新吗？** (RESOLVED — 执行时验证)
   - Resolution: Tunnel 使用 token 模式，Dashboard 配置为 `http://nginx:80`。Plan 61-02 已包含验证步骤：先检查 Tunnel 日志确认连接状态，如果失败则需在 Dashboard 更新端口。80 端口有 pre-prod HTTP->HTTPS 重定向的 server block，可能会响应但行为不符合预期（返回 301 而非内容）。

2. **r4s 当前网络可达性** (RESOLVED — 执行前置条件)
   - Resolution: 执行阶段必须在同一局域网中进行（SSH `192.168.1.1` 可达）。这是执行阶段的硬性前置条件，非规划问题。

3. **Mac noda-ops 当前状态** (RESOLVED — 执行时检查)
   - Resolution: Plan 61-03 Task 1 已包含 `docker ps -a --filter name=noda-ops` 检查步骤。Phase 58 迁移后 Mac noda-ops 可能已停止，Plan 会先检查再决定是否需要执行 `docker stop`。

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| SSH to r4s | 所有验证步骤 | 无法确认（当前网络不可达） | — | 需在同一局域网 |
| r4s Docker | 容器运行 | 需确认 | Docker 27.3.1 / Compose v2.39.1 | — |
| noda-ops 容器 (r4s) | 备份验证 + Tunnel | 需确认 | — | — |
| PostgreSQL (r4s) | pg_dump | 需确认 | 17.9 | — |
| Nginx (r4s) | Tunnel + pre-prod | 需确认 | 1.25-alpine | — |
| Mac Docker | 旧容器清理 | 可用 | — | — |

**Missing dependencies with no fallback:**
- r4s SSH 连接 — 必须在同一网络环境下执行
- r4s noda-ops 容器运行中 — 需确认 Phase 58/59/60 已完成

**Missing dependencies with fallback:**
- 无

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | 手动验证（SSH docker exec + curl） |
| Config file | 无 |
| Quick run command | `ssh root@r4s 'docker exec noda-ops /app/backup/backup-postgres.sh --dry-run'` |
| Full suite command | 串行执行 5 个 cronjob 验证 + Tunnel 验证 + pre-prod 验证 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BACKUP-01 | pg_dump 备份正常执行 | integration | `ssh root@r4s 'docker exec noda-ops /app/backup/backup-postgres.sh'` | 脚本存在 |
| BACKUP-02 | B2 上传成功 | integration | `ssh root@r4s 'docker exec noda-ops rclone ls b2remote:noda-backups/ ...'` | 脚本存在 |
| BACKUP-03 | Doppler 密钥备份 | integration | `ssh root@r4s 'docker exec noda-ops /app/backup/backup-doppler-secrets.sh --dry-run'` | 脚本存在 |
| BACKUP-04 | 周验证测试 | integration | `ssh root@r4s 'docker exec noda-ops /app/backup/test-verify-weekly.sh'` | 脚本存在 |
| BACKUP-05 | Mac 旧服务清理 | manual | `docker stop noda-ops` + `docker ps -a` | — |
| NET-01 | Cloudflare Tunnel | integration | `curl https://class.noda.co.nz/api/health` + 日志检查 | — |
| NET-02 | Nginx 端口映射 | integration | `curl -k https://class.noda.test:8443/api/health` | — |
| NET-03 | Pre-prod 域名路由 | integration | `curl -k https://class.noda.test:8443/` + /etc/hosts | — |

### Sampling Rate
- **Per task commit:** 无自动测试（手动验证阶段）
- **Per wave merge:** 每个验证步骤完成后确认
- **Phase gate:** 所有 8 个 requirement 验证通过

### Wave 0 Gaps
- 无框架安装需求（手动验证阶段）
- 需要 r4s 网络可达才能执行验证

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | SSH 密钥认证（Phase 57 已配置） |
| V3 Session Management | no | — |
| V4 Access Control | yes | Mac 旧容器停止后确认无残留服务暴露 |
| V5 Input Validation | no | — |
| V6 Cryptography | yes | Doppler 密钥备份使用 age 公钥加密 |

### Known Threat Patterns for 备份与网络迁移

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| B2 凭据泄露 | Information Disclosure | 凭据通过 docker-compose 环境变量注入，不落盘 |
| Doppler token 泄露 | Information Disclosure | token 在容器环境变量中，容器 read-only + tmpfs |
| Tunnel token 泄露 | Information Disclosure | supervisord 配置中引用 %(ENV_CLOUDFLARE_TUNNEL_TOKEN)s |
| 旧容器残留服务 | Elevation of Privilege | docker stop noda-ops（不删除，保留回滚） |

## Sources

### Primary (HIGH confidence)
- `deploy/Dockerfile.noda-ops` — noda-ops 镜像构建，包含所有依赖
- `deploy/supervisord.conf` — cloudflared 启动命令确认 token 模式
- `deploy/crontab` — 5 个 cronjob 定义
- `deploy/entrypoint-ops.sh` — rclone 配置初始化 + 回退逻辑
- `config/cloudflare/config.yml` — Tunnel 本地配置（token 模式下不使用）
- `docker/docker-compose.yml` — 服务定义、container_name、环境变量
- `docker/docker-compose.prod.yml` — prod overlay（tmpfs 权限）
- `docker/docker-compose.r4s.yml` — r4s 端口映射 8080:80/8081:81/8443:443
- `config/nginx/conf.d/default.conf` — 所有 server blocks 定义
- `scripts/backup/backup-postgres.sh` — 完整备份流程
- `scripts/backup/backup-doppler-secrets.sh` — Doppler 密钥备份流程
- `scripts/backup/test-verify-weekly.sh` — 周验证测试流程
- `docker/volumes/logs/cloudflared-error.log` — 历史日志确认 Tunnel 实际配置
- `.planning/phases/58-infra-migration/58-CONTEXT.md` — 基础设施迁移决策
- `.planning/phases/60-ci-cd/60-CONTEXT.md` — CI/CD SSH docker exec 模式

### Secondary (MEDIUM confidence)
- Cloudflare Tunnel token 模式行为（cloudflared 官方文档确认 token 模式从 Dashboard 拉取配置）

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有组件已在 Dockerfile 和 docker-compose 中确认
- Architecture: HIGH — 系统架构通过源码分析和日志验证
- Pitfalls: HIGH — 关键问题（Tunnel 配置模式、DNS 解析、端口映射）通过源码确认

**Research date:** 2026-05-19
**Valid until:** 2026-06-19（稳定，无快速变化的外部依赖）
