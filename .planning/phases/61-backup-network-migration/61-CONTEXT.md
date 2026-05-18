# Phase 61: 备份与网络迁移 - Context

**Gathered:** 2026-05-19
**Status:** Ready for planning

<domain>
## Phase Boundary

将所有备份 cronjob（pg_dump、B2 上传、Doppler 密钥、周验证）和 Cloudflare Tunnel 从 Mac noda-ops 容器迁移到 r4s noda-ops 容器。同时验证 r4s Nginx 端口映射和 pre-prod 域名路由正常工作。最后清理 Mac 上的旧 noda-ops 服务。

**范围：**
- 验证 r4s noda-ops 容器中 5 个 cronjob 功能正常（pg_dump、周验证、历史清理、旧文件清理、Doppler 密钥备份）
- 验证 Cloudflare Tunnel 在 r4s 上正常工作（config.yml DNS 解析）
- 验证 B2 云备份从 r4s 正常上传
- 验证 pre-prod 域名通过 r4s:8080 访问正常
- Mac 旧 noda-ops 容器停止（保留不删除）

**不在范围：**
- 新增备份策略或修改备份逻辑
- 新增域名或修改 Cloudflare Tunnel 路由规则
- Mac 容器删除（Phase 62 统一处理）
- r4s 上新增监控或告警

</domain>

<decisions>
## Implementation Decisions

### Cloudflare Tunnel 切换

- **D-01:** Cloudflare Tunnel 已在 r4s noda-ops 中运行，无需额外切换 DNS。保持现有 Tunnel 配置不变。
- **D-02:** config.yml 保持现有配置（6 个域名全部指向 `http://noda-nginx:81`）。但需要验证 Docker 内部 DNS 解析 `noda-nginx` 是否在 r4s 环境中正确指向 `noda-infra-nginx` 容器。
- **D-03:** Tunnel 域名路由配置不变（noda.co.nz、auth、class、admin、health、localhost 六个域名）。

### 备份 Cronjob 验证

- **D-04:** r4s noda-ops 容器中 cronjob 可能未正常触发过，需要手动触发验证每个备份功能。
- **D-05:** 验证按依赖关系串行执行：pg_dump 备份 → B2 上传验证 → Doppler 密钥备份 → 周验证测试。每步成功后才进行下一步。
- **D-06:** 通过 SSH 远程 `docker exec` 在 noda-ops 容器内执行备份脚本验证（沿用 Phase 60 D-12 的 SSH docker exec 模式）。
- **D-07:** 备份文件保留策略保持 7 天（`find -mtime +7 -delete`），r4s 64GB SD 卡空间足够。
- **D-08:** B2 上传验证通过检查 rclone 是否成功上传文件到 B2 bucket。

### 端口映射与 Pre-prod 路由

- **D-09:** 不需要从外部暴露 Nginx 高端口给外网。Cloudflare Tunnel 走 Docker 内部网络（noda-nginx:81），外部访问通过 Tunnel 完成。
- **D-10:** Pre-prod 访问通过 r4s:8080 端口（复用现有 r4s overlay 配置 `8080:80`）。本地 /etc/hosts 修改 `class.noda.dev` 指向 r4s IP:8080。
- **D-11:** r4s 上 80 端口被 iStoreOS 管理界面占用，使用高端口 8080 作为 pre-prod 访问入口。

### Mac 旧服务清理

- **D-12:** Mac 旧 noda-ops 容器在 r4s 验证通过后清理。
- **D-13:** Mac noda-ops 容器停止但不删除（保留回滚能力，与 Phase 58 D-12 策略一致）。
- **D-14:** Mac 上的备份 cronjob 和 Tunnel 随 noda-ops 容器停止而停止（cron 在容器内运行，容器停则 cron 停）。

### Claude's Discretion

- 手动触发验证的具体命令和参数
- Docker 内部 DNS 解析验证的具体方法
- B2 上传验证的检查方式（rclone ls 或 rclone check）
- pre-prod 访问验证的 curl 命令和预期响应
- 验证失败时的回退步骤

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Noda-ops 容器配置

- `deploy/Dockerfile.noda-ops` — noda-ops 多阶段构建，包含 cloudflared、doppler、rclone、dcron、supervisor
- `deploy/supervisord.conf` — supervisord 管理 cron + cloudflared 两个进程
- `deploy/crontab` — 5 个 cronjob 定义（备份、验证、清理、Doppler）
- `deploy/entrypoint-ops.sh` — 容器启动脚本，初始化 rclone 配置和目录

