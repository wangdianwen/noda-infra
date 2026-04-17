# Phase 27: 开发容器清理与 Docker Compose 简化 - Research

**Researched:** 2026-04-17
**Domain:** Docker Compose 配置清理 + 部署脚本更新 + 文档同步
**Confidence:** HIGH

## Summary

Phase 27 的核心任务是移除 `docker-compose.dev.yml` 中的 `postgres-dev` 和 `keycloak-dev` 服务定义，删除 `docker-compose.dev-standalone.yml`，清理 `docker-compose.simple.yml` 中的 `postgres-dev`，同步更新部署脚本 `deploy-infrastructure-prod.sh` 和文档。Phase 26 已完成本地 PostgreSQL 安装脚本 `setup-postgres-local.sh`，本地 PG 完全替代了 Docker dev 容器的功能，为本次清理奠定了基础。

本阶段的变更范围明确：仅涉及配置文件编辑、脚本逻辑更新和文档同步，不涉及任何运行时状态迁移或生产服务变更。所有需要修改的文件和引用点已通过代码库 grep 完整识别。

**Primary recommendation:** 按文件依赖顺序逐步清理 -- 先编辑 YAML 服务定义，再更新部署脚本的列表变量，然后处理 setup-postgres-local.sh 的兼容性，最后同步文档。每个文件修改后可独立验证。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** docker-compose.dev.yml **保留 nginx 和 keycloak 的开发覆盖配置**，仅移除 postgres-dev 和 keycloak-dev 服务定义
  - nginx 开发覆盖：端口 8081、挂载前端 dist 目录
  - keycloak 开发覆盖：无 hostname 限制、start-dev 模式
- **D-02:** **删除 docker-compose.dev-standalone.yml**
  - 本地 PostgreSQL 已完全替代其功能（Phase 26 已完成）
  - 独立项目名 `noda-dev` 和隔离网络 `noda-dev-network` 不再需要
- **D-03:** **同步清理 docker-compose.simple.yml 中的 postgres-dev 服务**
  - 如果 simple.yml 移除 dev 后与 docker-compose.yml 高度重复，考虑是否保留
- **D-04:** 更新 deploy-infrastructure-prod.sh：
  - `EXPECTED_CONTAINERS` 移除 `noda-infra-postgres-dev`
  - `START_SERVICES` 移除 `postgres-dev`
  - Compose 文件列表中移除对 dev.yml 的引用（如果 dev.yml 不再包含任何生产必需配置）
- **D-05:** 更新 setup-postgres-local.sh 的 migrate-data 函数：
  - postgres-dev 容器移除后，migrate-data 应检测容器是否存在
  - 容器不存在时输出友好提示
  - 不删除 migrate-data 子命令（保留接口兼容性），但标记为已废弃
- **D-06:** 更新相关文档引用（README.md、docs/DEVELOPMENT.md、docs/CONFIGURATION.md、docs/architecture.md、docs/GETTING-STARTED.md）

### Claude's Discretion
- 具体的 YAML 编辑细节
- 文档更新的措辞和详细程度
- 是否需要在移除前添加确认提示或备份说明

