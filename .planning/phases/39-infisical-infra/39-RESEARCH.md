# Phase 39: 密钥管理基础设施搭建 - Research

**Researched:** 2026-04-19
**Domain:** Doppler CLI 密钥管理 + Jenkins CI/CD 集成 + 离线备份
**Confidence:** HIGH

## Summary

本阶段在 Jenkins 宿主机上搭建 Doppler 密钥管理基础设施：安装 Doppler CLI、在 Doppler 云端创建项目 "noda"（单环境 "prod"）、将 ~15 个密钥从两个 .env 文件迁移到 Doppler Dashboard、创建 Service Token 并存储到 Jenkins Credentials、以及配置离线备份到密码管理器和 B2 加密快照。

Doppler CLI 最新稳定版 3.75.3 [VERIFIED: brew info dopplerhq/cli/doppler]，通过 `brew install dopplerhq/cli/doppler` 安装（需先 `brew tap dopplerhq/cli`）[VERIFIED: Context7/Docs]。认证流程极其简单：单个 Service Token (`dp.st.prd.xxx`) 作为 `DOPPLER_TOKEN` 环境变量即可访问所有密钥 [VERIFIED: Context7/Docs]。Jenkins 集成只需将 Service Token 存为 Secret text credential，Pipeline 中通过 `environment { DOPPLER_TOKEN = credentials('DOPPLER_TOKEN') }` 读取 [VERIFIED: Context7/Docs - Jenkins]。

Doppler Developer 免费版限制：10 个项目、4 个环境/项目、50 个 service token、API 240 reads/min [VERIFIED: Context7/Docs - Platform Limits]。Noda 项目仅需 1 个项目 + 1 个环境 + 1 个 service token，远低于免费额度。

**Primary recommendation:** 先在 Doppler Dashboard 创建项目和 Service Token（需人工操作），然后在 Jenkins 宿主机安装 CLI 并验证认证，最后配置离线备份。所有密钥导入可通过 `doppler secrets upload` 命令或 Dashboard UI 完成。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 使用 Doppler（Developer 免费版）替代 Infisical Cloud。理由：认证流程更简单（单 token）、CLI 安装更简洁、免费额度（50 service tokens、10 projects、4 environments）对 ~20 密钥的项目绑绰有余
- **D-02:** 通过 `brew install dopplerhq/cli/doppler` 安装到 Jenkins 宿主机。服务器已有 Homebrew（Phase 26 安装 PostgreSQL 时使用），无需额外安装包管理器
- **D-03:** 单项目 "noda"，单环境 "prod"，所有密钥平铺管理。密钥数量少，无需文件夹或多项目分离
- **D-04:** Doppler Service Token（`dp.st.prd.xxx`）存储到 Jenkins Credentials（Secret text 类型）。Pipeline 通过 `withCredentials` 读取，日志自动遮蔽。手动部署回退脚本要求用户手动设置 `DOPPLER_TOKEN` 环境变量
- **D-05:** 两层备份策略：（1）Service Token 存到密码管理器；（2）定期 `doppler secrets download --format=env` 导出 .env 文件，加密后上传到 Backblaze B2
- **D-06:** 备份系统 `scripts/backup/.env.backup` 保持独立明文文件，不迁移到 Doppler
- **D-07:** VITE_* 公开信息不纳入 Doppler，保持 --build-arg 硬编码

### Claude's Discretion
- Doppler CLI 具体安装脚本实现细节
- B2 加密快照的具体加密方式（age/gpg）
- Service Token 权限范围（read-only vs read-write）

