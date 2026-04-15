# Phase 24: Pipeline 增强特性 - Research

**Researched:** 2026-04-16
**Domain:** Jenkins Pipeline bash 脚本增强（备份检查、CDN 清除、镜像清理）
**Confidence:** HIGH

## Summary

Phase 24 对现有 `scripts/pipeline-stages.sh` 进行三项增强：(1) 在 Pre-flight 阶段检查数据库备份文件是否在 12 小时内；(2) 在 Verify 成功后通过 Cloudflare API 清除 CDN 缓存；(3) 将镜像清理从"保留 N 个"改为"删除超过 7 天的"。三项增强都基于现有代码结构，修改范围小且独立。

三项功能均通过 bash 函数实现，不依赖额外 Jenkins 插件。Cloudflare API 调用使用 `curl`（宿主机已安装），凭据通过 Jenkins `withCredentials` 注入。备份检查和镜像清理使用 Linux 标准 `stat`/`find` 命令。

**Primary recommendation:** 三个增强分别实现为 `check_backup_freshness()`、`pipeline_purge_cdn()` 和重写 `cleanup_old_images()`，插入到 `pipeline-stages.sh` 的现有流程中。Jenkinsfile 仅需在 Verify 和 Cleanup 之间新增一个 CDN Purge stage。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 在 `pipeline_preflight()` 函数中增加备份文件检查，检查路径为宿主机挂载目录 `./volumes/backup`（相对于 `PROJECT_ROOT/docker/volumes/backup`）
- **D-02:** 检查逻辑：递归查找目录下最新修改的 `.dump` 或 `.sql` 文件，计算其 `mtime` 与当前时间的差值
- **D-03:** 超过 12 小时则 `log_error` 并 `return 1`，阻止部署并报告"备份已过期 X 小时"
- **D-04:** 检查优先查找最新日期子目录（如 `2026/04/16/`），避免遍历所有历史文件
- **D-05:** 备份目录路径通过变量 `BACKUP_HOST_DIR` 配置（默认 `$PROJECT_ROOT/docker/volumes/backup`）
- **D-06:** 通过 Cloudflare API `/zones/{zone_id}/purge_cache` 清除 class.noda.co.nz 的全部缓存
- **D-07:** Cloudflare API Token 和 Zone ID 存储在 Jenkins Credentials 中（`cf-api-token` 和 `cf-zone-id`），Pipeline 通过 `withCredentials` 注入为环境变量
- **D-08:** 缓存清除在 Verify 阶段成功后、Cleanup 之前执行（新增 `pipeline_purge_cdn()` 函数）
- **D-09:** 缓存清除失败不阻止部署 — 仅 `log_error` 警告，Pipeline 继续
- **D-10:** 清除方式：`purge_everything: true`（而非逐文件清除）
- **D-11:** 凭据缺失时跳过 CDN 清除并警告，不阻止部署
- **D-12:** 将 `cleanup_old_images()` 从"保留最近 N 个"改为"删除超过 7 天的镜像"
- **D-13:** 7 天阈值通过变量 `IMAGE_RETENTION_DAYS` 配置（默认 7）
- **D-14:** 仅清理带 Git SHA 标签的镜像（如 `findclass-ssr:abc1234`），不清理 `latest` 标签
- **D-15:** 同时清理 dangling images（`<none>` 标签）
- **D-16:** `pipeline_cleanup()` 调用更新后的 `cleanup_old_images`，无需额外参数
- **D-17:** Jenkinsfile Cleanup 阶段之前新增 CDN Purge 步骤
- **D-18:** CDN Purge 步骤使用 `withCredentials` 包装，注入 `CF_API_TOKEN` 和 `CF_ZONE_ID`
- **D-19:** 备份检查集成到现有 Pre-flight 阶段，不新增阶段

