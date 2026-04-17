# Phase 28: Keycloak 蓝绿部署基础设施 - Research

**Researched:** 2026-04-17
**Domain:** Keycloak 容器蓝绿部署 + nginx upstream 切换 + docker run 生命周期管理
**Confidence:** HIGH

## Summary

Phase 28 将 Keycloak 从 Docker Compose 单容器管理迁移到蓝绿双容器模式。核心机制已在 v1.4（Phase 21-25）为 findclass-ssr 建立并验证：`manage-containers.sh` 通过环境变量参数化支持多服务，蓝绿容器通过 `docker run` 独立管理，nginx upstream 通过 `include snippets/` 文件原子切换。

研究确认 `manage-containers.sh` 的参数化设计可以直接复用，但 Keycloak 有三个关键差异需要处理：(1) 健康检查端点 — Keycloak 26.x 默认在管理端口 9000 暴露 `/health/ready`，而非应用端口 8080；(2) docker run 安全参数 — Keycloak 容器需要挂载主题目录且不能完全 `read-only`；(3) 无构建步骤 — Keycloak 使用官方镜像，Pipeline 省略 Build/Test 阶段。

**Primary recommendation:** 直接复用 `manage-containers.sh` + 创建 `keycloak-blue-green-deploy.sh` 部署脚本。环境变量参数化为 `SERVICE_NAME=keycloak SERVICE_PORT=8080 UPSTREAM_NAME=keycloak_backend HEALTH_PATH=/health/ready`，注意健康检查端口问题（见 Pitfall 1）。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Keycloak 蓝绿容器使用 HTTP 端点检查 `/health/ready`，`KC_HEALTH_ENABLED: "true"`
- **D-02:** 创建 env-keycloak.env 模板文件，包含所有 Keycloak 环境变量，通过 `--env-file` 加载
- **D-03:** 使用 manage-containers.sh init 子命令从 compose 迁移到蓝绿
- **D-04:** 复用 manage-containers.sh（环境变量参数化）+ 新建 keycloak-blue-green-deploy.sh
- **D-05:** 创建独立 Jenkinsfile.keycloak，7 阶段结构（无 Build/Test）
- **D-06:** 更新 upstream-keycloak.conf 支持蓝绿切换
- **D-07:** 蓝绿容器共享同一个 keycloak 数据库

### Claude's Discretion
- env-keycloak.env 模板变量列表和默认值
- health endpoint 重试次数和超时参数
- init 子命令的具体交互流程
- Jenkinsfile.keycloak 的具体环境变量配置
- 清理旧镜像的保留策略

### Deferred Ideas (OUT OF SCOPE)
- Keycloak 版本升级
- Keycloak 数据库分库
- 多服务统一蓝绿脚本（Phase 29）
- Keycloak 配置自动化
- 自动触发 Pipeline
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| KCBLUE-01 | 创建 env-keycloak.env 模板和 /opt/noda/active-env-keycloak 状态文件 | 从 docker-compose.prod.yml 提取所有环境变量；状态文件路径由 ACTIVE_ENV_FILE 控制 |
| KCBLUE-02 | Keycloak upstream 从 compose 别名改为 snippets/upstream-keycloak.conf 蓝绿切换 | 当前 default.conf 已通过 `include` 引用 upstream-keycloak.conf；仅需改为 keycloak-{color}:8080 格式 |
| KCBLUE-03 | manage-containers.sh 支持 Keycloak 蓝绿容器生命周期 | 已支持 SERVICE_NAME/SERVICE_PORT/UPSTREAM_NAME/HEALTH_PATH 环境变量参数化 |
| KCBLUE-04 | Keycloak 从 docker-compose 迁移到 docker run 管理 | init 子命令已有成熟流程：stop compose -> start blue -> update upstream -> reload nginx |
</phase_requirements>

## Standard Stack

