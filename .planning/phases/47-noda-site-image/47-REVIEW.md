---
phase: 47-noda-site-image
reviewed: 2026-04-20T12:00:00Z
depth: standard
files_reviewed: 5
files_reviewed_list:
  - deploy/Dockerfile.noda-site
  - deploy/nginx/default.conf
  - deploy/nginx/nginx.conf
  - docker/docker-compose.app.yml
  - jenkins/Jenkinsfile.noda-site
findings:
  critical: 1
  warning: 3
  info: 3
  total: 7
status: issues_found
---

# Phase 47: Code Review Report

**Reviewed:** 2026-04-20T12:00:00Z
**Depth:** standard
**Files Reviewed:** 5
**Status:** issues_found

## Summary

Review of 5 files for the noda-site static site image: Dockerfile, nginx configs, Docker Compose service definition, and Jenkinsfile. Found 1 critical issue (build context mismatch between Dockerfile and Jenkinsfile), 3 warnings (resource limits and health-check timing inconsistencies between compose file and blue-green deploy path), and 3 info items.

## Critical Issues

### CR-01: Jenkinsfile 将 nginx 配置复制到错误的构建上下文子目录，与 Dockerfile COPY 路径不匹配

**File:** `jenkins/Jenkinsfile.noda-site:77-83` (combined with `deploy/Dockerfile.noda-site:44-45`)
**Issue:** Dockerfile 中的 COPY 指令引用 `deploy/nginx/nginx.conf` 和 `deploy/nginx/default.conf`，这些路径是相对于 Docker build context 的。Jenkinsfile Build 阶段将 nginx 配置复制到 `$WORKSPACE/noda-apps/deploy/nginx/`，构建 context 是 `$WORKSPACE/noda-apps`（由 `pipeline_build` 传入）。然而在构建完成后（第 83 行），Jenkinsfile 执行 `rm -rf "$WORKSPACE/noda-apps/deploy"` 清理了这些临时文件。虽然清理发生在构建之后所以不影响镜像构建，但真正的问题在于：Dockerfile 中的 COPY 路径 `deploy/nginx/nginx.conf` 依赖于 noda-apps 仓库中恰好没有 `deploy/` 目录。如果 noda-apps 仓库将来添加了 `deploy/` 目录（例如其他服务的 Dockerfile），Dockerfile 会优先复制 noda-apps 仓库中的文件而非 Jenkinsfile 注入的文件，导致构建出错误配置的镜像。

**Fix:**
```groovy
// Jenkinsfile Build 阶段 — 先清理 noda-apps 中可能存在的 deploy 目录，再注入正确的 nginx 配置
sh '''
    source scripts/lib/log.sh
    # 确保构建上下文中只有我们注入的 nginx 配置
    rm -rf "$WORKSPACE/noda-apps/deploy"
    mkdir -p "$WORKSPACE/noda-apps/deploy/nginx"
    cp "$WORKSPACE/deploy/nginx/nginx.conf" "$WORKSPACE/noda-apps/deploy/nginx/nginx.conf"
    cp "$WORKSPACE/deploy/nginx/default.conf" "$WORKSPACE/noda-apps/deploy/nginx/default.conf"
    source scripts/pipeline-stages.sh
    pipeline_build "$WORKSPACE/noda-apps" "$GIT_SHA"
    # 清理构建上下文中的临时文件
    rm -rf "$WORKSPACE/noda-apps/deploy"
'''
```

## Warnings

### WR-01: 蓝绿部署路径中健康检查时序与 compose 定义不一致

**File:** `docker/docker-compose.app.yml:100-104` (compose 定义) vs `scripts/manage-containers.sh:233-236` (run_container 硬编码)
**Issue:** docker-compose.app.yml 中 noda-site 的健康检查配置为 `interval=10s, timeout=3s, retries=3, start_period=3s`，这符合 nginx 轻量容器快速启动的特性。但 `manage-containers.sh` 的 `run_container` 函数硬编码了 `--health-interval 30s --health-timeout 10s --health-retries 3 --health-start-period 60s`。Jenkinsfile 通过蓝绿路径部署时，noda-site 容器将使用 60 秒 start_period 和 30 秒间隔，导致健康检查阶段白白等待 60 秒以上。虽然不会导致功能错误，但显著拖慢部署速度。

