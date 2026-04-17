# Phase 28: Keycloak 蓝绿部署基础设施 - Context

**Gathered:** 2026-04-17
**Status:** Ready for planning (auto mode)

<domain>
## Phase Boundary

将 Keycloak 服务从 Docker Compose 单容器管理迁移到蓝绿双容器模式，通过 nginx upstream 切换实现零停机部署。复用已有的 findclass-ssr 蓝绿部署框架（manage-containers.sh + blue-green-deploy.sh），参数化适配 Keycloak 特性。

范围包括：
- 创建 Keycloak 蓝绿容器管理（manage-containers.sh 参数化复用或 Keycloak 特化配置）
- 创建 Keycloak 蓝绿部署脚本（blue-green-deploy.sh 模式）
- 更新 nginx upstream-keycloak.conf 支持蓝绿切换
- 创建 Keycloak 环境变量模板（env-keycloak.env）
- 创建 Keycloak 蓝绿 Jenkins Pipeline
- 从 docker-compose.yml/prod.yml 迁移 Keycloak 到蓝绿模式（init 子命令）

范围不包括：
- Keycloak 版本升级（保持 26.2.3）
- Keycloak 配置变更（realm/client/IdP 不动）
- findclass-ssr 蓝绿部署变更（已有的不动）
- 数据库变更（共享 keycloak 数据库）
- 其他基础设施服务的蓝绿部署（Phase 29 统一 Pipeline）

</domain>

<decisions>
## Implementation Decisions

### Keycloak 健康检查
- **D-01:** Keycloak 蓝绿容器使用 **HTTP 端点检查** `/health/ready`
  - Keycloak 26.x 启用 `KC_HEALTH_ENABLED: "true"` 后提供 `/health/ready` 和 `/health/live` 端点
  - 比 TCP 端口检查更准确反映服务就绪状态（数据库连接、realm 加载完成）
  - 健康检查命令：`wget --spider -q http://localhost:8080/health/ready`
  - 需要确认 Keycloak 26.2.3 在 start 模式下 health endpoint 的可用性

### 环境变量传递
- **D-02:** 创建 **env-keycloak.env 模板文件**，包含所有 Keycloak 环境变量
  - 与 findclass-ssr 的 env-findclass-ssr.env 模板保持一致
  - 包含：KC_DB, KC_DB_URL, KC_HOSTNAME, KC_PROXY, SMTP 配置, 管理员凭据等
  - docker run 通过 `--env-file` 加载
  - 敏感信息（密码）仍通过 .env 文件引用 `${VAR}` 格式

### 迁移策略
- **D-03:** 使用 **manage-containers.sh init** 子命令模式从 compose 迁移到蓝绿
  - 与 findclass-ssr 迁移模式一致：stop compose 容器 → start blue 容器 → update upstream → reload nginx
  - init 时自动检测 compose 管理的 keycloak 容器，确认停止后再启动 blue
  - 迁移前确保 compose 配置中 keycloak 服务可用作回退
  - init 后 compose 中的 keycloak 服务应保留但标记为不再主动使用

### 部署脚本复用
- **D-04:** **复用 manage-containers.sh（通过环境变量参数化）+ 新建 keycloak-blue-green-deploy.sh**
  - manage-containers.sh 已支持 SERVICE_NAME/SERVICE_PORT/UPSTREAM_NAME 等环境变量
  - Keycloak 参数：SERVICE_NAME=keycloak, SERVICE_PORT=8080, UPSTREAM_NAME=keycloak_backend
  - 状态文件：`/opt/noda/active-env-keycloak`（独立于 findclass-ssr）
  - 新建 keycloak-blue-green-deploy.sh 专门处理 Keycloak 部署流程（类似 blue-green-deploy.sh）

### Jenkins Pipeline
- **D-05:** 创建 **独立 Jenkinsfile.keycloak** 用于 Keycloak 蓝绿部署
  - 参考 Jenkinsfile（findclass-ssr）的 9 阶段结构
  - 手动触发（与 findclass-ssr 一致）
  - 阶段：Pre-flight → Pull Image → Deploy → Health Check → Switch → Verify → Cleanup
  - 不需要 Build/Test 阶段（Keycloak 使用官方镜像，不从源码构建）
  - 需要 CDN Purge（auth.noda.co.nz 缓存）

### nginx 配置
- **D-06:** 更新 **upstream-keycloak.conf** 支持蓝绿切换
  - 当前：`server keycloak:8080`（Docker 网络别名）
  - 蓝绿：`server keycloak-blue:8080` 或 `server keycloak-green:8080`
  - 切换方式与 findclass_backend 一致：原子写入 → nginx -t → reload
  - 主配置 default.conf 中已有 `include snippets/upstream-keycloak.conf`

### 数据库共享
- **D-07:** 蓝绿两个 Keycloak 容器 **共享同一个 keycloak 数据库**
  - 不会同时运行两个容器（蓝绿切换是原子操作）
  - 不需要数据库复制或分片
  - 同一 Keycloak 版本（26.2.3），不涉及 schema 迁移
  - Keycloak 启动时会自动检查并锁定数据库（通过 DB lock 机制）

### Claude's Discretion
- 具体的 env-keycloak.env 模板变量列表和默认值
- health endpoint 的重试次数和超时参数
- init 子命令的具体交互流程（是否需要确认提示）
- Jenkinsfile.keycloak 的具体环境变量配置
- 清理旧镜像的保留策略

