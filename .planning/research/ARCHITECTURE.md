# Architecture Research: 密钥管理集中化

**Domain:** Docker Compose 基础设施 + Jenkins CI/CD 密钥管理集成
**Researched:** 2026-04-19
**Confidence:** HIGH（基于完整代码库审计 + Context7 官方文档验证）

---

## 一、现状分析

### 1.1 当前密钥分布

项目当前有 4 个独立的密钥存储位置，彼此无统一管理：

| 存储位置 | 包含的密钥 | 消费者 | 格式 |
|---------|----------|--------|------|
| `docker/.env` | POSTGRES_PASSWORD, KEYCLOAK_ADMIN_*, CLOUDFLARE_TUNNEL_TOKEN, B2_*, ANTHROPIC_* | docker compose (noda-infra, noda-apps), pipeline-stages.sh | 明文 .env |
| `.env.production` | POSTGRES_*, KEYCLOAK_*, SMTP_*, RESEND_API_KEY, CLOUDFLARE_TUNNEL_TOKEN | docker compose app, 部署脚本 | 明文 .env |
| `scripts/backup/.env.backup` | POSTGRES_*, B2_* | noda-ops 容器内备份脚本 | 明文 .env |
| `config/secrets.sops.yaml` | cloudflare_tunnel_token, postgres_password, keycloak_admin_password, google_oauth_* | 部署脚本 (sops --decrypt) | SOPS + age 加密 |

**关键问题：**
1. `docker/.env` 和 `.env.production` 之间存在大量重复密钥（POSTGRES_PASSWORD, KEYCLOAK_ADMIN_*）
2. 同一密钥在多个文件中维护，更新时容易遗漏
3. `docker/.env` 被 gitignore 排除但 pipeline-stages.sh 直接 source 它（第 22-29 行），Jenkins 需要手动维护此文件
4. SOPS 加密文件已存在但只存储了部分密钥，未成为唯一真相源

### 1.2 现有 SOPS + age 基础设施

项目已建立的 SOPS 加密体系：
- **加密工具:** SOPS + age (非对称加密)
- **配置文件:** `.sops.yaml` 定义加密规则
- **密钥文件:** `config/keys/git-age-key.txt`（gitignored，仅本地保存）
- **加密存储:** `config/secrets.sops.yaml`（加密后提交到 Git）
- **解密脚本:** `scripts/utils/decrypt-secrets.sh`（支持 production/infra/noda/all）
- **消费者:** `deploy-infrastructure-prod.sh` 检查 `config/secrets.sops.yaml` 是否存在

### 1.3 密钥消费链路

```
密钥存储                    消费链路
──────────────────────────────────────────────────────

docker/.env ──────────┐
                       ├──> docker compose up (环境变量替换 ${VAR})
                       ├──> pipeline-stages.sh (source 加载)
                       └──> noda-ops 容器环境变量 (B2_*, POSTGRES_*)

.env.production ───────> docker-compose.app.yml 环境变量替换
                        (${POSTGRES_USER}, ${RESEND_API_KEY}, ...)

scripts/backup/.env.backup ──> noda-ops 容器内备份脚本 source

config/secrets.sops.yaml ──> sops --decrypt → 临时文件 → source → 删除
```

### 1.4 资源约束

单服务器部署，现有容器资源分配：

| 服务 | CPU 限制 | 内存限制 |
|------|---------|---------|
| PostgreSQL | 2 核 | 2G |
| Keycloak (blue/green) | 1 核 | 1G (每个) |
| findclass-ssr (blue/green) | 1 核 | 512M (每个) |
| Nginx | 共享 | 共享 |
| noda-ops | 共享 | 共享 |
| noda-site | 0.25 核 | 64M |
| Jenkins (宿主机) | 共享 | 共享 |

**约束：** 服务器总内存有限，新服务必须轻量。

---

## 二、方案评估

### 2.1 方案对比

