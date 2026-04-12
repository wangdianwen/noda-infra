# Phase 18: 容器标签分组 - Context

**Gathered:** 2026-04-12
**Status:** Ready for planning
**Source:** Auto mode (--auto)

<domain>
## Phase Boundary

为所有 Docker Compose 文件中的容器添加 `noda.environment=prod/dev` 标签，修复 `noda.service-group` 值的不一致（`apps` vs `noda-apps`），确保 `docker ps --filter label=noda.environment=prod/dev` 能正确筛选容器。

</domain>

<decisions>
## Implementation Decisions

### 标签值统一（GRP-02）
- **D-01:** `noda.service-group` 统一使用 `apps`（不是 `noda-apps`）。理由：更简洁，与 `infra` 对称，避免名称中重复 `noda` 前缀
- **D-02:** 修改 `docker-compose.yml` 和 `docker-compose.prod.yml` 中 findclass-ssr 的 `noda.service-group=noda-apps` 为 `noda.service-group=apps`
- **D-03:** `docker-compose.app.yml` 已经使用 `apps`，无需修改

### 环境标签添加（GRP-01）
- **D-04:** 所有生产服务添加 `noda.environment=prod` 标签
- **D-05:** 所有开发服务添加 `noda.environment=dev` 标签
- **D-06:** 具体服务分配：

**生产服务（noda.environment=prod）：**
| 服务 | compose 文件 |
|------|-------------|
| postgres | docker-compose.yml |
| keycloak | docker-compose.yml + docker-compose.prod.yml |
| nginx | docker-compose.yml |
| noda-ops | docker-compose.yml |
| findclass-ssr | docker-compose.yml + docker-compose.prod.yml |

**开发服务（noda.environment=dev）：**
| 服务 | compose 文件 |
|------|-------------|
| postgres-dev | docker-compose.dev.yml |
| keycloak-dev | docker-compose.dev.yml |

**simple.yml 和 dev-standalone.yml 同步更新：**
- simple.yml 中所有服务添加对应标签
- dev-standalone.yml 中 postgres-dev 添加 dev 标签

### 缺失标签修复
- **D-07:** docker-compose.dev.yml 中 postgres-dev 服务缺少 `noda.service-group=infra` 标签，需添加
- **D-08:** docker-compose.dev.yml 中 postgres-dev 服务添加 `noda.environment=dev`

### Claude's Discretion
- label 格式使用 `key=value` 单行还是多行（遵循现有格式）
- 是否需要在 compose.simple.yml 的 cloudflared 服务上添加标签

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docker Compose 配置（需修改）
- `docker/docker-compose.yml` — 基础 compose 配置（findclass-ssr 标签修改 + 所有服务添加 environment 标签）
- `docker/docker-compose.prod.yml` — 生产 overlay（findclass-ssr 标签修改 + keycloak environment 标签）
- `docker/docker-compose.dev.yml` — dev overlay（postgres-dev 补全标签 + keycloak-dev 添加 environment 标签）
- `docker/docker-compose.simple.yml` — 简化配置（所有服务添加标签）
- `docker/docker-compose.dev-standalone.yml` — 独立 dev 配置（postgres-dev 添加标签）
- `docker/docker-compose.app.yml` — 应用服务配置（已使用 `apps`，确认无需修改）

### 需求文档
- `.planning/REQUIREMENTS.md` — GRP-01、GRP-02 需求定义
- `CLAUDE.md` — 项目指南

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- 现有标签格式：`noda.service-group=infra`（key=value 格式，在 deploy.labels 块中）
- Docker Compose labels 语法已在所有主 compose 文件中使用

### Established Patterns
- 标签定义位置：在 `deploy:` → `labels:` 块中
- infra 组包含：postgres, keycloak, nginx, noda-ops
- apps 组包含：findclass-ssr

### Integration Points
- docker-compose.yml: 5 个服务需添加 environment 标签
- docker-compose.prod.yml: 2 个服务需修改（findclass-ssr 值修改 + keycloak environment 添加）
- docker-compose.dev.yml: 2 个服务需修改（postgres-dev 补全 + keycloak-dev 添加 environment）
- docker-compose.simple.yml: 5 个服务需添加标签
- docker-compose.dev-standalone.yml: 1 个服务需添加标签
- docker-compose.app.yml: 确认标签正确（无需修改）

### 当前不一致详情
| 文件 | 服务 | 当前值 | 目标值 |
|------|------|--------|--------|
| docker-compose.yml:111 | findclass-ssr | noda-apps | apps |
| docker-compose.prod.yml:116 | findclass-ssr | noda-apps | apps |
| docker-compose.app.yml:28 | findclass-ssr | apps | apps (已正确) |
| docker-compose.dev.yml | postgres-dev | 无标签 | 添加 service-group=infra + environment=dev |

</code_context>

<specifics>
## Specific Ideas

- 标签统一后验证命令：
  - `docker ps --filter label=noda.environment=prod` 应返回 5 个生产容器
  - `docker ps --filter label=noda.environment=dev` 应返回 2 个 dev 容器
  - `docker ps --filter label=noda.service-group=apps` 应返回 findclass-ssr
  - `docker ps --filter label=noda.service-group=infra` 应返回所有基础设施容器
- 确保 `docker compose config` 验证语法正确
- docker-compose.app.yml 使用 `apps` 是正确的目标值，只需修改另外 2 个文件

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 18-container-labels*
*Context gathered: 2026-04-12 via auto mode*
