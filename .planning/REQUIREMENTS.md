# Requirements: Noda 密钥管理集中化

**Defined:** 2026-04-19
**Core Value:** 数据库永不丢失。密钥管理不能影响备份系统的独立性。

## v1 Requirements

### A. Infisical 基础设施 (INFRA)

- [ ] **INFRA-01**: 在 Jenkins 宿主机安装 Infisical CLI，通过脚本自动化安装
- [ ] **INFRA-02**: 创建 Infisical Cloud 项目（noda-infra），按消费方分组管理密钥（infra / apps / backup 环境隔离）
- [ ] **INFRA-03**: 配置 Infisical Universal Auth（Machine Identity），将 Client ID + Secret 存储到 Jenkins Credentials
- [ ] **INFRA-04**: Infisical 凭据离线备份到密码管理器 + B2 加密快照

### B. Jenkins Pipeline 集成 (PIPE)

- [ ] **PIPE-01**: Jenkinsfile 添加 "Fetch Secrets" stage，Pipeline 启动时通过 `infisical export` 拉取密钥生成 .env 文件
- [ ] **PIPE-02**: 使用 `withCredentials` 绑定 Infisical Machine Identity 凭据，确保不暴露到构建日志
- [ ] **PIPE-03**: Docker Compose 服务通过生成的 .env 文件获取运行时密钥，现有 `envsubst` 模板机制不变
- [ ] **PIPE-04**: VITE_* 构建时变量通过 `docker build --build-arg` 从 Infisical 拉取的密钥注入

### C. 迁移与清理 (MIGR)

- [ ] **MIGR-01**: 将 .env.production、docker/.env、scripts/backup/.env.backup 中所有密钥迁移到 Infisical
- [ ] **MIGR-02**: 备份系统（scripts/backup/.env.backup）保持独立明文文件不变，作为最后防线
- [ ] **MIGR-03**: 迁移验证通过后删除 .env.production 和 docker/.env 明文文件
- [ ] **MIGR-04**: 删除旧的 SOPS 相关代码（scripts/utils/decrypt-secrets.sh 及相关引用）

### D. 备份与安全 (BACKUP)

- [ ] **BACKUP-01**: 创建定期 cron 任务，将 Infisical 密钥快照导出到 Backblaze B2
- [ ] **BACKUP-02**: Git 历史清理 docker/.env 中泄露的真实密钥（BFG Repo Cleaner）

## v2 Requirements

### 密钥轮换

- **ROTA-01**: PostgreSQL 密码双用户交替轮换脚本
- **ROTA-02**: Keycloak Admin 密码定期轮换
- **ROTA-03**: B2 Application Key 定期轮换（当前建议 6 个月）

### 高级安全

- **SEC-01**: Infisical 审计日志定期审查
- **SEC-02**: 密钥访问权限最小化（按服务分配不同读取权限）
- **SEC-03**: Secret Versioning（需 Infisical Pro 版本）

## Out of Scope

| Feature | Reason |
|---------|--------|
| HashiCorp Vault 自托管 | 单服务器资源不足（需 512MB+ 额外内存），运维复杂（unseal） |
| Infisical 自托管 | 需 3 个额外容器 ~1.5GB 内存，形成循环依赖 |
| 实时密钥轮换 | 项目规模小，手动轮换足够 |
| Docker Secrets（Swarm） | 项目使用 Docker Compose 非 Swarm 模式 |
| 迁移备份系统 | 备份系统是核心价值保障，必须保持独立 |
| 多环境密钥（staging） | 当前只有生产环境，暂不需要 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| INFRA-01 | — | Pending |
| INFRA-02 | — | Pending |
| INFRA-03 | — | Pending |
| INFRA-04 | — | Pending |
| PIPE-01 | — | Pending |
| PIPE-02 | — | Pending |
| PIPE-03 | — | Pending |
| PIPE-04 | — | Pending |
| MIGR-01 | — | Pending |
| MIGR-02 | — | Pending |
| MIGR-03 | — | Pending |
| MIGR-04 | — | Pending |
| BACKUP-01 | — | Pending |
| BACKUP-02 | — | Pending |

**Coverage:**
- v1 requirements: 14 total
- Mapped to phases: 0
- Unmapped: 14 ⚠️

---
*Requirements defined: 2026-04-19*
*Last updated: 2026-04-19 after initial definition*
