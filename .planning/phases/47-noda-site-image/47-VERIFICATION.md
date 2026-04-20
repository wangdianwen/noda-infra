---
phase: 47-noda-site-image
verified: 2026-04-20T12:00:00Z
status: human_needed
score: 6/7 must-haves verified
overrides_applied: 0
human_verification:
  - test: "构建 noda-site 镜像并检查体积是否 < 30MB"
    expected: "docker images 显示 noda-site 镜像 < 30MB"
    why_human: "noda-apps 源码不在本地仓库，无法执行 docker build 验证镜像体积"
  - test: "docker compose up 场景下 noda-site 健康检查是否正常"
    expected: "容器状态为 healthy（注意：docker-compose.app.yml 使用 localhost:3000，可能受 IPv6 影响）"
    why_human: "docker-compose.app.yml 健康检查使用 localhost 而非 127.0.0.1，在 BusyBox wget 下可能失败；蓝绿部署不受影响（CONTAINER_HEALTH_CMD 覆盖）"
---

# Phase 47: noda-site 镜像优化 Verification Report

**Phase Goal:** 将 noda-site 运行时镜像从 ~218MB 降至 ~25MB，同时保持端口 3000 和 SPA fallback 行为完全兼容
**Verified:** 2026-04-20T12:00:00Z
**Status:** human_needed
**Re-verification:** No -- 初始验证

## Goal Achievement

### ROADMAP Success Criteria 对应

| # | ROADMAP Success Criterion | 来源 | 对应 Truth |
|---|--------------------------|------|-----------|
| 1 | Dockerfile 使用 nginx:1.25-alpine，多阶段构建保留 Puppeteer prerender 阶段 | ROADMAP | Truth 1, 4 |
| 2 | 容器在端口 3000 提供静态文件服务，蓝绿部署全流程正常 | ROADMAP | Truth 2, 6 |
| 3 | Jenkins Pipeline 部署流程适配新 Dockerfile 并成功部署 | ROADMAP | Truth 6, 7 |
| 4 | docker images 显示 noda-site 镜像体积 < 30MB | ROADMAP | Truth 8 (需构建验证) |

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | noda-site Dockerfile 使用 nginx:1.25-alpine 基础镜像作为 runner 阶段 | VERIFIED | `deploy/Dockerfile.noda-site` line 38: `FROM nginx:1.25-alpine AS runner` |
| 2 | 所有未匹配路径返回 index.html（SPA fallback），等价于 serve -s dist | VERIFIED | `deploy/nginx/default.conf` line 8: `try_files $uri $uri/ /index.html` + `listen 3000` |
| 3 | 容器以 nginx 非 root 用户运行，支持 read_only + tmpfs | VERIFIED | `deploy/Dockerfile.noda-site` line 53: `USER nginx` + `deploy/nginx/nginx.conf` 所有临时文件指向 `/tmp` |
| 4 | 多阶段构建保留 Puppeteer prerender builder 阶段不变 | VERIFIED | `deploy/Dockerfile.noda-site` lines 12-33: `FROM node:20-alpine AS builder`, chromium 安装 + prerender 构建步骤完整保留 |
| 5 | builder 阶段 pnpm install 使用 BuildKit 缓存挂载（per D-07） | VERIFIED | `deploy/Dockerfile.noda-site` line 20: `--mount=type=cache,target=/root/.local/share/pnpm/store` |
| 6 | Jenkins Pipeline 蓝绿部署全流程适配 nginx 容器（CONTAINER_HEALTH_CMD + CONTAINER_MEMORY + nginx 配置复制） | VERIFIED | `jenkins/Jenkinsfile.noda-site` lines 21-24 环境变量 + lines 77-79 nginx 配置复制 + line 83 清理 |
| 7 | docker-compose.app.yml noda-site 健康检查和资源限制适配 nginx 运行时 | VERIFIED | `docker/docker-compose.app.yml` lines 101-112: interval=10s, timeout=3s, start_period=3s, memory=32M/8M |
| 8 | noda-site 镜像体积 < 30MB | UNCERTAIN | 需要实际构建验证；nginx:1.25-alpine 基础镜像 ~25MB + 静态文件，理论上满足 |

