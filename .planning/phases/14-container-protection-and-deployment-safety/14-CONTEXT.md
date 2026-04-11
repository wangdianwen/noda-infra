# Phase 14: Container protection and deployment safety - Context

**Gathered:** 2026-04-11
**Status:** Ready for planning

<domain>
## Phase Boundary

为 Docker 容器和部署流程添加安全加固、日志管理、故障恢复能力。不新增服务，不修改应用代码，不改变网络架构。

三大交付：
1. **Container security hardening** — 生产环境容器全面安全加固（security_opt, capabilities, non-root, logging）
2. **Deployment safety** — 自动回滚机制 + 部署前自动备份
3. **Nginx resilience** — upstream 故障转移 + 自定义错误页

不涉及：新增服务、应用代码变更、CI/CD pipeline、镜像扫描/SBOM、开发环境加固。

</domain>

<decisions>
## Implementation Decisions

### Container security hardening
- **D-01:** Full hardening — 对所有生产容器添加 `security_opt: no-new-privileges:true`、`cap_drop: ALL`（按需 cap_add）、`read_only: true` + `tmpfs` 临时目录。仅在生产 overlay (docker-compose.prod.yml) 中添加，开发环境保持宽松
- **D-02:** Non-root user for all containers — noda-ops 和 backup 容器当前以 root 运行，需要为它们创建专用用户并处理 crontab 和 rclone 的权限问题（findclass-ssr 已有 nodejs user）
- **D-03:** Uniform logging config — 所有生产容器添加 json-file driver + max-size/max-file 日志轮转，防止日志占满磁盘
- **D-04:** Graceful shutdown — 所有服务添加 `stop_grace_period: 30s`，确保数据库完成写入、应用完成请求、备份完成当前任务

### Deployment safety
- **D-05:** Image-tag based rollback — 部署前保存当前镜像标签（digest 或 tag），部署失败时自动回退到上一版本镜像
- **D-06:** Auto backup before deploy — 部署前自动触发数据库备份，如果 12 小时内已有成功备份则跳过

### Nginx resilience
- **D-07:** Upstream with retry — 将直接 `proxy_pass` 改为 upstream 块，配置 `proxy_next_upstream error timeout http_502 http_503` 实现故障转移
- **D-08:** Custom error page — 当后端不可用时显示友好的"服务维护中"页面（502/503 错误页）

### Claude's Discretion
- 每个 `cap_drop: ALL` 后具体需要 cap_add 哪些 capabilities（如 NET_BIND_SERVICE for nginx, CHOWN for backup）
- 日志轮转的具体参数（max-size: 10m, max-file: 3 等）
- noda-ops/backup 容器 non-root 用户的具体权限处理方式
- 自定义错误页面的设计内容
- 镜像标签保存和回滚的具体实现方式（文件 vs 环境变量 vs docker tag）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docker Compose 配置
- `docker/docker-compose.yml` — 基础配置，所有服务定义（当前无安全选项）
- `docker/docker-compose.prod.yml` — 生产环境 overlay（安全加固的目标文件）
- `docker/docker-compose.dev.yml` — 开发环境 overlay（保持不变）

### Dockerfiles
- `deploy/Dockerfile.findclass-ssr` — 已有 non-root user (nodejs)，可能需要调整
- `deploy/Dockerfile.noda-ops` — 需要添加 non-root user（处理 crontab/rclone 权限）
- `deploy/Dockerfile.backup` — 需要添加 non-root user

### 部署脚本
- `scripts/deploy/deploy-infrastructure-prod.sh` — 全量部署脚本（添加回滚和备份集成）
- `scripts/deploy/deploy-apps-prod.sh` — 应用部署脚本（添加回滚）

### Nginx 配置
- `config/nginx/conf.d/default.conf` — 反向代理配置（添加 upstream 块和错误页）
- `config/nginx/snippets/proxy-common.conf` — 代理通用配置

### 备份系统
- `scripts/backup/backup-postgres.sh` — 主备份脚本（用于部署前自动备份）
- `scripts/backup/lib/config.sh` — 备份配置（检查最近备份时间的逻辑）

### 前置 Phase 上下文
- `.planning/phases/11-服务整合/11-CONTEXT.md` — 服务分组标签模式（参考 compose overlay 修改方式）
- `.planning/phases/10-b2/10-CONTEXT.md` — 备份系统代码上下文

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **findclass-ssr non-root pattern:** `deploy/Dockerfile.findclass-ssr` 中已有 addgroup/adduser + chown + USER 指令的完整模式，noda-ops 和 backup 可参考
- **Deploy script error handling:** `deploy-infrastructure-prod.sh` 已有 `set -euo pipefail` + 健康检查 + 重启计数监控
- **Backup system:** `backup-postgres.sh` 可直接在部署脚本中调用
- **Compose overlay pattern:** 生产安全选项添加到 prod overlay，不影响基础和开发配置

### Established Patterns
- **Docker Compose overlay:** 基础 yml + prod.yml 叠加，生产特定配置在 prod.yml 中覆盖
- **容器命名:** `noda-infra-{service}-{env}` 格式
- **部署流程:** deploy-infrastructure-prod.sh → validate → deploy → health check → report

### Integration Points
- 安全选项仅修改 `docker-compose.prod.yml` — 不影响开发环境
- 回滚机制集成到 `deploy-infrastructure-prod.sh` 和 `deploy-apps-prod.sh`
- 部署前备份调用现有 `backup-postgres.sh`
- Nginx upstream 修改 `config/nginx/conf.d/default.conf`

</code_context>

<specifics>
## Specific Ideas

- noda-ops 容器需要 root 运行 crontab，non-root 改造可能需要使用 busybox crontab 替代方案或 sudoers 配置
- `proxy_next_upstream` 在 Nginx OSS 中仅支持被动健康检查，不需要 Nginx Plus
- 镜像标签回滚最简单的方式是 `docker compose down` + `docker compose up -d` 配合保存的 image digest
- 自定义错误页可以放在 `config/nginx/errors/` 目录下

</specifics>

<deferred>
## Deferred Ideas

- Image vulnerability scanning (Trivy/Docker Scout) — 需要CI/CD pipeline 集成，独立 phase
- SBOM generation — 合规需求，独立 phase
- Blue-green deployment — 需要额外基础设施，复杂度过高
- Deployment notifications — 需要通知渠道集成（Slack/email），独立 phase

</deferred>

---
*Phase: 14-container-protection-and-deployment-safety*
*Context gathered: 2026-04-11*
