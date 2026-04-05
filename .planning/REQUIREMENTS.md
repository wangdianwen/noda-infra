# Requirements: Noda 数据库备份系统

**Defined:** 2026-04-06
**Core Value:** 数据库永不丢失。即使发生服务器崩溃、误删除、数据库损坏等灾难，也能从最近12小时内的备份中恢复数据。

## v1 Requirements

里程碑 v1.0 的需求。每个需求都映射到路线图的某个阶段。

### Backup — 备份执行

- [ ] **BACKUP-01**: 系统可以备份多个数据库（keycloak_db、findclass_db）及其全局对象
- [ ] **BACKUP-02**: 备份文件使用时间戳和数据库名命名（格式：`{db_name}_{YYYYMMDD_HHmmss}.dump`）
- [ ] **BACKUP-03**: 备份使用 pg_dump -Fc 自定义压缩格式（自带 zlib 压缩）
- [ ] **BACKUP-04**: 备份前执行 PostgreSQL 健康检查（pg_isready）
- [ ] **BACKUP-05**: 备份前检查磁盘空间是否充足

### Upload — 云存储上传

- [ ] **UPLOAD-01**: 备份文件自动上传到 Backblaze B2 云存储（使用 rclone）
- [ ] **UPLOAD-02**: 上传失败时自动重试（指数退避，最多 3 次）
- [ ] **UPLOAD-03**: 上传后自动验证校验和（rclone --checksum）
- [ ] **UPLOAD-04**: 应用层保留策略自动清理 7 天前的旧备份（本地和云端）
- [ ] **UPLOAD-05**: 自动清理未完成的上传文件（B2 lifecycle + rclone）

### Restore — 恢复功能

- [ ] **RESTORE-01**: 提供一键恢复脚本，可从云存储下载并恢复数据库
- [ ] **RESTORE-02**: 支持列出所有可用的备份文件（按时间排序）
- [ ] **RESTORE-03**: 支持恢复指定的数据库（不影响其他运行中的数据库）
- [ ] **RESTORE-04**: 支持恢复到不同的数据库名（用于安全测试）

### Verify — 验证测试

- [ ] **VERIFY-01**: 备份后立即验证完整性（pg_restore --list）
- [ ] **VERIFY-02**: 每周自动执行恢复测试，验证备份可用性

### Monitor — 监控告警

- [ ] **MONITOR-01**: 备份脚本输出结构化日志（时间戳、数据库名、文件大小、耗时、状态、错误详情）
- [ ] **MONITOR-02**: 备份失败时发送 Webhook 告警通知
- [ ] **MONITOR-03**: 追踪备份持续时间，偏差超过 50% 时输出警告
- [ ] **MONITOR-04**: 备份前检查 Docker volume 可用磁盘空间
- [ ] **MONITOR-05**: 脚本使用标准退出码（0=成功、1=连接失败、2=备份失败、3=上传失败、4=清理失败、5=验证失败）

### Security — 安全管理

- [ ] **SECURITY-01**: 所有凭证（B2 Key、DB 密码）通过环境变量管理，绝不硬编码
- [ ] **SECURITY-02**: 使用最低权限的 B2 Application Key（仅限备份 bucket + 必要权限 + 文件前缀限制）

## v2 Requirements

推迟到未来版本的需求。当前不在路线图中。

### 性能优化

- **PERF-01**: 增量备份（pg_basebackup + WAL）— 减少备份时间和存储空间
- **PERF-02**: 并行备份（pg_restore -j）— 加快大数据库恢复速度

### 高级功能

- **ADV-01**: PITR 时间点恢复 — 恢复到任意时间点
- **ADV-02**: 跨区域备份复制 — 地理灾难恢复
- **ADV-03**: Web 管理面板 — 可视化管理备份

## Out of Scope

明确排除的功能。记录原因防止以后重新添加。

| 功能 | 排除原因 |
|------|----------|
| 实时复制/流备份 | 需要主从架构，至少双倍基础设施成本。6-12 小时 RPO 已满足需求 |
| PITR 时间点恢复 | 需要基础备份 + 完整 WAL 归档链，复杂度极高。当前已有 WAL 归档但只存本地，未配合云上传，形成了技术债务 |
| 跨区域备份复制 | 增加存储成本（至少翻倍）和管理复杂度。B2 本身已有数据中心冗余 |
| 手动备份触发 Web UI | Jenkins 已提供手动触发能力（Build Now 按钮）和参数化构建。Web UI 需要额外开发和维护 |
| 自定义客户端加密方案 | 自定义加密容易出错，反而降低安全性。rclone crypt 是成熟方案 |
| 压缩格式选择 | pg_dump -Fc 已内置 zlib 压缩，效果足够好。提供多种格式增加测试矩阵 |
| 数据库自动发现 | 自动发现会备份系统数据库，浪费空间。显式数据库列表更安全 |
| 可配置保留策略 | 增加配置复杂度和测试负担。7 天保留策略已明确 |
| Web 管理面板 | 需要额外开发和维护 Web 前端+后端+认证。Jenkins 已提供日志查看 |

## Traceability

哪些阶段覆盖哪些需求。路线图创建时更新。

| Requirement | Phase | Status |
|-------------|-------|--------|
| BACKUP-01 | Phase 1 | Pending |
| BACKUP-02 | Phase 1 | Pending |
| BACKUP-03 | Phase 1 | Pending |
| BACKUP-04 | Phase 1 | Pending |
| BACKUP-05 | Phase 1 | Pending |
| VERIFY-01 | Phase 1 | Pending |
| MONITOR-04 | Phase 1 | Pending |
| UPLOAD-01 | Phase 2 | Pending |
| UPLOAD-02 | Phase 2 | Pending |
| UPLOAD-03 | Phase 2 | Pending |
| UPLOAD-04 | Phase 2 | Pending |
| UPLOAD-05 | Phase 2 | Pending |
| SECURITY-01 | Phase 2 | Pending |
| SECURITY-02 | Phase 2 | Pending |
| RESTORE-01 | Phase 3 | Pending |
| RESTORE-02 | Phase 3 | Pending |
| RESTORE-03 | Phase 3 | Pending |
| RESTORE-04 | Phase 3 | Pending |
| VERIFY-02 | Phase 4 | Pending |
| MONITOR-01 | Phase 5 | Pending |
| MONITOR-02 | Phase 5 | Pending |
| MONITOR-03 | Phase 5 | Pending |
| MONITOR-05 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 23 total
- Mapped to phases: 23
- Unmapped: 0 ✓

---
*Requirements defined: 2026-04-06*
*Last updated: 2026-04-06 after roadmap creation*
