# Pre-Prod 环境功能研究

**Domain:** 部署基础设施 — Pre-Prod 验证环境作为生产上线守门员
**Researched:** 2026-05-08
**Confidence:** HIGH（基于现有架构深度分析 + 行业最佳实践交叉验证）

## 功能全景

### Table Stakes（必须有的基础功能）

用户（开发者/运维）理所当然期望存在的功能。缺少任何一个 = 整个 pre-prod 环境感觉不完整。

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Pre-Prod 蓝绿部署** | 已有 prod 蓝绿模式，pre-prod 必须同样支持 | MEDIUM | 复用 manage-containers.sh 参数化框架，新建 env-noda-apps-preprod.env 模板和 upstream-findclass-preprod.conf。容器命名 `noda-apps-preprod-blue/green`，独立 ACTIVE_ENV_FILE |
| **Build Once, Deploy to Pre-Prod** | Docker 镜像在 CI 构建一次，pre-prod 先用 | LOW | 复用现有 `pipeline_build` 函数构建镜像，构建产物是带 Git SHA tag 的本地镜像。noda-apps monorepo 只有一个镜像 |
| **Promote Same Image to Prod** | pre-prod 验证通过后，同一个镜像 promote 到 prod，不重新构建 | MEDIUM | 核心价值。Jenkins Promote 流程读取 pre-prod 当前镜像 digest/tag，用相同镜像部署到 prod 蓝绿。环境差异通过运行时环境变量注入（DATABASE_URL/KEYCLOAK_REALM 等） |
| **Pre-Prod 独立数据库** | 验证 DB migration 不能影响 prod 数据 | LOW | 同一 PostgreSQL 实例新增 `noda_preprod` 数据库。init-databases.sh 扩展。资源增量可忽略 |
| **Pre-Prod 独立 Keycloak Realm** | 认证流程必须端到端验证，不能用 prod 的 OAuth session | MEDIUM | 同一 Keycloak 实例新增 `noda-preprod` realm。需配置 Google OAuth redirect URI 包含 pre-prod 域名。client 配置独立于 prod |
| **Pre-Prod 独立域名 + 路由** | 团队需要通过真实 URL 访问验证环境 | LOW | pre.class.noda.co.nz / pre.auth.noda.co.nz / pre.noda.co.nz / pre.admin.noda.co.nz。Nginx 新增 server blocks，Cloudflare Tunnel + DNS 新增路由 |
| **健康检查 + 自动回滚** | prod 有，pre-prod 也必须有 | LOW | 完全复用现有 pipeline_health_check + pipeline_failure_cleanup。只是目标容器名和环境变量不同 |
| **Hotfix 紧急通道** | P0 级服务中断必须能跳过 pre-prod 直接部署到 prod | MEDIUM | Jenkins Pipeline 新增 `SKIP_PREPROD=true` 参数，直接走现有 prod 部署流程。需要权限控制和事后补验证机制 |

### Differentiators（提升价值的增强功能）

不是必须的，但实现后显著提升 pre-prod 环境的价值和团队信心。

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Git Tag 版本追踪** | 每次部署关联明确的版本号，便于追溯和回滚定位 | LOW | `git tag -a v1.x.x` 在 promote 成功后打 tag。Jenkins 自动读取 tag 作为镜像 label。trunk-based 工作流下 tag 是版本追踪的唯一锚点 |
| **DB Migration Pre-Check** | 在 pre-prod 数据库上验证 migration 脚本，提前发现 schema 冲突 | MEDIUM | Prisma migration 在 pre-prod 数据库上执行。如果 migration 失败，阻止 promote。需要在 Pipeline 中增加 migration stage |
| **Smoke Test 自动化门禁** | promote 前自动运行关键路径验证，不只是健康检查 | MEDIUM | 超越 HTTP 200 检查，验证登录流程、核心 API、页面渲染。可实现为 curl 脚本套件或简单 E2E 脚本。建议控制在 5 分钟内完成 |
| **Pre-Prod 数据定期同步** | 用 prod 数据（脱敏后）填充 pre-prod 数据库，提高验证真实性 | HIGH | 复杂度高，涉及数据脱敏策略。v1 不做，后续迭代考虑。当前用空数据库 + 手动创建测试数据足够 |
| **Promote 审批门禁** | promote 到 prod 需要人工确认 | LOW | Jenkins `input` 步骤即可实现，一行代码。但价值很大：防止未经人工确认的自动 promote |
| **部署历史关联 Git SHA** | Jenkins 构建记录关联 Git commit，便于快速定位 "这次部署改了什么" | LOW | 现有 Pipeline 已记录 GIT_SHA。Promote 时继承 pre-prod 的 GIT_SHA，在 Jenkins 构建描述中显示 |

