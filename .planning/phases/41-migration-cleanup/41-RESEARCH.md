# Phase 41: 迁移与清理 - Research

**Researched:** 2026-04-19
**Domain:** 密钥管理迁移（明文 .env 删除 + SOPS 代码清理）
**Confidence:** HIGH

## Summary

Phase 41 是密钥管理集中化（v1.8）的收尾阶段。前置条件已全部满足：Phase 39 在 Doppler 中创建了项目并录入了 15 个密钥，Phase 40 实现了 `scripts/lib/secrets.sh` 的双模式 `load_secrets()` 并更新了 3 个 Jenkinsfile 和 3 个手动部署脚本。本阶段的核心任务是：（1）验证 Doppler 中密钥完整性；（2）从 `secrets.sh` 移除 docker/.env 回退路径，使 Doppler 成为唯一密钥源；（3）删除 `docker/.env` 和 `.env.production` 明文文件；（4）删除所有 SOPS 相关代码和引用，更新文档。

**主要建议：** 严格按照 CONTEXT.md 中的决策执行。验证 -> 修改 secrets.sh -> 删除明文文件 -> 清理 SOPS 代码 -> 更新文档。备份系统（`scripts/backup/.env.backup`）完全独立，通过 `scripts/backup/lib/config.sh` 自行加载配置，不依赖 `docker/.env` 或 Doppler，确认不需要任何改动。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 删除明文文件前，运行 `scripts/verify-doppler-secrets.sh` 验证 Doppler 中所有密钥完整
- **D-02:** 验证覆盖范围：docker/.env 的 14 个密钥 + .env.production 中的 SMTP_* 等额外密钥
- **D-03:** 从 `scripts/lib/secrets.sh` 的 `load_secrets()` 中移除 docker/.env 回退路径
- **D-04:** DOPPLER_TOKEN 未设置时，输出明确错误提示并 return 1
- **D-05:** Doppler 成为唯一密钥源，所有部署必须通过 DOPPLER_TOKEN 认证
- **D-06:** 错误提示内容示例：`[ERROR] DOPPLER_TOKEN 未设置。请 export DOPPLER_TOKEN=<service-token> 后重试。`
- **D-07:** 删除 `docker/.env`（14 个基础设施密钥）
- **D-08:** 删除 `.env.production`（前端 + SMTP 密钥）
- **D-09:** 保留 `scripts/backup/.env.backup`（per MIGR-02，备份系统独立运行）
- **D-10:** 保留模板文件 `config/environments/.env.production.template`、`config/environments/.env.example`
- **D-11:** 保留 `scripts/backup/templates/.env.backup`、`scripts/backup/.env.example`
- **D-12:** 删除 SOPS 核心文件：`.sops.yaml`、`config/secrets.sops.yaml`、`scripts/utils/decrypt-secrets.sh`
- **D-13:** 删除已废弃脚本：`scripts/deploy/deploy-findclass-zero-deps.sh`
- **D-14:** 更新 `scripts/setup-keycloak-full.sh` — 移除 SOPS 解密逻辑，改为从环境变量读取 OAuth 凭据
- **D-15:** 更新文档：`docs/secrets-management.md` 重写、`docs/DEVELOPMENT.md` 移除 SOPS、`README.md` 移除 SOPS
- **D-16:** 更新 `.gitignore`：移除 SOPS 相关模式，保留 `docker/.env`
- **D-17:** 移除 `scripts/deploy/deploy-infrastructure-prod.sh` 中残留的 SOPS 检查注释
- **D-18:** VITE_* 公开信息不纳入 Doppler，保持 Dockerfile ARG 硬编码
- **D-19:** .env.production 中的 VITE_* 变量删除不影响构建

### Claude's Discretion
- verify-doppler-secrets.sh 是否需要更新以覆盖 .env.production 中的额外密钥
- setup-keycloak-full.sh 中 SOPS 替换的具体实现方式
- docs/secrets-management.md 重写的详细程度
- .gitignore 清理的具体范围

