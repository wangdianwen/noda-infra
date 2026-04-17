---
phase: 30-dev-setup
plan: 01
subsystem: dev-tooling
tags: [setup, developer-experience, shell-script, idempotent]
dependency_graph:
  requires:
    - scripts/setup-postgres-local.sh (Phase 26 产物)
    - scripts/lib/log.sh
  provides:
    - setup-dev.sh (一键开发环境入口)
  affects:
    - docs/DEVELOPMENT.md
tech_stack:
  added:
    - setup-dev.sh (bash 编排脚本)
  patterns:
    - 薄编排层委托模式（封装底层脚本，不重新实现）
key_files:
  created:
    - setup-dev.sh
  modified:
    - docs/DEVELOPMENT.md
decisions:
  - D-01: 封装 setup-postgres-local.sh，不替换
  - D-05: 非交互式执行，无 read -p
  - D-07: 脚本位于项目根目录
metrics:
  duration: 3m
  completed: "2026-04-17"
  tasks: 2
  files_changed: 2
---

# Phase 30 Plan 01: 一键开发环境脚本 Summary

一键开发环境脚本 setup-dev.sh（4 步编排：Homebrew 检查 -> PG 安装 -> 环境验证 -> 下一步指引），封装 setup-postgres-local.sh install/status，幂等且非交互式。同步更新 DEVELOPMENT.md 开发文档。

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | 创建 setup-dev.sh 一键开发环境脚本 | 259be88 | setup-dev.sh (84 行) |
| 2 | 更新 DEVELOPMENT.md 添加 setup-dev.sh 使用说明 | 93c75be | docs/DEVELOPMENT.md (+38/-2) |

## Key Changes

### Task 1: setup-dev.sh

- 4 步流程：`check_homebrew` -> `install_postgresql` -> `verify_environment` -> `show_next_steps`
- 通过 `$SETUP_PG` 变量引用 `scripts/setup-postgres-local.sh`，使用 `SCRIPT_DIR` 动态路径解析
- Homebrew 检查使用 `command -v brew`，已安装则显示版本
- 委托 `bash "$SETUP_PG" install` 执行 PG 安装（底层幂等：brew list/psql/brew services 检查）
- 委托 `bash "$SETUP_PG" status` 执行 5 项环境验证
- 成功后显示连接命令和文档指引
- 84 行，薄编排层，不含 PG 管理逻辑的重新实现

### Task 2: DEVELOPMENT.md 更新

- 在前置条件表格后插入 "快速开始（一键搭建）" 段落，包含 4 步说明和幂等性提示
- 新增 "本地开发数据库（PostgreSQL）" 段落，区分首次搭建（setup-dev.sh）和日常管理（setup-postgres-local.sh 子命令）
- 原有 "独立开发环境（仅 PostgreSQL）" 保留为 Docker 备选方案
- 移除了不存在的 `connect` 子命令引用

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] DEVELOPMENT.md 段落结构差异**
- **Found during:** Task 2
- **Issue:** 计划中引用的 "本地开发数据库（PostgreSQL）" 段落不存在于当前 DEVELOPMENT.md 中
- **Fix:** 在 "独立开发环境（仅 PostgreSQL）" 段落前新增 "本地开发数据库（PostgreSQL）" 段落，将原 Docker 方案标记为备选
- **Files modified:** docs/DEVELOPMENT.md
- **Commit:** 93c75be

## Requirements Coverage

| Requirement | Status | How Covered |
|------------|--------|-------------|
| DEVEX-01 | Covered | setup-dev.sh 一键安装（Homebrew + PG + DB + 验证） |
| DEVEX-02 | Covered | 幂等设计（底层 setup-postgres-local.sh 保证） |
| DEVEX-03 | Covered | 架构检测委托给 setup-postgres-local.sh 的 detect_homebrew_prefix() |

## Verification Results

```
Task 1 验证:
  bash "$SETUP_PG" install  -- PASS (line 48)
  bash "$SETUP_PG" status   -- PASS (line 57)
  source lib/log.sh         -- PASS (line 14)
  set -euo pipefail         -- PASS (line 2)
  command -v brew           -- PASS (line 23)
  test -x setup-dev.sh      -- PASS
  无 read -p                -- PASS
  行数: 84 (预期 80-100)

Task 2 验证:
  setup-dev.sh 引用 (2处)  -- PASS
  快速开始 段落             -- PASS
  日常管理 段落             -- PASS
  无 connect 子命令引用     -- PASS
  保留步骤 1-4 (4处)        -- PASS
```

## Self-Check: PASSED

- setup-dev.sh: FOUND
- docs/DEVELOPMENT.md: FOUND
- .planning/phases/30-dev-setup/30-01-SUMMARY.md: FOUND
- Commit 259be88 (Task 1): FOUND
- Commit 93c75be (Task 2): FOUND
