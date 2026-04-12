# Phase 16: Keycloak 端口收敛 - Research

**Researched:** 2026-04-12
**Domain:** Docker Compose 网络配置 + Cloudflare Tunnel 路由 + Nginx 反向代理
**Confidence:** HIGH

## Summary

Phase 16 将 auth.noda.co.nz 的流量路径从 Cloudflare Tunnel 直连 Keycloak 改为经过 nginx 反向代理，并移除 Docker Compose 中 Keycloak 的 8080/9000 端口暴露。这是一个改动极小但影响范围明确的配置变更。

核心发现：nginx 已经有完整的 auth.noda.co.nz server block 配置（包括 upstream keycloak_backend、WebSocket 支持、安全头），Cloudflare Tunnel 配置只需修改一行（将 `http://keycloak:8080` 改为 `http://noda-nginx:80`）。Docker Compose 中 Keycloak 的 `ports` 段可以安全移除，因为所有访问者（nginx、Cloudflare Tunnel、healthcheck）都在 Docker 内部网络中通信。

关于健康检查：当前 prod overlay 使用 `echo > /dev/tcp/localhost/9000` 进行 TCP 端口检查，这在容器内部执行，不依赖宿主机端口映射。移除 `ports` 暴露后健康检查不受影响。

**Primary recommendation:** 变更涉及 3 个文件共约 5 行修改：Cloudflare Tunnel config.yml 改路由目标、docker-compose.yml 移除 keycloak ports 段、docker-compose.dev.yml 移除 prod keycloak 的 healthcheck 覆盖（保持与 prod overlay 一致）。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 将 Cloudflare Tunnel 配置中 `auth.noda.co.nz` 的目标从 `http://keycloak:8080` 改为 `http://noda-nginx:80`
- **D-02:** Nginx 已配置 upstream `keycloak_backend` 指向 `keycloak:8080`，包含 WebSocket 支持和安全头 — 无需修改 nginx 配置
- **D-03:** 从 docker-compose.yml 的 keycloak 服务中移除所有 `ports` 暴露（包括 `127.0.0.1:8080:8080` 和 `9000:9000`）
- **D-04:** Keycloak 保持 Docker 内部网络通信（noda-network），nginx 通过容器名 `keycloak:8080` 访问
- **D-05:** KC_PROXY 保持 `edge` 配置（nginx 层终止 TLS/代理，Cloudflare 已处理 HTTPS）
- **D-06:** dev 应用（findclass-ssr dev）使用 auth.noda.co.nz 进行认证，复用线上 Keycloak 实例
- **D-07:** 在 Keycloak 的 noda-frontend client 中添加 localhost redirect URI（如 `http://localhost:3001/auth/callback`）
- **D-08:** docker-compose.dev.yml 中 findclass-ssr 的 KEYCLOAK_URL 保持 `https://auth.noda.co.nz`（通过 Cloudflare 访问线上 Keycloak）
- **D-09:** 使用 Docker healthcheck 通过容器内部 localhost 连接检查 Keycloak 状态（`curl -f http://localhost:8080/health/ready`），不暴露端口到宿主机
- **D-10:** 如果 docker-compose.prod.yml 中有 9000 端口的健康检查配置，改为内部 8080 端口检查

### Claude's Discretion
- nginx proxy 配置细节调整（如需要增加 buffer size、timeout 等参数）
- Keycloak healthcheck 具体的 curl 命令和间隔参数
- 是否需要调整 findclass-ssr 的 KEYCLOAK_INTERNAL_URL

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| KC-01 | auth.noda.co.nz 由 nginx 统一反向代理到 Keycloak（Cloudflare 路由更新） | Cloudflare Tunnel config.yml 单行变更；nginx 已有完整 server block，无需修改 |
| KC-02 | Docker Compose 移除 Keycloak 8080/9000 端口直接暴露 | docker-compose.yml 移除 keycloak service 的 `ports` 段；健康检查在容器内部执行，不受影响 |
| KC-03 | dev 应用复用线上 Keycloak（Google OAuth 配置 localhost redirect URI） | 需在 Keycloak admin console 手动添加 redirect URI；docker-compose.dev.yml 的 findclass-ssr 环境变量已正确配置 |
</phase_requirements>