### Deferred Ideas (OUT OF SCOPE)
- noda-site Pipeline 的 Doppler 集成 — 静态站点暂无敏感密钥
- 密钥自动轮换 — Doppler 免费版不支持
- 多环境（dev/staging）— 当前只有生产环境
- 密钥审计日志 — Doppler 免费版不包含
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| MIGR-01 | 将 .env.production、docker/.env 中所有密钥迁移到 Doppler 并验证完整 | verify-doppler-secrets.sh 已列出 15 个预期密钥，需对比 docker/.env（13 个有效 key）和 .env.production 的完整 key 列表 |
| MIGR-02 | 备份系统 scripts/backup/.env.backup 保持独立明文文件不变 | 确认备份系统通过 config.sh 自行加载 .env.backup，与 docker/.env 无任何依赖关系 |
| MIGR-03 | 迁移验证通过后删除 .env.production 和 docker/.env 明文文件 | 文件位置确认：docker/.env（存在）、.env.production（存在），删除前需 verify-doppler-secrets.sh 通过 |
| MIGR-04 | 删除旧的 SOPS 相关代码（scripts/utils/decrypt-secrets.sh 及相关引用） | SOPS 引用分布在 6 个脚本 + 7 个文档中，详见下方完整清单 |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| 密钥验证 | CLI / Jenkins | - | verify-doppler-secrets.sh 通过 DOPPLER_TOKEN 认证，验证 Doppler 中密钥完整性 |
| 密钥加载 | Shell 脚本层 | - | secrets.sh load_secrets() 是所有脚本的密钥入口，Doppler-only 后不再有文件回退 |
| 备份系统密钥 | Docker 容器 | - | noda-ops 容器内独立加载 .env.backup，与 Doppler/主密钥流完全解耦 |
| 文档更新 | 文档层 | - | docs/ 和 README.md 中 SOPS 引用需要替换为 Doppler 内容 |

## Standard Stack

### Core

本阶段不引入新库或工具。所有工具已在 Phase 39/40 安装和验证。

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Doppler CLI | 已安装 | 密钥拉取和验证 | Phase 39 安装验证通过 |
| age | 已安装 | B2 备份加密 | backup-doppler-secrets.sh 使用 |
| bash | 系统自带 | 脚本执行 | 所有脚本运行环境 |

### Supporting

| File | Purpose | When to Use |
|------|---------|-------------|
| `scripts/verify-doppler-secrets.sh` | 密钥完整性验证 | 删除明文文件前的验证门禁 |
| `scripts/lib/secrets.sh` | 密钥加载库 | 所有部署脚本的密钥入口 |
| `scripts/backup/backup-doppler-secrets.sh` | Doppler 离线备份 | 注意：此脚本从 .sops.yaml 读取 age 公钥（需更新） |

### Alternatives Considered

本阶段是清理阶段，无替代方案考虑。

## Architecture Patterns

### 密钥加载流（改造后）

```
部署触发（Jenkins Pipeline / 手动脚本）
    │
    ├─ Jenkins Pipeline
    │   └─ withCredentials 绑定 DOPPLER_TOKEN
    │       └─ load_secrets() 检测到 DOPPLER_TOKEN
    │           └─ doppler secrets download --no-file --format=env
    │               └─ set -a; eval "$_secrets"; set +a
    │
    └─ 手动部署脚本
        └─ 要求用户 export DOPPLER_TOKEN=xxx
            └─ load_secrets() 检测到 DOPPLER_TOKEN
                └─ doppler secrets download --no-file --format=env
                    └─ set -a; eval "$_secrets"; set +a

    ┌─ DOPPLER_TOKEN 未设置 ──→ [ERROR] 明确报错 + return 1
    │                          不再回退到 docker/.env（已删除）
```

### 备份系统密钥流（不变）

```
noda-ops 容器启动
    └─ docker-compose.yml 注入环境变量
        └─ scripts/backup/lib/config.sh load_config()
            ├─ 默认值（代码内置）
            ├─ .env.backup 文件覆盖
            └─ 环境变量覆盖（最高优先级）

注：完全独立于 Doppler / docker/.env / secrets.sh
```

### 要删除的文件清单

