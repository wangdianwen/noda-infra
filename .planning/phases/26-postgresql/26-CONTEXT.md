# Phase 26: 宿主机 PostgreSQL 安装与配置 - Context

**Gathered:** 2026-04-17
**Status:** Ready for planning (auto mode)

<domain>
## Phase Boundary

开发者在 macOS 宿主机上通过 Homebrew 安装 PostgreSQL 17.9（与生产 Docker 版本匹配），自动创建开发数据库和用户（noda_dev, keycloak_dev），配置 brew services 开机自启，并将 postgres_dev_data Docker volume 中的现有开发数据迁移到本地 PostgreSQL。

范围包括：
- Homebrew 安装 postgresql@17（版本与生产 Docker postgres:17.9 对齐）
- 自动创建开发数据库和用户（noda_dev, keycloak_dev）
- brew services 配置开机自动启动
- 从 postgres_dev_data Docker volume 迁移现有数据到本地 PG

范围不包括：
- Jenkins H2 → PG 迁移（尚未纳入正式需求，属于后续工作）
- 移除 postgres-dev / keycloak-dev 容器（Phase 27）
- 一键开发环境脚本（Phase 30）
- 生产 PostgreSQL 变更

</domain>

<decisions>
## Implementation Decisions

### 认证策略
- **D-01:** 本地开发数据库使用 **trust 认证**（无密码），简化本地开发体验
  - `pg_hba.conf` 中本地连接（local + localhost）使用 trust
  - 不为开发数据库设置密码，避免开发环境凭据管理负担
  - Jenkins 使用的数据库（未来迁移时）应使用 md5 认证，但不在本阶段实现

### 端口配置
- **D-02:** 本地 PostgreSQL 监听 **5432 端口**（默认端口）
  - 开发者本地 macOS 与生产服务器完全隔离，不存在端口冲突
  - Docker 容器中的 PostgreSQL 在服务器内部网络运行，不暴露到宿主机端口
  - 使用默认端口减少开发者配置变更（如 DATABASE_URL 等连接字符串）

### 数据迁移
- **D-03:** 使用 **pg_dump/pg_restore via docker exec** 从 postgres_dev_data volume 迁移数据
  - 通过 `docker exec noda-infra-postgres-dev pg_dump` 导出每个数据库
  - 通过本地 `pg_restore` 导入到宿主机 PostgreSQL
  - 使用 Docker 容器内的 pg_dump 确保版本与数据格式完全匹配
  - 迁移前验证本地 PG 运行正常，迁移后验证数据完整性
  - 如果 Docker volume 中无重要数据，允许跳过迁移直接使用种子脚本初始化

### 脚本组织
- **D-04:** 创建 **独立脚本 `scripts/setup-postgres-local.sh`**，采用子命令模式（与 setup-jenkins.sh 模式一致）
  - `install` — 安装 postgresql@17 + 配置 brew services + 创建开发数据库
  - `init-db` — 仅创建/重建开发数据库和用户
  - `migrate-data` — 从 Docker volume 迁移数据到本地 PG
  - `status` — 检查 PG 运行状态、版本、数据库列表
  - `uninstall` — 卸载 PostgreSQL 并清理数据目录
  - 所有操作幂等设计，重复运行不报错

### 版本对齐
- **D-05:** 严格锁定 **postgresql@17**（不是最新的 postgresql formula）
  - `brew install postgresql@17` 而非 `brew install postgresql`（后者可能安装 18.x）
  - 安装后验证 `psql --version` 主版本号为 17
  - 在项目文档中记录版本对齐要求

### 开发数据库规格
- **D-06:** 创建以下开发数据库和用户（复用现有 init-dev SQL 逻辑）

  | 数据库 | 用途 | 认证 | 初始化来源 |
  |--------|------|------|-----------|
  | `noda_dev` | findclass-ssr / Prisma 开发数据库 | trust | 现有 `init-dev/01-create-databases.sql` + `02-seed-data.sql` |
  | `keycloak_dev` | Keycloak 开发数据库（Phase 27 移除 keycloak-dev 后备用） | trust | 现有 `init-dev/01-create-databases.sql` |

  - 数据库创建脚本复用 `docker/services/postgres/init-dev/` 中现有 SQL
  - 种子数据脚本复用 `init-dev/02-seed-data.sql`（可选执行）

### Claude's Discretion
- 脚本的具体实现细节（错误处理、颜色输出、交互确认）
- brew services 的具体配置方式
- 幂等性检查的具体实现（检测数据库是否已存在等）
- 迁移脚本的进度反馈方式
- 是否需要单独的 `pg_hba.conf` 配置模板

