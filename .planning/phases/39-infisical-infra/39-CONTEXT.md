# Phase 39: 密钥管理基础设施搭建 - Context

**Gathered:** 2026-04-19
**Status:** Ready for planning

<domain>
## Phase Boundary

在 Jenkins 宿主机安装密钥管理 CLI，创建云端项目，配置 CI/CD 非交互式认证，并将凭据离线备份。目标：Jenkins 可通过 `doppler secrets download` 拉取所有密钥。

**重要变更：** 原 ROADMAP 指定 Infisical Cloud，经讨论后改为 Doppler。理由：认证更简单（单 Service Token vs Client ID + Secret → JWT），CLI 安装更简单，50 个 service token 免费额度充足。

</domain>

<decisions>
## Implementation Decisions

### 工具选择（重大变更）
- **D-01:** 使用 Doppler（Developer 免费版）替代 Infisical Cloud。理由：认证流程更简单（单 token）、CLI 安装更简洁、免费额度（50 service tokens、10 projects、4 environments）对 ~20 密钥的项目绑绰有余

### CLI 安装
- **D-02:** 通过 `brew install dopplerhq/cli/doppler` 安装到 Jenkins 宿主机。服务器已有 Homebrew（Phase 26 安装 PostgreSQL 时使用），无需额外安装包管理器

### Doppler 项目组织
- **D-03:** 单项目 "noda"，单环境 "prod"，所有 ~20 个密钥平铺管理。密钥数量少，无需文件夹或多项目分离。未来需要时 Doppler 免费版支持 10 个项目和 4 个环境

### 认证方案
- **D-04:** Doppler Service Token（`dp.st.prd.xxx`）存储到 Jenkins Credentials（Secret text 类型）。Pipeline 通过 `withCredentials` 读取，日志自动遮蔽。手动部署回退脚本要求用户手动设置 `DOPPLER_TOKEN` 环境变量

### 离线备份
- **D-05:** 两层备份策略：（1）Service Token 存到密码管理器；（2）定期 `doppler secrets download --format=env` 导出 .env 文件，加密后上传到 Backblaze B2

### 排除范围
- **D-06:** 备份系统 `scripts/backup/.env.backup` 保持独立明文文件，不迁移到 Doppler
- **D-07:** VITE_* 公开信息不纳入 Doppler，保持 --build-arg 硬编码

### Claude's Discretion
- Doppler CLI 具体安装脚本实现细节
- B2 加密快照的具体加密方式（age/gpg）
- Service Token 权限范围（read-only vs read-write）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 密钥管理需求
- `.planning/REQUIREMENTS.md` — INFRA-01 to INFRA-04 需求定义（注意：需更新 Infisical → Doppler）
- `.planning/ROADMAP.md` — Phase 39 范围和 Success Criteria（注意：需更新工具名称）
- `.planning/STATE.md` — 项目状态和已锁定决策

### 现有密钥文件
- `docker/.env` — Docker Compose 基础设施密钥（PG, Keycloak, CF, B2, Anthropic）~7 个
- `.env.production` — findclass-ssr 应用密钥 ~13 个（含空值 SMTP, ReSend）
- `scripts/backup/.env.backup` — 备份系统密钥（不迁移，保持独立）

### 现有密钥管理代码
- `scripts/utils/decrypt-secrets.sh` — 现有 SOPS 解密脚本（Phase 41 清理）

### Doppler 文档
- Doppler CLI: `https://docs.doppler.com/docs/install`
- Doppler CI/CD: `https://docs.doppler.com/docs/jenkins`
- Doppler Service Tokens: `https://docs.doppler.com/docs/service-tokens`

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/pipeline-stages.sh` — Pipeline 核心函数库，当前 `source docker/.env` 加载密钥，Phase 40 将改为 Doppler
- Jenkins Credentials Store — 已有凭据管理经验（Docker Hub、B2 等）
- `scripts/backup/lib/config.sh` — 备份系统配置加载，保持不变

### Established Patterns
- `withCredentials` 在 Jenkinsfile 中已广泛使用（Docker Hub 登录、B2 凭据等）
- 手动部署脚本通过 `source docker/.env` 加载密钥
- 蓝绿部署通过 envsubst 模板注入环境变量

### Integration Points
- Jenkins Pipeline（Phase 40）：Fetch Secrets stage 从 Doppler 拉取密钥生成 .env
- Docker Compose：通过生成的 .env 文件获取运行时密钥
- docker build：VITE_* 通过 --build-arg 注入（不从 Doppler 获取）
- 手动部署脚本：从 Doppler 获取密钥替代 source docker/.env

</code_context>

<specifics>
## Specific Ideas

- Doppler 认证比 Infisical 更简单：单 Service Token（`DOPPLER_TOKEN` 环境变量）vs Client ID + Secret → JWT 交换
- Doppler CLI 安装一条命令：`(curl -Ls https://cli.doppler.com/install.sh || wget -qO- https://cli.doppler.com/install.sh) | sh`
- 密钥导出：`doppler secrets download --no-file --format=env` 输出 .env 格式
- Jenkins 集成：`DOPPLER_TOKEN` 作为 Secret text credential，Pipeline 中 `withCredentials` 绑定

</specifics>

<deferred>
## Deferred Ideas

- 密钥版本管理 — Doppler Developer 免费版无此功能，Team 版才有
- 密钥自动轮换 — 未来可考虑 Team 版的自动轮换功能
- 多环境（dev/staging）— 当前只有生产环境，需要时再添加
- Infisical Cloud 作为升级路径 — 如果 Doppler 免费版不满足需求，可迁移到 Infisical 或 Doppler Team

</deferred>

---

*Phase: 39-infisical-infra*
*Context gathered: 2026-04-19*
