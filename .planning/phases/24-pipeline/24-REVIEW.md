---
phase: 24-pipeline
reviewed: 2026-04-16T09:24:00Z
depth: standard
files_reviewed: 2
files_reviewed_list:
  - jenkins/Jenkinsfile
  - scripts/pipeline-stages.sh
findings:
  critical: 1
  warning: 4
  info: 2
  total: 7
status: issues_found
---

# Phase 24: Code Review Report

**Reviewed:** 2026-04-16T09:24:00Z
**Depth:** standard
**Files Reviewed:** 2
**Status:** issues_found

## Summary

Reviewed the Jenkins Pipeline Jenkinsfile and the pipeline-stages.sh function library. The code is well-structured with clear documentation, proper error handling (`set -euo pipefail`), and good separation of concerns. However, there are several issues ranging from a critical security concern in the CDN purge function to logic bugs in the backup freshness check and environment variable handling.

Cross-referenced dependencies: `scripts/manage-containers.sh`, `scripts/lib/log.sh`, `scripts/lib/health.sh`, and `docker/docker-compose.app.yml`.

## Critical Issues

### CR-01: Cloudflare API Token 泄露到 Jenkins 构建日志

**File:** `scripts/pipeline-stages.sh:413-417`
**Issue:** `pipeline_purge_cdn` 函数将 `${CF_API_TOKEN}` 和 `${CF_ZONE_ID}` 嵌入 curl 命令行参数。当 Jenkins 执行 `sh` 步骤时，如果开启了调试模式或脚本以 `set -x` 运行，这些凭据会以明文出现在 Jenkins 构建日志中。此外，`curl` 进程参数在宿主机上通过 `/proc/<pid>/cmdline` 可被其他用户读取。

Jenkins 的 `withCredentials` 块虽然会遮掩 `sh` 步骤中的变量值，但这个保护仅限于 Jenkins Pipeline 的 Groovy 层。在 shell 脚本内部通过 `source` 加载函数并执行时，如果脚本或其调用链中存在任何 `set -x`，凭据就会泄露到日志。

**Fix:**
```bash
pipeline_purge_cdn() {
  if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ZONE_ID:-}" ]; then
    log_warn "Cloudflare 凭据未配置，跳过 CDN 缓存清除"
    return 0
  fi

  log_info "清除 CDN 缓存 (zone: $CF_ZONE_ID)..."

  # 使用 -H 传递 Authorization header，避免 token 出现在命令行参数中
  # 通过临时文件传递 JSON body，进一步降低泄露风险
  local tmp_body
  tmp_body=$(mktemp)
  echo '{"purge_everything":true}' > "$tmp_body"

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d @"$tmp_body" \
    --connect-timeout 10 \
    --max-time 30 2>/dev/null) || true

  rm -f "$tmp_body"

  if [ "$http_code" = "200" ]; then
    log_success "CDN 缓存清除完成"
  else
    log_error "CDN 缓存清除失败 (HTTP ${http_code:-timeout})，不影响部署"
  fi

  return 0
}
```

注意：`-H "Authorization: Bearer ${CF_API_TOKEN}"` 仍然会出现在 `set -x` 日志中。最安全的做法是通过环境变量传递给 curl（curl 的 `-H` 不支持环境变量内联），或使用 `.netrc` 文件。但鉴于 Jenkins `withCredentials` 的日志遮掩机制，当前方案的风险已大幅降低。关键是确保 pipeline-stages.sh 及其依赖不会启用 `set -x`。

## Warnings

### WR-01: `pipeline_failure_cleanup` 硬编码容器名绕过了 `get_container_name` 函数

**File:** `scripts/pipeline-stages.sh:440`
**Issue:** 第 440 行硬编码了 `local target_container="findclass-ssr-${target_env}"`，而同文件中其他所有函数（如 `pipeline_deploy` 第 349 行、`pipeline_health_check` 第 368 行）都通过 `get_container_name "$target_env"` 获取容器名。如果 `get_container_name` 的命名规则发生变化（例如添加前缀），此处会产生不一致。

**Fix:**
```bash
pipeline_failure_cleanup() {
  local target_env="$1"
  local target_container
  target_container=$(get_container_name "$target_env")
  # ... 其余不变
```

### WR-02: `pipeline_switch` 中 nginx 配置验证失败时回滚 upstream，但未 reload nginx

