# Phase 11: 服务整合 - Context

**Gathered:** 2026-04-11
**Status:** Ready for planning

<domain>
## Phase Boundary

findclass-ssr 相关文件路径引用整理统一，Docker 容器添加分组标签实现清晰的服务分类。

不涉及：新增服务、应用代码变更、网络架构调整、新增 docker-compose 变体。

</domain>

<decisions>
## Implementation Decisions

### 目录结构迁移 (GROUP-01)
- **D-01:** 保持 noda-apps 作为独立代码仓库（应用代码），Dockerfile 和配置文件留在 noda-infra/deploy/ 下，只整理路径引用使其一致
- **D-02:** 需要统一的路径引用 — 当前 docker-compose.yml 和 docker-compose.app.yml 的 Dockerfile 路径不一致（前者用 `./infra/docker/` 后者用 `../noda-infra/deploy/`），需要统一
- **D-03:** 成功标准：`docker compose config` 输出路径正确且服务正常启动

### Docker 分组标签 (GROUP-02)
- **D-04:** 双组标签设计 — 基础设施服务归入 `noda-infra` 组（postgres, keycloak, noda-ops, nginx），应用服务归入 `noda-apps` 组（findclass-ssr）
- **D-05:** 成功标准：`docker compose ps --format json` 显示所有容器带有正确分组标签，可通过 `--filter label=project=noda-apps` 过滤查看

### Compose 文件整理
- **D-06:** 所有 5 个 docker-compose 变体文件（yml, prod, dev, app, simple, dev-standalone）全部更新 labels 和路径引用
- **D-07:** 当前变体文件清单：
  - `docker-compose.yml` — 基础配置（所有服务）
  - `docker-compose.prod.yml` — 生产环境 overlay
  - `docker-compose.dev.yml` — 开发环境 overlay
  - `docker-compose.app.yml` — 应用服务独立配置（project name: noda-apps）
  - `docker-compose.simple.yml` — 简化版（无需构建的服务）
  - `docker-compose.dev-standalone.yml` — 开发环境独立部署

### Claude's Discretion
- 具体的 labels 键名和格式（建议使用 com.docker.compose.project 分组）
- 路径引用统一后是否需要更新部署脚本
- 是否需要清理废弃的路径引用

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docker Compose 配置
- `docker/docker-compose.yml` — 基础配置，所有服务定义（build context 和 Dockerfile 路径不一致问题所在）
- `docker/docker-compose.prod.yml` — 生产环境 overlay
- `docker/docker-compose.dev.yml` — 开发环境 overlay
- `docker/docker-compose.app.yml` — 应用服务独立配置（已设 project name: noda-apps）
- `docker/docker-compose.simple.yml` — 简化版
- `docker/docker-compose.dev-standalone.yml` — 开发环境独立部署

### 部署文件
- `deploy/Dockerfile.findclass-ssr` — findclass-ssr Dockerfile（当前存放位置）
- `deploy/Dockerfile.noda-ops` — noda-ops Dockerfile
- `deploy/Dockerfile.backup` — 备份 Dockerfile
- `deploy/entrypoint-ops.sh` — noda-ops 启动脚本
- `deploy/entrypoint.sh` — findclass-ssr 启动脚本

### Nginx 配置
- `config/nginx/conf.d/default.conf` — 反向代理配置（findclass-ssr 路由）

### 部署脚本
- `scripts/deploy/deploy-apps-prod.sh` — 应用部署脚本
- `scripts/deploy/deploy-findclass-zero-deps.sh` — 零依赖部署（引用 Dockerfile.findclass）
- `deploy.sh` — 主部署脚本

</canonical_refs>

<code_context>
## Existing Code Insights

### 当前路径引用问题
- `docker-compose.yml` 第 97 行：build context = `../../noda-apps`，dockerfile = `./infra/docker/Dockerfile.findclass-ssr`
- `docker-compose.app.yml` 第 19 行：build context = `../../noda-apps`，dockerfile = `../noda-infra/deploy/Dockerfile.findclass-ssr`
- 两个 compose 文件对同一个 Dockerfile 使用了不同的相对路径

### 现有分组
- `docker-compose.app.yml` 已设置 `name: noda-apps`（Docker Compose 项目名）
- `docker-compose.simple.yml` 已设置 `name: noda-infra`
- 其他 compose 文件无显式项目名设置

### Integration Points
- noda-apps 是独立仓库，通过 build context 引用（同级目录）
- Nginx 通过 `proxy_pass http://findclass-ssr:3001` 连接应用
- 应用通过 `noda-network` 外部网络与基础设施通信

</code_context>

<specifics>
## Specific Ideas

- 路径统一方向：将所有 compose 文件中的 Dockerfile 路径统一为从 compose 文件所在目录出发的相对路径
- 分组标签应使用标准 Docker Compose labels 格式，确保与 `docker compose ps --filter` 兼容

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 11-服务整合*
*Context gathered: 2026-04-11*
