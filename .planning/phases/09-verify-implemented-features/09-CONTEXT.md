# Phase 9: 验证已实现功能 - Context

**Gathered:** 2026-04-06 (assumptions mode)
**Status:** Ready for planning

## Phase Boundary

这是一个 Gap Closure 验证阶段，目标是文档化和验证 Phase 4-5 的已实现功能，确保所有成功标准都已达成。具体包括：为 Phase 4-5 创建 VERIFICATION.md 文档，执行端到端集成测试验证跨阶段集成。

## Implementation Decisions

### 验证文档结构与内容
- **D-01:** Phase 4 和 Phase 5 的 VERIFICATION.md 采用与 Phase 1 和 Phase 8 相同的四部分结构：1) Goal Achievement（Observable Truths 表格）2) Required Artifacts（产物清单）3) Key Link Verification（链接验证）4) Data-Flow Trace（数据流追踪）
- **D-02:** VERIFICATION.md 文档必须包含对成功标准的逐项验证，使用 Observable Truths 表格展示可观察的证据
- **D-03:** 验证文档应该引用已存在的单元测试结果（test_weekly_verify.sh、test_alert.sh、test_metrics.sh），避免重复执行

### Phase 4 验证策略
- **D-04:** Phase 4 验证基于已存在的 test-verify-weekly.sh 和 lib/test-verify.sh，重点验证四个核心功能：1) 下载最新备份（download_latest_backup）2) 创建测试数据库（create_test_database）3) 恢复到测试数据库（restore_to_test_database）4) 四层验证机制（verify_test_restore）
- **D-05:** Phase 4 的 Observable Truths 应该包含 4-5 个可观察的真值，对应 Phase 4 Success Criteria：1) 每周自动从 B2 下载最新备份 2) 恢复到临时数据库并验证完整性 3) 验证后自动清理临时资源 4) 失败时输出明确错误信息和退出码

### Phase 5 验证策略
- **D-06:** Phase 5 验证基于已存在的 lib/alert.sh 和 lib/metrics.sh，重点验证三个核心功能：1) 结构化日志输出（log_structured）2) 邮件告警系统（send_alert + 1 小时去重窗口）3) 耗时追踪系统（record_metric + 移动平均 + 异常检测）
- **D-07:** Phase 5 的 Observable Truths 应该包含 4 个可观察的真值，对应 Phase 5 Success Criteria：1) 结构化日志输出 2) 备份失败时自动发送告警 3) 追踪备份持续时间并检测异常 4) 使用标准退出码

### 端到端集成测试策略
- **D-08:** 端到端集成测试应该按照**备份 → 云上传 → 恢复 → 验证**的完整流程执行，使用真实的 PostgreSQL 容器和 B2 云存储
- **D-09:** 集成测试应该覆盖所有阶段的核心功能：1) 主备份脚本（backup-postgres.sh）2) 云上传功能（lib/cloud.sh）3) 恢复脚本（restore-postgres.sh）4) 验证测试（test-verify-weekly.sh）5) 监控告警（lib/alert.sh + lib/metrics.sh）
- **D-10:** 集成测试应该使用临时数据库进行测试，确保不影响生产环境，测试后应自动清理所有临时资源

### 文档组织方式
- **D-11:** 为 Phase 4 创建独立的 VERIFICATION.md 文件（.planning/phases/04-automated-verification/04-VERIFICATION.md）
- **D-12:** 为 Phase 5 创建独立的 VERIFICATION.md 文件（.planning/phases/05-monitoring-alerting/05-VERIFICATION.md）
- **D-13:** 创建 Phase 9 集成测试报告（.planning/phases/09-verify-implemented-features/09-INTEGRATION-TEST.md），记录端到端测试结果

### Claude's Discretion
以下方面由 Claude 在规划和实现时决定：
- 集成测试的具体执行顺序和检查点
- 验证报告的详细程度和组织结构
- 是否需要额外的集成测试脚本

## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 验证文档格式参考
- `.planning/phases/01-local-backup-core/01-VERIFICATION.md` — Phase 1 验证文档格式（四部分结构）
- `.planning/phases/08-execute-restore-scripts/08-VERIFICATION.md` — Phase 8 验证文档格式（端到端测试方法）

### Phase 4 参考文档
- `.planning/phases/04-automated-verification/04-CONTEXT.md` — Phase 4 上下文
- `.planning/phases/04-automated-verification/04-SUMMARY.md` — Phase 4 执行总结
- `.planning/phases/ROADMAP.md` §Phase 4 — Phase 4 Success Criteria（lines 79-85）

