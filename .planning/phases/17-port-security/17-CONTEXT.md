# Phase 17: 端口安全加固 - Context

**Gathered:** 2026-04-12
**Status:** Ready for planning
**Source:** Auto mode (--auto)

<domain>
## Phase Boundary

将 postgres-dev 5433 端口绑定从 0.0.0.0（所有接口）改为 127.0.0.1（仅本地），确认 Keycloak 9000 管理端口已在 Phase 16 收敛。修复所有 compose 文件中的不安全端口绑定。

</domain>

<decisions>
## Implementation Decisions

### postgres-dev 端口绑定（SEC-01）
- **D-01:** docker-compose.dev.yml 第 23 行端口从 `"5433:5432"` 改为 `"127.0.0.1:5433:5432"`
- **D-02:** docker-compose.simple.yml 第 43 行端口从 `"5433:5432"` 改为 `"127.0.0.1:5433:5432"`
- **D-03:** docker-compose.dev-standalone.yml 第 27 行端口从 `"5433:5432"` 改为 `"127.0.0.1:5433:5432"`
- **D-04:** 修改后本地开发通过 `127.0.0.1:5433` 仍可正常连接 dev 数据库

### Keycloak 管理端口（SEC-02）
- **D-05:** Keycloak 9000 管理端口已在 Phase 16 从生产 compose 中移除（KC-02），无需额外操作
- **D-06:** docker-compose.simple.yml 第 89 行 Keycloak 9000 端口从 `"9000:9000"` 改为 `"127.0.0.1:9000:9000"`（与 dev overlay 保持一致的 localhost 绑定策略）
- **D-07:** docker-compose.dev.yml 中 keycloak-dev 端口已绑定 127.0.0.1（`"127.0.0.1:19000:9000"`），无需修改

### 部署验证
- **D-08:** 部署后使用 `docker ps --format 'table {{.Names}}\t{{.Ports}}'` 验证 postgres-dev 端口显示为 `127.0.0.1:5433->5432/tcp`
- **D-09:** 使用 `ss -tlnp | grep 5433` 或 `netstat -tlnp | grep 5433` 确认仅监听 localhost
- **D-10:** 本地 `psql -h 127.0.0.1 -p 5433` 连接测试通过

### Claude's Discretion
- simple.yml 和 dev-standalone.yml 是否需要同时修改（D-02、D-03 建议修改）
- 验证命令的具体参数

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docker Compose 配置
- `docker/docker-compose.dev.yml` — dev overlay，postgres-dev 端口绑定（第 23 行）
- `docker/docker-compose.simple.yml` — 简化配置，postgres-dev 端口（第 43 行）+ Keycloak 9000 端口（第 89 行）
- `docker/docker-compose.dev-standalone.yml` — 独立 dev 配置，postgres-dev 端口（第 27 行）

### 项目文档
- `CLAUDE.md` — 项目指南，部署规则和架构说明
- `.planning/REQUIREMENTS.md` — SEC-01、SEC-02 需求定义

### 先前 Phase 参考
- `.planning/phases/16-keycloak/16-CONTEXT.md` — Phase 16 决策（Keycloak 端口移除已完成）
- `.planning/phases/16-keycloak/16-HUMAN-UAT.md` — Phase 16 验证结果

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Phase 16 已建立端口收敛模式（从 compose 移除/限制端口暴露）
- docker-compose.dev.yml 中 keycloak-dev 已使用 `"127.0.0.1:18080:8080"` 和 `"127.0.0.1:19000:9000"` 的 localhost 绑定模式

### Established Patterns
- Docker Compose 端口绑定格式：`"127.0.0.1:HOST_PORT:CONTAINER_PORT"` 限制为 localhost
- 生产环境不暴露端口，dev 环境端口绑定到 localhost

### Integration Points
- docker-compose.dev.yml 第 23 行 — postgres-dev 端口绑定
- docker-compose.simple.yml 第 43 行 — postgres-dev 端口绑定
- docker-compose.simple.yml 第 89 行 — Keycloak 9000 管理端口
- docker-compose.dev-standalone.yml 第 27 行 — postgres-dev 端口绑定

</code_context>

<specifics>
## Specific Ideas

- postgres-dev 端口 5433 在所有 compose 文件中都是 `"5433:5432"` 格式（0.0.0.0），需要统一改为 localhost 绑定
- Keycloak-dev 在 dev.yml 中已经正确使用 127.0.0.1 绑定，可以作为模式参考
- simple.yml 是简化/测试配置，其中的 9000 端口暴露是遗留问题

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 17-port-security*
*Context gathered: 2026-04-12 via auto mode*
