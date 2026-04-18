# Phase 40: Jenkins Pipeline 集成 - Context

**Gathered:** 2026-04-19
**Status:** Ready for planning

<domain>
## Phase Boundary

Jenkins Pipeline 启动时自动从 Doppler 拉取密钥，替代当前 `source docker/.env` 模式。Docker Compose 和 docker build 都能正确获取所需环境变量。同时更新手动部署脚本以支持 Doppler。

**涉及需求：** PIPE-01（Fetch Secrets）、PIPE-02（withCredentials）、PIPE-03（Docker Compose 注入）、PIPE-04（VITE_* 构建）

**注意：** REQUIREMENTS.md 仍引用 Infisical（工具已改为 Doppler），需求编号和目标不变。

</domain>

<decisions>
## Implementation Decisions

### Jenkinsfile 范围
- **D-01:** 只改 3 个 Jenkinsfile（findclass-ssr、infra、keycloak），跳过 noda-site（静态站点无敏感密钥）
- **D-02:** noda-site 未来需要密钥时可复用相同模式

### 密钥获取方式
- **D-03:** 在 pipeline-stages.sh 中统一处理密钥获取，不添加独立 Fetch Secrets stage
- **D-04:** pipeline-stages.sh 检测 `DOPPLER_TOKEN` 环境变量：有则 `doppler secrets download --no-file --format=env`，没有则回退 `source docker/.env`
- **D-05:** Doppler 配置：`--project noda --config prd`（注意 config 名为 `prd` 非 `prod`，Phase 39 已验证）

### Token 注入
- **D-06:** 每个 Jenkinsfile 用 `withCredentials([string(credentialsId: 'doppler-service-token', variable: 'DOPPLER_TOKEN')])` 包装需要密钥的 stages
- **D-07:** Service Token credentialsId: `doppler-service-token`（Phase 39 已录入 Jenkins Credentials）

### 手动部署脚本
- **D-08:** deploy-infrastructure-prod.sh 和 deploy-apps-prod.sh 本 phase 一起改为 Doppler
- **D-09:** 手动脚本要求用户预先设置 `DOPPLER_TOKEN` 环境变量，无 token 时回退 docker/.env

### Doppler 宕机回退
- **D-10:** 双模式回退策略：DOPPLER_TOKEN 存在 → Doppler 拉取；不存在 → 回退 source docker/.env
- **D-11:** Phase 41 删除 docker/.env 前回退机制始终可用。Phase 41 之后需确保 Doppler 稳定

### VITE_* 处理（已锁定，Phase 39）
- **D-12:** VITE_* 公开信息不纳入 Doppler，保持 Dockerfile 中 ARG 硬编码和 docker-compose.app.yml 中 args 硬编码

### Claude's Discretion
- pipeline-stages.sh 中 Doppler 回退逻辑的具体实现细节
- withCredentials 在 Jenkinsfile 中的包装位置和范围
- 手动脚本的 Doppler 检测和错误处理细节
- Doppler secrets download 后的变量注入方式（source /dev/stdin vs 临时文件）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 密钥管理需求
- `.planning/REQUIREMENTS.md` — PIPE-01 to PIPE-04 需求定义（注意：工具名仍为 Infisical，实际用 Doppler）
- `.planning/ROADMAP.md` — Phase 40 范围和 Success Criteria
- `.planning/STATE.md` — 项目状态和已锁定决策
- `.planning/phases/39-infisical-infra/39-CONTEXT.md` — Phase 39 决策（Doppler 项目组织、Service Token、排除范围）

### 现有 Pipeline 代码
- `scripts/pipeline-stages.sh` — Pipeline 核心函数库，当前 `source docker/.env` 加载密钥（主要改动文件）
- `jenkins/Jenkinsfile.findclass-ssr` — findclass-ssr 蓝绿部署 Pipeline
- `jenkins/Jenkinsfile.infra` — 基础设施服务 Pipeline
- `jenkins/Jenkinsfile.keycloak` — Keycloak 蓝绿部署 Pipeline
- `jenkins/Jenkinsfile.noda-site` — noda-site 静态站 Pipeline（本 phase 不改）

### 手动部署脚本
- `scripts/deploy/deploy-infrastructure-prod.sh` — 手动基础设施部署
- `scripts/deploy/deploy-apps-prod.sh` — 手动应用部署
- `scripts/blue-green-deploy.sh` — 蓝绿部署核心（也 source docker/.env）

### 现有密钥文件
- `docker/.env` — Docker Compose 基础设施密钥（Phase 40 期间保留作为回退）
- `docker/env-findclass-ssr.env` — findclass-ssr envsubst 模板
- `docker/env-keycloak.env` — Keycloak envsubst 模板

### Doppler 相关（Phase 39 已创建）
- `scripts/install-doppler.sh` — CLI 安装脚本
- `scripts/verify-doppler-secrets.sh` — 密钥验证脚本
- `scripts/backup/backup-doppler-secrets.sh` — 离线备份脚本

### Doppler 文档
- Doppler CI/CD 集成: `https://docs.doppler.com/docs/jenkins`
- Doppler Service Tokens: `https://docs.doppler.com/docs/service-tokens`
- Doppler CLI secrets download: `https://docs.doppler.com/docs/secrets-download`

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/pipeline-stages.sh` — 核心改动文件，已有 `source docker/.env` 逻辑需替换为 Doppler 双模式
- `withCredentials` 模式 — Jenkinsfile 中已有使用（Cloudflare cf-api-token、cf-zone-id），可直接复用
- `scripts/install-doppler.sh` — Phase 39 创建的安装脚本，已验证可用
- `scripts/verify-doppler-secrets.sh` — 验证 15 个预期密钥，可复用于部署后验证

### Established Patterns
- `withCredentials([string(credentialsId: 'xxx', variable: 'ENV_VAR')])` — Jenkins 凭据绑定标准模式
- `set -a; source .env; set +a` — 环境变量导出模式
- `envsubst` 模板 → `docker run --env-file` — 蓝绿部署密钥注入链路
- 手动脚本 `source docker/.env` — 与 pipeline-stages.sh 相同的加载模式

### Integration Points
- Jenkins Credentials Store — `doppler-service-token`（Phase 39 已创建 Secret text）
- pipeline-stages.sh 的密钥加载位置（约第 20-29 行）— 主要替换点
- 蓝绿部署 envsubst 链路 — 无需改动，密钥已通过 source 加载到环境中
- Docker Compose `${VAR}` 替换 — 无需改动，密钥通过环境变量注入

</code_context>

<specifics>
## Specific Ideas

- Doppler 密钥获取命令：`doppler secrets download --no-file --format=env --project noda --config prd`
- 注意 Doppler config 名为 `prd`（非 `prod`），这是 Phase 39 执行时确定的
- pipeline-stages.sh 的双模式逻辑：`if [ -n "${DOPPLER_TOKEN:-}" ]; then ... doppler ... else ... source docker/.env ... fi`
- 手动脚本需要提示用户设置 `export DOPPLER_TOKEN=xxx` 或回退到 docker/.env

</specifics>

<deferred>
## Deferred Ideas

- noda-site Pipeline 的 Doppler 集成 — 静态站点暂无敏感密钥，未来需要时复用相同模式
- Phase 41 删除 docker/.env — 本 phase 保留 .env 作为回退，删除在 Phase 41
- 密钥自动轮换 — Doppler 免费版不支持
- 多环境（dev/staging）— 当前只有生产环境

</deferred>

---

*Phase: 40-jenkins-pipeline*
*Context gathered: 2026-04-19*
