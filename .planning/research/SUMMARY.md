# 项目研究综合摘要

**项目:** Noda Infrastructure - v1.11 Pre-Prod 验证环境
**领域:** Docker Compose + Jenkins 单服务器部署基础设施
**研究日期:** 2026-05-08
**综合置信度:** HIGH

## 执行摘要

Noda v1.11 的目标是在现有单服务器 Docker Compose 部署架构上增加 pre-prod 验证环境，作为生产上线的守门员。研究确认的核心策略是 **"共享基础设施、隔离应用层"** -- PostgreSQL、Keycloak、Nginx、Cloudflare Tunnel 保持单实例运行，仅通过新增数据库（noda_preprod）、新 Keycloak realm（noda-preprod）和独立 Nginx server blocks 实现逻辑隔离，应用层则新增独立的 pre-prod 蓝绿容器组（noda-apps-preprod-blue/green）。这种方案将内存增量控制在约 1GB，避免了独立实例方案 2GB+ 的开销。

推荐的实施路径是 **Build Once, Promote Anywhere** 模式：Jenkins 构建一次 Docker 镜像，先部署到 pre-prod 验证，验证通过后用同一个镜像 promote 到 prod，环境差异完全通过运行时环境变量（DATABASE_URL、KEYCLOAK_REALM 等）注入。这比重新构建更能保证 pre-prod 验证的就是 prod 运行的代码。

研究识别出 **8 个关键陷阱**，其中 3 个具有 HIGH 级别恢复成本：Doppler 密钥环境隔离（pre-prod 可能误连 prod 数据库）、Nginx upstream 写入防护（pre-prod 切换可能覆盖 prod 配置）、以及 Jenkins Pipeline 并发锁（两个 Pipeline 同时 reload Nginx 导致配置错乱）。这些必须在 Phase 1 和 Phase 2 中提前建立防护机制，而非事后补救。

## 关键发现

### 推荐技术栈

Pre-prod 环境不引入任何新组件，完全复用现有技术栈并通过配置扩展实现隔离。这一决策基于单服务器资源约束和现有架构成熟度。

**核心技术决策：**

- **Docker run 参数化（非 Compose overlay）：** 现有蓝绿部署基于 `manage-containers.sh` + `docker run`，pre-prod 沿用同一脚本通过环境变量（SERVICE_NAME、ACTIVE_ENV_FILE、UPSTREAM_CONF）区分环境
- **PostgreSQL 同实例新数据库：** 新增 `noda_preprod` 数据库到现有 PostgreSQL 17.9 实例，避免额外 300MB 内存开销
- **Keycloak 同实例新 Realm：** 新增 `noda-preprod` realm 到现有 Keycloak 26.2.3 实例，避免额外 1GB 内存开销
- **Nginx 独立配置文件：** 新建 `conf.d/preprod.conf`（4 个 server block）+ `snippets/upstream-findclass-preprod.conf`，通过 `include *.conf` 自动加载
- **Jenkins 双 Pipeline：** 独立的 `Jenkinsfile.noda-apps-preprod`（部署到 pre-prod）和 `Jenkinsfile.noda-apps-promote`（promote 到 prod），与现有 prod Pipeline 并行
- **Cloudflare Dashboard 配置：** 添加 3 个 CNAME 记录 + Tunnel ingress 规则（pre.class/pre.auth/pre.noda.co.nz），实际运行在 `--token` 模式下

### 功能优先级

**必须实现（Table Stakes，P1）：**

- **Pre-Prod 蓝绿部署** -- 复用 manage-containers.sh 参数化框架，容器命名 `noda-apps-preprod-blue/green`，独立 ACTIVE_ENV_FILE
- **Build Once, Promote to Prod** -- Jenkins 构建一次镜像，pre-prod 先部署验证，通过后同一镜像 promote 到 prod
- **Pre-Prod 独立数据库** -- `noda_preprod` 数据库，验证 DB migration 不影响 prod
- **Pre-Prod 独立 Keycloak Realm** -- `noda-preprod` realm，端到端验证 OAuth 流程
- **Pre-Prod 独立域名路由** -- pre.class.noda.co.nz 等 4 个域名，Nginx + Cloudflare 路由
- **健康检查 + 自动回滚** -- 复用现有 pipeline_health_check + pipeline_failure_cleanup
- **Hotfix 紧急通道** -- SKIP_PREPROD=true 参数直接走 prod 部署，事后补验证

