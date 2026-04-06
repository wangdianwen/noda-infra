---
phase: 6
slug: fix-variable-conflicts
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-06
---

# Phase 6 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash built-in testing + grep verification |
| **Config file** | none — uses existing TEST_REPORT.md structure |
| **Quick run command** | `bash scripts/backup/backup-postgres.sh --verify-only` |
| **Full suite command** | `cd scripts/backup && bash test-all.sh 2>&1 | tee TEST_REPORT.md` |
| **Estimated runtime** | ~120 seconds |

---

## Sampling Rate

- **After every task commit:** Run `grep -r "EXIT_SUCCESS" scripts/backup/lib/ | wc -l` (should be 1)
- **After every task wave:** Run `bash scripts/backup/backup-postgres.sh --dry-run` (validation mode)
- **Before `/gsd-verify-work`:** Full suite must be green (100% tests pass)
- **Max feedback latency:** 120 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 06-01-01 | 01 | 1 | (技术债务修复) | — | 无安全威胁 | verification | `grep -c "source.*constants.sh" scripts/backup/lib/*.sh | grep -c "^9$"` | ✅ | ⬜ pending |
| 06-01-02 | 01 | 1 | (技术债务修复) | — | 无安全威胁 | verification | `grep -r "^readonly EXIT_" scripts/backup/lib/ | wc -l | grep "^1$"` | ✅ | ⬜ pending |
| 06-01-03 | 01 | 1 | (技术债务修复) | — | 无安全威胁 | verification | `bash scripts/backup/backup-postgres.sh --verify-only 2>&1 | grep -q "0 failed"` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `scripts/backup/lib/constants.sh` — 统一退出码定义 (已存在)
- [ ] `scripts/backup/TEST_REPORT.md` — 端到端测试报告 (已存在,100% 通过)
- [ ] 验证脚本: 创建 `scripts/backup/verify-phase6.sh` — 验证 Phase 6 修复完整性

*Existing infrastructure covers most phase requirements. Phase 6 adds verification scripts.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 主脚本完整执行 | Success Criteria #3 | 需要真实数据库环境 | 运行完整备份流程,验证健康检查→备份→验证→上传→清理全部成功 |
| 变量冲突检查 | Success Criteria #1, #2 | 需要代码审查 | 使用 grep 搜索所有 lib 文件,确认无重复 EXIT_* 定义 |

*All phase behaviors have automated verification through grep and test scripts.*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
