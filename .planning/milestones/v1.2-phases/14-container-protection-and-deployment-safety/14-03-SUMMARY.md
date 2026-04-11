---
phase: 14-container-protection-and-deployment-safety
plan: 03
subsystem: infra
tags: [docker-compose, rollback, backup, deployment-safety]

# Dependency graph
requires:
  - phase: 14-container-protection-and-deployment-safety
    provides: "部署脚本基础设施（deploy-infrastructure-prod.sh, deploy-apps-prod.sh）"
provides:
  - "deploy-infrastructure-prod.sh: 镜像 digest 保存 + compose-based 回滚 + 部署前 12 小时自动备份"
  - "deploy-apps-prod.sh: findclass-ssr 镜像 digest 保存 + compose-based 回滚"
affects: [deployment, rollback, backup]

# Tech tracking
tech-stack:
  added: []
  patterns: [compose-override-rollback, pre-deploy-backup-check]

key-files:
  created: []
  modified:
    - scripts/deploy/deploy-infrastructure-prod.sh
    - scripts/deploy/deploy-apps-prod.sh

key-decisions:
  - "回滚使用 docker compose override 文件而非裸 docker run，保留完整 compose 配置（网络、卷、环境变量）"
  - "部署前备份检查 12 小时阈值，已有足够新的备份则跳过"
  - "镜像 digest 通过 docker inspect --format={{.Image}} 获取，比 tag 更精确"

patterns-established:
  - "compose-override-rollback: 生成临时 rollback.yml 通过三层 overlay 恢复服务"
  - "pre-deploy-backup-check: 部署前检查 noda-ops 容器内 history.json 判断备份新旧"

requirements-completed: [D-05, D-06]

# Metrics
duration: 6min
completed: 2026-04-11
---

# Phase 14 Plan 03: 镜像回滚机制 + 部署前自动备份 Summary

**Compose-based 镜像 digest 回滚 + 12 小时阈值部署前自动备份，确保部署失败时安全回退且数据始终受保护**

## Performance

- **Duration:** 6 min
- **Started:** 2026-04-11T06:59:15Z
- **Completed:** 2026-04-11T07:05:40Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- deploy-infrastructure-prod.sh 新增 4 个函数（save_image_tags, rollback_images, check_recent_backup, run_pre_deploy_backup），部署步骤从 5 步扩展为 7 步
- deploy-apps-prod.sh 新增 2 个函数（save_app_image_tags, rollback_app），应用启动超时时自动回滚
- 三个失败点（健康检查超时、Keycloak 配置失败、频繁重启）均触发 compose-based 回滚
- 部署前备份通过 noda-ops 容器内 history.json 检查最近备份时间，12 小时内跳过

## Task Commits

Each task was committed atomically:

1. **Task 1: deploy-infrastructure-prod.sh 回滚 + 部署前备份** - `40d5aab` (feat)
2. **Task 2: deploy-apps-prod.sh 回滚机制** - `2b1417a` (feat)

## Files Created/Modified
- `scripts/deploy/deploy-infrastructure-prod.sh` - 新增镜像保存/回滚/备份检查函数，步骤扩展为 7 步
- `scripts/deploy/deploy-apps-prod.sh` - 新增应用镜像保存/回滚函数，超时自动回滚

## Decisions Made
- 回滚使用 docker compose override 文件（rollback.yml），通过三层 overlay 恢复服务，保留完整的网络、卷、环境变量和标签配置，CLAUDE.md 合规
- 镜像保存使用 `docker inspect --format='{{.Image}}'` 获取 digest，比 tag 更精确，避免 tag 被覆盖导致无法回滚
- 备份检查直接读取 noda-ops 容器内的 `/app/history/history.json`，利用已有的备份历史记录
- 容器名到服务名映射使用 declare -A 关联数组，跳过 dev overlay 中未映射的 postgres-dev

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- 两个部署脚本均已具备镜像回滚和（基础设施）部署前自动备份能力
- 回滚文件保存在 /tmp/noda-rollback，服务器重启后自动清理
- 下一步可继续执行 14 阶段的其他计划

## Self-Check: PASSED

- FOUND: scripts/deploy/deploy-infrastructure-prod.sh
- FOUND: scripts/deploy/deploy-apps-prod.sh
- FOUND: .planning/phases/14-container-protection-and-deployment-safety/14-03-SUMMARY.md
- FOUND: commit 40d5aab
- FOUND: commit 2b1417a

---
*Phase: 14-container-protection-and-deployment-safety*
*Completed: 2026-04-11*