### Deferred Ideas (OUT OF SCOPE)
- **docker-compose.simple.yml 合并到 base** -- 超出 Phase 27 清理范围
- **dev.yml 中 nginx/keycloak 开发覆盖重新设计** -- 当前保留，Phase 30 可能重新定义
- **Docker volume postgres_dev_data 清理** -- 数据已迁移到本地 PG，volume 清理应留给用户手动执行
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CLEANUP-01 | 移除 docker-compose.dev.yml 中的 postgres-dev 服务定义 | dev.yml L18-41 为 postgres-dev 服务定义，需完整移除；volumes 段的 postgres_dev_data 也需移除 |
| CLEANUP-02 | 移除 docker-compose.dev.yml 中的 keycloak-dev 服务定义 | dev.yml L87-126 为 keycloak-dev 服务定义，depends_on postgres-dev，需与 CLEANUP-01 同步移除 |
| CLEANUP-03 | 简化或移除 docker-compose.dev.yml（仅保留必要 dev overlay） | 按 D-01 决策保留 nginx/keycloak 开发覆盖、cloudflared profiles 禁用、postgres 段注释；移除后 dev.yml 仍保留约 60 行 |
| CLEANUP-04 | 更新 deploy-infrastructure-prod.sh 中的 EXPECTED_CONTAINERS 和 START_SERVICES 列表 | 移除 L46 的 noda-infra-postgres-dev、L54 的 postgres-dev；COMPOSE_FILES 仍保留 dev.yml 引用（因为 nginx 开发覆盖仍在其中）；rollback 映射函数中无 postgres-dev 条目（已跳过） |
| CLEANUP-05 | 清理 docker-compose.dev-standalone.yml（如果不再需要则移除） | 按 D-02 决策直接删除；同时需处理 docker/services/postgres/init-dev/ 目录的去留（属于数据迁移参考，建议保留但标注为已废弃） |
</phase_requirements>

## Architecture Patterns

### Docker Compose Overlay 模式

项目使用三层 overlay 模式：

```
docker-compose.yml (base)
  ├── docker-compose.prod.yml (生产覆盖：资源限制、SMTP、安全加固)
  ├── docker-compose.dev.yml (开发覆盖：端口映射、开发数据库、Keycloak 本地配置)
  └── docker-compose.simple.yml (独立简化版：硬编码默认值)
```

**清理后 dev.yml 保留的内容**（按 D-01）：
- `postgres:` 段注释（保持结构一致性）
- `nginx:` 开发覆盖（端口 8081、前端 dist 挂载）
- `cloudflared:` profiles 禁用
- `keycloak:` 开发覆盖（空 KC_HOSTNAME、KC_PROXY none、健康检查）

**keycloak-dev 的依赖链**：
```
keycloak-dev → depends_on → postgres-dev (service_healthy)
keycloak-dev → KC_DB_URL → postgres-dev:5432/keycloak_dev
```
两个服务必须同时移除，否则 keycloak-dev 会因依赖缺失而启动失败。

### 容器命名与标签体系

[VERIFIED: 代码库 grep]
```
postgres-dev  → container_name: noda-infra-postgres-dev
keycloak-dev  → container_name: noda-infra-keycloak-dev
```
两个容器都有标签：
- `noda.service-group=infra`
- `noda.environment=dev`

### 部署脚本模式

[VERIFIED: scripts/deploy/deploy-infrastructure-prod.sh]

`deploy-infrastructure-prod.sh` 使用三个变量控制行为：
1. `COMPOSE_FILES` - `-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml`
2. `EXPECTED_CONTAINERS` - 数组，用于健康检查循环
3. `START_SERVICES` - 空格分隔字符串，传给 `docker compose up -d`

**关键发现：COMPOSE_FILES 中包含 dev.yml 是因为生产部署也使用了它**。但仔细分析，dev.yml 中的 nginx 端口覆盖（8081）和 keycloak 配置覆盖是开发用的，生产部署不需要这些覆盖。当前生产部署使用三文件是因为 COMPOSE_FILES 硬编码了 dev.yml 引用。

**决策点（D-04 部分延伸）：** 移除 dev 服务后，COMPOSE_FILES 是否仍需引用 dev.yml？
- 如果 dev.yml 仅剩 nginx/keycloak 开发覆盖，生产部署不应使用这些覆盖
- **建议：COMPOSE_FILES 移除 dev.yml 引用，生产部署使用 `-f base -f prod` 双文件模式**
- 这与 CLAUDE.md 中记录的部署规则一致："deploy-infrastructure-prod.sh 需使用 `-f base -f prod` 双文件"

### rollback_images() 容器映射

[VERIFIED: scripts/deploy/deploy-infrastructure-prod.sh L99-107]

`container_to_service()` 函数中的映射表已明确跳过 `noda-infra-postgres-dev`（注释 "在 dev overlay 中，跳过"），不需要修改此函数。