### Folded Todos
无待办事项可合并。

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 需求文档
- `.planning/ROADMAP.md` §Phase 28 — 成功标准和验收条件（KCBLUE-01 至 KCBLUE-04）

### 前序 Phase 决策
- `.planning/phases/20-nginx/20-CONTEXT.md` — Nginx upstream include 模式决策
- `.planning/phases/21-blue-green-containers/21-CONTEXT.md` — 蓝绿容器管理决策（容器命名、状态文件、docker run 生命周期）
- `.planning/phases/22-blue-green-deploy/22-CONTEXT.md` — 蓝绿部署核心流程决策（健康检查、自动回滚、目标环境检测）
- `.planning/phases/27-docker-compose/27-CONTEXT.md` — Docker Compose 简化决策（dev 容器移除，Keycloak 仍保留在 compose）

### 现有代码参考
- `scripts/manage-containers.sh` — 蓝绿容器管理脚本（8 子命令，SERVICE_NAME 等环境变量参数化）
- `scripts/blue-green-deploy.sh` — findclass-ssr 蓝绿部署脚本（7 步部署流程）
- `docker/env-findclass-ssr.env` — findclass-ssr 环境变量模板（Keycloak 模板参考）
- `config/nginx/snippets/upstream-keycloak.conf` — 当前 Keycloak upstream 配置
- `config/nginx/snippets/upstream-findclass.conf` — findclass-ssr 蓝绿 upstream 参考
- `config/nginx/conf.d/default.conf` — nginx 主配置（upstream include 引用）
- `docker/docker-compose.yml` — Keycloak 基础服务定义（环境变量参考）
- `docker/docker-compose.prod.yml` — Keycloak 生产 overlay（安全配置、资源限制参考）
- `jenkins/Jenkinsfile` — findclass-ssr 蓝绿 Pipeline（阶段结构参考）
- `scripts/pipeline-stages.sh` — Pipeline 阶段函数库
- `scripts/deploy/deploy-infrastructure-prod.sh` — 基础设施部署脚本（Keycloak 当前部署方式）

### 项目文档
- `.planning/PROJECT.md` — v1.5 目标、架构、Out of Scope
- `.planning/STATE.md` — 当前进度和 Blockers/Concerns

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/manage-containers.sh` — 已支持 SERVICE_NAME/SERVICE_PORT/UPSTREAM_NAME 环境变量参数化，可直接复用
- `scripts/blue-green-deploy.sh` — 7 步部署流程可作为 Keycloak 部署脚本模板
- `docker/env-findclass-ssr.env` — 环境变量模板格式参考
- `config/nginx/snippets/upstream-keycloak.conf` — 已存在，仅需改为蓝绿格式
- `jenkins/Jenkinsfile` + `scripts/pipeline-stages.sh` — Pipeline 结构和阶段函数可复用

### Established Patterns
- Docker run 管理蓝绿容器（非 compose 管理）
- 状态文件 `/opt/noda/active-env-{service}` per-service 独立跟踪
- 原子写入 upstream conf → nginx -t → nginx -s reload 切换流量
- Health check: docker exec wget HTTP 检查（findclass-ssr 模式）
- E2E 验证: 通过 nginx 代理路径验证（findclass-ssr 模式）
- 容器安全: no-new-privileges, cap-drop ALL, read-only, tmpfs
- 容器标签: noda.blue-green={env}, noda.service-group

### Integration Points
- Keycloak 容器依赖 postgres（health condition: service_healthy）
- nginx 通过 upstream-keycloak.conf 代理所有 auth.noda.co.nz 流量
- Cloudflare Tunnel 转发到 nginx，不直接访问 Keycloak
- Jenkins 以 jenkins 用户执行 docker 命令（需要 docker 组权限）
- deploy-infrastructure-prod.sh 引用 keycloak 服务名（需同步更新）

### 风险评估
- **中风险：** 从 compose 迁移到 docker run 管理 — init 过程需要确保零停机
- **低风险：** 蓝绿容器共享数据库 — 同版本无 schema 变更
- **低风险：** nginx upstream 切换 — 已有成熟模式
- **需验证：** Keycloak 26.2.3 的 /health/ready 端点在 start 模式下是否可用
- **需验证：** manage-containers.sh 的 run_container 是否支持 Keycloak 的安全配置（capabilities, read-only）

</code_context>

<specifics>
## Specific Ideas

- Keycloak 的 docker run 参数需要包含完整的安全配置（从 docker-compose.prod.yml 提取）
- env-keycloak.env 需要包含 SMTP 配置（生产环境邮件功能）
- Keycloak 容器需要挂载自定义主题目录（/opt/keycloak/themes/noda）
- init 迁移时需要先确认 compose keycloak 容器的健康状态
- Keycloak 健康检查超时可能需要更长（start_period: 60s 在 compose 中已配置）
- Jenkins Pipeline 不需要 Build/Test 阶段，但需要 Pull Image 阶段（拉取指定版本镜像）

</specifics>

<deferred>
## Deferred Ideas

- **Keycloak 版本升级** — 超出蓝绿部署范围，需单独评估兼容性
- **Keycloak 数据库分库** — 当前共享数据库足够，无需分离
- **多服务统一蓝绿脚本** — Phase 29 统一 Pipeline 会处理
- **Keycloak 配置自动化** — realm/client 配置不在蓝绿部署范围内
- **自动触发 Pipeline** — 保持手动触发，与安全要求一致

---

*Phase: 28-keycloak*
*Context gathered: 2026-04-17 (auto mode)*