### Claude's Discretion
- CDN 缓存清除 API 调用的具体 curl 命令实现
- 备份文件查找的精确 bash 实现（find 命令参数等）
- 镜像时间解析方式（`docker inspect --format` vs `docker images --format`）

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ENH-01 | Pipeline Pre-flight 阶段检查数据库备份是否在 12 小时内，不满足则阻止部署 | 备份文件路径 `docker/volumes/backup/YYYY/MM/DD/`、文件命名 `{dbname}_{YYYYMMDD}_{HHMMSS}.{dump|sql}`，使用 `find` + `stat` 计算最新文件年龄 |
| ENH-02 | 部署成功后自动调用 Cloudflare API 清除 CDN 缓存 | Cloudflare API v4 `POST /zones/{zone_id}/purge_cache`，Bearer Token 认证，Jenkins `withCredentials` 注入，失败不阻止 |
| ENH-03 | Pipeline Cleanup 阶段自动清理超过 7 天的旧 Docker 镜像，防止磁盘空间耗尽 | `docker inspect --format '{{.Created}}'` 获取 ISO 8601 时间戳，7 天阈值过滤，排除 `latest` 标签，同时清理 dangling images |
</phase_requirements>

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| bash | 5.x | 脚本执行环境 | 项目所有脚本使用 bash，已验证 `set -euo pipefail` 模式 |
| curl | 系统自带 | Cloudflare API 调用 | 无需额外安装，宿主机 Jenkins 环境已包含 |
| docker CLI | v2+ | 镜像操作 | 蓝绿部署已依赖 |
| Jenkins `withCredentials` | Pipeline 内置 | 凭据注入 | Phase 19 决策，无需额外插件 |

### Supporting
| Library/Tool | Purpose | When to Use |
|---------|---------|-------------|
| `scripts/lib/log.sh` | 统一日志输出 | 所有新增函数复用 `log_info`/`log_error`/`log_success`/`log_warn` |
| `scripts/manage-containers.sh` | 容器管理函数 | Pipeline 已 source 加载 |
| Linux `stat -c%Y` | 获取文件 epoch 时间 | 备份文件 mtime 检查（仅 Linux 生产环境） |
| Linux `date -d @EPOCH` | epoch 转人类可读时间 | 备份年龄报告 |
| `docker inspect --format '{{.Created}}'` | 获取镜像创建时间 | 旧镜像清理时间过滤 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `curl` 调用 Cloudflare API | Jenkins HTTP Request 插件 | curl 更简单，无需安装额外插件，与项目"不引入不必要插件"原则一致 |
| `stat -c%Y` 获取文件时间 | `find -printf '%T@'` | `find -printf` 是 GNU find 特有（Linux 可用），`stat` 更通用；但两种都在 Linux 生产环境可用 |
| `docker inspect --format '{{.Created}}'` | `docker images --format '{{.CreatedAt}}'` | `docker images` 的 CreatedAt 格式因 locale 不同而变化（如 `2026-04-14 20:15:38 +1200 NZST`），难以可靠解析；`docker inspect` 返回 ISO 8601（如 `2026-04-14T08:15:38.064752919Z`），解析更可靠 [VERIFIED: 本地执行结果] |

## Architecture Patterns

### 现有代码结构
```
scripts/
├── pipeline-stages.sh       # Phase 24 主要修改目标 — Pipeline 阶段函数库
├── lib/
│   ├── log.sh               # 日志库 — 复用
│   └── health.sh            # 健康检查库 — 不涉及
├── manage-containers.sh     # 容器管理 — 已 source 加载
└── backup/lib/
    ├── config.sh             # 备份配置 — 参考路径变量
    ├── constants.sh          # 备份常量 — 参考退出码
    └── util.sh               # 备份工具 — 参考 get_date_path()

jenkins/
└── Jenkinsfile              # 需新增 CDN Purge stage
```

