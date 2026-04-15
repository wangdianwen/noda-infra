# Phase 21: 蓝绿容器管理 - Context

**Gathered:** 2026-04-15
**Status:** Ready for planning

<domain>
## Phase Boundary

blue 和 green 两个 findclass-ssr 容器可以独立启停，通过状态文件追踪当前活跃环境。容器通过 `docker run` 管理生命周期（不通过 docker-compose.yml），nginx 通过容器名 DNS 解析访问。

范围包括：
- 蓝绿容器管理脚本（完整运维工具集）
- 状态文件 `/opt/noda/active-env` 初始化与管理
- 独立环境变量文件 `docker/env-findclass-ssr.env`
- 从当前单容器到蓝绿架构的自动迁移
- Docker 网络和标签配置

</domain>

<decisions>
## Implementation Decisions

### 管理脚本结构
- **D-01:** 单脚本 `manage-containers.sh` 多子命令模式，与 `setup-jenkins.sh` 风格一致
- **D-02:** 子命令包含完整运维工具集：start、stop、status、init、restart、logs 等（7+ 个子命令）
- **D-03:** Phase 22 部署脚本通过 shell source 调用内部函数，复用启动/停止逻辑

### 环境变量管理
- **D-04:** 创建独立 `docker/env-findclass-ssr.env` 文件，包含所有 findclass-ssr 需要的环境变量
- **D-05:** 管理脚本通过 `docker run --env-file` 传递变量，变量值中的 `${VAR}` 语法由脚本解析填充
- **D-06:** 环境变量与 docker-compose.app.yml 中的定义保持一致（NODE_ENV、DATABASE_URL、KEYCLOAK_*、RESEND_API_KEY）

### 初始迁移策略
- **D-07:** `init` 子命令自动执行完整迁移流程：
  1. 检测当前 compose 管理的 findclass-ssr 容器
  2. 停止 compose 容器
  3. 用 docker run 启动 blue 容器（使用相同镜像）
  4. 更新 nginx upstream 指向 `findclass-ssr-blue:3001`
  5. 写入 `/opt/noda/active-env` 初始值 `blue`

### 容器命名与标签
- **D-08:** 容器名：`findclass-ssr-blue` / `findclass-ssr-green`（与 Phase 20 upstream 切换目标一致）
- **D-09:** 保留现有标签 `noda.service-group=apps` + `noda.environment=prod`，新增 `noda.blue-green=blue/green`
- **D-10:** 容器安全配置沿用 docker-compose.app.yml 中的配置：no-new-privileges、cap_drop:ALL、read_only、tmpfs /tmp、资源限制 512M/1CPU
- **D-11:** 日志配置沿用：json-file driver、max-size 10m、max-file 3
- **D-12:** restart 策略：unless-stopped（与 compose 一致）

### Claude's Discretion
- 环境变量文件中具体哪些变量需要动态替换（如 `${POSTGRES_USER}`）vs 硬编码
- 子命令的参数设计细节（如 start 是否需要指定镜像标签）
- init 迁移时的错误恢复机制
- status 子命令的输出格式

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 20 产出（直接依赖）
- `config/nginx/snippets/upstream-findclass.conf` — nginx upstream 定义，Phase 21 的 init 需要修改此文件内容
- `config/nginx/conf.d/default.conf` — server 块中引用 upstream，验证修改后配置正确

### Docker 配置
- `docker/docker-compose.app.yml` — findclass-ssr 当前配置（环境变量、安全配置、资源限制的基准）
- `docker/docker-compose.yml` — noda-network 外部网络定义

### 脚本参考
- `scripts/lib/log.sh` — 结构化日志库（所有脚本复用）
- `scripts/lib/health.sh` — wait_container_healthy() 函数，可用于容器启动后健康检查
- `scripts/setup/setup-jenkins.sh` — 单脚本多子命令模式参考（Phase 19 产出）
- `scripts/deploy/deploy-apps-prod.sh` — 现有部署脚本模式参考

### 需求文档
- `.planning/REQUIREMENTS.md` — BLUE-01、BLUE-03、BLUE-04、BLUE-05 需求定义
- `.planning/ROADMAP.md` Phase 21 — 成功标准
- `.planning/phases/20-nginx/20-CONTEXT.md` — Phase 20 决策，特别是 upstream 切换接口

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/lib/health.sh:16` — `wait_container_healthy()` 函数，可直接用于 start 子命令后等待容器健康
- `scripts/lib/log.sh` — log_info/log_success/log_error/log_warn，所有脚本统一使用
- `config/nginx/snippets/upstream-findclass.conf` — 当前内容 `server findclass-ssr:3001`，init 时需要改为 `findclass-ssr-blue:3001`
- `docker/docker-compose.app.yml` — findclass-ssr 完整配置定义，docker run 参数的参考来源

### Established Patterns
- 单脚本多子命令：`setup-jenkins.sh` 提供 7 个子命令，使用 case 语句路由
- 严格模式：所有脚本 `set -euo pipefail`
- 日志统一：`source scripts/lib/log.sh`
- Docker Compose 项目分离：noda-infra（基础设施）+ noda-apps（应用），共享 noda-network

### Integration Points
- Phase 22 的 `blue-green-deploy.sh` 将调用 `manage-containers.sh` 的 start/stop 功能
- Phase 22 的 nginx 切换将复用 init 中修改 upstream-findclass.conf 的逻辑
- Phase 23 Jenkins Pipeline 通过 `sh` 步骤调用管理脚本
- docker-compose.app.yml 仍然用于 `docker compose build`（仅构建，不运行蓝绿容器）

</code_context>

<specifics>
## Specific Ideas

- 容器名使用 `findclass-ssr-blue` 和 `findclass-ssr-green`，与 nginx upstream 切换目标保持一致（Phase 20 CONTEXT.md D-01）
- docker-compose.app.yml 保留用于构建镜像（`docker compose build findclass-ssr`），但不再用于运行生产容器
- noda-network 是 external 网络，docker run 启动的容器需要通过 `--network noda-network` 加入
- init 迁移时需要 `docker exec nginx nginx -s reload` 使新 upstream 配置生效

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 21-blue-green-containers*
*Context gathered: 2026-04-15*
