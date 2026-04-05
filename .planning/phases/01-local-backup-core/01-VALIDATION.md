---
phase: 1
slug: local-backup-core
status: ready
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-06
updated: 2026-04-06
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash 脚本测试（Bash 手动测试） |
| **Config file** | 无（Bash 脚本不需要） |
| **Quick run command** | `bash scripts/backup/backup-postgres.sh --dry-run` |
| **Full suite command** | `bash scripts/backup/tests/test_backup.sh` |
| **Estimated runtime** | ~30-60 秒 |

---

## Sampling Rate

- **After every task commit:** 运行 `bash scripts/backup/backup-postgres.sh --dry-run`
- **After every plan wave:** 运行 `bash scripts/backup/tests/test_backup.sh`
- **Before `/gsd-verify-work`:** 完整测试套件必须通过
- **Max feedback latency:** 60 秒

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 01-00-01 | 00 | 0 | — | — | 创建环境配置模板 | 单元测试 | `test -f scripts/backup/templates/.env.backup` | ✅ 已创建 | ⬜ pending |
| 01-00-02 | 00 | 0 | — | — | 创建测试数据库脚本 | 单元测试 | `bash -n scripts/backup/tests/create_test_db.sh` | ✅ 已创建 | ⬜ pending |
| 01-00-03 | 00 | 0 | BACKUP-01~05, VERIFY-01, MONITOR-04 | — | 创建备份功能测试脚本 | 集成测试 | `bash -n scripts/backup/tests/test_backup.sh` | ✅ 已创建 | ⬜ pending |
| 01-00-04 | 00 | 0 | D-43 | — | 创建恢复功能测试脚本 | 集成测试 | `bash -n scripts/backup/tests/test_restore.sh` | ✅ 已创建 | ⬜ pending |
| 01-01-01 | 01 | 1 | BACKUP-04, MONITOR-04 | T-1-02 | 配置管理函数实现 | 单元测试 | `bash -n scripts/backup/lib/config.sh` | ❌ 需创建 | ⬜ pending |
| 01-01-02 | 01 | 1 | BACKUP-04, MONITOR-04 | T-1-04 | 健康检查函数实现 | 单元测试 | `bash -n scripts/backup/lib/health.sh` | ❌ 需创建 | ⬜ pending |
| 01-01-03 | 01 | 1 | BACKUP-04, MONITOR-04 | T-1-03 | 环境变量模板创建 | 单元测试 | `test -f scripts/backup/templates/.env.backup` | ✅ 已创建（00） | ⬜ pending |
| 01-02-01 | 02 | 2 | BACKUP-01, BACKUP-02, BACKUP-03 | T-2-01, T-2-02 | 日志函数实现 | 单元测试 | `bash -n scripts/backup/lib/log.sh` | ❌ 需创建 | ⬜ pending |
| 01-02-02 | 02 | 2 | BACKUP-01, BACKUP-02, BACKUP-03 | — | 工具函数实现 | 单元测试 | `bash -n scripts/backup/lib/util.sh` | ❌ 需创建 | ⬜ pending |
| 01-02-03 | 02 | 2 | BACKUP-01, BACKUP-02, BACKUP-03 | T-2-01, T-2-03 | 数据库操作函数实现 | 集成测试 | `bash -n scripts/backup/lib/db.sh` | ❌ 需创建 | ⬜ pending |
| 01-03-01 | 03 | 3 | BACKUP-05, VERIFY-01 | T-3-01, T-3-03 | 验证函数实现 | 集成测试 | `bash -n scripts/backup/lib/verify.sh` | ❌ 需创建 | ⬜ pending |
| 01-03-02 | 03 | 3 | BACKUP-05, VERIFY-01, D-43 | T-3-02 | 主脚本实现（含 --test 模式） | 集成测试 | `bash scripts/backup/tests/test_restore.sh` | ❌ 需创建 | ⬜ pending |
| 01-03-03 | 03 | 3 | D-45 | — | 恢复文档创建 | 手动验证 | `test -f scripts/backup/templates/RESTORE.md` | ❌ 需创建 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] `scripts/backup/tests/test_backup.sh` — 覆盖所有阶段需求（BACKUP-01 到 BACKUP-05、VERIFY-01、MONITOR-04）
- [x] `scripts/backup/tests/test_restore.sh` — 恢复功能测试（D-43）
- [x] `scripts/backup/tests/create_test_db.sh` — 测试数据库创建脚本（用于 D-43 测试模式）
- [x] `scripts/backup/templates/.env.backup` — 环境变量模板文件

*Wave 0 完成状态：所有测试基础设施文件已在计划 00 中定义*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 备份文件权限检查 | BACKUP-02, D-13 | 需要手动验证文件权限 | 运行备份后，检查 `ls -l` 输出确认权限为 600 |
| 恢复文档可用性 | D-45 | 需要人工验证文档清晰度 | 阅读 RESTORE.md，按照步骤尝试恢复操作 |
| 错误消息清晰度 | D-46 | 需要人工评估错误消息质量 | 触发各种错误场景（磁盘不足、连接失败等），评估消息质量 |

*如果无：所有阶段行为都有自动化验证*

---

## Threat Model References

从 RESEARCH.md 的安全域部分：

| 威胁模式 | STRIDE | 缓解措施 | 相关任务 |
|----------|--------|----------|----------|
| 备份文件泄露 | 信息泄露 | 文件权限 600、加密存储（Phase 2）、安全删除 | 01-02-03（文件权限） |
| 硬编码凭证 | 信息泄露 | .pgpass 文件、环境变量、避免硬编码 | 01-01-01（脚本架构） |
| 路径遍历 | 基本数据伪造 | 验证数据库名、使用绝对路径、避免用户输入直接拼接 | 01-02-03（数据库发现） |
| 备份篡改 | 基本数据伪造 | SHA-256 校验和、只读存储、签名（Phase 2） | 01-03-01（验证） |

---

## Validation Sign-Off

- [x] 所有任务都有 `<automated>` 验证或 Wave 0 依赖
- [x] 采样连续性：没有连续 3 个任务没有自动化验证
- [x] Wave 0 覆盖所有缺失的引用
- [x] 无监视模式标志
- [x] 反馈延迟 < 60 秒
- [x] `nyquist_compliant: true` 设置在 frontmatter

**Approval:** pending

---

## 修订记录

**2026-04-06 - 修订 1**
- 添加 Wave 0 计划（01-00-PLAN.md）
- 创建测试基础设施文件（test_backup.sh、test_restore.sh、create_test_db.sh）
- 更新 `nyquist_compliant: true` 和 `wave_0_complete: true`
- 将环境变量模板创建移至 Wave 0（任务 01-00-01）
- 更新任务验证映射表，包含 Wave 0 任务
- 为 D-43 测试模式提供完整实现（test_restore.sh）
