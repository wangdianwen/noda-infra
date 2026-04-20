---
phase: 47-noda-site-image
plan: 02
subsystem: infra
tags: [jenkins, docker-compose, blue-green, health-check, nginx]

# Dependency graph
requires:
  - "47-01 (Dockerfile runner 阶段重写为 nginx:1.25-alpine)"
provides:
  - "noda-site 蓝绿部署 Pipeline 兼容 nginx 容器"
  - "docker-compose.app.yml noda-site 健康检查和资源限制优化"
affects: [pipeline-noda-site, docker-compose-app]

# Tech tracking
tech-stack:
  added: []
  patterns: [container-health-cmd-override, nginx-config-build-context-copy]

key-files:
  created: []
  modified:
    - docker/docker-compose.app.yml
    - jenkins/Jenkinsfile.noda-site

key-decisions:
  - "CONTAINER_HEALTH_CMD 覆盖 manage-containers.sh 默认 node fetch 命令，使用 BusyBox wget + 127.0.0.1"
  - "nginx 配置文件通过构建前复制到 noda-apps/deploy/nginx/ 再构建后清理的方式注入构建上下文"
  - "manage-containers.sh 通用脚本不修改，60s start_period 对 nginx 无害"

requirements-completed: [SITE-03]

# Metrics
duration: 4min
completed: 2026-04-20
---

# Phase 47 Plan 02: Pipeline 和 Docker Compose 适配 Summary

**Jenkins Pipeline 和 Docker Compose 配置适配 nginx 容器：健康检查命令覆盖（wget 替代 node fetch）、资源限制降低（32MB）、构建上下文 nginx 配置复制**

## Performance

- **Duration:** 4 min
- **Started:** 2026-04-20T08:32:00Z
- **Completed:** 2026-04-20T08:36:00Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- docker-compose.app.yml noda-site 健康检查参数缩短（interval=10s, timeout=3s, start_period=3s），适配 nginx 快速启动
- docker-compose.app.yml noda-site 资源限制降低（32MB limits, 8M reservations），适配 nginx 低内存运行时
- Jenkinsfile 新增 CONTAINER_HEALTH_CMD 使用 BusyBox wget + 127.0.0.1，覆盖 manage-containers.sh 默认 node fetch 命令
- Jenkinsfile 新增 CONTAINER_MEMORY=32m 和 CONTAINER_MEMORY_RESERVATION=8m
- Jenkinsfile Build 阶段在 pipeline_build 前复制 nginx 配置到 noda-apps 构建上下文，构建后清理临时文件

## Task Commits

Each task was committed atomically:

1. **Task 1: 更新 docker-compose.app.yml noda-site 服务配置** - `1687a5b` (feat)
2. **Task 2: 更新 Jenkinsfile.noda-site 适配 nginx 容器** - `16536de` (feat)

## Files Created/Modified
- `docker/docker-compose.app.yml` - noda-site 健康检查参数缩短 + 资源限制降低
- `jenkins/Jenkinsfile.noda-site` - 新增 CONTAINER_HEALTH_CMD/CONTAINER_MEMORY 环境变量 + Build 阶段 nginx 配置复制

## Decisions Made
- CONTAINER_HEALTH_CMD 使用 `wget --quiet --tries=1 --spider http://127.0.0.1:3000/ || exit 1` -- 覆盖 manage-containers.sh 默认 `node -e fetch(...)` 命令，因为 nginx 容器无 Node.js（per RESEARCH Pitfall 2）
- 使用 `127.0.0.1` 而非 `localhost` -- BusyBox wget 将 localhost 解析为 IPv6 (::1) 导致连接失败（per RESEARCH Pitfall 1）
- nginx 配置文件构建前复制方案 -- 在 Build 阶段将 deploy/nginx/ 下的配置文件复制到 noda-apps/deploy/nginx/，因为 Dockerfile COPY 路径相对于构建上下文（noda-apps），构建后清理临时文件
- 不修改 manage-containers.sh 通用脚本 -- 60s start_period 硬编码对 nginx 无害（只是多等几秒），保持通用性

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Self-Check: PASSED

- FOUND: docker/docker-compose.app.yml
- FOUND: jenkins/Jenkinsfile.noda-site
- FOUND: 1687a5b (Task 1 commit)
- FOUND: 16536de (Task 2 commit)

---
*Phase: 47-noda-site-image*
*Completed: 2026-04-20*
