# 特性模式分析：密钥管理集中化

**领域：** Jenkins + Docker Compose 环境下的集中密钥管理
**研究日期：** 2026-04-19
**总体置信度：** HIGH（基于 Context7 官方文档 + 项目代码实际审计 + 已验证的架构分析）

---

## 当前密钥分布审计

研究特性之前，必须先理解"从什么迁移到什么"。以下是项目当前所有密钥存储位置和注入方式的完整审计：

### 密钥文件分布

| 文件 | 包含的密钥 | 注入方式 | 被谁使用 |
|------|-----------|---------|---------|
| `docker/.env` | POSTGRES_PASSWORD, KEYCLOAK_ADMIN_PASSWORD, KEYCLOAK_DB_PASSWORD, CLOUDFLARE_TUNNEL_TOKEN, B2_ACCOUNT_ID, B2_APPLICATION_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL | Docker Compose `environment:` 中 `${VAR}` 变量替换 | postgres, noda-ops, keycloak (compose 启动时) |
| `docker/env-findclass-ssr.env` | DATABASE_URL(含密码), RESEND_API_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL (均为 `${VAR}` 模板) | `manage-containers.sh` 的 `envsubst` 生成临时 env-file -> `docker run --env-file` | findclass-ssr 蓝绿容器 |
| `docker/env-keycloak.env` | KC_DB_PASSWORD, KEYCLOAK_ADMIN_PASSWORD, SMTP_PASSWORD (均为 `${VAR}` 模板) | 同上 envsubst 机制 | keycloak 蓝绿容器 |
| `.env.production` | VITE_KEYCLOAK_URL, POSTGRES_PASSWORD, KEYCLOAK_ADMIN_PASSWORD, KEYCLOAK_DB_PASSWORD | `docker build --build-arg` 的 VITE_* 值 | findclass-ssr 前端构建 |
| `scripts/backup/.env.backup` | POSTGRES_PASSWORD, B2_ACCOUNT_ID, B2_APPLICATION_KEY | noda-ops 容器内 `source` | 备份系统 |
| Jenkins Credentials Store | cf-api-token, cf-zone-id, noda-apps-git-credentials | `withCredentials([string(...)])` | CDN Purge stage, Git checkout |
| `scripts/jenkins/config/jenkins-admin.env` | JENKINS_ADMIN_ID, JENKINS_API_TOKEN | Jenkins 脚本 `source` | setup-jenkins-pipeline.sh |

### 密钥注入链路

```
docker/.env（宿主机明文文件）
  |
  +--> docker compose up --> ${VAR} 替换 --> postgres/noda-ops 容器环境变量
  |
  +--> pipeline-stages.sh source docker/.env --> envsubst 模板 --> 临时 /tmp/*.env.$$
       |
       +--> docker run --env-file --> findclass-ssr/keycloak 蓝绿容器
```

### 核心问题

1. **明文存储**：`docker/.env` 包含所有生产密码，仅靠 `.gitignore` 和文件权限 `600` 保护
2. **分散冗余**：同一密码（如 POSTGRES_PASSWORD）在 3+ 个文件中重复出现
3. **无审计**：谁读了密码、什么时候改的，无记录
4. **无轮换**：密码从不轮换，B2 key 文件中甚至有注释建议"每 6 个月轮换一次"但从未执行
5. **Pipeline 脆弱**：`pipeline-stages.sh` 通过硬编码路径 fallback 查找 `.env` 文件

---

## 基本要求（Table Stakes）

不做就等于没完成密钥管理集中化的特性。