### Folded Todos
无待办事项可合并。

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 研究文档
- `.planning/research/FEATURES.md` §T1 — 宿主机 PostgreSQL 安装与配置详细分析（数据库规格、认证方式、端口策略）
- `.planning/research/PITFALLS.md` §Pitfall 2 — Homebrew PostgreSQL 版本与 Docker 版本不匹配的风险和缓解措施
- `.planning/research/PITFALLS.md` §Integration Gotchas — Homebrew PG -> Docker PG 交互注意事项

### 需求文档
- `.planning/REQUIREMENTS.md` — LOCALPG-01 至 LOCALPG-04 需求定义
- `.planning/ROADMAP.md` §Phase 26 — 成功标准和验收条件

### 现有代码参考
- `docker/services/postgres/init-dev/01-create-databases.sql` — 现有开发数据库创建 SQL（直接复用）
- `docker/services/postgres/init-dev/02-seed-data.sql` — 现有种子数据 SQL（可选复用）
- `scripts/setup-jenkins.sh` — 子命令模式参考（install/uninstall/status 等子命令结构）
- `scripts/init-databases.sh` — 数据库创建脚本模式参考
- `scripts/lib/log.sh` — 结构化日志库（所有脚本统一使用）
- `scripts/lib/health.sh` — 健康检查函数库
- `docker/docker-compose.dev.yml` — postgres-dev 服务定义（了解现有端口和 volume 配置）
- `docker/.env` — 现有数据库凭据配置
- `CLAUDE.md` — 部署规则和项目架构说明

### 项目文档
- `.planning/PROJECT.md` — v1.5 目标、技术栈、Core Value
- `.planning/STATE.md` — 当前进度和 Blockers/Concerns

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `docker/services/postgres/init-dev/01-create-databases.sql` — 创建 noda_dev 和 keycloak_dev 数据库的 SQL，可直接在本地 PG 上执行
- `docker/services/postgres/init-dev/02-seed-data.sql` — 种子数据（uuid-ossp 扩展 + 测试数据），可用于本地 PG 初始化
- `scripts/setup-jenkins.sh` — 子命令模式的完整参考（install/uninstall/status 等），包括架构检测、幂等操作、颜色输出
- `scripts/lib/log.sh` — log_info/log_success/log_error/log_warn 函数，所有脚本统一使用
- `scripts/init-databases.sh` — 数据库创建模式参考（检查数据库是否存在再创建）

### Established Patterns
- 所有脚本使用 `set -euo pipefail` 严格模式
- 日志通过 `source scripts/lib/log.sh` 引入
- 安装脚本提供 install/uninstall/status 子命令（setup-jenkins.sh 模式）
- Docker Compose 使用 overlay 模式（base + dev + prod）
- 数据库初始化使用编号 SQL 文件（01-create-databases.sql, 02-seed-data.sql）

### Integration Points
- 本地 PG 安装后，Phase 27 将移除 docker-compose.dev.yml 中的 postgres-dev 服务
- 本地 PG 的 noda_dev 数据库供 findclass-ssr 本地开发使用
- 本地 PG 的 keycloak_dev 数据库备用（keycloak-dev 容器移除后）
- 数据迁移需要连接到 Docker 网络中的 postgres-dev 容器执行 pg_dump

</code_context>

<specifics>
## Specific Ideas

- 安装脚本应先检查 macOS 架构（Apple Silicon `/opt/homebrew` vs Intel `/usr/local`），自动设置 Homebrew 路径
- `brew install postgresql@17` 安装后需要手动执行 `brew services start postgresql@17` 启动
- PostgreSQL 17 在 Homebrew 中的数据目录为 `/opt/homebrew/var/postgresql@17`（Apple Silicon）
- 数据迁移脚本应支持可选跳过（如果 Docker volume 中无重要数据）
- 安装脚本应检查是否已有其他版本 PostgreSQL 运行（端口冲突检测）

</specifics>

<deferred>
## Deferred Ideas

- **Jenkins H2 → PG 迁移** — 需要本地 PG 就绪后执行，但尚未纳入正式需求定义；待 Phase 26 完成后评估是否纳入 v1.5 或 v1.6
- **Jenkins PG 数据纳入 B2 备份** — 依赖 Jenkins 迁移完成，超出 Phase 26 范围
- **开发数据库种子数据自动化** — Phase 30（一键开发环境脚本）中处理
- **PostgreSQL 配置优化（shared_buffers, work_mem）** — 开发环境使用默认配置即可，生产配置在 Docker 容器中

</deferred>

---

*Phase: 26-postgresql*
*Context gathered: 2026-04-17 (auto mode)*
