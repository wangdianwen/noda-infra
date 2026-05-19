---
gsd_state_version: 1.0
milestone: v1.12
milestone_name: 迁移到 iStoreOS (r4s)
status: Phase 61 完成，准备规划 Phase 62
last_updated: "2026-05-19T03:51:29.433Z"
progress:
  total_phases: 5
  completed_phases: 4
  total_plans: 17
  completed_plans: 15
  percent: 80
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-05-17)

**Core value:** 数据库永不丢失。迁移不改变核心功能，只改变运行位置。

**Current focus:** Phase 62 — 切换与验证

## Current Position

Phase: 62 (切换与验证) — PLANNING
Plan: 0 of TBD
Status: Phase 61 完成，准备规划 Phase 62
Progress: [█████████░] 88%

### Phase 61 完成总结

所有备份 cronjob 和 Cloudflare Tunnel 已从 Mac 迁移到 r4s。

**验证结果：8/8 全部通过**

| 验证项 | 状态 |
|--------|------|
| pg_dump 每日备份 | ✅ |
| B2 云备份上传 | ✅ |
| Doppler 密钥备份 | ✅ |
| 周验证测试 | ✅ |
| Mac 旧容器清理 | ✅ |
| Cloudflare Tunnel | ✅ |
| Nginx 端口映射 | ✅ |
| pre-prod 路由 | ✅ |

### Phase 62 目标

迁移完成后的全链路验证、清理和回滚方案确认。

### 完成定义

Phase 62 完成当：

1. 全链路验证通过：浏览器 → Cloudflare → r4s Nginx → 各服务（prod + pre-prod）
2. Mac 上旧容器已停止并清理，不再占用端口和资源
3. 回滚方案已验证：如果 r4s 出问题，可以快速切回 Mac 运行

## Accumulated Context

### 关键决策记录

| 决策 | 理由 | 结果 |
|------|------|------|
| r4s 作为目标服务器 | ARM64 架构与 Mac M4 兼容，Docker 镜像可直接复用 | ✅ 已确认 |
| Jenkins 保留在 Mac | r4s 内存不足（3.77 GiB），Jenkins 需要独立环境 | ✅ 已确认 |
| SSH 远程部署模式 | Jenkins 在 Mac 通过 SSH 执行 r4s 上的 docker compose 命令 | ✅ 已确认 |
| 零停机迁移策略 | r4s 服务先启动，验证通过后切换 Cloudflare | ✅ 已确认 |
| Phase 57 环境准备 | 独立网桥、Swap、内存限制、SSH 密钥配置 | ✅ 已完成 |

### 已知问题

- r4s 上 Docker 镜像过旧，通过 volume mount 覆盖脚本文件（config.sh, test-verify.sh）。未来需要重建镜像以移除 workaround。

### 阻塞问题

无阻塞问题。

## Session Continuity

**上次会话结束**: 2026-05-19
**上次会话成果**: Phase 61 完成，8/8 验证通过
**下次会话重点**: Phase 62 切换与验证规划
**上下文恢复**: `.planning/phases/61-backup-network-migration/`

---
*State created: 2026-05-17*
*Last updated: 2026-05-19*
