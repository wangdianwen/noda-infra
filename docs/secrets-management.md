# 密钥管理指南

本文档描述 Noda 基础设施项目的密钥管理方案。项目使用 **Doppler** 作为集中式密钥管理平台，所有敏感配置通过 Doppler CLI 拉取并注入运行环境。

> **历史说明**：项目曾使用 SOPS + age 本地加密方案，已在 Phase 40 迁移到 Doppler。SOPS 相关文件和脚本已移除。

---

## 概述

- **密钥存储**：Doppler 云端（https://dashboard.doppler.com）
- **项目名**：`noda`
- **环境（config）**：`prd`
- **认证方式**：Service Token（`DOPPLER_TOKEN` 环境变量）
- **密钥加载**：`scripts/lib/secrets.sh` 的 `load_secrets()` 函数
- **离线备份**：`scripts/backup/backup-doppler-secrets.sh`（age 加密 + B2 上传）

---

## 架构

```
Doppler 云端密钥存储
       |
       | doppler secrets download --no-file --format=env
       v
scripts/lib/secrets.sh: load_secrets()
       |
       | eval（注入 shell 环境变量）
       v
环境变量（POSTGRES_PASSWORD, GOOGLE_CLIENT_SECRET, ...）
       |
       | Docker Compose ${VAR} 引用
       v
容器内服务使用
```

关键设计决策：
- **不落盘**：`--no-file` 参数确保密钥不写入磁盘，仅在内存中传递
- **Doppler Only**：所有密钥统一从 Doppler 拉取，不维护本地密钥文件

---

## 密钥列表

Doppler 项目 `noda` 环境 `prd` 中管理以下密钥：

### 基础设施密钥

| 密钥名 | 用途 |
|--------|------|
| `POSTGRES_USER` | PostgreSQL 超级用户名 |
| `POSTGRES_PASSWORD` | PostgreSQL 超级用户密码 |
| `POSTGRES_DB` | PostgreSQL 默认数据库名 |
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflare Tunnel 认证 Token |

### Keycloak 密钥

| 密钥名 | 用途 |
|--------|------|
| `KEYCLOAK_ADMIN_USER` | Keycloak 管理员用户名 |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak 管理员密码 |
| `KEYCLOAK_DB_PASSWORD` | Keycloak 数据库连接密码 |

### Google OAuth 密钥

| 密钥名 | 用途 |
|--------|------|
| `GOOGLE_CLIENT_ID` | Google OAuth 客户端 ID |
| `GOOGLE_CLIENT_SECRET` | Google OAuth 客户端密钥 |

### 邮件服务密钥

| 密钥名 | 用途 |
|--------|------|
| `SMTP_HOST` | SMTP 服务器地址 |
| `SMTP_PORT` | SMTP 服务器端口 |
| `SMTP_FROM` | 发件人地址 |
| `SMTP_USER` | SMTP 认证用户名 |
| `SMTP_PASSWORD` | SMTP 认证密码 |
| `RESEND_API_KEY` | Resend 邮件 API 密钥 |

### 其他密钥

| 密钥名 | 用途 |
|--------|------|
| `ANTHROPIC_AUTH_TOKEN` | Anthropic API 认证 Token |
| `ANTHROPIC_BASE_URL` | Anthropic API 基础 URL |

---

## 使用方式

### Jenkins Pipeline（自动）

Jenkins 部署 Pipeline 自动加载密钥。`DOPPLER_TOKEN` 配置在 Jenkins Credentials 中，Pipeline 通过 `withCredentials` 注入环境变量，然后调用 `load_secrets()` 拉取所有密钥。

相关脚本：
- `scripts/lib/secrets.sh` -- `load_secrets()` 函数
- `scripts/jenkins/pipeline-stages.sh` -- Pipeline 阶段调用
- `scripts/jenkins/blue-green-deploy.sh` -- 蓝绿部署调用

### 手动部署

手动部署时需要设置 `DOPPLER_TOKEN`：