| 文件 | 决策编号 | 说明 |
|------|---------|------|
| `docker/.env` | D-07 | 主密钥文件，13 个有效 key |
| `.env.production` | D-08 | 前端 + SMTP 密钥 |
| `.sops.yaml` | D-12 | SOPS 配置（含 age 公钥） |
| `config/secrets.sops.yaml` | D-12 | 加密密钥文件 |
| `scripts/utils/decrypt-secrets.sh` | D-12 | SOPS 解密脚本 |
| `scripts/deploy/deploy-findclass-zero-deps.sh` | D-13 | 已废弃脚本 |

### 要更新的文件清单

| 文件 | 决策编号 | 修改内容 |
|------|---------|---------|
| `scripts/lib/secrets.sh` | D-03/D-04/D-06 | 移除 docker/.env 回退，DOPPLER_TOKEN 必须设置 |
| `scripts/setup-keycloak-full.sh` | D-14 | 移除 SOPS 解密逻辑（步骤 1），改为从环境变量读取 GOOGLE_CLIENT_ID/SECRET |
| `scripts/deploy/deploy-infrastructure-prod.sh` | D-17 | 移除第 216 行 SOPS 注释 |
| `scripts/backup/backup-doppler-secrets.sh` | 隐含 | 第 65-77 行从 .sops.yaml 读取 age 公钥，需改为从环境变量或直接硬编码公钥 |
| `docs/secrets-management.md` | D-15 | 重写为 Doppler 密钥管理文档 |
| `docs/DEVELOPMENT.md` | D-15 | 移除 SOPS 安装说明、更新密钥管理章节 |
| `README.md` | D-15 | 移除 SOPS 依赖提及 |
| `.gitignore` | D-16 | 移除 SOPS 相关模式 |
| `docs/architecture.md` | D-15（隐含） | 更新密钥管理描述（第 77、89、263 行等 SOPS 引用） |
| `docs/GETTING-STARTED.md` | D-15（隐含） | 移除 SOPS/age 前置要求、更新部署说明 |
| `docs/CONFIGURATION.md` | D-15（隐含） | 更新密钥文件表和加密章节 |
| `docs/KEYCLOAK_SCRIPTS.md` | D-15（隐含） | 移除 SOPS 解密说明 |
| `docs/DEPLOYMENT_GUIDE.md` | D-15（隐含） | 移除 SOPS 解密步骤和故障排除 |

### 必须保留的文件

| 文件 | 原因 |
|------|------|
| `scripts/backup/.env.backup` | 备份系统独立密钥（MIGR-02） |
| `scripts/backup/.env.example` | 备份系统模板 |
| `scripts/backup/templates/.env.backup` | 备份系统模板 |
| `config/environments/.env.production.template` | 新环境参考 |
| `config/environments/.env.example` | 新环境参考 |
| `config/keys/git-age-key.txt` | backup-doppler-secrets.sh 的 age 加密需要（需确认是否保留） |

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 密钥验证 | 自定义比较逻辑 | verify-doppler-secrets.sh | Phase 39 已创建，验证 15 个密钥完整性 |
| 密钥加载 | 自定义 Doppler 集成 | secrets.sh load_secrets() | Phase 40 已实现 Doppler 模式 |

**关键洞察：** 本阶段主要是删除和清理，不需要编写新的复杂逻辑。唯一需要新代码的是 setup-keycloak-full.sh 的 SOPS 替换和 backup-doppler-secrets.sh 的 age 公钥来源调整。

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | Doppler 云端 15 个密钥已录入（Phase 39 验证） | 无需变更 — 验证完整性即可 |
| Stored data | `scripts/backup/.env.backup` 独立密钥文件 | 不动 — MIGR-02 明确保留 |
| Stored data | `config/keys/git-age-key.txt` age 私钥 | 需决策 — backup-doppler-secrets.sh 仍需 age 加密 |
| Live service config | Jenkins Credentials Store 中的 `doppler-service-token` | 不动 — Phase 39 已配置 |
| Live service config | `config/nginx/snippets/upstream-*.conf` .gitignore 条目 | 不动 — 与 SOPS 无关 |
| OS-registered state | 无 | 无需变更 |
| Secrets/env vars | DOPPLER_TOKEN 在 Jenkins 中通过 credentials 注入 | 不动 — Phase 40 已配置 |
| Build artifacts | `config/secrets.sops.yaml` 在 Git 历史中 | Phase 42 用 BFG 清理（非本阶段） |
| Build artifacts | `docker/.env` 曾提交到 Git（commit c15faba） | Phase 42 用 BFG 清理（非本阶段） |