**建议实现（Differentiators，P2）：**

- **Promote 审批门禁** -- Jenkins `input` 步骤要求人工确认，实现成本极低但价值高
- **Git Tag 版本追踪** -- promote 成功后自动打 release tag
- **Smoke Test 自动化门禁** -- 超越 HTTP 200 检查，验证登录流程和核心 API

**推迟到 v2+（P3）：**

- **Pre-Prod 数据定期同步** -- 需要数据脱敏策略，复杂度高
- **E2E 测试套件** -- 维护成本高于收益
- **Slack/通知集成** -- Jenkins UI 查看状态已够用

### 架构方案

Pre-prod 与 prod 共享所有基础设施组件（PostgreSQL、Keycloak、Nginx、Cloudflare Tunnel），仅通过数据库级别、Realm 级别和 server block 级别实现逻辑隔离。应用层使用独立的蓝绿容器组，通过 Docker 标签（`noda.environment=preprod`）和环境变量区分。

**核心组件关系：**

1. **PostgreSQL** -- 共享实例，新增 `noda_preprod` 数据库，通过 `init-databases.sh` 扩展创建
2. **Keycloak** -- 共享实例，新增 `noda-preprod` realm + `noda-frontend-preprod` client，共享 Google OAuth
3. **Nginx** -- 共享实例，新增 4 个 pre-prod server block + 独立 upstream 变量（`$findclass_preprod_upstream` 等）
4. **应用容器** -- 独立蓝绿组，`noda-apps-preprod-blue/green`，通过运行时环境变量指向不同的数据库和 realm
5. **Jenkins** -- 3 个 Pipeline 并行（prod 直接部署、pre-prod 部署、promote），共享 `pipeline-stages.sh` 函数库
6. **Cloudflare Tunnel** -- 共享 tunnel，新增 3 个域名路由（pre.class/pre.auth/pre.noda.co.nz）

**关键数据流：**
```
浏览器 -> Cloudflare -> Nginx -> pre-prod upstream 变量 -> noda-apps-preprod-{color}:3000
  -> DATABASE_URL -> noda_preprod 数据库
  -> KEYCLOAK_REALM -> noda-preprod realm（共享 Keycloak 实例）
```

**Promote 流程：**
```
pre-prod 验证通过 -> Promote Pipeline 读取 pre-prod 镜像 digest
  -> 同一镜像部署到 prod 蓝绿 -> 环境变量切换到 prod 值
```

### 关键陷阱

1. **Doppler 密钥环境隔离** -- 当前 `secrets.sh` 硬编码 `doppler --config prd`，pre-prod 必须创建独立的 `pre` config，覆盖 DATABASE_URL 和 KEYCLOAK_* 变量。否则 pre-prod 会连接 prod 数据库。防护方案：Doppler 新建 `pre` config + 独立 service token + `secrets.sh` 参数化 `DOPPLER_CONFIG`

2. **Nginx upstream 写入防护** -- `update_upstream()` 使用 `UPSTREAM_CONF` 环境变量决定写入哪个文件，如果 pre-prod Pipeline 忘记设置此变量，会直接修改 prod 的 upstream。防护方案：写入前验证文件路径包含预期环境标识 + upstream 内容校验（pre-prod 内容必须包含 "preprod"）

3. **Jenkins Pipeline 并发锁** -- `disableConcurrentBuilds()` 只保护同一 Job 内并发，跨 Job（pre-prod + prod 同时部署）可能导致 Nginx reload 冲突。防护方案：使用 `lock('nginx-reload')` 包裹 Switch 阶段

4. **内存不足 OOM** -- 4 个 noda-apps 容器同时运行（prod 蓝绿 + pre-prod 蓝绿）加上基础设施和 Jenkins，可能超出服务器内存。防护方案：pre-prod 容器 memory limit 降至 512M + 部署前内存检查 + 考虑 pre-prod 单容器部署（不做蓝绿）

5. **Keycloak Google OAuth redirect URI 遗漏** -- 项目历史上多次因 redirect URI 问题导致登录失败，pre-prod 新增 4 个域名需要同步更新 Google Cloud Console 和 Keycloak client 配置。防护方案：创建部署前检查清单 + 自动化验证脚本