| # | 特性 | 为什么期望有 | 复杂度 | 依赖 | 优先级 |
|---|------|------------|--------|------|--------|
| T-01 | **Jenkins Pipeline 构建前密钥拉取** -- 在每个 Pipeline 的 Pre-flight 阶段从密钥管理服务拉取密钥，注入为环境变量 | 当前 source docker/.env 的方式要求明文文件存在于 workspace。集中化后 Pipeline 必须能从服务拉取密钥，否则蓝绿部署无法工作 | Medium | 密钥管理服务已部署 | P0 |
| T-02 | **Docker Compose 密钥注入** -- postgres 和 noda-ops 通过 compose 启动时从密钥管理服务获取环境变量 | 这两个服务不走蓝绿部署，由 `docker compose up` 直接启动。必须有机制让 compose 文件从密钥服务获取变量，否则基础设施起不来 | Medium | T-01 | P0 |
| T-03 | **env 模板 envsubst 替换机制保留** -- findclass-ssr 和 keycloak 的 `env-*.env` 模板 + `envsubst` 机制必须继续工作 | 蓝绿部署依赖 `manage-containers.sh` 的 `prepare_env_file()` 用 envsubst 生成临时 env-file。密钥集中化不能破坏这个核心部署流程 | Low | T-01 | P0 |
| T-04 | **迁移后删除明文 .env 文件** -- 迁移完成后删除 `docker/.env`、`.env.production` 中的实际密码值 | 如果迁移后仍保留明文文件，集中化就失去了意义。但 `.env.production` 的 VITE_* 值在构建时写入 JS，必须特殊处理 | Low | T-01, T-02, T-03 | P0 |
| T-05 | **密钥数据备份到 B2** -- 密钥管理服务的存储数据定期备份到 Backblaze B2 | 项目核心价值"数据库永不丢失"的延伸。密钥丢失等同于服务不可恢复 | Medium | B2 备份系统已就绪 | P0 |
| T-06 | **传输加密 (TLS)** -- 密钥管理服务与 Jenkins/Docker 之间通信加密 | 密钥在传输中明文等于没有集中化。Docker 内部网络通信必须 TLS 或至少验证服务身份 | Low | -- | P0 |
| T-07 | **静态加密** -- 密钥在存储时加密 | 密钥服务使用的数据库/文件必须是加密的。如果服务崩溃/磁盘被盗，密钥不能明文泄露 | Low | -- | P0 |

### 特性依赖关系

```
密钥管理服务部署（独立，无特性依赖）
  |
  +--> T-01 Jenkins Pipeline 密钥拉取
  |      |
  |      +--> T-03 envsubst 机制保留（依赖 T-01 拉取的变量）
  |
  +--> T-02 Docker Compose 密钥注入
  |
  +--> T-04 删除明文 .env（依赖 T-01 + T-02 + T-03 全部验证通过）
  |
  +--> T-05 B2 备份（依赖服务部署完成）
  |
  T-06 传输加密 + T-07 静态加密（服务自带，无额外依赖）
```

---

## 差异化特性（Differentiators）

做了会让密钥管理明显超越"把 .env 换个地方存"的特性。

| # | 特性 | 价值主张 | 复杂度 | 依赖 | 优先级 |
|---|------|----------|--------|------|--------|
| D-01 | **PostgreSQL 密码自动轮换** -- 使用双用户交替轮换模式（user1/user2），无停机更换数据库密码 | B2 key 文件注释"每 6 个月轮换一次"但从未执行。自动轮换消除人为疏忽。Vault 和 Infisical 均原生支持此模式 | Medium | T-01, T-02 | P1 |
| D-02 | **审计日志** -- 记录谁在什么时候读取/修改了哪个密钥 | 当前无法追踪密钥访问。审计日志是安全合规的基本要求，也为故障排查提供线索 | Low | -- | P1 |
| D-03 | **环境隔离 (prod/dev)** -- 密钥按环境分路径存储，Pipeline 通过参数选择环境 | 项目已有 prod/dev 双环境概念（docker-compose.dev.yml / docker-compose.prod.yml），密钥也应隔离 | Low | T-01 | P1 |
| D-04 | **密钥版本管理** -- 密钥变更后保留历史版本，可回滚 | 错误修改密码时可以回滚到上一个版本。Vault KV v2 和 Infisical 均原生支持 | Low | -- | P1 |
| D-05 | **Jenkins Credentials Provider 集成** -- 密钥管理服务作为 Jenkins Credential Provider，`withCredentials` 直接从服务拉取 | 当前的 cf-api-token、cf-zone-id 等存在 Jenkins 内部凭据存储。如果密钥服务能作为 Provider，所有凭据统一管理 | Medium | 密钥管理服务插件支持 | P2 |
| D-06 | **密钥模板引用** -- 一个密钥引用另一个密钥的值（如 DATABASE_URL 引用 POSTGRES_USER + POSTGRES_PASSWORD） | 消除 `env-*.env` 模板中 DATABASE_URL 手动拼接密码的冗余。Infisical 原生支持 secret references | Low | T-03 | P2 |
| D-07 | **轮换 webhook 通知** -- 密钥轮换成功/失败时发送通知 | 轮换是高风险操作，失败意味着服务可能无法连接数据库。通知机制确保及时响应 | Low | D-01 | P2 |