### Deferred Ideas (OUT OF SCOPE)
- 密钥版本管理 -- Doppler Developer 免费版无此功能，Team 版才有
- 密钥自动轮换 -- 未来可考虑 Team 版的自动轮换功能
- 多环境（dev/staging）-- 当前只有生产环境，需要时再添加
- Infisical Cloud 作为升级路径 -- 如果 Doppler 免费版不满足需求，可迁移到 Infisical 或 Doppler Team
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| INFRA-01 | 在 Jenkins 宿主机安装 Doppler CLI，通过脚本自动化安装 | `brew tap dopplerhq/cli && brew install dopplerhq/cli/doppler` 安装最新版 3.75.3；备选 `(curl -Ls https://cli.doppler.com/install.sh \|\| wget -qO- https://cli.doppler.com/install.sh) \| sudo sh` [VERIFIED: Context7/Docs] |
| INFRA-02 | 创建 Doppler 项目 "noda"，单环境 "prod"，所有密钥平铺管理 | Dashboard 手动创建项目 + 环境是最简方案；CLI 可用 `doppler setup` 交互式选择；密钥可通过 `doppler secrets upload .env` 或 Dashboard UI 导入 [VERIFIED: Context7/Docs] |
| INFRA-03 | 配置 Doppler Service Token，存储到 Jenkins Credentials（Secret text） | Dashboard: Project -> Config -> Access -> Generate Service Token；CLI: `doppler configs tokens create jenkins --plain --project noda --config prod`；Jenkins: Manage Credentials -> Add Credential -> Secret text -> ID: DOPPLER_TOKEN [VERIFIED: Context7/Docs] |
| INFRA-04 | Doppler 凭据离线备份到密码管理器 + B2 加密快照 | Service Token 存密码管理器（人工操作）；`doppler secrets download --format=env --no-file` 导出 .env，age 加密后上传 B2；Doppler CLI 内置 fallback 机制 `doppler secrets download --passphrase` [VERIFIED: Context7/Docs] |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Doppler CLI 安装 | Jenkins 宿主机 (OS) | — | CLI 二进制文件安装到宿主机，供 Jenkins Pipeline 和手动部署使用 |
| Doppler 项目/密钥管理 | Doppler Cloud (SaaS) | — | 密钥存储在 Doppler 云端，CLI/Dashboard 操作 |
| Service Token 认证 | Jenkins Credentials Store | — | Token 作为 Secret text credential 存储，Pipeline 中 withCredentials 读取 |
| 离线备份 | B2 Cloud Storage | 密码管理器 | B2 存储加密快照，密码管理器存储 Service Token 明文 |
| 密钥消费 | Jenkins Pipeline | 手动部署脚本 | Pipeline 通过 DOPPLER_TOKEN 环境变量自动拉取；手动脚本需人工设置 |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Doppler CLI | 3.75.3 | 密钥拉取、认证、管理 | 官方 CLI，brew 安装，支持 secrets download/upload/run [VERIFIED: brew info] |
| Doppler Service Token | dp.st.prd.* | 非交互式 CI/CD 认证 | 单 token 认证，无需 JWT 交换，支持 read-only 权限 [VERIFIED: Context7/Docs] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| age | 已安装 | 加密备份快照 | B2 加密上传时使用；项目已有 age（SOPS 依赖） |
| gnupg | 已安装 | Doppler CLI 签名验证 | brew 安装 Doppler 时需要 gnupg 做二进制签名验证 [VERIFIED: Context7/Docs] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| brew 安装 | curl install.sh | install.sh 更适合 CI 临时环境，但宿主机持久安装用 brew 更易管理和更新 |
| read-only Service Token | read-write Service Token | Jenkins 只需拉取密钥，read-only 更安全；写入权限仅在 Dashboard 或本地 doppler login 时需要 |
| age 加密 B2 快照 | gpg 加密 | age 更简单（项目已在使用，SOPS 依赖）；gpg 功能更多但配置复杂 |

**Installation:**
```bash
# 1. 安装 Doppler CLI（Jenkins 宿主机，一次性操作）
brew tap dopplerhq/cli
brew install dopplerhq/cli/doppler

# 验证安装
doppler --version

# 2. 备选：curl 安装脚本（适用于无 Homebrew 的环境）
(curl -Ls --tlsv1.2 --proto "=https" --retry 3 https://cli.doppler.com/install.sh || wget -t 3 -qO- https://cli.doppler.com/install.sh) | sudo sh
```

**Version verification:** Doppler CLI 3.75.3 [VERIFIED: brew info dopplerhq/cli/doppler, 2026-04-19]

## Architecture Patterns

### System Architecture Diagram

