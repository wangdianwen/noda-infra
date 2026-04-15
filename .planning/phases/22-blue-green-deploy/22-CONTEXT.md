# Phase 22: 蓝绿部署核心流程 - Context

**Gathered:** 2026-04-15
**Status:** Ready for planning

<domain>
## Phase Boundary

管理员可通过脚本执行完整的蓝绿部署流程：构建新镜像 → 启动目标容器 → 健康检查 → 切换流量 → E2E 验证。以及紧急手动回滚脚本。

范围包括：
- 蓝绿部署主脚本 `blue-green-deploy.sh`（构建 + 启动 + 健康检查 + 切换 + 验证）
- 紧急回滚脚本 `rollback-findclass.sh`（切回上一活跃容器）
- 镜像标签管理（Git SHA 短哈希标签）
- 健康检查（HTTP 直检）+ E2E 验证（nginx 链路验证）
- 部署失败自动防护（不切换、不停旧）

</domain>

<decisions>
## Implementation Decisions

### 健康检查策略
- **D-01:** 部署脚本使用 **HTTP 直检** — 通过 `docker exec` 在目标容器内部执行 wget/curl 检测 `http://localhost:3001/api/health`
- **D-02:** 不复用 `wait_container_healthy()`（Docker inspect healthcheck），部署脚本有独立的 HTTP 检查逻辑，超时参数更灵活（建议 120 秒，30 次 x 4 秒，覆盖 SSR 冷启动）
- **D-03:** Docker healthcheck（Phase 21 配置的 `--health-cmd wget`）作为容器长期监控，与部署脚本的 HTTP 直检是两套独立机制

### 脚本接口与参数设计
- **D-04:** 目标环境**自动检测** — 脚本读取 `/opt/noda/active-env` 获取当前活跃环境，自动部署到非活跃侧。用户无需记住当前是 blue 还是 green
- **D-05:** **当前目录构建** — 脚本在 noda-apps 代码目录执行，从 `.git` 获取 SHA。脚本参数只需项目根目录路径（用于定位 manage-containers.sh 和 nginx 配置）
- **D-06:** 通过 **source 复用** `manage-containers.sh` 的函数（`run_container()`, `update_upstream()`, `reload_nginx()`, `get_active_env()`, `get_inactive_env()`），不通过子命令调用

### 回滚脚本设计
- **D-07:** `rollback-findclass.sh` 执行**切回上一容器** — 检查上一次活跃环境的容器是否还在运行，如果是则立即切换流量回该容器
- **D-08:** 回滚流程：验证旧容器运行中 → 更新 upstream → reload nginx → 更新 active-env → 停止新版本容器
- **D-09:** 旧镜像保留策略：**保留最近 N 个**带标签的镜像。N 的具体值由实现决定（建议 5）。Phase 24 会提供更完善的清理脚本

### 构建与镜像管理
- **D-10:** 镜像标签使用 **Git SHA 短哈希 7 字符**（如 `findclass-ssr:abc1234`），通过 `git rev-parse --short HEAD` 获取
- **D-11:** 构建命令使用 **docker compose build**（`docker compose -f docker/docker-compose.app.yml build findclass-ssr`），构建后用 `docker tag` 添加 SHA 标签
- **D-12:** 构建失败时脚本立即中止（`set -e` 自然行为），不进入部署阶段

### Claude's Discretion
- HTTP 健康检查的具体实现细节（重试间隔、超时参数、失败日志输出）
- E2E 验证的 curl 端点和判断逻辑（通过 nginx 容器 curl 目标容器 vs 通过外部 URL curl）
- 保留镜像数量 N 的默认值
- 脚本的步骤日志格式和进度输出
- rollback-findclass.sh 的参数设计（无参数一键回滚 vs 指定环境回滚）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 21 产出（直接依赖）
- `scripts/manage-containers.sh` — 蓝绿容器管理脚本，提供 source 复用的函数（run_container, update_upstream, reload_nginx, get_active_env, get_inactive_env）
- `docker/env-findclass-ssr.env` — 环境变量模板文件
- `config/nginx/snippets/upstream-findclass.conf` — nginx upstream 定义文件

### 脚本参考
- `scripts/lib/log.sh` — 结构化日志库（所有脚本复用）
- `scripts/lib/health.sh` — wait_container_healthy() 函数（部署脚本不复用，但参考其模式）
- `scripts/deploy/deploy-apps-prod.sh` — 现有部署脚本模式（保存镜像标签 + 构建 + 部署 + 回滚）

### Docker 配置
- `docker/docker-compose.app.yml` — findclass-ssr 构建配置（Dockerfile 路径、build args）
- `deploy/Dockerfile.findclass-ssr` — findclass-ssr Dockerfile
- `docker/docker-compose.yml` — noda-network 外部网络定义

### 需求文档
- `.planning/REQUIREMENTS.md` — PIPE-02, PIPE-03, TEST-03, TEST-04, TEST-05 需求定义
- `.planning/ROADMAP.md` Phase 22 — 成功标准
- `.planning/phases/21-blue-green-containers/21-CONTEXT.md` — Phase 21 决策（source 复用接口、容器命名、状态文件）

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/manage-containers.sh:117` — `run_container(env, image)` 函数，启动蓝绿容器的完整逻辑（docker run + 所有安全参数 + 环境变量）
- `scripts/manage-containers.sh:164` — `update_upstream(env)` 函数，原子更新 nginx upstream 配置文件
- `scripts/manage-containers.sh:182` — `reload_nginx()` 函数，重载 nginx 配置
- `scripts/manage-containers.sh:44` — `get_active_env()` / `get_inactive_env()` 函数
- `scripts/manage-containers.sh:449` — `cmd_switch()` 子命令，流量切换完整流程（含 nginx -t 验证）

### Established Patterns
- 单脚本多子命令模式：`setup-jenkins.sh`（Phase 19）和 `manage-containers.sh`（Phase 21）
- 严格模式：`set -euo pipefail`
- 日志统一：`source scripts/lib/log.sh`
- 镜像回滚：`deploy-apps-prod.sh` 中 save/rollback 函数模式

### Integration Points
- Phase 23 Jenkins Pipeline 通过 `sh` 步骤调用 `blue-green-deploy.sh`
- `docker-compose.app.yml` 仍然用于 `docker compose build`（仅构建，不运行容器）
- 构建后需要 `docker tag` 添加 SHA 标签（docker compose build 默认使用 compose 文件中的 image 名）

</code_context>

<specifics>
## Specific Ideas

- 部署脚本核心流程：构建 → tag → 停止旧目标容器 → 启动新目标容器 → HTTP 健康检查 → 切换流量 → E2E 验证 → 停止旧活跃容器（可选）
- 回滚脚本核心流程：检查旧活跃容器 → 验证健康 → 切换 upstream → reload → 更新 active-env
- E2E 验证需要通过 nginx 链路（可能通过 nginx 容器 curl 目标容器名，验证完整请求路径）
- 保留旧活跃容器一段时间（不立即停止），方便紧急回滚

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 22-blue-green-deploy*
*Context gathered: 2026-04-15*