### Anti-Features（看似合理但应该避免的功能）

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| **完全独立的基础设施栈** | "pre-prod 应该和 prod 完全隔离" | 单服务器资源受限，独立 PostgreSQL/Keycloak/Nginx 实例会增加 ~2GB 内存，且运维复杂度翻倍。镜像管理、备份策略都需要维护两套 | 共享基础设施（PostgreSQL/Keycloak/Nginx），仅应用层双实例。数据库级别隔离（noda_prod vs noda_preprod），不是实例级别 |
| **自动触发 Pre-Prod 部署** | "每次 git push 自动部署到 pre-prod" | 项目更新频率低（周级别），自动触发增加攻击面和资源消耗。Jenkins 需要配置 webhook，暴露公网接口。自动构建可能触发不必要的资源占用 | 手动触发 Jenkins Build Now。开发节奏可控，且 pre-prod 资源不浪费 |
| **Pre-Prod 全自动 Promote** | "pre-prod 通过后自动 promote 到 prod" | 移除了人工审查环节，任何 pre-prod 验证遗漏会直接冲击 prod。对于小型团队，人工确认是重要的安全网 | Promote 需要手动触发 + `input` 审批门禁。自动化的部分是部署和验证，决策权在人 |
| **Feature Flag 系统** | "用 feature flag 控制灰度发布" | 引入 LaunchDarkly/Unleash 等第三方服务增加外部依赖和成本。Noda 项目规模不需要灰度发布 | 蓝绿部署本身已提供版本切换能力。环境变量控制功能开关足够（NEXT_PUBLIC_* 构建时注入） |
| **多环境并行验证** | "pre-prod 和 prod 同时跑不同版本对比" | 单服务器内存限制（pre-prod 已增加 ~1GB），无法支持多个历史版本并行运行 | pre-prod 只跑即将发布的版本，prod 跑当前版本。需要对比时在本地开发环境进行 |
| **复杂的 RBAC 权限控制** | "只有特定角色才能 promote" | Jenkins RBAC 插件配置复杂，团队只有 1-2 人。过度工程化 | Jenkins 基本权限（登录才能触发）+ 人工确认步骤足够。Hotfix 跳过审批需要口头约定 |

## Feature Dependencies

```
[Pre-Prod 基础设施]
    ├──requires──> [noda_preprod 数据库]
    ├──requires──> [noda-preprod Keycloak realm]
    └──requires──> [Pre-Prod Nginx 路由 + Cloudflare DNS]

[Pre-Prod 蓝绿部署]
    ├──requires──> [Pre-Prod 基础设施]
    ├──requires──> [manage-containers.sh preprod 参数化]
    └──requires──> [env-noda-apps-preprod.env 模板]

[Build Once + Promote Pipeline]
    ├──requires──> [Pre-Prod 蓝绿部署]
    └──requires──> [Jenkins Promote Pipeline 或参数化 DEPLOY_TARGET]

[Hotfix 紧急通道]
    ├──requires──> [现有 prod 蓝绿部署]（已有）
    └──conflicts──> [Pre-Prod 必须先验证规则]（特殊情况豁免）

[Git Tag 版本追踪]
    └──enhances──> [Promote Pipeline]（tag 在 promote 成功后打）

[Promote 审批门禁]
    ├──requires──> [Promote Pipeline]
    └──enhances──> [安全性]

[Smoke Test 门禁]
    ├──requires──> [Pre-Prod 蓝绿部署]
    └──enhances──> [Promote Pipeline]（promote 前必须通过）

[DB Migration Pre-Check]
    ├──requires──> [noda_preprod 数据库]
    └──enhances──> [Pre-Prod 部署流程]（部署阶段增加 migration step）
```

