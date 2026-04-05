# Roadmap: Noda 数据库备份系统

## Overview

为 Noda 基础设施的 PostgreSQL 数据库建立完整的自动化云备份系统。从本地备份核心开始，逐步集成 Backblaze B2 云存储、一键恢复、自动化验证测试和监控告警，最终实现数据库永不丢失的目标。5 个阶段渐进式构建，每个阶段都有可验证的交付物。

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: 本地备份核心** - 建立可靠的多数据库本地备份流程，包含健康检查、压缩格式和即时验证
- [ ] **Phase 2: 云存储集成** - 备份自动上传到 Backblaze B2，包含重试、校验、清理和凭证安全
- [ ] **Phase 3: 恢复脚本** - 提供一键恢复脚本，支持列出备份、指定数据库恢复和恢复到测试库
- [ ] **Phase 4: 自动化验证测试** - 每周自动执行恢复测试，验证备份可用性
- [ ] **Phase 5: 监控与告警** - 结构化日志、Webhook 告警、耗时追踪和标准退出码

## Phase Details

### Phase 1: 本地备份核心
**Goal**: 运维人员可以手动执行备份脚本，可靠地备份所有数据库到本地文件系统，并立即验证备份完整性
**Depends on**: Nothing (first phase)
**Requirements**: BACKUP-01, BACKUP-02, BACKUP-03, BACKUP-04, BACKUP-05, VERIFY-01, MONITOR-04
**Success Criteria** (what must be TRUE):
  1. 执行备份脚本后，keycloak_db 和 findclass_db 都生成了 .dump 格式的备份文件，文件名包含时间戳和数据库名
  2. 全局对象（角色和表空间定义）也被单独备份
  3. 备份前自动检查 PostgreSQL 连接状态和磁盘空间，不满足条件时脚本提前退出并给出明确错误信息
  4. 每个备份文件生成后，pg_restore --list 可以成功列出其内容（验证备份可读性）
**Plans**: TBD

Plans:
- [ ] 01-01: TBD
- [ ] 01-02: TBD

### Phase 2: 云存储集成
**Goal**: 备份文件自动上传到 Backblaze B2 云存储，上传后验证校验和，旧备份自动清理，凭证通过环境变量安全管理
**Depends on**: Phase 1
**Requirements**: UPLOAD-01, UPLOAD-02, UPLOAD-03, UPLOAD-04, UPLOAD-05, SECURITY-01, SECURITY-02
**Success Criteria** (what must be TRUE):
  1. 备份完成后自动上传到 B2 云存储，上传失败时自动重试（最多 3 次，指数退避）
  2. 上传后通过 rclone --checksum 验证文件完整性，校验和不匹配时标记为失败
  3. 超过 7 天的旧备份（本地和云端）被自动清理，未完成的上传文件也被自动清除
  4. 所有凭证（B2 Key、数据库密码）通过环境变量传入，脚本中无硬编码凭证
  5. B2 Application Key 仅拥有备份 bucket 的最低必要权限（writeFiles + deleteFiles + listFiles + fileNamePrefix 限制）
**Plans**: TBD

Plans:
- [ ] 02-01: TBD
- [ ] 02-02: TBD

### Phase 3: 恢复脚本
**Goal**: 运维人员可以通过恢复脚本从云存储下载并恢复任意数据库，支持恢复到不同数据库名以进行安全测试
**Depends on**: Phase 2
**Requirements**: RESTORE-01, RESTORE-02, RESTORE-03, RESTORE-04
**Success Criteria** (what must be TRUE):
  1. 执行恢复脚本可以列出 B2 上所有可用的备份文件，按时间排序
  2. 可以指定数据库名和时间戳，从云存储下载对应备份并恢复到生产数据库
  3. 恢复指定数据库时，其他运行中的数据库不受影响
  4. 可以恢复到不同的数据库名（如 _test 后缀），用于安全验证而不影响生产环境
**Plans**: TBD

Plans:
- [ ] 03-01: TBD

### Phase 4: 自动化验证测试
**Goal**: 系统每周自动执行恢复测试，在临时数据库中验证备份文件可完整恢复，失败时发出告警
**Depends on**: Phase 3
**Requirements**: VERIFY-02
**Success Criteria** (what must be TRUE):
  1. 每周自动从 B2 下载最新备份，恢复到临时数据库，验证数据完整性后清理临时资源
  2. 自动恢复测试失败时，输出明确的错误信息和失败阶段（下载/恢复/验证）
**Plans**: TBD

Plans:
- [ ] 04-01: TBD

### Phase 5: 监控与告警
**Goal**: 备份系统具备完整的可观测性，运维人员可以通过结构化日志了解备份状态，通过 Webhook 及时收到失败告警
**Depends on**: Phase 4
**Requirements**: MONITOR-01, MONITOR-02, MONITOR-03, MONITOR-05
**Success Criteria** (what must be TRUE):
  1. 备份脚本输出结构化日志，包含时间戳、数据库名、文件大小、耗时、状态和错误详情
  2. 备份失败时自动发送 Webhook 告警通知，包含失败原因和上下文信息
  3. 追踪备份持续时间，与历史平均耗时对比，偏差超过 50% 时输出警告
  4. 脚本使用标准退出码（0=成功、1=连接失败、2=备份失败、3=上传失败、4=清理失败、5=验证失败），可通过 Jenkins 准确判断失败阶段
**Plans**: TBD

Plans:
- [ ] 05-01: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. 本地备份核心 | 0/? | Not started | - |
| 2. 云存储集成 | 0/? | Not started | - |
| 3. 恢复脚本 | 0/? | Not started | - |
| 4. 自动化验证测试 | 0/? | Not started | - |
| 5. 监控与告警 | 0/? | Not started | - |
