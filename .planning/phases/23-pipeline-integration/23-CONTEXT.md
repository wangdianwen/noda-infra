# Phase 23: Pipeline 集成与测试门禁 - Context

**Gathered:** 2026-04-15
**Status:** Ready for planning

<domain>
## Phase Boundary

管理员可在 Jenkins 中手动触发 Pipeline，自动执行 lint + 单元测试 + 蓝绿部署全流程，构建日志在失败时自动归档。

范围包括：
- Jenkinsfile 八阶段 Declarative Pipeline（Pre-flight → Build → Test → Deploy → Health Check → Switch → Verify → Cleanup）
- noda-apps 仓库 Git 配置与代码拉取
- lint/test 质量门禁（pnpm lint + pnpm test）
- 失败时日志归档（构建日志 + 容器日志）
- 手动触发配置

</domain>

<decisions>
## Implementation Decisions

### Jenkinsfile 位置与存储
- **D-01:** Jenkinsfile 放在 **noda-infra 仓库**作为独立文件（路径建议 `jenkins/Jenkinsfile`），通过更新 Phase 19 的 `03-pipeline-job.groovy` 引用该文件路径
- **D-02:** Jenkinsfile 使用 **Declarative Pipeline** 语法（非 Scripted），与 CLAUDE.md 中"不使用 Scripted Pipeline"决策一致

### Pipeline 阶段粒度
- **D-03:** 采用 **8 阶段细粒度**拆分：Pre-flight → Build → Test → Deploy → Health Check → Switch → Verify → Cleanup
- **D-04:** 每个阶段调用独立的脚本或函数，而非一次性调用 `blue-green-deploy.sh`。这意味着需要将 `blue-green-deploy.sh` 的逻辑拆分为可独立调用的阶段脚本，或者 Jenkinsfile 中直接用 `sh` 命令组合 `manage-containers.sh` 的函数
- **D-05:** Jenkins Stage View 可展示每阶段的通过/失败状态，便于定位问题

### noda-apps 代码获取
- **D-06:** Jenkins 通过 **Git SCM 插件**配置 noda-apps 仓库地址，使用 **SSH key 或 Personal Access Token** 认证
- **D-07:** Pipeline 从 noda-infra checkout Jenkinsfile 配置，再 checkout noda-apps 到子目录（如 `noda-apps/`）
- **D-08:** Git 凭据存储在 Jenkins Credentials 中，Pipeline 通过 `credentials()` 引用

### lint/test 执行环境
- **D-09:** lint 和 test **直接在 Jenkins workspace 中执行**（`pnpm lint` 和 `pnpm test`），需要在 Jenkins 宿主机安装 Node.js + pnpm
- **D-10:** lint/test 在 noda-apps 源码目录执行，复用 noda-apps 已有的 `package.json` scripts
- **D-11:** lint 或 test 不通过则 Pipeline 中止，不进入部署阶段（TEST-01, TEST-02）

### 日志归档策略
- **D-12:** **仅部署失败时**归档日志，成功时不归档（减少存储占用）
- **D-13:** 归档内容包括：构建日志（Jenkins console output 自动保存）+ 失败容器的 docker logs 输出
- **D-14:** 使用 Jenkins `archiveArtifacts` 归档日志文件

### Claude's Discretion
- Jenkinsfile 各阶段具体调用哪些脚本/函数（可直接在 sh 步骤中写命令，或创建阶段包装脚本）
- noda-apps 仓库的具体 Git URL 和分支配置（planner 阶段确认）
- Node.js/pnpm 在 Jenkins 宿主机的安装方式（手动 vs 脚本化）
- 日志归档的文件名格式和保留策略

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 22 产出（直接依赖）
- `scripts/blue-green-deploy.sh` — 蓝绿部署主脚本，Phase 23 需要拆分其逻辑为独立阶段
- `scripts/manage-containers.sh` — 容器管理函数库（run_container, update_upstream, reload_nginx 等）
- `scripts/rollback-findclass.sh` — 紧急回滚脚本

