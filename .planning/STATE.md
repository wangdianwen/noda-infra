---
gsd_state_version: 1.0
milestone: v1.12
milestone_name: 迁移到 iStoreOS (r4s)
status: ready_to_plan
last_updated: 2026-05-17T20:38:52.188Z
progress:
  total_phases: 5
  completed_phases: 0
  total_plans: 3
  completed_plans: 3
  percent: 0
stopped_at: Phase 58 complete (3/3) — ready to discuss Phase 59
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-05-17)

**Core value:** 数据库永不丢失。迁移不改变核心功能，只改变运行位置。

**Current focus:** Phase 59 — 应用服务迁移

## Current Position

Phase: 59
Plan: Not started
Status: Ready to plan
Progress: 0/5 phases (0%)

### Phase 58 目标

所有基础设施容器（PostgreSQL、Keycloak、Nginx、noda-ops）在 r4s 上正常运行，数据完整迁移。

### 完成定义

Phase 58 完成当：

1. PostgreSQL 数据从 Mac 完整迁移到 r4s，无数据丢失
2. Keycloak 在 r4s 上启动，所有配置与 Mac 环境一致
3. Nginx 在 r4s 上正常监听 80/443 端口
4. noda-ops 容器在 r4s 上运行，Cloudflare Tunnel 能连接
5. 所有基础设施容器加入 noda-network 外部网络

## Accumulated Context

### 关键决策记录

| 决策 | 理由 | 结果 |
|------|------|------|
| r4s 作为目标服务器 | ARM64 架构与 Mac M4 兼容，Docker 镜像可直接复用 | ✅ 已确认 |
| Jenkins 保留在 Mac | r4s 内存不足（3.77 GiB），Jenkins 需要独立环境 | ✅ 已确认 |
| SSH 远程部署模式 | Jenkins 在 Mac 通过 SSH 执行 r4s 上的 docker compose 命令 | ✅ 已确认 |
| 零停机迁移策略 | r4s 服务先启动，验证通过后切换 Cloudflare | ✅ 已确认 |
| Phase 57 环境准备 | 独立网桥、Swap、内存限制、SSH 密钥配置 | ✅ 已完成 |

### 技术约束

**r4s 硬件限制**:

- 内存: 3.77 GiB（需要容器内存限制）
- 存储: 64GB SD卡（需要定期清理镜像）
- 架构: ARM64（与 Mac M4 兼容）

**网络约束**:

- r4s 作为软路由，端口映射需要避免冲突
- Cloudflare Tunnel 需要指向 r4s 公网 IP
- Nginx 80/443 端口需要从 r4s 暴露

**数据迁移约束**:

- PostgreSQL 必须零数据丢失（pg_dump/pg_restore）
- Keycloak 配置必须完整迁移（realm/客户端/用户）
- 迁移期间服务不能中断（r4s 先启动，再切换）

### 待办事项

**Phase 58 待办**:

- [ ] PostgreSQL 数据迁移（pg_dump/pg_restore）
- [ ] Keycloak 配置迁移
- [ ] Nginx 配置迁移
- [ ] noda-ops 容器迁移
- [ ] noda-network 外部网络创建

**Phase 59 待办**:

- [ ] findclass-ssr prod 容器迁移
- [ ] findclass-ssr pre-prod 容器迁移
- [ ] noda-admin 容器迁移
- [ ] noda-auth 容器迁移

**Phase 60 待办**:

- [ ] Jenkinsfile 应用部署 Pipeline 改造
- [ ] Docker 镜像传输流程（docker save/load）
- [ ] Jenkinsfile 基础设施 Pipeline 改造
- [ ] SSH 远程部署验证

**Phase 61 待办**:

- [ ] pg_dump 备份 cronjob 迁移
- [ ] B2 云备份迁移
- [ ] Doppler 密钥备份 cronjob 迁移
- [ ] 周验证测试 cronjob 迁移
- [ ] Mac 旧备份清理
- [ ] Cloudflare Tunnel 迁移
- [ ] Nginx 端口映射验证
- [ ] pre-prod 域名路由验证

**Phase 62 待办**:

- [ ] 全链路验证
- [ ] Mac 旧容器清理
- [ ] 回滚方案验证

### 已知问题

无已知问题。

### 阻塞问题

无阻塞问题。

### Deferred Items

无推迟项。

## Session Continuity

**上次会话结束**: 2026-05-17
**上次会话成果**: 完成 Phase 57 环境准备，创建 v1.12 路线图
**下次会话重点**: 开始 Phase 58 基础设施迁移规划

**上下文提示**:

- r4s SSH 访问: `ssh root@192.168.1.1`（根据实际 IP 调整）
- Docker 在 r4s 上的路径: `/mnt/mmc1-4/docker`
- iStoreOS 版本: 24.10.6
- Docker 版本: 27.3.1
- Docker Compose 版本: v2.39.1

**快速恢复命令**:

```bash

# 检查 r4s Docker 状态

ssh root@192.168.1.1 "docker ps -a"

# 检查 r4s 网络

ssh root@192.168.1.1 "docker network ls"

# 检查 Mac 当前容器

docker ps -a
```

**路线图阶段映射**:

- Phase 58: INFRA-01~05（基础设施迁移）
- Phase 59: APP-01~04（应用服务迁移）
- Phase 60: CICD-01~04（CI/CD 改造）
- Phase 61: BACKUP-01~05, NET-01~03（备份与网络迁移）
- Phase 62: SWITCH-01~03（切换与验证）

---
*State created: 2026-05-17*
*Last updated: 2026-05-17*