---

## 反特性（Anti-Features）

明确不应该做的事情。做了会适得其反或过度工程化。

| # | 反特性 | 原因 | 替代方案 |
|---|--------|------|----------|
| A-01 | **不要删除 Jenkins Credentials Store** | Jenkins 的 Git SSH key（noda-apps-git-credentials）、Cloudflare API token（cf-api-token）已经安全存储在 Jenkins 内部。这些与 Docker 服务密钥的生命周期不同（Jenkins 操作 vs 容器运行），强行统一增加攻击面 | Jenkins Credentials 保留不动，仅迁移 Docker/应用密钥到集中服务 |
| A-02 | **不要使用 Vault 动态密钥（Dynamic Secrets）** | 动态密钥（按请求生成临时数据库凭证）需要应用代码配合（连接池回收、新凭证重新连接）。findclass-ssr 和 Keycloak 都不支持这种模式，引入后会导致连接中断 | 使用静态密钥 + 定期轮换（D-01 的双用户交替模式） |
| A-03 | **不要替换 envsubst 模板机制** | `manage-containers.sh` 的 `prepare_env_file()` 是蓝绿部署的核心。重写为密钥服务直接注入会导致 manage-containers.sh、pipeline-stages.sh、所有 Jenkinsfile 大面积重写。风险远超收益 | 保持 envsubst 模板不变，仅将 `source docker/.env` 改为从密钥服务拉取 |
| A-04 | **不要引入 Kubernetes** | 项目是单服务器 Docker Compose 架构，引入 K8s 仅为密钥管理是极度过度工程化。Vault 的 K8s Agent Injector 不适用 | 使用 CLI/API 方式拉取密钥 |
| A-05 | **不要使用 Doppler（SaaS-only 方案）** | Doppler 不支持自托管，所有密钥必须上传到 Doppler 云。项目已有自托管基础设施的要求（PostgreSQL、Keycloak 均在本地），密钥不应离开服务器 | 使用 Vault 或 Infisical 自托管 |
| A-06 | **不要同时部署 Vault + Infisical** | 两个系统职责重叠，增加运维复杂度。选择一个并用好它 | 根据复杂度评估选择其一 |
| A-07 | **不要为密钥管理服务引入独立的 Consul 集群** | Vault 可以使用 Integrated Storage (Raft)，不需要 Consul。对单服务器场景，Consul 是不必要的依赖 | Vault Raft 存储后端 |
| A-08 | **不要在密钥服务不可用时阻塞所有部署** | 密钥服务是新的单点故障。如果服务挂了，必须有 break-glass 机制让紧急部署继续进行 | 保留本地密钥文件作为 fallback（加密存储，紧急时解密使用） |

---

## 密钥注入模式对比

项目中有 3 种不同的密钥注入场景，每种需要不同的集成方式。

### 场景 1：Docker Compose 服务启动

```
密钥服务 → shell 脚本拉取 → export 环境变量 → docker compose up（${VAR} 替换）
```

**现状**：`source docker/.env` -> `docker compose up`
**迁移后**：`vault kv get -format=json secret/noda/prod` -> `eval $(vault kv get ...)` -> `docker compose up`

**关键约束**：compose 文件的 `environment:` 块中 `${POSTGRES_PASSWORD}` 语法必须工作。密钥服务的输出必须是可 export 的 shell 变量格式。

### 场景 2：蓝绿容器部署

```
密钥服务 → pipeline-stages.sh 拉取 → export 环境变量
  → manage-containers.sh prepare_env_file() → envsubst 模板 → docker run --env-file
```

