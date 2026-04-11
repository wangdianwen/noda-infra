# Noda 基础设施项目

## Current Milestone: v1.3 安全收敛与分组整理

**Goal:** 消除所有端口直接暴露，统一通过 nginx 代理，完成容器分组

**Target features:**
1. PostgreSQL 客户端升级（pg_dump 16.11 → 17.x）
2. Keycloak 统一反代（auth.noda.co.nz → nginx → Keycloak；dev 复用线上 Keycloak + localhost callback）
3. PostgreSQL dev 端口安全评估与规避
4. 容器标签分组（noda-prod / noda-dev）

**Previous state:** v1.2 已交付 (2026-04-11) — 5 Phase、10 Plan、96 commit，所有生产容器运行正常，安全加固已部署。

## Shipped Milestones

### v1.2 基础设施修复与整合 ✅ (2026-04-11)

96 commits, 93 files changed (+12,200/-2,196 LOC)

- B2 备份修复（crontab 路径/磁盘检查/下载路径 3 个 bug）
- 服务整合（Dockerfile 路径统一 + noda.service-group 分组标签）
- Keycloak 双环境（dev 独立实例 + 密码登录 + 主题热重载）
- Keycloak 品牌主题（Pounamu Green #2D6A4F 登录页）
- 容器安全加固（5 容器 no-new-privileges/cap_drop:ALL/read_only）
- 部署自动化（镜像回滚 + 部署前备份 + Nginx 故障转移 + 自定义错误页面）

### v1.1 基础设施现代化 ✅ (2026-04-11)

29 commits, 134 files changed (+2617/-3710 lines)

- findclass-ssr 三合一服务（SSR + API + 静态文件）
- Keycloak Google 登录 5 层修复
- PostgreSQL prod/dev 双实例（安全端口隔离）
- noda-ops 容器合并（备份 + Cloudflare Tunnel）
- 全量文档更新与历史遗留清理

### v1.0 完整备份系统 ✅ (2026-04-06)

9 phases, 16 plans, 23 tasks

- 完整的本地备份流程（健康检查 → 备份 → 验证 → 清理）
- B2 云存储集成（自动上传、重试、校验、清理）
- 一键恢复脚本（列出、下载、恢复、验证）
- 每周自动验证测试（4 层验证机制）
- 监控与告警系统（结构化日志、邮件告警、指标追踪）

## What This Is

Noda 项目基础设施仓库，通过 Docker Compose 管理生产环境的数据库、认证、反向代理和应用服务部署。

**技术栈：**
- Docker Compose（多环境 overlay）
- PostgreSQL 17.9（prod/dev 双实例）
- Keycloak 26.2.3（Google OAuth + 品牌主题）
- Nginx 1.25-alpine（反向代理 + 故障转移）
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

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| 云存储方案 | Backblaze B2 性价比最优 | ✅ Good |
| findclass-ssr 三合一 | 减少 50% 容器数量 | ✅ Good |
| PostgreSQL 不暴露端口 | 安全最佳实践 | ✅ Good |
| noda-ops 容器合并 | 减少运维复杂度 | ✅ Good |
| Keycloak v2 SPI | v1 选项废弃 | ✅ Good |
| Docker Compose overlay | 多环境共享基础配置 | ✅ Good |
| 容器 read_only + tmpfs | 最小权限原则 | ✅ Good |
| 部署前自动备份 | 安全网机制 | ✅ Good |

---
---

*Last updated: 2026-04-11 — v1.3 milestone started*