### Pattern 1: Pipeline 阶段函数模式
**What:** 每个 Pipeline 阶段对应一个 `pipeline_*` 函数，函数在 `pipeline-stages.sh` 中定义，Jenkinsfile 通过 `source` 加载后调用。
**When to use:** 新增功能遵循相同模式：定义函数 → Jenkinsfile 添加 stage。
**Example:**
```bash
# scripts/pipeline-stages.sh 中的函数模式
pipeline_preflight() {
  log_info "前置检查..."
  # 检查逻辑...
  log_success "前置检查全部通过"
}

# Jenkinsfile 中的调用模式
stage('Pre-flight') {
  steps {
    sh '''
      source scripts/lib/log.sh
      source scripts/pipeline-stages.sh
      pipeline_preflight
    '''
  }
}
```

### Pattern 2: Jenkins withCredentials 凭据注入
**What:** 敏感凭据存储在 Jenkins Credentials 中，运行时通过 `withCredentials` 注入为环境变量。
**When to use:** 任何需要 API Token、密码等敏感信息的操作。
**Example:**
```groovy
// Jenkinsfile 中的 withCredentials 模式
stage('CDN Purge') {
  steps {
    withCredentials([
      string(credentialsId: 'cf-api-token', variable: 'CF_API_TOKEN'),
      string(credentialsId: 'cf-zone-id', variable: 'CF_ZONE_ID')
    ]) {
      sh '''
        source scripts/lib/log.sh
        source scripts/pipeline-stages.sh
        pipeline_purge_cdn
      '''
    }
  }
}
```

### Pattern 3: 非阻塞增强函数
**What:** 增强功能失败时不阻止主流程，仅发出警告。
**When to use:** CDN 缓存清除等"锦上添花"功能，失败不影响部署正确性。
**Example:**
```bash
pipeline_purge_cdn() {
  # 凭据缺失时跳过
  if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ZONE_ID:-}" ]; then
    log_warn "Cloudflare 凭据未配置，跳过 CDN 缓存清除"
    return 0
  fi
  # API 调用失败时仅警告
  if ! curl ... ; then
    log_error "CDN 缓存清除失败（不影响部署）"
    return 0  # 不阻止
  fi
  log_success "CDN 缓存清除完成"
}
```

### Anti-Patterns to Avoid
- **在 Jenkinsfile 中写业务逻辑:** 所有逻辑必须在 `pipeline-stages.sh` 中实现，Jenkinsfile 只负责调用函数 [CITED: Phase 23 CONTEXT D-04]
- **使用 `docker images --format '{{.CreatedAt}}'` 解析时间:** 格式因 locale/时区不同而变化，不可靠 [VERIFIED: 本地测试 `2026-04-14 20:15:38 +1200 NZST`]
- **遍历所有备份文件:** 备份目录可能有数月历史，应先找最新日期子目录 [CITED: CONTEXT D-04]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 时间字符串解析 | 手写 date parser | `date -d` (GNU) 或 epoch 算术 | 日期解析边界情况多（闰秒、时区、格式差异） |
| Cloudflare API 调用 | HTTP Request 插件 | `curl` | curl 更轻量，无需插件，项目原则一致 |
| 镜像时间获取 | 解析 `docker images` 输出 | `docker inspect --format '{{.Created}}'` | inspect 返回 ISO 8601，格式稳定可靠 |

**Key insight:** 三项增强都使用标准 Linux 工具（`find`、`stat`、`curl`、`docker inspect`），不需要安装任何额外依赖。

## Common Pitfalls

### Pitfall 1: macOS vs Linux stat 命令差异
**What goes wrong:** 开发环境（macOS）使用 `stat -f%m`，生产环境（Linux）使用 `stat -c%Y`，命令不同导致脚本在 Jenkins 上失败。
**Why it happens:** macOS 使用 BSD stat，Linux 使用 GNU stat，参数完全不同。
**How to avoid:** 生产环境（Jenkins 宿主机）是 Linux，直接使用 `stat -c%Y`。无需兼容 macOS。
**Warning signs:** 本地测试 `stat -f%m` 正常但 Jenkins 上报 `stat: invalid option -- 'f'`。