## 对路线图的影响

基于研究发现的依赖关系和风险分布，建议以下阶段结构：

### Phase 1: 基础设施准备

**理由：** 所有后续阶段都依赖数据库、Keycloak realm 和路由配置就位。这是最安全、变更范围最小的阶段，可以独立验证每个组件。

**交付物：** noda_preprod 数据库可连接 + noda-preprod realm 可登录 + Nginx pre-prod 路由可达（返回 502 表示路由正确但无后端）+ Cloudflare DNS 解析正常

**覆盖功能：** Pre-Prod 独立数据库、Pre-Prod 独立 Keycloak Realm、Pre-Prod 独立域名路由

**需要规避的陷阱：** Doppler 密钥环境隔离（Pitfall 2）、Keycloak OAuth redirect URI（Pitfall 4）、内存评估（Pitfall 5）

**涉及文件：**
- 修改：`scripts/init-databases.sh`（添加 noda_preprod）
- 修改：`services/keycloak/init-realm.sh`（添加 noda-preprod realm）
- 新建：`config/nginx/snippets/upstream-findclass-preprod.conf`
- 新建：`config/nginx/conf.d/preprod.conf`（4 个 server block）
- 新建：`docker/env-noda-apps-preprod.env`
- Cloudflare Dashboard 配置（3 个 CNAME + Tunnel ingress）

### Phase 2: 蓝绿部署脚本参数化

**理由：** manage-containers.sh 的参数化是整个 pre-prod 部署机制的核心。必须在 Jenkins Pipeline 之前完成，因为 Pipeline 依赖脚本的 preprod 支持。这是变更风险最高的阶段，涉及共享核心脚本。

**交付物：** manage-containers.sh 支持 `noda-apps-preprod` 服务名 + pre-prod wrapper 脚本 + 手动验证 pre-prod 蓝绿切换可行

**使用的技术栈元素：** Docker run 参数化、UPSTREAM_VARS_PREFIX 环境变量、noda.environment 标签

**需要规避的陷阱：** Docker 网络别名冲突（Pitfall 1）、Nginx upstream 写入防护（Pitfall 7）

**涉及文件：**
- 修改：`scripts/manage-containers.sh`（update_upstream 增加 UPSTREAM_VARS_PREFIX）
- 新建：`scripts/deploy-preprod.sh`（pre-prod 蓝绿部署 wrapper）

### Phase 3: Jenkins Pipeline 构建

**理由：** Pipeline 是自动化的最后一步，依赖前两个阶段提供的脚本和基础设施。双 Pipeline 模式保持 prod 现有流程不变，降低回归风险。

**交付物：** noda-apps-preprod Pipeline + noda-apps-promote Pipeline + Promote 端到端验证通过

**覆盖功能：** Build Once Promote to Prod、健康检查 + 自动回滚、Hotfix 紧急通道

**需要规避的陷阱：** Jenkins Pipeline 并发锁（Pitfall 3）、镜像清理冲突（Pitfall 6）、Hotfix 同步（Pitfall 8）

**涉及文件：**
- 新建：`jenkins/Jenkinsfile.noda-apps-preprod`
- 新建：`jenkins/Jenkinsfile.noda-apps-promote`
- 新建：`scripts/promote-to-prod.sh`
- 新建：`scripts/jenkins/init.groovy.d/10-pipeline-job-noda-apps-preprod.groovy`
- 新建：`scripts/jenkins/init.groovy.d/13-pipeline-job-noda-apps-promote.groovy`

### Phase 4: 安全加固与文档

**理由：** 核心功能就位后进行安全审查和文档完善。Promote 审批门禁在此阶段加入（成本极低）。

**交付物：** Promote 审批门禁 + CLAUDE.md 更新 + 端到端验证清单 + Hotfix SOP 文档

**覆盖功能：** Promote 审批门禁、Git Tag 版本追踪（可选）

### 阶段排序理由

- **Phase 1 先行**是因为数据库、realm、路由是所有后续步骤的硬依赖，且变更风险最低（仅新增配置，不修改现有逻辑）
- **Phase 2 在 Phase 3 之前**是因为 Jenkins Pipeline 的 shell 步骤直接调用 manage-containers.sh 和 wrapper 脚本，脚本必须先支持 preprod
- **Phase 4 放在最后**是因为安全加固和文档不阻塞核心功能，可以在验证通过后补充
- **manage-containers.sh 修改是关键路径**，这个文件是蓝绿部署的核心，修改需要特别谨慎

