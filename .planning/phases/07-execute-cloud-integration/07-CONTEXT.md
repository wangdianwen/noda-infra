# Phase 7: 执行云存储集成 - Context

**Gathered:** 2026-04-06
**Status:** Ready for planning

## Phase Boundary

这是一个 Gap Closure 验证阶段，目标是验证 Phase 2 已实现的云存储集成功能是否完整、正确和安全。具体包括：验证 cloud.sh 的上传、重试、校验和功能，运行测试套件，确认安全配置符合要求，并评估性能表现。

**重要说明**：根据代码库分析，Phase 2 的云操作库（lib/cloud.sh）和测试文件（test_rclone.sh、test_upload.sh）已经存在。Phase 7 不重新实现这些功能，而是验证现有实现的正确性，并修复任何发现的问题。

## Implementation Decisions

### 验证范围
- **D-01:** Phase 7 是验证阶段，不涉及新的代码实现（除非发现 bug 需要修复）
- **D-02:** 验证覆盖四个方面：功能、测试、安全、性能
- **D-03:** 优先验证功能正确性，然后是测试通过，最后是安全和性能

### 功能验证标准
- **D-04:** cloud.sh 的 upload_to_b2 函数能成功上传文件到 B2
- **D-05:** 上传失败时自动重试（最多 3 次，指数退避）
- **D-06:** 上传后通过 rclone --checksum 验证文件完整性
- **D-07:** 7 天前的旧备份能被自动清理（本地和云端）

### 测试验证标准
- **D-08:** test_rclone.sh 能成功验证 rclone 配置
- **D-09:** test_upload.sh 能成功上传测试文件到 B2
- **D-10:** 所有测试退出码为 0，无错误输出

### 安全验证标准
- **D-11:** 所有凭证（B2 Key、数据库密码）通过环境变量传入
- **D-12:** 脚本中无硬编码凭证（grep 验证）
- **D-13:** 临时配置文件权限为 600
- **D-14:** B2 Application Key 仅拥有备份 bucket 的最低必要权限

### 性能验证标准
- **D-15:** 上传速度符合预期（> 1MB/s 为正常）
- **D-16:** 重试机制工作正常（模拟失败场景）
- **D-17:** 大文件上传不超时（30 分钟超时设置）

### 测试环境配置
- **D-18:** 使用测试数据库（test_backup_db）进行验证
- **D-19:** 不影响生产数据（keycloak_db、noda_prod）
- **D-20:** 测试数据使用小型数据库（减少上传时间）

### B2 配置
- **D-21:** 使用现有的 B2 账户和 bucket
- **D-22:** 环境变量配置：B2_ACCOUNT_ID、B2_APPLICATION_KEY、B2_BUCKET_NAME
- **D-23:** B2 bucket 路径：backups/postgres/YYYY/MM/DD/

### Claude's Discretion
- 验证测试的具体实现方式（单元测试 vs 集成测试）
- 性能基准的具体阈值
- 发现 bug 时的修复优先级

## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 2 上下文
- `.planning/phases/02-cloud-integration/02-CONTEXT.md` — Phase 2 的完整上下文和决策
- `.planning/phases/02-cloud-integration/02-RESEARCH.md` — 技术研究（Backblaze B2 + rclone）
- `.planning/phases/02-cloud-integration/02-PLAN.md` — Phase 2 执行计划

### 现有代码
- `scripts/backup/lib/cloud.sh` — 云操作库（已实现）
- `scripts/backup/lib/config.sh` — 配置管理（包含 B2 配置项）
- `scripts/backup/tests/test_rclone.sh` — rclone 配置测试
- `scripts/backup/tests/test_upload.sh` — 上传功能测试

### Phase 1 上下文（依赖）
- `.planning/phases/01-local-backup-core/01-CONTEXT.md` — 本地备份上下文
- `.planning/phases/06-fix-variable-conflicts/06-CONTEXT.md` — 变量冲突修复上下文

## Existing Code Insights

### Reusable Assets
- **lib/cloud.sh**: 云操作库（已实现，需要验证）
  - `upload_to_b2()` - 上传备份文件到 B2
  - `cleanup_old_backups_b2()` - 清理云端旧备份
  - `setup_rclone_config()` - 创建临时 rclone 配置
  - `cleanup_rclone_config()` - 清理配置文件

- **lib/config.sh**: 配置管理（已预留 B2 配置）
  - `get_b2_account_id()` - 获取 B2 Account ID
  - `get_b2_application_key()` - 获取 B2 Application Key
  - `get_b2_bucket_name()` - 获取 B2 bucket 名称

- **tests/test_rclone.sh**: rclone 配置测试（已实现）
- **tests/test_upload.sh**: 上传功能测试（已实现）

### Established Patterns
- **环境变量配置**: 所有凭证通过环境变量传入，不硬编码
- **临时文件管理**: 配置文件使用 mktemp 创建，权限 600，用完删除
- **日志输出**: 使用 log.sh 统一输出日志（ℹ️、⚠️、❌、✅ 符号）
- **错误处理**: 使用 constants.sh 定义的退出码（EXIT_CLOUD_UPLOAD_FAILED 等）

### Integration Points
- **主脚本集成**: backup-postgres.sh 需要调用 cloud.sh 的上传函数
- **配置加载**: 从 .env.backup 或环境变量加载 B2 配置
- **测试数据库**: 使用 test_backup_db 进行验证，不影响生产

## Specific Ideas

### 验证方法
- "运行 test_rclone.sh 验证 rclone 配置正确性"
- "运行 test_upload.sh 上传小型测试文件"
- "检查 cloud.sh 代码逻辑，确认重试和校验和机制"
- "使用 grep 搜索硬编码凭证，确保无安全问题"

### 性能基准
- "上传速度应该 > 1MB/s（正常网络条件）"
- "大文件（> 100MB）上传应该在 30 分钟内完成"
- "重试不应该立即执行，应该有指数退避（1s, 2s, 4s）"

### 测试数据
- "使用 test_backup_db 作为测试数据库"
- "创建小型备份（< 10MB）以加快测试速度"
- "测试完成后清理云端测试文件"

## Deferred Ideas

无 — 这是一个验证阶段，所有工作聚焦在验证现有实现。

---

*Phase: 07-execute-cloud-integration*
*Context gathered: 2026-04-06*