## 受影响文件清单

### 必须修改的文件

| 文件 | 变更内容 | 影响等级 |
|------|---------|---------|
| `docker/docker-compose.dev.yml` | 移除 postgres-dev（L18-41）和 keycloak-dev（L87-126）服务定义；移除 postgres_dev_data volume 声明 | 核心 |
| `docker/docker-compose.dev-standalone.yml` | 删除整个文件 | 核心 |
| `docker/docker-compose.simple.yml` | 移除 postgres-dev 服务（L37-58）和 postgres_dev_data volume 声明 | 中等 |
| `scripts/deploy/deploy-infrastructure-prod.sh` | EXPECTED_CONTAINERS 移除 postgres-dev；START_SERVICES 移除 postgres-dev；COMPOSE_FILES 移除 dev.yml 引用 | 核心 |
| `scripts/setup-postgres-local.sh` | migrate-data 函数增加容器不存在时的友好提示 | 低 |
| `README.md` | 移除目录结构中 dev-standalone.yml 引用；更新服务表格 | 低 |
| `docs/DEVELOPMENT.md` | 移除 "独立开发环境" 段落；更新开发环境表格 | 中等 |
| `docs/CONFIGURATION.md` | 移除 "独立开发环境" 配置段；更新 Docker Compose 文件结构表 | 中等 |
| `docs/architecture.md` | 移除目录结构中 dev-standalone.yml；更新环境配置层级表 | 中等 |
| `docs/GETTING-STARTED.md` | 更新容器状态示例（移除 postgres-dev 行）；更新端口表格 | 中等 |

### 可选保留的文件

| 文件/目录 | 决策 | 原因 |
|-----------|------|------|
| `docker/services/postgres/init-dev/` | 建议保留，标注为已废弃 | 02-seed-data.sql 包含有价值的种子数据参考，Phase 30 一键脚本可能复用 |

### 不受影响的文件

| 文件 | 原因 |
|------|------|
| `docker/docker-compose.yml` | 基础配置不含 dev 服务 |
| `docker/docker-compose.prod.yml` | 生产 overlay 不含 dev 服务 |
| `config/nginx/*` | Nginx 配置不引用 dev 服务 [VERIFIED: grep] |
| `scripts/init-databases.sh` | 仅操作 postgres-prod 容器和生产数据库 |
| `scripts/verify/*.sh` | 验证脚本不引用 dev 服务 [VERIFIED: grep] |
| `scripts/backup/*` | 备份脚本仅操作 postgres-prod |
| `scripts/lib/*` | 通用库不含 dev 引用 |

## Don't Hand-Roll

| 问题 | 不要自建 | 使用方案 | 原因 |
|------|---------|---------|------|
| dev.yml 验证 | 编写自定义 YAML 解析 | `docker compose -f ... config` 命令 | Docker Compose 原生验证 overlay 合并结果的正确性 |
| 容器存在检测 | 复杂的 Docker API 调用 | `docker ps --format "{{.Names}}" \| grep -q` | setup-postgres-local.sh 已使用此模式 |

## Common Pitfalls

### Pitfall 1: COMPOSE_FILES 移除 dev.yml 导致 nginx/keycloak 开发覆盖丢失

**What goes wrong:** 生产部署脚本 COMPOSE_FILES 中移除 dev.yml 后，如果未来有人误用生产脚本启动开发环境，nginx 会使用生产端口 80（而非 8081），keycloak 会使用生产 hostname 限制。

**Why it happens:** COMPOSE_FILES 变量被 `docker compose down` 和 `docker compose up` 共用，移除 dev.yml 意味着生产部署不再包含任何 dev 覆盖。

**How to avoid:** 这是正确行为 -- 生产部署本不应包含 dev 覆盖。开发环境启动命令应继续使用独立的 `-f dev.yml` 参数。需要在文档中明确区分生产和开发的 compose 文件组合。

### Pitfall 2: rollback_images 中的 postgres-dev 映射

