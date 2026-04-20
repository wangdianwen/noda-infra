---
phase: 48-docker-hygiene
reviewed: 2026-04-20T22:10:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - .dockerignore
  - deploy/Dockerfile.noda-ops
  - deploy/Dockerfile.noda-site
  - scripts/backup/docker/Dockerfile.test-verify
findings:
  critical: 1
  warning: 3
  info: 3
  total: 7
status: issues_found
---

# Phase 48: Code Review Report

**Reviewed:** 2026-04-20T22:10:00Z
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

审查了 4 个 Docker 相关文件：`.dockerignore`、`Dockerfile.noda-ops`、`Dockerfile.noda-site`、`Dockerfile.test-verify`。发现 1 个严重问题（构建失败风险）、3 个警告、3 个信息级建议。

严重问题：`Dockerfile.noda-site` 中的 `COPY deploy/nginx/...` 指令引用了 noda-infra 仓库中的文件，但构建上下文指向 noda-apps 仓库，这些文件在构建上下文中不存在，会导致构建失败。

## Critical Issues

### CR-01: Dockerfile.noda-site COPY 路径与构建上下文不匹配

**File:** `deploy/Dockerfile.noda-site:44-45`
**Issue:** `docker-compose.app.yml` 中 `noda-site` 的构建上下文（`context`）设置为 `../../noda-apps`（noda-apps 仓库），但 Dockerfile 中 Stage 2 的 `COPY` 指令引用 `deploy/nginx/nginx.conf` 和 `deploy/nginx/default.conf`，这些文件位于 noda-infra 仓库的 `deploy/nginx/` 目录下，在 noda-apps 构建上下文中不存在。这会导致 `docker compose build noda-site` 失败。

```dockerfile
# 第 44-45 行，相对于 noda-apps 上下文解析，文件不存在
COPY --chown=nginx:nginx deploy/nginx/nginx.conf /etc/nginx/nginx.conf
COPY --chown=nginx:nginx deploy/nginx/default.conf /etc/nginx/conf.d/default.conf
```

**Fix:** 将构建上下文改为 noda-infra 仓库（或包含两个仓库的父目录），或者在 noda-apps 仓库中放置这些 nginx 配置文件。最简单的修复是修改 `docker-compose.app.yml` 中的 context：

```yaml
# docker-compose.app.yml - 方案 A：改用 noda-infra 作为构建上下文
noda-site:
  build:
    context: ..                          # noda-infra 仓库根目录
    dockerfile: deploy/Dockerfile.noda-site
```

但这样需要同步调整 Dockerfile 中的 Stage 1 `COPY . .` 路径（noda-apps 源码不再在上下文中）。更实际的方案是将 nginx 配置文件复制到 noda-apps 仓库：

```bash
# 方案 B：在 noda-apps 仓库中放置 nginx 配置
mkdir -p /path/to/noda-apps/deploy/nginx/
cp deploy/nginx/nginx.conf /path/to/noda-apps/deploy/nginx/
cp deploy/nginx/default.conf /path/to/noda-apps/deploy/nginx/
```

## Warnings

### WR-01: entrypoint-ops.sh 使用 sudo 但镜像未安装 sudo

**File:** `deploy/Dockerfile.noda-ops:37`（间接问题，实际代码在 `deploy/entrypoint-ops.sh:37`）
**Issue:** `entrypoint-ops.sh` 第 37 行使用 `sudo mkdir -p /home/nodaops/.config/rclone`，但 `Dockerfile.noda-ops` 中没有安装 `sudo` 包。该容器以 `nodaops` 用户运行（第 71 行 `USER nodaops`），`sudo` 命令会失败。虽然使用了 `2>/dev/null || true` 静默了错误，但这意味着 rclone 配置目录可能无法创建，导致 B2 备份上传失败。

**Fix:** 在 Dockerfile 中安装 `sudo` 并配置 nodaops 用户的无密码 sudo，或者更好的做法是在 Dockerfile 的 ROOT 阶段预创建该目录（第 64 行已有部分目录创建，应添加 rclone 配置目录）：

```dockerfile
# Dockerfile.noda-ops 第 64 行，扩展 mkdir 命令
RUN mkdir -p /var/log/supervisor /var/log/noda-backup /app/history /run/supervisor /home/nodaops/.config/rclone && \
    chown -R nodaops:nodaops /var/log/supervisor /var/log/noda-backup /app/history /run/supervisor /home/nodaops
```