### Dependency Notes

- **Pre-Prod 蓝绿部署 requires Pre-Prod 基础设施：** 数据库、Keycloak realm、路由必须先就位，否则容器启动后无法连接后端服务
- **Build Once + Promote requires Pre-Prod 蓝绿部署：** 没有可部署的 pre-prod 环境就无法验证，promote 就没有意义
- **Hotfix 紧急通道 conflicts Pre-Prod 规则：** hotfix 本质上豁免了 "必须先在 pre-prod 验证" 的规则。需要明确定义什么情况可以触发（仅 P0 服务中断/数据安全风险）
- **Git Tag 版本追踪 enhances Promote：** tag 不是 promote 的前置条件，但在 promote 成功后打 tag 是最佳时机（确认代码已经安全上线）
- **Smoke Test 门禁 enhances Promote Pipeline：** smoke test 不是 v1 的硬性要求，但实现后显著提高 promote 的信心

## MVP Definition

### Launch With (v1)

最小可行 pre-prod 环境 — 能够做到 "先验证再上线"。

- [ ] **Pre-Prod 基础设施** — noda_preprod 数据库 + noda-preprod Keycloak realm + Nginx 路由 + Cloudflare DNS。没有这些 pre-prod 无法运行
- [ ] **Pre-Prod 蓝绿部署** — manage-containers.sh 支持 preprod 环境参数，env 模板和 upstream 配置独立。复用现有蓝绿框架
- [ ] **Pre-Prod Jenkins Pipeline** — 独立 Jenkinsfile（或参数化），构建镜像并部署到 pre-prod。与现有 prod Pipeline 并行
- [ ] **Promote to Prod 流程** — Jenkins Pipeline 读取 pre-prod 当前镜像，用相同镜像部署到 prod 蓝绿。build once, promote anywhere
- [ ] **Hotfix 紧急通道** — `SKIP_PREPROD=true` 参数直接走 prod 部署。需要有明确的 P0 定义文档

### Add After Validation (v1.x)

核心流程跑通后，增加提升信心和效率的功能。

- [ ] **Git Tag 版本追踪** — pre-prod 部署后自动标记，promote 成功后打 release tag。触发条件：v1 流程稳定运行 2 周
- [ ] **Promote 审批门禁** — Jenkins `input` 步骤要求人工确认。触发条件：出现一次未经确认的 promote 导致问题
- [ ] **Smoke Test 自动化** — 超越 HTTP 健康检查，验证登录、核心 API。触发条件：手动验证流程成为瓶颈
- [ ] **DB Migration Pre-Check** — pre-prod 部署时先跑 migration。触发条件：首次遇到 migration 在 prod 失败的情况

### Future Consideration (v2+)

需要产品方向明确后才值得投入的功能。

- [ ] **Pre-Prod 数据定期同步** — 需要数据脱敏策略，涉及隐私合规问题。推迟原因：当前空库 + 手动测试数据够用
- [ ] **E2E 测试套件** — Playwright/Cypress 级别的端到端测试。推迟原因：团队只有 1-2 人，维护成本高于收益
- [ ] **Slack/通知集成** — 部署状态推送到团队通讯工具。推迟原因：Jenkins UI 查看状态已够用

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Pre-Prod 基础设施（DB + Realm + DNS） | HIGH | LOW | P1 |
| Pre-Prod 蓝绿部署 | HIGH | MEDIUM | P1 |
| Pre-Prod Jenkins Pipeline | HIGH | MEDIUM | P1 |
| Promote to Prod 流程 | HIGH | MEDIUM | P1 |
| Hotfix 紧急通道 | HIGH | LOW | P1 |
| Promote 审批门禁 | MEDIUM | LOW | P2 |
| Git Tag 版本追踪 | MEDIUM | LOW | P2 |
| Smoke Test 门禁 | MEDIUM | MEDIUM | P2 |
| DB Migration Pre-Check | MEDIUM | MEDIUM | P3 |
| Pre-Prod 数据同步 | LOW | HIGH | P3 |
| E2E 测试套件 | LOW | HIGH | P3 |

