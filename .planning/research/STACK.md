# Stack Research: 密钥管理集中化 (v1.8)

**Domain:** Docker Compose 单服务器基础设施 + Jenkins CI/CD 密钥管理
**Researched:** 2026-04-19
**Confidence:** HIGH

## 核心决策：使用 Infisical Cloud（免费版）+ Infisical CLI

**不选择自托管 Docker 密钥服务。** 经过对比分析，推荐使用 Infisical Cloud 免费版而非自托管任何密钥管理服务。原因：

1. 单服务器资源有限，自托管方案额外消耗 1-4 GB 内存
2. 项目仅 ~20 个密钥，60 次/月部署，远低于免费额度
3. Infisical 免费版功能（无限制密钥、3 项目、3 环境、Jenkins 集成）完全满足需求
4. 自托管引入新的运维负担（备份、升级、监控），违背基础设施精简原则

## Recommended Stack

### Core: 密钥管理服务

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Infisical Cloud (Free) | SaaS | 密钥存储、版本管理、Web UI | 免费、无限制密钥数、原生 Jenkins 集成、MIT 开源项目、Web UI 管理密钥。免费版支持 3 项目、3 环境、5 用户、10 集成，完全覆盖本项目需求 | HIGH |

### Core: CLI 工具

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Infisical CLI | 0.43.x | Jenkins Pipeline 中拉取和注入密钥 | 46MB 轻量 CLI，支持 `infisical export`（导出 .env 格式）和 `infisical run`（命令包裹注入），宿主机 apt 安装无需容器。Universal Auth 支持无交互 CI/CD 认证 | HIGH |

### Core: 认证方式

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Machine Identity (Universal Auth) | - | CI/CD 无交互认证 | Client ID + Client Secret 认证，无需浏览器交互。Secret 存储在 Jenkins Credentials 中，Pipeline 中通过 `withCredentials` 注入 | HIGH |

## Jenkins Pipeline 集成方案

### 集成架构

```
Jenkins Pipeline
    |
    |-- withCredentials(Infisical Client ID/Secret)
    |       |
    |       |-- infisical login --method=universal-auth
    |       |
    |       |-- infisical export --env=prod --format=dotenv > docker/.env
    |       |       |
    |       |       +--> docker compose up (使用注入的 .env)
    |       |
    |       +-- infisical run --env=prod -- docker compose up -d
```

### 两种密钥注入模式

| 模式 | 命令 | 适用场景 | 优劣 |
|------|------|---------|------|
| Export 模式 | `infisical export --env=prod --format=dotenv > .env` | docker compose 需要读取 .env 文件时 | 兼容现有流程，.env 写入磁盘（临时） |
| Run 模式 | `infisical run --env=prod -- docker compose up -d` | 命令只需环境变量时 | 密钥不写入磁盘，更安全 |

### Pipeline 代码示例

```groovy
// Jenkinsfile 中的密钥拉取
stage('Fetch Secrets') {
    steps {
        withCredentials([
            string(credentialsId: 'infisical-client-id', variable: 'INFISICAL_CLIENT_ID'),
            string(credentialsId: 'infisical-client-secret', variable: 'INFISICAL_CLIENT_SECRET')
        ]) {
            sh '''
                # 认证
                infisical login --method=universal-auth \
                    --client-id=$INFISICAL_CLIENT_ID \
                    --client-secret=$INFISICAL_CLIENT_SECRET \
                    --plain

                # 导出密钥到 .env 文件（docker compose 需要）
                infisical export --env=prod --projectId=$INFISICAL_PROJECT_ID \
                    --format=dotenv > docker/.env
            '''
        }
    }
}
```

## Infisical 免费版额度 vs 项目需求