### 研究标记

需要更深入研究的阶段：
- **Phase 2：** `update_upstream()` 参数化方案需要仔细验证。ARCHITECTURE.md 和 STACK.md 给出了不同方案（ARCHITECTURE 推荐 if/else 分支，STACK 推荐 UPSTREAM_VARS_PREFIX），需要在实现时统一决策
- **Phase 3：** Jenkins `lock()` 资源锁机制需要确认是否需要额外插件（Lockable Resources Plugin）

模式成熟、可跳过研究阶段的：
- **Phase 1 数据库和 Keycloak：** 沿用现有 init-databases.sh 和 init-realm.sh 模式，文档充分
- **Phase 1 Nginx 配置：** 现有 default.conf 提供完整参考模板，复制修改即可
- **Phase 4 文档更新：** 纯文档工作，无技术风险

## 置信度评估

| 领域 | 置信度 | 说明 |
|------|--------|------|
| 技术栈 | HIGH | 不引入新组件，完全基于对现有代码库的深度分析。所有扩展方案都在现有代码中有参考模式 |
| 功能范围 | HIGH | 功能边界清晰，Table Stakes 和 Anti-Features 定义明确。社区最佳实践（Build Once Deploy Anywhere）有广泛共识 |
| 架构方案 | HIGH | 组件职责和数据流基于对 6 个核心脚本和配置文件的完整分析。依赖关系明确，无模糊地带 |
| 陷阱识别 | HIGH | 8 个陷阱全部基于对现有代码的具体函数和行号分析（secrets.sh、update_upstream()、image-cleanup.sh），而非理论推测 |

**综合置信度：HIGH**

### 需要解决的缺口

- **Docker 镜像命名策略：** STACK 建议使用不同镜像名（`noda-apps-preprod`），但 ARCHITECTURE 建议使用同一镜像。这影响 Promote 流程（是否需要 retag）和镜像清理逻辑。建议在 Phase 3 实现时统一决策，推荐使用不同镜像名 + Promote 时 retag
- **pre-prod 是否做蓝绿：** 内存评估建议 pre-prod 使用单容器（省内存），但功能研究要求蓝绿部署（零停机）。建议 Phase 1 启动容器前先确认实际可用内存，如果不足则退化为单容器
- **Doppler pre config 具体变量：** 需要在实施时确定哪些变量从 prd 继承、哪些需要覆盖。建议 Phase 1 创建 Doppler config 时逐项确认
- **manage-containers.sh 参数化方案：** ARCHITECTURE.md 推荐 if/else 分支（更实用），STACK.md 推荐 UPSTREAM_VARS_PREFIX 环境变量（更灵活）。需要在 Phase 2 实现时选择一种并保持一致

## 来源

### 主要来源（HIGH 置信度）

- 项目源码分析：`scripts/manage-containers.sh`、`scripts/pipeline-stages.sh`、`scripts/lib/secrets.sh`、`scripts/lib/image-cleanup.sh`、`jenkins/Jenkinsfile.noda-apps`、`config/nginx/conf.d/default.conf`、`config/nginx/snippets/upstream-findclass.conf`、`docker/env-noda-apps.env`
- 项目历史记录：CLAUDE.md（Phase 16 OAuth 修复、端口收敛、蓝绿部署架构）
- 项目决策记录：`.planning/PROJECT.md`、`.planning/notes/pre-prod-environment-plan.md`
- Jenkins 官方文档：Pipeline promotion 模式、Declarative Pipeline 语法

### 次要来源（MEDIUM 置信度）

- Docker Compose Override Strategies (oneuptime.com) -- overlay 模式验证
- Build Once Deploy Many (Reddit r/devops、devm.io) -- 社区最佳实践共识
- Smoke Testing Best Practices (Harness) -- smoke test 时间控制建议
- Deployment Gatekeepers (Reddit r/ExperiencedDevs) -- 小团队 gatekeeper 经验

---
*研究完成日期: 2026-05-08*
*路线图就绪: 是*