### Core
| Library/Component | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Keycloak | 26.2.3 | 认证服务 | 已在生产环境运行，不升级 [VERIFIED: docker-compose.yml image tag] |
| manage-containers.sh | existing | 蓝绿容器生命周期管理 | 已验证参数化设计，支持多服务 [VERIFIED: scripts/manage-containers.sh L20-36] |
| nginx upstream include | existing | 流量切换机制 | 原子写入 + reload，已为 findclass 和 noda-site 验证 [VERIFIED: config/nginx/snippets/] |
| Docker run | v29.1.3 | 容器运行时 | 与 findclass-ssr 蓝绿模式一致 [VERIFIED: docker --version] |

### Supporting
| Component | Purpose | When to Use |
|-----------|---------|-------------|
| env-keycloak.env | Keycloak 环境变量模板 | 所有 docker run 启动 Keycloak 的场景 |
| keycloak-blue-green-deploy.sh | Keycloak 部署流程脚本 | Pipeline 或手动部署时调用 |
| Jenkinsfile.keycloak | Keycloak 专用 Pipeline | Jenkins 手动触发部署 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| 复用 manage-containers.sh 参数化 | 新建独立 keycloak-manage.sh | 独立脚本减少耦合但增加维护成本；参数化复用已在 noda-site 上验证可行 |
| HTTP /health/ready 端点检查 | TCP 端口 8080 检查 | TCP 不验证服务就绪状态（DB 连接等）；但 HTTP 端点需注意管理端口问题（见 Pitfall 1） |

## Architecture Patterns

### 推荐的项目结构变更
```
config/nginx/snippets/
  upstream-keycloak.conf     # 修改：从 keycloak:8080 改为 keycloak-{blue|green}:8080

docker/
  env-keycloak.env           # 新增：Keycloak 环境变量模板

scripts/
  keycloak-blue-green-deploy.sh  # 新增：Keycloak 部署脚本

jenkins/
  Jenkinsfile.keycloak       # 新增：Keycloak Pipeline
```

### Pattern 1: manage-containers.sh 环境变量参数化
**What:** 通过环境变量控制 manage-containers.sh 的服务名、端口、upstream 名、健康检查路径
**When to use:** 所有蓝绿容器管理场景
**Example:**
```bash
# Keycloak 蓝绿参数（通过环境变量或 source 前设置）
export SERVICE_NAME=keycloak
export SERVICE_PORT=8080
export UPSTREAM_NAME=keycloak_backend
export HEALTH_PATH=/health/ready
export ACTIVE_ENV_FILE=/opt/noda/active-env-keycloak
export UPSTREAM_CONF="$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf"

source "$PROJECT_ROOT/scripts/manage-containers.sh"
# 或直接执行：
SERVICE_NAME=keycloak SERVICE_PORT=8080 bash scripts/manage-containers.sh status
```

### Pattern 2: Keycloak docker run 安全配置
**What:** Keycloak 容器需要与 findclass-ssr 不同的安全参数
**Key differences from findclass-ssr:**
- 需要挂载主题目录（`-v themes:/opt/keycloak/themes/noda:ro`）
- 内存限制更高（1G vs 512m）
- 健康检查需要适配 Keycloak 特定端点
- 不能完全 `read-only`（Keycloak 需要写入临时文件到 `/opt/keycloak/data`）

**Source:** docker-compose.prod.yml L96-109 Keycloak 配置

### Pattern 3: init 迁移流程
**What:** 从 compose 管理迁移到 docker run 蓝绿管理
**Flow:**
1. 检测 compose 容器 `noda-infra-keycloak-prod`（注意：不是 `keycloak`）
2. 获取当前镜像 `quay.io/keycloak/keycloak:26.2.3`
3. 用户确认
4. 停止 compose 容器
5. 启动 blue 容器
6. 等待健康检查
7. 更新 upstream（从 `keycloak:8080` 改为 `keycloak-blue:8080`）
8. reload nginx
9. 写入状态文件

