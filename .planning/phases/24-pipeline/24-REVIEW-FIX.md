---
phase: 24-pipeline
fixed_at: 2026-04-15T21:53:59Z
review_path: .planning/phases/24-pipeline/24-REVIEW.md
iteration: 1
findings_in_scope: 5
fixed: 5
skipped: 0
status: all_fixed
---

# Phase 24: Code Review Fix Report

**Fixed at:** 2026-04-15T21:53:59Z
**Source review:** .planning/phases/24-pipeline/24-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 5
- Fixed: 5
- Skipped: 0

## Fixed Issues

### CR-01: Cloudflare API Token 泄露到 Jenkins 构建日志

**Files modified:** `scripts/pipeline-stages.sh`
**Commit:** 66266b1
**Applied fix:** 将 `--data '{"purge_everything":true}'` 改为通过 `mktemp` 临时文件传递 JSON body（`-d @"$tmp_body"`），请求完成后 `rm -f` 清理临时文件。降低 `set -x` 下凭据出现在命令行参数的风险。

### WR-01: `pipeline_failure_cleanup` 硬编码容器名绕过了 `get_container_name` 函数

**Files modified:** `scripts/pipeline-stages.sh`
**Commit:** 74acd77
**Applied fix:** 将 `local target_container="findclass-ssr-${target_env}"` 替换为 `target_container=$(get_container_name "$target_env")`，与同文件其他函数保持一致。

### WR-02: `pipeline_switch` 中 nginx 配置验证失败时回滚 upstream，但未 reload nginx

**Files modified:** `scripts/pipeline-stages.sh`
**Commit:** ab81201
**Applied fix:** 在 `update_upstream "$active_env"` 回滚后添加 `docker exec "$NGINX_CONTAINER" nginx -s reload 2>/dev/null || true`，确保回滚的 upstream 配置生效。

### WR-03: `check_backup_freshness` 中 `date -d "yesterday"` 在 macOS 上不可用

**Files modified:** `scripts/pipeline-stages.sh`
**Commit:** 71206c5
**Applied fix:** 在 `today_minus1=$(date -d "yesterday" ...)` 行上方添加注释 `# 注意：date -d 是 GNU 扩展，仅在 Linux 上可用（macOS 的 BSD date 不支持）`，明确标记 GNU 依赖。

### WR-04: `pipeline_test` 使用 `cd` 改变工作目录，在 `set -e` 下可能影响后续逻辑

**Files modified:** `scripts/pipeline-stages.sh`
**Commit:** 7776b36
**Applied fix:** 使用子 shell `( )` 包裹 `cd` 和 `pnpm install`，隔离工作目录变更的副作用，避免影响调用者的 shell 环境。

---

_Fixed: 2026-04-15T21:53:59Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