| 维度 | 增强 SOPS + age（推荐） | HashiCorp Vault | Infisical 自托管 |
|------|----------------------|-----------------|-----------------|
| 额外容器 | 0 | 1 (Vault) | 3 (backend + PG + Redis) |
| 额外内存 | 0 | 256-512M | 1-2G |
| 实施复杂度 | 低 | 高（unseal、初始化、HA） | 中（依赖 PG + Redis） |
| 学习成本 | 已有基础 | 高（新概念多） | 中 |
| 运维负担 | 低 | 高（unseal、备份、升级） | 中（多容器管理） |
| 与现有架构兼容性 | 极好（无侵入） | 需新增 compose 项目 | 需新增 compose 项目 |
| 失败影响范围 | 有限（回退到手动 .env） | 严重（Vault down = 全部服务无法获取密钥） | 严重（同 Vault） |
| CI/CD 集成 | sops --decrypt 一行 | 需要 vault CLI + token 管理 | infisical CLI + token |
| 密钥轮换 | 手动 | 自动（动态密钥） | 自动 |
| 审计日志 | git log（变更记录） | 完整审计日志 | 完整审计日志 |
| 许可证 | MPL-2.0 (SOPS) + MIT (age) | BSL 1.1 | MIT (核心) |
| 项目规模适配度 | 高（单服务器，<20 密钥） | 过重（企业级功能大部分用不上） | 过重（需要 3 个额外容器） |

### 2.2 方案选型：增强 SOPS + age

**推荐理由：**

1. **零额外资源消耗** — 不需要新增容器，不影响现有服务
2. **已有基础设施** — 项目已经使用 SOPS + age，只需扩展到覆盖所有密钥
3. **Git 作为真相源** — 加密文件提交到 Git，天然有版本控制和审计日志
4. **渐进式迁移** — 可以逐个 .env 文件迁移，无需一次性切换
5. **无单点故障** — 不引入新的运行时依赖，SOPS 解密是部署时操作而非运行时
6. **规模匹配** — 项目约 20 个密钥，不需要 Vault/Infisical 的动态密钥和自动轮换

**为什么不选 Vault：**
- 单服务器已有 Jenkins + PostgreSQL + Keycloak + findclass-ssr，资源紧张
- Vault 的 unseal 机制意味着每次容器重启都需要人工干预（除非配置 auto-unseal，又引入额外复杂度）
- Vault down = 所有依赖它的服务无法启动 = 引入鸡生蛋问题
- BSL 许可证对企业使用有限制

**为什么不选 Infisical：**
- 自托管需要 3 个额外容器（backend + PG + Redis），资源开销 1-2G
- 又引入一个需要备份和管理的数据库
- MIT 核心版本缺少 RBAC 和 SSO，对单用户场景无额外价值

---

## 三、推荐架构

### 3.1 架构总览

```
                    Git 仓库（唯一真相源）
                    ┌──────────────────────┐
                    │ config/secrets/       │
                    │   infra.sops.yaml     │ ← 基础设施密钥
                    │   apps.sops.yaml      │ ← 应用密钥
                    │   backup.sops.yaml    │ ← 备份系统密钥
                    │   jenkins.sops.yaml   │ ← Jenkins 专用
                    │                       │
                    │ .sops.yaml            │ ← SOPS 加密规则
                    │ config/keys/          │ ← age 密钥 (gitignored)
                    └──────────┬───────────┘
                               │
              ┌────────────────┼──────────────────┐
              │                │                  │
         Jenkins          部署脚本           docker compose
              │                │                  │
    ┌─────────▼──────┐ ┌──────▼───────┐ ┌────────▼─────────┐
    │ pipeline       │ │ deploy-*.sh  │ │ envsubst / source │
    │ fetch-secrets  │ │ decrypt-secs │ │ .env（临时生成）  │
    │ → .env 临时文件│ │ → env vars   │ │                  │
    └────────────────┘ └──────────────┘ └──────────────────┘
              │                │                  │
              └────────────────┼──────────────────┘
                               │
                    ┌──────────▼───────────┐
                    │ Docker Compose 服务   │
                    │ (环境变量注入)        │
                    └──────────────────────┘
```

### 3.2 密钥文件重组

将分散的密钥整合到 `config/secrets/` 目录，按消费方分组：

```yaml
# config/secrets/infra.sops.yaml — 基础设施密钥
# 消费者：docker-compose.yml + docker-compose.prod.yml
postgres_user: ENC[...]
postgres_password: ENC[...]
postgres_db: ENC[...]
keycloak_admin_user: ENC[...]
keycloak_admin_password: ENC[...]
cloudflare_tunnel_token: ENC[...]

# config/secrets/apps.sops.yaml — 应用密钥
# 消费者：docker-compose.app.yml, findclass-ssr
smtp_host: ENC[...]
smtp_port: ENC[...]
smtp_user: ENC[...]
smtp_password: ENC[...]
resend_api_key: ENC[...]
anthropic_auth_token: ENC[...]
anthropic_base_url: ENC[...]

# config/secrets/backup.sops.yaml — 备份系统密钥
# 消费者：noda-ops 容器
b2_account_id: ENC[...]
b2_application_key: ENC[...]
b2_bucket_name: ENC[...]

# config/secrets/jenkins.sops.yaml — Jenkins 专用密钥
# 消费者：Jenkins Pipeline
cf_api_token: ENC[...]
cf_zone_id: ENC[...]
noda_apps_git_ssh_key: ENC[...]
```