**注意：** `config/keys/git-age-key.txt` 的去留需要确认。`backup-doppler-secrets.sh` 使用 age 加密 Doppler 备份文件再上传 B2，需要 age 公钥。当前从 `.sops.yaml` 读取公钥，删除 `.sops.yaml` 后需替代方案。建议保留 age 密钥文件或改为硬编码公钥到脚本中。

## Common Pitfalls

### Pitfall 1: backup-doppler-secrets.sh 因 .sops.yaml 删除而中断
**What goes wrong:** backup-doppler-secrets.sh 第 65-77 行从 `.sops.yaml` 读取 age 公钥用于加密备份。删除 `.sops.yaml` 后脚本将无法获取公钥。
**Why it happens:** Phase 39 创建 backup-doppler-secrets.sh 时，.sops.yaml 仍存在，复用了已有的 age 公钥。
**How to avoid:** 在删除 `.sops.yaml` 前，更新 backup-doppler-secrets.sh 的公钥获取方式。推荐方案：将 age 公钥硬编码到脚本中（公钥可公开，不同于私钥），或改为从 `AGE_PUBLIC_KEY` 环境变量读取并移除 .sops.yaml 回退。
**Warning signs:** backup-doppler-secrets.sh --dry-run 执行时报 `AGE_PUBLIC_KEY 未设置且无法从 .sops.yaml 读取`。

### Pitfall 2: setup-keycloak-full.sh SOPS 替换后缺少环境变量
**What goes wrong:** 当前 setup-keycloak-full.sh 步骤 1 通过 SOPS 解密获取 GOOGLE_CLIENT_ID 和 GOOGLE_CLIENT_SECRET。改为从环境变量读取后，如果 Doppler 未将这两个变量注入环境，脚本将失败。
**Why it happens:** GOOGLE_CLIENT_ID 和 GOOGLE_CLIENT_SECRET 存储在 `config/secrets.sops.yaml` 中（已验证：文件第 9-10 行），但需确认这两个密钥是否已录入 Doppler。
**How to avoid:** （1）先确认 GOOGLE_CLIENT_ID 和 GOOGLE_CLIENT_SECRET 是否在 Doppler 15 个密钥中（verify-doppler-secrets.sh 的 EXPECTED_SECRETS 列表中未包含这两个）；（2）如未录入，需先在 Doppler 中添加这两个密钥。
**Warning signs:** verify-doppler-secrets.sh 未验证 Google OAuth 密钥。

### Pitfall 3: verify-doppler-secrets.sh 密钥列表不完整
**What goes wrong:** 当前 verify-doppler-secrets.sh 列出 15 个预期密钥，但 docker/.env 实际有 13 个有效 key（B2_ACCOUNT_ID, B2_APPLICATION_KEY, B2_BUCKET_NAME, B2_PATH, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, KEYCLOAK_ADMIN_USER, KEYCLOAK_ADMIN_PASSWORD, KEYCLOAK_DB_PASSWORD, CLOUDFLARE_TUNNEL_TOKEN, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL），.env.production 有额外的 SMTP_* 和 RESEND_API_KEY。verify 脚本的 15 个列表中未包含 GOOGLE_CLIENT_ID 和 GOOGLE_CLIENT_SECRET。
**Why it happens:** config/secrets.sops.yaml 包含 Google OAuth 凭据，这些凭据不存储在 docker/.env 或 .env.production 中，而是直接被 setup-keycloak-full.sh 通过 SOPS 解密获取。
**How to avoid:** 更新 verify-doppler-secrets.sh 将 GOOGLE_CLIENT_ID 和 GOOGLE_CLIENT_SECRET 加入预期密钥列表（如果已录入 Doppler），或在 setup-keycloak-full.sh 中单独处理。
**Warning signs:** Doppler 中缺少 Google OAuth 密钥导致 setup-keycloak-full.sh 失败。

