# Phase 41: 迁移与清理 - Context

**Gathered:** 2026-04-19
**Status:** Ready for planning

<domain>
## Phase Boundary

所有密钥已在 Doppler 验证通过后，删除明文 .env 文件和废弃的 SOPS 代码。确保服务仍能通过 Doppler 正常部署。

**涉及需求：** MIGR-01（密钥验证）、MIGR-02（备份隔离）、MIGR-03（文件删除）、MIGR-04（SOPS 清理）

**前置条件：** Phase 40 已完成 Doppler 双模式集成，所有脚本通过 load_secrets() 获取密钥。

</domain>

<decisions>
## Implementation Decisions

### 密钥验证（per MIGR-01）
- **D-01:** 删除明文文件前，运行 `scripts/verify-doppler-secrets.sh` 验证 Doppler 中所有密钥完整。验证脚本已由 Phase 39 创建。
- **D-02:** 验证覆盖范围：docker/.env 的 14 个密钥 + .env.production 中的 SMTP_* 等额外密钥。对比 Doppler `doppler secrets download` 输出与现有 .env 文件的 key 列表。

### secrets.sh 回退策略（per MIGR-03）
- **D-03:** 从 `scripts/lib/secrets.sh` 的 `load_secrets()` 中移除 docker/.env 回退路径
- **D-04:** DOPPLER_TOKEN 未设置时，输出明确错误提示并 return 1（而非静默回退到不存在的文件）
- **D-05:** Doppler 成为唯一密钥源，所有部署（Pipeline + 手动）必须通过 DOPPLER_TOKEN 认证
- **D-06:** 错误提示内容示例：`[ERROR] DOPPLER_TOKEN 未设置。请 export DOPPLER_TOKEN=<service-token> 后重试。`

### 明文文件删除（per MIGR-03）
- **D-07:** 删除 `docker/.env`（14 个基础设施密钥）
- **D-08:** 删除 `.env.production`（前端 + SMTP 密钥）
- **D-09:** 保留 `scripts/backup/.env.backup`（per MIGR-02，备份系统独立运行）
- **D-10:** 保留模板文件 `config/environments/.env.production.template`、`config/environments/.env.example`（用于新环境参考）
- **D-11:** 保留 `scripts/backup/templates/.env.backup`、`scripts/backup/.env.example`（备份系统模板）

### SOPS 代码清理（per MIGR-04）
- **D-12:** 删除 SOPS 核心文件：
  - `.sops.yaml`（SOPS 配置）
  - `config/secrets.sops.yaml`（加密密钥文件）
  - `scripts/utils/decrypt-secrets.sh`（SOPS 解密脚本）
- **D-13:** 删除已废弃脚本：
  - `scripts/deploy/deploy-findclass-zero-deps.sh`（已标记废弃，仍引用 SOPS）
- **D-14:** 更新引用 SOPS 的脚本：
  - `scripts/setup-keycloak-full.sh` — 移除 SOPS 解密逻辑，改为从环境变量读取 OAuth 凭据（Doppler 注入）
- **D-15:** 更新文档：
  - `docs/secrets-management.md` — 重写为 Doppler 密钥管理文档
  - `docs/DEVELOPMENT.md` — 移除 SOPS 安装和使用说明
  - `README.md` — 移除 SOPS 依赖提及
- **D-16:** 更新 `.gitignore`：
  - 移除 SOPS 相关模式（`.sops.yaml`、`*.sops.yaml` 等）
  - 保留 `docker/.env` 在 .gitignore 中（防止未来误提交）
- **D-17:** 移除 `scripts/deploy/deploy-infrastructure-prod.sh` 中残留的 SOPS 检查注释（Phase 40 已弱化，本 phase 彻底清除）

### VITE_* 处理（已锁定）
- **D-18:** VITE_* 公开信息不纳入 Doppler，保持 Dockerfile ARG 硬编码（per D-12/Phase 40）
- **D-19:** .env.production 中的 VITE_* 变量删除不影响构建，因为它们已通过 Dockerfile ARG 硬编码

