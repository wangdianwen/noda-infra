---
phase: 47-noda-site-image
fixed_at: 2026-04-20T12:30:00Z
review_path: .planning/phases/47-noda-site-image/47-REVIEW.md
iteration: 1
findings_in_scope: 4
fixed: 4
skipped: 0
status: all_fixed
---

# Phase 47: Code Review Fix Report

**Fixed at:** 2026-04-20T12:30:00Z
**Source review:** .planning/phases/47-noda-site-image/47-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 4
- Fixed: 4
- Skipped: 0

## Fixed Issues

### CR-01: Jenkinsfile 将 nginx 配置复制到错误的构建上下文子目录，与 Dockerfile COPY 路径不匹配

**Files modified:** `jenkins/Jenkinsfile.noda-site`
**Commit:** 1bc4702
**Applied fix:** 在 `mkdir -p` 之前添加 `rm -rf "$WORKSPACE/noda-apps/deploy"`，确保 noda-apps 仓库中可能存在的 deploy/ 目录不会覆盖 Jenkinsfile 注入的 nginx 配置文件。

### WR-01: 蓝绿部署路径中健康检查时序与 compose 定义不一致

**Files modified:** `scripts/manage-containers.sh`, `jenkins/Jenkinsfile.noda-site`
**Commit:** 0edd3dd
**Applied fix:** 在 `run_container` 函数中将健康检查时序参数（interval、timeout、retries、start_period）改为环境变量覆盖。默认值保持 findclass-ssr 兼容（30s/10s/3/60s），Jenkinsfile.noda-site 覆盖为 noda-site 的值（10s/3s/3/3s），与 docker-compose.app.yml 一致。

### WR-02: 蓝绿部署路径中 CPU 限制与 compose 定义不一致

**Files modified:** `scripts/manage-containers.sh`, `jenkins/Jenkinsfile.noda-site`
**Commit:** 0edd3dd
**Applied fix:** 将 `--cpus 1` 硬编码改为 `${CONTAINER_CPUS:-1}` 参数化。Jenkinsfile.noda-site 设置 `CONTAINER_CPUS = "0.25"`，与 docker-compose.app.yml 中 noda-site 的 0.25 核限制一致。

### WR-03: 蓝绿部署路径中 /app/scripts/logs tmpfs 挂载不适用于 nginx 容器

**Files modified:** `scripts/manage-containers.sh`, `jenkins/Jenkinsfile.noda-site`
**Commit:** 0edd3dd
**Applied fix:** 将硬编码的两个 `--tmpfs` 改为基于 `CONTAINER_TMPFS` 环境变量的动态列表。默认值 `/tmp /app/scripts/logs` 保持 findclass-ssr 兼容，Jenkinsfile.noda-site 覆盖为 `CONTAINER_TMPFS = "/tmp"`。

## Skipped Issues

None -- all in-scope findings were successfully fixed.

---

_Fixed: 2026-04-20T12:30:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
