# Requirements: Noda 基础设施

**Defined:** 2026-04-11
**Core Value:** 数据库永不丢失。即使发生灾难，也能从最近12小时内的备份中恢复数据。

## v1.0 Requirements (Shipped)

### Backup — 备份执行

- [x] **BACKUP-01**: 系统可以备份多个数据库（keycloak_db、findclass_db）及其全局对象
- [x] **BACKUP-02**: 备份文件使用时间戳和数据库名命名（格式：`{db_name}_{YYYYMMDD_HHmmss}.dump`）
- [x] **BACKUP-03**: 备份使用 pg_dump -Fc 自定义压缩格式（自带 zlib 压缩）
- [x] **BACKUP-04**: 备份前执行 PostgreSQL 健康检查（pg_isready）
- [x] **BACKUP-05**: 备份前检查磁盘空间是否充足

### Upload — 云存储上传

- [x] **UPLOAD-01**: 备份文件自动上传到 Backblaze B2 云存储（使用 rclone）
- [x] **UPLOAD-02**: 上传失败时自动重试（指数退避，最多 3 次）
- [x] **UPLOAD-03**: 上传后自动验证校验和（rclone --checksum）
- [x] **UPLOAD-04**: 应用层保留策略自动清理 7 天前的旧备份（本地和云端）
- [x] **UPLOAD-05**: 自动清理未完成的上传文件（B2 lifecycle + rclone）

### Restore — 恢复功能

- [x] **RESTORE-01**: 提供一键恢复脚本，可从云存储下载并恢复数据库
- [x] **RESTORE-02**: 支持列出所有可用的备份文件（按时间排序）
- [x] **RESTORE-03**: 支持恢复指定的数据库（不影响其他运行中的数据库）
- [x] **RESTORE-04**: 支持恢复到不同的数据库名（用于安全测试）

### Verify — 验证测试

- [x] **VERIFY-01**: 备份后立即验证完整性（pg_restore --list）
- [ ] **VERIFY-02**: 每周自动执行恢复测试，验证备份可用性

### Monitor — 监控告警

- [ ] **MONITOR-01**: 备份脚本输出结构化日志（时间戳、数据库名、文件大小、耗时、状态、错误详情）
- [ ] **MONITOR-02**: 备份失败时发送 Webhook 告警通知
- [ ] **MONITOR-03**: 追踪备份持续时间，偏差超过 50% 时输出警告
- [x] **MONITOR-04**: 备份前检查 Docker volume 可用磁盘空间
- [ ] **MONITOR-05**: 脚本使用标准退出码（0=成功、1=连接失败、2=备份失败、3=上传失败、4=清理失败、5=验证失败）

### Security — 安全管理

- [x] **SECURITY-01**: 所有凭证（B2 Key、DB 密码）通过环境变量管理，绝不硬编码
- [x] **SECURITY-02**: 使用最低权限的 B2 Application Key（仅限备份 bucket + 必要权限 + 文件前缀限制）

## v1.2 Requirements

### 备份修复

- [ ] **BFIX-01**: B2 自动备份恢复 — 调查 4/8 起中断原因，修复后备份正常上传到 B2
- [ ] **BFIX-02**: 磁盘空间检查正常工作 — 备份前检查磁盘空间并在不足时告警
- [ ] **BFIX-03**: 验证测试下载功能正常 — 自动验证测试能成功下载备份文件进行校验

### 服务整合

- [ ] **GROUP-01**: findclass-ssr 目录迁移 — 相关文件迁移到 noda-apps/ 目录下
- [ ] **GROUP-02**: Docker 分组标签 — 容器 labels/project 归入 noda-apps 分组

### Keycloak 双环境

- [ ] **KCDEV-01**: 本地 dev Keycloak 实例 — 独立 keycloak-dev 容器 + keycloak_dev 数据库 + 端口偏移
- [ ] **KCDEV-02**: Dev 认证方式 — 开发环境可使用密码登录（Google OAuth 可选）
- [ ] **KCDEV-03**: Dev 开发效率 — 开发环境禁用主题缓存，支持热重载

### Keycloak 自定义主题

- [ ] **THEME-01**: 品牌化登录页 — 创建 noda 主题，CSS 覆盖实现 Noda 品牌风格
- [ ] **THEME-02**: 自定义 Logo — 替换默认 Keycloak Logo 为 Noda Logo

## Future Requirements

### Keycloak 增强

- **THEME-03**: 中文消息包 — 登录页中文文案自定义
- **THEME-04**: Email 主题 — 品牌化邮件模板
- **THEME-05**: Account 主题 — 品牌化账户管理页

### 性能优化

- **PERF-01**: 增量备份（pg_basebackup + WAL）— 减少备份时间和存储空间
- **PERF-02**: 并行备份（pg_restore -j）— 加快大数据库恢复速度

### 高级功能

- **ADV-01**: PITR 时间点恢复 — 恢复到任意时间点
- **ADV-02**: 跨区域备份复制 — 地理灾难恢复

## Out of Scope

| Feature | Reason |
|---------|--------|
| 实时复制/流备份 | 需要主从架构，6-12 小时 RPO 已满足需求 |
| PITR 时间点恢复 | 复杂度极高 |
| 跨区域备份复制 | B2 已有数据中心冗余 |
| v2 React 主题 | Keycloak 26.x 仍推荐 v1 FreeMarker，v2 仅限 Account Console |
| 多 Realm 管理 | 当前仅需 noda realm，无需多租户 |
| LDAP/AD 集成 | Google OAuth 已满足认证需求 |

## Traceability

v1.0 需求已完成归档。v1.2 需求待路线图创建时映射。

| Requirement | Phase | Status |
|-------------|-------|--------|
| BFIX-01 | — | Pending |
| BFIX-02 | — | Pending |
| BFIX-03 | — | Pending |
| GROUP-01 | — | Pending |
| GROUP-02 | — | Pending |
| KCDEV-01 | — | Pending |
| KCDEV-02 | — | Pending |
| KCDEV-03 | — | Pending |
| THEME-01 | — | Pending |
| THEME-02 | — | Pending |

**Coverage:**
- v1.2 requirements: 10 total
- Mapped to phases: 0
- Unmapped: 10 ⚠️

---
*Requirements defined: 2026-04-06*
*Last updated: 2026-04-11 after v1.2 requirements definition*
