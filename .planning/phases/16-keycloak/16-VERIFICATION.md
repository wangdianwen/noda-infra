---
phase: 16-keycloak
verified: 2026-04-12T08:58:00+12:00
status: human_needed
score: 3/5 must-haves verified
overrides_applied: 0
human_verification:
  - test: "浏览器访问 https://auth.noda.co.nz"
    expected: "正常显示 Keycloak 登录页"
    why_human: "浏览器渲染和外部网络请求无法通过代码扫描验证"
  - test: "Google OAuth 完整登录流程（class.noda.co.nz -> 登录 -> Google 认证 -> 返回）"
    expected: "登录成功并返回应用首页"
    why_human: "OAuth 回调流程涉及浏览器重定向和外部 IdP 交互"
  - test: "Keycloak Admin Console > noda realm > Clients > noda-frontend > Valid Redirect URIs 包含 http://localhost:3001/auth/callback"
    expected: "localhost redirect URI 已添加"
    why_human: "Keycloak 运行时配置存储在数据库中，无法通过代码仓库验证"
  - test: "部署后 docker inspect noda-infra-keycloak-prod --format='{{.State.Health.Status}}' 输出 healthy"
    expected: "healthy"
    why_human: "需要部署后等待 90 秒检查容器运行时健康状态"
---

# Phase 16: Keycloak 端口收敛 Verification Report

**Phase Goal:** auth.noda.co.nz 流量统一经过 nginx 反向代理到 Keycloak，Docker 不再直接暴露 Keycloak 端口
**Verified:** 2026-04-12T08:58:00+12:00
**Status:** human_needed
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | auth.noda.co.nz 流量经过 nginx 反向代理到达 Keycloak | VERIFIED | Cloudflare config.yml 行 22-23 指向 `noda-nginx:80`; nginx default.conf 行 4 定义 `upstream keycloak_backend` 指向 `keycloak:8080`; nginx 行 40 `proxy_pass http://keycloak_backend` 完成代理 |
| 2 | Docker Compose 不再暴露 Keycloak 8080 和 9000 端口到宿主机 | VERIFIED | docker-compose.yml keycloak 服务（行 140-174）无 `ports:` 段; grep 确认无 `8080:8080` 和 `9000:9000` 映射; git diff 确认 `-3` 行删除了 ports 段 |
| 3 | Keycloak 健康检查在容器内部正常运行（不依赖宿主机端口映射） | VERIFIED | docker-compose.prod.yml 行 103-108 使用 `echo > /dev/tcp/localhost/8080`; docker-compose.dev.yml 行 73-74 同步为 `localhost:8080`; 健康检查在容器内部执行，不依赖宿主机端口映射 |
| 4 | 浏览器访问 auth.noda.co.nz 正常显示 Keycloak 登录页 | HUMAN NEEDED | 需要部署后在浏览器中实际访问验证，无法通过代码扫描确认 |
| 5 | 开发环境可通过 auth.noda.co.nz 完成认证（localhost redirect URI 已配置） | HUMAN NEEDED | findclass-ssr 的 KEYCLOAK_URL 已正确配置为 `https://auth.noda.co.nz`（行 117），但 Keycloak Admin Console 中 localhost redirect URI 的添加需要人工操作确认 |

**Score:** 3/5 truths verified (2 require human verification)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `config/cloudflare/config.yml` | auth.noda.co.nz 指向 noda-nginx:80 | VERIFIED | 行 22-23: `hostname: auth.noda.co.nz` / `service: http://noda-nginx:80` |
| `docker/docker-compose.yml` | Keycloak 基础配置，无 ports 暴露 | VERIFIED | keycloak 服务（行 140-174）从 labels 直接跳到 environment，无 ports 段 |
| `docker/docker-compose.prod.yml` | 生产健康检查使用容器内部端口 | VERIFIED | 行 104: `echo > /dev/tcp/localhost/8080` TCP 检查 |
| `docker/docker-compose.dev.yml` | dev overlay 健康检查同步 | VERIFIED | 行 74: `echo > /dev/tcp/localhost/8080` TCP 检查 |
| `config/nginx/conf.d/default.conf` | nginx keycloak 反向代理 | VERIFIED (pre-existing) | 行 4-6 upstream + 行 36-42 proxy_pass，Phase 16 无需修改 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `config/cloudflare/config.yml` | `noda-nginx:80` | Cloudflare Tunnel ingress service 目标 | WIRED | 行 23: `service: http://noda-nginx:80` |
| `noda-nginx:80` | `keycloak:8080` | nginx upstream keycloak_backend proxy_pass | WIRED | default.conf 行 5: `server keycloak:8080` + 行 40: `proxy_pass http://keycloak_backend` |
| `docker/docker-compose.prod.yml` | keycloak container localhost:8080 | Docker healthcheck CMD-SHELL | WIRED | 行 104: `echo > /dev/tcp/localhost/8080` |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|--------------|--------|--------------------|--------|
| config/cloudflare/config.yml | ingress[].service | 静态配置 | N/A (配置文件) | N/A |
| docker-compose.yml | keycloak service definition | 静态配置 | N/A (配置文件) | N/A |
| docker-compose.prod.yml | keycloak healthcheck | 静态配置 | N/A (配置文件) | N/A |