**Source:** manage-containers.sh cmd_init L252-324

### Anti-Patterns to Avoid
- **硬编码 Keycloak 端口到 run_container 函数:** 当前 `run_container` 已参数化（SERVICE_PORT），但要确保健康检查命令也使用参数而非硬编码
- **忘记 compose 容器名差异:** compose 中 Keycloak 容器名是 `noda-infra-keycloak-prod`（不是 `keycloak`），init 检测需要用 SERVICE_NAME（默认 keycloak）或手动适配
- **Keycloak read-only 与 tmpfs 冲突:** Keycloak 需要写入数据到多个目录，不能直接使用 findclass-ssr 的安全配置

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 蓝绿容器管理 | 新的管理脚本 | manage-containers.sh 参数化 | 已验证 8 个子命令，参数化已支持多服务 |
| 流量切换 | 自定义 nginx API | update_upstream + reload_nginx 函数 | 已在 findclass-ssr 和 noda-site 验证 |
| 健康检查轮询 | 自定义 wait 循环 | wait_container_healthy（health.sh） | 统一的健康检查库，支持 Docker health state 轮询 |
| E2E 验证 | 自定义 curl 检查 | e2e_verify 函数 | 已支持 curl/wget 自动切换 |
| 部署前备份检查 | 新的备份检查 | check_backup_freshness | 已在 pipeline-stages.sh 实现 |

**Key insight:** v1.4 已建立完整的蓝绿部署框架，Phase 28 的核心工作是"参数化适配"而非"重新构建"。主要工程量在解决 Keycloak 特有的差异（健康检查端口、安全配置、env 变量模板）。

## Common Pitfalls

### Pitfall 1: Keycloak 健康检查端口问题（高风险）
**What goes wrong:** 设置 `KC_HEALTH_ENABLED=true` 后，`/health/ready` 端点可能不在应用端口 8080 上，而在管理端口 9000 上
**Why it happens:** Keycloak 26.x（Quarkus）默认启用管理接口时，健康端点从应用端口移到管理端口（9000）。项目当前 compose 中使用 TCP 8080 检查而非 HTTP 端点
**How to avoid:**
- 方案 A（推荐）：使用 TCP 端口 8080 检查 `echo > /dev/tcp/localhost/8080`（当前 compose 方式）
- 方案 B：明确设置 `KC_HTTP_MANAGEMENT_PORT=9000` 并在健康检查中使用 9000 端口访问 `/health/ready`
- 方案 C：禁用管理接口，让健康端点留在 8080（需验证 Keycloak 26 是否支持）
**Warning signs:** 健康检查超时或 404 错误
**Confidence:** MEDIUM — 基于训练数据，需在实现时验证 [ASSUMED]

### Pitfall 2: init 迁移时 compose 容器名不匹配（中风险）
**What goes wrong:** `cmd_init` 检测 compose 容器名 `keycloak`（SERVICE_NAME），但实际 compose 容器名是 `noda-infra-keycloak-prod`
**Why it happens:** docker-compose.yml 中设置了 `container_name: noda-infra-keycloak-prod`，而 manage-containers.sh 的 init 检测使用 SERVICE_NAME（默认 keycloak）
**How to avoid:** init 子命令需要先检查 `noda-infra-keycloak-prod`，回退检查 `keycloak`
**Warning signs:** init 报告"未找到 compose 容器"但容器实际存在
**Confidence:** HIGH — 已通过代码审查确认 [VERIFIED: docker-compose.yml L109]

### Pitfall 3: Keycloak 启动时间较长（中风险）
**What goes wrong:** 健康检查超时，因为 Keycloak 启动需要 30-60 秒（加载 realm、建立 DB 连接）
**Why it happens:** Keycloak 启动比 findclass-ssr 慢得多，当前 start_period=60s 在 compose 中已配置
**How to avoid:** 蓝绿容器健康检查的 start_period 至少 90s，总超时至少 180s
**Warning signs:** 容器日志显示 "Listening on: http://0.0.0.0:8080" 但 health check 仍失败
**Confidence:** HIGH — compose 中已配置 start_period=60s [VERIFIED: docker-compose.prod.yml L106]