## Standard Stack

### Core（本 Phase 无新增依赖）

本 Phase 是纯配置变更，不引入新库或工具。所有组件已在项目中就绪。

| 组件 | 当前版本 | 角色 | 备注 |
|------|----------|------|------|
| Keycloak | 26.2.3 | 认证服务 | `quay.io/keycloak/keycloak:26.2.3` [VERIFIED: docker-compose.yml] |
| Nginx | 1.25-alpine | 反向代理 | 已配置 auth.noda.co.nz server block [VERIFIED: config/nginx/conf.d/default.conf] |
| Cloudflare Tunnel | noda-ops 容器内 | 外部流量入口 | config/cloudflare/config.yml 定义路由规则 [VERIFIED: config file] |
| Docker Compose | v2 | 服务编排 | 三层 overlay 模式 [VERIFIED: docker-compose*.yml] |

## Architecture Patterns

### 当前架构（变更前）

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops 容器)
  ├── class.noda.co.nz → noda-nginx:80 → findclass-ssr:3001
  └── auth.noda.co.nz  → keycloak:8080 (直连，绕过 nginx)
```

Keycloak 通过 Docker `ports` 暴露 8080（仅 localhost）和 9000 到宿主机。

### 目标架构（变更后）

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops 容器)
  ├── class.noda.co.nz → noda-nginx:80 → findclass-ssr:3001
  └── auth.noda.co.nz  → noda-nginx:80 → keycloak:8080 (经 nginx 代理)
```

所有外部流量统一经过 nginx 入口。Keycloak 不再暴露端口到宿主机。

### 健康检查架构

**关键洞察：** Docker healthcheck 在容器内部的网络命名空间执行，不依赖 `ports` 映射。

| 环境 | 健康检查方式 | 端口 | 文件 |
|------|-------------|------|------|
| prod | `echo > /dev/tcp/localhost/9000` | 9000（管理端口） | docker-compose.prod.yml |
| dev（prod keycloak） | `echo > /dev/tcp/localhost/9000` | 9000（管理端口） | docker-compose.dev.yml |
| dev（keycloak-dev） | `echo > /dev/tcp/localhost/8080` | 8080（start-dev 模式无管理端口） | docker-compose.dev.yml |

**关于 D-09/D-10 决策的注意事项：**
- D-09 建议使用 `curl -f http://localhost:8080/health/ready`
- D-10 建议将 9000 端口检查改为 8080 端口检查
- 但 Keycloak 官方文档说明：当 `KC_HEALTH_ENABLED=true` 时，健康检查端点默认在**管理端口 9000** 上提供 [CITED: keycloak.org/server/management-interface]
- 当前 TCP 检查 `echo > /dev/tcp/localhost/9000` 不需要 curl，且已稳定运行
- **推荐方案：** 保持当前 prod overlay 的 TCP 9000 健康检查不变（简单可靠，无需安装 curl），作为 Claude's Discretion 范围内的优化建议

### Docker Compose Overlay 模式

```
docker-compose.yml      → 基础配置（所有服务定义）
  ├─ docker-compose.prod.yml → 生产覆盖（安全加固 + 资源限制 + 健康检查）
  └─ docker-compose.dev.yml  → 开发覆盖（独立 dev 实例 + 端口暴露）
```

三层文件按顺序合并，后者的值覆盖前者。

## Don't Hand-Roll

