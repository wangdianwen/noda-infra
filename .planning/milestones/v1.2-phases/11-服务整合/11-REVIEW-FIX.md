---
phase: 11-服务整合
fixed_at: 2026-04-11T01:35:06Z
review_path: .planning/phases/11-服务整合/11-REVIEW.md
iteration: 1
findings_in_scope: 9
fixed: 9
skipped: 0
status: all_fixed
---

# Phase 11: Code Review Fix Report

**Fixed at:** 2026-04-11T01:35:06Z
**Source review:** .planning/phases/11-服务整合/11-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 9
- Fixed: 9
- Skipped: 0

## Fixed Issues

### CR-01: docker-compose.simple.yml 硬编码明文凭据

**Files modified:** `docker/docker-compose.simple.yml`
**Commit:** c8d5df6
**Applied fix:** 将所有硬编码密码（POSTGRES_PASSWORD、KC_DB_USERNAME、KC_DB_PASSWORD、KEYCLOAK_ADMIN、KEYCLOAK_ADMIN_PASSWORD）替换为环境变量引用（${POSTGRES_USER}、${POSTGRES_PASSWORD}、${KEYCLOAK_ADMIN_USER}、${KEYCLOAK_ADMIN_PASSWORD}）。

### CR-02: docker-compose.app.yml 中 KEYCLOAK_INTERNAL_URL 使用自动生成的容器名

**Files modified:** `docker/docker-compose.yml`, `docker/docker-compose.app.yml`
**Commit:** 4b0c3e7
**Applied fix:** 在 docker-compose.yml 的 keycloak 服务网络配置中添加 alias `keycloak`，并将 docker-compose.app.yml 的 KEYCLOAK_INTERNAL_URL 从 `http://noda-infra-keycloak-1:8080` 改为 `http://keycloak:8080`。

### CR-03: docker-compose.simple.yml 使用已废弃的 KC_HOSTNAME_PORT 选项

**Files modified:** `docker/docker-compose.simple.yml`
**Commit:** 8fe30b5
**Applied fix:** 删除废弃的 `KC_HOSTNAME_PORT: "443"`，将 `KC_HOSTNAME` 从 `"auth.noda.co.nz"` 修正为 `"https://auth.noda.co.nz"`（符合 Keycloak v2 Hostname SPI 要求）。

### WR-01: 生产环境 Keycloak 暴露管理端口 9000

**Files modified:** `docker/docker-compose.prod.yml`
**Commit:** de9f99c
**Applied fix:** 将 8080 端口改为 `127.0.0.1:8080:8080`（仅本机可访问），移除 8443 和 9000 端口映射。

### WR-02: docker-compose.yml 中 keycloak depends_on 缺少健康检查条件

**Files modified:** `docker/docker-compose.yml`
**Commit:** f4dd4d4
**Applied fix:** 将 keycloak 的 `depends_on: - postgres` 改为 `depends_on: postgres: condition: service_healthy`，确保 PostgreSQL 完全就绪后才启动 Keycloak。

### WR-03: docker-compose.simple.yml 缺少 KC_PROXY_HEADERS 配置

**Files modified:** `docker/docker-compose.simple.yml`
**Commit:** 14ec302
**Applied fix:** 在 KC_PROXY: "edge" 后补充 `KC_PROXY_HEADERS: "xforwarded"`，与基础配置和 prod 配置保持一致。

### WR-04: docker-compose.dev.yml 中 findclass-ssr 连接生产数据库

**Files modified:** `docker/docker-compose.dev.yml`
**Commit:** e833bfa
**Applied fix:** 将 DATABASE_URL 和 DIRECT_URL 从 `postgres:5432/noda_prod` 改为 `postgres-dev:5432/noda_dev`，NODE_ENV 从 production 改为 development。

**Status:** fixed: requires human verification -- 此修改涉及数据库连接逻辑变更，建议人工确认开发环境是否确实需要独立数据库。

### WR-05: deploy-findclass-zero-deps.sh 清理函数中使用未初始化变量

**Files modified:** `scripts/deploy/deploy-findclass-zero-deps.sh`
**Commit:** 37045bc
**Applied fix:** 在脚本配置区域初始化 `DECRYPTED_ENV_FILE=""`，并将 cleanup 函数改为使用 `${DECRYPTED_ENV_FILE:-}` 默认值语法，避免 `set -u` 下引用未设置变量导致脚本退出。

### WR-06: deploy-findclass-zero-deps.sh 健康检查匹配过时容器名

**Files modified:** `scripts/deploy/deploy-findclass-zero-deps.sh`
**Commit:** 4276e0c
**Applied fix:** 将 `grep -q "noda-findclass"` 改为 `grep -q "findclass-ssr"`，匹配当前实际的容器名。

---

_Fixed: 2026-04-11T01:35:06Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
