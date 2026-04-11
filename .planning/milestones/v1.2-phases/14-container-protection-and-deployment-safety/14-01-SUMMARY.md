---
phase: 14-container-protection-and-deployment-safety
plan: 01
subsystem: container-security
tags: [security-hardening, non-root, logging, docker-compose]
dependency_graph:
  requires: []
  provides: [D-01, D-02, D-03, D-04]
  affects: [docker/docker-compose.prod.yml, deploy/Dockerfile.noda-ops, deploy/entrypoint-ops.sh, deploy/supervisord.conf]
tech_stack:
  added: []
  patterns: [no-new-privileges, cap_drop/cap_add whitelist, read_only+tmpfs, json-file log rotation]
key_files:
  created: []
  modified:
    - docker/docker-compose.prod.yml
    - deploy/Dockerfile.noda-ops
    - deploy/entrypoint-ops.sh
    - deploy/supervisord.conf
decisions:
  - noda-ops 使用 nodaops 用户而非 nodejs 用户，因为它是 Alpine 镜像（addgroup -S/adduser -S）
  - supervisord.conf pidfile 迁移到 /run/supervisor/supervisord.pid（tmpfs 可写路径）
  - entrypoint-ops.sh 中 cloudflared 禁用逻辑改为复制配置到 /tmp 再修改（因为 read_only 文件系统）
  - noda-ops 的 /home/nodaops 作为 tmpfs 挂载，用于 rclone config 运行时写入
metrics:
  duration: 6m
  completed: "2026-04-11"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 4
  commits: 2
---

# Phase 14 Plan 01: 容器安全加固与 Non-Root 改造 Summary

为所有 5 个生产容器添加全面安全加固（no-new-privileges + cap_drop:ALL + read_only + json-file 日志轮转），noda-ops 容器从 root 改造为 nodaops 非 root 用户运行。

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | noda-ops non-root 用户改造 (D-02) | `6525ae3` | deploy/Dockerfile.noda-ops, deploy/entrypoint-ops.sh, deploy/supervisord.conf |
| 2 | 生产 overlay 安全加固 (D-01, D-03, D-04) | `288e39f` | docker/docker-compose.prod.yml |

## Changes Detail

### Task 1: noda-ops non-root 用户改造

**deploy/Dockerfile.noda-ops:**
- 添加 `addgroup -S nodaops && adduser -S -G nodaops nodaops` 创建非 root 用户
- crontab COPY 目标从 `/etc/crontabs/root` 改为 `/etc/crontabs/nodaops`
- 添加 `chown -R nodaops:nodaops` 确保目录权限
- 创建 `/home/nodaops/.config/rclone` 目录并设置权限
- 添加 `USER nodaops` 指令

**deploy/entrypoint-ops.sh:**
- rclone 配置路径从 `/root/.config/rclone` 改为 `/home/nodaops/.config/rclone`
- 添加 `export RCLONE_CONFIG=/home/nodaops/.config/rclone/rclone.conf` 环境变量
- cloudflared 禁用逻辑改为复制 supervisord.conf 到 `/tmp` 再修改（兼容 read_only 文件系统）
- supervisord 启动时自动选择正确的配置文件路径

**deploy/supervisord.conf:**
- cron 程序 HOME 从 `/root` 改为 `/home/nodaops`
- cloudflared 程序 HOME 从 `/root` 改为 `/home/nodaops`
- pidfile 从 `/var/run/supervisord.pid` 改为 `/run/supervisor/supervisord.pid`（tmpfs 路径）

### Task 2: 生产 overlay 安全加固

**docker/docker-compose.prod.yml -- 5 个服务全部加固:**

| 服务 | no-new-privileges | cap_drop:ALL | cap_add 白名单 | read_only + tmpfs | json-file 日志 | stop_grace_period |
|------|-------------------|-------------|---------------|-------------------|---------------|-------------------|
| postgres | yes | yes | CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID | yes | 10m/3 files | 30s |
| keycloak | yes | no | -- | yes | 10m/3 files | 30s |
| findclass-ssr | yes | yes | -- | yes | 10m/3 files | 30s |
| nginx | yes | yes | NET_BIND_SERVICE | yes | 10m/3 files | 30s |
| noda-ops | yes | yes | CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID | yes | 10m/3 files | 30s |

**tmpfs 路径说明:**
- postgres: `/var/run/postgresql`, `/tmp`
- keycloak: `/tmp`, `/opt/keycloak/data/tmp`
- findclass-ssr: `/tmp`
- nginx: `/var/cache/nginx`, `/var/run`, `/tmp`
- noda-ops: `/tmp`, `/var/log/supervisor`, `/run/supervisor`, `/home/nodaops`

## Verification Results

- `docker compose config --quiet`: 通过（无语法错误）
- `stop_grace_period`: 5 个（符合预期）
- `max-size`: 5 个（符合预期）
- `cap_drop`: 4 个（keycloak 除外，符合预期）
- `no-new-privileges`: 5 个（符合预期）
- `read_only`: 5 个（符合预期）
- docker-compose.dev.yml: 未修改

## Deviations from Plan

None -- plan executed exactly as written.

## Decisions Made

1. **noda-ops 使用 Alpine addgroup -S/adduser -S** -- 因为基础镜像是 alpine:3.19，使用 Alpine 风格的用户创建命令（-S = system user），与 Dockerfile.findclass-ssr 中的 node:20-alpine 模式一致

2. **supervisord.conf pidfile 迁移到 /run/supervisor/** -- 原路径 `/var/run/supervisord.pid` 在 read_only 文件系统下不可写，改为 tmpfs 挂载的 `/run/supervisor/` 路径

3. **entrypoint-ops.sh 中 cloudflared 禁用逻辑** -- 因为容器将设为 read_only，不能原地修改 `/etc/supervisord.conf`，改为复制到 `/tmp/supervisord.conf` 后修改，启动时自动选择正确的配置文件

4. **noda-ops 的 /home/nodaops 作为 tmpfs** -- rclone config 需要运行时写入，且 Dockerfile 中创建的目录在 read_only 模式下不可写，通过 tmpfs 覆盖解决

## Known Stubs

None.

## Threat Flags

None. All changes are within the plan's threat model scope.

## Self-Check: PASSED

- All 5 modified/created files verified present
- Both commits (6525ae3, 288e39f) verified in git log
- docker compose config validation passed
