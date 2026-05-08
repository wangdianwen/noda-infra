---
gsd_state_version: 1.0
milestone: v1.11
milestone_name: Pre-Prod 验证环境 + 安全上线流程
status: planning
last_updated: "2026-05-08T12:00:00.000Z"
last_activity: 2026-05-08 -- Milestone v1.11 started
progress:
  total_phases: 0
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-05-08)

**Core value:** 数据库永不丢失。即使发生服务器崩溃、误删除、数据库损坏等灾难，也能从最近12小时内的备份中恢复数据。

**Current focus:** v1.11 Pre-Prod 验证环境

## Current Position

Phase: Not started (defining requirements)
Plan: —
Status: Defining requirements
Last activity: 2026-05-08 — Milestone v1.11 started

Progress: [          ] 0%

## Accumulated Context

### Decisions

- [v1.11]: noda-infra 共享基础设施（PostgreSQL/Keycloak/Nginx/Cloudflare 跑一份）
- [v1.11]: noda-apps 双实例（prod 和 pre-prod 各自蓝绿部署）
- [v1.11]: 同实例不同库（noda_prod + noda_preprod 在同一个 PostgreSQL 实例）
- [v1.11]: Keycloak 同实例新 realm（noda + noda-preprod）
- [v1.11]: 独立子域名访问（pre.class.noda.co.nz 等）
- [v1.11]: Git Trunk + Tag 推进策略
- [v1.11]: Keycloak 作为 noda-infra 共享基础设施（不单独部署）

### Blockers/Concerns

- 单服务器资源限制（pre-prod 增量约 1GB 内存）
- Cloudflare Tunnel 配置需要域名 DNS 变更

### Deferred Items

Items acknowledged and deferred:

| Category | Item | Status |
|----------|------|--------|
| uat | Phase 32 (32-HUMAN-UAT.md) | partial, 2 pending |
| uat | Phase 34 (34-HUMAN-UAT.md) | partial, 2 pending |
| verification | Phase 32 (32-VERIFICATION.md) | human_needed |
| verification | Phase 34 (32-VERIFICATION.md) | human_needed |

## Session Continuity

**Milestone:** v1.11 Pre-Prod 验证环境 + 安全上线流程 — STARTED
