# Roadmap: Noda Infrastructure

**当前里程碑**: v1.13
**粒度**: fine
**覆盖率**: 100% requirements mapped

## Milestones

### v1.12: 迁移到 iStoreOS (r4s) ✅ 2026-05-20

将所有 Docker 服务从 Mac 迁移到 r4s (iStoreOS)，Jenkins 保留在 Mac 通过 SSH 远程部署。

**结果**: 90% 完成（26/29 requirements，3 partial）。Phase 58-61 完成，Phase 62 部分完成。

→ [完整里程碑归档](./milestones/v1.12-ROADMAP.md)

### v1.13: 待规划（下一个里程碑）

待定义。

## Current Phase

**Phase 63**: 待规划

## Progress

| Milestone | Status | Phases | Completed |
|-----------|--------|--------|-----------|
| v1.12 | ✅ Shipped | 58-62 | 2026-05-20 |
| v1.13 | 🔄 Planning | 63+ | - |

## Dependencies

```
v1.12 (迁移到 r4s) ✅ 已完成
    ↓
v1.13 (待规划)
```

## Context

**Project**: Noda 基础设施管理，通过 Docker Compose 部署 PostgreSQL、Keycloak、Nginx、应用服务和 Cloudflare Tunnel。

**Technology Stack**:
- Docker Compose（多环境 overlay）
- PostgreSQL 17.9
- Keycloak 26.2.3
- Nginx 1.25-alpine
- Jenkins（宿主机，通过 SSH 远程部署）
- Backblaze B2 云存储（备份）

**Core Value**: 数据库永不丢失。

---
*Roadmap created: 2026-05-17*
*Last updated: 2026-05-20 after v1.12 completion*