| 问题 | 不要自己实现 | 使用现有方案 | 原因 |
|------|-------------|-------------|------|
| nginx 代理配置 | 写新的 proxy_pass 和 header | 已有 auth.noda.co.nz server block | default.conf 行 22-50 已完整配置 |
| WebSocket 支持 | 手动添加 Upgrade/Connection 头 | proxy-websocket.conf snippet | 已包含所有 WebSocket 和代理头 |
| Keycloak 代理模式 | 调整 proxy 配置 | 保持 KC_PROXY=edge | 已验证正常工作，Cloudflare 终止 TLS |
| 健康检查 | 实现 HTTP 健康检查 | 保持 TCP 端口检查 | 容器内无需 curl，TCP 检查足够 |

## Common Pitfalls

### Pitfall 1: 误认为 healthcheck 依赖 ports 映射
**What goes wrong:** 认为 Docker healthcheck 需要端口暴露到宿主机才能工作
**Why it happens:** 混淆了容器间通信与宿主机端口映射的概念
**How to avoid:** healthcheck 命令在容器内部网络命名空间执行，直接访问 localhost:9000 或 localhost:8080，不经过 Docker 的端口映射层
**Warning signs:** 尝试在移除 ports 后重新添加不必要的端口暴露

### Pitfall 2: Cloudflare Tunnel 容器名解析
**What goes wrong:** 使用错误的目标主机名（如 `nginx:80` 而非 `noda-nginx:80`）
**Why it happens:** Docker Compose 服务名 vs container_name 的混淆
**How to avoid:** Tunnel 在 noda-ops 容器内运行，通过 Docker 网络解析。nginx 服务的 `container_name: noda-infra-nginx` 但在 noda-network 上也可通过服务名 `nginx` 或 compose 文件中定义的其他名称访问。**验证 config.yml 中其他路由已使用 `noda-nginx:80` 作为目标，保持一致。**

### Pitfall 3: dev 环境 prod keycloak 配置冲突
**What goes wrong:** docker-compose.dev.yml 覆盖了 prod keycloak 的 hostname/proxy 配置，导致 dev 环境中 prod keycloak 行为异常
**Why it happens:** dev overlay 设置 `KC_HOSTNAME: ""` 和 `KC_PROXY: none` 来允许 localhost 访问，但这些覆盖可能影响通过 auth.noda.co.nz 访问的场景
**How to avoid:** dev 环境中的 prod keycloak 覆盖是**现有的**配置，本 Phase 不修改它。KC-03 要求 dev 应用通过 Cloudflare（`https://auth.noda.co.nz`）访问线上 Keycloak，不走本地 keycloak-dev
**Warning signs:** dev 环境登录失败时检查 prod keycloak 的 KC_HOSTNAME 和 KC_PROXY 设置

### Pitfall 4: 移除管理端口后无法访问 admin console
**What goes wrong:** 移除 9000 端口暴露后，无法从宿主机直接访问 Keycloak Admin Console
**Why it happens:** Admin Console 在 8080 端口的 `/admin` 路径，但管理 REST API 在 9000 端口
**How to avoid:** Admin Console 通过 `https://auth.noda.co.nz/admin` 经 nginx 访问（走 8080 端口），管理 REST API 的 9000 端口仅在需要直接 API 调用时使用，可通过 `docker exec` 访问
**Warning signs:** 部署后通过浏览器验证 `https://auth.noda.co.nz/admin` 可正常打开

### Pitfall 5: 部署顺序导致短暂不可用
**What goes wrong:** 先移除端口再改路由，或反过来，导致中间状态不可用
**Why it happens:** Cloudflare Tunnel config.yml 变更需要重启 noda-ops 容器才生效，而 docker-compose.yml 变更需要重启 keycloak 容器
**How to avoid:** 使用部署脚本 `bash scripts/deploy/deploy-infrastructure-prod.sh` 一次性全量重启所有容器，避免中间状态
**Warning signs:** 分步手动重启导致服务中断

## Code Examples

### 变更 1: Cloudflare Tunnel 路由（config/cloudflare/config.yml）

```yaml
# 变更前（行 22-23）
  - hostname: auth.noda.co.nz
    service: http://keycloak:8080

# 变更后
  - hostname: auth.noda.co.nz
    service: http://noda-nginx:80
```

