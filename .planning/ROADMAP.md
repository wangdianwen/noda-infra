# Roadmap: Noda 数据库备份系统

## Overview

为 Noda 基础设施的 PostgreSQL 数据库建立完整的自动化云备份系统。从本地备份核心开始，逐步集成 Backblaze B2 云存储、一键恢复、自动化验证测试和监控告警，最终实现数据库永不丢失的目标。5 个阶段渐进式构建，每个阶段都有可验证的交付物。

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: 本地备份核心** - 建立可靠的多数据库本地备份流程，包含健康检查、压缩格式和即时验证 ✅
- [x] **Phase 2: 云存储集成** - 备份自动上传到 Backblaze B2，包含重试、校验、清理和凭证安全 ⚠️ (规划完成，未执行)
- [x] **Phase 3: 恢复脚本** - 提供一键恢复脚本，支持列出备份、指定数据库恢复和恢复到测试库 ⚠️ (规划完成，未执行)
- [x] **Phase 4: 自动化验证测试** - 每周自动执行恢复测试，验证备份可用性 ⚠️ (已实现，未验证)
- [x] **Phase 5: 监控与告警** - 结构化日志、Webhook 告警、耗时追踪和标准退出码 ⚠️ (已实现，未验证)
- [ ] **Phase 6: 修复变量冲突** - 统一退出码管理，修复 Phase 1 主脚本运行问题 🔧
- [ ] **Phase 7: 执行云存储集成** - 实现 B2 上传、重试、校验和凭证管理 📋
- [ ] **Phase 8: 执行恢复脚本** - 实现一键恢复、列出备份和安全测试功能 📋
- [ ] **Phase 9: 验证已实现功能** - 添加验证文档，执行端到端集成测试 ✅

## Phase Details

### Phase 1: 本地备份核心
**Goal**: 运维人员可以手动执行备份脚本，可靠地备份所有数据库到本地文件系统，并立即验证备份完整性
**Depends on**: Nothing (first phase)
**Requirements**: BACKUP-01, BACKUP-02, BACKUP-03, BACKUP-04, BACKUP-05, VERIFY-01, MONITOR-04
**Success Criteria** (what must be TRUE):
  1. 执行备份脚本后，keycloak_db 和 findclass_db 都生成了 .dump 格式的备份文件，文件名包含时间戳和数据库名
  2. 每个备份文件可以通过 `pg_restore --list` 验证可读性，备份目录包含 SHA-256 校验和文件
  3. 备份文件存储在 Docker volume 映射的宿主机目录，权限为 600（仅所有者可读写）
  4. 备份前自动检查磁盘空间（数据库大小 × 2），空间不足时拒绝执行并返回明确错误
  5. 提供 `--test` 模式，可以创建测试数据库并验证完整备份和恢复流程（D-43）
**Plans**: 4 plans (Wave 0 + 3 execution waves)

Plans:
- [x] 01-00: 创建测试基础设施（Wave 0，Nyquist 规则合规）
- [x] 01-01: 实现健康检查和配置管理（Wave 1）
- [x] 01-02: 实现数据库备份核心功能（发现、备份、日志、工具）（Wave 2）
- [x] 01-03: 实现备份验证和主脚本集成（含完整 D-43 测试模式）（Wave 3）

**Status**: ✅ Complete (所有测试通过，19 commits)

### Phase 2: 云存储集成
**Goal**: 备份文件自动上传到 Backblaze B2 云存储，上传后验证校验和，旧备份自动清理，凭证通过环境变量安全管理
**Depends on**: Phase 1 ✅
**Requirements**: UPLOAD-01, UPLOAD-02, UPLOAD-03, UPLOAD-04, UPLOAD-05, SECURITY-01, SECURITY-02
**Success Criteria** (what must be TRUE):
  1. 备份完成后自动上传到 B2 云存储，上传失败时自动重试（最多 3 次，指数退避）
  2. 上传后通过 rclone --checksum 验证文件完整性，校验和不匹配时标记为失败
  3. 超过 7 天的旧备份（本地和云端）被自动清理，未完成的上传文件也被自动清除
  4. 所有凭证（B2 Key、数据库密码）通过环境变量传入，脚本中无硬编码凭证
  5. B2 Application Key 仅拥有备份 bucket 的最低必要权限（writeFiles + deleteFiles + listFiles + fileNamePrefix 限制）
**Plans**: 4 plans (Wave 0 + 3 execution waves)

Plans:
- [ ] 02-00: 基础设施准备（Wave 0，rclone 安装 + B2 配置）
- [ ] 02-01: 实现云操作库（Wave 1，lib/cloud.sh）
- [ ] 02-02: 集成到主脚本（Wave 2，云上传流程）
- [ ] 02-03: 测试和优化（Wave 3，端到端测试）

**Status**: 📋 Planning Complete (ready for execution)

### Phase 3: 恢复脚本
**Goal**: 运维人员可以通过恢复脚本从云存储下载并恢复任意数据库，支持恢复到不同数据库名以进行安全测试
**Depends on**: Phase 2
**Requirements**: RESTORE-01, RESTORE-02, RESTORE-03, RESTORE-04
**Success Criteria** (what must be TRUE):
  1. 执行恢复脚本可以列出 B2 上所有可用的备份文件，按时间排序
  2. 可以指定备份文件恢复到目标数据库，支持恢复到不同数据库名（用于测试）
  3. 恢复前自动验证备份文件完整性（校验和），恢复后验证表数量和关键记录
  4. 恢复失败时提供明确的错误信息和解决建议
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

