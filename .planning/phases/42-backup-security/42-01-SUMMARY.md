---
phase: 42-backup-security
plan: 01
subsystem: infra
tags: [doppler, rclone, b2, age, cron, docker]

requires:
  - phase: 41-migration-cleanup
    provides: Doppler 成为唯一密钥源，backup-doppler-secrets.sh 已存在
provides:
  - Doppler 密钥每日自动备份到 B2（rclone 上传）
  - noda-ops 容器内 doppler CLI + age 加密工具
  - crontab 3:30 密钥备份调度
  - DOPPLER_TOKEN 环境变量注入到 noda-ops 容器
affects: [backup, doppler, noda-ops]

tech-stack:
  added: [doppler-cli, age, rclone-copy]
  patterns: [rclone-config-reuse, env-var-injection]

key-files:
  created: []
  modified:
    - scripts/backup/backup-doppler-secrets.sh
    - deploy/Dockerfile.noda-ops
    - deploy/crontab
    - docker/docker-compose.yml
    - deploy/entrypoint-ops.sh

key-decisions:
  - "b2 CLI 替换为 rclone（与数据库备份共享 rclone 基础设施）"
  - "容器内复用 entrypoint-ops.sh 已配置的 rclone，本地执行创建临时配置"

patterns-established:
  - "rclone 配置复用: 容器内用 RCLONE_CONFIG 环境变量，本地创建临时配置"
  - "密钥备份错开数据库备份: 3:30 vs 3:00"

requirements-completed: [BACKUP-01]

duration: 5min
completed: 2026-04-19
---

# Phase 42: 备份与安全 Plan 01 Summary

**Doppler 密钥备份集成到 noda-ops 容器 cron 调度（rclone 上传 + age 加密 + 3:30 定时）**

## Performance

- **Duration:** 5 min
- **Started:** 2026-04-19T18:00:00Z
- **Completed:** 2026-04-19T18:05:00Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- backup-doppler-secrets.sh 从 b2 CLI 迁移到 rclone 上传，复用数据库备份的 rclone 配置
- Dockerfile.noda-ops 安装 doppler CLI + age 加密工具
- crontab 配置每天 3:30 执行密钥备份（错开数据库备份 3:00）
- docker-compose.yml 注入 DOPPLER_TOKEN 到 noda-ops 容器
- entrypoint-ops.sh 启动时验证 DOPPLER_TOKEN 并显示 Doppler CLI 版本

## Task Commits

1. **Task 1+2: Doppler 密钥备份集成** - `1fa4e70` (feat)

## Files Created/Modified
- `scripts/backup/backup-doppler-secrets.sh` - b2 CLI → rclone copy 上传，本地创建临时 rclone 配置
- `deploy/Dockerfile.noda-ops` - 添加 age + doppler CLI 安装
- `deploy/crontab` - 添加 3:30 密钥备份 cron（--config prd）
- `docker/docker-compose.yml` - noda-ops 添加 DOPPLER_TOKEN 环境变量
- `deploy/entrypoint-ops.sh` - Doppler 环境验证（token + CLI 版本）

## Decisions Made
- 使用 rclone 替代 b2 CLI，与数据库备份共享基础设施
- 容器内复用 entrypoint-ops.sh 已创建的 rclone 配置（RCLONE_CONFIG），本地执行时创建临时配置
- 帮助信息 --config 默认值从 `prod` 修正为 `prd`

## Deviations from Plan
None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None

## Next Phase Readiness
- Plan 42-02 (Git 历史清理脚本) 可独立执行，无依赖

---
*Phase: 42-backup-security*
*Completed: 2026-04-19*
