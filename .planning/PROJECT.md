# Noda 基础设施项目

## Current Milestone: v1.2 基础设施修复与整合

**Goal:** 修复 B2 备份中断、整合服务分组、清除遗留问题、补齐开发环境

**Target features:**
1. B2 备份修复 — 调查 4/8 起备份中断原因并修复
2. findclass-ssr 分组整合 — 目录结构 + Docker Compose 归入 noda-apps
3. 备份系统 bug 修复 — 磁盘空间检查 + 验证测试下载功能
4. Keycloak 双环境 — 本地独立实例 + 配置结构统一（复用 PostgreSQL prod/dev overlay 模式）
5. Keycloak 自定义主题 — 实现品牌化登录页

## Shipped Milestones

### v1.1 基础设施现代化 ✅ (2026-04-11)
- ✅ findclass-ssr 三合一服务（SSR + API + 静态文件）
- ✅ Keycloak Google 登录 5 层修复
- ✅ PostgreSQL prod/dev 双实例（安全端口隔离）
- ✅ noda-ops 容器合并（备份 + Cloudflare Tunnel）
- ✅ 全量文档更新并验证（10 个文档）
- ✅ 基础设施清理（Vercel/Supabase/Jenkins 残留）

### v1.0 完整备份系统 ✅ (2026-04-06)
- ✅ 完整的本地备份流程（健康检查 → 备份 → 验证 → 清理）
- ✅ B2 云存储集成（自动上传、重试、校验、清理）
- ✅ 一键恢复脚本（列出、下载、恢复、验证）
- ✅ 每周自动验证测试（4 层验证机制）
- ✅ 监控与告警系统（结构化日志、邮件告警、指标追踪）

## What This Is

Noda 项目基础设施仓库，通过 Docker Compose 管理生产环境的数据库、认证、反向代理和应用服务部署。包含完整的数据库备份系统和现代化服务架构。

**技术栈：**
- Docker Compose（多环境 overlay）
- PostgreSQL 17.9（prod/dev 双实例）
- Keycloak 26.2.3（Google OAuth 登录）
- Nginx 1.25-alpine（反向代理）
- Cloudflare Tunnel（外部访问）
- Backblaze B2 云存储（备份）
- findclass-ssr（Node.js SSR 三合一服务）

## Core Value

数据库永不丢失。即使发生服务器崩溃、误删除、数据库损坏等灾难，也能从最近12小时内的备份中恢复数据。

## Architecture

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops) → Docker 内部网络
  class.noda.co.nz → nginx → findclass-ssr (SSR + API + 静态文件)
  auth.noda.co.nz  → keycloak:8080
```

## Requirements

### Validated (v1.0)

- ✓ BACKUP-01~05: 多数据库备份、时间戳命名、压缩格式、健康检查、磁盘检查
- ✓ UPLOAD-01~05: B2 上传、重试、校验、保留策略、清理
- ✓ RESTORE-01~04: 一键恢复、列备份、指定恢复、恢复到测试库
- ✓ VERIFY-01~02: 即时验证、每周自动测试
- ✓ MONITOR-01~05: 结构化日志、Webhook 告警、耗时追踪、磁盘检查、退出码
- ✓ SECURITY-01~02: 环境变量管理、最小权限 B2 Key

### Active (v1.2)

- ✓ BFIX-01: Crontab 路径不匹配修复 (Validated in Phase 10: b2)
- ✓ BFIX-02: 容器内磁盘空间检查修复 (Validated in Phase 10: b2)
- ✓ BFIX-03: B2 下载路径解析修复 (Validated in Phase 10: b2)

### Out of Scope

- 实时复制/流备份 — 需要主从架构，6-12 小时 RPO 已满足需求
- PITR 时间点恢复 — 复杂度极高
- 跨区域备份复制 — B2 已有数据中心冗余
- Web 管理面板 — Jenkins 已提供基本管理能力

## Context

**基础设施状态 (v1.1)：**
- PostgreSQL 17.9 prod/dev 双实例
- Keycloak 26.2.3 认证服务（Google OAuth 已修复）
- findclass-ssr 三合一应用服务
- noda-ops 运维容器（备份 + Cloudflare Tunnel）
- Nginx 反向代理
- 完整的文档体系（10 个文档）

**部署状态：**
- ✅ 所有服务运行正常
- ✅ Google 登录功能正常
- ✅ Cloudflare Tunnel 连接正常
- ⚠️ B2 备份自 4/8 起中断（Phase 10 已修复，待生产环境验证）

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| 云存储方案 | Backblaze B2 性价比最优 | ✅ Good |
| findclass-ssr 三合一 | 减少 50% 容器数量 | ✅ Good |
| PostgreSQL 不暴露端口 | 安全最佳实践 | ✅ Good |
| noda-ops 容器合并 | 减少运维复杂度 | ✅ Good |
| Keycloak v2 SPI | v1 选项废弃 | ✅ Good |
| Docker Compose overlay | 多环境共享基础配置 | ✅ Good |

## Evolution

**v1.1 完成后更新：**
1. ✅ 基础设施现代化完成
2. ✅ 全量文档更新并验证
3. ✅ 历史遗留清理

**下一步 (v1.2)：**
- Phase 10 完成 — B2 备份 3 个 bug 已修复（crontab 路径、磁盘检查、下载路径）
- 监控生产环境运行情况
- 根据实际使用情况规划

---

*Last updated: 2026-04-11 after Phase 10 (b2) completion*
