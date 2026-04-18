---
phase: 38
slug: quality-assurance
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-19
---

# Phase 38 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ShellCheck 0.11.0 + bash -n（无测试框架） |
| **Config file** | 无 — 本阶段创建 .shellcheckrc |
| **Quick run command** | `shellcheck scripts/**/*.sh` |
| **Full suite command** | `shellcheck scripts/**/*.sh && find scripts/ -name '*.sh' -exec bash -n {} \;` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `shellcheck scripts/**/*.sh && find scripts/ -name '*.sh' -exec bash -n {} \;`
- **After every plan wave:** Run `shellcheck scripts/**/*.sh && shfmt -d scripts/`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 38-01-01 | 01 | 1 | QUAL-01 | N/A | .shellcheckrc 记录抑制规则 | smoke | `test -f .shellcheckrc && shellcheck scripts/**/*.sh` | ❌ W0 | ⬜ pending |
| 38-01-02 | 01 | 1 | QUAL-01 | N/A | ShellCheck 零 error | smoke | `shellcheck -S error scripts/**/*.sh; echo $?` | ✅ | ⬜ pending |
| 38-02-01 | 02 | 2 | QUAL-02 | N/A | shfmt 安装并格式化 | smoke | `shfmt -d scripts/ \| wc -l` (应为 0) | ❌ W0 | ⬜ pending |
| 38-02-02 | 02 | 2 | QUAL-02 | N/A | .editorconfig 存在 | smoke | `test -f .editorconfig` | ❌ W0 | ⬜ pending |
| 38-02-03 | 02 | 2 | QUAL-01+02 | N/A | 格式化后 bash -n 通过 | smoke | `find scripts/ -name '*.sh' -exec bash -n {} \;` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] 安装 shfmt: `brew install shfmt`
- [ ] 创建 `.editorconfig` — covers QUAL-02 配置
- [ ] 创建 `.shellcheckrc` — covers QUAL-01 配置

---

## Manual-Only Verifications

All phase behaviors have automated verification.

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