**分组原则：** 按最小权限原则，每个消费方只能解密自己需要的密钥。实际上使用同一个 age 密钥，但文件分离使权限管理更清晰。

### 3.3 统一密钥获取脚本

新增 `scripts/lib/secrets.sh` — 统一密钥获取接口：

```bash
#!/bin/bash
# scripts/lib/secrets.sh — 统一密钥获取接口
# 依赖：sops CLI, age 密钥
# 用法：
#   source scripts/lib/secrets.sh
#   fetch_secrets infra     # 解密 infra.sops.yaml → 设置环境变量
#   fetch_secrets apps      # 解密 apps.sops.yaml → 设置环境变量
#   fetch_secrets backup    # 解密 backup.sops.yaml → 设置环境变量
#   fetch_secrets_all       # 解密所有密钥

_SECRETS_DIR="${_SECRETS_DIR:-$PROJECT_ROOT/config/secrets}"
_SECRETS_CACHE_DIR="/tmp/noda-secrets-$$"

# _find_age_key - 查找 age 密钥文件
_find_age_key() {
    # 优先级：环境变量 > 项目目录 > 用户目录
    if [[ -n "${SOPS_AGE_KEY_FILE:-}" && -f "$SOPS_AGE_KEY_FILE" ]]; then
        echo "$SOPS_AGE_KEY_FILE"
        return
    fi
    local key_file="$PROJECT_ROOT/config/keys/git-age-key.txt"
    if [[ -f "$key_file" ]]; then
        echo "$key_file"
        return
    fi
    log_error "未找到 age 密钥文件，请设置 SOPS_AGE_KEY_FILE"
    return 1
}

# fetch_secrets - 解密密钥文件并导出为环境变量
# 参数：$1 = 密钥组名 (infra|apps|backup|jenkins)
# 效果：将解密后的键值对 export 到当前 shell
fetch_secrets() {
    local group="$1"
    local encrypted_file="$_SECRETS_DIR/${group}.sops.yaml"

    if [[ ! -f "$encrypted_file" ]]; then
        log_error "密钥文件不存在: $encrypted_file"
        return 1
    fi

    local age_key
    age_key=$(_find_age_key) || return 1
    export SOPS_AGE_KEY_FILE="$age_key"

    # 解密 YAML → 提取键值对 → export
    local decrypted
    decrypted=$(sops --decrypt "$encrypted_file" 2>/dev/null) || {
        log_error "密钥解密失败: $group"
        return 1
    }

    # YAML 值提取（纯 bash，无 yq 依赖）
    while IFS=': ' read -r key value; do
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        [[ -z "$key" || "$key" == \#* ]] && continue
        # 去除引号
        value="${value#\"}" ; value="${value%\"}"
        export "$key=$value"
    done <<< "$decrypted"

    log_success "已加载密钥: $group"
}

# cleanup_secrets - 清理环境变量中的敏感信息
cleanup_secrets() {
    # 从已知的密钥列表中 unset 环境变量
    # 注意：这不会影响已经传递给 docker compose up 的变量
    unset POSTGRES_PASSWORD KEYCLOAK_ADMIN_PASSWORD 2>/dev/null || true
    # ... 其他密钥
    rm -rf "$_SECRETS_CACHE_DIR" 2>/dev/null || true
}

# fetch_secrets_all - 加载所有密钥组
fetch_secrets_all() {
    fetch_secrets infra
    fetch_secrets apps
    fetch_secrets backup
    fetch_secrets jenkins
}
```

### 3.4 Docker Compose 集成

**方式：部署时生成临时 .env 文件**

不修改 docker-compose.yml 中的 `${VAR}` 引用方式（这是 Docker Compose 的标准模式），而是在部署前从 SOPS 解密生成 `.env` 文件：

```bash
# scripts/lib/secrets.sh 中的 generate_env_file 函数
# 生成临时 .env 文件供 docker compose 消费

generate_env_file() {
    local group="$1"
    local output_file="$2"

    fetch_secrets "$group"

    # 将环境变量写入临时 .env 文件
    sops --decrypt "$_SECRETS_DIR/${group}.sops.yaml" | \
        sed 's/: /=/' | \
        sed 's/^"//' | sed 's/"$//' > "$output_file"

    chmod 600 "$output_file"
}
```