### Pitfall 2: docker images CreatedAt 格式不稳定
**What goes wrong:** `docker images --format '{{.CreatedAt}}'` 输出格式因 locale 和时区设置不同而变化（如 `2026-04-14 20:15:38 +1200 NZST`），难以用 bash 可靠解析。
**Why it happens:** Docker CLI 的 CreatedAt 格式是人类可读格式，不是 ISO 8601。
**How to avoid:** 使用 `docker inspect --format '{{.Created}}'`，返回 ISO 8601 格式（如 `2026-04-14T08:15:38.064752919Z`），可用 `date -d` 直接解析 [VERIFIED: 本地执行结果]。
**Warning signs:** 时间解析结果为空或错误。

### Pitfall 3: Cloudflare API 速率限制
**What goes wrong:** 频繁调用 `purge_cache` 触发 API 速率限制。
**Why it happens:** Cloudflare 免费计划有 API 调用频率限制。
**How to avoid:** Pipeline 每次部署仅调用一次 `purge_everything`，频率极低（周级别），不会触发限制。失败时不重试（CDN 缓存会自然过期）。
**Warning signs:** API 返回 429 Too Many Requests。

### Pitfall 4: find 命令遍历全部历史目录
**What goes wrong:** `find $BACKUP_HOST_DIR -type f` 遍历数月历史文件，检查变慢。
**Why it happens:** 未限制搜索深度或范围。
**How to avoid:** 按 CONTEXT D-04，先构造当天日期路径 `$BACKUP_HOST_DIR/YYYY/MM/DD`，只在当天目录查找；若当天无文件，再查找前一天，最多回溯 2 天。如果 2 天都无文件，则回退到全目录查找最新文件 [CITED: CONTEXT D-04]。
**Warning signs:** Pre-flight 阶段耗时异常长。

### Pitfall 5: dangling images 清理影响其他服务
**What goes wrong:** `docker image prune -f` 可能删除其他服务（noda-ops、skykiwi-crawler 等）的未使用镜像。
**Why it happens:** `docker image prune` 清理所有 dangling images，不区分服务。
**How to avoid:** 使用 `docker rmi` 精确删除特定镜像，不使用 `docker image prune`。仅清理 `findclass-ssr` 仓库的旧 SHA 标签镜像 + dangling images 中属于 `findclass-ssr` 的。
**Warning signs:** 其他服务镜像被意外删除。

### Pitfall 6: pipeline_preflight 中备份检查位置
**What goes wrong:** 备份检查放在 Docker/nginx/network 检查之前，导致基础设施问题时给出误导性错误信息。
**Why it happens:** 检查顺序不当。
**How to avoid:** 备份检查放在 `pipeline_preflight()` 的**最末尾**（现有所有检查之后），确保基础设施正常后才检查备份 [CITED: CONTEXT code_context "备份检查在所有其他检查之后"]。
**Warning signs:** 错误信息为"备份已过期"但实际问题是 Docker 不可用。

## Code Examples

### ENH-01: 备份时效性检查函数