```bash
# 1. 设置 Service Token
export DOPPLER_TOKEN='dp.st.prd.xxxx'

# 2. 加载密钥（source 密钥库后调用）
source scripts/lib/secrets.sh
load_secrets

# 3. 执行部署
bash scripts/deploy/deploy-infrastructure-prod.sh
```

### 查看密钥值

```bash
# 设置 Token
export DOPPLER_TOKEN='dp.st.prd.xxxx'

# 查看所有密钥名
doppler secrets --only-names --project noda --config prd

# 下载密钥为 env 格式（不落盘）
doppler secrets download --no-file --format=env --project noda --config prd
```

---

## 离线备份

为防止 Doppler 服务不可用时无法获取密钥，项目提供离线备份机制：

```bash
# 执行备份（需要 DOPPLER_TOKEN）
DOPPLER_TOKEN='dp.st.prd.xxxx' bash scripts/backup/backup-doppler-secrets.sh

# dry-run 模式（仅下载加密，不上传 B2）
DOPPLER_TOKEN='dp.st.prd.xxxx' bash scripts/backup/backup-doppler-secrets.sh --dry-run
```

备份流程：
1. 从 Doppler API 下载密钥
2. 通过管道用 age 公钥加密（明文不落盘）
3. 上传加密文件到 Backblaze B2（`noda-backups/doppler-backup/`）
4. 清理本地临时文件

恢复备份：
```bash
# 从 B2 下载加密文件
b2 download-file-by-name noda-backups doppler-backup/doppler-backup-YYYYMMDD-HHMMSS.env.age /tmp/backup.env.age

# 使用 age 私钥解密
age -d -i /path/to/age-privkey.txt -o /tmp/backup.env /tmp/backup.env.age

# 加载到环境
set -a && source /tmp/backup.env && set +a
```

---

## 新环境设置

在新服务器上配置 Doppler 密钥访问：

```bash
# 1. 安装 Doppler CLI
bash scripts/install-doppler.sh

# 2. 设置 Service Token（从 Doppler Dashboard 获取）
export DOPPLER_TOKEN='dp.st.prd.xxxx'

# 3. 验证密钥完整性
bash scripts/verify-doppler-secrets.sh
```

获取 Service Token：
1. 访问 https://dashboard.doppler.com
2. 选择项目 `noda`
3. 进入 Settings > Service Tokens
4. 为环境 `prd` 创建新 Token

---

## 验证密钥完整性

```bash
# 验证所有预期密钥是否存在
DOPPLER_TOKEN='dp.st.prd.xxxx' bash scripts/verify-doppler-secrets.sh
```

预期输出：
```
[INFO] 验证 Doppler 项目 'noda' 环境 'prd' 的密钥完整性...
[INFO] 预期密钥数量: 17
  ✓ POSTGRES_USER
  ✓ POSTGRES_PASSWORD
  ...
[INFO] 验证通过: 17/17 密钥完整
```

---

## 故障排除

### Doppler Token 无效

**症状**：`Doppler 密钥拉取失败（检查 DOPPLER_TOKEN 是否有效）`

**解决方案**：
1. 确认 Token 未过期（Doppler Dashboard > Settings > Service Tokens）
2. 确认 Token 对应环境为 `prd`
3. 重新设置环境变量：`export DOPPLER_TOKEN='dp.st.prd.xxxx'`

### Doppler CLI 未安装

**症状**：`DOPPLER_TOKEN 已设置但 doppler CLI 不可用`

**解决方案**：
```bash
bash scripts/install-doppler.sh
```

### 密钥缺失

**症状**：`验证失败: X/17 密钥完整，缺少 N 个`

**解决方案**：
1. 访问 Doppler Dashboard 确认密钥存在
2. 在 Dashboard 中手动添加缺失的密钥
3. 重新运行验证脚本

### Doppler 服务不可用

**症状**：网络超时或 API 错误

**解决方案**：
1. 使用离线备份恢复密钥（参见"离线备份"章节）
2. 检查 Doppler 状态页：https://status.doppler.com
