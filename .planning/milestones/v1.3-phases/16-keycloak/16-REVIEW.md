---
phase: 16-keycloak
reviewed: 2026-04-12T12:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - config/cloudflare/config.yml
  - docker/docker-compose.yml
  - docker/docker-compose.prod.yml
  - docker/docker-compose.dev.yml
findings:
  critical: 1
  warning: 2
  info: 2
  total: 5
status: issues_found
---

# Phase 16: Code Review Report

**Reviewed:** 2026-04-12T12:00:00Z
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

Phase 16 将 Keycloak 的外部端口暴露（8080/9000）收敛为仅通过 nginx 反向代理访问，统一了健康检查端口从 9000 到 8080。变更范围精确，四个文件的修改逻辑一致且正确。

关键发现：

1. **CRITICAL**：Cloudflare Tunnel 使用 `--token` 模式运行（`deploy/supervisord.conf` 第 23 行），`config/cloudflare/config.yml` 仅为本地参考文件，未被容器挂载或使用。auth.noda.co.nz 的路由变更必须在 Cloudflare Zero Trust Dashboard 中同步操作，否则生产环境路由不会生效。
2. **WARNING**：CLAUDE.md 和 `docs/architecture.md` 中的架构描述仍反映旧的路由方式（auth.noda.co.nz 直接到 keycloak:8080），需要更新以保持文档与实际部署一致。

## Critical Issues

### CR-01: Cloudflare Tunnel 本地配置文件不控制实际路由

**File:** `config/cloudflare/config.yml:22-23`
**Issue:** Cloudflare Tunnel 以 `--token` 模式运行（见 `deploy/supervisord.conf` 第 23 行：`cloudflared tunnel --no-autoupdate run --token %(ENV_CLOUDFLARE_TUNNEL_TOKEN)s`），ingress 规则由 Cloudflare Dashboard 远程管理。`config/cloudflare/config.yml` 未被任何容器挂载或引用，仅作为本地参考文件。

将 `auth.noda.co.nz` 的 service 从 `http://keycloak:8080` 改为 `http://noda-nginx:80` 仅更新了本地参考文件。**必须在 Cloudflare Zero Trust Dashboard 中同步修改 auth.noda.co.nz 的 tunnel 路由目标**，否则生产环境流量仍会直接发往 keycloak:8080，而 Keycloak 的端口映射已在 `docker-compose.yml` 中移除，导致 auth.noda.co.nz 完全不可达。

注：Phase 16 的研究文档（`16-RESEARCH.md`）已识别此风险（PITFALL-01），但代码变更本身不包含对 Dashboard 操作的验证或提醒。建议在部署前确认 Dashboard 路由已更新。

**Fix:**
在 Cloudflare Zero Trust Dashboard 中，将 auth.noda.co.nz 的 tunnel public hostname 的 service 从 `http://keycloak:8080` 改为 `http://noda-nginx:80`（或等效的 nginx 服务地址）。部署前应先更新 Dashboard，再移除 docker-compose.yml 中的端口映射。

## Warnings

### WR-01: CLAUDE.md 架构描述与实际部署不一致

**File:** `CLAUDE.md:12`
**Issue:** 架构图中 `auth.noda.co.nz -> keycloak:8080` 的描述已过时。Phase 16 变更后，所有外部流量（包括 auth.noda.co.nz）都通过 nginx 反向代理。同样，第 18 行 `Keycloak | 8080/9000 | HTTP + 管理端口，通过 Cloudflare Tunnel 暴露` 的描述也不准确——Keycloak 不再通过 Tunnel 直接暴露。

**Fix:**
```
# 更新架构图
auth.noda.co.nz  -> nginx -> keycloak:8080

# 更新端口表
| Keycloak | 8080 (内部) | 不暴露外部端口，通过 nginx 反向代理访问 |
```

### WR-02: docs/architecture.md 中的路由描述需要同步更新

**File:** `docs/architecture.md:15,159`
**Issue:** 第 15 行 `CF -->|auth.noda.co.nz| Keycloak[keycloak :8080]` 和第 159 行 `auth.noda.co.nz：代理到 keycloak:8080` 描述的是旧的直连路由方式，与 Phase 16 变更后的架构（auth.noda.co.nz -> nginx -> keycloak:8080）不一致。

**Fix:** 更新架构图和路由描述，反映 auth.noda.co.nz 现在通过 nginx 反向代理访问 Keycloak。

## Info

### IN-01: config/cloudflare/config.yml 注释可增强

**File:** `config/cloudflare/config.yml:1-3`
**Issue:** 文件顶部缺少说明此文件仅为本地参考、不控制实际 Tunnel 路由的提示。当前 PITFALLS.md 和 ARCHITECTURE.md 中已记录此信息，但在文件本身添加注释可防止未来的维护者误以为修改此文件即可生效。

**Fix:** 在文件头部添加注释，例如：
```yaml
# 注意：此文件仅作本地参考。Tunnel 使用 --token 模式运行，
# ingress 规则由 Cloudflare Zero Trust Dashboard 远程管理。
# 如需修改路由，请在 Dashboard 中操作并同步更新此文件。
```

### IN-02: docker-compose.yml 中 nginx 的 depends_on 缺少 keycloak

**File:** `docker/docker-compose.yml:52-53`
**Issue:** nginx 的 `depends_on` 仅包含 postgres，不包含 keycloak。Phase 16 之后，auth.noda.co.nz 流量经 nginx 代理到 keycloak，理论上 nginx 应在 keycloak 启动后再启动。不过这是一个已存在的状态（非 Phase 16 引入），且 keycloak 有自己的 healthcheck 和重启策略，实际影响较低。

**Fix:** 考虑将 keycloak 添加到 nginx 的 depends_on 中：
```yaml
depends_on:
  - postgres
  - keycloak
```

---

_Reviewed: 2026-04-12T12:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