**现状**：`source docker/.env` -> envsubst 替换 `${VAR}` -> `docker run --env-file /tmp/*.env.$$`
**迁移后**：从密钥服务拉取 -> export 到当前 shell -> envsubst 替换 -> `docker run --env-file`（envsubst 机制完全不变）

**关键约束**：`prepare_env_file()` 中 `ENVSUBST_VARS` 定义的变量列表必须全部从密钥服务可用。

### 场景 3：前端构建时密钥

```
密钥服务 → Jenkins Pipeline 拉取 → docker build --build-arg VITE_KEYCLOAK_URL=...
```

**现状**：从 `.env.production` 读取 VITE_* 值 -> build-arg 传入 Dockerfile
**迁移后**：从密钥服务拉取 VITE_* 值 -> build-arg 传入（Dockerfile 不变）

**关键约束**：VITE_* 变量在 `docker build` 时写入 JS 文件，运行时环境变量无法覆盖。密钥服务必须在 Build stage 前提供这些值。

---

## 密钥清单与分类

项目当前使用以下密钥，按安全等级和轮换频率分类：

### 高敏感度密钥（数据库密码、管理密码）

| 密钥 | 当前位置 | 使用者 | 轮换建议 |
|------|---------|--------|---------|
| POSTGRES_PASSWORD | docker/.env, .env.production, scripts/backup/.env.backup | postgres, findclass-ssr, noda-ops, keycloak, 备份系统 | 季度 |
| KEYCLOAK_ADMIN_PASSWORD | docker/.env, .env.production | keycloak 管理控制台 | 季度 |
| KEYCLOAK_DB_PASSWORD | docker/.env | keycloak 数据库连接 | 季度 |

### API 密钥和令牌

| 密钥 | 当前位置 | 使用者 | 轮换建议 |
|------|---------|--------|---------|
| CLOUDFLARE_TUNNEL_TOKEN | docker/.env | noda-ops (cloudflared) | 年度 |
| B2_ACCOUNT_ID | docker/.env, scripts/backup/.env.backup | noda-ops 备份系统 | 半年 |
| B2_APPLICATION_KEY | docker/.env, scripts/backup/.env.backup | noda-ops 备份系统 | 半年 |
| RESEND_API_KEY | (envsubst 模板引用) | findclass-ssr 邮件发送 | 年度 |
| ANTHROPIC_AUTH_TOKEN | docker/.env, env-findclass-ssr.env | findclass-ssr AI 功能 | 年度 |
| CF_API_TOKEN | Jenkins Credentials | CDN 缓存清除 | 年度 |
| CF_ZONE_ID | Jenkins Credentials | CDN 缓存清除 | 不需要轮换 |
| SMTP_PASSWORD | (envsubst 模板引用) | keycloak 邮件 | 年度 |

### 非敏感配置（不需要集中管理）

| 变量 | 原因 |
|------|------|
| VITE_KEYCLOAK_URL, VITE_KEYCLOAK_REALM, VITE_KEYCLOAK_CLIENT_ID | 公开信息，嵌入前端 JS |
| POSTGRES_USER, POSTGRES_DB | 非敏感配置值 |
| B2_BUCKET_NAME, B2_PATH | 非敏感配置值 |

---

## 密钥服务方案对比（项目场景）

基于项目的实际约束（单服务器、Docker Compose、~60 部署/月、已有 SOPS 加密经验），对比三个方案。

### 评估维度

