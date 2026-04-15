---
phase: 21-blue-green-containers
plan: 01
subsystem: infra
tags: [docker, blue-green, container-management, nginx-upstream, envsubst]

requires:
  - phase: 20
    provides: upstream include 文件（snippets/upstream-findclass.conf），nginx 通配符加载
provides:
  - manage-containers.sh 蓝绿容器管理脚本（8 个子命令）
  - env-findclass-ssr.env 环境变量模板
  - docker run 参数完整翻译自 docker-compose.app.yml
  - 状态文件 /opt/noda/active-env 追踪活跃环境
  - 原子写入 upstream 文件和状态文件
affects: [phase-22, phase-23]

tech-stack:
  added: []
  patterns: [docker run 蓝绿双容器模式, envsubst 安全环境变量替换, 原子文件写入(tmpfile+mv), 状态文件追踪活跃环境]

key-files:
  created:
    - scripts/manage-containers.sh
    - docker/env-findclass-ssr.env
  modified: []

key-decisions:
  - "envsubst 指定只替换 POSTGRES_USER, POSTGRES_PASSWORD, RESEND_API_KEY 三个变量，避免替换 $HOSTNAME 等 shell 内置变量"
  - "run_container 函数独立可 source，Phase 22 可通过 source 复用"
  - "KEYCLOAK_INTERNAL_URL 使用 noda-infra-keycloak-prod 匹配 prod compose 的容器名"

patterns-established:
  - "蓝绿容器命名: findclass-ssr-{blue|green}"
  - "状态文件: /opt/noda/active-env 存储当前活跃环境"
  - "容器管理脚本模式: 单脚本多子命令，source log.sh + health.sh"

requirements-completed: [BLUE-01, BLUE-03, BLUE-04, BLUE-05]

duration: 12min
completed: 2026-04-15
---

# Phase 21 Plan 01: 蓝绿容器管理脚本 Summary

**manage-containers.sh 实现 8 个子命令管理 findclass-ssr 蓝绿双容器，docker run 参数完整翻译自 compose 配置，envsubst 安全环境变量替换，原子状态文件读写**

## Performance

- **Duration:** 12 min
- **Started:** 2026-04-15T06:03:36Z
- **Completed:** 2026-04-15T06:16:06Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- 创建 env-findclass-ssr.env 环境变量模板，包含全部 8 个变量（动态替换 POSTGRES_USER/PASSWORD + RESEND_API_KEY）
- 创建 manage-containers.sh 540 行脚本，实现 init/start/stop/restart/status/logs/switch/usage 8 个子命令
- docker run 参数完整翻译：安全配置（no-new-privileges/cap-drop:ALL/read-only/tmpfs）、资源限制（512M/1CPU）、日志（json-file/10m/3）、健康检查（wget/api/health/30s/60s）、网络（noda-network）、标签（blue-green）
- 原子写入机制：active-env 状态文件和 nginx upstream 配置均使用 tmpfile+mv

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建 env-findclass-ssr.env 环境变量文件** - `655761b` (feat)
2. **Task 2: 创建 manage-containers.sh 蓝绿容器管理脚本** - `5cba31b` (feat)

## Files Created/Modified
- `docker/env-findclass-ssr.env` - findclass-ssr 环境变量模板，${VAR} 占位符由 envsubst 替换
- `scripts/manage-containers.sh` - 蓝绿容器管理主脚本（8 个子命令，540 行）

## Decisions Made
- envsubst 指定只替换三个变量（POSTGRES_USER, POSTGRES_PASSWORD, RESEND_API_KEY），避免替换 $HOSTNAME 等 shell 内置变量（per RESEARCH Pitfall 6）
- KEYCLOAK_INTERNAL_URL 使用 `noda-infra-keycloak-prod` 而非 compose 基础配置中的 `keycloak`，匹配生产环境实际容器名
- run_container 函数设计为独立可 source，Phase 22 部署脚本可通过 source 复用（per D-03）

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- worktree 基于错误的 commit 创建（dbdd999 而非 8baaf7e），通过 git reset --soft 修复到正确 base
- reset --soft 导致大量无关文件在 staging 中，通过 git reset HEAD + git checkout -- . 清理

## Next Phase Readiness
- Phase 22（蓝绿部署核心流程）可通过 `source manage-containers.sh` 复用 run_container, update_upstream, reload_nginx 等函数
- init 子命令支持从 compose 单容器一键迁移到蓝绿架构
- switch 子命令实现安全的流量切换（健康检查 -> nginx -t 验证 -> reload -> 状态更新）

## Self-Check: PASSED

- FOUND: scripts/manage-containers.sh
- FOUND: docker/env-findclass-ssr.env
- FOUND: .planning/phases/21-blue-green-containers/21-01-SUMMARY.md
- FOUND: 655761b (Task 1 commit)
- FOUND: 5cba31b (Task 2 commit)

---
*Phase: 21-blue-green-containers*
*Completed: 2026-04-15*