```
Jenkins Pipeline                  Jenkins 宿主机               Doppler Cloud
┌─────────────────┐              ┌──────────────────┐        ┌────────────────┐
│ Jenkinsfile     │              │                  │        │  Project "noda"│
│                 │  DOPPLER_TOKEN│  Doppler CLI     │ HTTPS  │  Config "prod" │
│ environment {   │─────────────>│  (3.75.3)        │───────>│                │
│   DOPPLER_TOKEN │   (env var)  │                  │<- ─ ─ ─│  ~15 secrets   │
│     =credentials│              │  doppler secrets │  JSON  │                │
│ }               │              │  download        │        │  Service Token │
│                 │              │  --format=env     │        │  (read-only)   │
│ sh 'doppler     │              │  --no-file       │        └────────────────┘
│  secrets download│              │                  │              │
│  --format=env'  │              └──────┬───────────┘              │
└─────────────────┘                     │                          │
                                        │                          │
                            ┌───────────┴───────────┐    ┌────────┴────────┐
                            │                       │    │                 │
                            │  离线备份              │    │  密码管理器      │
                            │  age 加密 -> B2       │    │  (Service Token │
                            │                       │    │   明文存储)      │
                            └───────────────────────┘    └─────────────────┘
```

### Recommended Project Structure
```
# Phase 39 不改变项目文件结构
# 新增配置仅在 Jenkins Credentials Store（非文件）
# 离线备份脚本可放在 scripts/backup/ 目录下（Phase 42 实现）
```

### Pattern 1: Service Token 认证模式
**What:** 通过单个环境变量 `DOPPLER_TOKEN` 完成所有认证
**When to use:** CI/CD 环境、脚本自动化
**Example:**
```bash
# Source: Context7/Docs - Service Tokens
export DOPPLER_TOKEN='dp.st.prd.xxxx'
doppler secrets download --format=env --no-file
# 输出 .env 格式的所有密钥到 stdout
```

### Pattern 2: Jenkins Pipeline 集成
**What:** Jenkins environment block + credentials 绑定
**When to use:** Jenkinsfile 中所有需要密钥的 Pipeline
**Example:**
```groovy
// Source: Context7/Docs - Jenkins Integration
pipeline {
    agent any
    environment {
        DOPPLER_TOKEN = credentials('DOPPLER_TOKEN')
    }
    stages {
        stage('Fetch Secrets') {
            steps {
                sh '''
                    doppler secrets download --format=env --no-file > docker/.env
                '''
            }
        }
    }
}
```

### Pattern 3: 密钥离线备份（Fallback）
**What:** 加密快照 + passphrase 保护
**When to use:** 定期备份、灾难恢复
**Example:**
```bash
# Source: Context7/Docs - High Availability
# 加密下载到文件（使用 passphrase 保护）
doppler secrets download --format=json --passphrase="$BACKUP_PASSPHRASE" ./doppler-backup.json

# 或者明文 .env 格式 + age 加密（推荐，与现有 SOPS/age 工具链一致）
doppler secrets download --format=env --no-file | age -r "$AGE_PUBLIC_KEY" -o backup.env.age
```

### Anti-Patterns to Avoid
- **直接在命令行传递 Service Token:** `doppler secrets download --token=dp.st.prd.xxx` 会将 token 暴露在进程列表和 bash history 中。应使用环境变量 `export DOPPLER_TOKEN=xxx` [VERIFIED: Context7/Docs]
- **在 Jenkinsfile 中硬编码 token:** 应使用 Jenkins Credentials Store，`credentials('DOPPLER_TOKEN')` 自动遮蔽日志 [VERIFIED: Context7/Docs - Jenkins]
- **将 VITE_* 纳入 Doppler:** VITE_* 是构建时注入的公开信息（嵌入 JS），不是密钥，保持 --build-arg 硬编码即可
- **迁移备份系统密钥:** `scripts/backup/.env.backup` 是最后防线的独立文件，不应依赖任何外部服务

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 密钥加密备份 | 自己写 AES 加密脚本 | `doppler secrets download --passphrase` 或 `age` 加密 | Doppler CLI 内置加密下载；age 是成熟工具，SOPS 已在用 |
| JWT token 刷新 | 自己管理 token 过期刷新 | Doppler Service Token（长期有效，无过期） | Service Token 不会自动过期，除非手动 revoke 或设置 expiration [VERIFIED: Context7/Docs] |
| .env 文件解析和合并 | 自己写 env 解析器 | `doppler secrets download --format=env --no-file` | 直接输出标准 .env 格式，无需解析 |

