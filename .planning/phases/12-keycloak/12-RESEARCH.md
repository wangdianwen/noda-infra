# Phase 12: Keycloak 双环境 - Research

**Researched:** 2026-04-11
**Domain:** Keycloak Docker 开发环境配置 + Docker Compose overlay 模式
**Confidence:** HIGH

## Summary

Phase 12 的核心任务是在现有 Docker Compose 基础上添加独立的 `keycloak-dev` 容器，复用已建立的 postgres-dev 双实例模式。研究确认所有前置条件已就绪：keycloak_dev 数据库已在 postgres-dev 初始化脚本中预创建，noda-network 网络已运行，端口 18080/19000 未被占用。

Keycloak 的 `start-dev` 命令是此阶段的关键技术决策。它自动禁用主题缓存（`spi-theme-static-max-age=-1`）、放宽 HTTPS 要求、启用开发友好的默认值，无需手动配置任何 SPI 属性即可同时满足 KCDEV-02（密码登录）和 KCDEV-03（热重载）两个需求 [CITED: keycloak.org/server/configuration]。

架构上需要遵循 postgres-dev 的模式：在 `docker-compose.dev.yml` 中新增独立的 `keycloak-dev` 服务（不是覆盖现有 keycloak 服务），连接 postgres-dev:5432 的 keycloak_dev 数据库，使用读写挂载的主题目录。

**Primary recommendation:** 在 docker-compose.dev.yml 中新增 keycloak-dev 服务，使用 `start-dev` 命令，连接 postgres-dev 的 keycloak_dev 数据库，端口 18080/19000，宿主机主题目录读写挂载。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** keycloak-dev 使用 `start-dev` 命令启动
- **D-02:** 端口映射：HTTP `18080:8080`，管理 `19000:9000`
- **D-03:** keycloak-dev 加入现有 `noda-network` 网络
- **D-04:** 手动在 Admin Console 创建 noda realm 和测试用户
- **D-05:** 开发环境仅开启密码登录，不配置 Google OAuth
- **D-06:** 使用宿主机目录读写挂载到 Keycloak themes 目录
- **D-07:** 挂载标准 login 类型主题（Freemarker 模板 + CSS 覆盖）

### Claude's Discretion
- keycloak-dev 容器名格式（建议 noda-infra-keycloak-dev，与现有命名一致）
- keycloak-dev 数据库连接字符串的具体参数
- start-dev 是否需要额外 JVM 参数（内存限制等）
- 是否需要为 keycloak-dev 添加 healthcheck

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| KCDEV-01 | 独立 keycloak-dev 容器 + keycloak_dev 数据库 + 端口偏移 | docker-compose.dev.yml 新增 keycloak-dev 服务，连接 postgres-dev:5432/keycloak_dev，端口 18080/19000。keycloak_dev 数据库已在 init-dev SQL 中预创建 [VERIFIED: docker/services/postgres/init-dev/01-create-databases.sql] |
| KCDEV-02 | 开发环境可使用密码登录 | start-dev 模式默认开启用户名/密码认证，无需额外配置。D-05 锁定不配置 Google OAuth [CITED: keycloak.org/server/configuration] |
| KCDEV-03 | 开发环境禁用主题缓存，支持热重载 | start-dev 自动设置 `spi-theme-static-max-age=-1`、`spi-theme-cache-themes=false`、`spi-theme-cache-templates=false`。D-06 锁定宿主机读写挂载 [CITED: keycloak.org/server/configuration] |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Keycloak | 26.2.3 | 身份认证服务 | 生产环境已部署此版本，开发环境保持一致避免兼容问题 [VERIFIED: docker-compose.yml] |
| PostgreSQL | 17.9 | Keycloak 后端数据库 | postgres-dev 已运行此版本 [VERIFIED: docker-compose.dev.yml] |
| Docker Compose | v2.40.3 | 容器编排 | 已安装且运行中 [VERIFIED: docker compose version] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| nginx | 1.25-alpine | 反向代理 | 本阶段不涉及修改，Phase 13 可能需要添加 dev 路由 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| start-dev | start + 手动 SPI 配置 | start-dev 是官方推荐的开发模式，无需手动配置任何 SPI 属性，简化维护 |
| 读写挂载 themes | Docker volume | 读写挂载允许直接在宿主机编辑文件，热重载生效更快；Docker volume 需要额外拷贝步骤 |