**Docker Compose 部署流程变化：**

```bash
# 之前（直接 source docker/.env）
source docker/.env
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d

# 之后（从加密文件解密生成临时 .env）
source scripts/lib/secrets.sh
generate_env_file infra /tmp/noda-infra-env.$$
docker compose --env-file /tmp/noda-infra-env.$$ -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d
rm -f /tmp/noda-infra-env.$$
```

### 3.5 Jenkins Pipeline 集成

**修改 pipeline-stages.sh 的密钥加载逻辑：**

当前 pipeline-stages.sh 第 22-29 行：

```bash
# 当前：直接 source 明文 .env
for _env_path in "$PROJECT_ROOT/docker/.env" "$HOME/Project/noda-infra/docker/.env"; do
    if [ -f "$_env_path" ]; then
        set -a; source "$_env_path"; set +a
        break
    fi
done
```

改为：

```bash
# 新：从 SOPS 加密文件解密
source "$PROJECT_ROOT/scripts/lib/secrets.sh"

# 根据需要加载对应密钥组
fetch_secrets infra   # 数据库密码、Keycloak 管理员密码、Cloudflare token
fetch_secrets backup  # B2 凭据（备份相关 Pipeline 使用）
fetch_secrets jenkins # Cloudflare API token（CDN Purge 阶段使用）
```

**Jenkins 环境配置要求：**

Jenkins 宿主机需要：
1. 安装 `sops` CLI
2. 配置 `SOPS_AGE_KEY_FILE` 环境变量指向 age 私钥
3. age 私钥存储在 Jenkins 的 `credentials` 中，通过 `withCredentials` 注入

```groovy
// Jenkinsfile 中的 environment 块增强
environment {
    PROJECT_ROOT = "${WORKSPACE}"
    SOPS_AGE_KEY_FILE = credentials('sops-age-key-file')  // Jenkins Credentials
    // ... 其他环境变量
}
```

### 3.6 网络拓扑

**无变化。** SOPS 方案不引入新的网络组件。密钥解密是部署时（build time / deploy time）操作，不是运行时（runtime）操作。

```
                    ┌──────────────────────────────────────┐
                    │         noda-network (external)       │
                    │                                      │
                    │  ┌──────────┐  ┌─────────────────┐  │
                    │  │ nginx    │  │ noda-ops        │  │
                    │  │ :80      │  │ (backup+CF)     │  │
                    │  └────┬─────┘  └────────┬────────┘  │
                    │       │                 │            │
                    │  ┌────▼─────┐  ┌────────▼────────┐  │
                    │  │ keycloak │  │ postgres        │  │
                    │  │ :8080    │  │ :5432           │  │
                    │  └──────────┘  └─────────────────┘  │
                    │                                      │
                    │  ┌─────────────────────────────────┐ │
                    │  │ findclass-ssr (blue/green)       │ │
                    │  │ noda-site                        │ │
                    │  └─────────────────────────────────┘ │
                    └──────────────────────────────────────┘

宿主机:
  Jenkins — 部署时调用 sops --decrypt → 环境变量 → docker compose
  age 密钥 — 仅 Jenkins 用户和运维者可读
```

### 3.7 备份流程

**SOPS 加密文件的备份策略：**

SOPS 加密文件已存储在 Git 中，天然有版本控制。但密钥管理引入了两个新的备份需求：

#### 3.7.1 age 私钥备份

age 私钥（`config/keys/git-age-key.txt`）是解密所有密钥的根密钥，必须安全备份：

```
age 私钥备份策略：
1. 主存储：服务器 config/keys/git-age-key.txt (gitignored)
2. 备份 1：离线 USB 或密码管理器（如 1Password/Bitwarden）
3. 备份 2：B2 云存储加密存储（使用独立密码加密后上传）

恢复：只要有 age 私钥，即可从 Git 仓库中的 SOPS 加密文件解密所有密钥
```

#### 3.7.2 密钥文件同步到 B2

在现有 noda-ops 备份流程中添加 SOPS 加密文件备份：

```bash
# 在 noda-ops 的 crontab 中添加（或集成到 backup-postgres.sh）
# 备份 SOPS 加密文件到 B2（文件已经加密，直接上传）

rclone copy /app/config-secrets/ b2:noda-backups/secrets/ \
    --verbose --log-file /var/log/noda-backup/secrets-backup.log
```

