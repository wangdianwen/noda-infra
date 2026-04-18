---
phase: 35-shared-libs
plan: 01
subsystem: deploy-check
tags: [refactor, shared-library, health-check]
dependency_graph:
  requires: [log.sh, manage-containers.sh]
  provides: [http_health_check, e2e_verify]
  affects: [blue-green-deploy.sh, keycloak-blue-green-deploy.sh, rollback-findclass.sh, pipeline-stages.sh]
tech_stack:
  added: [scripts/lib/deploy-check.sh]
  patterns: [source-guard, positional-params]
key_files:
  created:
    - scripts/lib/deploy-check.sh
  modified:
    - scripts/blue-green-deploy.sh
    - scripts/keycloak-blue-green-deploy.sh
    - scripts/rollback-findclass.sh
    - scripts/pipeline-stages.sh
decisions:
  - 所有参数通过位置参数传递，不使用环境变量隐式传递
  - deploy-check.sh 不 source log.sh/manage-containers.sh（调用方已加载）
  - blue-green-deploy.sh 的 http_health_check 从容器内部 wget 改为通过 nginx 容器检查（与其他脚本统一）
metrics:
  duration: 5min
  completed: "2026-04-18"
  tasks_completed: 2
  files_changed: 5
  lines_removed: 393
  lines_added: 125
---

# Phase 35 Plan 01: 部署检查共享库提取 Summary

提取 http_health_check() 和 e2e_verify() 到共享库 scripts/lib/deploy-check.sh，消除 4 个文件中的重复函数定义（约 393 行），统一参数化接口。

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | 创建 deploy-check.sh 并迁移 blue-green-deploy.sh + keycloak-blue-green-deploy.sh | 3c5d4e4 | deploy-check.sh, blue-green-deploy.sh, keycloak-blue-green-deploy.sh |
| 2 | 迁移 rollback-findclass.sh + pipeline-stages.sh | ed6cd81 | rollback-findclass.sh, pipeline-stages.sh |

## Key Changes

- **scripts/lib/deploy-check.sh**: 新建共享库，包含 Source Guard (`_NODA_DEPLOY_CHECK_LOADED`) + `http_health_check()` + `e2e_verify()` 两个函数
- **4 个消费者脚本**: 删除内联函数定义（每个约 50-80 行），添加 `source "$PROJECT_ROOT/scripts/lib/deploy-check.sh"`
- **参数化接口**: 函数通过 5 个位置参数接收 (container, service_port, health_path, max_retries, interval)
- **差异化参数保留**:
  - blue-green-deploy.sh: 3001:/api/health, 30 retries/4s + 5 retries/2s
  - keycloak-blue-green-deploy.sh: $SERVICE_PORT:$HEALTH_PATH, 45 retries/4s + 5 retries/2s
  - rollback-findclass.sh: 3001:/api/health, 10 retries/3s + 5 retries/2s
  - pipeline-stages.sh: ${SERVICE_PORT:-3001}:${HEALTH_PATH:-/api/health}, 30/4s + 5/2s

## Deviations from Plan

None - plan executed exactly as written.

## Verification

- 所有 5 个文件通过 `bash -n` 语法检查
- 4 个消费者脚本中 http_health_check() 和 e2e_verify() 函数定义数量均为 0
- deploy-check.sh 中两个函数各仅定义 1 次
- 4 个消费者均包含 `source deploy-check.sh`

## Self-Check: PASSED

- scripts/lib/deploy-check.sh: FOUND
- Commit 3c5d4e4: FOUND
- Commit ed6cd81: FOUND