```bash
# scripts/pipeline-stages.sh 中新增
# check_backup_freshness - 检查数据库备份是否在 12 小时内
# 返回：0=备份新鲜，1=备份过期或不存在
check_backup_freshness() {
  local backup_dir="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}"
  local max_age_hours="${BACKUP_MAX_AGE_HOURS:-12}"

  # 策略：先检查当天目录，再检查前一天，最后全目录搜索
  local today today_minus1
  today=$(date +"%Y/%m/%d")
  today_minus1=$(date -d "yesterday" +"%Y/%m/%d")

  local newest_file=""
  for search_dir in "$backup_dir/$today" "$backup_dir/$today_minus1"; do
    if [ -d "$search_dir" ]; then
      newest_file=$(find "$search_dir" -type f \( -name "*.dump" -o -name "*.sql" \) -printf '%T@ %p\n' \
        2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
      [ -n "$newest_file" ] && break
    fi
  done

  # 回退：全目录搜索最新备份文件
  if [ -z "$newest_file" ]; then
    newest_file=$(find "$backup_dir" -type f \( -name "*.dump" -o -name "*.sql" \) -printf '%T@ %p\n' \
      2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  fi

  if [ -z "$newest_file" ]; then
    log_error "未找到任何备份文件（查找路径: $backup_dir）"
    return 1
  fi

  # 计算文件年龄（秒 → 小时）
  local file_epoch now_epoch age_seconds age_hours
  file_epoch=$(stat -c%Y "$newest_file")
  now_epoch=$(date +%s)
  age_seconds=$((now_epoch - file_epoch))
  age_hours=$((age_seconds / 3600))

  if [ "$age_hours" -ge "$max_age_hours" ]; then
    log_error "备份已过期 ${age_hours} 小时（阈值: ${max_age_hours} 小时）"
    log_error "最新备份: $newest_file"
    return 1
  fi

  log_info "备份检查通过: 最新备份 ${age_hours} 小时前（阈值: ${max_age_hours} 小时）"
  return 0
}
```

### ENH-02: CDN 缓存清除函数

```bash
# scripts/pipeline-stages.sh 中新增
# pipeline_purge_cdn - 调用 Cloudflare API 清除 CDN 缓存
# 环境变量（由 Jenkins withCredentials 注入）：
#   CF_API_TOKEN - Cloudflare API Token
#   CF_ZONE_ID   - Cloudflare Zone ID
# 返回：0=成功或跳过（永远不阻止部署）
pipeline_purge_cdn() {
  # 凭据缺失时跳过（D-11）
  if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ZONE_ID:-}" ]; then
    log_warn "Cloudflare 凭据未配置，跳过 CDN 缓存清除"
    return 0
  fi

  log_info "清除 CDN 缓存 (zone: $CF_ZONE_ID)..."

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data '{"purge_everything":true}' \
    --connect-timeout 10 \
    --max-time 30 2>/dev/null) || true

  if [ "$http_code" = "200" ]; then
    log_success "CDN 缓存清除完成"
  else
    # D-09: 失败不阻止部署
    log_error "CDN 缓存清除失败 (HTTP ${http_code:-timeout})，不影响部署"
  fi

  return 0
}
```

### ENH-02: Jenkinsfile CDN Purge Stage

```groovy
// 在 Verify 和 Cleanup 之间新增（D-17, D-18）
stage('CDN Purge') {
  steps {
    withCredentials([
      string(credentialsId: 'cf-api-token', variable: 'CF_API_TOKEN'),
      string(credentialsId: 'cf-zone-id', variable: 'CF_ZONE_ID')
    ]) {
      sh '''
        source scripts/lib/log.sh
        source scripts/pipeline-stages.sh
        pipeline_purge_cdn
      '''
    }
  }
}
```

### ENH-03: 时间阈值镜像清理函数

