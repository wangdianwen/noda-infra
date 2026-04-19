---
phase: 42
slug: backup-security
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-19
---

# Phase 42 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Shell 脚本测试（bash + docker） |
| **Config file** | none |
| **Quick run command** | `bash -n scripts/backup/backup-doppler-secrets.sh` |
| **Full suite command** | `bash scripts/backup/backup-doppler-secrets.sh --dry-run` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash -n` syntax check on modified scripts
- **After every plan wave:** Run `--dry-run` verification
- **Before `/gsd-verify-work`:** Full dry-run must be green
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 42-01-01 | 01 | 1 | BACKUP-01 | — | n/a | syntax | `bash -n scripts/backup/backup-doppler-secrets.sh` | ✅ W0 | ⬜ pending |
| 42-01-02 | 01 | 1 | BACKUP-01 | — | n/a | integration | `grep doppler-secrets deploy/entrypoint-ops.sh` | ⬜ pending | ⬜ pending |
| 42-01-03 | 01 | 1 | BACKUP-01 | — | n/a | integration | `grep DOPPLER_TOKEN docker/docker-compose.yml` | ⬜ pending | ⬜ pending |
| 42-02-01 | 02 | 1 | BACKUP-02 | — | n/a | syntax | `bash -n scripts/utils/git-history-cleanup.sh` | ⬜ pending | ⬜ pending |
| 42-02-02 | 02 | 1 | BACKUP-02 | — | n/a | integration | `grep git-filter-repo scripts/utils/git-history-cleanup.sh` | ⬜ pending | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Existing infrastructure covers all phase requirements. Shell syntax checking is built-in.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| BFG/git-filter-repo 实际执行 | BACKUP-02 | 需要 force push 到 remote，不可自动执行 | 脚本列出变更 → 用户确认 → 执行 → 验证 |
| cron 任务实际触发 | BACKUP-01 | 需要等待 cron 周期 | 等待 24 小时后检查 B2 bucket |
| Doppler 备份到 B2 端到端 | BACKUP-01 | 需要 noda-ops 容器重建后验证 | 部署后 --dry-run 验证 |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
