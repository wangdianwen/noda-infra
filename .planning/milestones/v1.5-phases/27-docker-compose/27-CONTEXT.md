# Phase 27: 开发容器清理与 Docker Compose 简化 - Context

**Gathered:** 2026-04-17
**Status:** Ready for planning (auto mode)

<domain>
## Phase Boundary

移除 docker-compose.dev.yml 中的 postgres-dev 和 keycloak-dev 服务定义，简化 Docker Compose overlay 仅保留生产部署必需配置，同步清理相关部署脚本和文档。确保现有生产服务（postgres-prod、keycloak、nginx、noda-ops）部署不受影响。

范围包括：
- 移除 docker-compose.dev.yml 中的 postgres-dev 和 keycloak-dev 服务定义
- 简化 docker-compose.dev.yml（保留 nginx/keycloak 开发覆盖）
- 删除 docker-compose.dev-standalone.yml
- 清理 docker-compose.simple.yml 中的 postgres-dev
- 更新 deploy-infrastructure-prod.sh 的 EXPECTED_CONTAINERS 和 START_SERVICES
- 更新 setup-postgres-local.sh 的 migrate-data 函数兼容性

范围不包括：
- 生产 Docker Compose 配置变更（docker-compose.yml, docker-compose.prod.yml 不动）
- 数据迁移（Phase 26 已完成）
- Keycloak 蓝绿部署（Phase 28）
- 一键开发环境脚本（Phase 30）

</domain>

<decisions>
## Implementation Decisions

### dev.yml 保留内容
- **D-01:** docker-compose.dev.yml **保留 nginx 和 keycloak 的开发覆盖配置**，仅移除 postgres-dev 和 keycloak-dev 服务定义
  - nginx 开发覆盖：端口 8081（避免与生产 80 冲突）、挂载前端 dist 目录
  - keycloak 开发覆盖：无 hostname 限制、start-dev 模式
  - 这些覆盖对本地开发仍有价值，不属于 "移除" 范围

### dev-standalone.yml 处理
- **D-02:** **删除 docker-compose.dev-standalone.yml**
  - 本地 PostgreSQL 已完全替代其功能（Phase 26 已完成）
  - 独立项目名 `noda-dev` 和隔离网络 `noda-dev-network` 不再需要
  - 删除后减少维护负担和用户困惑

### simple.yml 清理
- **D-03:** **同步清理 docker-compose.simple.yml 中的 postgres-dev 服务**
  - simple.yml 包含 postgres-dev 服务定义（端口 5433），与清理目标一致
  - 移除后 simple.yml 仅保留生产服务（postgres、nginx、keycloak、cloudflared）
  - 如果 simple.yml 移除 dev 后与 docker-compose.yml 高度重复，考虑是否保留

### 部署脚本更新
- **D-04:** 更新 deploy-infrastructure-prod.sh：
  - `EXPECTED_CONTAINERS` 移除 `noda-infra-postgres-dev`
  - `START_SERVICES` 移除 `postgres-dev`
  - Compose 文件列表中移除对 dev.yml 的引用（如果 dev.yml 不再包含任何生产必需配置）

### migrate-data 兼容性
- **D-05:** 更新 setup-postgres-local.sh 的 migrate-data 函数：
  - postgres-dev 容器移除后，migrate-data 应检测容器是否存在
  - 容器不存在时输出友好提示："postgres-dev 容器已移除，开发数据已在本地 PostgreSQL 中"
  - 不删除 migrate-data 子命令（保留接口兼容性），但标记为已废弃

### 文档更新
- **D-06:** 更新相关文档引用：
  - README.md 中对 dev-standalone.yml 的引用
  - docs/DEVELOPMENT.md 中的开发环境说明
  - docs/CONFIGURATION.md 中的 postgres-dev 文档
  - docs/architecture.md 中的架构说明
  - docs/GETTING-STARTED.md 中的容器状态示例

### Claude's Discretion
- 具体的 YAML 编辑细节
- 文档更新的措辞和详细程度
- 是否需要在移除前添加确认提示或备份说明

