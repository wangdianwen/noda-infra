# Requirements: Noda Infrastructure v1.3

**Defined:** 2026-04-12
**Core Value:** 消除所有端口直接暴露，统一通过 nginx 代理，完成容器分组

## v1.3 Requirements

### PostgreSQL 升级 (PG)

- [ ] **PG-01**: pg_dump 版本匹配服务端 17.x（noda-ops Dockerfile 升级 Alpine 3.21 + postgresql17-client）
- [ ] **PG-02**: 备份脚本显式设置 sslmode=disable（防止 PG17 默认 sslmode=require 导致 Docker 内部连接静默失败）

### Keycloak 端口收敛 (KC)

- [ ] **KC-01**: auth.noda.co.nz 由 nginx 统一反向代理到 Keycloak（Cloudflare Dashboard 路由更新）
- [ ] **KC-02**: Docker Compose 移除 Keycloak 8080/9000 端口直接暴露
- [ ] **KC-03**: dev 应用复用线上 Keycloak（Google OAuth 配置 localhost redirect URI，dev 使用 auth.noda.co.nz 认证）

### 端口安全 (SEC)

- [ ] **SEC-01**: postgres-dev 5433 端口从 0.0.0.0 绑定改为 127.0.0.1（仅本地可访问）
- [ ] **SEC-02**: Keycloak 9000 管理端口不再外部暴露（在 KC-02 中一并完成）

### 容器分组 (GRP)

- [ ] **GRP-01**: 所有容器添加 noda.environment=prod/dev 标签，与现有 noda.service-group 互补
- [ ] **GRP-02**: 统一标签命名规范（修复 noda-apps vs apps 的不一致）

## Future Requirements

### Prisma 7 兼容性

- **PRISMA-01**: findclass-ssr 迁移 schema.prisma 到 Prisma 7.7.0 格式
- **PRISMA-02**: 验证所有 Prisma 查询兼容新 API

## Out of Scope

| Feature | Reason |
|---------|--------|
| Docker Compose profiles | 当前 overlay 模式已满足需求，profiles 增加复杂度 |
| 网络隔离（prod/dev 分离网络） | 标签分组已满足管理需求，网络隔离过度工程 |
| dev Keycloak 独立实例 | 复用线上 Keycloak 更简单，维护成本更低 |
| Prisma 7 迁移 | 依赖 noda-apps 仓库变更，非基础设施范畴 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| PG-01 | Phase 15 | Pending |
| PG-02 | Phase 15 | Pending |
| KC-01 | Phase 16 | Pending |
| KC-02 | Phase 16 | Pending |
| KC-03 | Phase 16 | Pending |
| SEC-01 | Phase 17 | Pending |
| SEC-02 | Phase 17 | Pending |
| GRP-01 | Phase 18 | Pending |
| GRP-02 | Phase 18 | Pending |

**Coverage:**
- v1.3 requirements: 9 total
- Mapped to phases: 9
- Unmapped: 0 ✓

---
*Requirements defined: 2026-04-12*
*Last updated: 2026-04-12 after initial definition*