**Score:** 7/8 truths verified (1 needs human)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `deploy/Dockerfile.noda-site` | 多阶段构建（builder + nginx runner） | VERIFIED | 62 行，runner 阶段使用 `nginx:1.25-alpine`，包含 HEALTHCHECK、USER nginx、COPY 配置 |
| `deploy/nginx/nginx.conf` | 容器内 nginx 主配置（非 root，PID/日志指向 /tmp） | VERIFIED | 22 行，`pid /tmp/nginx.pid`，无 `user` 指令，所有 temp_path 指向 `/tmp` |
| `deploy/nginx/default.conf` | server 块（SPA fallback + 端口 3000） | VERIFIED | 10 行，`listen 3000` + `try_files $uri $uri/ /index.html`，无 gzip/缓存头 |
| `docker/docker-compose.app.yml` | noda-site 健康检查和资源限制配置 | VERIFIED | `start_period: 3s`, `memory: 32M`，参数已优化适配 nginx |
| `jenkins/Jenkinsfile.noda-site` | Pipeline 参数和 Build 阶段 nginx 配置复制 | VERIFIED | `CONTAINER_HEALTH_CMD`, `CONTAINER_MEMORY=32m`, Build 阶段复制+清理 nginx 配置 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `deploy/Dockerfile.noda-site` | `deploy/nginx/nginx.conf` | `COPY deploy/nginx/nginx.conf /etc/nginx/nginx.conf` | WIRED | Dockerfile line 44 正确引用 |
| `deploy/Dockerfile.noda-site` | `deploy/nginx/default.conf` | `COPY deploy/nginx/default.conf /etc/nginx/conf.d/default.conf` | WIRED | Dockerfile line 45 正确引用 |
| `deploy/Dockerfile.noda-site` | builder stage | `COPY --from=builder /app/apps/site/dist /usr/share/nginx/html` | WIRED | Dockerfile line 48 正确引用 builder 产物 |
| `jenkins/Jenkinsfile.noda-site` | `scripts/manage-containers.sh` | `CONTAINER_HEALTH_CMD` 环境变量 | WIRED | Jenkinsfile line 21 设置 wget 命令，manage-containers.sh line 205 读取 `CONTAINER_HEALTH_CMD` |
| `jenkins/Jenkinsfile.noda-site` | `scripts/pipeline-stages.sh` | `pipeline_build()` 调用 | WIRED | Jenkinsfile line 81 调用，lines 77-79 预复制 nginx 配置到构建上下文 |
| `jenkins/Jenkinsfile.noda-site` | `docker/docker-compose.app.yml` | `CONTAINER_MEMORY` 环境变量 | WIRED | Jenkinsfile line 23-24 设置 32m/8m，manage-containers.sh line 197-198 读取 |

### Data-Flow Trace (Level 4)

本阶段不涉及动态数据渲染（Docker 配置 + nginx 静态文件），Level 4 不适用。

### Behavioral Spot-Checks

**Step 7b: SKIPPED (no runnable entry points)** -- noda-site 容器需要 noda-apps 源码构建，本地环境无法执行 `docker build`。所有验证通过静态代码分析完成。

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| SITE-01 | 47-01 | noda-site 运行时从 node:20-alpine + serve 切换到 nginx:1.25-alpine | SATISFIED | Dockerfile runner 阶段已重写，端口 3000 + 非 root + SPA fallback |
| SITE-02 | 47-01 | 多阶段构建保留 Puppeteer prerender 构建阶段 | SATISFIED | builder 阶段完整保留：node:20-alpine + chromium + prerender |
| SITE-03 | 47-02 | Jenkins Pipeline 部署流程适配新 Dockerfile | SATISFIED | CONTAINER_HEALTH_CMD + CONTAINER_MEMORY + nginx 配置复制 + 清理 |

