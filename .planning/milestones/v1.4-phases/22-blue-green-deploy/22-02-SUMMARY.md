---
phase: 22-blue-green-deploy
plan: 02
subsystem: infra
tags: [blue-green, rollback, docker, nginx, bash]

requires:
  - phase: 21-blue-green-containers
    provides: manage-containers.sh with get_active_env, get_container_name, update_upstream, reload_nginx, set_active_env, is_container_running functions
  - phase: 22-blue-green-deploy/plan-01
    provides: source guard in manage-containers.sh
provides:
  - rollback-findclass.sh emergency rollback script

tech-stack:
  added: []
  patterns: [independent rollback, aggressive health check, docker exec wget]

key-files:
  created:
    - scripts/rollback-findclass.sh
  modified: []

---

# Plan 22-02: 紧急回滚脚本

## What was Built

1. **rollback-findclass.sh** — 200 行独立紧急回滚脚本，完整 4 步回滚流程

## Implementation Details

### 回滚流程（4 步）

1. **验证回滚目标容器健康** — `docker exec wget` 直检，10 次 x 3 秒 = 30 秒（比部署脚本更激进）
2. **切换流量** — `update_upstream()` + `nginx -t` + `reload_nginx()`
3. **E2E 验证** — nginx 容器内 curl/wget 目标容器，失败时告警但不自动恢复
4. **完成** — 旧版本容器保持运行，可手动停止

### 关键设计决策

- **独立运行**：不依赖 blue-green-deploy.sh，只 source manage-containers.sh
- **自有健康检查**：定义独立的 `http_health_check()` 和 `e2e_verify()`，参数更激进（30 秒 vs 部署的 120 秒）
- **前置检查**：nginx 容器必须运行，回滚目标容器必须运行且健康
- **不自动停新容器**：回滚后新版本容器保持运行，由运维手动决定是否停止

## Deviations

无偏差，实现完全遵循 CONTEXT.md 和 PLAN.md。