### Phase 6: 修复变量冲突
**Goal**: 统一退出码管理，修复 Phase 1 主脚本运行问题
**Depends on**: Phase 1
**Requirements**: (技术债务修复)
**Gap Closure**: 修复 EXIT_SUCCESS 变量冲突，使主脚本可以运行
**Success Criteria** (what must be TRUE):
  1. 创建 `lib/constants.sh` 统一定义所有退出码常量
  2. 移除 health.sh、db.sh、verify.sh 中的 EXIT_* 重复定义
  3. 主脚本可以正常运行并执行备份流程
  4. 所有库文件通过 source 加载共享常量
**Plans**: 1 plan

Plans:
- [ ] 06-01: 创建统一常量文件并修复变量冲突

**Status**: 📋 Gap Closure Phase

### Phase 7: 执行云存储集成
**Goal**: 实现 B2 云存储上传、重试、校验和凭证管理
**Depends on**: Phase 6 (修复后的 Phase 1)
**Requirements**: UPLOAD-01, UPLOAD-02, UPLOAD-03, UPLOAD-04, UPLOAD-05, SECURITY-01, SECURITY-02
**Gap Closure**: 执行原始 Phase 2 计划（仅规划，未执行）
**Success Criteria** (what must be TRUE):
  1. 备份完成后自动上传到 B2 云存储，上传失败时自动重试（最多 3 次，指数退避）
  2. 上传后通过 rclone --checksum 验证文件完整性，校验和不匹配时标记为失败
  3. 超过 7 天的旧备份（本地和云端）被自动清理，未完成的上传文件也被自动清除
  4. 所有凭证（B2 Key、数据库密码）通过环境变量传入，脚本中无硬编码凭证
  5. B2 Application Key 仅拥有备份 bucket 的最低必要权限
**Plans**: 4 plans (Wave 0 + 3 execution waves)

Plans:
- [ ] 07-00: 基础设施准备（Wave 0，rclone 安装 + B2 配置）
- [ ] 07-01: 实现云操作库（Wave 1，lib/cloud.sh）
- [ ] 07-02: 集成到主脚本（Wave 2，云上传流程）
- [ ] 07-03: 测试和优化（Wave 3，端到端测试）

**Status**: 📋 Gap Closure Phase

### Phase 8: 执行恢复脚本
**Goal**: 实现一键恢复脚本，支持列出备份、指定数据库恢复和安全测试
**Depends on**: Phase 7
**Requirements**: RESTORE-01, RESTORE-02, RESTORE-03, RESTORE-04
**Gap Closure**: 执行原始 Phase 3 计划（仅规划，未执行）
**Success Criteria** (what must be TRUE):
  1. 执行恢复脚本可以列出 B2 上所有可用的备份文件，按时间排序
  2. 可以指定备份文件恢复到目标数据库，支持恢复到不同数据库名（用于测试）
  3. 恢复前自动验证备份文件完整性（校验和），恢复后验证表数量和关键记录
  4. 恢复失败时提供明确的错误信息和解决建议
**Plans**: 2 plans

Plans:
- [ ] 08-01: 实现恢复核心功能（列出、下载、恢复）
- [ ] 08-02: 添加验证和安全测试功能

**Status**: 📋 Gap Closure Phase

### Phase 9: 验证已实现功能
**Goal**: 添加验证文档，执行端到端集成测试
**Depends on**: Phase 8
**Requirements**: VERIFY-02, MONITOR-01, MONITOR-02, MONITOR-03, MONITOR-05
**Gap Closure**: 为 Phase 4-5 创建 VERIFICATION.md，验证跨阶段集成
**Success Criteria** (what must be TRUE):
  1. Phase 4 和 5 拥有 VERIFICATION.md 文件
  2. 端到端流程测试通过（备份 → 云上传 → 恢复 → 验证）
  3. 自动化验证测试功能已验证
  4. 监控告警功能已验证
**Plans**: 2 plans

Plans:
- [ ] 09-01: 为 Phase 4-5 创建 VERIFICATION.md
- [ ] 09-02: 执行端到端集成测试

**Status**: 📋 Gap Closure Phase

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9

**Milestone Status:**
⚠️ **Milestone v1.0 - Gap Closure Phases Added** - Audit found gaps, creating fix phases (2026-04-06)

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. 本地备份核心 | 4/4 | ⚠️ Complete (有验证问题) | 2026-04-06 |
| 2. 云存储集成 | 0/4 | ❌ Not Executed | - |
| 3. 恢复脚本 | 0/2 | ❌ Not Executed | - |
| 4. 自动化验证测试 | 1/1 | ⚠️ Complete (缺少验证) | 2026-04-06 |
| 5. 监控与告警 | 1/1 | ⚠️ Complete (缺少验证) | 2026-04-06 |
| 6. 修复变量冲突 | 0/1 | 📋 Gap Closure Phase | - |
| 7. 执行云存储集成 | 0/4 | 📋 Gap Closure Phase | - |
| 8. 执行恢复脚本 | 0/2 | 📋 Gap Closure Phase | - |
| 9. 验证已实现功能 | 0/2 | 📋 Gap Closure Phase | - |
| **Original Total** | **8/8** | **⚠️ Gaps Found** | **2026-04-06** |
| **With Gap Closure** | **8/17** | **🚧 In Progress** | **-** |