**注意：** 上传的是 SOPS 加密后的 `.sops.yaml` 文件，不是明文。age 私钥使用独立加密后单独上传。

### 3.8 迁移流程

#### 3.8.1 迁移步骤（可逆、渐进式）

```
Phase 1: 创建密钥文件结构
  ├─ 创建 config/secrets/ 目录
  ├─ 创建 infra.sops.yaml（从 docker/.env 和 config/secrets.sops.yaml 迁移）
  ├─ 创建 apps.sops.yaml（从 .env.production 迁移）
  ├─ 创建 backup.sops.yaml（从 scripts/backup/.env.backup 迁移）
  └─ 创建 jenkins.sops.yaml（Jenkins 凭据文档化）

Phase 2: 创建统一密钥获取接口
  ├─ 创建 scripts/lib/secrets.sh
  └─ 单元测试：sops 加密/解密/环境变量导出

Phase 3: 修改消费方（渐进式）
  ├─ 修改 pipeline-stages.sh（最关键 — Jenkins 主消费方）
  ├─ 修改 deploy-infrastructure-prod.sh
  ├─ 修改 deploy-apps-prod.sh
  └─ 修改 noda-ops 容器环境变量注入方式

Phase 4: 验证 + 清理
  ├─ 全流程测试（Jenkins Pipeline + 手动部署）
  ├─ 删除 docker/.env 中的密钥（保留非敏感变量如 COMPOSE_PROJECT_NAME）
  ├─ 删除 .env.production
  ├─ 删除 scripts/backup/.env.backup 中的密钥
  └─ 更新 .gitignore 和文档
```

#### 3.8.2 迁移映射表

| 现有位置 | 目标位置 | 密钥列表 |
|---------|---------|---------|
| `docker/.env` → POSTGRES_USER | config/secrets/infra.sops.yaml | postgres_user |
| `docker/.env` → POSTGRES_PASSWORD | config/secrets/infra.sops.yaml | postgres_password |
| `docker/.env` → POSTGRES_DB | config/secrets/infra.sops.yaml | postgres_db |
| `docker/.env` → KEYCLOAK_ADMIN_USER | config/secrets/infra.sops.yaml | keycloak_admin_user |
| `docker/.env` → KEYCLOAK_ADMIN_PASSWORD | config/secrets/infra.sops.yaml | keycloak_admin_password |
| `docker/.env` → CLOUDFLARE_TUNNEL_TOKEN | config/secrets/infra.sops.yaml | cloudflare_tunnel_token |
| `docker/.env` → B2_ACCOUNT_ID | config/secrets/backup.sops.yaml | b2_account_id |
| `docker/.env` → B2_APPLICATION_KEY | config/secrets/backup.sops.yaml | b2_application_key |
| `docker/.env` → B2_BUCKET_NAME | config/secrets/backup.sops.yaml | b2_bucket_name |
| `docker/.env` → ANTHROPIC_AUTH_TOKEN | config/secrets/apps.sops.yaml | anthropic_auth_token |
| `docker/.env` → ANTHROPIC_BASE_URL | config/secrets/apps.sops.yaml | anthropic_base_url |
| `.env.production` → SMTP_* | config/secrets/apps.sops.yaml | smtp_host, smtp_port, smtp_user, smtp_password |
| `.env.production` → RESEND_API_KEY | config/secrets/apps.sops.yaml | resend_api_key |
| `scripts/backup/.env.backup` → B2_* | config/secrets/backup.sops.yaml | (已合并) |
| `config/secrets.sops.yaml` → * | 分散到对应文件后删除 | (已分散) |
| Jenkins credentials → cf-api-token | config/secrets/jenkins.sops.yaml | cf_api_token |
| Jenkins credentials → cf-zone-id | config/secrets/jenkins.sops.yaml | cf_zone_id |

### 3.9 故障恢复（Fallback）

#### 3.9.1 SOPS 解密失败

**场景：** age 私钥丢失或 SOPS 工具不可用

**恢复方案：**
1. **age 私钥丢失：** 从离线备份恢复（密码管理器或 USB）
2. **SOPS 不可用：** 在部署服务器上运行 `apt install sops` 或下载二进制
3. **紧急回退：** 手动创建 `.env` 文件（从密码管理器中获取密钥值）