**Version verification:**
```bash
# Keycloak 镜像版本 — 与生产保持一致
docker image inspect quay.io/keycloak/keycloak:26.2.3 --format '{{.Id}}' 2>/dev/null | head -1

# Docker Compose 版本
docker compose version  # v2.40.3-desktop.1 [VERIFIED]
```

## Architecture Patterns

### Recommended Project Structure
```
docker/
├── docker-compose.yml          # 基础配置（keycloak 服务定义）
├── docker-compose.dev.yml      # 开发 overlay（postgres-dev + keycloak-dev）
├── docker-compose.prod.yml     # 生产 overlay
├── services/
│   ├── postgres/
│   │   └── init-dev/
│   │       └── 01-create-databases.sql  # 已含 keycloak_dev 数据库创建
│   └── keycloak/
│       └── themes/             # 需新建：主题开发目录
│           └── noda/           # Phase 13 将填充
│               └── login/
│                   ├── theme.properties
│                   └── resources/
│                       └── css/
│                           └── styles.css
```

### Pattern 1: Docker Compose overlay 独立服务模式
**What:** 在 dev.yml 中定义全新的 `keycloak-dev` 服务（不是覆盖现有 keycloak 服务）
**When to use:** 当开发环境需要独立的容器实例，与生产容器并存
**Example:**
```yaml
# docker-compose.dev.yml — 新增 keycloak-dev 服务（不覆盖现有 keycloak）
services:
  keycloak-dev:
    image: quay.io/keycloak/keycloak:26.2.3
    container_name: noda-infra-keycloak-dev
    labels:
      - "noda.service-group=infra"
    restart: unless-stopped
    ports:
      - "18080:8080"   # HTTP 开发端口
      - "19000:9000"   # 管理端口
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres-dev:5432/keycloak_dev
      KC_DB_USERNAME: ${POSTGRES_USER}
      KC_DB_PASSWORD: ${POSTGRES_PASSWORD}
      KC_HTTP_ENABLED: "true"
      KEYCLOAK_ADMIN: ${KEYCLOAK_ADMIN_USER}
      KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
    command: start-dev
    volumes:
      - ./services/keycloak/themes:/opt/keycloak/themes/noda  # 读写挂载
    networks:
      - noda-network
    depends_on:
      postgres-dev:
        condition: service_healthy
```

### Pattern 2: Keycloak start-dev 启动模式
**What:** 使用 `start-dev` 替代 `start` 命令，自动启用开发友好配置
**When to use:** 本地开发环境，需要热重载和宽松安全设置
**Example:**
```yaml
# start-dev 自动配置项（无需手动设置）:
# - spi-theme-static-max-age=-1        禁用静态资源缓存
# - spi-theme-cache-themes=false        禁用主题缓存
# - spi-theme-cache-templates=false     禁用模板缓存
# - hostname-strict-https=false         不强制 HTTPS
# - http-enabled=true                   允许 HTTP 连接
command: start-dev
```
**Source:** [CITED: keycloak.org/server/configuration — start-dev automatically configures development-friendly settings]

### Pattern 3: 主题目录读写挂载
**What:** 将宿主机目录挂载到容器内 Keycloak themes 路径，支持热重载
**When to use:** 开发自定义主题时，修改文件后自动重新加载
**Example:**
```yaml
# 关键区别：读写挂载（不带 :ro），允许开发时修改
volumes:
  - ./services/keycloak/themes:/opt/keycloak/themes/noda
# 注意：生产环境使用 :ro 只读挂载
```