**Priority key:**
- P1: v1 必须有 — pre-prod 环境的核心价值
- P2: v1.x 加入 — 提升安全性和信心
- P3: v2+ 考虑 — 需要更多场景验证投入产出比

## 部署流程对比

### 当前流程（无 Pre-Prod）

```
main push → Jenkins Build Now → Build → Test → Deploy Prod → Health → Switch → Verify → CDN Purge → Cleanup
```

问题：没有验证缓冲区，构建直接上线。

### 目标流程（有 Pre-Prod）

```
# 正常流程
main push → Jenkins Pre-Prod Build Now
  → Build (一次) → Test → Deploy Pre-Prod → Health → Switch → Verify
  → 团队在 pre.class.noda.co.nz 手动验证
  → Jenkins Promote Build Now
  → (读取同一镜像) → Deploy Prod → Health → Switch → Verify → CDN Purge → Cleanup

# Hotfix 流程 (P0 紧急)
hotfix commit → Jenkins Prod Build Now (SKIP_PREPROD=true)
  → Build → Deploy Prod → Health → Switch → Verify → CDN Purge → Cleanup
  → 事后补 Pre-Prod 验证
```

### Promote 关键实现细节

**镜像传递机制：** pre-prod 部署时镜像 tag 为 `noda-apps:{GIT_SHA}`。Promote Pipeline 读取 pre-prod 容器的镜像 tag（通过 `docker inspect` 或状态文件），用相同 tag 部署到 prod。

**环境差异通过运行时变量隔离：** 同一镜像在不同环境只需替换：
| 变量 | Pre-Prod | Prod |
|------|----------|------|
| DATABASE_URL | ...noda_preprod | ...noda_prod |
| KEYCLOAK_URL | pre.auth.noda.co.nz | auth.noda.co.nz |
| KEYCLOAK_REALM | noda-preprod | noda |
| KEYCLOAK_CLIENT_ID | noda-frontend-preprod | noda-frontend |

**注意：** NEXT_PUBLIC_* 变量是构建时注入的。Pre-prod 和 prod 的前端代码完全相同（同镜像），认证 URL 的差异通过运行时 Keycloak init 配置处理，或需要前端支持运行时配置注入。

## Verification Criteria（Pre-Prod 验证标准）

### 必须验证（Table Stakes）

| 检查项 | 方法 | 通过标准 |
|--------|------|----------|
| 容器健康 | `docker inspect` healthcheck | `healthy` |
| HTTP 可达性 | `curl pre.class.noda.co.nz` | HTTP 200 |
| API 健康检查 | `curl pre.class.noda.co.nz/api/health` | HTTP 200 + JSON |
| 数据库连接 | API health 响应包含 DB 状态 | 无连接错误 |
| Keycloak 认证 | 浏览器手动登录测试 | 能完成 OAuth 登录流程 |
| 静态资源 | 浏览器检查 Network 面板 | CSS/JS/图片全部加载 |

### 建议验证（Differentiators）

| 检查项 | 方法 | 通过标准 |
|--------|------|----------|
| 核心用户流程 | 手动走一遍关键路径 | 功能正常 |
| Nginx 路由 | curl 各 pre-prod 域名 | 正确路由到对应服务 |
| SSL/TLS | 浏览器访问 | 证书有效，无混合内容 |

