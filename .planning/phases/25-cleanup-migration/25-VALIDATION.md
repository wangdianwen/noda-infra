---
phase: "25"
slug: cleanup-migration
status: draft
nyquist_compliant: false
wave_0_complete: true
created: "2026-04-16"
---

# Phase 25 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | 手动验证（文档审查） |
| **Config file** | none — 纯文档/注释变更 |
| **Quick run command** | `git diff HEAD~1 --stat` |
| **Full suite command** | `git diff HEAD~N --stat` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `git diff HEAD~1 --stat` 确认变更范围
- **After every plan wave:** Run `git diff HEAD~N` 确认所有文件正确修改
- **Before `/gsd-verify-work`:** 全部文件 diff 审查通过
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 25-01-01 | 01 | 1 | ENH-04 | — | N/A | manual-only | `head -15 scripts/deploy/deploy-infrastructure-prod.sh` | ✅ | ⬜ pending |
| 25-01-02 | 01 | 1 | ENH-04 | — | N/A | manual-only | `grep -A 30 "部署命令" CLAUDE.md` | ✅ | ⬜ pending |
| 25-01-03 | 01 | 1 | ENH-04 | — | N/A | manual-only | `grep "v1.4" .planning/ROADMAP.md` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Existing infrastructure covers all phase requirements — 纯文档变更，无测试框架需求。

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 旧脚本添加手动回退注释 | ENH-04 | 文档变更无自动化测试 | `head -15 scripts/deploy/deploy-infrastructure-prod.sh` 检查注释块 |
| CLAUDE.md 部署章节更新 | ENH-04 | 文档变更无自动化测试 | `grep -A 30 "部署命令" CLAUDE.md` 检查章节内容 |
| ROADMAP.md/PROJECT.md/STATE.md 归档 | ENH-04 | 文档变更无自动化测试 | 人工审查 diff 确认格式一致 |

---

## Validation Sign-Off

- [x] All tasks have verification commands defined
- [x] Sampling continuity: all tasks have manual verify steps
- [x] Wave 0 covers all MISSING references (N/A — no test framework needed)
- [x] No watch-mode flags
- [x] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
