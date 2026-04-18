---
phase: 37-cleanup-rename
plan: 01
subsystem: scripts
tags: [cleanup, verify-scripts, legacy-removal]
dependency_graph:
  requires: []
  provides: [scripts/verify/ 目录已删除, deploy 脚本引用已更新]
  affects: [scripts/deploy/deploy-apps-prod.sh, scripts/deploy/deploy-findclass-zero-deps.sh]
tech_stack:
  added: []
  patterns: [legacy-code-removal]
key_files:
  deleted:
    - scripts/verify/quick-verify.sh
    - scripts/verify/verify-apps.sh
    - scripts/verify/verify-services.sh
    - scripts/verify/verify-infrastructure.sh
    - scripts/verify/verify-findclass.sh
  modified:
    - scripts/deploy/deploy-apps-prod.sh
    - scripts/deploy/deploy-findclass-zero-deps.sh
decisions:
  - verify 脚本注释保留删除说明，不彻底移除脚本名称（便于历史追溯）
metrics:
  duration: 60s
  completed: "2026-04-19"
  tasks_total: 1
  tasks_completed: 1
  files_changed: 7
  commits: 1
---

# Phase 37 Plan 01: 删除 verify 脚本 Summary

删除 `scripts/verify/` 目录下 5 个硬编码旧架构路径的不可用验证脚本，更新 deploy 脚本中的引用为注释说明。

## Tasks Completed

| Task | Name | Commit | Files |
| ---- | ---- | ------ | ----- |
| 1 | 删除 verify 脚本并更新源码引用 | 303bad9 | 删除 5 个 verify 脚本，修改 2 个 deploy 脚本 |

## Changes Detail

### Task 1: 删除 verify 脚本并更新源码引用

**已删除：**
- `scripts/verify/quick-verify.sh` — 硬编码 localhost:8080、旧容器名
- `scripts/verify/verify-apps.sh` — 引用旧 docker-compose 命令和旧容器名
- `scripts/verify/verify-services.sh` — 硬编码旧服务名（findclass-api, findclass-web）
- `scripts/verify/verify-infrastructure.sh` — 硬编码旧架构路径
- `scripts/verify/verify-findclass.sh` — 硬编码本地路径和旧 docker-compose 项目

**已修改：**
- `scripts/deploy/deploy-apps-prod.sh` — 将 `bash scripts/verify/verify-infrastructure.sh` 调用替换为注释说明（第 109 行）
- `scripts/deploy/deploy-findclass-zero-deps.sh` — 简化 `health_check()` 函数，移除对已删除 `verify-findclass.sh` 的条件调用，改为日志提示健康检查由 Pipeline 覆盖

### Verification Results

- `scripts/verify/` 目录已删除
- `bash -n scripts/deploy/deploy-apps-prod.sh` — 语法检查通过
- `bash -n scripts/deploy/deploy-findclass-zero-deps.sh` — 语法检查通过
- `scripts/` 源码中无功能调用引用已删除的 verify 脚本（仅注释中保留说明文字）

## Deviations from Plan

None — 计划按原样执行。

## Threat Flags

无新安全面引入。

## Known Stubs

无。

## Self-Check: PASSED

- FOUND: scripts/verify/ removed
- FOUND: 303bad9 commit exists