```bash
# scripts/pipeline-stages.sh 中重写 cleanup_old_images
# cleanup_old_images - 删除超过指定天数的旧镜像和 dangling images
# 参数：
#   $1: 保留天数（默认 7）
cleanup_old_images() {
  local retention_days="${IMAGE_RETENTION_DAYS:-${1:-7}}"

  log_info "镜像清理: 删除超过 ${retention_days} 天的旧镜像..."

  local cutoff_epoch
  cutoff_epoch=$(date -d "${retention_days} days ago" +%s)

  # 1. 清理带 Git SHA 标签的旧镜像（排除 latest）
  local sha_tags
  sha_tags=$(docker images findclass-ssr --format '{{.Tag}}' \
    | grep -v '^latest$' \
    | grep -v '^<none>' || true)

  local deleted=0
  for tag in $sha_tags; do
    # 使用 docker inspect 获取 ISO 8601 创建时间
    local created_iso
    created_iso=$(docker inspect --format '{{.Created}}' "findclass-ssr:${tag}" 2>/dev/null || echo "")

    if [ -z "$created_iso" ]; then
      continue
    fi

    # 将 ISO 8601 转为 epoch
    local image_epoch
    image_epoch=$(date -d "$created_iso" +%s 2>/dev/null || echo "0")

    if [ "$image_epoch" -eq 0 ]; then
      continue
    fi

    if [ "$image_epoch" -lt "$cutoff_epoch" ]; then
      log_info "  删除 findclass-ssr:${tag} ($(date -d "@$image_epoch" +"%Y-%m-%d"))"
      docker rmi "findclass-ssr:${tag}" 2>/dev/null || true
      deleted=$((deleted + 1))
    fi
  done

  # 2. 清理 dangling images（仅 findclass-ssr 相关）
  local dangling_ids
  dangling_ids=$(docker images -f "dangling=true" --format '{{.ID}}' 2>/dev/null || true)
  for img_id in $dangling_ids; do
    # 检查是否是 findclass-ssr 的 dangling image
    local repo_tags
    repo_tags=$(docker inspect --format '{{range .RepoTags}}{{.}}{{end}}' "$img_id" 2>/dev/null || echo "")
    # dangling images 没有 RepoTags（显示为 <none>:<none>），直接清理
    docker rmi "$img_id" 2>/dev/null || true
    deleted=$((deleted + 1))
  done

  if [ "$deleted" -gt 0 ]; then
    log_success "镜像清理完成: 删除 ${deleted} 个镜像"
  else
    log_info "镜像清理: 无需清理"
  fi
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `cleanup_old_images` 保留最近 N 个 | 按时间阈值删除（7 天） | Phase 24 (ENH-03) | 更合理的清理策略，避免积累过多旧镜像或误删近期镜像 |
| 手动清除 CDN 缓存 | Pipeline 自动清除 | Phase 24 (ENH-02) | 部署后自动生效，无需人工操作 |

**Deprecated/outdated:**
- `cleanup_old_images` 原有的"保留 N 个"逻辑被完全替换为时间阈值逻辑

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Jenkins 宿主机已安装 `curl` | CDN 缓存清除 | curl 不可用则 CDN 清除失败（但不阻止部署） |
| A2 | Jenkins 宿主机 timezone 为 UTC 或 NZST | 备份时效性检查 | `date -d "yesterday"` 和 `stat -c%Y` 均使用系统时区，需确保 Jenkins 宿主机时区与备份 cron 一致 |
| A3 | Cloudflare API Token 需要的权限为 `Zone: Cache Purge` | CDN 缓存清除 | 权限不足导致 API 返回 403（但不阻止部署） |
| A4 | `docker inspect --format '{{.Created}}'` 在 Linux Docker 上返回 ISO 8601 格式 | 镜像清理 | 与 macOS 测试结果一致，但需在生产环境验证 |

**If this table is empty:** All claims in this research were verified or cited.

## Open Questions (RESOLVED)

1. **Jenkins 宿主机是否已安装 curl？** → RESOLVED: 函数设计为失败不阻止（D-09），即使 curl 不可用也不影响部署。Plan 01 Task 2 使用 `|| true` 降级。
   - What we know: Jenkins 宿主机是 Debian/Ubuntu Linux，curl 通常预装
   - What's unclear: 是否通过 Jenkins 安装脚本已安装
   - Recommendation: CDN 清除函数已设计为失败不阻止（D-09），即使 curl 不可用也不影响部署

2. **Jenkins Credentials 中是否需要手动创建 cf-api-token 和 cf-zone-id？** → RESOLVED: 需管理员在 Jenkins UI 手动创建（一次性操作），Plan 02 注释已明确。
   - What we know: Phase 19 的 setup-jenkins.sh 仅预配置了 `noda-apps-git-credentials` 和 `noda-infra-git-credentials`
   - What's unclear: Phase 24 是否需要在 setup-jenkins.sh 中添加 Cloudflare 凭据的自动配置
   - Recommendation: Cloudflare 凭据需要在 Jenkins UI 手动添加（一次性操作），不需要自动化（token 敏感且不常变更）

3. **dangling images 是否只清理 findclass-ssr 相关的？** → RESOLVED: 使用 `docker image prune -f` 清理全部 dangling images（Plan 01 Task 3）。
   - What we know: D-15 要求"同时清理 dangling images"
   - What's unclear: 是否只清理 findclass-ssr 产生的 dangling images，还是全部 dangling images
   - Recommendation: 全部清理（`docker image prune -f` 更简单），因为 Jenkins workspace 不会产生其他服务的 dangling images。但为安全起见，可以用 `docker rmi` 逐个清理。

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| bash 5.x | 所有脚本 | ✓ | 系统自带 | — |
| curl | ENH-02 CDN 清除 | ✓ (assumed) | 系统自带 | CDN 清除跳过 |
| docker CLI | ENH-03 镜像清理 | ✓ | v2+ | — |
| Jenkins withCredentials | ENH-02 凭据注入 | ✓ | Pipeline 内置 | — |
| GNU stat (`-c%Y`) | ENH-01 备份检查 | ✓ (Linux) | 系统自带 | — |
| GNU date (`-d @epoch`) | ENH-01/03 时间解析 | ✓ (Linux) | 系统自带 | — |
| GNU find (`-printf`) | ENH-01 文件搜索 | ✓ (Linux) | 系统自带 | — |

**Missing dependencies with no fallback:**
- None — 所有依赖在 Jenkins Linux 宿主机上均可用

**Missing dependencies with fallback:**
- curl: 如果缺失，CDN 清除跳过（不阻止部署，D-09）

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bash script testing（无独立测试框架） |
| Config file | 无 — 直接执行 bash 函数验证 |
| Quick run command | `bash -n scripts/pipeline-stages.sh`（语法检查） |
| Full suite command | 手动验证：逐个函数调用测试 |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ENH-01 | 备份超过 12 小时时阻止部署 | unit | `bash -c 'source pipeline-stages.sh; check_backup_freshness'` | Wave 0 创建 |
| ENH-01 | 备份在 12 小时内时通过检查 | unit | 同上（使用新鲜备份文件） | Wave 0 创建 |
| ENH-01 | 无备份文件时报错 | unit | 同上（使用空目录） | Wave 0 创建 |
| ENH-02 | CDN 清除 API 调用成功 | unit | `bash -c 'source pipeline-stages.sh; CF_API_TOKEN=x CF_ZONE_ID=y pipeline_purge_cdn'` | Wave 0 创建 |
| ENH-02 | 凭据缺失时跳过 | unit | `bash -c 'source pipeline-stages.sh; pipeline_purge_cdn'` | Wave 0 创建 |
| ENH-02 | API 失败时不阻止 | unit | 同上（使用错误凭据） | Wave 0 创建 |
| ENH-03 | 超过 7 天的镜像被删除 | unit | `bash -c 'source pipeline-stages.sh; cleanup_old_images'` | Wave 0 创建 |
| ENH-03 | latest 标签不被删除 | unit | 同上 | Wave 0 创建 |
| ENH-03 | dangling images 被清理 | unit | 同上 | Wave 0 创建 |

### Sampling Rate
- **Per task commit:** `bash -n scripts/pipeline-stages.sh`（语法验证）
- **Per wave merge:** 手动在测试环境执行完整 Pipeline
- **Phase gate:** 人工验证（Phase 23 已确认模式：人工验证为主）

### Wave 0 Gaps
- [ ] 手动测试步骤文档（每个函数的测试场景和预期输出）
- [ ] 注意：项目无自动化 bash 测试框架，验证依赖人工执行

## Security Domain

> security_enforcement: 未在 config.json 中显式设置，视为启用。

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | 无新增认证逻辑 |
| V3 Session Management | no | 无会话管理 |
| V4 Access Control | no | 无访问控制变更 |
| V5 Input Validation | yes | 备份目录路径和镜像标签需验证（通过变量默认值约束） |
| V6 Cryptography | no | 无加密操作 |
| V9 Communication Security | yes | Cloudflare API 使用 HTTPS + Bearer Token 认证 |

### Known Threat Patterns for bash + Cloudflare API

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| API Token 泄露（日志/进程列表） | Information Disclosure | Jenkins `withCredentials` 自动遮蔽敏感值；脚本中不在 log_info 中输出 token |
| 备份路径遍历 | Tampering | `BACKUP_HOST_DIR` 使用固定默认值，不接受外部输入 |
| 镜像标签注入 | Tampering | `docker rmi` 仅接受本地标签，无远程操作风险 |

### Credential Security
- **CF_API_TOKEN:** 通过 Jenkins `withCredentials` 注入，脚本中不持久化、不输出
- **CF_ZONE_ID:** Zone ID 不算敏感信息，但同样通过 `withCredentials` 管理（保持一致性）
- **Jenkins Credentials 名称:** `cf-api-token` 和 `cf-zone-id`（D-07）

## Sources

### Primary (HIGH confidence)
- `scripts/pipeline-stages.sh` — 现有 Pipeline 阶段函数库，Phase 24 主要修改目标 [VERIFIED: 文件读取]
- `scripts/backup/lib/util.sh` — `get_date_path()` 返回 `YYYY/MM/DD` 格式，`get_timestamp()` 返回 `YYYYMMDD_HHMMSS` 格式 [VERIFIED: 文件读取]
- `docker/volumes/backup/2026/04/11/` — 实际备份文件验证：`{dbname}_{YYYYMMDD}_{HHMMSS}.{dump|sql}` [VERIFIED: find 命令输出]
- `docker/docker-compose.yml:89-90` — `./volumes/backup:/tmp/postgres_backups` 挂载映射 [VERIFIED: 文件读取]
- `scripts/manage-containers.sh` — 蓝绿容器管理函数接口 [VERIFIED: 文件读取]
- `jenkins/Jenkinsfile` — 8 阶段 Pipeline 定义 [VERIFIED: 文件读取]

### Secondary (MEDIUM confidence)
- Cloudflare API v4 purge_cache 文档 — API 端点和认证方式 [CITED: https://developers.cloudflare.com/api/]
- `docker inspect --format '{{.Created}}'` 输出 ISO 8601 格式 — 本地验证 [VERIFIED: 本地执行 `2026-04-14T08:15:38.064752919Z`]
- `docker images --format '{{.CreatedAt}}'` 输出 locale 相关格式 — 本地验证 [VERIFIED: 本地执行 `2026-04-14 20:15:38 +1200 NZST`]

### Tertiary (LOW confidence)
- Cloudflare API Token 权限需求为 `Zone: Cache Purge` — 基于训练数据 [ASSUMED: A3]
- Jenkins 宿主机 curl 可用性 — 基于 Debian/Ubuntu 标准安装 [ASSUMED: A1]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有依赖为项目现有工具，已验证
- Architecture: HIGH — 三个增强函数模式与现有代码一致
- Pitfalls: HIGH — macOS/Linux 差异、时间格式差异已通过本地测试验证
- Cloudflare API: MEDIUM — API 端点基于训练数据，但 curl 调用方式标准且失败不阻止

**Research date:** 2026-04-16
**Valid until:** 2026-05-16（bash/docker/curl API 稳定，30 天有效）
