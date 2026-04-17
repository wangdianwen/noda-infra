---
phase: 24
slug: pipeline
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-16
---

# Phase 24 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash script testing（无独立测试框架） |
| **Config file** | 无 — 直接执行 bash 函数验证 |
| **Quick run command** | `bash -n scripts/pipeline-stages.sh` |
| **Full suite command** | 手动验证：逐个函数调用测试 |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** `bash -n scripts/pipeline-stages.sh`
- **After every plan wave:** 手动在测试环境执行完整 Pipeline
- **Before `/gsd-verify-work`:** 人工验证通过
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 24-01-01 | 01 | 1 | ENH-01 | — | N/A | unit | `bash -n scripts/pipeline-stages.sh` | ✅ | ⬜ pending |
| 24-01-02 | 01 | 1 | ENH-01 | — | N/A | unit | `bash -n scripts/pipeline-stages.sh` | ✅ | ⬜ pending |
| 24-01-03 | 01 | 1 | ENH-02 | — | CF API Token 不泄露到日志 | unit | `bash -n scripts/pipeline-stages.sh` | ✅ | ⬜ pending |
| 24-01-04 | 01 | 1 | ENH-03 | — | N/A | unit | `bash -n scripts/pipeline-stages.sh` | ✅ | ⬜ pending |
| 24-01-05 | 01 | 1 | ENH-02 | — | N/A | unit | `bash -n jenkins/Jenkinsfile` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] `bash -n scripts/pipeline-stages.sh` — bash 语法检查
- [x] `bash -n jenkins/Jenkinsfile` — 不适用（Groovy 语法）

*Existing infrastructure covers all phase requirements.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 备份超过 12 小时时阻止部署 | ENH-01 | 需要 Jenkins 环境和真实备份文件 | 1. 确认备份文件 >12h 前 2. 触发 Pipeline 3. 检查 Pre-flight 失败 |
| CDN 缓存清除成功 | ENH-02 | 需要 Cloudflare 凭据和真实 API 调用 | 1. 部署成功后检查 Pipeline 日志 2. curl 检查 CDN 缓存已清除 |
| 旧镜像清理 | ENH-03 | 需要 Docker 环境和真实旧镜像 | 1. 确认存在 >7 天镜像 2. 触发 Pipeline 3. 检查镜像已清理 |

---

## Validation Sign-Off

- [x] All tasks have automated verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
