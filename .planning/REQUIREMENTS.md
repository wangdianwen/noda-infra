# Requirements: Noda 基础设施 v1.11

**Defined:** 2026-05-08
**Core Value:** 数据库永不丢失。Pre-prod 环境确保上线前全链路验证，降低 prod 故障风险。

## v1.11 Requirements

### 基础设施准备 (INFRA)

- [ ] **INFRA-01**: 创建 `noda_preprod` 数据库（同 PostgreSQL 实例，独立数据库 + 用户）
- [ ] **INFRA-02**: 创建 Keycloak `noda-preprod` realm（Google OAuth redirect URIs 包含 pre-prod 域名）
- [ ] **INFRA-03**: 创建 `noda-frontend-preprod` Keycloak client（redirect URIs 指向 pre.class.noda.co.nz 和 pre.auth.noda.co.nz）
- [ ] **INFRA-04**: 创建 Nginx pre-prod upstream 配置（`upstream-findclass-preprod.conf`，变量名使用 `_preprod_` 前缀避免冲突）
- [ ] **INFRA-05**: 创建 4 个 Nginx pre-prod server blocks（pre.class.noda.co.nz / pre.auth.noda.co.nz / pre.noda.co.nz / pre.admin.noda.co.nz）
- [ ] **INFRA-06**: 在 Cloudflare 添加 4 个 pre-prod 子域名 DNS 记录 + Tunnel 路由

### 蓝绿部署扩展 (BLUE)

- [ ] **BLUE-01**: `manage-containers.sh` 的 `update_upstream()` 支持 UPSTREAM_VARS_PREFIX 环境变量，pre-prod 使用 `preprod_` 前缀
- [ ] **BLUE-02**: `manage-containers.sh` 的 `noda.environment` 标签参数化（`NODA_ENVIRONMENT` 环境变量，默认 `prod`）
- [ ] **BLUE-03**: 创建 `env-noda-apps-preprod.env` 环境变量模板（DATABASE_URL 指向 noda_preprod，KEYCLOAK_REALM=noda-preprod）
- [ ] **BLUE-04**: pre-prod 容器命名规范：`noda-apps-preprod-{blue|green}`
- [ ] **BLUE-05**: pre-prod 状态文件：`/opt/noda/active-env-preprod`
- [ ] **BLUE-06**: pre-prod 蓝绿 wrapper 脚本（设置 SERVICE_NAME/ACTIVE_ENV_FILE/UPSTREAM_CONF 等 env vars）
- [ ] **BLUE-07**: `image-cleanup.sh` 适配 pre-prod 容器名前缀（`noda-apps-preprod`）

### Jenkins Pipeline (PIPE)

- [ ] **PIPE-01**: 创建 `Jenkinsfile.noda-apps-preprod`（Build -> Test -> Deploy Pre-prod -> Health -> Switch -> Verify）
- [ ] **PIPE-02**: 创建 `Jenkinsfile.noda-apps-promote`（读取 pre-prod 镜像 digest -> 部署 Prod 蓝绿 -> Health -> Switch -> Verify -> CDN Purge）
- [ ] **PIPE-03**: Promote Pipeline 使用与 pre-prod 完全相同的 Docker 镜像（Build Once / Promote Anywhere）
- [ ] **PIPE-04**: Hotfix 紧急通道：直接触发 `Jenkinsfile.noda-apps` 部署到 Prod，跳过 pre-prod
- [ ] **PIPE-05**: Pipeline 并发锁：prod 和 pre-prod Pipeline 使用 `lock()` 资源防止同时操作 Nginx/Docker daemon

### 安全防护 (SEC)

- [ ] **SEC-01**: Doppler 创建 `pre` config，pre-prod Pipeline 使用 `DOPPLER_CONFIG=pre` 加载独立密钥
- [ ] **SEC-02**: Nginx upstream 写入防护：Pipeline 执行前验证 UPSTREAM_CONF 路径包含预期的环境标识（pre-prod 不能写入 prod upstream 文件）
- [ ] **SEC-03**: Docker 网络别名隔离：pre-prod 容器使用 `noda-apps-preprod` 别名，避免与 prod 的 `noda-apps` 别名冲突

## v2 Requirements

### 增强功能

- **ENHANCE-01**: Promote 审批门禁（Promote Pipeline 增加 `input` 步骤等待人工确认）
- **ENHANCE-02**: Git Tag 版本追踪（Promote 成功后自动打 tag）
- **ENHANCE-03**: Smoke Test 自动化门禁（pre-prod 部署后自动运行 E2E 测试套件）
- **ENHANCE-04**: Pre-prod 数据库定期从 prod 同步脱敏数据
- **ENHANCE-05**: Cloudflare Access 保护 pre-prod 域名（限制访问 IP 或 SSO 认证）

## Out of Scope

| Feature | Reason |
|---------|--------|
| 独立 PostgreSQL 实例 | 同实例不同库已满足需求，资源消耗更少 |
| 独立 Keycloak 容器 | 同实例不同 realm 已满足需求，1GB+ 内存开销不值得 |
| Docker 网络隔离（prod/pre-prod 分离网络） | 共享 noda-network 是既定决策，标签分组已满足管理需求 |
| 前端运行时配置注入 | NEXT_PUBLIC_* 变量在 pre-prod 和 prod 可以使用相同的 Keycloak URL（通过 Nginx 代理） |
| Pre-prod CDN 缓存清除 | pre-prod 流量低，缓存影响小，优先级低 |
| 自动触发部署（Git push -> auto deploy） | 项目更新频率低，手动触发更可控 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| INFRA-01 | Phase 53 | Pending |
| INFRA-02 | Phase 53 | Pending |
| INFRA-03 | Phase 53 | Pending |
| INFRA-04 | Phase 54 | Pending |
| INFRA-05 | Phase 54 | Pending |
| INFRA-06 | Phase 54 | Pending |
| BLUE-01 | Phase 55 | Pending |
| BLUE-02 | Phase 55 | Pending |
| BLUE-03 | Phase 55 | Pending |
| BLUE-04 | Phase 55 | Pending |
| BLUE-05 | Phase 55 | Pending |
| BLUE-06 | Phase 55 | Pending |
| BLUE-07 | Phase 55 | Pending |
| PIPE-01 | Phase 56 | Pending |
| PIPE-02 | Phase 56 | Pending |
| PIPE-03 | Phase 56 | Pending |
| PIPE-04 | Phase 56 | Pending |
| PIPE-05 | Phase 56 | Pending |
| SEC-01 | Phase 53 | Pending |
| SEC-02 | Phase 56 | Pending |
| SEC-03 | Phase 55 | Pending |

**Coverage:**
- v1.11 requirements: 21 total
- Mapped to phases: 21
- Unmapped: 0

---
*Requirements defined: 2026-05-08*
*Last updated: 2026-05-08 after roadmap creation*
