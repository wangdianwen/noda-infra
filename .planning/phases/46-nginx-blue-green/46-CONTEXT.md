# Phase 46: nginx 蓝绿部署支持 - Context

**Gathered:** 2026-04-19
**Status:** Ready for planning

<domain>
## Phase Boundary

修复 nginx infra Pipeline `--force-recreate` 后 DNS 解析失败导致的容器重启循环。最小范围改动：nginx.conf 添加 Docker DNS resolver + Pipeline 添加 reload 步骤。

**涉及需求：** DNS-01, DNS-02

**前置条件：** Phase 43-45 已完成 — Pipeline 清理体系已建立

</domain>

<decisions>
## Implementation Decisions

### DNS 解析方案
- **D-01:** 在 `nginx.conf` http 块添加 `resolver 127.0.0.11 valid=30s;` 和 `resolver_timeout 5s;`。这是 Docker 内置 DNS 服务器，让 nginx 使用 Docker DNS 解析容器名称。`valid=30s` 设置 DNS 缓存 TTL 为 30 秒，确保 IP 变更后及时刷新

### Pipeline 部署顺序
- **D-02:** `pipeline_deploy_nginx()` 在 `docker compose up --force-recreate` 后添加：(1) sleep 3-5 秒等待 Docker DNS 就绪 (2) `docker exec noda-infra-nginx nginx -s reload` 触发 DNS 重新解析。确保 nginx reload 时 DNS 已就绪

### 范围边界
- **D-03:** 最小范围：仅修复 DNS 解析问题。nginx 蓝绿部署模式（双 nginx 容器 + upstream 切换）不纳入本 phase

### Claude's Discretion
- sleep 的具体秒数（3-5 秒范围内）
- resolver_timeout 的具体值
- pipeline_deploy_nginx() 中 reload 步骤的具体日志输出格式
- 是否需要在 pipeline_deploy_noda_ops() 中也添加类似 reload 步骤（noda-ops 不涉及 upstream DNS，理论上不需要）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### nginx 配置（修改目标）
- `config/nginx/nginx.conf` — 主配置文件，需添加 resolver 指令（当前无 resolver）
- `config/nginx/conf.d/default.conf` — server 块配置，proxy_pass 引用 upstream 名称
- `config/nginx/snippets/upstream-findclass.conf` — findclass upstream，使用 Docker DNS 名称 `findclass-ssr-green:3001`
- `config/nginx/snippets/upstream-keycloak.conf` — keycloak upstream，使用 Docker DNS 名称 `keycloak-green:8080`
- `config/nginx/snippets/upstream-noda-site.conf` — noda-site upstream，使用 Docker DNS 名称 `noda-site-blue:3000`

### Pipeline 脚本（修改目标）
- `scripts/pipeline-stages.sh` §`pipeline_deploy_nginx()` line 655-670 — nginx 部署函数，需添加 sleep + reload 步骤

### Docker Compose 配置
- `docker/docker-compose.yml` — nginx 服务定义（容器名、网络、restart 策略）

### 前序 Phase 决策
- `.planning/phases/43-cleanup-pipeline/43-CONTEXT.md` — Pipeline 清理体系
- `.planning/phases/45-infra-image-cleanup/45-CONTEXT.md` — infra Pipeline 镜像清理

</canonical_refs>

<code_context>
## Existing Code Insights

### 问题根因
- nginx upstream 块使用 Docker DNS 名称（如 `findclass-ssr-green:3001`）
- nginx 启动时一次性解析 DNS 并缓存，不主动刷新
- `nginx.conf` 中没有 `resolver` 指令，nginx 使用系统默认 DNS 解析行为
- `--force-recreate` 重建 nginx 容器后，新容器可能无法立即解析后端容器名称（Docker DNS 延迟或 IP 变更）

### 修改文件清单
1. `config/nginx/nginx.conf` — http 块添加 2 行（resolver + resolver_timeout）
2. `scripts/pipeline-stages.sh` — `pipeline_deploy_nginx()` 添加 sleep + docker exec reload（约 5 行）

### Established Patterns
- nginx reload 通过 `docker exec noda-infra-nginx nginx -s reload` 执行（蓝绿部署脚本中已有此模式）
- Pipeline 函数使用 `log_info`/`log_success` 日志输出
- Docker DNS 服务器地址：127.0.0.11（Docker 内置，所有容器可用）

### Integration Points
- `pipeline_deploy_nginx()` 被 `jenkins/Jenkinsfile.infra` 的 Deploy 阶段调用
- nginx reload 不会中断现有连接（graceful reload）
- resolver 指令对 upstream 块的影响：nginx reload 时重新解析 upstream DNS

</code_context>

<specifics>
## Specific Ideas

- Docker DNS 127.0.0.11 是所有 Docker 容器的内置 DNS 解析器，无需额外配置
- `valid=30s` 是 DNS 缓存 TTL，30 秒后 nginx 会重新查询 DNS。这是 Docker 容器 IP 变更场景的合理值
- nginx reload（`nginx -s reload`）是优雅重载，不会断开现有连接，只重新加载配置和刷新 DNS 缓存
- `resolver_timeout 5s` 防止 DNS 查询卡住影响请求处理

</specifics>

<deferred>
## Deferred Ideas

- nginx 蓝绿部署模式（双 nginx 容器 + upstream 切换）— 如果未来需要 nginx 自身零停机部署，可考虑此方案。当前 nginx 部署频率极低（配置变更才需要），graceful reload 已足够

</deferred>

---
*Phase: 46-nginx-blue-green*
*Context gathered: 2026-04-19*
