---
phase: 11-服务整合
reviewed: 2026-04-11T13:20:00Z
depth: standard
files_reviewed: 7
files_reviewed_list:
  - docker/docker-compose.app.yml
  - docker/docker-compose.dev-standalone.yml
  - docker/docker-compose.dev.yml
  - docker/docker-compose.prod.yml
  - docker/docker-compose.simple.yml
  - docker/docker-compose.yml
  - scripts/deploy/deploy-findclass-zero-deps.sh
findings:
  critical: 3
  warning: 6
  info: 5
  total: 14
status: issues_found
---

# Phase 11: Code Review Report

**Reviewed:** 2026-04-11T13:20:00Z
**Depth:** standard
**Files Reviewed:** 7
**Status:** issues_found

## Summary

审查了 7 个文件，包括 6 个 Docker Compose 配置和 1 个部署脚本。发现 3 个严重问题、6 个警告和 5 个信息项。

严重问题集中在：硬编码凭据在生产配置中使用、内部服务 URL 依赖自动生成容器名、以及废弃脚本仍可能被误用。警告涉及 Keycloak 配置不一致、生产端口过度暴露、以及 Shell 脚本中的变量初始化问题。

---

## Critical Issues

### CR-01: docker-compose.simple.yml 硬编码明文凭据

**File:** `docker/docker-compose.simple.yml:18-19,45-46,93-94,100-101`
**Issue:** `docker-compose.simple.yml` 中硬编码了明文密码（`postgres_password_change_me`、`admin_password_change_me`），包含数据库密码、Keycloak 管理员密码。虽然 `_change_me` 后缀暗示需要替换，但该文件可直接用于启动生产服务（Keycloak 配置中 `KC_HOSTNAME` 指向 `auth.noda.co.nz`），如果未修改就部署将使用弱密码。
**Fix:**
```yaml
# 所有密码改用环境变量引用
POSTGRES_USER: ${POSTGRES_USER}
POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
KC_DB_USERNAME: ${POSTGRES_USER}
KC_DB_PASSWORD: ${POSTGRES_PASSWORD}
KEYCLOAK_ADMIN: ${KEYCLOAK_ADMIN_USER}
KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
```

### CR-02: docker-compose.app.yml 中 KEYCLOAK_INTERNAL_URL 使用自动生成的容器名

**File:** `docker/docker-compose.app.yml:35`
**Issue:** `KEYCLOAK_INTERNAL_URL: http://noda-infra-keycloak-1:8080` 依赖 Docker Compose 自动生成的容器名（`<project>-<service>-<number>`）。如果项目名、服务名或实例编号变化（例如 scale out、重命名项目），此 URL 将失效。基础配置 `docker-compose.yml` 中 keycloak 服务没有设置 `container_name`，因此名称不稳定。
**Fix:**
在 `docker-compose.yml` 的 keycloak 服务中添加 `container_name`，或使用 Docker 网络 alias（推荐后者，已在 simple.yml 中使用 `aliases: - keycloak`）：
```yaml
# docker-compose.yml keycloak 服务添加 network alias
networks:
  noda-network:
    aliases:
      - keycloak

# docker-compose.app.yml 使用稳定的 alias
KEYCLOAK_INTERNAL_URL: http://keycloak:8080
```

### CR-03: docker-compose.simple.yml 使用已废弃的 KC_HOSTNAME_PORT 选项

**File:** `docker/docker-compose.simple.yml:98`
**Issue:** 根据项目 CLAUDE.md 中的修复记录，`KC_HOSTNAME_PORT` 是 Keycloak v1 废弃选项，不应在 Keycloak 26.x（v2 Hostname SPI）中使用。simple.yml 中 `KC_HOSTNAME: "auth.noda.co.nz"` 缺少 `https://` 协议前缀，与 v2 SPI 要求不一致。正确做法与 `docker-compose.yml` 和 `docker-compose.prod.yml` 一致：`KC_HOSTNAME: "https://auth.noda.co.nz"`。
**Fix:**
```yaml
# 删除废弃选项，修正 KC_HOSTNAME 格式
KC_HOSTNAME: "https://auth.noda.co.nz"
KC_HOSTNAME_STRICT: "false"
# 删除: KC_HOSTNAME_PORT: "443"
```