### Phase 19 产出（Jenkins 基础设施）
- `scripts/jenkins/init.groovy.d/03-pipeline-job.groovy` — Pipeline 作业模板（占位 Jenkinsfile，Phase 23 需要更新为引用实际 Jenkinsfile）
- `scripts/jenkins/init.groovy.d/02-plugins.groovy` — 插件配置

### 脚本参考
- `scripts/lib/log.sh` — 结构化日志库
- `scripts/verify/verify-infrastructure.sh` — 基础设施验证脚本（Pre-flight 阶段可复用）
- `scripts/deploy/deploy-apps-prod.sh` — 现有部署脚本模式参考

### Docker 配置
- `docker/docker-compose.app.yml` — findclass-ssr 构建配置
- `deploy/Dockerfile.findclass-ssr` — findclass-ssr Dockerfile
- `config/nginx/snippets/upstream-findclass.conf` — nginx upstream 定义

### 需求文档
- `.planning/REQUIREMENTS.md` — PIPE-01, PIPE-04, PIPE-05, TEST-01, TEST-02 需求定义
- `.planning/ROADMAP.md` Phase 23 — 成功标准
- `.planning/research/FEATURES.md` — Pipeline 8 阶段详细设计草稿

### 前置阶段决策
- `.planning/phases/19-jenkins/19-CONTEXT.md` — Jenkins 端口 8888、Pipeline 作业名 noda-apps-deploy
- `.planning/phases/22-blue-green-deploy/22-CONTEXT.md` — 部署脚本接口设计、健康检查策略
- `.planning/phases/21-blue-green-containers/21-CONTEXT.md` — manage-containers.sh 函数接口

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/blue-green-deploy.sh:36-61` — `http_health_check()` 函数，Health Check 阶段可直接调用
- `scripts/blue-green-deploy.sh:72-123` — `e2e_verify()` 函数，Verify 阶段可直接调用
- `scripts/blue-green-deploy.sh:131-160` — `cleanup_old_images()` 函数，Cleanup 阶段可直接调用
- `scripts/manage-containers.sh:44-60` — `get_active_env()` / `get_inactive_env()` 函数
- `scripts/manage-containers.sh:117` — `run_container()` 函数
- `scripts/manage-containers.sh:164` — `update_upstream()` 函数
- `scripts/manage-containers.sh:182` — `reload_nginx()` 函数
- `scripts/jenkins/init.groovy.d/03-pipeline-job.groovy` — 需要更新 `configXml` 中的 script 内容为引用 Jenkinsfile 路径

### Established Patterns
- 单脚本多子命令：`setup-jenkins.sh`（Phase 19）和 `manage-containers.sh`（Phase 21）
- 严格模式：`set -euo pipefail`
- 日志统一：`source scripts/lib/log.sh`
- `blue-green-deploy.sh` 通过 `source manage-containers.sh` 复用函数

### Integration Points
- Jenkins 通过 `sh` 步骤调用 bash 脚本
- Pipeline 需要在 noda-infra 目录执行构建（docker compose build）和部署脚本
- Pipeline 需要在 noda-apps 目录执行 lint/test（pnpm lint && pnpm test）
- Jenkins workspace 需要同时包含 noda-infra 和 noda-apps 两个仓库的代码
- 8 阶段拆分意味着需要将 `blue-green-deploy.sh` 的 main() 拆为独立可调用的阶段函数

</code_context>

<specifics>
## Specific Ideas

- 8 阶段 Pipeline 与 `blue-green-deploy.sh` 的 7 步流程大致对应，但多了 Test 阶段
- Pre-flight 阶段可复用 `scripts/verify/verify-infrastructure.sh`
- Build 阶段：`docker compose -f docker/docker-compose.app.yml build findclass-ssr` + `docker tag`
- Test 阶段：`cd noda-apps && pnpm install && pnpm lint && pnpm test`
- Deploy 阶段：停止旧目标容器 + 启动新容器（`run_container()`）
- Health Check 阶段：`http_health_check()`
- Switch 阶段：`update_upstream()` + `reload_nginx()` + `set_active_env()`
- Verify 阶段：`e2e_verify()`
- Cleanup 阶段：`cleanup_old_images()` + 停止旧活跃容器（可选）

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 23-pipeline-integration*
*Context gathered: 2026-04-15*