**File:** `scripts/pipeline-stages.sh:378-384`
**Issue:** 当 `docker exec "$NGINX_CONTAINER" nginx -t` 失败时，代码调用 `update_upstream "$active_env"` 回滚 upstream 配置文件，但没有执行 `reload_nginx` 使回滚生效。此时 nginx 仍在运行旧的（失败的）配置。虽然 `nginx -t` 失败意味着 nginx 没有加载新配置，所以 `reload` 不一定需要，但如果之前有某次 reload 成功了一半，不 reload 回滚配置会导致下次 reload 时使用错误的配置文件。

**Fix:**
```bash
  if ! docker exec "$NGINX_CONTAINER" nginx -t; then
    log_error "nginx 配置验证失败，回滚 upstream"
    update_upstream "$active_env"
    # 尝试 reload 使回滚生效（不检查返回值，因为 nginx 可能本身就有问题）
    docker exec "$NGINX_CONTAINER" nginx -s reload 2>/dev/null || true
    return 1
  fi
```

### WR-03: `check_backup_freshness` 中 `date -d "yesterday"` 在 macOS 上不可用

**File:** `scripts/pipeline-stages.sh:46`
**Issue:** `date -d "yesterday"` 使用的是 GNU date 语法。注释（第 68 行）提到"使用 GNU stat（Linux 生产环境）"，所以这在生产环境（Linux）上可以运行。但如果有人在 macOS 上本地测试此脚本，会直接失败。这不是阻塞性问题，但值得注意。

**Fix:** 当前行为与项目目标一致（生产环境为 Linux）。可以添加一个注释明确标记此 GNU 依赖：
```bash
  # 注意：date -d 是 GNU 扩展，仅在 Linux 上可用（macOS 的 BSD date 不支持）
  today_minus1=$(date -d "yesterday" +"%Y/%m/%d")
```

### WR-04: `pipeline_test` 使用 `cd` 改变工作目录，在 `set -e` 下可能影响后续逻辑

**File:** `scripts/pipeline-stages.sh:338-339`
**Issue:** `pipeline_test` 函数直接执行 `cd "$apps_dir"`。由于 `pipeline-stages.sh` 通过 `source` 加载到调用者的 shell 中，`cd` 会改变调用者的工作目录。虽然 Jenkins 的每个 `sh` 步骤都是独立子进程，所以实际上不会影响其他步骤，但如果将来有人在同一个 `sh` 块中连续调用多个 pipeline 函数，`cd` 的副作用会导致问题。

**Fix:**
```bash
pipeline_test() {
  local apps_dir="$1"
  (
    cd "$apps_dir"
    pnpm install --frozen-lockfile
    log_success "依赖安装完成"
  )
}
```

使用子 shell `( )` 隔离 `cd` 的副作用。

## Info

### IN-01: Jenkinsfile 每个 stage 重复 `source` 两个文件

**File:** `jenkins/Jenkinsfile:54-56, 64-66, 76-78, 91-94, 101-104, 111-114, 121-124, 135-138, 146-149, 161-163`
**Issue:** 每个 stage 的 `sh` 块都重复 `source scripts/lib/log.sh` 和 `source scripts/pipeline-stages.sh`。这是 Jenkins `sh` 步骤的限制（每次都是新的 shell 进程），无法避免，但产生了大量重复代码。

**Fix:** 可以考虑创建一个 `scripts/pipeline-init.sh` 封装两个 source 操作：
```bash
#!/bin/bash
source "$WORKSPACE/scripts/lib/log.sh"
source "$WORKSPACE/scripts/pipeline-stages.sh"
```
然后每个 stage 只需 `source scripts/pipeline-init.sh`。但这是微优化，当前方式也完全可以接受。

### IN-02: `pipeline_deploy` 中 `docker compose build` 不传递 `--no-cache` 或构建参数

**File:** `scripts/pipeline-stages.sh:329`
**Issue:** `docker compose -f "$COMPOSE_FILE" build findclass-ssr` 使用默认构建行为。根据 CLAUDE.md 中记录的"Docker 构建注意事项"，BuildKit 缓存可能导致 Dockerfile 修改未生效。在 CI/CD Pipeline 中，通常建议使用 `--no-cache` 确保构建的确定性。

**Fix:** 考虑在 Pipeline 构建中添加 `--no-cache`：
```bash
docker compose -f "$COMPOSE_FILE" build --no-cache findclass-ssr
```
或者将此作为可选参数，通过环境变量控制是否跳过缓存。

---

_Reviewed: 2026-04-16T09:24:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