与 class.noda.co.nz 路由保持一致（`service: http://noda-nginx:80`）。

### 变更 2: Docker Compose 移除 Keycloak 端口（docker/docker-compose.yml）

```yaml
# 变更前（行 145-147）
    ports:
      - "127.0.0.1:8080:8080"  # HTTP 端口（仅本机）
      - "9000:9000"  # 管理端口（健康检查）

# 变更后：完全移除 ports 段（keycloak service 不再有 ports 键）
```

### 变更 3: Nginx 配置 — 无需修改

已有完整配置（config/nginx/conf.d/default.conf 行 22-50）：

```nginx
upstream keycloak_backend {
    server keycloak:8080 max_fails=3 fail_timeout=30s;
}
server {
    listen 80;
    server_name auth.noda.co.nz;
    client_max_body_size 100M;
    # Security headers...
    location / {
        proxy_next_upstream error timeout http_502 http_503;
        proxy_next_upstream_timeout 5s;
        proxy_next_upstream_tries 2;
        proxy_pass http://keycloak_backend;
        include /etc/nginx/snippets/proxy-websocket.conf;
    }
}
```

### 已有 Nginx 代理头（proxy-websocket.conf）

```nginx
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $forwarded_proto;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection 'upgrade';
proxy_cache_bypass $http_upgrade;
```

这些头已满足 Keycloak `KC_PROXY=edge` + `KC_PROXY_HEADERS=xforwarded` 的要求。

### KC-03: Keycloak Redirect URI 配置

需在 Keycloak Admin Console 手动操作（非代码变更）：
1. 访问 `https://auth.noda.co.nz/admin`
2. 进入 noda realm > Clients > noda-frontend
3. 在 Valid Redirect URIs 中添加 `http://localhost:3001/auth/callback`
4. 在 Web Origins 中确认 `http://localhost:3001` 已存在或添加

## State of the Art

| 旧方式 | 当前方式 | 变更时间 | 影响 |
|--------|----------|----------|------|
| Cloudflare 直连 Keycloak | Cloudflare → nginx → Keycloak | 本 Phase | 统一入口，简化网络拓扑 |
| Keycloak 暴露端口到宿主机 | Keycloak 仅 Docker 内部网络 | 本 Phase | 减少攻击面，SEC-02 同步完成 |
| Keycloak v1 hostname SPI | v2 hostname SPI（KC_HOSTNAME 全 URL） | v1.1 | 已完成，本 Phase 无需改动 |
| Keycloak legacy observability | 管理端口 9000 独立 | Keycloak 26+ | 健康检查在 9000，非 8080 |

**非废弃但需注意：**
- `KC_PROXY=edge` 是当前推荐的代理模式，本 Phase 不变更 [CITED: CLAUDE.md 修复记录]
- `KC_PROXY_HEADERS=xforwarded` 与 nginx 的 `proxy-websocket.conf` 配合正常 [VERIFIED: 代码库]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Keycloak Admin Console 通过 8080 端口的 `/admin` 路径访问，移除 9000 端口暴露不影响浏览器访问 Admin Console | Common Pitfalls | Admin Console 不可达，需改回端口暴露或通过 docker exec 访问 |
| A2 | dev overlay 中 prod keycloak 的 `KC_HOSTNAME: ""` 和 `KC_PROXY: none` 不影响通过 auth.noda.co.nz 的认证流程（因为 dev findclass-ssr 通过 Cloudflare 访问线上 Keycloak，不访问本地 prod keycloak） | Common Pitfalls | dev 环境认证异常 |
| A3 | Cloudflare Tunnel 在 noda-ops 容器内运行时能解析 `noda-nginx` 作为容器名（其他路由已使用此名称，证明可行） | Code Examples | Tunnel 无法连接 nginx，需调试 DNS 解析 |