---

## Warnings

### WR-01: 生产环境 Keycloak 暴露管理端口 9000

**File:** `docker/docker-compose.prod.yml:37-40`
**Issue:** 生产环境配置中 Keycloak 暴露了 8080、8443 和 9000 端口到宿主机。管理端口 9000 无需对外暴露，Cloudflare Tunnel 通过 Docker 内部网络访问服务即可。8080 端口在生产环境中也应考虑是否需要暴露（如仅通过 nginx 内部代理或 tunnel 访问，则不需要映射到宿主机）。
**Fix:**
```yaml
# 生产环境移除不必要的端口映射，仅保留必需的
keycloak:
  # 如果仅通过 Cloudflare Tunnel 访问，可完全不暴露端口
  # 如果需要 nginx 内部代理，使用 127.0.0.1 绑定
  ports:
    - "127.0.0.1:8080:8080"  # 仅本机可访问
  # 移除 8443 和 9000 端口映射
```

### WR-02: docker-compose.yml 中 keycloak depends_on 缺少健康检查条件

**File:** `docker/docker-compose.yml:169-170`
**Issue:** 基础配置中 keycloak 的 `depends_on` 仅列出 `postgres` 但没有 `condition: service_healthy`。而 `findclass-ssr` 服务正确使用了 `postgres: condition: service_healthy`。Keycloak 可能在 PostgreSQL 尚未完全就绪时启动，导致数据库连接失败。
**Fix:**
```yaml
depends_on:
  postgres:
    condition: service_healthy
```

### WR-03: docker-compose.simple.yml 缺少 KC_PROXY_HEADERS 配置

**File:** `docker/docker-compose.simple.yml:99`
**Issue:** simple.yml 配置了 `KC_PROXY: "edge"` 但缺少 `KC_PROXY_HEADERS: "xforwarded"`。基础配置和 prod 配置都同时设置了这两个选项。缺少此配置时 Keycloak 无法正确读取代理转发的 X-Forwarded 头，可能导致生成的回调 URL 使用错误的协议（http 而非 https）。
**Fix:**
```yaml
KC_PROXY: "edge"
KC_PROXY_HEADERS: "xforwarded"
```

### WR-04: docker-compose.dev.yml 中 findclass-ssr 连接生产数据库

**File:** `docker/docker-compose.dev.yml:97-99`
**Issue:** 开发环境覆盖配置中 findclass-ssr 的 `DATABASE_URL` 和 `DIRECT_URL` 指向 `postgres:5432/noda_prod`（生产数据库）。开发环境应连接开发数据库 `postgres-dev:5432/noda_dev`，避免开发操作影响生产数据。
**Fix:**
```yaml
findclass-ssr:
  environment:
    NODE_ENV: development
    DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres-dev:5432/noda_dev
    DIRECT_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres-dev:5432/noda_dev
```

### WR-05: deploy-findclass-zero-deps.sh 清理函数中使用未初始化变量

**File:** `scripts/deploy/deploy-findclass-zero-deps.sh:29`
**Issue:** `cleanup()` 函数引用 `$DECRYPTED_ENV_FILE`，但该变量仅在 `decrypt_secrets()` 成功时才被设置（第 75 行）。如果 `decrypt_secrets()` 未被调用或执行失败，`$DECRYPTED_ENV_FILE` 为空，`[[ -f "$DECRYPTED_ENV_FILE" ]]` 对空字符串会返回 false（不会报错），但 ShellCheck 会标记此问题。更重要的是，如果 `set -u`（第 7 行）生效，引用未设置变量会导致脚本立即退出。
**Fix:**
```bash
DECRYPTED_ENV_FILE=""  # 在脚本顶部初始化

# 或在 cleanup 中使用默认值
cleanup() {
    local env_file="${DECRYPTED_ENV_FILE:-}"
    if [[ -n "$env_file" && -f "$env_file" ]]; then
        rm -f "$env_file"
        log_info "已清理临时环境变量文件"
    fi
}
```