| 资源 | 免费额度 | Noda 需求 | 充裕度 |
|------|---------|----------|--------|
| 密钥数量 | 无限制 | ~20 个 | 充裕 |
| 项目数 | 3 | 1 (noda-infra) | 充裕 |
| 环境数 | 3 | 2 (dev/prod) | 充裕 |
| 团队成员 | 5 | 1-2 | 充裕 |
| 集成数 | 10 | 1 (Jenkins) | 充裕 |
| 部署频率 | 无限制 | ~60 次/月 | 充裕 |
| Secret Scanning | 包含 | 可选 | 额外收益 |
| Secret Referencing | 包含 | 可用 | 免费版特性 |
| Webhooks | 包含 | 可用 | 免费版特性 |
| Infisical Agent | 包含 | 暂不需要 | 免费版特性 |
| Self-hosting 选项 | 包含 | 不使用 | 免费版也支持自托管 |

**结论：免费版完全覆盖需求，无需付费。**

## 需要管理的密钥清单

| 密钥 | 当前位置 | 用途 | 敏感度 |
|------|---------|------|--------|
| POSTGRES_USER | docker/.env | 数据库用户名 | P2 |
| POSTGRES_PASSWORD | docker/.env | 数据库密码 | P1 |
| POSTGRES_DB | docker/.env | 数据库名 | P2（非敏感） |
| KEYCLOAK_ADMIN_USER | docker/.env | Keycloak 管理员 | P2 |
| KEYCLOAK_ADMIN_PASSWORD | docker/.env | Keycloak 管理员密码 | P1 |
| KEYCLOAK_DB_PASSWORD | docker/.env | Keycloak 数据库密码 | P1 |
| CLOUDFLARE_TUNNEL_TOKEN | docker/.env | Cloudflare Tunnel | P1 |
| B2_ACCOUNT_ID | docker/.env | Backblaze B2 账户 | P1 |
| B2_APPLICATION_KEY | docker/.env | Backblaze B2 密钥 | P1 |
| B2_BUCKET_NAME | docker/.env | B2 桶名 | P2（非敏感） |
| ANTHROPIC_AUTH_TOKEN | docker/.env | Anthropic API | P1 |
| ANTHROPIC_BASE_URL | docker/.env | API 端点 | P2（非敏感） |
| SMTP_HOST | .env.production | SMTP 服务器 | P2 |
| SMTP_PASSWORD | .env.production | SMTP 密码 | P1 |
| RESEND_API_KEY | .env.production | ReSend API | P1 |
| VITE_KEYCLOAK_URL | .env.production | 前端构建变量 | P2（非敏感） |
| VITE_KEYCLOAK_REALM | .env.production | 前端构建变量 | P2（非敏感） |
| VITE_KEYCLOAK_CLIENT_ID | .env.production | 前端构建变量 | P2（非敏感） |

## Installation

```bash
# ============================================
# Infisical CLI 安装（生产服务器宿主机，一次性）
# ============================================

# Linux (Ubuntu/Debian)
curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.deb.sh' | sudo -E bash
sudo apt-get update && sudo apt-get install -y infisical

# macOS (开发机)
brew install infisical

# 验证安装
infisical --version   # 预期: 0.43.x

# ============================================
# Jenkins 认证配置（一次性）
# ============================================
# 1. 访问 https://app.infisical.com/signup 创建账户
# 2. 创建项目 "noda-infra"
# 3. 创建两个环境: dev, prod
# 4. 在 Project Settings > Machine Identities 创建 Universal Auth
# 5. 记录 Client ID 和 Client Secret
# 6. 在 Jenkins > Credentials 中添加:
#    - infisical-client-id (Secret text)
#    - infisical-client-secret (Secret text)
#    - infisical-project-id (Secret text)
# 7. 所有 Pipeline 中使用 withCredentials 注入
```

## 备份策略

| 数据 | 方式 | 频率 | 存储 |
|------|------|------|------|
| Infisical 密钥 | Infisical Cloud 托管（多区域冗余） | 实时 | Infisical 托管 |
| 本地 .env（迁移前） | 备份到 B2 | 迁移时一次性 | Backblaze B2 |
| Infisical 导出快照 | `infisical export` + B2 上传 | 每日 cron | Backblaze B2 |
| Jenkins 凭据 | JenkinsCredentials XML 导出 | 迁移时一次性 | 安全存储 |

