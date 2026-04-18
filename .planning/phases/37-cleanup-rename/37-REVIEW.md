---
phase: 37-cleanup-rename
reviewed: 2026-04-19T12:00:00Z
depth: quick
files_reviewed: 4
files_reviewed_list:
  - scripts/deploy/deploy-apps-prod.sh
  - scripts/deploy/deploy-findclass-zero-deps.sh
  - scripts/backup/lib/db-health.sh
  - scripts/backup/backup-postgres.sh
findings:
  critical: 0
  warning: 2
  info: 2
  total: 4
status: issues_found
---

# Phase 37: Code Review Report

**Reviewed:** 2026-04-19T12:00:00Z
**Depth:** quick
**Files Reviewed:** 4
**Status:** issues_found

## Summary

对 4 个 Shell 脚本进行了 quick 深度扫描（硬编码密钥、危险函数、调试残留、空 catch 块、Shell 特有模式）。未发现硬编码密钥或危险函数。发现 2 个 Warning（未加引号的变量展开、废弃脚本仍可执行致命操作）和 2 个 Info（临时文件路径硬编码、访问地址过时）。

## Critical Issues

无。

## Warnings

### WR-01: cleanup_old_backups_b2 参数未加引号

**File:** `scripts/backup/backup-postgres.sh:287`
**Issue:** `cleanup_old_backups_b2 $(get_retention_days)` 中 `$(get_retention_days)` 未加双引号。对比同一脚本第 286 行 `cleanup_old_backups "$(get_backup_dir)"` 对参数做了引号保护，第 287 行遗漏了。若 `get_retention_days` 返回空值或包含空格，会导致 word splitting，函数可能收到 0 个或多个参数，行为不可预测。
**Fix:**
```bash
cleanup_old_backups_b2 "$(get_retention_days)"
```

### WR-02: 废弃脚本 build_images 仍执行并 exit 1，但 main() 未短路

**File:** `scripts/deploy/deploy-findclass-zero-deps.sh:86,209`
**Issue:** `build_images()` 在第 86 行直接 `exit 1`（标记为废弃），但 `main()` 第 209 行无条件调用 `build_images`。虽然结果确实是脚本立即退出，但 `stop_old_containers`、`start_new_containers` 等后续步骤永远不会执行，却仍然留在代码中，给维护者造成困惑。此外，脚本第 1 行注释标记 `DEPRECATED`，但脚本仍然可执行 `decrypt_secrets()`（第 206 行），会把解密后的密钥 source 到当前 shell 环境后立刻退出，留下 `/tmp/noda-secrets/.env.prod` 文件在磁盘上。
**Fix:** 建议在 `main()` 最顶部直接输出废弃信息并退出，避免执行任何有副作用的操作（如解密密钥）：
```bash
main() {
    log_error "此脚本已废弃，请使用 deploy-infrastructure-prod.sh 或 deploy-apps-prod.sh"
    exit 1
}
```

## Info

### IN-01: 临时目录硬编码为 /tmp

**File:** `scripts/deploy/deploy-findclass-zero-deps.sh:58,69`
**Issue:** 解密后的密钥文件写入 `/tmp/noda-secrets/.env.prod`。`/tmp` 可能在系统重启后清空，且在某些系统上权限较宽松。考虑到此脚本已标记为 DEPRECATED，优先级较低。
**Fix:** 若后续仍需使用，改用 `mktemp -d` 生成临时目录。

### IN-02: show_deployment_status 显示过时的访问地址

**File:** `scripts/deploy/deploy-findclass-zero-deps.sh:189-190`
**Issue:** 显示 `前端: http://localhost:3000` 和 `Nginx: http://localhost:8080`。根据项目架构，findclass-ssr 运行在端口 3001，Nginx 在端口 80，且 Keycloak 在 8080。此信息已过时。由于脚本已废弃，影响有限。
**Fix:** 标记为废弃脚本，无需修复。若将来恢复使用，需更新端口号。

---

_Reviewed: 2026-04-19T12:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: quick_
