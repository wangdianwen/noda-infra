---
phase: 28-keycloak
plan: 01
subsystem: infra
tags: [keycloak, blue-green, nginx-upstream, docker, envsubst]

# Dependency graph
requires:
  - phase: 20-nginx
    provides: "Nginx upstream include 抽离模式（upstream-*.conf 可被原子替换）"
  - phase: 21-blue-green-containers
    provides: "蓝绿容器管理框架（manage-containers.sh + 环境变量参数化）"
provides:
  - "Keycloak 环境变量模板 env-keycloak.env"
  - "Keycloak nginx upstream 蓝绿切换配置"
  - "manage-containers.sh Keycloak 参数覆盖支持（内存/只读/服务组/额外参数/envsubst 变量）"
affects: [28-02, 28-03]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "ENVSUBST_VARS 环境变量覆盖模式（多服务 envsubst 变量列表差异化）"
    - "CONTAINER_MEMORY/CONTAINER_READONLY/EXTRA_DOCKER_ARGS 容器参数覆盖模式"
    - "compose 容器名回退检测（SERVICE_NAME -> noda-infra-{SERVICE_NAME}-prod）"

key-files:
  created:
    - docker/env-keycloak.env
  modified:
    - config/nginx/snippets/upstream-keycloak.conf
    - scripts/manage-containers.sh

key-decisions:
  - "KC_DB_URL 使用 compose 容器名 noda-infra-postgres-prod 而非网络别名 postgres"
  - "所有 manage-containers.sh 修改通过环境变量覆盖默认值，保持 findclass-ssr/noda-site 向后兼容"
  - "Keycloak CONTAINER_READONLY=false（需要写入 /opt/keycloak/data）"
  - "Keycloak SERVICE_GROUP=infra（而非默认 apps）"

patterns-established:
  - "env-{service}.env 模板模式：每服务独立环境变量文件，敏感值 ${VAR} 占位符"
  - "upstream-{service}.conf 蓝绿格式：{service}-blue:{port} 默认值，原子替换"

requirements-completed: [KCBLUE-01, KCBLUE-02, KCBLUE-03]

# Metrics
duration: 5min
completed: 2026-04-17
---

# Phase 28: Keycloak 蓝绿部署基础设施 Summary

**Keycloak 蓝绿部署三大基础组件：env-keycloak.env 环境变量模板、upstream-keycloak.conf 蓝绿切换、manage-containers.sh 参数化适配**

## Performance

- **Duration:** 5 min
- **Started:** 2026-04-17T04:11:51Z
- **Completed:** 2026-04-17T04:16:55Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments
- 创建 env-keycloak.env 模板，包含全部 Keycloak 环境变量（数据库/主机名/代理/健康检查/管理员/SMTP），敏感值 ${VAR} 占位符
- upstream-keycloak.conf 从 compose 单容器格式改为 keycloak-blue:8080 蓝绿格式
- manage-containers.sh 支持多服务参数化：内存限制、只读模式、服务组标签、额外 docker 参数、envsubst 变量列表、compose 容器名回退检测

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建 env-keycloak.env 环境变量模板** - `814e7fc` (feat)
2. **Task 2: 更新 upstream-keycloak.conf 为蓝绿格式** - `9a7c995` (feat)
3. **Task 3: manage-containers.sh 支持 Keycloak 参数覆盖** - `62634de` (feat)

## Files Created/Modified
- `docker/env-keycloak.env` - Keycloak 环境变量模板（25 行，包含 9 个动态 ${VAR} 占位符）
- `config/nginx/snippets/upstream-keycloak.conf` - nginx upstream 蓝绿切换配置（keycloak-blue:8080）
- `scripts/manage-containers.sh` - 蓝绿容器管理脚本参数化（+51/-14 行）

## Decisions Made
- KC_DB_URL 使用 `noda-infra-postgres-prod` 容器名而非 compose 网络别名 `postgres`，因为 docker run 模式下网络别名不可用
- 所有 manage-containers.sh 修改通过环境变量覆盖（`${VAR:-default}` 模式），findclass-ssr 和 noda-site 使用默认值，行为不变
- Keycloak 需要通过 EXTRA_DOCKER_ARGS 挂载主题卷和 data tmpfs，因为只有 Keycloak 需要这些额外参数
- compose 容器名回退检测：先尝试 `$SERVICE_NAME`，再尝试 `noda-infra-${SERVICE_NAME}-prod`

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- 三个基础组件就绪，Plan 02 可以创建 Keycloak 蓝绿部署脚本（keycloak-blue-green-deploy.sh）
- Plan 03 可以创建 Keycloak Jenkinsfile Pipeline
- manage-containers.sh 的参数化支持已验证，Keycloak 通过环境变量覆盖即可使用

## Self-Check: PASSED

- FOUND: docker/env-keycloak.env
- FOUND: config/nginx/snippets/upstream-keycloak.conf
- FOUND: scripts/manage-containers.sh
- FOUND: .planning/phases/28-keycloak/28-01-SUMMARY.md
- FOUND: 814e7fc (Task 1 commit)
- FOUND: 9a7c995 (Task 2 commit)
- FOUND: 62634de (Task 3 commit)

---
*Phase: 28-keycloak*
*Completed: 2026-04-17*
