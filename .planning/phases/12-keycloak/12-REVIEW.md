---
phase: 12-keycloak
reviewed: 2026-04-11T00:00:00Z
depth: standard
files_reviewed: 3
files_reviewed_list:
  - docker/docker-compose.dev.yml
  - docker/services/keycloak/themes/noda/login/resources/css/styles.css
  - docker/services/keycloak/themes/noda/login/theme.properties
findings:
  critical: 0
  warning: 3
  info: 2
  total: 5
status: issues_found
---

# Phase 12: Code Review Report

**Reviewed:** 2026-04-11
**Depth:** standard
**Files Reviewed:** 3
**Status:** issues_found

## Summary

Reviewed the Keycloak development environment setup, including `docker-compose.dev.yml` overlay and the custom "noda" login theme files. The keycloak-dev service is well-configured with proper database isolation, localhost-only port binding, and start-dev mode. The theme is a minimal CSS-only override that correctly extends the built-in keycloak theme.

Three warnings found: a postgres-dev port exposure issue, a findclass-ssr dev config pointing at the production database, and a production keycloak port exposure in the dev overlay. Two informational items: the empty CSS placeholder and a comment referencing an incorrect phase number.

## Critical Issues

No critical issues found.

## Warnings

### WR-01: postgres-dev 端口未绑定到 127.0.0.1

**File:** `docker/docker-compose.dev.yml:23`
**Issue:** `postgres-dev` 服务暴露端口 `5433:5432` 但未绑定到 localhost。与 `keycloak-dev`（第 106-107 行使用 `127.0.0.1:18080`）不同，postgres-dev 端口对所有网络接口开放。结合 `.env` 中使用的默认密码（`postgres_password_change_me`），在共享网络环境下存在数据库被未授权访问的风险。
**Fix:**
```yaml
ports:
  - "127.0.0.1:5433:5432"  # 仅本机访问
```

### WR-02: findclass-ssr 开发环境连接生产数据库

**File:** `docker/docker-compose.dev.yml:92-93`
**Issue:** 开发环境的 `findclass-ssr` 服务 `DATABASE_URL` 指向 `postgres:5432/noda_prod`（生产 PostgreSQL 容器的生产数据库），而不是 `postgres-dev:5432/noda_dev`。这意味着开发环境中的测试操作会直接影响生产数据，存在数据损坏或丢失的风险。
**Fix:**
```yaml
environment:
  NODE_ENV: development
  DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres-dev:5432/noda_dev
  DIRECT_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres-dev:5432/noda_dev
```

### WR-03: 生产 keycloak 端口在开发环境中暴露到所有接口

**File:** `docker/docker-compose.dev.yml:73-75`
**Issue:** 开发覆盖配置中，生产 `keycloak` 服务（从 `docker-compose.yml` 基础文件继承的服务）暴露了 `8080:8080`、`8443:8443`、`9000:9000` 端口，均未绑定到 `127.0.0.1`。而在 `docker-compose.prod.yml` 中，同样的端口正确地使用了 `127.0.0.1` 绑定。在开发环境启动时，这些端口对外暴露。对比同文件中 `keycloak-dev` 服务的 `127.0.0.1` 绑定，这里的配置不一致。
**Fix:**
```yaml
ports:
  - "127.0.0.1:8080:8080"  # 仅本机访问
  - "127.0.0.1:8443:8443"  # 仅本机访问
  - "127.0.0.1:9000:9000"  # 仅本机访问
```

## Info

### IN-01: CSS 文件仅有占位注释

**File:** `docker/services/keycloak/themes/noda/login/resources/css/styles.css:1`
**Issue:** CSS 文件内容仅为 `/* Noda custom login theme - Phase 13 */`，没有任何实际样式规则。虽然作为初始占位符是合理的，但在部署到生产环境之前需要添加实际的自定义样式。
**Fix:** 添加 Noda 品牌相关的 CSS 样式，或确认这是预期的空白占位符状态。

### IN-02: CSS 注释中的 Phase 编号与当前阶段不一致

**File:** `docker/services/keycloak/themes/noda/login/resources/css/styles.css:1`
**Issue:** 注释写的是 "Phase 13"，但当前是 Phase 12（Keycloak 双环境设置）。Phase 编号不一致可能导致追踪混乱。
**Fix:** 将注释更新为 `/* Noda custom login theme - Phase 12 */` 或移除阶段引用。

---

_Reviewed: 2026-04-11_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
