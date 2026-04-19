---
phase: 40-jenkins-pipeline
plan: 01
subsystem: secrets
tags: [doppler, secrets, pipeline, shared-library]
dependency_graph:
  requires: []
  provides: [load_secrets-function]
  affects: [scripts/pipeline-stages.sh, scripts/blue-green-deploy.sh]
tech-stack:
  added: [doppler-cli]
  patterns: [dual-mode-secrets-loading, no-file-secret-injection]
key-files:
  created:
    - scripts/lib/secrets.sh
  modified:
    - scripts/pipeline-stages.sh
decisions:
  - Doppler CLI 作为密钥获取首选通道，.env 文件作为回退（per D-03, D-10）
  - doppler secrets download --no-file 避免密钥落盘到临时文件（per D-04）
  - Doppler config 名为 prd 非 prod（per D-05）
  - log 函数 fallback 内置于 load_secrets() 中，降低耦合度
metrics:
  duration: 120s
  completed: "2026-04-19"
  tasks_completed: 2
  files_touched: 2
---

# Phase 40 Plan 01: Doppler 双模式密钥加载库 Summary

创建共享密钥加载库 `scripts/lib/secrets.sh`，实现 Doppler API + 本地 .env 双模式密钥获取，并改造 `pipeline-stages.sh` 使用该函数替换旧的直接 source .env 逻辑。

## 完成的任务

| Task | 名称 | Commit | 文件 |
| ---- | ---- | ------ | ---- |
| 1 | 创建 scripts/lib/secrets.sh 双模式密钥加载库 | 6cf048b | scripts/lib/secrets.sh |
| 2 | 改造 pipeline-stages.sh 使用 load_secrets() | 8ce9b4b | scripts/pipeline-stages.sh |

## 验证结果

- `bash -n scripts/lib/secrets.sh` -- 语法正确
- `bash -n scripts/pipeline-stages.sh` -- 语法正确
- `grep 'load_secrets' scripts/pipeline-stages.sh` -- 调用存在
- `grep 'doppler secrets download.*--project noda --config prd' scripts/lib/secrets.sh` -- Doppler 命令正确
- VITE_* 构建参数未被修改（per D-12）

## Key Links 验证

| From | To | Via | 状态 |
| ---- | -- | --- | ---- |
| scripts/pipeline-stages.sh | scripts/lib/secrets.sh | source | OK |
| scripts/lib/secrets.sh | doppler CLI | doppler secrets download | OK |

## Deviations from Plan

None -- plan executed exactly as written.

## Threat Model 实施确认

| Threat ID | Disposition | 实施 |
| --------- | ----------- | ---- |
| T-40-01 | mitigate | --no-file flag 已使用，密钥不落盘到临时文件 |
| T-40-02 | mitigate | Doppler --format=env 输出标准 KEY=VALUE 格式，eval 前不经过用户输入 |
| T-40-03 | mitigate | 双模式回退到 docker/.env 已实现 |

## Self-Check: PASSED

- FOUND: scripts/lib/secrets.sh
- FOUND: scripts/pipeline-stages.sh
- FOUND: commit 6cf048b
- FOUND: commit 8ce9b4b