### Pitfall 4: env-keycloak.env 中的变量替换安全性（中风险）
**What goes wrong:** `envsubst` 替换过多变量，可能替换 Keycloak 配置值中的 `$` 符号
**Why it happens:** findclass-ssr 只替换 3 个变量（POSTGRES_USER, POSTGRES_PASSWORD, RESEND_API_KEY），但 Keycloak 有更多敏感变量（SMTP_PASSWORD, KEYCLOAK_ADMIN_PASSWORD）
**How to avoid:** `envsubst` 明确列出所有需要替换的变量名，不使用无参数 `envsubst`
**Warning signs:** 容器启动失败，环境变量包含空值或原始 `${VAR}` 字符串
**Confidence:** HIGH — 已在 findclass-ssr 中验证此模式 [VERIFIED: manage-containers.sh L109]

### Pitfall 5: nginx upstream 切换后会话丢失（已知风险）
**What goes wrong:** 蓝绿切换后用户被登出
**Why it happens:** Keycloak 会话存储在 JVM 内存（Infinispan local cache），不在数据库中。切换到新容器后内存中的会话全部丢失
**How to avoid:** 在维护窗口执行 Keycloak 蓝绿切换；STATE.md 已记录此风险
**Warning signs:** 切换后大量用户报告需要重新登录
**Confidence:** HIGH — STATE.md 已记录 [VERIFIED: .planning/STATE.md L76]

### Pitfall 6: docker run 缺少 compose 的网络别名（低风险）
**What goes wrong:** 其他服务（findclass-ssr）通过 `keycloak` 主机名连接 Keycloak，但 docker run 审计的容器名是 `keycloak-blue` 或 `keycloak-green`
**What goes wrong:** `env-findclass-ssr.env` 中 `KEYCLOAK_INTERNAL_URL=http://noda-infra-keycloak-prod:8080` 硬编码了旧容器名
**How to avoid:** 方案 A：docker run 添加 `--network-alias keycloak`；方案 B：findclass-ssr 通过 nginx 代理访问 Keycloak；方案 C：更新 env 中的内部 URL 指向蓝绿容器
**Confidence:** HIGH — 已在 env-findclass-ssr.env 确认 [VERIFIED: docker/env-findclass-ssr.env L9]

### Pitfall 7: deploy-infrastructure-prod.sh 与蓝绿管理冲突（低风险）
**What goes wrong:** deploy-infrastructure-prod.sh 仍尝试通过 `docker compose up keycloak` 启动 Keycloak，与蓝绿 docker run 容器冲突
**Why it happens:** 蓝绿迁移后 compose 中的 keycloak 服务仍存在
**How to avoid:** 从 START_SERVICES 中移除 keycloak；或 compose 中 keycloak 服务添加 profiles: [compose-only]
**Confidence:** HIGH — 已确认 START_SERVICES 包含 keycloak [VERIFIED: deploy-infrastructure-prod.sh L53]

## Code Examples

### Keycloak 蓝绿容器启动参数
```bash
# Source: 基于 manage-containers.sh run_container + docker-compose.prod.yml Keycloak 配置
# 关键差异：更高内存、主题卷挂载、HTTP 健康检查、非 read-only

# Keycloak 特有参数（需要覆盖 run_container 默认值）
SERVICE_NAME=keycloak
SERVICE_PORT=8080
UPSTREAM_NAME=keycloak_backend
HEALTH_PATH="/health/ready"  # 或使用 TCP 检查
ACTIVE_ENV_FILE=/opt/noda/active-env-keycloak
UPSTREAM_CONF="$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf"

# run_container 已有的参数中需要调整的：
# --memory 512m → 1g（Keycloak 需要更多内存）
# --memory-reservation 128m → 512m
# --read-only → 移除（Keycloak 需要写入临时文件）
# 添加 --tmpfs /opt/keycloak/data（Keycloak 数据目录）
# 添加 -v themes:/opt/keycloak/themes/noda:ro（自定义主题）
```

