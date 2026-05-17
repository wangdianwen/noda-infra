---
gsd_state_version: 1.0
milestone: v1.12
milestone_name: 迁移到 iStoreOS (r4s)
status: Not started
stopped_at: Phase 57 context gathered
last_updated: "2026-05-17T05:02:37.030Z"
last_activity: 2026-05-17 — Milestone v1.12 规划完成
progress:
  total_phases: 6
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-05-17)

**Core value:** 数据库永不丢失。即使发生服务器崩溃、误删除、数据库损坏等灾难，也能从最近12小时内的备份中恢复数据。

**Current focus:** Phase 57 — 环境准备（r4s Docker 网络与资源限制配置）

## Current Position

Phase: Phase 57 - 环境准备
Plan: TBD
Status: Not started
Last activity: 2026-05-17 — Milestone v1.12 规划完成

## Accumulated Context

### Decisions

- [v1.12]: r4s 作为生产服务器（Mac M4 和 r4s 都是 ARM64，Docker 镜像直接复用）
- [v1.12]: Jenkins 保留在 Mac（r4s 内存不足，通过 SSH 远程部署）
- [v1.12]: 共享基础设施（prod + pre-prod 共享 PostgreSQL/Keycloak，节省内存）
- [v1.12]: 蓝绿部署移除（v1.11 已完成，简化部署流程）
- [v1.12]: 回滚方案保留（Mac 上的所有脚本和配置保留，可快速切回）
- [v1.11]: 共享基础设施、隔离应用层（PostgreSQL/Keycloak/Nginx 单实例，数据库/realm 级别隔离）
- [v1.11]: Build Once / Promote Anywhere（Jenkins 构建一次镜像，pre-prod 验证后 promote 同一镜像到 prod）
- [v1.11]: Doppler pre config 必须在 Pipeline 之前创建（PIPE-01 需要 DOPPLER_CONFIG=pre）
- [v1.11]: Docker 网络别名隔离必须在 pre-prod 容器启动前完成（SEC-03）
- [54-01]: 使用 _preprod_ 前缀命名所有 upstream 变量，防止蓝绿部署时与 prod 变量冲突
- [54-01]: 共享 Keycloak 实例（pre-prod Auth App 使用 pre-prod upstream，Keycloak 路由使用共享 upstream）
- [54-01]: Forwarded protocol 映射确保 pre-prod 域名的 X-Forwarded-Proto/Port 头正确（HTTPS/443）
- [54-02]: Pre-prod 路由基础设施验证完成，Cloudflare Tunnel + Nginx 配置就绪
- [55-01]: 使用 UPSTREAM_VARS_PREFIX 方案实现 manage-containers.sh 参数化，支持 prod 和 pre-prod 环境
- [55-02]: 创建 pre-prod 环境变量模板、容器命名规范和状态文件管理
- [55-03]: 更新 image-cleanup.sh 支持多环境，实现 Docker 网络别名隔离和安全验证
- [55-01]: manage-containers.sh 支持 NODA_ENVIRONMENT 参数化（UPSTREAM_VARS_PREFIX 机制）
- [55-02]: 创建 pre-prod 环境变量模板、状态文件管理和部署脚本
- [55-03]: 镜像清理脚本参数化，网络别名隔离验证工具
- [56-01]: 创建 Jenkinsfile.noda-apps-preprod，实现 pre-prod 完整部署流程
- [56-02]: 创建 Jenkinsfile.noda-apps-promote，实现 Build Once / Promote Anywhere 流程
- [56-03]: 实现 upstream 写入防护、Pipeline 并发锁和 Jenkins Job 初始化脚本

### Blockers/Concerns

- r4s 内存限制（3.77 GiB），需要合理分配所有容器内存限制
- Swap 文件需要手动创建，iStoreOS 默认无 Swap
- ~~manage-containers.sh update_upstream() 参数化方案需要在 Phase 55 实现时统一决策（UPSTREAM_VARS_PREFIX vs if/else 分支）~~ ✅ 已解决：采用 UPSTREAM_VARS_PREFIX 方案
- Jenkins lock() 资源锁需要确认是否需要额外插件（Lockable Resources Plugin）
- ~~Pre-prod 应用容器未部署（Phase 55 脚本已完成，等待 Phase 56 Jenkins Pipeline 自动部署）~~ ✅ v1.11 已完成

### Deferred Items

Items acknowledged and deferred:

| Category | Item | Status |
|----------|------|--------|
| v2 | MON-01: r4s 容器资源监控告警 | Deferred |
| v2 | LOG-01: 集中式日志收集 | Deferred |
| v2 | HA-01: r4s 高可用方案 | Deferred |
| v2 | DISK-01: 1TB 机械硬盘挂载 | Deferred |
| uat | Phase 32 (32-HUMAN-UAT.md) | partial, 2 pending |
| uat | Phase 34 (34-HUMAN-UAT.md) | partial, 2 pending |
| verification | Phase 32 (32-VERIFICATION.md) | human_needed |
| verification | Phase 34 (32-VERIFICATION.md) | human_needed |

## Session Continuity

Last session: 2026-05-17T05:02:37.025Z
Stopped at: Phase 57 context gathered
Resume file: .planning/phases/57-env-prep/57-CONTEXT.md

### Next Steps

1. 开始 Phase 57: 环境准备
2. 在 r4s 上创建 Docker 独立网桥（noda-network）
3. 创建 2GB Swap 文件
4. 配置容器内存限制
5. 配置 SSH 免密登录

### Context Handoff

- **Current focus:** v1.12 迁移到 iStoreOS (r4s)
- **Key constraint:** r4s 内存限制（3.77 GiB）
- **Critical path:** 环境准备 → 基础设施迁移 → 应用迁移 → CI/CD 改造 → 备份网络迁移 → 切换验证
- **Success criteria:** 所有服务在 r4s 上运行，Mac 清理干净，回滚方案就绪