**What goes wrong:** 如果回滚文件中包含已停止的 postgres-dev 容器，`container_to_service()` 函数会返回空字符串（因为映射表中没有 postgres-dev），导致回滚跳过该容器。虽然当前代码已处理此情况（`log_info "跳过未映射的容器"`），但需确认不会影响生产容器的回滚。

**Why it happens:** `save_image_tags()` 遍历 EXPECTED_CONTAINERS 数组保存镜像信息。移除 postgres-dev 后，该容器不会再被保存到回滚文件。

**How to avoid:** 移除 EXPECTED_CONTAINERS 中的 postgres-dev 条目即可，save_image_tags 不会再尝试保存它的镜像。当前代码已安全。

### Pitfall 3: simple.yml 清理后与 base compose 高度重复

**What goes wrong:** simple.yml 移除 postgres-dev 后，其内容（postgres-prod、nginx、keycloak、cloudflared）与 docker-compose.yml + docker-compose.prod.yml 的组合几乎完全重复。保留 simple.yml 可能造成维护负担。

**Why it happens:** simple.yml 最初是为"无需构建镜像"的快速测试场景设计的独立文件。

**How to avoid:** 按 D-03 决策执行清理，simple.yml 的去留判断留给执行阶段。如果决定保留，需添加注释说明其用途和使用场景。

### Pitfall 4: 部署脚本的完成信息仍提及 PostgreSQL (Dev)

**What goes wrong:** deploy-infrastructure-prod.sh 的末尾输出（L353-354）包含 "PostgreSQL (Dev): 运行中"，如果不更新会误导用户。

**Why it happens:** 部署脚本的完成信息是硬编码的。

**How to avoid:** 移除部署脚本末尾的 dev 相关输出行。

### Pitfall 5: postgres_dev_data Docker volume 残留

**What goes wrong:** 移除 compose 文件中的服务定义不会自动删除 Docker volume。`postgres_dev_data` volume 会一直存在占用磁盘空间。

**Why it happens:** Docker Compose `down` 默认不删除 named volumes。

**How to avoid:** 按 CONTEXT.md deferred 决策，volume 清理留给用户手动执行。但在 migrate-data 子命令的废弃提示中应提醒用户可手动清理 volume。

## Code Examples

### 清理后的 docker-compose.dev.yml 结构

```yaml
# 清理后应保留的段落（参考）：
services:
  # PostgreSQL 生产环境（开发环境中不暴露端口）
  postgres:
    # 保持生产 postgres 的初始化脚本
    # 开发环境不暴露端口

  # Nginx 开发环境配置
  nginx:
    ports:
      - "8081:80"  # 本地开发端口
    volumes:
      - ./apps/noda/frontend/dist:/usr/share/nginx/html:ro

  # Cloudflare Tunnel（开发环境禁用）
  cloudflared:
    profiles:
      - dev

  # Keycloak 认证服务（开发环境配置）
  keycloak:
    environment:
      KC_HOSTNAME: ""
      KC_HOSTNAME_STRICT: "false"
      KC_HOSTNAME_STRICT_HTTPS: "false"
      KC_PROXY: none
      KC_HEALTH_ENABLED: "true"
    healthcheck:
      test: ["CMD-SHELL", "echo > /dev/tcp/localhost/8080 2>/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

# 注意：不再需要 volumes 段（postgres_dev_data 已移除）
```

### deploy-infrastructure-prod.sh 更新要点

```bash
# 更新前：
COMPOSE_FILES="-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml"
EXPECTED_CONTAINERS=(
  "noda-infra-postgres-prod"
  "noda-infra-postgres-dev"      # 移除此行
  "noda-infra-keycloak-prod"
  "noda-infra-nginx"
  "noda-ops"
  "findclass-ssr"
)
START_SERVICES="postgres keycloak nginx noda-ops postgres-dev"  # 移除 postgres-dev

# 更新后：
COMPOSE_FILES="-f docker/docker-compose.yml -f docker/docker-compose.prod.yml"
EXPECTED_CONTAINERS=(
  "noda-infra-postgres-prod"
  "noda-infra-keycloak-prod"
  "noda-infra-nginx"
  "noda-ops"
  "findclass-ssr"
)
START_SERVICES="postgres keycloak nginx noda-ops"
```