### Phase 5 参考文档
- `.planning/phases/05-monitoring-alerting/05-SUMMARY.md` — Phase 5 执行总结
- `.planning/phases/ROADMAP.md` §Phase 5 — Phase 5 Success Criteria（lines 91-99）

### 已实现的核心代码
- `scripts/backup/test-verify-weekly.sh` — 每周验证测试主脚本（260 行）
- `scripts/backup/lib/test-verify.sh` — 验证测试库（350 行）
- `scripts/backup/lib/alert.sh` — 告警库（150 行）
- `scripts/backup/lib/metrics.sh` — 指标库（160 行）
- `scripts/backup/lib/verify.sh` — 验证库
- `scripts/backup/backup-postgres.sh` — 主备份脚本
- `scripts/backup/restore-postgres.sh` — 恢复脚本

### 单元测试参考
- `scripts/backup/tests/test_weekly_verify.sh` — 19 个测试，全部通过
- `scripts/backup/tests/test_alert.sh` — 9 个测试，全部通过
- `scripts/backup/tests/test_metrics.sh` — 12 个测试，全部通过

### 需求规范
- `.planning/REQUIREMENTS.md` §Verify — 验证测试需求（VERIFY-02）
- `.planning/REQUIREMENTS.md` §Monitor — 监控告警需求（MONITOR-01 到 MONITOR-05）

## Existing Code Insights

### Reusable Assets
- **test-verify-weekly.sh**: 完整的每周验证测试脚本，已实现下载、恢复、验证、清理的完整流程
- **lib/test-verify.sh**: 验证测试核心库，包含测试数据库管理、下载重试、多层验证等功能
- **lib/alert.sh**: 告警库，实现邮件发送和 1 小时去重窗口
- **lib/metrics.sh**: 指标库，实现耗时追踪、移动平均和异常检测
- **lib/verify.sh**: 验证库，实现 SHA-256 校验和和 pg_restore --list 验证

### Established Patterns
- **验证文档格式**: Phase 1 和 Phase 8 都使用四部分结构（Goal Achievement、Required Artifacts、Key Link Verification、Data-Flow Trace）
- **Observable Truths**: 将 Success Criteria 转化为可观察的真值表格，包含描述、如何验证和状态的列
- **单元测试复用**: 引用已通过的单元测试结果，避免重复执行
- **端到端测试**: 使用真实环境（PostgreSQL 容器 + B2 云存储）和临时数据库，确保测试真实性

### Integration Points
- **PostgreSQL 容器**: noda-infra-postgres-1（PostgreSQL 17.9）
- **B2 云存储**: Backblaze B2 bucket（backups/postgres/）
- **测试数据库**: 使用 test_restore_* 前缀的临时数据库
- **备份目录**: /var/lib/postgresql/backup（容器内）
- **配置文件**: .env.backup（环境变量）

### 已验证的工作状态
- ✅ Phase 4 所有 19 个单元测试通过（test_weekly_verify.sh）
- ✅ Phase 5 所有 21 个单元测试通过（test_alert.sh + test_metrics.sh）
- ✅ Phase 1 端到端测试通过（TEST_REPORT.md）
- ✅ Phase 8 恢复功能验证通过（08-VERIFICATION.md）

## Specific Ideas

### 验证文档内容
- "Phase 4 的 VERIFICATION.md 应该重点验证四个核心功能：下载、恢复、验证、清理"
- "Phase 5 的 VERIFICATION.md 应该重点验证三个核心功能：日志、告警、指标"
- "验证文档应该引用已通过的单元测试结果，避免重复执行"

### 端到端集成测试流程
- "端到端测试应该模拟真实的运维场景：备份 → 上传 → 恢复 → 验证"
- "测试应该使用真实的小型数据库，而不是 mock 数据"
- "测试后应该清理所有临时资源，不留垃圾"

### 验证方法
- "验证脚本应该像 verify-phase6.sh 一样，输出清晰的检查项和通过/失败状态"
- "每个成功标准都应该有独立的验证函数，便于调试和维护"
- "验证报告应该包含具体的命令和输出，便于审查"

## Deferred Ideas

无 — 这是一个 Gap Closure 验证阶段，所有工作都聚焦在文档化和验证已实现功能。

---

*Phase: 09-verify-implemented-features*
*Context gathered: 2026-04-06*