注意：Infisical Cloud 免费版不包含 Point-in-Time Recovery（Pro 功能），也不包含 Secret Versioning（Pro 功能）。但密钥变更频率极低（月级别），通过定期 `infisical export` 备份到 B2 即可满足恢复需求。即使 Infisical Cloud 宕机，Pipeline 中可临时使用 `--fallback` 缓存机制持续服务。

## Alternatives Considered

### 密钥管理方案完整对比

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| **Infisical Cloud (Free)** | HashiCorp Vault (自托管 Docker) | 资源消耗大：Vault 进程最低 512MB RAM（推荐 4GB+），加 Consul/Raft 存储需要更多。运维复杂：unseal 密钥管理（3-of-5 Shamir）、TLS 证书配置、policy 管理。官方生产加固指南要求独占服务器（single tenancy）。BSL 许可证限制。学习曲线陡峭。对于 20 个静态密钥完全是杀鸡用牛刀 |
| **Infisical Cloud (Free)** | Infisical (自托管 Docker) | docker-compose.prod.yml 需要 3 个容器：infisical/infisical:latest (694MB 镜像，运行时 ~512MB-1GB RAM) + postgres:14-alpine (~256MB RAM) + redis (~128MB RAM)，总计 ~1-1.5GB 额外内存。且 Infisical 的 PostgreSQL 数据库也需要备份，形成"管理密钥的密钥需要密钥"的循环依赖。Infisical 自身还需要 SMTP 配置来发送邀请邮件 |
| **Infisical Cloud (Free)** | Docker Secrets (Swarm mode) | 需要 Docker Swarm 模式，当前使用 Docker Compose standalone。且无 Web UI、无版本控制、无审计日志、无 CI/CD 集成 |
| **Infisical Cloud (Free)** | SOPS + Git | 密钥存储在 Git 仓库中（即使加密），增加攻击面。需要 GPG/KMS 密钥管理。需要额外密钥分发机制给 docker compose。无 Web UI，不便于非技术用户管理 |
| **Infisical Cloud (Free)** | CyberArk Conjur | 企业级产品，资源消耗极大（4GB+ RAM），配置极其复杂。开源版 (Conjur OSS) 功能严重受限。适合大规模企业部署，不适合单服务器项目 |
| **Infisical Cloud (Free)** | 1Password Secrets Automation | 需要 1Password Business 账户 ($7.99/用户/月起)。无免费自托管选项。CLI 工具 (op) 在 CI/CD 中集成不如 Infisical 成熟 |
| **Infisical Cloud (Free)** | Doppler | 免费版仅 5 个用户、5 个项目。CLI 集成不如 Infisical 的 `infisical run`/`infisical export` 灵活。不在 GitHub 上开源（闭源 SaaS），社区可信度低 |

### 为什么不用自托管 Infisical（详细分析）

Infisical 官方 `docker-compose.prod.yml`（来自 GitHub 仓库 main 分支）：

```yaml
services:
  backend:
    image: infisical/infisical:latest   # 694MB 压缩，运行时 ~512MB-1GB RAM
    ports:
      - 80:8080
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started

  redis:
    image: redis                        # 运行时 ~128MB RAM

  db:
    image: postgres:14-alpine           # 运行时 ~256MB RAM
    volumes:
      - pg_data:/var/lib/postgresql/data
```

**总内存占用：~1-1.5GB 额外 RAM。** 在单服务器上，这会显著挤压现有服务（PostgreSQL、Keycloak、findclass-ssr、nginx、noda-ops）的内存空间。

**循环依赖问题：**
- Infisical 的 PostgreSQL 需要密码 -> 存在哪里？
- Infisical 的 ENCRYPTION_KEY 和 AUTH_SECRET -> 存在哪里？
- 最终还是需要至少一个 .env 文件来 bootstrap Infisical

### 为什么不用 HashiCorp Vault（详细分析）

**资源需求：**
- Vault 进程本身：256MB-512MB（最小可用），官方生产推荐 4-8GB
- 需要额外存储后端（Integrated Raft 或外部 Consul）
- 官方生产加固指南明确要求 "single tenancy"（独占一台服务器）

