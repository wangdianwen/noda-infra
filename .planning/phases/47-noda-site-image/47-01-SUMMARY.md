---
phase: 47-noda-site-image
plan: 01
subsystem: infra
tags: [docker, nginx, dockerfile, multi-stage-build, buildkit-cache]

# Dependency graph
requires: []
provides:
  - "noda-site Dockerfile runner 阶段重写为 nginx:1.25-alpine"
  - "容器内 nginx 配置文件（nginx.conf + default.conf）"
  - "pnpm store BuildKit 缓存挂载"
affects: [47-02, docker-compose-app, jenkinsfile-noda-site]

# Tech tracking
tech-stack:
  added: [nginx:1.25-alpine]
  patterns: [multi-stage-build-nginx-runner, buildkit-cache-mount-pnpm]

key-files:
  created:
    - deploy/nginx/nginx.conf
    - deploy/nginx/default.conf
  modified:
    - deploy/Dockerfile.noda-site

key-decisions:
  - "nginx.conf 不写 user 指令 -- Docker USER nginx 已以 nginx 用户运行进程，user 指令会尝试切换用户导致权限冲突"
  - "HEALTHCHECK 使用 127.0.0.1 而非 localhost -- BusyBox wget IPv6 解析问题"
  - "容器内不配置 gzip 和缓存头 -- 外层 nginx + Cloudflare 已处理"

patterns-established:
  - "Pattern: 容器内 nginx 配置文件放在 deploy/nginx/ 目录，通过 Dockerfile COPY 引入"
  - "Pattern: 非 root nginx 运行需要将 PID、日志、临时文件全部指向 /tmp（tmpfs）"

requirements-completed: [SITE-01, SITE-02]

# Metrics
duration: 6min
completed: 2026-04-20
---

# Phase 47 Plan 01: noda-site Dockerfile 重写 Summary

**noda-site 运行时从 node:20-alpine + serve 切换到 nginx:1.25-alpine，镜像体积从 ~218MB 降至 ~25MB，builder 阶段添加 pnpm store BuildKit 缓存挂载**

## Performance

- **Duration:** 6 min
- **Started:** 2026-04-20T08:08:51Z
- **Completed:** 2026-04-20T08:15:15Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- 创建容器内 nginx 配置文件（nginx.conf 非 root 配置 + default.conf SPA fallback）
- Dockerfile runner 阶段从 node:20-alpine + serve 重写为 nginx:1.25-alpine
- builder 阶段 pnpm install 添加 BuildKit 缓存挂载（per D-07）
- HEALTHCHECK 使用 127.0.0.1 避免 BusyBox wget IPv6 问题

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建容器内 nginx 配置文件** - `3ff0dbc` (feat)
2. **Task 2: 重写 Dockerfile runner 阶段 + pnpm 缓存挂载** - `587540e` (feat)

## Files Created/Modified
- `deploy/nginx/nginx.conf` - 容器内 nginx 主配置（非 root，PID/日志指向 /tmp）
- `deploy/nginx/default.conf` - 容器内 nginx server 块（端口 3000 + SPA fallback）
- `deploy/Dockerfile.noda-site` - 多阶段构建（builder 添加 pnpm 缓存挂载，runner 切换到 nginx:1.25-alpine）

## Decisions Made
- nginx.conf 不写 `user` 指令 -- Docker `USER nginx` 已以 nginx 用户身份运行进程，nginx.conf 的 user 指令会尝试切换用户导致权限冲突（per RESEARCH Pitfall 5）
- HEALTHCHECK 使用 `127.0.0.1` 而非 `localhost` -- BusyBox wget 将 localhost 解析为 IPv6 (::1) 导致连接失败（per RESEARCH Pitfall 1）
- 容器内不配置 gzip 和缓存头 -- 外层 nginx (default.conf) 已处理缓存策略，Cloudflare 已处理压缩，避免两层冲突（per D-02, D-03）
- builder 阶段将 corepack enable 和 pnpm install 合并为单个 RUN 命令 -- 确保在同一个 BuildKit 缓存挂载层内完成（per D-07）

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Dockerfile 和 nginx 配置文件就绪，Plan 02 需要在 Jenkinsfile 中适配 pipeline_build() 将 nginx 配置文件复制到构建上下文
- manage-containers.sh 默认健康检查命令 (`node -e fetch(...)`) 不兼容 nginx 容器，Plan 02 需要在 Jenkinsfile 中设置 CONTAINER_HEALTH_CMD 环境变量覆盖

## Self-Check: PASSED

- FOUND: deploy/nginx/nginx.conf
- FOUND: deploy/nginx/default.conf
- FOUND: deploy/Dockerfile.noda-site
- FOUND: 3ff0dbc (Task 1 commit)
- FOUND: 587540e (Task 2 commit)

---
*Phase: 47-noda-site-image*
*Completed: 2026-04-20*
