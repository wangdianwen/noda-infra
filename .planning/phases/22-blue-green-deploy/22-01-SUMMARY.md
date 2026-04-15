---
phase: 22-blue-green-deploy
plan: 01
subsystem: infra
tags: [blue-green, docker, nginx, deployment, bash]

requires:
  - phase: 21-blue-green-containers
    provides: manage-containers.sh with run_container, update_upstream, reload_nginx functions
  - phase: 20-nginx
    provides: upstream-findclass.conf include file for traffic switching
provides:
  - source guard for manage-containers.sh (safe sourcing)
  - blue-green-deploy.sh zero-downtime deployment script
affects: [phase-23-pipeline, phase-24-enhancements, phase-25-cleanup]

tech-stack:
  added: []
  patterns: [source guard pattern, HTTP health check via docker exec, E2E verification via nginx container]

key-files:
  created:
    - scripts/blue-green-deploy.sh
  modified:
    - scripts/manage-containers.sh

---

# Plan 22-01: 蓝绿部署主脚本

## What was built

1. **manage-containers.sh source guard** — 在 case 分发前添加 `BASH_SOURCE[0] == ${0}` 检测，使 source 复用时不会触发子命令分发
2. **blue-green-deploy.sh** — 297 行零停机部署脚本，完整 7 步编排流程

## Implementation Details

### 部署流程（7 步）

1. **构建镜像** — `docker compose build findclass-ssr`
2. **SHA 标签** — `docker tag findclass-ssr:latest findclass-ssr:{SHA7}`
3. **停止旧目标 + 启动新容器** — 通过 `run_container()` 复用 manage-containers.sh
4. **HTTP 健康检查** — `docker exec wget` 直检，30 次 x 4 秒 = 120 秒超时
5. **切换流量** — `update_upstream()` + `nginx -t` + `reload_nginx()`
6. **E2E 验证** — nginx 容器内 curl/wget 目标容器名，失败自动回滚
7. **清理旧镜像** — 保留最近 5 个标签镜像

### 关键设计决策

- **HTTP 直检**：使用 `docker exec wget`（容器基于 node:20-alpine，有 wget 无 curl）
- **E2E 双模式**：优先 curl，nginx 容器无 curl 时自动回退 wget
- **失败防护**：健康检查失败 → 不切换流量、不停旧容器；E2E 失败 → 自动回滚到旧环境
- **自动检测**：读取 `/opt/noda/active-env` 自动部署到非活跃侧

## Deviations

无偏差，实现完全遵循 CONTEXT.md 和 PLAN.md。
