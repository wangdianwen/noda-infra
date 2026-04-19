---
phase: 40-jenkins-pipeline
plan: 03
subsystem: secrets
tags: [doppler, secrets, deploy-scripts, blue-green]

# Dependency graph
requires:
  - phase: 40-01
    provides: load_secrets() 函数 (scripts/lib/secrets.sh)
provides:
  - 3 个手动部署脚本支持 Doppler 双模式密钥获取
  - 手动脚本作为 Jenkins Pipeline 不可用时的紧急回退方案
affects: [Phase 41 SOPS 清理]

# Tech tracking
tech-stack:
  added: []
  patterns: [doppler-dual-mode-secrets, load_secrets-in-manual-scripts]

key-files:
  created: []
  modified:
    - scripts/blue-green-deploy.sh
    - scripts/deploy/deploy-infrastructure-prod.sh
    - scripts/deploy/deploy-apps-prod.sh

key-decisions:
  - "手动脚本直接 source scripts/lib/secrets.sh 而非 pipeline-stages.sh，保持独立性"
  - "deploy-infrastructure-prod.sh 移除 SOPS 检查，SOPS 将在 Phase 41 清理"
  - "Docker Compose 不自动读取 docker/ 子目录外的 .env，需显式 load_secrets()"

patterns-established:
  - "手动脚本密钥加载模式: source secrets.sh -> load_secrets()（与 Pipeline 脚本一致）"

requirements-completed: [PIPE-01, PIPE-03]

# Metrics
duration: 1min
completed: "2026-04-19"
---

# Phase 40 Plan 03: 手动脚本 Doppler 双模式密钥集成 Summary

3 个手动部署脚本（blue-green-deploy.sh、deploy-infrastructure-prod.sh、deploy-apps-prod.sh）集成 load_secrets() 函数，实现 Doppler API + 本地 .env 双模式密钥获取，作为 Jenkins Pipeline 不可用时的紧急回退方案。

## Performance

- **Duration:** 1 min
- **Started:** 2026-04-19T00:25:44Z
- **Completed:** 2026-04-19T00:26:41Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- blue-green-deploy.sh 移除旧的 set -a/source .env/set +a 逻辑，替换为 load_secrets()
- deploy-infrastructure-prod.sh 添加 load_secrets() 并移除过时的 SOPS 检查
- deploy-apps-prod.sh 添加 load_secrets()，支持 Doppler 双模式

## Task Commits

Each task was committed atomically:

1. **Task 1: blue-green-deploy.sh 使用 load_secrets()** - `9c02970` (feat)
2. **Task 2: deploy 脚本使用 load_secrets()** - `67d0879` (feat)

## Files Created/Modified
- `scripts/blue-green-deploy.sh` - 移除旧 .env 加载逻辑，添加 source secrets.sh + load_secrets()
- `scripts/deploy/deploy-infrastructure-prod.sh` - 添加 load_secrets()，移除 SOPS 检查
- `scripts/deploy/deploy-apps-prod.sh` - 添加 source secrets.sh + load_secrets()

## Decisions Made
- 手动脚本直接 source scripts/lib/secrets.sh 而非 pipeline-stages.sh，保持独立性（per success_criteria #5）
- deploy-infrastructure-prod.sh 移除 config/secrets.sops.yaml 检查，因为 Doppler 模式下 sops 文件可能不存在（Phase 41 会全面清理 SOPS 相关代码）
- Docker Compose 不会自动读取 docker/ 子目录的 .env，需要显式 load_secrets() 将密钥注入 shell 环境

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - 脚本自动检测 DOPPLER_TOKEN 环境变量，未设置时回退到 docker/.env。

## Next Phase Readiness
- 3 个手动脚本均支持 Doppler 双模式，可在 Jenkins 不可用时手动部署
- Phase 41 可安全清理 SOPS 相关代码（deploy-infrastructure-prod.sh 中的 sops 检查已移除）

## Self-Check: PASSED

- FOUND: scripts/blue-green-deploy.sh
- FOUND: scripts/deploy/deploy-infrastructure-prod.sh
- FOUND: scripts/deploy/deploy-apps-prod.sh
- FOUND: .planning/phases/40-jenkins-pipeline/40-03-SUMMARY.md
- FOUND: 9c02970
- FOUND: 67d0879

---
*Phase: 40-jenkins-pipeline*
*Completed: 2026-04-19*