### WR-06: deploy-findclass-zero-deps.sh 健康检查匹配过时容器名

**File:** `scripts/deploy/deploy-findclass-zero-deps.sh:129`
**Issue:** `wait_for_containers()` 使用 `grep -q "noda-findclass"` 检查容器是否就绪，但当前所有 Docker Compose 配置中容器名均为 `findclass-ssr`（不是 `noda-findclass`）。这意味着健康检查永远不会匹配成功，脚本将在 5 分钟超时后以错误退出。
**Fix:**
```bash
if docker ps --format '{{.Names}}' | grep -q "findclass-ssr"; then
```

---

## Info

### IN-01: deploy-findclass-zero-deps.sh 已标记为废弃但仍保留

**File:** `scripts/deploy/deploy-findclass-zero-deps.sh:1-2,84-86`
**Issue:** 脚本第一行标记为 `DEPRECATED`，`build_images()` 函数直接报错退出（第 84-86 行）。由于 `build_images()` 在 `main()` 中被调用，此脚本实际上无法完成任何部署操作。建议在完成迁移后删除此文件，或至少将整个 main() 替换为一条废弃提示以避免混淆。
**Fix:** 删除此脚本，或在 `main()` 开头直接输出废弃提示并退出：
```bash
main() {
    log_error "此脚本已废弃，请使用 scripts/deploy/deploy-infrastructure-prod.sh 或 scripts/deploy/deploy-apps-prod.sh"
    exit 1
}
```

### IN-02: docker-compose.dev-standalone.yml 使用独立项目名

**File:** `docker/docker-compose.dev-standalone.yml:5`
**Issue:** `dev-standalone.yml` 使用项目名 `noda-dev`，而所有其他 compose 文件使用 `noda-infra`。这是有意为之（独立部署场景），但会导致 `docker compose ls` 中出现两个项目，可能造成管理混淆。建议在文件头部注释中明确说明此设计决策。
**Fix:** 已有注释说明，无需修改。可补充一行解释项目名不同的原因。

### IN-03: docker-compose.app.yml 缺少 depends_on 配置

**File:** `docker/docker-compose.app.yml:17-54`
**Issue:** `docker-compose.app.yml` 中 findclass-ssr 服务没有 `depends_on` 配置。虽然数据库和 Keycloak 通过外部网络连接（由其他 compose 文件管理），但缺少 `depends_on` 意味着如果基础设施未启动，应用容器也会启动并反复失败。
**Fix:** 考虑添加外部依赖的健康检查或至少在文档中说明启动顺序要求。

### IN-04: docker-compose.simple.yml 缺少 KC_FRONTEND_URL 配置

**File:** `docker/docker-compose.simple.yml:83-101`
**Issue:** 基础配置 `docker-compose.yml` 中 keycloak 设置了 `KC_FRONTEND_URL: "https://auth.noda.co.nz"`（第 159 行），但 simple.yml 中没有此配置。缺少时 Keycloak 可能生成不正确的前端回调 URL。
**Fix:**
```yaml
KC_FRONTEND_URL: "https://auth.noda.co.nz"
```

### IN-05: deploy-findclass-zero-deps.sh 显示的访问地址过时

**File:** `scripts/deploy/deploy-findclass-zero-deps.sh:197-198`
**Issue:** `show_deployment_status()` 显示 "前端: http://localhost:3000" 和 "Nginx: http://localhost:8080"，但当前配置中前端通过 findclass-ssr 在 3001 端口提供服务，Nginx 在 80 端口。这些地址与实际部署不匹配。
**Fix:** 更新为实际地址或删除此废弃脚本。

---

_Reviewed: 2026-04-11T13:20:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
