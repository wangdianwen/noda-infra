---
phase: 15
slug: postgresql
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-12
---

# Phase 15 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Shell 脚本 (bash) |
| **Config file** | none — 运行时验证 |
| **Quick run command** | `docker exec noda-ops pg_dump --version` |
| **Full suite command** | `bash scripts/deploy/deploy-infrastructure-prod.sh` + 手动触发备份 |
| **Estimated runtime** | ~120 seconds |

---

## Sampling Rate

- **After every task commit:** Run `docker exec noda-ops pg_dump --version`
- **After every plan wave:** 部署后验证完整备份流程
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 120 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 15-01-01 | 01 | 1 | PG-01 | — | pg_dump 版本 17.x | smoke | `docker exec noda-ops pg_dump --version` | N/A | ⬜ pending |
| 15-01-02 | 01 | 1 | PG-02 | T-15-01 | sslmode=disable 已设置 | smoke | `docker exec noda-ops printenv PGSSLMODE` | N/A | ⬜ pending |
| 15-01-03 | 01 | 1 | PG-02 | — | HEALTHCHECK 正常 | smoke | `docker inspect noda-ops --format='{{.State.Health.Status}}'` | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

*Existing infrastructure covers all phase requirements.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 端到端备份流程 | PG-01, PG-02 | 需生产环境部署 + B2 上传验证 | 部署后手动触发备份，验证健康检查->备份->验证->上传 B2 全流程 |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
