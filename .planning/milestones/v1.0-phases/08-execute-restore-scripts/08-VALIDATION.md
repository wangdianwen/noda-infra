---
phase: 08
slug: execute-restore-scripts
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-06
---

# Phase 08 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Shell Testing (Bash 5.x) |
| **Config file** | .planning/phases/08-execute-restore-scripts/08-RESEARCH.md |
| **Quick run command** | `./scripts/backup/tests/test_restore_quick.sh` |
| **Full suite command** | `./scripts/backup/tests/test_restore.sh` |
| **Estimated runtime** | ~120 seconds |

---

## Sampling Rate

- **After every task commit:** Run `./scripts/backup/tests/test_restore_quick.sh`
- **After every plan wave:** Run `./scripts/backup/tests/test_restore.sh`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 08-01-01 | 01 | 1 | RESTORE-01 | T-08-01 | 列出 B2 备份时不泄露凭证 | integration | `./scripts/backup/tests/test_restore_quick.sh` | ✅ | ⬜ pending |
| 08-01-02 | 01 | 1 | RESTORE-02 | T-08-02 | 恢复时不覆盖生产数据库（测试模式） | integration | `./scripts/backup/tests/test_restore.sh` | ✅ | ⬜ pending |
| 08-01-03 | 01 | 1 | RESTORE-03 | T-08-03 | 校验和验证防止恶意备份注入 | integration | `./scripts/backup/tests/test_restore.sh` | ✅ | ⬜ pending |
| 08-01-04 | 01 | 1 | RESTORE-04 | T-08-04 | 错误信息不泄露敏感路径 | integration | `./scripts/backup/tests/test_restore.sh` | ✅ | ⬜ pending |
| 08-02-01 | 02 | 2 | VERIFY-02 | — | 验证脚本报告完整覆盖 | unit | `./scripts/backup/verify-restore.sh` | ✅ | ⬜ pending |
| 08-02-02 | 02 | 2 | DOC-01 | — | 文档包含安全注意事项 | manual | Review VERIFICATION.md | ✅ | ⬜ pending |
| 08-02-03 | 02 | 2 | DOC-02 | — | 使用指南包含示例 | manual | Review VERIFICATION.md | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

*注：08-02 的测试文件（verify-restore.sh、08-VERIFICATION.md）在 Plan 02 Task 1/2 中创建。Plan 01（Wave 1）修复 restore.sh 兼容性，Plan 02（Wave 2）依赖 Plan 01 完成后创建验证脚本和文档。测试基础设施随实现任务一起构建，无需单独的 Wave 0。*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 验证报告审查 | VERIFY-02 | 需要人工检查报告的完整性和准确性 | 1. 运行 `verify-restore.sh` 2. 检查报告包含所有 4 个成功标准 3. 验证每个标准有具体的证据和命令输出 |
| 文档实用性测试 | DOC-01, DOC-02 | 需要人工判断文档的清晰度和实用性 | 1. 阅读 VERIFICATION.md 使用指南 2. 按照示例命令执行测试 3. 验证命令输出与文档一致 |
| 错误信息质量评估 | RESTORE-04 | 需要人工评估错误信息的明确性 | 1. 触发各种恢复失败场景 2. 检查错误信息是否包含解决建议 3. 评估错误信息的可理解性 |

---

## Validation Sign-Off

- [x] 所有任务都有 `<automated>` 验证或已在实现任务中创建
- [x] 采样连续性：没有 3 个连续任务没有自动化验证
- [x] 无 Wave 0 引用缺失（测试基础设施随实现任务创建）
- [x] 没有 watch-mode 标志
- [x] 反馈延迟 < 30s
- [x] `nyquist_compliant: true` 在 frontmatter 中设置

**Approval:** pending