### 不需要验证（Anti-Pattern）

| 检查项 | Why Skip |
|--------|----------|
| 压力测试 | Pre-prod 资源配置与 prod 不同，压测结果无参考价值 |
| 全量 E2E 回归 | 维护成本高于收益，手动验证关键路径足够 |
| 跨浏览器兼容性 | Pre-prod 目的是验证部署流程，不是 QA 环境 |

## 与现有架构的集成点

| 现有组件 | Pre-Prod 集成方式 | 变更范围 |
|---------|-------------------|----------|
| `manage-containers.sh` | 环境变量参数化支持 preprod：SERVICE_NAME 前缀、ACTIVE_ENV_FILE、UPSTREAM_CONF、ENV_TEMPLATE | MEDIUM — 新增 preprod 分支逻辑 |
| `pipeline-stages.sh` | 新增 `pipeline_promote` 函数族（读取 pre-prod 镜像、部署到 prod 蓝绿） | MEDIUM — 新增函数，不修改现有函数 |
| `blue-green-deploy.sh` | 不修改，通过环境变量适配 preprod | 无变更 |
| `env-noda-apps.env` | 新增 `env-noda-apps-preprod.env` 模板 | 新增文件 |
| `upstream-findclass.conf` | 新增 `upstream-findclass-preprod.conf` | 新增文件 |
| `default.conf` | 新增 pre-prod server blocks（pre.class.noda.co.nz 等） | MEDIUM — 新增 4 个 server blocks |
| `docker-compose.app.yml` | 不修改。蓝绿容器通过 `docker run` 管理，不走 compose | 无变更 |
| `Jenkinsfile.noda-apps` | 可能增加 `DEPLOY_TARGET` 参数化，或新增独立 `Jenkinsfile.noda-apps-promote` | MEDIUM — 取决于单/双 Pipeline 决策 |
| Cloudflare Tunnel | 新增 pre-prod 域名路由 | LOW — 配置变更 |

## Sources

- [Build Once, Deploy Anywhere — Reddit r/devops](https://www.reddit.com/r/devops/comments/1qqhrbs/build_once_deploy_everywhere_and_build_on_merge/) — "Build once" 核心理念：构建一次，在不同环境之间 promote 相同制品，MEDIUM confidence
- [Docker Image Build and Promotion Pipeline — DevOpsCube](https://devopscube.com/docker-image-build-and-promotion-pipeline/) — 标准最佳实践：构建一次，镜像 promote 到 prod，HIGH confidence
- [Build Once, Deploy Anywhere — devm.io](https://devm.io/javascript/build-once-deploy-anywhere-applying-cicd-best-practices-to-frontend-apps) — 前端应用的 build once 策略，环境差异通过运行时配置注入，MEDIUM confidence
- [Smoke Testing Best Practices — Harness](https://www.harness.io/harness-devops-academy/integrating-smoke-testing-into-your-ci-cd-pipeline-what-devops-needs-to-know) — Smoke test 应在 5 分钟内完成，promote 前自动运行，MEDIUM confidence
- [Securing Staging Environments — Doppler](https://www.doppler.com/blog/securing-staging-environments-secrets-management) — Staging 需要与 prod 同等级别的安全配置（TLS、密钥管理），MEDIUM confidence
- [Deployment Gatekeepers — Reddit r/ExperiencedDevs](https://www.reddit.com/r/ExperiencedDevs/comments/1hfn3aa/deployment_gatekeepers/) — 小型团队的实际 gatekeeper 经验分享，MEDIUM confidence
- 项目代码分析：`docker/docker-compose.app.yml`、`jenkins/Jenkinsfile.noda-apps`、`scripts/manage-containers.sh`、`scripts/blue-green-deploy.sh`、`scripts/pipeline-stages.sh`、`config/nginx/conf.d/default.conf` — 现有架构深度分析，HIGH confidence

---
*Feature research for: Pre-Prod 验证环境*
*Researched: 2026-05-08*