### env-keycloak.env 模板内容（预期）
```bash
# Source: 从 docker-compose.yml L114-131 + docker-compose.prod.yml L63-89 提取
# ${VAR} 格式的变量由 envsubst 替换

# 数据库配置
KC_DB=postgres
KC_DB_URL=jdbc:postgresql://noda-infra-postgres-prod:5432/keycloak
KC_DB_USERNAME=${POSTGRES_USER}
KC_DB_PASSWORD=${POSTGRES_PASSWORD}

# 主机名配置
KC_HOSTNAME=https://auth.noda.co.nz
KC_HOSTNAME_STRICT=false
KC_HTTP_ENABLED=true
KC_PROXY=edge
KC_PROXY_HEADERS=xforwarded
KC_FRONTEND_URL=https://auth.noda.co.nz

# 健康检查
KC_HEALTH_ENABLED=true

# 管理员账号
KEYCLOAK_ADMIN=${KEYCLOAK_ADMIN_USER}
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}

# SMTP 配置
KC_MAIL_HOST=${SMTP_HOST}
KC_MAIL_PORT=${SMTP_PORT}
KC_MAIL_FROM=${SMTP_FROM}
KC_MAIL_FROM_DISPLAY_NAME=Noda
KC_SMTP_AUTH=true
KC_SMTP_USER=${SMTP_USER}
KC_SMTP_PASSWORD=${SMTP_PASSWORD}
KC_SMTP_SSL=false
KC_SMTP_STARTTLS=true
```

### upstream-keycloak.conf 蓝绿格式
```nginx
# 当前（compose 单容器）:
upstream keycloak_backend {
    server keycloak:8080 max_fails=3 fail_timeout=30s;
}

# 蓝绿（与 upstream-findclass.conf 格式一致）:
upstream keycloak_backend {
    server keycloak-blue:8080 max_fails=3 fail_timeout=30s;
}
```