| 维度 | HashiCorp Vault | Infisical (自托管) | SOPS + age (当前方案增强) |
|------|-----------------|-------------------|--------------------------|
| **部署复杂度** | 中 -- 单节点 Raft，需 seal/unseal 流程 | 高 -- 需要 PostgreSQL + Redis + 多个微服务 | 极低 -- 已在用，无新服务 |
| **内存占用** | ~200-400MB (单节点) | ~1GB+ (backend + frontend + worker + DB + Redis) | 0 (CLI 工具) |
| **Jenkins 集成** | HIGH -- 官方 Jenkins 插件，withCredentials 原生支持 | MEDIUM -- 通过 CLI `infisical export` 拉取 | LOW -- 通过 shell 脚本 `sops --decrypt` |
| **密钥轮换** | 原生支持静态轮换 + 数据库引擎 | 原生支持 PostgreSQL 密码轮换 | 不支持 -- 纯手动 |
| **审计日志** | 原生 file/socket audit device | 内置审计日志 + API | 不支持 |
| **环境隔离** | 路径隔离 (secret/noda/prod, secret/noda/dev) | 原生环境概念 (dev/staging/prod) | 目录隔离 |
| **学习曲线** | 高 -- policies, auth methods, seal/unseal | 低 -- Web UI, 简单 CLI | 已掌握 |
| **运维负担** | 中 -- 监控 seal 状态、备份 Raft 存储 | 高 -- 5+ 个容器、数据库维护、升级 | 极低 -- 仅文件管理 |
| **单服务器可行性** | 可行但偏重 -- 200MB+ 内存开销 | 不可行 -- 资源需求超出单服务器余量 | 完美适配 |

### 推荐方案评估

**对 Noda 项目的推荐排序：**

1. **SOPS + age (增强版)** -- 最适合当前项目规模
2. **Vault (单节点)** -- 如果未来需要审计日志和自动轮换
3. **Infisical** -- 资源需求过高，不适合单服务器

**理由**：
- 项目只有 ~20 个密钥，60 次部署/月
- 单服务器资源有限（findclass-ssr 512MB、Keycloak 1GB、PostgreSQL 2GB 已占用大部分内存）
- 已有 SOPS + age 加密机制（`decrypt-secrets.sh` 存在但未在 Pipeline 中使用）
- SOPS 没有运行时服务，不存在单点故障
- 迁移成本最低 -- 增强现有 `decrypt-secrets.sh` 并集成到 Pipeline 即可

---

## B2 备份策略对比

密钥数据备份到 B2 的三种策略：

| 策略 | 方式 | 优点 | 缺点 | 推荐度 |
|------|------|------|------|--------|
| **SOPS 加密后直接上传** | `sops --encrypt` + `rclone copy` | 文件已加密，B2 上零风险；复用现有备份基础设施 | 需要定期同步 | 推荐 |
| **Vault Raft 快照** | `vault operator raft snapshot` | 原生备份机制 | 需要 Vault 运行才能恢复 | 仅 Vault 方案 |
| **数据库 pg_dump** | 备份密钥服务的 PostgreSQL | 标准 pg_dump 流程 | 密钥服务可能有非 PG 存储后端 | 备选 |

---

## MVP 建议

### Phase 1：Pipeline 集成 SOPS 解密（必须完成，解决 80% 的安全问题）

1. **T-01**：在 `pipeline-stages.sh` 的密钥加载部分（第 20-29 行）替换 `source docker/.env` 为 SOPS 解密
2. **T-02**：`deploy-infrastructure-prod.sh` 和 `deploy-apps-prod.sh` 同样改为 SOPS 解密
3. **T-03**：验证 envsubst 模板机制不受影响（仅替换变量来源）
4. **T-04**：将所有密钥文件用 SOPS 加密，明文文件加入 .gitignore
5. **T-05**：加密后的密钥文件通过现有 B2 备份流程上传

### Phase 2：增强特性（建议完成，提升安全性）

1. **D-02**：在 SOPS 解密时记录审计日志（简单的 access.log 文件）
2. **D-03**：为 prod/dev 环境创建独立的加密文件
3. **D-04**：SOPS + git 天然支持版本管理

### Phase 3：如果未来需要（锦上添花）

1. **D-01**：PostgreSQL 密码自动轮换（需要额外工具，如自定义脚本 + cron）
2. **D-05**：如果迁移到 Vault，使用 Jenkins Vault Plugin 作为 Credentials Provider
3. **D-06**：密钥模板引用（需要 Vault/Infisical 支持）

### 明确推迟

- **Vault 部署**：项目规模不需要，SOPS 增强版已满足所有 P0 需求。Vault 的 seal/unseal、内存开销、运维复杂度对单服务器场景是不必要的负担
- **Infisical 部署**：资源需求过高（需要独立的 PostgreSQL + Redis + 多微服务），不适合单服务器
- **动态密钥**：应用不支持，收益不明确
- **Jenkins Credentials 统一**：现有 Jenkins Credentials Store 工作正常，不需要迁移

