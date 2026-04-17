---
phase: 23
slug: pipeline-integration
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-16
---

# Phase 23 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Jenkins Pipeline (Declarative) + bash scripts |
| **Config file** | `jenkins/Jenkinsfile` + `scripts/lib/*.sh` |
| **Quick run command** | `jenkins/Jenkinsfile` syntax check via `jenkinsfile-runner` or manual |
| **Full suite command** | Jenkins "Build Now" manual trigger |
| **Estimated runtime** | ~120 seconds (full pipeline) |

---

## Sampling Rate

- **After every task commit:** Verify Jenkinsfile syntax + bash script syntax
- **After every plan wave:** Full pipeline dry-run check
- **Before `/gsd-verify-work`:** Jenkins Pipeline must execute end-to-end
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 23-01-01 | 01 | 1 | PIPE-01 | T-23-01 | Jenkinsfile stage structure matches 8-stage spec | structural | `grep -c "stage(" jenkins/Jenkinsfile` | ❌ W0 | ⬜ pending |
| 23-01-02 | 01 | 1 | PIPE-01 | — | Multi-repo checkout (noda-infra + noda-apps) | integration | `grep "dir('noda-apps')" jenkins/Jenkinsfile` | ❌ W0 | ⬜ pending |
| 23-01-03 | 01 | 1 | PIPE-04 | — | Job definition script creates pipeline job | unit | `bash -n jenkins/jobs/03-pipeline-job.groovy` | ❌ W0 | ⬜ pending |
| 23-02-01 | 02 | 1 | PIPE-05 | — | Lint stage gates deployment | integration | `grep "pnpm lint" jenkins/Jenkinsfile` | ❌ W0 | ⬜ pending |
| 23-02-02 | 02 | 1 | TEST-01 | — | Unit test stage gates deployment | integration | `grep "pnpm test" jenkins/Jenkinsfile` | ❌ W0 | ⬜ pending |
| 23-02-03 | 02 | 1 | TEST-02 | — | Failure logs archived to Jenkins | integration | `grep "archiveArtifacts" jenkins/Jenkinsfile` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `jenkins/Jenkinsfile` — stubs for 8 stages
- [ ] `jenkins/jobs/03-pipeline-job.groovy` — job definition

*Existing infrastructure covers bash script dependencies from Phase 21/22.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Pipeline triggers via "Build Now" | PIPE-04 | Requires running Jenkins instance | 1. Open Jenkins UI 2. Click "Build Now" 3. Verify pipeline starts |
| Full pipeline end-to-end execution | PIPE-01 | Requires running Jenkins + Docker + noda-apps | 1. Trigger pipeline 2. Verify all 8 stages execute 3. Verify blue-green switch |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
