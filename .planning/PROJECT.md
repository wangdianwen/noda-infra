# Noda 基础设施项目

## Current Milestone: v1.6 Jenkins Pipeline 强制执行

**Goal:** 所有容器只能通过 Jenkins Pipeline 上线，禁止直接 docker compose / shell 脚本部署

**Target features:**
- Docker 权限收敛：仅 jenkins 用户可执行 docker 命令
- 部署脚本权限锁定：仅 jenkins 用户可执行 deploy 脚本
- 操作审计日志（记录谁在什么时候执行了什么）

## Current State

**Last shipped:** v1.5 开发环境本地化 + 基础设施 CI/CD (2026-04-17)
**Active milestone:** v1.6 Jenkins Pipeline 强制执行

## Shipped Milestones

### v1.5 开发环境本地化 + 基础设施 CI/CD ✅ (2026-04-17)

5 phases, 12 plans, 17 tasks, 72 files changed (+10,834/-337 LOC)

- 宿主机 PostgreSQL 安装脚本（setup-postgres-local.sh 4 子命令，Apple Silicon/Intel 双架构）
- 开发容器清理（移除 postgres-dev/keycloak-dev，Docker 纯线上业务）
- Keycloak 蓝绿部署（env 模板 + upstream 切换 + manage-containers.sh 参数化 + Jenkins Pipeline）
- 统一基础设施 Jenkins Pipeline（Jenkinsfile.infra 4 服务 + 12 个 pipeline_infra_* 函数）
- 一键开发环境脚本（setup-dev.sh 幂等非交互式 4 步编排）

### v1.4 CI/CD 零停机部署 ✅ (2026-04-16)

7 phases, 11 plans, 95 commits, 89 files changed (+15,967/-1,511 LOC)

- Jenkins 宿主机原生安装/卸载脚本（setup-jenkins.sh 7 子命令 + groovy 自动化）
- Nginx upstream include 抽离（蓝绿路由基础，支持 nginx -s reload 切换）
- 蓝绿容器管理（manage-containers.sh 8 子命令 + env-findclass-ssr.env 模板）
- 蓝绿部署核心流程（blue-green-deploy.sh + rollback-findclass.sh，零停机 + 自动回滚）
- Jenkinsfile 9 阶段 Pipeline + pipeline-stages.sh 函数库（lint/test 质量门禁）
- Pipeline 增强特性（备份时效性检查 + CDN 缓存清除 + 镜像时间阈值清理）
- 旧脚本保留为手动回退 + 部署文档更新 + 里程碑归档

### v1.3 安全收敛与分组整理 ✅ (2026-04-12)

4 phases, 4 plans, 89 commits, 113 files changed (+9,291/-546 LOC)

### v1.2 基础设施修复与整合 ✅ (2026-04-11)

96 commits, 93 files changed (+12,200/-2,196 LOC)

### v1.1 基础设施现代化 ✅ (2026-04-11)

29 commits, 134 files changed (+2617/-3710 lines)

### v1.0 完整备份系统 ✅ (2026-04-06)

9 phases, 16 plans, 23 tasks

## What This Is

Noda 项目基础设施仓库，通过 Docker Compose 管理生产环境的数据库、认证、反向代理和应用服务部署。开发环境使用宿主机 PostgreSQL，生产环境通过 Jenkins Pipeline 管理部署。

**技术栈：**
- Docker Compose（多环境 overlay + 独立项目分离）
- PostgreSQL 17.9（生产 Docker + 开发宿主机 Homebrew）
- Keycloak 26.2.3（Google OAuth + 品牌主题 + 蓝绿部署）
- Nginx 1.25-alpine（反向代理 + 故障转移 + upstream 切换）
- Jenkins LTS（Declarative Pipeline + 蓝绿/滚动部署）
- Cloudflare Tunnel（外部访问）
- Backblaze B2 云存储（备份）
- findclass-ssr（Node.js SSR 三合一服务）

## Core Value

数据库永不丢失。即使发生服务器崩溃、误删除、数据库损坏等灾难，也能从最近12小时内的备份中恢复数据。