**Fix:** 在 `scripts/manage-containers.sh` 的 `run_container` 函数中，将健康检查时序参数化为环境变量：
```bash
local health_interval="${CONTAINER_HEALTH_INTERVAL:-30s}"
local health_timeout="${CONTAINER_HEALTH_TIMEOUT:-10s}"
local health_retries="${CONTAINER_HEALTH_RETRIES:-3}"
local health_start_period="${CONTAINER_HEALTH_START_PERIOD:-60s}"
# ...
    --health-interval "$health_interval" \
    --health-timeout "$health_timeout" \
    --health-retries "$health_retries" \
    --health-start-period "$health_start_period" \
```
然后在 Jenkinsfile 中添加对应的环境变量覆盖：
```groovy
CONTAINER_HEALTH_INTERVAL = "10s"
CONTAINER_HEALTH_TIMEOUT = "3s"
CONTAINER_HEALTH_START_PERIOD = "3s"
```

### WR-02: 蓝绿部署路径中 CPU 限制与 compose 定义不一致

**File:** `docker/docker-compose.app.yml:108` vs `scripts/manage-containers.sh:222`
**Issue:** docker-compose.app.yml 中 noda-site 的 CPU 限制为 `0.25` 核（`cpus: '0.25'`），但 `manage-containers.sh` 的 `run_container` 函数硬编码了 `--cpus 1`。蓝绿部署时 noda-site 容器将获得 4 倍于设计值的 CPU 配额。对于静态站点这不是功能问题，但与设计意图不符，可能在资源竞争时影响其他服务。

**Fix:** 在 `run_container` 函数中将 CPU 参数化：
```bash
local container_cpus="${CONTAINER_CPUS:-1}"
# ...
    --cpus "$container_cpus" \
```
Jenkinsfile 中添加：
```groovy
CONTAINER_CPUS = "0.25"
```

### WR-03: 蓝绿部署路径中 `/app/scripts/logs` tmpfs 挂载不适用于 nginx 容器

**File:** `scripts/manage-containers.sh:219`
**Issue:** `run_container` 硬编码了 `--tmpfs /app/scripts/logs`，这是 Node.js (findclass-ssr) 应用的日志路径。noda-site 使用 nginx 运行时，该路径无意义。虽然 tmpfs 挂载到不存在的目录不会出错，但会产生无用的内存开销，且语义上不清晰。

**Fix:** 将 tmpfs 路径列表参数化为环境变量，或根据 `SERVICE_NAME` 条件化：
```bash
local container_tmpfs="${CONTAINER_TMPFS:-/tmp /app/scripts/logs}"
# 在 docker run 中动态展开
for t in $container_tmpfs; do
    args="$args --tmpfs $t"
done
```

## Info

### IN-01: nginx.conf 未设置 worker_processes

**File:** `deploy/nginx/nginx.conf:1`
**Issue:** nginx.conf 未显式设置 `worker_processes`，将使用默认值 1。对于纯静态站点这是合理的，但如果希望充分利用多核 CPU，可以设为 `auto`。

**Fix:** 无需修改。单 worker 对 noda-site 的低流量场景足够。

### IN-02: default.conf 缺少安全相关的 HTTP 响应头

**File:** `deploy/nginx/default.conf`
**Issue:** 服务器块没有设置 `X-Content-Type-Options: nosniff`、`X-Frame-Options: DENY` 等安全头。虽然外部请求经过基础设施 nginx 反向代理（可能已添加这些头），但容器自身的直接端口访问不包含安全头。

**Fix:** 考虑在 server 块中添加常用安全头：
```nginx
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
```

### IN-03: Dockerfile 未使用 COPY --chown 优化

**File:** `deploy/Dockerfile.noda-site:50-51`
**Issue:** 注释中提到"Phase 48 可优化为 COPY --chown"，当前使用单独的 `RUN chown -R` 命令。这会在镜像中产生额外层。

**Fix:** 使用 `COPY --chown=nginx:nginx` 减少镜像层数：
```dockerfile
COPY --from=builder --chown=nginx:nginx /app/apps/site/dist /usr/share/nginx/html
RUN chown -R nginx:nginx /var/cache/nginx
```

---

_Reviewed: 2026-04-20T12:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