这样 entrypoint-ops.sh 中的 rclone 配置目录已存在，无需 `sudo`。

### WR-02: .dockerignore 排除了 scripts/backup/ 下的 .md 文件但保留 .sh 文件，路径匹配不精确

**File:** `.dockerignore:15,38-40`
**Issue:** `.dockerignore` 第 15 行的 `*.md` 规则是全局匹配，会排除项目中所有 `.md` 文件（包括 `scripts/backup/` 下的 `README.md` 等文档）。这本身没问题，但第 38-40 行又单独列出了 `scripts/backup/TEST_REPORT.md`、`scripts/backup/DEPLOYMENT_SUMMARY.md`、`scripts/backup/DATA_VOLUME_CHECK.md`，这些规则是多余的——它们已被第 15 行的 `*.md` 规则覆盖。更严重的是，这种隐式依赖全局 `*.md` 规则的模式不安全：如果将来移除 `*.md` 规则，这些敏感文件会意外被包含在构建上下文中。

**Fix:** 将 backup 相关的 `.md` 文件排除与全局 `*.md` 规则解耦，使用更显式的路径匹配：

```dockerignore
# 备份相关的敏感和文档文件（显式排除，不依赖全局 *.md）
scripts/backup/*.md
scripts/backup/.env.*
scripts/backup/.gitignore
```

### WR-03: Dockerfile.test-verify 缺少 .dockerignore 文件

**File:** `scripts/backup/docker/Dockerfile.test-verify`
**Issue:** 该 Dockerfile 的构建上下文应该是 noda-infra 项目根目录（因为 `COPY scripts/backup/lib/*.sh` 和 `COPY scripts/backup/test-verify-weekly.sh` 都引用了相对于根目录的路径）。但 `scripts/backup/docker/` 目录中没有独立的 `.dockerignore` 文件，所以构建时会使用根目录的 `.dockerignore`。根目录的 `.dockerignore` 排除了 `*.md` 但没有排除 `scripts/backup/.env.backup`（这个文件已被第 35 行覆盖，但依赖全局规则），且没有排除 `scripts/backup/docker/` 本身。不过，根目录 `.dockerignore` 第 35 行确实排除了 `scripts/backup/.env.backup`，所以这不是一个立即的安全问题，但最好显式处理。

**Fix:** 考虑在 `scripts/backup/docker/` 目录添加专用的 `.dockerignore`，或者确保构建上下文只包含必要的文件。当前风险较低，仅做建议。

## Info

### IN-01: Dockerfile.noda-ops 中 apk 缓存清理效果有限

**File:** `deploy/Dockerfile.noda-ops:24`
**Issue:** 第 24 行 `&& rm -rf /var/cache/apk/*` 清理 apk 缓存。但 `apk add --no-cache` 本身就会自动清理缓存（`--no-cache` 等价于在 `/etc/apk/cache` 不缓存）。额外的 `rm -rf` 是冗余的，虽然无害。

**Fix:** 移除冗余的 `rm -rf /var/cache/apk/*`，`--no-cache` 已足够：

```dockerfile
RUN apk add --no-cache \
    bash curl wget jq coreutils rclone dcron supervisor \
    ca-certificates postgresql17-client gnupg age
```

### IN-02: Dockerfile.test-verify 中 sha256sum --version 验证

**File:** `scripts/backup/docker/Dockerfile.test-verify:30`
**Issue:** 第 30 行 `sha256sum --version` 用于验证工具安装。由于第 4 行安装了 `coreutils` 包（提供 GNU `sha256sum`），`--version` 参数可以正常工作。但这是验证步骤，对构建结果无影响，仅用于提前发现缺少工具的问题。合理但可简化。

**Fix:** 无需修改，当前实现合理。

### IN-03: Dockerfile.noda-ops 和 Dockerfile.backup 使用不同的基础镜像

**File:** `deploy/Dockerfile.noda-ops:8` vs `deploy/Dockerfile.backup:9`
**Issue:** `Dockerfile.noda-ops` 使用 `alpine:3.21`，而 `Dockerfile.backup` 使用 `postgres:17-alpine`。两者功能重叠（都做备份），但基础镜像不同。这不是 bug（它们是不同的服务容器），但维护两套备份相关的基础镜像会增加维护成本。

**Fix:** 长期考虑将备份功能统一到 `noda-ops` 中，废弃 `Dockerfile.backup`。当前无需修改。

---

_Reviewed: 2026-04-20T22:10:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