备注：本 Phase 为基础设施配置变更，不涉及动态数据流。所有 artifacts 均为静态配置文件，Level 4 不适用。

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Docker Compose 配置语法正确 | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml config --quiet` | EXIT_CODE=0（仅有 env var 未设置警告） | PASS |
| Commit 84a741f 存在且包含 4 文件变更 | `git show 84a741f --stat` | 4 files changed, +5/-8 | PASS |
| Cloudflare 路由 auth.noda.co.nz 指向 nginx | `grep -A1 auth.noda.co.nz config/cloudflare/config.yml` | `service: http://noda-nginx:80` | PASS |
| Keycloak 无端口映射 | `grep -E '8080:8080|9000:9000' docker/docker-compose.yml` | 无输出 | PASS |
| Prod 健康检查使用 8080 | `grep localhost:8080 docker/docker-compose.prod.yml` | 匹配 healthcheck CMD-SHELL | PASS |
| Dev overlay 健康检查使用 8080 | `grep localhost:8080 docker/docker-compose.dev.yml` | 匹配 healthcheck CMD-SHELL | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| KC-01 | 16-01 | auth.noda.co.nz 由 nginx 统一反向代理到 Keycloak | SATISFIED | config.yml 指向 noda-nginx:80; nginx upstream keycloak:8080 proxy_pass 已配置 |
| KC-02 | 16-01 | Docker Compose 移除 Keycloak 8080/9000 端口直接暴露 | SATISFIED | docker-compose.yml keycloak 服务无 ports 段; git diff 确认删除 |
| KC-03 | 16-01 | dev 应用复用线上 Keycloak（localhost redirect URI 配置） | NEEDS HUMAN | findclass-ssr KEYCLOAK_URL 配置正确; 但 localhost redirect URI 需在 Keycloak Admin Console 人工添加并验证 |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (无) | - | - | - | 本 Phase 4 个文件均为静态配置，无 TODO/FIXME/placeholder，无空实现 |

### Human Verification Required

### 1. Keycloak 登录页可达性

**Test:** 部署后在浏览器访问 `https://auth.noda.co.nz`
**Expected:** 正常显示 Keycloak 登录页面
**Why human:** 浏览器渲染和外部网络链路（Cloudflare CDN -> Tunnel -> nginx -> keycloak）无法通过代码扫描验证

### 2. Google OAuth 完整登录流程

**Test:** 在 `https://class.noda.co.nz` 点击登录 -> 选择 Google -> 完成 OAuth 认证
**Expected:** 成功登录并返回应用首页
**Why human:** OAuth 回调流程涉及浏览器重定向链、cookie 跨域、外部 IdP 交互，无法自动化验证

### 3. localhost Redirect URI 配置

**Test:** Keycloak Admin Console > noda realm > Clients > noda-frontend > Valid Redirect URIs 中添加 `http://localhost:3001/auth/callback`
**Expected:** localhost redirect URI 存在于配置中
**Why human:** Keycloak 运行时配置存储在数据库中，非代码仓库管理。需要在 Admin Console 中人工操作添加

### 4. 容器健康状态

**Test:** 部署后等待 90 秒，执行 `docker inspect noda-infra-keycloak-prod --format='{{.State.Health.Status}}'`
**Expected:** 输出 `healthy`
**Why human:** 需要在部署目标服务器上运行容器后检查运行时状态

### 5. 端口不暴露确认

**Test:** 部署后执行 `docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep keycloak-prod`
**Expected:** 无端口映射输出（PORTS 列为空）
**Why human:** 需要在部署后检查运行时容器状态

### Gaps Summary

本 Phase 的自动化配置变更（4 个文件、+5/-8 行）已全部正确实施：

1. **Cloudflare 路由收敛** -- auth.noda.co.nz 从直连 keycloak:8080 改为经过 noda-nginx:80，与 class.noda.co.nz 和 localhost.noda.co.nz 保持一致
2. **端口暴露移除** -- docker-compose.yml 中 keycloak 的 ports 段完全删除（8080 + 9000），Keycloak 仅通过 Docker 内部网络可达
3. **健康检查统一** -- prod 和 dev overlay 中 keycloak 健康检查从 9000 管理端口改为 8080 HTTP 端口 TCP 检查
4. **Docker Compose 语法** -- `config` 验证通过（退出码 0）
5. **Nginx 配置** -- 已有完整的 auth.noda.co.nz server block，无需修改

剩余 2 项需要人工验证：浏览器访问验证和 Keycloak Admin Console 的 localhost redirect URI 配置。这些是部署后的运行时验证项。

---

_Verified: 2026-04-12T08:58:00+12:00_
_Verifier: Claude (gsd-verifier)_