### Anti-Patterns to Avoid
- **在 dev overlay 中覆盖 keycloak 服务：** 当前 docker-compose.dev.yml 已覆盖 keycloak 服务用于本地开发模式。新增 keycloak-dev 是一个全新服务，两者并存。覆盖会导致生产 keycloak 在 dev compose 中被替换，失去双环境并存能力
- **在 start-dev 模式设置 KC_HOSTNAME：** start-dev 自动禁用 hostname strict 模式，手动设置 KC_HOSTNAME 可能导致 localhost 访问异常
- **使用 :ro 只读挂载开发主题目录：** 热重载需要容器能检测文件变化，只读挂载不会阻止检测但不符合语义，且 Phase 13 需要写入能力
- **为 keycloak-dev 配置 Google OAuth：** D-05 明确排除，且需要 Google Cloud Console 配置 localhost 回调 URL，增加复杂度

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 主题缓存禁用 | 手动设置 SPI 属性 | start-dev 命令 | start-dev 自动处理所有缓存相关配置，手动设置容易遗漏或版本升级后失效 |
| 开发环境安全放宽 | 自定义 JVM 参数和配置 | start-dev 命令 | start-dev 是官方推荐方式，经过充分测试 |
| 数据库 schema 初始化 | 手动 SQL 脚本 | Keycloak 自动 schema 迁移 | Keycloak 启动时自动检测并创建/升级数据库 schema，首次连接 keycloak_dev 空数据库会自动初始化 |
| 容器健康检查 | 自定义 curl/wget 检查 | TCP 端口检查模式 | 与生产环境一致的健康检查模式：`echo > /dev/tcp/localhost/9000` [VERIFIED: docker-compose.prod.yml] |

**Key insight:** start-dev 是 Keycloak 官方为开发场景设计的一站式命令，它处理的配置项远比表面看到的要多（包括主题缓存、HTTPS 放宽、metrics 端点等）。手动复现这些配置既不完整也不可维护。

## Common Pitfalls

### Pitfall 1: 混淆 keycloak 服务覆盖与 keycloak-dev 新服务
**What goes wrong:** 在 docker-compose.dev.yml 中修改现有 `keycloak` 服务定义，导致 dev compose 启动时替换了生产 keycloak 配置
**Why it happens:** Docker Compose overlay 机制中，同名的 service key 会合并/覆盖，而非创建新实例
**How to avoid:** keycloak-dev 必须是全新的 service key（`keycloak-dev`），与 `keycloak` 完全独立
**Warning signs:** `docker compose -f ... -f ... up` 后只有一个 keycloak 容器运行

### Pitfall 2: 连接错误的 PostgreSQL 实例
**What goes wrong:** keycloak-dev 的 KC_DB_URL 指向 `postgres:5432`（生产）而非 `postgres-dev:5432`（开发），导致开发环境数据写入生产数据库
**Why it happens:** 复制生产配置时忘记修改数据库主机名
**How to avoid:** KC_DB_URL 必须使用 `postgres-dev:5432` 作为主机，且数据库为 `keycloak_dev`（不是 `keycloak`）
**Warning signs:** keycloak-dev 启动后生产 keycloak 出现 schema 冲突错误

### Pitfall 3: 端口冲突
**What goes wrong:** keycloak-dev 的端口与现有服务冲突
**Why it happens:** 8080 已被生产 keycloak 占用，9000 已被生产 keycloak 管理端口占用
**How to avoid:** 严格使用 D-02 锁定的端口映射：18080:8080（HTTP）和 19000:9000（管理）[VERIFIED: docker ps 确认 8080/9000 已被占用]
**Warning signs:** `port is already allocated` 错误