### Folded Todos
无待办事项可合并。

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 研究文档
- `.planning/research/FEATURES.md` §T3 — 移除 postgres-dev / keycloak-dev 容器详细分析（影响矩阵、保留内容）
- `.planning/research/PITFALLS.md` §Pitfall 3 — 移除 dev 容器破坏现有开发工作流的风险和缓解措施

### 需求文档
- `.planning/REQUIREMENTS.md` — CLEANUP-01 至 CLEANUP-05 需求定义
- `.planning/ROADMAP.md` §Phase 27 — 成功标准和验收条件

### 前序 Phase 决策
- `.planning/phases/26-postgresql/26-CONTEXT.md` — 本地 PG 安装决策（D-01~D-06），特别是 D-03 数据迁移策略

### 现有代码参考
- `docker/docker-compose.dev.yml` — 包含 postgres-dev（L18-41）和 keycloak-dev（L87-126）服务定义，需移除
- `docker/docker-compose.dev-standalone.yml` — 独立开发配置，需删除
- `docker/docker-compose.simple.yml` — 包含 postgres-dev（L37-58），需清理
- `docker/docker-compose.yml` — 基础配置（不修改，参考用）
- `docker/docker-compose.prod.yml` — 生产 overlay（不修改，参考用）
- `scripts/deploy/deploy-infrastructure-prod.sh` — EXPECTED_CONTAINERS 和 START_SERVICES 需更新
- `scripts/setup-postgres-local.sh` — migrate-data 函数需兼容性更新
- `CLAUDE.md` — 部署规则和项目架构说明

### 项目文档
- `.planning/PROJECT.md` — v1.5 目标、架构、Out of Scope
- `.planning/STATE.md` — 当前进度和 Blockers/Concerns

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/setup-postgres-local.sh` — Phase 26 创建的本地 PG 管理脚本，migrate-data 函数需要兼容性更新
- `docker/docker-compose.yml` — 基础配置不变，作为清理后的参考基线
- `docker/docker-compose.prod.yml` — 生产 overlay 不变，确保清理不影响生产

### Established Patterns
- Docker Compose overlay 模式（base + dev + prod 三层）
- 容器命名：`noda-infra-{service}-{env}` 格式
- 部署脚本使用 `-f base -f prod` 双文件模式
- 容器双标签体系（`noda.environment` + `noda.service-group`）

### Integration Points
- deploy-infrastructure-prod.sh 引用 EXPECTED_CONTAINERS 进行部署前验证
- docker-compose.dev.yml 被 deploy 脚本通过 `-f` 参数引用
- dev-standalone.yml 使用独立项目名 `noda-dev`，与主项目 `noda-infra` 分离
- simple.yml 中的 cloudflared 服务是独立的 Cloudflare Tunnel 配置

### 风险评估
- **低风险：** 移除 dev 服务定义（生产不依赖这些服务）
- **中风险：** 修改 deploy 脚本的 EXPECTED_CONTAINERS（需确保不影响生产验证逻辑）
- **低风险：** 删除 dev-standalone.yml（独立项目，不影响主 compose）
- **需验证：** 确认没有其他脚本或文档引用被移除的服务

</code_context>

<specifics>
## Specific Ideas

- 移除 postgres-dev 前确认 Phase 26 的数据迁移已完成（STATE.md 中有记录）
- keycloak-dev 的 `depends_on: postgres-dev` 意味着两个服务必须同时移除
- dev.yml 移除 dev 服务后，可能需要评估是否还值得保留 dev overlay 文件
- simple.yml 移除 postgres-dev 后仅剩生产服务，可考虑是否与 base compose 合并

</specifics>

<deferred>
## Deferred Ideas

- **docker-compose.simple.yml 合并到 base** — 超出 Phase 27 清理范围，可后续评估
- **dev.yml 中 nginx/keycloak 开发覆盖重新设计** — 当前保留，Phase 30 一键脚本可能重新定义开发环境
- **Docker volume postgres_dev_data 清理** — 数据已迁移到本地 PG，但 volume 清理应留给用户手动执行

</deferred>

---

*Phase: 27-docker-compose*
*Context gathered: 2026-04-17 (auto mode)*