**Key insight:** Doppler 的认证模型比 Infisical 简单得多。不需要 Client ID + Secret -> JWT 交换流程，单个 Service Token 直接使用，无过期时间（除非手动设置）。

## Runtime State Inventory

> 本阶段不涉及 rename/refactor/migration，跳过此节。

## Common Pitfalls

### Pitfall 1: Doppler CLI 需要 gnupg 依赖
**What goes wrong:** `brew install dopplerhq/cli/doppler` 需要先安装 `gnupg`，否则签名验证失败
**Why it happens:** Doppler CLI 二进制使用 GPG 签名，brew formula 要求 gnupg 作为验证工具
**How to avoid:** 安装前确认 gnupg 已安装：`brew install gnupg` [VERIFIED: Context7/Docs]
**Warning signs:** 安装时报 gnupg 相关错误

### Pitfall 2: brew tap 需要先执行
**What goes wrong:** 直接 `brew install dopplerhq/cli/doppler` 报 "No available formula"
**Why it happens:** 需要先 `brew tap dopplerhq/cli` 注册 tap 源
**How to avoid:** 安装分两步：先 tap 再 install [VERIFIED: brew info 测试确认]
**Warning signs:** "No available formula or cask with the name 'dopplerhq/cli/doppler'"

### Pitfall 3: Service Token 只显示一次
**What goes wrong:** 创建 Service Token 后忘记保存，之后无法再查看
**Why it happens:** Doppler 安全设计，token 值仅在创建时显示一次
**How to avoid:** 创建后立即复制到密码管理器和 Jenkins Credentials [VERIFIED: Context7/Docs]
**Warning signs:** Dashboard 中 token 只显示 `dp.st.prd.xxxx...` 的掩码版本

### Pitfall 4: 密钥名冲突（两个 .env 文件有重叠 key）
**What goes wrong:** docker/.env 和 .env.production 有 7 个重叠 key（POSTGRES_*, KEYCLOAK_*, CLOUDFLARE_TUNNEL_TOKEN），但 Doppler 单项目只存一份
**Why it happens:** 两个文件本来就是为了不同消费方复制了相同值
**How to avoid:** 这不是问题——Doppler 单项目平铺管理正是为了消除这种冗余。迁移后每个 key 只存一份
**Warning signs:** 无，这正是 D-03 的设计意图

### Pitfall 5: Doppler SaaS 宕机导致无法部署
**What goes wrong:** Doppler 服务不可用时，Pipeline 无法拉取密钥，部署中断
**Why it happens:** Doppler 是外部 SaaS 服务，存在可用性风险
**How to avoid:** 手动部署脚本作为回退（从 .env 文件直接 source）；Doppler fallback 机制可缓存加密快照到本地 [VERIFIED: Context7/Docs - High Availability]
**Warning signs:** `doppler secrets download` 超时或返回网络错误

### Pitfall 6: Service Token 权限过大
**What goes wrong:** 使用 read-write token 而非 read-only，增加了安全风险
**Why it happens:** Dashboard 创建 token 时默认是 read-only，但可能误选
**How to avoid:** 明确创建 read-only Service Token（`access: "read"`）；写入操作仅在 Dashboard 或 `doppler login` 本地环境执行 [VERIFIED: Context7/Docs - Terraform 示例显示 access = "read"]

## Code Examples

### Doppler CLI 安装验证脚本
```bash
# Source: Context7/Docs + brew info 验证
#!/bin/bash
set -euo pipefail

echo "=== Doppler CLI 安装验证 ==="

# 检查 Homebrew
if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew 未安装"
    exit 1
fi

# 安装 gnupg（签名验证依赖）
brew install gnupg 2>/dev/null || true

# 安装 Doppler CLI
brew tap dopplerhq/cli
brew install dopplerhq/cli/doppler

# 验证
doppler --version
echo "Doppler CLI 安装完成"
```