### Pitfall 4: 主题目录不存在导致挂载失败
**What goes wrong:** `./services/keycloak/themes/` 目录不存在，Docker 创建一个空目录但 Keycloak 无法检测主题
**Why it happens:** 该目录从未创建（当前 docker/services/keycloak/ 不存在）
**How to avoid:** 在 docker-compose.dev.yml 配置之前，先创建目录结构 `docker/services/keycloak/themes/noda/login/resources/css/`
**Warning signs:** 容器启动正常但 Admin Console 中看不到自定义主题

### Pitfall 5: start-dev 模式下配置生产级安全参数
**What goes wrong:** 给 start-dev 容器添加 KC_PROXY=edge、KC_HOSTNAME 等生产配置，导致 localhost 访问被重定向到 auth.noda.co.nz
**Why it happens:** 不了解 start-dev 的自动配置会与手动配置冲突
**How to avoid:** start-dev 不需要 KC_HOSTNAME、KC_PROXY、KC_PROXY_HEADERS，这些是生产专属配置
**Warning signs:** 浏览器访问 localhost:18080 被重定向到 auth.noda.co.nz

## Code Examples

### 示例 1: keycloak-dev 完整服务定义
```yaml
# 来源: 基于 docker-compose.dev.yml 中 postgres-dev 模式 + CONTEXT.md 决策
# 文件: docker/docker-compose.dev.yml（新增服务）

  # ----------------------------------------
  # Keycloak 开发环境（独立容器）
  # ----------------------------------------
  keycloak-dev:
    image: quay.io/keycloak/keycloak:26.2.3
    container_name: noda-infra-keycloak-dev
    labels:
      - "noda.service-group=infra"
    restart: unless-stopped
    ports:
      - "18080:8080"   # HTTP 开发端口
      - "19000:9000"   # 管理端口
    environment:
      # 数据库配置（连接 postgres-dev 的 keycloak_dev）
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres-dev:5432/keycloak_dev
      KC_DB_USERNAME: ${POSTGRES_USER}
      KC_DB_PASSWORD: ${POSTGRES_PASSWORD}
      # 启用 HTTP
      KC_HTTP_ENABLED: "true"
      # 管理员账号（与生产使用相同凭证）
      KEYCLOAK_ADMIN: ${KEYCLOAK_ADMIN_USER}
      KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
    # start-dev: 自动禁用主题缓存、放宽安全限制
    command: start-dev
    # 读写挂载主题目录（热重载）
    volumes:
      - ./services/keycloak/themes:/opt/keycloak/themes/noda
    networks:
      - noda-network
    depends_on:
      postgres-dev:
        condition: service_healthy
    # 健康检查（Claude's discretion — 推荐添加）
    healthcheck:
      test: ["CMD-SHELL", "echo > /dev/tcp/localhost/9000 2>/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
```

### 示例 2: 主题目录初始结构
```bash
# 需要创建的最小目录结构（Phase 12 准备，Phase 13 填充内容）
mkdir -p docker/services/keycloak/themes/noda/login/resources/css

# theme.properties 最小配置（Phase 13 开发自定义主题时使用）
cat > docker/services/keycloak/themes/noda/login/theme.properties << 'EOF'
parent=keycloak
import=common/keycloak
EOF
```