**运维复杂度：**
- Unseal 流程：每次重启需要至少 3-of-5 Shamir 密钥才能 unseal
- 必须配置 TLS 证书（生产环境不允许 HTTP）
- 需要管理 auth method（AppRole/Token/UserPass）、policy、secret engine
- 备份需要 `vault operator raft snapshot save`
- 密钥轮转需要手动策略或自动化脚本

**许可证问题：**
- Vault 从 2023 年改为 BSL (Business Source License)，非 MIT/Apache
- BSL 禁止在竞品托管服务中使用
- 虽然不影响内部使用，但 MIT 许可证的 Infisical 更自由

**能力浪费：**
- 我们需要存储约 20 个静态密钥（KV v2 足够）
- 不需要动态密钥生成（数据库临时凭证等）
- 不需要 PKI 证书管理
- 不需要数据库凭证轮转
- 不需要多集群复制
- Vault 90% 的能力在此场景中无用

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| HashiCorp Vault (自托管) | 单服务器资源不足（4GB+ RAM），运维复杂度与收益不成比例（unseal/TLS/policy），BSL 许可证 | Infisical Cloud |
| Infisical (自托管 Docker) | 3 个额外容器 + 1.5GB 内存，密钥管理的循环依赖（Infisical 的 DB 密码存哪？） | Infisical Cloud |
| CyberArk Conjur | 企业级产品，4GB+ RAM，配置复杂度极高 | Infisical Cloud |
| Docker Swarm Secrets | 需要切换到 Swarm 模式，破坏现有 Docker Compose standalone 架构 | Infisical CLI |
| 硬编码 .env 文件（当前方案） | 密钥明文存储在磁盘，存在 Git 历史中（.env.production 已 commit），无法审计访问，无法轮转 | Infisical Cloud + CLI |
| Jenkins Credentials Store 作为唯一密钥存储 | 仅 Jenkins 内使用，docker compose 启动仍需明文 .env，不统一。且无法版本管理密钥 | Infisical Cloud + Jenkins Credentials 仅存 bootstrap 凭据 |
| AWS Secrets Manager / GCP Secret Manager | 需要云平台账号和额外费用，增加网络延迟和外部依赖 | Infisical Cloud |
| etcd 作为密钥存储 | 无加密默认、无审计、无 Web UI，不是密钥管理工具而是分布式 KV 存储 | Infisical Cloud |
| ansible-vault | 仅适合 Ansible 场景，无 CI/CD 集成，无 Web UI，手动管理加密密钥 | Infisical Cloud |

## Stack Patterns by Variant

**如果将来需要离线/内网环境：**
- 迁移到 Infisical 自托管（`docker-compose.prod.yml`）
- 利用 Infisical CLI 的 `--domain=https://infisical.internal` 参数指向自托管实例
- 需要服务器增加至少 2GB 内存
- Infisical 自托管也包含在免费版中

**如果将来需要动态密钥（数据库临时凭证等）：**
- 评估升级到 Infisical Pro（Secret Rotation + Dynamic Secrets 功能）
- Infisical Pro 支持 PostgreSQL、MySQL 的动态密钥和自动轮转
- $18/月/identity，按需评估

**如果将来需要 KMS/HSM 硬件加密：**
- 必须用 Vault Enterprise 或 Infisical Enterprise
- 不在当前需求范围内

**如果将来部署频率增长到 >1000 次/月：**
- Infisical 免费版有 API 速率限制（具体限制未公开）
- 可考虑升级到 Pro 版获取更高速率限制

## Version Compatibility

| Component | Version | Compatible With | Notes |
|-----------|---------|-----------------|-------|
| Infisical CLI | 0.43.76 | Linux amd64/arm64, macOS | 宿主机安装，不在容器内 |
| Infisical CLI | 0.43.76 | Jenkins `sh` 步骤 | jenkins 用户需要有执行权限 |
| infisical/infisical Docker 镜像 | v0.159.16 | Docker Compose | 自托管时使用，694MB 镜像 |
| infisical/cli Docker 镜像 | 0.43.76 | Docker run | 备选方案（宿主机安装更简单） |
| hashicorp/vault Docker 镜像 | 2.0.0 / 1.21.x | Docker Compose | 不推荐使用，仅供参考 |
| PostgreSQL 14-alpine | 14.x | Infisical 自托管后端数据库 | Infisical 自托管时需要 |
| Redis | latest | Infisical 自托管缓存 | Infisical 自托管时需要 |