### Service Token 认证验证
```bash
# Source: Context7/Docs - Service Tokens
export DOPPLER_TOKEN='dp.st.prd.xxxx'

# 验证认证：列出密钥名（不显示值）
doppler secrets --only-names --project noda --config prod

# 验证密钥下载
doppler secrets download --format=env --no-file --project noda --config prod
# 应输出所有密钥的 KEY=VALUE 格式

# 验证特定密钥存在
doppler secrets get POSTGRES_PASSWORD --project noda --config prod
```

### 密钥上传到 Doppler（从 .env 文件批量导入）
```bash
# Source: Context7/Docs - Secrets Upload
# 从现有 .env 文件导入（注意：需去重，两个文件有重叠 key）

# 方案 1：合并后上传（推荐）
# 合并两个文件，去重（保留任意一份，值相同）
cat docker/.env .env.production | sort -u -t= -k1,1 > /tmp/noda-secrets-merged.env
doppler secrets upload /tmp/noda-secrets-merged.env --project noda --config prod
rm -f /tmp/noda-secrets-merged.env

# 方案 2：Dashboard UI 手动逐个添加
# 登录 Doppler Dashboard -> noda project -> prod config -> Secrets -> Add Secret
```

### 离线备份（age 加密 + B2 上传）
```bash
# Source: Context7/Docs - High Availability + 项目现有 age 工具链
export DOPPLER_TOKEN='dp.st.prd.xxxx'

# 方案 A：age 加密（推荐，与现有 SOPS 工具链一致）
AGE_PUBLIC_KEY="age1xxx..."  # 从 SOPS 配置获取
doppler secrets download --format=env --no-file --project noda --config prod \
    | age -r "$AGE_PUBLIC_KEY" -o /tmp/doppler-backup-$(date +%Y%m%d).env.age

# 上传到 B2
b2 upload-file noda-backups /tmp/doppler-backup-$(date +%Y%m%d).env.age \
    "doppler-backup/$(date +%Y%m%d).env.age"

# 清理临时文件
rm -f /tmp/doppler-backup-*.env.age

# 方案 B：Doppler 内置加密（使用 passphrase）
doppler secrets download --format=json --passphrase="$BACKUP_PASSPHRASE" \
    ./doppler-backup.json --project noda --config prod
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| SOPS + age 加密 .env 文件 | Doppler 云端密钥管理 | Phase 39 (2026-04) | 密钥集中管理，不再需要本地加密文件和 age key 分发 |
| source docker/.env 手动加载 | doppler secrets download 自动拉取 | Phase 40 (计划中) | Pipeline 自动获取最新密钥，无需维护 .env 文件 |
| Client ID + Secret -> JWT (Infisical) | 单 Service Token (Doppler) | 2026-04 (工具变更) | 认证步骤从 2 步简化为 1 步 |

**Deprecated/outdated:**
- `scripts/utils/decrypt-secrets.sh`: SOPS 解密脚本，Phase 41 清理
- `secrets/*.enc`: SOPS 加密文件，Phase 41 清理

## 密钥清单分析

### 需要迁移到 Doppler 的密钥（15 个，去重后）

| 密钥名 | 来源 | 分类 | 备注 |
|--------|------|------|------|
| POSTGRES_USER | 两个文件共有 | 基础设施 | 数据库用户名 |
| POSTGRES_PASSWORD | 两个文件共有 | 基础设施 | 数据库密码 |
| POSTGRES_DB | 两个文件共有 | 基础设施 | 数据库名 |
| KEYCLOAK_ADMIN_USER | 两个文件共有 | 基础设施 | Keycloak 管理员 |
| KEYCLOAK_ADMIN_PASSWORD | 两个文件共有 | 基础设施 | Keycloak 管理员密码 |
| KEYCLOAK_DB_PASSWORD | 两个文件共有 | 基础设施 | Keycloak 数据库密码 |
| CLOUDFLARE_TUNNEL_TOKEN | 两个文件共有 | 基础设施 | CF Tunnel 认证 |
| ANTHROPIC_AUTH_TOKEN | 仅 docker/.env | 应用 | Anthropic API 密钥 |
| ANTHROPIC_BASE_URL | 仅 docker/.env | 应用 | Anthropic API 地址 |
| SMTP_HOST | 仅 .env.production | 应用 | 邮件服务器 |
| SMTP_PORT | 仅 .env.production | 应用 | 邮件端口 |
| SMTP_FROM | 仅 .env.production | 应用 | 发件人地址 |
| SMTP_USER | 仅 .env.production | 应用 | SMTP 用户名 |
| SMTP_PASSWORD | 仅 .env.production | 应用 | SMTP 密码 |
| RESEND_API_KEY | 仅 .env.production | 应用 | ReSend API 密钥 |

### 不纳入 Doppler 的密钥（3 个）

| 密钥名 | 原因 | 处理方式 |
|--------|------|----------|
| VITE_KEYCLOAK_URL | 公开信息，构建时注入 | 保持 --build-arg 硬编码（D-07） |
| VITE_KEYCLOAK_REALM | 公开信息，构建时注入 | 保持 --build-arg 硬编码（D-07） |
| VITE_KEYCLOAK_CLIENT_ID | 公开信息，构建时注入 | 保持 --build-arg 硬编码（D-07） |

### 不迁移的文件

| 文件 | 原因 |
|------|------|
| `scripts/backup/.env.backup` | 备份系统保持独立（D-06），核心价值保障 |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Jenkins 宿主机已有 Homebrew 且可正常使用 | 环境可用性 | 如果 brew 不可用，需改用 curl install.sh 方式 |
| A2 | Doppler Developer 免费版注册无需信用卡 | Standard Stack | 如果需要信用卡，可能影响团队决策 |
| A3 | 两个 .env 文件中重叠的 7 个 key 值完全相同 | 密钥清单 | 如果值不同，需确认哪个是正确的 |
| A4 | age 公钥可从现有 SOPS 配置获取 | 离线备份 | 如果 SOPS 配置不包含 age 公钥，需重新生成 |

**注：** A1 可在执行阶段验证。A2 需人工注册时确认。A3 需在迁移时逐个比对。A4 可从 `.sops.yaml` 或 `team-keys/` 目录获取。

## Open Questions

1. **Doppler 账号注册**
   - What we know: 需要在 Doppler Dashboard 注册账号，创建项目
   - What's unclear: 是否需要团队账号或有个人 Developer Free 选项
   - Recommendation: 人工注册 Doppler 账号，创建 "noda" 项目

2. **密钥值一致性验证**
   - What we know: docker/.env 和 .env.production 有 7 个重叠 key
   - What's unclear: 两份文件中的值是否完全一致（可能一份更新了但另一份没同步）
   - Recommendation: 迁移时人工比对 7 个重叠 key 的值，确保 Doppler 中存的是正确的值

3. **B2 备份的触发时机**
   - What we know: D-05 要求定期加密快照到 B2
   - What's unclear: Phase 39 是否需要自动化 cron，还是仅建立手动备份流程
   - Recommendation: Phase 39 仅建立手动备份流程和脚本，自动化 cron 留到 Phase 42

## Environment Availability

> Jenkins 宿主机是远程服务器，以下为本地 macOS 环境验证结果，实际部署到服务器时需确认。

| Dependency | Required By | Available (本地) | Version | Fallback |
|------------|------------|-----------------|---------|----------|
| Homebrew | Doppler CLI 安装 | ✓ | auto | curl install.sh |
| Doppler CLI | 密钥管理 | 未安装 | 3.75.3 (latest) | — |
| gnupg | Doppler CLI 签名验证 | ✓ | — | — |
| age | B2 加密快照 | ✓ | — | gpg |
| sops | 现有密钥解密（对比用） | ✓ | — | — |
| Jenkins | Credentials Store | ✓ (服务器) | LTS 2.541.3 | — |

**Missing dependencies with no fallback:**
- Doppler CLI: Phase 39 核心安装目标，必须安装
- Doppler 账号/项目: 需人工在 Dashboard 创建

**Missing dependencies with fallback:**
- 无

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell 手动验证（无自动化测试框架） |
| Config file | 无 |
| Quick run command | `doppler --version && doppler secrets --only-names` |
| Full suite command | 见下方验证清单 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| INFRA-01 | Doppler CLI 安装成功，版本 >= 3.75 | smoke | `doppler --version` | N/A (CLI command) |
| INFRA-01 | CLI 可执行，返回 exit code 0 | smoke | `doppler --help >/dev/null 2>&1` | N/A |
| INFRA-02 | Doppler 项目 "noda" 存在，环境 "prod" 存在 | smoke | `doppler secrets --only-names --project noda --config prod` | N/A |
| INFRA-02 | 所有 15 个密钥存在于 Doppler | smoke | `doppler secrets --only-names --project noda --config prod \| grep -c 'KEY_NAME'` | N/A |
| INFRA-03 | Service Token 可成功认证 | smoke | `DOPPLER_TOKEN=$TOKEN doppler secrets download --format=env --no-file` | N/A |
| INFRA-03 | Jenkins Credentials 中存在 DOPPLER_TOKEN | manual | Jenkins UI 验证 | N/A |
| INFRA-04 | 离线备份可生成加密文件 | smoke | `doppler secrets download --format=env --no-file \| age -r $KEY -o test.age` | N/A |

### Sampling Rate
- **Per task commit:** `doppler --version` 验证 CLI 可用
- **Per wave merge:** `doppler secrets --only-names` 验证密钥完整
- **Phase gate:** 全量验证清单（4 个 Success Criteria）

### Wave 0 Gaps
- Phase 39 主要是基础设施配置和人工操作，无自动化测试文件需要创建
- 验证通过 CLI 命令手动执行即可

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Doppler Service Token（单 token 认证） |
| V3 Session Management | yes | Service Token 无过期（长期有效），需定期轮换 |
| V4 Access Control | yes | Service Token read-only 权限，最小权限原则 |
| V5 Input Validation | no | 无用户输入 |
| V6 Cryptography | yes | age 加密离线备份（与 SOPS 工具链一致） |

### Known Threat Patterns for Doppler + Jenkins 集成

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Service Token 泄露 | Information Disclosure | Jenkins Credentials Store 自动遮蔽日志；token 存密码管理器 |
| Doppler API 不可用 | Denial of Service | 手动部署脚本作为回退（source .env 文件）；Doppler fallback 机制 |
| .env 文件残留 | Information Disclosure | Phase 41 迁移验证后删除明文 .env 文件 |
| 密钥值不一致 | Tampering | 迁移时逐个比对两个 .env 文件的重叠 key |

## Sources

### Primary (HIGH confidence)
- [Context7 /dopplerhq/cli] - Doppler CLI 安装、认证、secrets download/upload 命令
- [Context7 /websites/doppler] - Doppler Jenkins 集成、Service Token 管理、Platform Limits
- [brew info dopplerhq/cli/doppler] - 版本 3.75.3 确认
- 项目代码: docker/.env, .env.production, scripts/pipeline-stages.sh, jenkins/Jenkinsfile.findclass-ssr

### Secondary (MEDIUM confidence)
- Doppler 文档 https://docs.doppler.com/docs/jenkins - Jenkins 集成指南
- Doppler 文档 https://docs.doppler.com/docs/service-tokens - Service Token 创建和管理
- Doppler 文档 https://docs.doppler.com/docs/high-availability - 离线备份和 fallback

### Tertiary (LOW confidence)
- 无

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Doppler CLI 版本通过 brew 验证，API 通过 Context7 确认
- Architecture: HIGH - Jenkins 集成模式已在官方文档中详细说明，且项目已有 withCredentials 使用经验
- Pitfalls: HIGH - brew tap 顺序问题已实际验证确认
- 密钥清单: HIGH - 通过实际文件扫描确认

**Research date:** 2026-04-19
**Valid until:** 2026-05-19（Doppler CLI 稳定，30 天有效期）