### Pitfall 4: .gitignore 过度清理
**What goes wrong:** 移除 SOPS 相关 .gitignore 条目时误删了仍需要的条目。
**Why it happens:** .gitignore 中 SOPS 相关条目与非 SOPS 条目混杂。
**How to avoid:** 精确识别需要移除的条目：`*.decrypted`（SOPS 解密产物）、`config/secrets.sops.yaml.bak`（SOPS 备份）、`!config/secrets.sops.yaml`（SOPS 加密文件例外）、`config/secrets.local.yaml`（SOPS 本地密钥）、`config/keys/`（age 密钥目录 — 注意这个仍被 backup-doppler-secrets.sh 间接需要）。保留 `docker/.env`（防止未来误提交）。
**Warning signs:** git status 显示 config/keys/ 或其他应忽略的文件变为可追踪。

### Pitfall 5: 文档更新遗漏 SOPS 引用
**What goes wrong:** 只更新了明确列出的 3 个文档（secrets-management.md、DEVELOPMENT.md、README.md），但其他 4 个文档中也有 SOPS 引用。
**Why it happens:** Grep 扫描发现 SOPS 引用分布在 7 个文档中：secrets-management.md、DEVELOPMENT.md、README.md、architecture.md、GETTING-STARTED.md、CONFIGURATION.md、KEYCLOAK_SCRIPTS.md、DEPLOYMENT_GUIDE.md。
**How to avoid:** 使用 `grep -rl 'sops\|SOPS' docs/` 确保所有文档都被覆盖。
**Warning signs:** 用户按照文档操作时遇到 SOPS 相关步骤已不存在。

## Code Examples

### secrets.sh 改造后（Doppler-only）

```bash
# 改造要点：移除 else 分支中的 .env 回退逻辑，DOPPLER_TOKEN 未设置时直接报错

load_secrets()
{
    if ! declare -f log_info >/dev/null 2>&1; then
        log_info()    { echo "[INFO] $*"; }
        log_error()   { echo "[ERROR] $*" >&2; }
        log_success() { echo "[OK] $*"; }
        log_warn()    { echo "[WARN] $*"; }
    fi

    if [ -z "${DOPPLER_TOKEN:-}" ]; then
        log_error "DOPPLER_TOKEN 未设置。请 export DOPPLER_TOKEN=<service-token> 后重试。"
        return 1
    fi

    if ! command -v doppler >/dev/null 2>&1; then
        log_error "doppler CLI 不可用。安装: brew install dopplerhq/cli/doppler"
        return 1
    fi

    local _secrets
    _secrets=$(doppler secrets download --no-file --format=env --project noda --config prd 2>/dev/null)

    if [ $? -ne 0 ]; then
        log_error "Doppler 密钥拉取失败（检查 DOPPLER_TOKEN 是否有效）"
        return 1
    fi

    set -a
    eval "$_secrets"
    set +a

    log_success "密钥已从 Doppler 加载（project=noda, config=prd）"
}
```

### setup-keycloak-full.sh 步骤 1 改造

```bash
# 改造前：SOPS 解密获取 Google OAuth 凭据
# 改造后：从 Doppler 注入的环境变量直接读取

log_info "步骤 1/6: 获取 Google OAuth 凭据"

# 密钥由 Doppler 通过 load_secrets() 注入到环境变量中
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"

if [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ]; then
    log_error "缺少 Google OAuth 凭据（GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET）"
    log_error "请确保 DOPPLER_TOKEN 已设置，且 Doppler 中已配置这些密钥"
    exit 1
fi

log_success "凭据已从环境变量获取"
log_info "Client ID: ${GOOGLE_CLIENT_ID:0:20}..."
```

### backup-doppler-secrets.sh age 公钥获取改造

