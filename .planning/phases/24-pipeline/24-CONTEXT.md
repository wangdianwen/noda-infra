# Phase 24: Pipeline 增强特性 - Context

**Gathered:** 2026-04-16
**Status:** Ready for planning

<domain>
## Phase Boundary

Pipeline 在部署前检查备份时效性，部署后自动清除 CDN 缓存，Cleanup 阶段改为按时间清理旧镜像。范围包括：
- Pre-flight 阶段增加备份文件时效性检查（ENH-01）
- 部署成功后自动调用 Cloudflare API 清除 CDN 缓存（ENH-02）
- Cleanup 阶段改为按 7 天时间阈值清理旧 Docker 镜像（ENH-03）

</domain>

<decisions>
## Implementation Decisions

### 备份时效性检查（ENH-01）
- **D-01:** 在 `pipeline_preflight()` 函数中增加备份文件检查，检查路径为宿主机挂载目录 `./volumes/backup`（相对于 `PROJECT_ROOT/docker/volumes/backup`）
- **D-02:** 检查逻辑：递归查找目录下最新修改的 `.dump` 或 `.sql` 文件，计算其 `mtime` 与当前时间的差值
- **D-03:** 超过 12 小时则 `log_error` 并 `return 1`，阻止部署并报告"备份已过期 X 小时"
- **D-04:** 检查优先查找最新日期子目录（如 `2026/04/16/`），避免遍历所有历史文件
- **D-05:** 备份目录路径通过变量 `BACKUP_HOST_DIR` 配置（默认 `$PROJECT_ROOT/docker/volumes/backup`），方便后续调整

### CDN 缓存清除（ENH-02）
- **D-06:** 通过 Cloudflare API `/zones/{zone_id}/purge_cache` 清除 class.noda.co.nz 的全部缓存
- **D-07:** Cloudflare API Token 和 Zone ID 存储在 Jenkins Credentials 中（`cf-api-token` 和 `cf-zone-id`），Pipeline 通过 `withCredentials` 注入为环境变量
- **D-08:** 缓存清除在 Verify 阶段成功后、Cleanup 之前执行（新增 `pipeline_purge_cdn()` 函数）
- **D-09:** 缓存清除失败不阻止部署 — 仅 `log_error` 警告，Pipeline 继续（CDN 缓存最终会自然过期）
- **D-10:** 清除方式：`purge_everything: true`（而非逐文件清除），简单可靠且 API 调用次数最少
- **D-11:** 凭据缺失时跳过 CDN 清除并警告，不阻止部署

### 旧镜像清理（ENH-03）
- **D-12:** 将 `cleanup_old_images()` 从"保留最近 N 个"改为"删除超过 7 天的镜像"
- **D-13:** 7 天阈值通过变量 `IMAGE_RETENTION_DAYS` 配置（默认 7）
- **D-14:** 仅清理带 Git SHA 标签的镜像（如 `findclass-ssr:abc1234`），不清理 `latest` 标签
- **D-15:** 同时清理 dangling images（`<none>` 标签）以回收更多空间
- **D-16:** `pipeline_cleanup()` 调用更新后的 `cleanup_old_images`，无需额外参数

### Jenkinsfile 变更
- **D-17:** Jenkinsfile Cleanup 阶段之前新增 CDN Purge 步骤（在 Verify 和 Cleanup 之间）
- **D-18:** CDN Purge 步骤使用 `withCredentials` 包装，注入 `CF_API_TOKEN` 和 `CF_ZONE_ID`
- **D-19:** 备份检查集成到现有 Pre-flight 阶段，不新增阶段

### Claude's Discretion
- CDN 缓存清除 API 调用的具体 curl 命令实现
- 备份文件查找的精确 bash 实现（find 命令参数等）
- 镜像时间解析方式（`docker inspect --format` vs `docker images --format`）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 23 产出（直接依赖）
- `scripts/pipeline-stages.sh` — Pipeline 阶段函数库，Phase 24 主要修改目标
- `jenkins/Jenkinsfile` — 8 阶段 Pipeline 定义，需增加 CDN Purge 步骤

### 备份系统
- `scripts/backup/lib/config.sh` — 备份配置管理（BACKUP_DIR 变量、备份路径结构）
- `scripts/backup/backup-postgres.sh` — 备份主脚本，了解备份文件命名格式
- `docker/volumes/backup/` — 备份文件宿主机挂载目录（实际路径）

### Cloudflare 配置
- `docker/docker-compose.yml:87-88` — Cloudflare Tunnel 配置（已有 CLOUDFLARE_TUNNEL_TOKEN）
- `.env.production:17` — 现有 Cloudflare 环境变量

### Docker 配置
- `docker/docker-compose.app.yml` — findclass-ssr 构建配置
- `deploy/Dockerfile.findclass-ssr` — 镜像构建文件

### 前置阶段决策
- `.planning/phases/23-pipeline-integration/23-CONTEXT.md` — Pipeline 函数库设计、Pre-flight 单一真相源
- `.planning/phases/22-blue-green-deploy/22-CONTEXT.md` — cleanup_old_images 原始设计
- `.planning/phases/19-jenkins/19-CONTEXT.md` — Jenkins 凭据管理方式

### 需求文档
- `.planning/REQUIREMENTS.md` — ENH-01, ENH-02, ENH-03 需求定义
- `.planning/ROADMAP.md` Phase 24 — 成功标准

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/pipeline-stages.sh:134-163` — `cleanup_old_images()` 需要重写为时间阈值
- `scripts/pipeline-stages.sh:169-234` — `pipeline_preflight()` 是备份检查的插入点
- `scripts/pipeline-stages.sh:312-315` — `pipeline_cleanup()` 调用 `cleanup_old_images`
- `scripts/lib/log.sh` — 统一日志库，所有新函数复用
- `scripts/manage-containers.sh` — 容器管理函数库（`get_container_name` 等可能用到）

### Established Patterns
- Jenkins 凭据通过 `withCredentials` 注入（Phase 19 决策）
- Pipeline 阶段函数通过 `source scripts/pipeline-stages.sh` 加载
- 日志统一使用 `log_info`/`log_error`/`log_success`
- 备份文件命名格式：`{dbname}_{YYYYMMDD}_{HHMMSS}.{dump|sql}`
- 备份目录结构：`volumes/backup/{YYYY}/{MM}/{DD}/{files}`

### Integration Points
- `pipeline_preflight()` 末尾（备份检查在所有其他检查之后）
- `pipeline_cleanup()` 之前新增 `pipeline_purge_cdn()` 函数
- Jenkinsfile Verify 和 Cleanup 之间新增 CDN Purge stage
- Jenkins Credentials 系统需要新增 `cf-api-token` 和 `cf-zone-id` 两条凭据

</code_context>

<specifics>
## Specific Ideas

- 备份检查函数 `check_backup_freshness()` 应返回备份年龄（小时），便于日志报告
- CDN 清除使用 `purge_everything: true` 最简单，Cloudflare 免费计划支持
- Jenkins 需要安装 HTTP Request 插件或直接用 curl 调用 Cloudflare API（curl 更简单，无需额外插件）
- Cloudflare API 调用：`curl -X POST "https://api.cloudflare.com/client/v4/zones/{zone_id}/purge_cache" -H "Authorization: Bearer {token}" -H "Content-Type: application/json" --data '{"purge_everything":true}'`

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 24-pipeline*
*Context gathered: 2026-04-16*