### 备份脚本

- `scripts/backup/backup-postgres.sh` — PostgreSQL 备份主脚本
- `scripts/backup/backup-doppler-secrets.sh` — Doppler 密钥备份脚本（age 加密）
- `scripts/backup/lib/cloud.sh` — B2 云操作库（rclone）
- `scripts/backup/lib/verify.sh` — 备份验证库
- `scripts/backup/lib/test-verify.sh` — 周验证测试库
- `scripts/backup/lib/config.sh` — 备份配置管理
- `scripts/backup/lib/constants.sh` — 常量和退出码

### Cloudflare Tunnel 配置

- `config/cloudflare/config.yml` — Tunnel 入站规则（6 个域名 → noda-nginx:81）

### Docker Compose 配置

- `docker/docker-compose.yml` — noda-ops 服务定义（环境变量、卷挂载）
- `docker/docker-compose.prod.yml` — 生产环境 overlay
- `docker/docker-compose.r4s.yml` — r4s overlay（内存限制、高端口映射 8080/8081/8443）

### 环境变量

- `docker/.env` — 环境变量模板（包含 B2、Cloudflare Tunnel、Doppler Token）

### Nginx 配置

- `config/nginx/conf.d/default.conf` — 反向代理路由（包含 pre-prod server blocks）

### 前序阶段参考

- `.planning/phases/58-infra-migration/58-CONTEXT.md` — 基础设施迁移决策（noda-ops 内存限制 256M）
- `.planning/phases/60-ci-cd/60-CONTEXT.md` — CI/CD 改造决策（SSH docker exec 模式）

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets

- `deploy/Dockerfile.noda-ops` — noda-ops 镜像已在 Phase 58 构建并传输到 r4s，包含所有备份工具和 cloudflared
- `deploy/crontab` — 5 个 cronjob 已在 Dockerfile 中 COPY 进容器，无需额外配置
- `deploy/entrypoint-ops.sh` — 自动初始化 rclone 配置和验证环境变量
- `scripts/backup/backup-postgres.sh` — 完整的备份脚本，支持 pg_dump + B2 上传 + 验证
- `scripts/backup/backup-doppler-secrets.sh` — Doppler 密钥备份，age 加密后上传 B2
- `docker/docker-compose.r4s.yml` — r4s overlay 已配置 noda-ops 256M 内存限制和 Nginx 8080 端口映射

### Established Patterns

- SSH docker exec 模式：`ssh root@r4s 'docker exec noda-ops-container /app/backup/script.sh'`（Phase 60 D-12）
- Docker Compose overlay 模式：`-f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.r4s.yml`
- 备份脚本设计模式：健康检查 → 备份 → 验证 → B2 上传 → 清理
- Mac 旧容器保留不删除（回滚策略）

### Integration Points

- noda-ops 容器需要访问 PostgreSQL（noda-infra-postgres-prod:5432）— Phase 58 已迁移
- noda-ops 容器需要访问 B2 存储（需要 B2_ACCOUNT_ID、B2_APPLICATION_KEY）
- noda-ops 容器需要 CLOUDFLARE_TUNNEL_TOKEN 启动 Tunnel
- noda-ops 容器需要 DOPPLER_TOKEN 执行密钥备份
- Nginx pre-prod server blocks 监听容器内 80 端口，通过 r4s overlay 8080:80 映射到宿主机

</code_context>

<specifics>
## Specific Ideas

- config.yml 中 `service: http://noda-nginx:81` 使用容器名 `noda-nginx`，但实际容器名可能是 `noda-infra-nginx`。需要在 Docker 内部网络验证 DNS 解析是否正确。如果 `noda-nginx` 不能解析，可能需要改为 `noda-infra-nginx` 或在 Docker Compose 中添加 `hostname: noda-nginx`。
- Pre-prod 访问方式：本地 /etc/hosts 添加 `class.noda.dev` → r4s IP，然后通过 `http://class.noda.dev:8080` 访问 pre-prod 环境。
- r4s noda-ops 健康检查使用 `pg_isready`（Dockerfile 中已定义 HEALTHCHECK），可通过 `docker inspect` 检查容器健康状态。

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope
</deferred>

---

*Phase: 61-备份与网络迁移*
*Context gathered: 2026-05-19*