**Orphaned Requirements:** 无 -- SITE-01, SITE-02, SITE-03 全部被 Plan 01 和 Plan 02 覆盖。

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `docker/docker-compose.app.yml` | 100 | `localhost:3000` 而非 `127.0.0.1:3000` | WARNING | docker-compose up 场景下健康检查可能因 BusyBox wget IPv6 解析失败；蓝绿部署不受影响（CONTAINER_HEALTH_CMD 覆盖为 127.0.0.1） |

**详细分析：** docker-compose.app.yml 中 noda-site 健康检查 `test` 使用 `http://localhost:3000/`。RESEARCH.md Pitfall 1 明确指出 BusyBox wget 将 localhost 解析为 IPv6 (::1)，导致连接失败。但在实际生产部署中：
- 蓝绿部署通过 `manage-containers.sh --health-cmd` 覆盖，使用 Jenkinsfile 中的 `CONTAINER_HEALTH_CMD`（127.0.0.1）
- Dockerfile 中的 HEALTHCHECK 正确使用 `127.0.0.1:3000`
- 仅在 `docker compose up` 直接启动场景中可能触发此问题

**Stub 分类检查：** 未发现空实现、placeholder、return null 等模式。所有配置文件内容完整实质性。

### Human Verification Required

### 1. 镜像体积验证

**Test:** 在服务器上执行 `docker build -t noda-site:test -f deploy/Dockerfile.noda-site ../noda-apps` 后运行 `docker images noda-site:test`
**Expected:** 镜像体积 < 30MB（目标 ~25MB）
**Why human:** noda-apps 源码在独立仓库，本地环境无法执行 docker build

### 2. docker-compose up 健康检查兼容性

**Test:** 在服务器上执行 `docker compose -f docker/docker-compose.app.yml up noda-site`，观察容器健康状态
**Expected:** 容器状态变为 `healthy`；如果因 IPv6 解析失败，建议将 docker-compose.app.yml line 100 的 `localhost` 改为 `127.0.0.1`
**Why human:** docker-compose.app.yml 健康检查使用 `localhost` 而非 `127.0.0.1`，可能触发 BusyBox wget IPv6 问题（RESEARCH Pitfall 1）；蓝绿部署不受影响

### 3. 端到端蓝绿部署验证

**Test:** 通过 Jenkins 触发 noda-site 部署 Pipeline，观察 Build -> Health Check -> Switch -> Verify 全流程
**Expected:** 所有 8 个阶段 PASS，部署成功
**Why human:** 蓝绿部署涉及容器运行时行为，需要实际服务器环境验证

### Gaps Summary

Phase 47 的代码实现质量很高，所有 5 个关键文件（Dockerfile + 2 个 nginx 配置 + docker-compose + Jenkinsfile）均通过三级验证（存在 + 实质性 + 接线）。

**潜在问题 1 个：**
- `docker/docker-compose.app.yml` noda-site 健康检查使用 `localhost:3000` 而非 `127.0.0.1:3000`。这不影响生产蓝绿部署（CONTAINER_HEALTH_CMD 覆盖），但在 `docker compose up` 场景中可能因 BusyBox wget IPv6 解析导致健康检查失败。建议将 line 100 的 `localhost` 改为 `127.0.0.1` 以保持一致性。

**需要人工验证 2 项：**
1. 镜像体积验证（需要 noda-apps 源码 + docker build）
2. 端到端蓝绿部署验证（需要服务器环境）

3 个需求（SITE-01, SITE-02, SITE-03）全部有代码级证据支持，无遗漏需求。

---

_Verified: 2026-04-20T12:00:00Z_
_Verifier: Claude (gsd-verifier)_