```bash
# 紧急回退脚本（scripts/utils/emergency-env.sh）
# 从密码管理器获取密钥值，手动创建 .env 文件
#!/bin/bash
echo "紧急模式：手动输入密钥值生成 .env 文件"
echo "POSTGRES_PASSWORD="; read -rs PG_PASS
echo "KEYCLOAK_ADMIN_PASSWORD="; read -rs KC_PASS
# ...
cat > /tmp/emergency.env <<EOF
POSTGRES_PASSWORD=$PG_PASS
KEYCLOAK_ADMIN_PASSWORD=$KC_PASS
EOF
chmod 600 /tmp/emergency.env
echo "紧急 .env 已生成: /tmp/emergency.env"
```

#### 3.9.2 密钥文件损坏

**场景：** Git 中的 SOPS 加密文件被损坏

**恢复方案：**
1. `git log -- config/secrets/infra.sops.yaml` 找到上一个有效版本
2. `git checkout HEAD~1 -- config/secrets/infra.sops.yaml` 恢复
3. B2 备份中也有加密文件副本

#### 3.9.3 Jenkins 无法获取密钥

**场景：** Jenkins 构建时 SOPS 解密失败

**恢复方案：**
1. Pipeline 在 Pre-flight 阶段检查 `sops` 和 age 密钥文件
2. 如果失败，Pipeline 提供明确的错误信息和恢复指引
3. 使用手动部署脚本（`deploy-infrastructure-prod.sh`）作为回退
4. 手动脚本也使用相同的 `secrets.sh` 接口，但可以退回到直接指定 `.env` 文件

```bash
# pipeline-stages.sh 中的回退逻辑
if ! fetch_secrets infra 2>/dev/null; then
    log_warn "SOPS 解密失败，尝试加载明文 .env（不推荐）"
    if [[ -f "$PROJECT_ROOT/docker/.env" ]]; then
        set -a; source "$PROJECT_ROOT/docker/.env"; set +a
        log_warn "已从明文 .env 加载密钥（建议迁移到 SOPS）"
    else
        log_error "无法加载任何密钥，中止部署"
        return 1
    fi
fi
```

---

## 四、组件边界与职责

### 4.1 新增组件

| 组件 | 职责 | 类型 |
|------|------|------|
| `config/secrets/*.sops.yaml` | 加密密钥存储（Git 提交） | 数据文件 |
| `scripts/lib/secrets.sh` | 统一密钥获取接口 | Shell 库 |
| `scripts/utils/backup-age-key.sh` | age 私钥备份到 B2 | 工具脚本 |
| `scripts/utils/emergency-env.sh` | 紧急回退 .env 生成 | 工具脚本 |

### 4.2 修改组件

| 组件 | 变更类型 | 具体改动 |
|------|---------|---------|
| `pipeline-stages.sh` | 密钥加载重构 | 第 22-29 行 source .env 改为 `fetch_secrets` |
| `deploy-infrastructure-prod.sh` | 密钥加载重构 | 第 209 行检查改为 `fetch_secrets infra` |
| `deploy-apps-prod.sh` | 密钥加载重构 | 添加 `fetch_secrets apps` |
| `Jenkinsfile.findclass-ssr` | 环境变量增强 | 添加 `SOPS_AGE_KEY_FILE` credentials |
| `Jenkinsfile.infra` | 环境变量增强 | 添加 `SOPS_AGE_KEY_FILE` credentials |
| `Jenkinsfile.keycloak` | 环境变量增强 | 添加 `SOPS_AGE_KEY_FILE` credentials |
| `Jenkinsfile.noda-site` | 无变更 | noda-site 不需要密钥 |
| `docker/docker-compose.yml` | 移除硬编码环境变量 | noda-ops 的 B2_* 环境变量改为从 .env 读取 |
| `.sops.yaml` | 更新加密规则 | 添加 `config/secrets/*.sops.yaml` 路径规则 |

### 4.3 删除组件（迁移完成后）

| 组件 | 删除原因 |
|------|---------|
| `config/secrets.sops.yaml` | 内容分散到 `config/secrets/*.sops.yaml` |
| `docker/.env`（密钥部分） | 密钥迁移到 SOPS 文件，仅保留非敏感配置 |
| `.env.production` | 全部密钥迁移到 SOPS 文件 |
| `scripts/backup/.env.backup`（密钥部分） | 密钥迁移到 SOPS 文件 |
| `scripts/utils/decrypt-secrets.sh` | 被 `scripts/lib/secrets.sh` 替代 |

---

## 五、数据流

### 5.1 部署时密钥注入流程（Jenkins Pipeline）