**Note:** A3 的风险实际很低 — config.yml 中 `noda.co.nz` 和 `localhost.noda.co.nz` 路由已使用 `http://noda-nginx:80` 作为目标 [VERIFIED: config/cloudflare/config.yml 行 20, 26]，证明 Tunnel 可以解析此名称。

## Open Questions

1. **健康检查方式选择**
   - What we know: D-09/D-10 建议改用 `curl -f http://localhost:8080/health/ready`，但当前 TCP 检查在 9000 端口工作正常且无需额外工具
   - What's unclear: Keycloak 容器是否预装 curl（Alpine 基础镜像可能不包含）
   - Recommendation: 保持现有 TCP 检查 `echo > /dev/tcp/localhost/9000`，作为 Claude's Discretion 的决策。TCP 检查验证端口可达性，足以判断服务是否就绪

2. **dev overlay 中 prod keycloak 的 healthcheck 覆盖**
   - What we know: docker-compose.dev.yml 行 73-78 为 prod keycloak 定义了 TCP 9000 健康检查，与 prod overlay 一致
   - What's unclear: 移除基础配置的 ports 后，dev overlay 的 healthcheck override 是否需要同步调整
   - Recommendation: 不需要调整。dev overlay 的 healthcheck 与 prod overlay 使用相同的 TCP 检查，两者都访问容器内部 localhost，不依赖端口映射

## Environment Availability

> 本 Phase 依赖的组件均为已有服务，无新外部依赖。

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker Compose | 服务编排 | 部署目标服务器 | v2 | -- |
| Cloudflare Tunnel | 外部流量路由 | noda-ops 容器内 | 当前 | -- |
| nginx | 反向代理 | noda-infra-nginx 容器 | 1.25-alpine | -- |
| Keycloak | 认证服务 | noda-infra-keycloak-prod 容器 | 26.2.3 | -- |
| noda-network | Docker 内部通信 | external network | -- | -- |

**Missing dependencies with no fallback:** None

**Missing dependencies with fallback:** None

**Note:** 本 Phase 在部署目标服务器上执行，所有组件已在运行。变更通过 `bash scripts/deploy/deploy-infrastructure-prod.sh` 部署。

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | 手动验证（配置变更，无自动化测试框架） |
| Config file | none |
| Quick run command | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml config` |
| Full suite command | `bash scripts/deploy/deploy-infrastructure-prod.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | Manual Verification |
|--------|----------|-----------|-------------------|---------------------|
| KC-01 | auth.noda.co.nz 流量经 nginx 代理 | manual-only | -- | 浏览器访问 `https://auth.noda.co.nz` 确认正常显示登录页 |
| KC-01 | Cloudflare Tunnel 路由指向 nginx | manual-only | -- | 检查 config.yml 中 auth.noda.co.nz 目标为 `noda-nginx:80` |
| KC-02 | Keycloak 无端口暴露 | smoke | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml config \| grep -A5 'keycloak' \| grep 'ports'` 应无输出 | `docker ps` 确认 keycloak 无端口映射 |
| KC-02 | 健康检查正常 | smoke | `docker inspect noda-infra-keycloak-prod --format='{{.State.Health.Status}}'` | 等待 60s 后检查健康状态 |
| KC-03 | Google OAuth 登录可用 | manual-only | -- | 完整登录流程测试 |
| KC-03 | Admin Console 可访问 | manual-only | -- | 浏览器访问 `https://auth.noda.co.nz/admin` |

### Sampling Rate
- **Per task commit:** `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml config` 验证配置语法
- **Per wave merge:** `bash scripts/deploy/deploy-infrastructure-prod.sh` 全量部署验证
- **Phase gate:** 部署后手动验证所有 KC-* 要求