### setup-postgres-local.sh migrate-data 兼容性更新

```bash
# 在 cmd_migrate_data() 的 Docker 容器检查部分：
# 替换现有的容器未运行处理逻辑
if ! docker ps --format "{{.Names}}" | grep -q "$docker_container"; then
  log_warn "postgres-dev 容器已被移除（Phase 27 清理）"
  log_info "开发数据已在本地 PostgreSQL 中，无需从 Docker 迁移"
  log_info "如需清理 Docker volume: docker volume rm noda-infra_postgres_dev_data"
  return 0
fi
```

## 验证方法

### 验证 CLEANUP-01/02/03: docker compose config 检查

```bash
# 验证 base + dev overlay 不包含 postgres-dev 和 keycloak-dev
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml config | grep -c "postgres-dev\|keycloak-dev"
# 期望输出: 0

# 验证 nginx/keycloak 开发覆盖仍然存在
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml config | grep -A2 "nginx:" | grep "8081"
# 期望输出: 包含 8081 端口映射
```

### 验证 CLEANUP-04: 部署脚本检查

```bash
# 检查脚本中不再包含 dev 服务引用
grep -c "postgres-dev" scripts/deploy/deploy-infrastructure-prod.sh
# 期望输出: 0（注释除外）
```

### 验证 CLEANUP-05: 文件删除确认

```bash
test -f docker/docker-compose.dev-standalone.yml && echo "文件仍存在" || echo "文件已删除"
# 期望输出: 文件已删除
```

### 验证生产部署不受影响

```bash
# 仅用 base + prod 验证配置有效性
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml config
# 期望: 无错误输出
```

## State of the Art

| 旧做法 | 新做法 | 变更时间 | 影响 |
|--------|--------|---------|------|
| Docker postgres-dev 容器提供开发数据库 | Homebrew 本地 PostgreSQL 17 | Phase 26 (2026-04-17) | 开发者需运行 setup-postgres-local.sh install |
| dev-standalone.yml 独立开发环境 | 本地 PG 替代 | Phase 27 | 删除文件 |
| 三文件部署（base + prod + dev） | 双文件部署（base + prod） | Phase 27 | 生产部署不再引入 dev 覆盖 |

**已废弃：**
- `docker-compose.dev-standalone.yml`: 独立开发 PostgreSQL 容器，本地 PG 替代
- `docker/services/postgres/init-dev/`: 开发数据库初始化脚本，功能已由 `setup-postgres-local.sh` 覆盖（建议保留文件作为参考）

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Phase 26 的数据迁移已完成或用户确认无需迁移 | Summary | 如果数据未迁移，移除容器后数据可能丢失 |
| A2 | 生产部署使用 COMPOSE_FILES 变量中的所有三个文件是历史遗留，不是有意设计 | Pitfall 1 | 如果生产确实需要 dev.yml 中的某些覆盖，移除后生产行为会改变 |
| A3 | 开发者本地环境变量中没有硬编码 `localhost:5433` 的配置 | Pitfall 3 (FEATURES.md) | 需提醒开发者更新本地连接配置 |

**如果此表中的 A1 和 A2 需要验证：** 建议在执行阶段先用 `docker compose config` 验证 base + prod 的合并结果，确认生产服务行为不变。

## Open Questions

1. **simple.yml 是否保留？**
   - What we know: simple.yml 移除 postgres-dev 后仅剩生产服务，与 base + prod 组合高度重复
   - What's unclear: 是否有用户仍在使用 simple.yml 进行快速测试
   - Recommendation: 保留但添加顶部注释说明用途差异（无需 .env 文件、无资源限制），不在本阶段删除