## Architecture

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops) → Docker 内部网络
  class.noda.co.nz → nginx → findclass-ssr (SSR + API + 静态文件)
  auth.noda.co.nz  → nginx → keycloak:8080

Docker Compose 项目：
  noda-infra  — postgres, keycloak, nginx, noda-ops
  noda-apps   — findclass-ssr
  共享网络：noda-network (external)

开发环境：
  宿主机 PostgreSQL (Homebrew) — setup-dev.sh 一键搭建
  生产 Keycloak 测试 — 无需本地安装
```

## Requirements

### Validated

- ✓ pg_dump 17.x 版本匹配 — v1.3
- ✓ 备份 sslmode=disable — v1.3
- ✓ Keycloak nginx 统一反代 — v1.3
- ✓ Keycloak 端口不暴露 — v1.3
- ✓ postgres-dev 127.0.0.1 绑定 — v1.3
- ✓ 容器双标签体系 — v1.3
- ✓ Docker Compose 项目分离 — v1.3
- ✓ Jenkins 宿主机原生安装/卸载 — v1.4
- ✓ Nginx upstream include 抽离（蓝绿路由基础） — v1.4
- ✓ 现有部署脚本迁移为 Jenkins Pipeline — v1.4
- ✓ findclass-ssr 蓝绿部署（零停机） — v1.4
- ✓ Pipeline lint + 单元测试门禁 — v1.4
- ✓ 上线后 HTTP E2E 健康检查 — v1.4
- ✓ 验证失败自动回滚 — v1.4
- ✓ 宿主机 PostgreSQL 安装与配置 (Homebrew) — v1.5
- ✓ 移除 postgres-dev / keycloak-dev 容器 — v1.5
- ✓ 统一基础设施 Jenkins Pipeline（参数化服务选择） — v1.5
- ✓ Keycloak 蓝绿部署（零停机） — v1.5
- ✓ 部署前自动备份 + 健康检查 + 回滚 + 人工确认门禁 — v1.5
- ✓ 一键开发环境脚本（setup-dev.sh） — v1.5

### Active

- [ ] Jenkins H2 → 本地 PostgreSQL 迁移
- [ ] Docker 权限收敛：仅 jenkins 用户可执行 docker 命令
- [ ] 部署脚本权限锁定：仅 jenkins 用户可执行 deploy 脚本
- [ ] 操作审计日志

### Out of Scope

| Feature | Reason |
|---------|--------|
| Docker Compose profiles | overlay 模式已满足需求 |
| 网络隔离（prod/dev 分离网络） | 标签分组已满足管理需求 |
| Prisma 7 迁移 | 依赖 noda-apps 仓库变更 |
| skykiwi-crawler Pipeline | 单次任务容器，手动触发足够 |
| 本地安装 Keycloak | 开发环境直接用生产 Keycloak 测试 |

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
| Docker Compose 项目分离 | 基础设施与应用独立部署 | ✅ Good |
| 容器双标签体系 | 按环境和服务组筛选 | ✅ Good |
| 所有端口 127.0.0.1 绑定 | 仅本地可访问 | ✅ Good |
| Upstream include 抽离 | 蓝绿部署路由基础 | ✅ Good |
| Pipeline 备份时效性检查 | 部署前安全网 | ✅ Good |
| CDN 缓存清除 | 部署后自动刷新 | ✅ Good |
| 镜像时间阈值清理 | 磁盘空间管理 | ✅ Good |
| 蓝绿容器 docker run 管理 | 避免与 compose 冲突 | ✅ Good |
| Pipeline 手动触发 | 生产环境安全控制 | ✅ Good |
| Jenkinsfile Declarative Pipeline | 可读性和可维护性 | ✅ Good |
| 本地 PostgreSQL 替代 Docker dev | 开发环境与生产分离，Docker 纯线上业务 | ✅ Good |
| 一键开发环境脚本 | 新开发者运行一个命令即可搭建环境 | ✅ Good |
| Jenkins 迁移到本地 PG | 数据更安全、可备份，消除 H2 风险 | — Pending |

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
*Last updated: 2026-04-17 — v1.6 milestone started*