## 与现有架构的集成点

| 现有组件 | 集成方式 | 变更范围 |
|---------|---------|---------|
| `docker/.env` | Pipeline 从 Infisical 拉取后生成此文件 | 中 -- 运行时生成，不手动维护 |
| `.env.production` | VITE_* 变量迁移到 Infisical，构建时拉取 | 中 -- findclass-ssr Dockerfile 中需注入 |
| `docker/docker-compose.yml` | 无变更，仍从 .env 读取 | 无 -- Docker Compose 行为不变 |
| `jenkins/Jenkinsfile` | 添加 Fetch Secrets stage | 小 -- 在 Build stage 前插入 |
| `jenkins/Jenkinsfile.infra` | 同上，基础设施 Pipeline 也需要 | 小 -- 同样的 Fetch Secrets 模式 |
| `scripts/lib/health.sh` | 无变更 | 无 |
| `scripts/deploy/deploy-*.sh` | 无变更（手动部署仍读 .env） | 无 -- .env 由 Infisical 生成 |
| `config/nginx/*` | 无变更 | 无 |
| Backblaze B2 | 添加密钥快照备份 | 小 -- 新增备份类型 |

## Sources

- [Infisical 定价页](https://infisical.com/pricing) -- 免费版额度确认：无限制密钥、3 项目、3 环境、5 用户、10 集成，$0/月。HIGH confidence
- [Infisical GitHub 仓库](https://github.com/Infisical/infisical) -- MIT 许可证，25.9k stars，自托管 docker-compose.prod.yml 配置文件。HIGH confidence
- [Infisical Docker Hub: infisical/infisical](https://hub.docker.com/r/infisical/infisical/tags) -- 最新版本 v0.159.16 (2026-04-18)，镜像 694MB (amd64) / 677MB (arm64)。HIGH confidence
- [Infisical Docker Hub: infisical/cli](https://hub.docker.com/r/infisical/cli/tags) -- 最新版本 0.43.76 (2026-04-18)，镜像 46.64MB (amd64) / 44.17MB (arm64)。HIGH confidence
- [Infisical CLI Context7 文档](https://context7.com/infisical/cli/llms.txt) -- CLI 命令参考：`infisical run`、`infisical export`、`infisical login --method=universal-auth`、Machine Identity 认证流程。HIGH confidence
- [Infisical 自托管 docker-compose.prod.yml](https://raw.githubusercontent.com/Infisical/infisical/main/docker-compose.prod.yml) -- 官方自托管配置：3 个容器（backend + postgres + redis）。HIGH confidence
- [HashiCorp Vault Docker Hub](https://hub.docker.com/r/hashicorp/vault/tags) -- 最新版本 2.0.0 (2026-04-15)，镜像 182MB (amd64)。HIGH confidence
- [HashiCorp Vault 生产加固指南](https://developer.hashicorp.com/vault/docs/concepts/production-hardening) -- 推荐 single tenancy、禁用 swap、强制 TLS、启用 audit device。HIGH confidence
- [HashiCorp Vault 许可证](https://github.com/hashicorp/vault/blob/main/LICENSE) -- BSL (Business Source License)，非 MIT/Apache。HIGH confidence
- [Vault v2.x 文档](https://developer.hashicorp.com/vault/docs/what-is-vault) -- 存储选项（Integrated Raft、Filesystem、In-memory），Enterprise vs Community 功能。HIGH confidence
- 项目代码: `docker/docker-compose.yml`、`docker/.env`、`.env.production` -- 现有架构和密钥分布分析。HIGH confidence

---
*Stack research for: Noda 密钥管理集中化 (v1.8)*
*Researched: 2026-04-19*