---

## 特性依赖图

```
Phase 1（MVP）
  |
  T-05 B2 备份 ───────────────────── 独立，可最先或最后做
  |
  T-06 传输加密 ──────────────────── SOPS 文件级加密，天然满足
  T-07 静态加密 ──────────────────── SOPS + age，天然满足
  |
  T-01 Pipeline 密钥拉取 ─────────── 核心特性，替换 source .env
  |   |
  |   +-- T-03 envsubst 机制保留 ── 验证 T-01 不破坏模板替换
  |
  T-02 Compose 密钥注入 ─────────── 与 T-01 并行，替换 deploy 脚本中的 .env
  |
  T-04 删除明文 .env ────────────── 最后做，依赖 T-01 + T-02 + T-03 验证通过

Phase 2（增强）
  |
  D-02 审计日志 ──────────────────── 独立，可随时添加
  D-03 环境隔离 ──────────────────── 独立，需要规划文件结构
  D-04 版本管理 ──────────────────── SOPS + git 天然支持

Phase 3（可选）
  |
  D-01 密码轮换 ──────────────────── 需要 cron + 自定义脚本
  D-05 Jenkins Provider ──────────── 需要 Vault
  D-06 密钥引用 ──────────────────── 需要 Vault/Infisical
```

---

## 置信度评估

| 区域 | 置信度 | 原因 |
|------|--------|------|
| 当前密钥分布审计 | HIGH | 基于对所有 .env 文件、Jenkinsfile、pipeline-stages.sh 的完整代码阅读 |
| SOPS 增强方案可行性 | HIGH | 项目已有 decrypt-secrets.sh 和 SOPS + age 加密机制，仅需要集成到 Pipeline |
| Vault/Infisical 评估 | MEDIUM | 基于 Context7 官方文档 + 训练数据，WebSearch 不可用，但两个产品的架构特征已充分了解 |
| 资源需求估算 | MEDIUM | Vault ~200-400MB 为经验值，Infisical ~1GB+ 为多微服务架构的合理估计 |
| 密钥轮换可行性 | MEDIUM | 双用户交替轮换模式是标准做法，但需要实际验证 PostgreSQL 角色切换 |

---

## 来源

### Primary (HIGH confidence)

- [Context7 /websites/developer_hashicorp_vault] -- Vault KV v2 读写操作、Docker 部署、Raft 存储后端、审计日志 [VERIFIED]
- [Context7 /websites/jenkins_io_doc] -- Jenkins `withCredentials` 用法、Declarative Pipeline `environment` 块、`credentials()` 函数 [VERIFIED]
- [Context7 /websites/infisical] -- Infisical CLI `export`/`run` 命令、自托管部署模型、PostgreSQL 密码轮换 API、审计日志结构 [VERIFIED]
- [Context7 /infisical/cli] -- Infisical CLI CI/CD 集成、machine identity token、`infisical export --token` [VERIFIED]
- [Context7 /websites/getsops_io] -- SOPS 加密文件格式、age 后端、.env 文件支持 [VERIFIED]
- 项目代码审计 -- `docker/.env`, `docker/env-findclass-ssr.env`, `docker/env-keycloak.env`, `scripts/pipeline-stages.sh` (第 20-29 行), `scripts/manage-containers.sh` (prepare_env_file), `jenkins/Jenkinsfile.findclass-ssr`, `scripts/utils/decrypt-secrets.sh` [VERIFIED: 代码阅读]

### Secondary (MEDIUM confidence)

- WebSearch 不可用（API 余额不足），Vault/Infisical 对比基于训练数据 + Context7 文档综合判断
- Vault 内存占用 ~200-400MB 为社区经验值，未经生产环境实测验证
- Infisical 自托管资源需求基于 Docker 镜像分析（backend + frontend + worker + PostgreSQL + Redis）

---

*Feature research for: Noda v1.8 密钥管理集中化*
*Researched: 2026-04-19*
