---
phase: 48-docker-hygiene
plan: 01
subsystem: infra
tags: [docker, dockerignore, copy-chown, alpine, postgres, nginx, build-optimization]

# Dependency graph
requires: []
provides:
  - .dockerignore 覆盖 noda-ops/backup/test-verify 构建上下文
  - Dockerfile COPY --chown 优化（noda-ops、noda-site）
  - test-verify 基础镜像升级到 postgres:17-alpine
affects: [48-02, docker-build]

# Tech tracking
tech-stack:
  added: []
  patterns: [COPY --chown 替代 RUN chown, 合并 RUN 指令减少镜像层数]

key-files:
  created:
    - .dockerignore
  modified:
    - deploy/Dockerfile.noda-ops
    - deploy/Dockerfile.noda-site
    - scripts/backup/docker/Dockerfile.test-verify

key-decisions:
  - ".dockerignore 排除 scripts/backup/tests/ 而非 scripts/backup/，保留构建所需的 lib/ 和脚本文件"
  - "/var/cache/nginx 权限由基础镜像管理，noda-site 删除 RUN chown 后不需要手动设置"
  - "noda-ops 的 /app 目录不再需要 RUN chown，因为所有 COPY 已通过 --chown 设置所有权"

patterns-established:
  - "COPY --chown=<user>:<group> 替代独立 RUN chown 层，减少镜像层数"
  - "多个 RUN mkdir/chown 合并为单个 RUN 指令，减少中间层数量"

requirements-completed: [HYGIENE-01, HYGIENE-02, HYGIENE-03]

# Metrics
duration: 5min
completed: 2026-04-20
---

# Phase 48 Plan 01: Docker 卫生实践优化 Summary

**添加 .dockerignore 过滤构建上下文，4 个 COPY 改用 --chown 减少镜像层，test-verify 升级 postgres:17-alpine**

## Performance

- **Duration:** 5 min
- **Started:** 2026-04-20T09:59:24Z
- **Completed:** 2026-04-20T10:04:00Z
- **Tasks:** 1
- **Files modified:** 4

## Accomplishments
- 新建 .dockerignore 排除 .git/.planning/docs/docker/jenkins 等无关文件，减小构建上下文
- noda-site 3 个 COPY 添加 --chown=nginx:nginx，删除独立 RUN chown 层（减少 1 个镜像层）
- noda-ops 4 个 COPY 添加 --chown=nodaops:nodaops，3 个 RUN 指令合并为 1 个（减少 2 个镜像层）
- test-verify 基础镜像从 postgres:15-alpine 升级到 postgres:17-alpine（与生产 PostgreSQL 17.9 版本一致）

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建项目根目录 .dockerignore 并优化 4 个 Dockerfile** - `06e0b06` (feat)

## Files Created/Modified
- `.dockerignore` - 新建，排除 .git/.planning/docs/docker 等无关文件
- `deploy/Dockerfile.noda-ops` - 4 个 COPY 添加 --chown，3 个 RUN 合并为 1 个
- `deploy/Dockerfile.noda-site` - 3 个 COPY 添加 --chown=nginx:nginx，删除 RUN chown
- `scripts/backup/docker/Dockerfile.test-verify` - FROM postgres:15-alpine 改为 postgres:17-alpine

## Decisions Made
- .dockerignore 排除 scripts/backup/tests/ 而非整个 scripts/backup/ 目录，保留 noda-ops 和 test-verify 构建所需的 lib/ 脚本
- /var/cache/nginx 权限由 nginx:1.25-alpine 基础镜像管理，删除 noda-site 的 RUN chown 后不影响运行
- noda-ops 的 /app 目录所有权已通过 4 个 COPY --chown 覆盖，不再需要整体 RUN chown

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- 48-01 完成所有 Dockerfile 最佳实践优化
- 48-02 可基于此继续执行其他 Docker 卫生实践
- 部署时需重新构建所有修改的镜像以使改动生效

---
*Phase: 48-docker-hygiene*
*Completed: 2026-04-20*

## Self-Check: PASSED

- .dockerignore: FOUND
- deploy/Dockerfile.noda-ops: FOUND
- deploy/Dockerfile.noda-site: FOUND
- scripts/backup/docker/Dockerfile.test-verify: FOUND
- 48-01-SUMMARY.md: FOUND
- Commit 06e0b06: FOUND
