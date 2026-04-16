---
phase: 25-cleanup-migration
reviewed: 2026-04-16T12:00:00Z
depth: standard
files_reviewed: 3
files_reviewed_list:
  - scripts/deploy/deploy-infrastructure-prod.sh
  - scripts/deploy/deploy-apps-prod.sh
  - CLAUDE.md
findings:
  critical: 0
  warning: 3
  info: 3
  total: 6
status: issues_found
---

# Phase 25: Code Review Report

**Reviewed:** 2026-04-16T12:00:00Z
**Depth:** standard
**Files Reviewed:** 3
**Status:** issues_found

## Summary

审查了 3 个文件的变更：两个部署脚本添加了 Jenkins 回退说明注释，CLAUDE.md 更新了部署命令章节以反映 Jenkins Pipeline 为主要部署方式。

变更本身范围较小（注释更新和文档结构调整），未引入新的逻辑代码。但在审查已有脚本完整内容时，发现了一些既存的质量问题，包括：`verify-infrastructure.sh` 使用过时的 `docker-compose` 命令（与脚本调用方使用的 `docker compose` v2 不一致）、`deploy-apps-prod.sh` 中 noda-site 回滚使用了追加写 YAML 的不安全模式、以及健康检查失败后仅记录日志未触发回滚。

## Warnings

### WR-01: verify-infrastructure.sh 使用过时的 docker-compose v1 命令

**File:** `scripts/verify/verify-infrastructure.sh:13-14`
**Issue:** `deploy-apps-prod.sh` 第 109 行调用 `bash scripts/verify/verify-infrastructure.sh`，但该验证脚本内部使用 `docker-compose`（v1 带连字符的命令），而两个部署脚本和项目其余部分统一使用 `docker compose`（v2 子命令）。如果服务器上未安装 docker-compose v1 兼容层，验证步骤会失败，导致应用部署中断。
**Fix:** 将 `verify-infrastructure.sh` 中的 `docker-compose` 替换为 `docker compose`：
```bash
# 第 13 行和第 18 行
docker compose -f docker/docker-compose.yml ps
docker compose -f docker/docker-compose.yml ps | grep -q "$service.*Up"
```

### WR-02: noda-site 回滚时追加写 YAML 可能产生格式错误

**File:** `scripts/deploy/deploy-apps-prod.sh:88-91`
**Issue:** `rollback_app()` 函数在追加 noda-site 回滚条目时使用 `cat >> "$rollback_compose"` 追加内容到 YAML 文件。如果 `findclass-ssr` 的回滚块已经写入了尾部换行，追加的内容可能产生格式不一致；更重要的是，如果第一次 `cat` 写入的 YAML_HEADER 块缺少尾部换行，追加的 `noda-site:` 缩进将不正确。虽然当前 `cat >` 写入的头部以 `services:` 换行结尾，但这种追加模式在 YAML 生成中是脆弱的。
**Fix:** 将两个服务的回滚条目一次性写入同一个文件，而非先写后追加：
```bash
# 一次性生成包含所有需要回滚服务的 YAML
{
  echo "services:"
  echo "  findclass-ssr:"
  echo "    image: ${image_id}"
  if [ -n "$noda_site_image_id" ]; then
    echo "  noda-site:"
    echo "    image: ${noda_site_image_id}"
  fi
} > "$rollback_compose"
```

### WR-03: noda-site 健康检查失败不触发回滚

**File:** `scripts/deploy/deploy-apps-prod.sh:157-159`
**Issue:** `findclass-ssr` 健康检查失败时会自动回滚（第 150-154 行），但 `noda-site` 健康检查失败时只记录了 `log_error`，既不回滚也不以非零退出码终止脚本。这意味着 noda-site 部署失败时脚本仍会输出 "应用部署完成" 的成功消息，给运维人员造成误导。由于脚本开头设置了 `set -e`，`wait_container_healthy` 失败返回非零时本应终止脚本，但 `if !` 结构会吞掉该错误，阻止 `set -e` 生效。
**Fix:** noda-site 健康检查失败时也应触发回滚或至少以非零退出码终止：
```bash
log_info "等待 noda-site 健康检查..."
if ! wait_container_healthy noda-site 30; then
  log_error "noda-site 健康检查失败，尝试回滚..."
  rollback_app || true
  exit 1
fi
```

## Info

### IN-01: deploy-infrastructure-prod.sh 重复的头部注释块

**File:** `scripts/deploy/deploy-infrastructure-prod.sh:1-21`
**Issue:** 新增的 "手动回退部署脚本" 注释块（第 1-12 行）与原有的 "基础设施部署脚本" 注释块（第 14-20 行）在内容上有部分重叠（都提到了 "自动部署并配置基础设施服务"）。合并为一个注释块会更清晰。
**Fix:** 将两个注释块合并为一个：
```bash
#!/bin/bash
# ============================================
# 手动回退部署脚本（生产环境）
# ============================================
# NOTE: 此脚本作为 Jenkins Pipeline 不可用时的紧急回退方案保留。
# 正常部署请使用 Jenkins Pipeline（Build Now -> findclass-deploy）。
#
# 功能：自动部署并配置基础设施服务
# 包括：PostgreSQL (Prod/Dev), Keycloak, Nginx, Noda-Ops, Findclass-SSR
# 此脚本行为不变，可直接手动执行。
# ============================================
```

### IN-02: verify-infrastructure.sh 仅检查 compose 基础文件，缺少 prod overlay

**File:** `scripts/verify/verify-infrastructure.sh:13`
**Issue:** 该验证脚本仅使用 `-f docker/docker-compose.yml` 检查容器状态，而部署脚本使用的是 `-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml` 三个 overlay 文件。验证可能遗漏 prod/dev 特有的容器（如 `postgres-dev`），导致验证结果不完整。
**Fix:** 将 compose 文件参数与部署脚本保持一致：
```bash
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml ps
```

### IN-03: ROLLBACK_FILE 使用 /tmp 目录，重启后丢失

**File:** `scripts/deploy/deploy-infrastructure-prod.sh:38` 和 `scripts/deploy/deploy-apps-prod.sh:28`
**Issue:** 回滚文件存放在 `/tmp/noda-rollback/` 目录。服务器重启后 `/tmp` 可能被清理（取决于 OS 配置），导致无法使用保存的镜像标签进行回滚。不过考虑到这些脚本是短生命周期运行（部署完成后回滚文件即失效），实际风险较低。
**Fix:** 如果需要持久化回滚信息，可改用 `/var/lib/noda/rollback/` 等非易失目录。当前行为可接受，仅作记录。

---

_Reviewed: 2026-04-16T12:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