```bash
# 改造前：从 .sops.yaml 读取 age 公钥
# 改造后：硬编码公钥到脚本中（公钥可安全公开）

# Doppler 备份加密公钥（age 公钥，可安全公开）
AGE_PUBLIC_KEY="${AGE_PUBLIC_KEY:-age1869smm93r878hzgarhv5uggkg58mttaz54l05wwc0s3zmp264e7qw7rc3w}"

if [[ -z "$AGE_PUBLIC_KEY" ]]; then
    error "AGE_PUBLIC_KEY 未设置"
    error "使用方法: export AGE_PUBLIC_KEY='age1xxx...'"
    exit 1
fi
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| SOPS + age 本地加密 | Doppler 云端密钥管理 | Phase 39 (2026-04-19) | 密钥不再存储在 Git 中（即使加密） |
| source docker/.env 明文回退 | Doppler-only（无回退） | Phase 41 | DOPPLER_TOKEN 成为部署必需品 |
| decrypt-secrets.sh 运行时解密 | Doppler CLI 直接拉取 | Phase 40 | 简化了密钥获取链路 |

**Deprecated/outdated:**
- SOPS + age 加密方案：被 Doppler 完全替代
- `scripts/utils/decrypt-secrets.sh`：SOPS 时代的解密脚本
- `config/secrets.sops.yaml`：SOPS 加密的密钥文件
- `.sops.yaml`：SOPS 配置文件
- `scripts/deploy/deploy-findclass-zero-deps.sh`：已标记废弃的旧部署脚本

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | GOOGLE_CLIENT_ID 和 GOOGLE_CLIENT_SECRET 已录入 Doppler 的 15 个密钥中 | Pitfall 2 | setup-keycloak-full.sh 改造后无法获取 Google OAuth 凭据 |
| A2 | config/keys/git-age-key.txt 在删除 SOPS 后仍需保留（backup-doppler-secrets.sh 使用） | Runtime State Inventory | Doppler 备份加密链路中断 |
| A3 | Doppler 中 15 个密钥与 docker/.env + .env.production 中的密钥完全一致 | Pitfall 3 | 删除明文文件后缺少密钥导致部署失败 |
| A4 | B2_ACCOUNT_ID, B2_APPLICATION_KEY 等在 Doppler 和 docker/.env 中的值相同 | Standard Stack | 备份系统从 Doppler 获取的 B2 凭据可能不一致 |

**需要用户确认：**
- A1：Google OAuth 凭据是否已录入 Doppler？verify-doppler-secrets.sh 的 EXPECTED_SECRETS 中不包含 GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET
- A2：是否保留 config/keys/ 目录和 age 私钥？还是改用其他方案？

## Open Questions

1. **Google OAuth 密钥是否在 Doppler 中？**
   - What we know: verify-doppler-secrets.sh 列出 15 个预期密钥，不包含 GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET。config/secrets.sops.yaml 包含这两个密钥。
   - What's unclear: 这两个密钥是否已手动录入 Doppler？Phase 39 的 EXECUTION 确认录入了 15 个密钥，但未明确列出是否包含 Google OAuth。
   - Recommendation: 在 verify-doppler-secrets.sh 中添加 GOOGLE_CLIENT_ID 和 GOOGLE_CLIENT_SECRET 验证。如果 Doppler 中缺少，先补充录入再继续清理。

2. **config/keys/ 目录和 age 私钥是否保留？**
   - What we know: backup-doppler-secrets.sh 使用 age 公钥加密备份文件。age 私钥（git-age-key.txt）用于解密备份恢复。
   - What's unclear: 删除 SOPS 后，age 工具链是否仍需要。Doppler 备份脚本只用公钥加密，私钥只在恢复时需要。
   - Recommendation: 保留 config/keys/ 目录和 age 私钥，但在 .gitignore 中继续忽略。在 backup-doppler-secrets.sh 中将公钥硬编码为默认值。

3. **verify-doppler-secrets.sh 是否需要更新？**
   - What we know: 当前验证 15 个密钥。docker/.env 有 13 个有效 key（B2_PATH 只在 verify 脚本中出现但不在 docker/.env 中？需确认），.env.production 有 SMTP_* 等额外密钥。加上 Google OAuth 可能有 17+ 个密钥。
   - What's unclear: Doppler 中实际存储了多少个密钥？
   - Recommendation: 执行 `doppler secrets --only-names` 对比确认，然后更新 verify 脚本。

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Doppler CLI | 密钥拉取/验证 | 已确认（Phase 39 安装） | 3.x+ | - |
| bash 3.2+ | 所有脚本 | macOS 自带 | 3.2 | - |
| age | backup-doppler-secrets.sh | 已确认 | 1.3+ | - |
| b2 CLI | B2 上传（非本阶段必须） | 已确认 | - | --dry-run 模式 |
| git | 文件操作 | 已确认 | - | - |

**Missing dependencies with no fallback:**
- 无

**Missing dependencies with fallback:**
- 无

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bash 手动验证（无自动化测试框架） |
| Config file | 无 |
| Quick run command | `DOPPLER_TOKEN='dp.st.prd.xxx' bash scripts/verify-doppler-secrets.sh` |
| Full suite command | 无正式测试套件 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| MIGR-01 | Doppler 中所有密钥完整 | smoke | `bash scripts/verify-doppler-secrets.sh` | Yes (Phase 39) |
| MIGR-02 | 备份系统不受影响 | manual-only | 手动检查 backup/.env.backup 存在 | - |
| MIGR-03 | 明文文件已删除 | manual-only | `ls docker/.env .env.production 2>&1` | - |
| MIGR-04 | SOPS 代码已清理 | manual-only | `grep -rl 'sops\|SOPS' scripts/` 应无结果 | - |

### Sampling Rate
- **Per task commit:** `bash scripts/verify-doppler-secrets.sh`
- **Per wave merge:** verify-doppler-secrets.sh + grep 扫描 SOPS 残留
- **Phase gate:** 所有 MIGR 需求验证通过

### Wave 0 Gaps
- 无正式测试框架 — 本阶段是清理工作，验证以手动 smoke test 为主
- verify-doppler-secrets.sh 可能需要更新密钥列表（取决于 Open Question 1/3）

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | 不涉及认证变更 |
| V3 Session Management | no | 不涉及会话管理 |
| V4 Access Control | no | 不涉及访问控制 |
| V5 Input Validation | no | 不涉及输入验证 |
| V6 Cryptography | yes | 删除 SOPS 加密体系，保留 age 加密用于 Doppler 备份 |

### Known Threat Patterns for Shell/Docker 密钥管理

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 明文密钥泄露 | Information Disclosure | 删除明文 .env 文件（MIGR-03） |
| 密钥硬编码在脚本中 | Information Disclosure | Doppler 环境变量注入 |
| 历史密钥残留 | Information Disclosure | Phase 42 BFG 清理（非本阶段） |
| Doppler 服务中断 | Denial of Service | 手动脚本需要 DOPPLER_TOKEN（Phase 41 后无回退） |

## Sources

### Primary (HIGH confidence)
- 项目代码库直接扫描 — `scripts/lib/secrets.sh`、`scripts/verify-doppler-secrets.sh`、`scripts/setup-keycloak-full.sh`、`scripts/deploy/deploy-infrastructure-prod.sh`、`scripts/backup/backup-doppler-secrets.sh`、`scripts/utils/decrypt-secrets.sh` 全部已读取分析
- `.gitignore`、`docs/*.md`、`README.md` 全部已读取分析 SOPS 引用
- `.planning/phases/39-infisical-infra/39-CONTEXT.md` — Phase 39 决策上下文
- `.planning/phases/40-jenkins-pipeline/40-CONTEXT.md` — Phase 40 决策上下文
- `config/secrets.sops.yaml` — 确认包含 Google OAuth 凭据（cloudflare_tunnel_token, postgres_password, keycloak_admin_password, google_oauth_client_id, google_oauth_client_secret）

### Secondary (MEDIUM confidence)
- `.planning/REQUIREMENTS.md` — MIGR-01 到 MIGR-04 需求定义
- `.planning/STATE.md` — 项目状态和历史决策

### Tertiary (LOW confidence)
- 无

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - 不引入新工具，所有工具已在 Phase 39/40 验证
- Architecture: HIGH - 所有文件和依赖关系已通过代码扫描确认
- Pitfalls: HIGH - 基于 grep 扫描所有 SOPS 引用 + 代码逻辑分析

**Research date:** 2026-04-19
**Valid until:** 30 天（稳定，无外部依赖变化）
