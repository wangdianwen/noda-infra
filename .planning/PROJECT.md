# Noda 数据库备份系统

## Current Milestone: v1.0 数据库备份系统

**目标：** 为 Noda 基础设施的 PostgreSQL 数据库建立完整的自动化备份系统，确保即使发生灾难性故障也能快速恢复数据。

**目标功能：**
- 每 6-12 小时自动执行完整数据库备份
- 备份文件自动上传到云存储（性价比最优方案）
- 云存储自动保留最近 7 天的备份，删除旧备份
- 备份文件使用云存储原生加密功能保护
- 提供一键恢复脚本，从云存储下载并恢复数据库
- 每周自动测试恢复流程，验证备份可恢复性
- 备份失败时发送告警通知（邮件/webhook）
- 提供备份状态监控面板或日志查询

## What This Is

为 Noda 基础设施的 PostgreSQL 数据库建立自动化备份系统，定期将数据库备份上传到云端存储，确保即使发生灾难性故障也能快速恢复数据。包含备份脚本、云存储集成、恢复流程和自动化测试。

## Core Value

数据库永不丢失。即使发生服务器崩溃、误删除、数据库损坏等灾难，也能从最近12小时内的备份中恢复数据。

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

(None yet — ship to validate)

### Active

<!-- Current scope. Building toward these. -->

- [ ] **BACKUP-01**: 系统每6-12小时自动执行一次完整数据库备份
- [ ] **BACKUP-02**: 备份文件自动上传到云存储（性价比最优方案）
- [ ] **BACKUP-03**: 云存储自动保留最近7天的备份，删除旧备份
- [ ] **BACKUP-04**: 备份文件使用云存储原生加密功能保护
- [ ] **BACKUP-05**: 提供一键恢复脚本，从云存储下载并恢复数据库
- [ ] **BACKUP-06**: 每周自动测试恢复流程，验证备份可恢复性
- [ ] **BACKUP-07**: 备份失败时发送告警通知（邮件/ webhook）
- [ ] **BACKUP-08**: 提供备份状态监控面板或日志查询

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- **实时复制** — 需要主从架构，复杂度高，当前需求不需要
- **增量备份** — PostgreSQL 数据库大小适中，完整备份即可
- **跨区域复制** — 增加成本，当前不需要
- **手动备份触发** — 自动化即可，无需手动干预

## Context

**当前基础设施状态**：
- PostgreSQL 17.9 运行在 Docker 容器中（noda-infra-postgres-1）
- 数据库名称：noda_prod（生产）、noda_dev（开发）
- 已有基础备份脚本：`scripts/backup/backup-postgres.sh`（本地备份）
- 已有 Jenkins CI/CD 流水线（可集成定时任务）
- 使用 Cloudflare Tunnel 作为网络入口

**现有备份脚本**：
- 位于 `scripts/backup/backup-postgres.sh`
- 当前只备份到本地文件系统
- 需要扩展为上传到云存储

**数据规模**（待调研）：
- 当前数据库大小未知
- 增长速度未知
- 需要在调研阶段评估

## Constraints

- **成本**: 存储成本优先 — 选择性价比最高的云存储方案
- **频率**: 每6-12小时备份一次（每天2-4次）
- **保留期**: 7天（保留7天×每天4次 = 28个备份文件）
- **安全性**: 使用云存储原生加密
- **兼容性**: 必须与现有 Docker Compose 架构兼容
- **自动化**: 无需人工干预，完全自动执行

## Key Decisions

<!-- Decisions that constrain future work. Add throughout project lifecycle. -->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| 云存储方案 | 待调研性价比最优选项（Backblaze B2、AWS S3、Wasabi） | — Pending |
| 备份工具 | 待确定（pg_dump、自定义脚本、或第三方工具） | — Pending |
| 调度方式 | 待确定（Jenkins cron vs Docker 容器 vs systemd） | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-06 after milestone v1.0 initialization*
