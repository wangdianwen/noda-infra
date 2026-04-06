# Phase 8: 执行恢复脚本 - Context

**Gathered:** 2026-04-06
**Status:** Ready for planning

## Phase Boundary

验证、文档化和端到端测试已实现的恢复脚本功能，确保符合所有成功标准。恢复功能已在阶段 3 完整实现并通过 UAT 测试（5/5 通过），本阶段专注于正式验证、文档补充和集成测试。

## Implementation Decisions

### 验证策略
- **D-01:** 创建自动化验证脚本 `verify-restore.sh`，对照阶段 8 的 4 个成功标准逐项测试并生成报告
- **D-02:** 验证脚本应测试每个成功标准，记录通过/失败状态和具体证据
- **D-03:** 复用阶段 3 的 UAT 测试结果作为基线，补充新的验证测试

### 文档策略
- **D-04:** 创建 `08-VERIFICATION.md` 文档，包含 4 个主要部分：
  - 成功标准验证（每个标准的验证方法和结果）
  - 测试用例覆盖（所有测试用例、预期和实际结果）
  - 边界情况和错误处理（故障场景、处理策略）
  - 使用指南（命令行参数、示例、最佳实践）
- **D-05:** 文档应包含具体命令示例和预期输出，便于运维人员使用

### 集成测试策略
- **D-06:** 执行完整的端到端集成测试：备份 → 云上传 → 下载 → 恢复 → 验证
- **D-07:** 使用临时数据库进行测试，确保不影响生产环境
- **D-08:** 测试应验证整个数据链路的完整性，包括 B2 云存储的下载功能

### 边界情况处理
- **D-09:** 网络故障处理：测试网络中断、B2 不可用、认证失败等场景的恢复能力
- **D-10:** 恢复失败场景：处理损坏的备份文件、磁盘空间不足、数据库连接失败
- **D-11:** 数据库冲突：处理恢复到已存在的数据库、权限不足、SQL 错误等情况
- **D-12:** 性能和并发：测试大文件恢复、并发恢复请求、部分下载恢复等场景

### 测试环境
- **D-13:** 所有测试应在独立的 Docker 容器或临时数据库中执行
- **D-14:** 测试数据应使用小型测试数据库，避免长时间运行
- **D-15:** 测试后应自动清理临时资源（临时数据库、下载的备份文件）

### Claude's Discretion
以下方面由 Claude 在规划和实现时决定：
- 验证脚本的具体输出格式和报告结构
- 集成测试的具体执行顺序和检查点
- 边界情况测试的优先级和覆盖范围
- 文档的具体组织结构和详细程度

## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 需求规范
- `.planning/REQUIREMENTS.md` — 完整的需求列表
- `.planning/REQUIREMENTS.md` §Restore — 恢复功能需求（RESTORE-01 到 RESTORE-04）
- `.planning/REQUIREMENTS.md` §Verify — 验证测试需求（VERIFY-02）

### 路线图
- `.planning/ROADMAP.md` §Phase 8 — 阶段 8 目标、成功标准和计划
- `.planning/ROADMAP.md` §Phase 3 — 阶段 3 的原始恢复脚本计划

### 已有实现参考
- `scripts/backup/restore-postgres.sh` — 现有恢复脚本（完整实现）
- `scripts/backup/lib/restore.sh` — 恢复核心库函数
- `.planning/phases/03-restore-scripts/03-UAT.md` — 阶段 3 的 UAT 测试结果（5/5 通过）

### 测试脚本参考
- `scripts/backup/tests/test_restore.sh` — 现有恢复测试脚本
- `scripts/backup/tests/test_restore_quick.sh` — 快速恢复测试
- `scripts/backup/lib/verify.sh` — 验证库函数

## Existing Code Insights

### Reusable Assets
- **scripts/backup/restore-postgres.sh**: 完整的恢复脚本，已实现所有阶段 8 成功标准
- **scripts/backup/lib/restore.sh**: 核心恢复函数（list_backups_b2, download_backup, restore_database, verify_backup_integrity）
- **scripts/backup/lib/cloud.sh**: B2 云存储集成函数
- **scripts/backup/lib/verify.sh**: 备份验证函数（SHA256 校验和、pg_restore --list）
- **scripts/backup/tests/test_restore.sh**: 现有测试脚本可作为参考

### Established Patterns
- **环境变量配置**: 使用 .env.backup 文件管理配置
- **日志输出**: 使用统一的日志格式（log_info, log_warn, log_error, log_success）
- **错误处理**: 使用标准退出码（EXIT_RESTORE_FAILED, EXIT_INVALID_ARGS 等）
- **Docker 执行**: 使用 docker exec 在容器内执行 PostgreSQL 命令
- **临时文件管理**: 使用 mktemp 创建临时目录，测试后自动清理

### Integration Points
- **B2 云存储**: 通过 rclone 访问 Backblaze B2 bucket
- **PostgreSQL 容器**: noda-infra-postgres-1（PostgreSQL 17.9）
- **配置文件**: .env.backup（环境变量）
- **备份目录**: /var/lib/postgresql/backup（容器内）

### 创造性选项
- **验证脚本模式**: 可以参考 verify-phase6.sh 的只读检查模式
- **测试数据库**: 可以使用 test_restore_db 或 create_test_db.sh 创建的测试数据库
- **报告格式**: 可以生成 Markdown 或 JSON 格式的验证报告
- **并行测试**: 可以并行执行独立的测试用例以提高效率

## Specific Ideas

### 验证脚本行为
- "验证脚本应该像 verify-phase6.sh 一样，输出清晰的检查项和通过/失败状态"
- "每个成功标准都应该有独立的测试函数，便于调试和维护"
- "验证报告应该包含具体的命令和输出，便于审查"

### 集成测试流程
- "端到端测试应该模拟真实的运维场景：备份 → 上传 → 恢复 → 验证"
- "测试应该使用真实的小型数据库，而不是 mock 数据"
- "测试后应该清理所有临时资源，不留垃圾"

### 边界情况处理
- "网络故障应该有明确的错误信息和重试建议"
- "恢复失败应该提供详细的诊断信息（哪个步骤失败、为什么）"
- "数据库冲突应该提供解决建议（如：删除现有数据库、使用不同的数据库名）"

## Deferred Ideas

None — discussion stayed within phase scope.

---

*Phase: 08-execute-restore-scripts*
*Context gathered: 2026-04-06*
