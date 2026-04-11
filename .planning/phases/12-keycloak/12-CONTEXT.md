# Phase 12: Keycloak 双环境 - Context

**Gathered:** 2026-04-11
**Status:** Ready for planning

<domain>
## Phase Boundary

创建独立的 Keycloak 开发环境实例（keycloak-dev），开发者可安全测试配置变更而不影响生产数据。三个需求交付：

1. **KCDEV-01:** 独立 keycloak-dev 容器 + keycloak_dev 数据库 + 端口偏移
2. **KCDEV-02:** 开发环境支持密码登录（无需 Google OAuth）
3. **KCDEV-03:** 开发环境禁用主题缓存，支持热重载

不涉及：生产 Keycloak 配置变更、新增认证方式、自定义主题开发（Phase 13 范围）。

</domain>

<decisions>
## Implementation Decisions

### Keycloak 启动模式
- **D-01:** keycloak-dev 使用 `start-dev` 命令启动 — 自动禁用主题缓存、关闭 HTTPS 要求、放宽安全限制，开箱即用满足 KCDEV-02/03 需求

### 端口与网络设计
- **D-02:** 端口映射：HTTP `18080:8080`，管理 `19000:9000` — 与 prod 端口（8080/9000）对应，易记忆
- **D-03:** keycloak-dev 加入现有 `noda-network` 网络 — 与 postgres-dev 保持一致模式，可直接访问 postgres-dev:5432

### 开发环境初始化
- **D-04:** 手动在 Admin Console 创建 noda realm 和测试用户 — 简单直接，避免维护自动化脚本
- **D-05:** 开发环境仅开启密码登录，不配置 Google OAuth — 避免在 Google Cloud Console 添加 localhost 回调 URL

### 主题热重载机制
- **D-06:** 使用宿主机目录读写挂载到 Keycloak themes 目录 — 修改文件后 start-dev 自动重新加载
- **D-07:** 挂载标准 login 类型主题（Freemarker 模板 + CSS 覆盖）— 为 Phase 13 自定义主题开发提供基础

### Claude's Discretion
- keycloak-dev 容器名格式（建议 noda-infra-keycloak-dev，与现有命名一致）
- keycloak-dev 数据库连接字符串的具体参数
- start-dev 是否需要额外 JVM 参数（内存限制等）
- 是否需要为 keycloak-dev 添加 healthcheck

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docker Compose 配置
- `docker/docker-compose.yml` — 基础配置，keycloak 服务定义（prod 配置参考）
- `docker/docker-compose.dev.yml` — 开发环境 overlay，postgres-dev 定义模式参考
- `docker/docker-compose.simple.yml` — 简化版，包含 keycloak 基础定义
- `docker/docker-compose.prod.yml` — 生产环境 Keycloak 配置（v2 hostname SPI 参考源）

### 数据库初始化
- `docker/services/postgres/init-dev/01-create-databases.sql` — 已预创建 keycloak_dev 数据库

### Nginx 配置
- `config/nginx/conf.d/default.conf` — 反向代理配置（开发环境可能需要添加 keycloak-dev 路由）

### Keycloak 主题
- `docker/services/keycloak/themes/` — 主题目录（当前为空，Phase 13 将使用）

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **PostgreSQL dev 双实例模式:** postgres-dev 容器已在 docker-compose.dev.yml 中定义，使用 5433 端口 + postgres_dev_data 卷 + noda-network 网络。keycloak-dev 可完全复用此模式
- **keycloak_dev 数据库:** 已在 init-dev/01-create-databases.sql 中预创建，无需额外初始化
- **Keycloak v2 hostname SPI 配置:** 生产环境已验证 `KC_HOSTNAME` + `KC_PROXY: "edge"` + `KC_PROXY_HEADERS: "xforwarded"` 组合可用

### Established Patterns
- **Docker Compose overlay 模式:** 基础 yml + dev.yml 叠加，开发环境覆盖生产配置
- **端口偏移模式:** postgres-dev 用 5433（prod 5432），keycloak-dev 用 18080（prod 8080）
- **容器命名:** `noda-infra-{service}-{env}` 格式（如 noda-infra-postgres-prod, noda-infra-postgres-dev）
- **noda.service-group 标签:** 所有基础设施服务标记为 `infra`

### Integration Points
- keycloak-dev 通过 noda-network 连接 postgres-dev:5432 的 keycloak_dev 数据库
- findclass-ssr 开发环境需要将 KEYCLOAK_URL 指向 keycloak-dev（当前指向 prod keycloak）
- 开发环境 Nginx 可能需要添加 keycloak-dev 的代理配置

</code_context>

<specifics>
## Specific Ideas

- start-dev 模式是 Keycloak 官方推荐的开发启动方式，自动处理了主题缓存禁用等开发便利设置
- 主题目录挂载需要在 docker-compose.dev.yml 中添加 volumes 配置，将 `./services/keycloak/themes` 挂载到 `/opt/keycloak/themes/noda`
- 开发环境启动命令：`docker compose -f docker-compose.yml -f docker-compose.dev.yml up keycloak-dev`
- findclass-ssr 开发环境可能需要额外的 KEYCLOAK_URL 覆盖来指向 keycloak-dev

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---
*Phase: 12-keycloak*
*Context gathered: 2026-04-11*