### Wave 0 Gaps
- 无需测试框架 — 本 Phase 是纯配置变更，验证通过部署脚本 + 手动测试完成

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Keycloak OIDC + Google OAuth |
| V3 Session Management | yes | Keycloak session 管理，KC_PROXY=edge 确保 Secure cookie |
| V4 Access Control | yes | Keycloak RBAC |
| V5 Input Validation | yes | Nginx 反向代理过滤 |
| V6 Cryptography | yes | Cloudflare TLS 终止，内部 HTTP |

### Security Impact of This Phase

**正面影响（安全加固）：**
- Keycloak 不再暴露端口到宿主机，减少攻击面（SEC-02 同步完成）
- 所有外部流量统一经过 nginx，可集中管理和审计
- nginx 提供额外的安全头（X-Content-Type-Options, X-Frame-Options 等）

**无负面影响：**
- KC_PROXY=edge 模式不变，cookie Secure 标记行为不变
- WebSocket 支持不变
- 健康检查仍在容器内部执行，不引入新的外部可访问端点

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 端口扫描 | Information Disclosure | 移除宿主机端口暴露，仅 Docker 内部通信 |
| 中间人攻击 | Tampering | Cloudflare TLS + nginx 内部通信 |
| Admin Console 暴露 | Information Disclosure | Admin Console 通过 auth.noda.co.nz 访问，受 Keycloak 认证保护 |

## Project Constraints (from CLAUDE.md)

### 部署规则（强制）
- **禁止直接使用 `docker compose up/down/restart`** — 所有部署必须通过 `bash scripts/deploy/deploy-infrastructure-prod.sh`
- 允许的只读命令：`docker compose ps`, `logs`, `config`, `images`

### 项目名一致性
- `docker-compose.yml` 和 `docker-compose.prod.yml` 项目名必须一致（当前为 `noda-infra`）

### Keycloak 配置要点
- `KC_HOSTNAME: "https://auth.noda.co.nz"` — 完整 URL，端口从 scheme 推导
- `KC_PROXY: "edge"` — 必须保留
- `KC_PROXY_HEADERS: "xforwarded"` — 必须保留
- 不要使用 `KC_HOSTNAME_PORT`、`KC_HOSTNAME_STRICT_HTTPS`（v1 废弃选项）

## Sources

### Primary (HIGH confidence)
- config/cloudflare/config.yml — 当前 Tunnel 路由配置 [VERIFIED: 文件内容]
- config/nginx/conf.d/default.conf — nginx auth.noda.co.nz server block [VERIFIED: 文件内容]
- docker/docker-compose.yml — Keycloak 基础配置 + ports 暴露 [VERIFIED: 文件内容]
- docker/docker-compose.prod.yml — 生产健康检查 + 安全加固 [VERIFIED: 文件内容]
- docker/docker-compose.dev.yml — 开发环境覆盖 [VERIFIED: 文件内容]
- config/nginx/snippets/proxy-websocket.conf — 代理头配置 [VERIFIED: 文件内容]
- scripts/deploy/deploy-infrastructure-prod.sh — 部署脚本 [VERIFIED: 文件内容]
- CLAUDE.md — 项目部署规则和 Keycloak 配置要点 [VERIFIED: 文件内容]

### Secondary (MEDIUM confidence)
- Keycloak 26.x 管理接口文档 — 健康检查端点在管理端口 9000 [CITED: keycloak.org/server/management-interface]

### Tertiary (LOW confidence)
- Keycloak Admin Console 通过 8080 端口 `/admin` 路径可达 [ASSUMED — 基于已知 Keycloak 架构，未在本项目中独立验证]

## Metadata

**Confidence breakdown:**
- Standard Stack: HIGH — 所有组件版本从代码库文件直接验证
- Architecture: HIGH — 流量路径和 overlay 模式从配置文件和已有运行记录确认
- Pitfalls: HIGH — 基于项目中已发生过的问题（CLAUDE.md 修复记录）和 Docker/Keycloak 官方文档
- Security: HIGH — 变更减少攻击面，无安全回退

**Research date:** 2026-04-12
**Valid until:** 2026-05-12（配置变更，稳定期长）