```
┌─────────────┐    ┌───────────────┐    ┌──────────────────┐    ┌──────────────┐
│ Jenkins     │    │ scripts/lib/  │    │ SOPS + age       │    │ Docker       │
│ Pipeline    │───>│ secrets.sh    │───>│ decrypt           │───>│ Compose      │
│             │    │               │    │                   │    │              │
│ 1. checkout │    │ 2. fetch_     │    │ 3. sops --decrypt │    │ 4. compose up│
│    代码     │    │    secrets    │    │    *.sops.yaml    │    │    环境变量  │
│             │    │    infra      │    │    → 环境变量     │    │    注入容器  │
│             │    │    apps       │    │                   │    │              │
│             │    │    backup     │    │                   │    │              │
└─────────────┘    └───────────────┘    └──────────────────┘    └──────────────┘
```

**步骤详解：**

1. Jenkins checkout 代码 → `.sops.yaml` 和 `config/secrets/*.sops.yaml` 都在 Git 中
2. Jenkins 通过 `withCredentials` 注入 `SOPS_AGE_KEY_FILE` 路径
3. `pipeline-stages.sh` 调用 `fetch_secrets infra/apps/backup`
4. `secrets.sh` 执行 `sops --decrypt` 解密到内存中的环境变量
5. 后续 `docker compose up` 或 `docker run` 通过 `${VAR}` 引用已设置的环境变量
6. Pipeline 结束时环境变量随 shell 退出自动清理

### 5.2 手动部署时密钥注入流程

```
┌─────────────┐    ┌───────────────┐    ┌──────────────────┐
│ 运维者      │    │ deploy-*.sh   │    │ Docker Compose   │
│             │───>│               │───>│                  │
│ export      │    │ source        │    │ compose up       │
│ SOPS_AGE_   │    │ secrets.sh    │    │ (环境变量已设置) │
│ KEY_FILE=.. │    │ fetch_secrets │    │                  │
└─────────────┘    └───────────────┘    └──────────────────┘
```

### 5.3 密钥更新流程

```
┌─────────────┐    ┌───────────────┐    ┌──────────────┐
│ 运维者      │    │ SOPS 编辑     │    │ Git          │
│             │───>│               │───>│              │
│ sops edit   │    │ 自动加密      │    │ git add +    │
│ infra.sops  │    │ 保存加密文件  │    │ git commit + │
│ .yaml       │    │               │    │ git push     │
└─────────────┘    └───────────────┘    └──────────────┘
                                               │
                                               ▼
                                        ┌──────────────┐
                                        │ Jenkins      │
                                        │ 下次构建时   │
                                        │ 自动使用新值 │
                                        └──────────────┘
```

---

## 六、安全考量

### 6.1 age 私钥保护

age 私钥是整个密钥管理体系的根信任点：

| 保护措施 | 说明 |
|---------|------|
| 服务器本地存储 | `config/keys/git-age-key.txt`，权限 600，仅 jenkins 用户可读 |
| Jenkins Credentials | 作为 Secret file 类型存储，Pipeline 中通过 `withCredentials` 注入 |
| 离线备份 | 存储在密码管理器（如 1Password），或加密 USB |
| B2 加密备份 | 使用独立密码的 gpg 对称加密后上传到 B2 |

### 6.2 内存中的密钥生命周期

```
密钥在内存中的存在时间：
  fetch_secrets → export → docker compose up → shell 退出 → 环境变量消失

最长存活时间：一个 Pipeline 构建周期（通常 5-15 分钟）
不会写入磁盘（除非使用 generate_env_file 生成临时文件，使用后立即删除）
```

### 6.3 审计日志

Git 提交记录天然提供密钥变更审计：
- `git log -- config/secrets/` 查看所有密钥文件变更历史
- `git diff` 显示哪些行被修改（SOPS 支持行级加密，diff 友好）
- Jenkins 构建日志记录每次部署使用的 Git commit SHA

---

## 七、Anti-Patterns

### Anti-Pattern 1: 运行时密钥服务（Vault/Infisical 模式）

**问题：** 在单服务器上运行密钥服务意味着密钥服务 down = 所有服务 down。这比当前的 .env 文件方案更脆弱。

**避免：** 使用部署时解密（SOPS）而非运行时获取（Vault/Infisical）。密钥在容器启动前就已经存在于环境变量中。

### Anti-Pattern 2: 密钥文件全部分到一个文件

**问题：** 将所有密钥放入单个 `secrets.sops.yaml` 意味着 noda-ops 容器可以解密 Keycloak 管理员密码，findclass-ssr 可以看到 B2 凭据。