2. **init-dev/ 目录是否保留？**
   - What we know: 02-seed-data.sql 包含有价值的种子数据 SQL
   - What's unclear: Phase 30 一键脚本是否会复用此文件
   - Recommendation: 保留目录和文件，在 01-create-databases.sql 顶部添加废弃注释，指向 setup-postgres-local.sh

## Environment Availability

Step 2.6: SKIPPED（本阶段仅涉及配置文件编辑和脚本更新，无外部依赖）

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Docker Compose config 验证（无传统测试框架） |
| Config file | none |
| Quick run command | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml config \| grep -c "postgres-dev"` |
| Full suite command | `bash scripts/utils/validate-docker.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CLEANUP-01 | dev.yml 不包含 postgres-dev 服务 | smoke | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml config 2>&1 \| grep -c postgres-dev` 期望 0 | ✅ |
| CLEANUP-02 | dev.yml 不包含 keycloak-dev 服务 | smoke | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml config 2>&1 \| grep -c keycloak-dev` 期望 0 | ✅ |
| CLEANUP-03 | dev.yml 仍包含 nginx/keycloak 开发覆盖 | smoke | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml config 2>&1 \| grep "8081"` | ✅ |
| CLEANUP-04 | 部署脚本不含 postgres-dev 引用 | unit | `grep -c "postgres-dev" scripts/deploy/deploy-infrastructure-prod.sh` | ✅ |
| CLEANUP-05 | dev-standalone.yml 已删除 | smoke | `test -f docker/docker-compose.dev-standalone.yml && echo FAIL || echo PASS` | ✅ |

### Sampling Rate
- **Per task commit:** `bash scripts/utils/validate-docker.sh`
- **Per wave merge:** `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml config`
- **Phase gate:** 全部 5 项验证命令通过

### Wave 0 Gaps
None -- 现有 `validate-docker.sh` 脚本可覆盖配置语法验证需求，无需额外测试框架。

## Security Domain

> 本阶段不涉及安全域变更。仅移除开发容器定义和更新部署脚本列表，不影响生产安全配置。

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | 不涉及 |
| V3 Session Management | no | 不涉及 |
| V4 Access Control | no | 不涉及 |
| V5 Input Validation | no | 不涉及 |
| V6 Cryptography | no | 不涉及 |

### Known Threat Patterns

无新增威胁模式。移除 dev 容器实际上减小了攻击面（减少了暴露的端口和服务）。

## Sources

### Primary (HIGH confidence)
- 代码库分析: `docker/docker-compose.dev.yml` -- postgres-dev (L18-41) 和 keycloak-dev (L87-126) 服务定义
- 代码库分析: `docker/docker-compose.dev-standalone.yml` -- 独立开发环境配置
- 代码库分析: `docker/docker-compose.simple.yml` -- postgres-dev (L37-58) 服务定义
- 代码库分析: `scripts/deploy/deploy-infrastructure-prod.sh` -- EXPECTED_CONTAINERS (L44-51) 和 START_SERVICES (L54)
- 代码库分析: `scripts/setup-postgres-local.sh` -- migrate-data 函数 (L340-466)
- 代码库 grep: Nginx 配置不引用 dev 服务 -- 确认无影响

### Secondary (MEDIUM confidence)
- `.planning/research/FEATURES.md` §T3 -- 移除 dev 容器的详细分析和依赖链
- `.planning/research/PITFALLS.md` §Pitfall 3 -- 移除 dev 容器的风险和缓解措施
- `.planning/phases/26-postgresql/26-CONTEXT.md` -- Phase 26 决策（数据迁移策略 D-03）

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - 所有变更基于已有技术（Docker Compose YAML、Bash 脚本），无新技术引入
- Architecture: HIGH - Docker Compose overlay 模式已验证，依赖关系清晰
- Pitfalls: HIGH - 通过完整代码库 grep 识别了所有引用点，无遗漏风险

**Research date:** 2026-04-17
**Valid until:** 2026-05-17（配置清理任务，变更稳定）

---

*Phase: 27-docker-compose*
*Research completed: 2026-04-17*