### 示例 3: 启动与验证命令
```bash
# 启动开发环境（包含 keycloak-dev）
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d keycloak-dev

# 验证容器运行
docker ps --filter "name=noda-infra-keycloak-dev"

# 访问 Admin Console
# http://localhost:18080/admin/

# 检查日志
docker logs noda-infra-keycloak-dev --tail 50

# 验证数据库连接（检查 keycloak_dev 中是否有 schema）
docker exec noda-infra-postgres-dev psql -U ${POSTGRES_USER} -d keycloak_dev -c "\dt"
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Keycloak v1 hostname SPI (`KC_HOSTNAME_PORT`, `KC_HOSTNAME_STRICT_HTTPS`) | Keycloak v2 hostname SPI (`KC_HOSTNAME` 完整 URL) | Keycloak 20+ | 生产配置已迁移到 v2。start-dev 不需要 hostname 配置 [VERIFIED: CLAUDE.md 修复记录] |
| 手动 SPI 配置禁用主题缓存 | `start-dev` 自动处理 | Keycloak 17+ (Quarkus) | 开发环境零配置即可热重载 |
| WildFly 发行版 | Quarkus 发行版 | Keycloak 17+ | 当前使用的 26.2.3 是 Quarkus 版本，配置语法完全不同 [VERIFIED: docker-compose.yml] |

**Deprecated/outdated:**
- `KC_HOSTNAME_PORT`: v1 废弃选项，不应在 26.x 中使用 [VERIFIED: CLAUDE.md 修复记录]
- `KC_HOSTNAME_STRICT_HTTPS`: v1 废弃选项，`KC_HOSTNAME` 已包含此功能
- `standalone.xml` 配置: WildFly 时代的配置方式，Quarkus 版本使用环境变量

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | start-dev 自动禁用主题缓存（spi-theme-static-max-age=-1 等） | Architecture Patterns, Code Examples | 低 — 这是 Keycloak 官方文档明确记载的行为，但未在此会话中通过 WebSearch 二次验证 |
| A2 | start-dev 模式不需要 KC_HOSTNAME 和 KC_PROXY 配置 | Architecture Patterns, Common Pitfalls | 低 — start-dev 的核心设计就是放宽这些限制 |
| A3 | Keycloak 首次连接空 keycloak_dev 数据库会自动创建 schema | Don't Hand-Roll | 低 — 这是 Keycloak 的标准行为，已通过多次版本验证 |
| A4 | 读写挂载 + start-dev 模式下，修改宿主机主题文件后 Keycloak 会自动重新加载 | Architecture Patterns | 中 — 需要实际验证热重载的响应时间，可能需要浏览器刷新 |

## Open Questions

1. **findclass-ssr 开发环境 KEYCLOAK_URL 覆盖**
   - What we know: findclass-ssr dev 环境当前 KEYCLOAK_URL 未在 docker-compose.dev.yml 中覆盖，默认使用生产值
   - What's unclear: 是否需要在 dev overlay 中为 findclass-ssr 添加 KEYCLOAK_URL: http://keycloak-dev:8080
   - Recommendation: 作为 Claude's discretion 处理 — 建议在 docker-compose.dev.yml 的 findclass-ssr 服务中添加 KEYCLOAK_URL 和 KEYCLOAK_INTERNAL_URL 环境变量覆盖

2. **JVM 内存限制**
   - What we know: 生产环境 keycloak 有 1G 内存限制，开发环境未确定
   - What's unclear: start-dev 模式下的内存消耗是否需要限制
   - Recommendation: 初期不设置限制，观察实际使用后再决定。开发环境资源消耗通常较低

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker Engine | 容器运行时 | Yes | 29.1.3 | -- |
| Docker Compose | 编排工具 | Yes | v2.40.3 | -- |
| Keycloak 镜像 26.2.3 | keycloak-dev 服务 | Yes | 已拉取 | -- |
| PostgreSQL 17.9 (postgres-dev) | keycloak_dev 数据库 | Yes | 运行中 | -- |
| noda-network | 容器间通信 | Yes | 外部网络 | -- |
| 端口 18080 | keycloak-dev HTTP | Yes | 未占用 | -- |
| 端口 19000 | keycloak-dev 管理 | Yes | 未占用 | -- |

**Missing dependencies with no fallback:**
None — 所有依赖均已就绪

**Missing dependencies with fallback:**
None

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Docker smoke tests（基础设施项目，无代码测试框架） |
| Config file | none |
| Quick run command | `docker ps --filter "name=noda-infra-keycloak-dev" && curl -s -o /dev/null -w "%{http_code}" http://localhost:18080/admin/` |
| Full suite command | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d keycloak-dev && sleep 30 && docker ps --filter "name=noda-infra-keycloak-dev"` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| KCDEV-01 | keycloak-dev 容器运行在 18080/19000 端口 | smoke | `docker ps --filter "name=noda-infra-keycloak-dev" --format "{{.Ports}}" \|\| echo "FAIL"` | Wave 0 |
| KCDEV-01 | keycloak_dev 数据库有 Keycloak schema | smoke | `docker exec noda-infra-postgres-dev psql -U postgres -d keycloak_dev -c "\dt" 2>&1 \| grep -c "table"` | Wave 0 |
| KCDEV-02 | Admin Console 可通过密码登录 | manual | 浏览器访问 http://localhost:18080/admin/ 并登录 | N/A |
| KCDEV-03 | 主题目录已挂载且可检测 | smoke | `docker exec noda-infra-keycloak-dev ls /opt/keycloak/themes/noda/login/ 2>&1` | Wave 0 |
| KCDEV-03 | 主题缓存已禁用 | manual | Admin Console 查看主题列表应实时反映文件变更 | N/A |

### Sampling Rate
- **Per task commit:** `docker ps --filter "name=noda-infra-keycloak-dev"`
- **Per wave merge:** 完整启动验证 + 端口检查 + 数据库 schema 验证
- **Phase gate:** 全部 smoke 测试通过 + Admin Console 手动验证完成

### Wave 0 Gaps
- [ ] `docker/services/keycloak/themes/noda/login/theme.properties` — 主题目录最小文件（KCDEV-03 验证需要）
- [ ] keycloak-dev 服务定义在 docker-compose.dev.yml 中 — KCDEV-01 验证需要
- [ ] 无需额外测试框架安装 — 基于容器运行状态的 smoke 测试

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Keycloak 内置用户名/密码认证（开发环境仅密码登录） |
| V3 Session Management | yes | Keycloak 自动管理 session，开发环境默认配置 |
| V4 Access Control | yes | Keycloak Admin Console 控制访问 |
| V5 Input Validation | no | 本阶段无用户输入处理代码 |
| V6 Cryptography | no | 开发环境不涉及加密配置，start-dev 使用默认 HTTP |

### Known Threat Patterns for Docker Compose + Keycloak

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 开发环境暴露在公网 | Information Disclosure | 端口 18080/19000 绑定 127.0.0.1 或仅在内网使用 |
| 开发环境使用生产凭证 | Elevation of Privilege | 开发环境可使用独立的 KEYCLOAK_ADMIN_PASSWORD（当前决策复用） |
| 数据库跨环境污染 | Tampering | KC_DB_URL 严格指向 postgres-dev:5432/keycloak_dev |
| 主题目录挂载路径遍历 | Tampering | Docker volume 挂载使用相对路径，已限制在 ./services/keycloak/themes 内 |

## Sources

### Primary (HIGH confidence)
- docker-compose.yml — 现有 keycloak 生产配置参考 [VERIFIED]
- docker-compose.dev.yml — postgres-dev 双实例模式参考 [VERIFIED]
- docker-compose.prod.yml — 生产健康检查模式参考 [VERIFIED]
- docker/services/postgres/init-dev/01-create-databases.sql — keycloak_dev 数据库预创建 [VERIFIED]
- CLAUDE.md — Keycloak v2 hostname SPI 配置历史和修复记录 [VERIFIED]

### Secondary (MEDIUM confidence)
- keycloak.org/server/configuration — start-dev 模式行为描述 [CITED]
- Keycloak 26.x Quarkus distribution — 环境变量配置语法 [ASSUMED from training]

### Tertiary (LOW confidence)
- 无 — 所有关键技术声明均有项目文件验证或官方文档引用

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有版本和配置已在项目文件中验证
- Architecture: HIGH — postgres-dev 双实例模式已运行，keycloak-dev 完全复用此模式
- Pitfalls: HIGH — 基于 CLAUDE.md 记录的 5 层问题修复经验和 Docker Compose overlay 机制

**Research date:** 2026-04-11
**Valid until:** 2026-05-11（稳定 — 基于已部署的固定版本 26.2.3）
