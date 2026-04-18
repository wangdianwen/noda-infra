---
phase: 35-shared-libs
plan: 03
subsystem: deploy-check
tags: [bash, shared-library, image-cleanup, refactoring]
dependency_graph:
  requires: [log.sh]
  provides:
    - scripts/lib/image-cleanup.sh - cleanup_by_tag_count, cleanup_by_date_threshold, cleanup_dangling
  affects: [blue-green-deploy.sh, keycloak-blue-green-deploy.sh, pipeline-stages.sh]
tech_stack:
  added: [scripts/lib/image-cleanup.sh]
  patterns: [source-guard, parameterized-image-name]
key_files:
  created:
    - scripts/lib/image-cleanup.sh
  modified:
    - scripts/blue-green-deploy.sh
    - scripts/keycloak-blue-green-deploy.sh
    - scripts/pipeline-stages.sh
decisions:
  - "3 个独立清理函数而非统一入口（per D-01/D-02/D-03，三种策略本质不同）"
  - "cleanup_by_tag_count 参数化镜像名（原硬编码 findclass-ssr），便于未来复用"
  - "pipeline-stages.sh 中 pipeline_cleanup 的 else 分支（dangling 清理）用 cleanup_dangling 替代内联逻辑"
patterns-established:
  - "Source Guard: _NODA_IMAGE_CLEANUP_LOADED 防止重复加载（沿用 config.sh 模式）"
requirements-completed: [LIB-03]
metrics:
  duration: 3min
  completed: "2026-04-18"
  tasks_completed: 1
  files_changed: 4
  lines_removed: 158
  lines_added: 157
---

# Phase 35 Plan 03: 镜像清理共享库提取 Summary

**提取 3 个镜像清理函数到 scripts/lib/image-cleanup.sh，消除 3 个文件中的重复清理代码（约 158 行），统一参数化接口**

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | 创建 image-cleanup.sh 共享库并迁移 3 个消费者脚本 | 66d4273 | image-cleanup.sh, blue-green-deploy.sh, keycloak-blue-green-deploy.sh, pipeline-stages.sh |

## Key Changes

- **scripts/lib/image-cleanup.sh**: 新建共享库（149 行），包含 Source Guard (`_NODA_IMAGE_CLEANUP_LOADED`) + 3 个独立清理函数
- **scripts/blue-green-deploy.sh**: 删除内联 cleanup_old_images 定义（35 行），添加 source，调用改为 `cleanup_by_tag_count "findclass-ssr" 5`
- **scripts/keycloak-blue-green-deploy.sh**: 删除内联 cleanup_old_keycloak_images 定义（20 行），添加 source，调用改为 `cleanup_dangling`
- **scripts/pipeline-stages.sh**: 删除内联 cleanup_old_images 定义（82 行），添加 source，两处调用分别改为 `cleanup_by_date_threshold` 和 `cleanup_dangling`

### 函数与消费者对应关系

| 函数 | 策略 | 消费者 |
|------|------|--------|
| cleanup_by_tag_count | 保留最近 N 个标签镜像 | blue-green-deploy.sh |
| cleanup_by_date_threshold | 删除超过 N 天的旧镜像 + dangling | pipeline-stages.sh (pipeline_cleanup) |
| cleanup_dangling | 仅清理 dangling images | keycloak-blue-green-deploy.sh, pipeline-stages.sh (pipeline_infra_cleanup) |

## Deviations from Plan

None - plan executed exactly as written.

## Verification

- 所有 4 个文件通过 `bash -n` 语法检查
- 3 个消费者脚本中旧的 cleanup 函数定义数量均为 0
- image-cleanup.sh 中 3 个函数各仅定义 1 次
- 3 个消费者均包含 `source image-cleanup.sh`
- 所有 14 项验收标准全部通过

## Self-Check: PASSED

- scripts/lib/image-cleanup.sh: FOUND
- Commit 66d4273: FOUND
- .planning/phases/35-shared-libs/35-03-SUMMARY.md: FOUND

---
*Phase: 35-shared-libs*
*Completed: 2026-04-18*