### Jenkinsfile.keycloak 结构（7 阶段）
```groovy
// Source: 基于 Jenkinsfile（findclass-ssr）简化，移除 Build/Test 阶段
pipeline {
    agent any
    environment {
        PROJECT_ROOT = "${WORKSPACE}"
        SERVICE_NAME = "keycloak"
        ACTIVE_ENV = sh(script: 'cat /opt/noda/active-env-keycloak 2>/dev/null || echo blue', returnStdout: true).trim()
        TARGET_ENV = "${env.ACTIVE_ENV == 'blue' ? 'green' : 'blue'}"
    }
    // 7 阶段：Pre-flight -> Pull Image -> Deploy -> Health Check -> Switch -> Verify -> Cleanup
    // 注意：无 Build（官方镜像）、无 Test（无需测试）、有 CDN Purge（auth.noda.co.nz 缓存）
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Docker Compose 管理 Keycloak | docker run 蓝绿管理 | Phase 28 | 需要从 compose 迁移，compose 中 keycloak 服务保留但不主动使用 |
| TCP 8080 健康检查 | HTTP /health/ready | Phase 28 | 更准确反映服务就绪，但需验证端口可用性 |
| 单容器 nginx upstream | 蓝绿切换 upstream | Phase 28 | 零停机部署能力 |

**Deprecated/outdated:**
- `KC_HOSTNAME_PORT`、`KC_HOSTNAME_STRICT_HTTPS`（v1 废弃选项，不要使用）[VERIFIED: CLAUDE.md]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Keycloak 26.2.3 在 `start` 模式下 `/health/ready` 在 8080 端口可用 | Pitfall 1, Architecture | 需改用 TCP 检查或管理端口 9000 |
| A2 | manage-containers.sh 的 `run_container` 安全参数（read-only, cap-drop ALL）可以被覆盖或参数化 | Architecture Patterns | 需修改 run_container 支持自定义安全参数 |
| A3 | Keycloak docker run 可以在非 read-only 模式下运行而不引入安全风险 | Architecture Patterns | 可能需要额外的 tmpfs 挂载 |
| A4 | compose 中 keycloak 服务的网络别名 `keycloak` 在蓝绿模式下不再需要（findclass-ssr 通过 nginx 代理访问） | Pitfall 6 | 需要添加 --network-alias keycloak |
| A5 | Jenkins Pipeline 可以直接 `docker pull quay.io/keycloak/keycloak:26.2.3` 拉取官方镜像 | Jenkins Pipeline | 需要配置 Docker Hub/Quay.io 访问权限 |

**Note:** A1 是最高风险假设，需要在 Phase 实现初期（Wave 0）验证。

## Open Questions

1. **Keycloak 健康检查端点端口**
   - What we know: compose 中当前使用 TCP 8080 检查；KC_HEALTH_ENABLED=true 已配置
   - What's unclear: `/health/ready` 在 8080 还是管理端口 9000 上可用
   - Recommendation: 实现时先用 TCP 检查（安全回退），后续可改为 HTTP 检查

2. **run_container 参数化覆盖**
   - What we know: 当前 run_container 硬编码了 read-only、memory 512m 等参数
   - What's unclear: 是否需要修改 run_container 支持参数覆盖，还是创建 Keycloak 专用函数
   - Recommendation: 创建 `run_keycloak_container` 函数或通过环境变量控制差异参数

3. **compose 中 keycloak 服务的长期处理**
   - What we know: init 后 compose 中的 keycloak 服务保留
   - What's unclear: deploy-infrastructure-prod.sh 的 START_SERVICES 是否应移除 keycloak
   - Recommendation: 从 START_SERVICES 移除 keycloak，compose 保留 keycloak 定义但不启动

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | 容器管理 | available | 29.1.3 | - |
| nginx (container) | upstream 切换 | available | 1.25-alpine | - |
| Keycloak image | 蓝绿容器 | available (quay.io) | 26.2.3 | - |
| noda-network | 容器网络 | available | Docker network | - |
| gettext (envsubst) | env 模板替换 | available (Linux) / macOS 需检查 | - | 手动替换 |
| Jenkins | Pipeline 触发 | available (server) | 2.541.3 LTS | 手动脚本回退 |
| Cloudflare API | CDN 缓存清除 | available | - | 跳过（不阻止部署） |

**Missing dependencies with no fallback:**
- 无阻塞依赖

**Missing dependencies with fallback:**
- gettext/envsubst: macOS 可能未安装，可使用 `brew install gettext`；或回退到 sed/手动替换

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell（bash 脚本直接测试） |
| Config file | 无 — 使用 docker healthcheck + nginx -t |
| Quick run command | `bash scripts/manage-containers.sh status`（验证 Keycloak 蓝绿容器状态） |
| Full suite command | `SERVICE_NAME=keycloak SERVICE_PORT=8080 bash scripts/manage-containers.sh status && docker exec noda-infra-nginx nginx -t` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| KCBLUE-01 | env-keycloak.env 模板和状态文件存在 | manual-only | `test -f docker/env-keycloak.env && test -f /opt/noda/active-env-keycloak` | Wave 0 创建 |
| KCBLUE-02 | upstream-keycloak.conf 蓝绿格式 | unit | `docker exec noda-infra-nginx nginx -t` | existing file, modified |
| KCBLUE-03 | manage-containers.sh 支持 Keycloak | integration | `SERVICE_NAME=keycloak SERVICE_PORT=8080 UPSTREAM_NAME=keycloak_backend bash scripts/manage-containers.sh status` | existing file |
| KCBLUE-04 | Keycloak 迁移到 docker run 管理 | integration | `docker ps --filter name=keycloak-blue --format '{{.Names}}'` | Wave 0 |

### Sampling Rate
- **Per task commit:** `docker exec noda-infra-nginx nginx -t`
- **Per wave merge:** `SERVICE_NAME=keycloak bash scripts/manage-containers.sh status`
- **Phase gate:** 完整蓝绿切换流程验证（init -> start -> switch -> verify）

### Wave 0 Gaps
- [ ] `docker/env-keycloak.env` — 环境变量模板（KCBLUE-01）
- [ ] `scripts/keycloak-blue-green-deploy.sh` — 部署脚本（KCBLUE-03/04）
- [ ] `jenkins/Jenkinsfile.keycloak` — Pipeline 配置（D-05）
- [ ] 健康检查端点验证 — 需在现有 Keycloak 容器上测试 `/health/ready`（A1 假设验证）

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Keycloak 管理（不在此 Phase 变更） |
| V3 Session Management | yes | Keycloak 会话（蓝绿切换会丢失 JVM 内存会话） |
| V4 Access Control | yes | Keycloak 管理（不在此 Phase 变更） |
| V5 Input Validation | yes | envsubst 明确变量列表 |
| V6 Cryptography | yes | KC_PROXY=edge + KC_PROXY_HEADERS=xforwarded（不在此 Phase 变更） |

### Known Threat Patterns for Docker Blue-Green

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 容器逃逸 | Elevation of Privilege | --security-opt no-new-privileges, --cap-drop ALL |
| 环境变量泄露 | Information Disclosure | envsubst 只替换指定变量，临时 env 文件用后删除 |
| 镜像篡改 | Tampering | 使用官方镜像 quay.io/keycloak/keycloak:26.2.3，不修改 |
| 未授权部署 | Spoofing | Jenkins 手动触发，disableConcurrentBuilds |

## Sources

### Primary (HIGH confidence)
- `scripts/manage-containers.sh` — 蓝绿容器管理脚本，8 子命令参数化设计
- `scripts/blue-green-deploy.sh` — findclass-ssr 部署脚本，7 步流程
- `scripts/pipeline-stages.sh` — Pipeline 阶段函数库
- `docker/docker-compose.yml` — Keycloak 基础服务定义（L107-143）
- `docker/docker-compose.prod.yml` — Keycloak 生产配置（L57-109）
- `config/nginx/snippets/upstream-keycloak.conf` — 当前 upstream 配置
- `config/nginx/snippets/upstream-findclass.conf` — 蓝绿 upstream 参考
- `config/nginx/conf.d/default.conf` — nginx 主配置
- `jenkins/Jenkinsfile` — findclass-ssr Pipeline 结构
- `docker/env-findclass-ssr.env` — env 模板参考格式
- `scripts/deploy/deploy-infrastructure-prod.sh` — 基础设施部署脚本
- `scripts/lib/health.sh` — 容器健康检查库
- `.planning/phases/28-keycloak/28-CONTEXT.md` — 用户决策
- `.planning/REQUIREMENTS.md` — KCBLUE-01 到 KCBLUE-04
- `.planning/STATE.md` — 项目状态和已知风险

### Secondary (MEDIUM confidence)
- Keycloak 26.x Quarkus 健康端点行为 — 基于训练数据 [ASSUMED，需验证]

### Tertiary (LOW confidence)
- Keycloak 管理端口 9000 默认行为 — 基于训练数据，未在项目环境中验证

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 全部基于已验证的代码库
- Architecture: HIGH — 复用已验证的蓝绿框架
- Pitfalls: MEDIUM — Keycloak 健康检查端口未在运行环境验证
- Security: HIGH — 沿用已验证的安全配置模式

**Research date:** 2026-04-17
**Valid until:** 2026-05-17（30 天，稳定基础设施）