### Claude's Discretion
- verify-doppler-secrets.sh 是否需要更新以覆盖 .env.production 中的额外密钥
- setup-keycloak-full.sh 中 SOPS 替换的具体实现方式
- docs/secrets-management.md 重写的详细程度
- .gitignore 清理的具体范围

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 密钥管理需求
- `.planning/REQUIREMENTS.md` — MIGR-01 to MIGR-04 需求定义
- `.planning/ROADMAP.md` — Phase 41 范围和 Success Criteria
- `.planning/STATE.md` — 项目状态和已锁定决策
- `.planning/phases/39-infisical-infra/39-CONTEXT.md` — Phase 39 Doppler 决策
- `.planning/phases/40-jenkins-pipeline/40-CONTEXT.md` — Phase 40 Pipeline 集成决策

### 要删除的文件
- `docker/.env` — 主密钥文件（删除前验证 Doppler 完整）
- `.env.production` — 前端密钥文件（删除前验证 Doppler 完整）
- `.sops.yaml` — SOPS 配置
- `config/secrets.sops.yaml` — 加密密钥
- `scripts/utils/decrypt-secrets.sh` — SOPS 解密脚本
- `scripts/deploy/deploy-findclass-zero-deps.sh` — 已废弃脚本

### 要更新的文件
- `scripts/lib/secrets.sh` — 移除 docker/.env 回退，DOPPLER_TOKEN 必须设置
- `scripts/setup-keycloak-full.sh` — 移除 SOPS 解密，改用 Doppler 环境变量
- `scripts/deploy/deploy-infrastructure-prod.sh` — 清除残留 SOPS 注释
- `docs/secrets-management.md` — 重写为 Doppler 文档
- `docs/DEVELOPMENT.md` — 移除 SOPS 相关章节
- `README.md` — 移除 SOPS 依赖
- `.gitignore` — 移除 SOPS 模式

### 必须保留的文件
- `scripts/backup/.env.backup` — 备份系统独立密钥（per MIGR-02）
- `config/environments/.env.production.template` — 新环境参考模板
- `config/environments/.env.example` — 示例模板

### Doppler 相关（Phase 39 已创建）
- `scripts/verify-doppler-secrets.sh` — 密钥验证脚本
- `scripts/install-doppler.sh` — CLI 安装脚本
- `scripts/backup/backup-doppler-secrets.sh` — 离线备份脚本

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/verify-doppler-secrets.sh`（Phase 39 创建）— 可直接用于验证密钥完整性
- `scripts/lib/secrets.sh`（Phase 40 创建）— load_secrets() 函数，需修改回退逻辑
- Doppler CLI 已安装在 Jenkins 宿主机（Phase 39 验证）

### Established Patterns
- `load_secrets()` 双模式 → 改为 Doppler-only 模式
- 密钥通过 `set -a; eval; set +a` 注入环境 → 不变
- Jenkins `credentials()` 自动注入 DOPPLER_TOKEN → 不变

### Integration Points
- `scripts/lib/secrets.sh` — 主要修改点（回退逻辑移除）
- `scripts/setup-keycloak-full.sh` — SOPS 引用替换为环境变量
- `.gitignore` — 清理 SOPS 模式
- `docs/` — 文档更新

### 当前 docker/.env 密钥列表（14 个）
POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, KEYCLOAK_ADMIN_USER, KEYCLOAK_ADMIN_PASSWORD, KEYCLOAK_DB_PASSWORD, CLOUDFLARE_TUNNEL_TOKEN, B2_ACCOUNT_ID, B2_APPLICATION_KEY, B2_BUCKET_NAME, B2_PATH, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL

### .env.production 额外密钥
SMTP_HOST, SMTP_PORT, SMTP_FROM, SMTP_USER, SMTP_PASSWORD, RESEND_API_KEY

</code_context>

<specifics>
## Specific Ideas

- 验证顺序：先 verify-doppler-secrets.sh 确认所有密钥在 Doppler 中 → 再删除明文文件
- secrets.sh 改为 Doppler-only 后，手动部署必须 `export DOPPLER_TOKEN=xxx`，不再有回退
- 备份系统完全不受影响 — 独立 .env.backup 不依赖 docker/.env
- Phase 42 的 BFG 清理需要在 Phase 41 确认所有密钥已从文件系统删除后进行

</specifics>

<deferred>
## Deferred Ideas

- noda-site Pipeline 的 Doppler 集成 — 静态站点暂无敏感密钥，未来需要时复用相同模式
- 密钥自动轮换 — Doppler 免费版不支持
- 多环境（dev/staging）— 当前只有生产环境
- 密钥审计日志 — Doppler 免费版不包含

</deferred>

---

*Phase: 41-migration-cleanup*
*Context gathered: 2026-04-19*