**避免：** 按消费方分组到不同文件（infra/apps/backup/jenkins），虽然使用同一个 age 密钥，但文件分离使权限意图更清晰，也为未来分密钥提供基础。

### Anti-Pattern 3: 迁移时一次性切换

**问题：** 一次性删除所有 .env 文件，如果 SOPS 解密出问题，无法回退。

**避免：** 渐进式迁移 — 每个 .env 文件独立迁移，迁移后保留原文件作为回退（带 .bak 后缀），确认 SOPS 流程稳定后再删除。

### Anti-Pattern 4: age 私钥只存一处

**问题：** age 私钥只在服务器上，服务器硬盘损坏 = 永久丢失所有密钥。

**避免：** age 私钥至少有 3 处备份：服务器本地 + 密码管理器 + B2 加密备份。

---

## 八、构建顺序建议

```
Phase 1: 基础设施（无破坏性变更）
  ├─ 创建 config/secrets/ 目录结构
  ├─ 从现有文件迁移密钥到 *.sops.yaml
  ├─ 创建 scripts/lib/secrets.sh
  └─ 单元测试 secrets.sh 的加密/解密/导出功能

Phase 2: Jenkins 集成（关键路径）
  ├─ Jenkins 安装 sops CLI
  ├─ 配置 Jenkins Credentials（age 私钥）
  ├─ 修改 pipeline-stages.sh 密钥加载
  └─ 端到端测试 Pipeline（findclass-ssr 部署）

Phase 3: 手动部署脚本迁移
  ├─ 修改 deploy-infrastructure-prod.sh
  ├─ 修改 deploy-apps-prod.sh
  └─ 修改 noda-ops 环境变量注入

Phase 4: 备份 + 清理
  ├─ age 私钥备份到 B2（加密后）
  ├─ SOPS 文件备份集成到 noda-ops crontab
  ├─ 删除旧明文 .env 文件（确认稳定后）
  ├─ 更新文档和 .gitignore
  └─ 删除 scripts/utils/decrypt-secrets.sh（被 secrets.sh 替代）
```

**依赖关系：**
- Phase 2 依赖 Phase 1（需要 secrets.sh 和密钥文件）
- Phase 3 依赖 Phase 1（同上）
- Phase 4 依赖 Phase 2 + 3（确认所有消费方都已迁移）

---

## 九、扩展性考虑

| 关注点 | 当前（<20 密钥） | 50+ 密钥 | 100+ 密钥 / 多环境 |
|--------|-----------------|----------|-------------------|
| 密钥管理 | SOPS + 手动编辑 | SOPS + sed/yq 脚本 | 考虑 Infisical 或 Vault |
| 分组策略 | 4 个文件（按消费方） | 可能需要更细粒度分组 | 按环境 + 服务矩阵分组 |
| 轮换 | 手动（sops edit） | 半自动（脚本 + cron） | 全自动（Vault 动态密钥） |
| 多人协作 | 单 age 密钥 | 多 age 密钥 (.sops.yaml 配置多 recipient) | 考虑 KMS 集成 |

**当前方案可以平滑升级到 Vault/Infisical：** 密钥文件格式独立于存储后端。如果未来需要迁移到 Vault，`secrets.sh` 的接口不变，只是内部实现从 `sops --decrypt` 改为 `vault kv get`。

---

## Sources

| 来源 | 置信度 | 用途 |
|------|--------|------|
| 项目代码库完整审计（2026-04-19） | HIGH | docker-compose*.yml, .env*, pipeline-stages.sh, Jenkinsfile.* |
| Context7: HashiCorp Vault Docker 部署文档 | HIGH | Vault standalone Docker 配置、unseal 流程、Raft 存储 |
| Context7: HashiCorp Vault AppRole 认证文档 | HIGH | CI/CD 集成模式、Jenkins 最佳实践 |
| Context7: HashiCorp Vault Raft 备份恢复文档 | HIGH | `vault operator raft snapshot save/restore` |
| Context7: Infisical Docker Compose 部署文档 | HIGH | 自托管架构、资源需求 |
| Context7: Infisical CLI 文档 | HIGH | `infisical export` 和 CI/CD 集成模式 |
| SOPS + age 官方文档 | HIGH | 加密配置、.sops.yaml 规则 |
| 现有 config/secrets.sops.yaml 审计 | HIGH | 当前 SOPS 使用状态 |

---

*Architecture research for: 密钥管理集中化*
*Researched: 2026-04-19*
