---
phase: 44
slug: jenkins-maintenance-cleanup
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-20
---

# Phase 44 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Jenkins Pipeline 手动验证 + bash -n 语法检查 |
| **Config file** | 无独立测试框架 |
| **Quick run command** | `bash -n scripts/lib/cleanup.sh && bash -n jenkins/Jenkinsfile.cleanup` |
| **Full suite command** | 手动触发 cleanup Pipeline + 检查日志 + 验证磁盘空间 |
| **Estimated runtime** | ~120 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash -n` syntax check on modified files
- **After every plan wave:** Manual Pipeline trigger + log review
- **Before `/gsd-verify-work`:** Full cleanup Pipeline execution must succeed
- **Max feedback latency:** 120 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 44-01-01 | 01 | 1 | JENK-02 | T-44-01 | workspace_root 使用硬编码默认值，不接受外部输入 | manual | `bash -n scripts/lib/cleanup.sh` | ❌ W0 | ⬜ pending |
| 44-01-02 | 01 | 1 | CACHE-02 | — | 7 天间隔 + 标记文件 | manual | `bash -n scripts/lib/cleanup.sh` | ❌ W0 | ⬜ pending |
| 44-01-03 | 01 | 1 | CACHE-03 | — | `npm cache clean --force` + `|| true` | manual | `bash -n scripts/lib/cleanup.sh` | ❌ W0 | ⬜ pending |
| 44-02-01 | 02 | 2 | JENK-01 | — | buildDiscarder numToKeepStr: '20' | verify | `grep -r "buildDiscarder" jenkins/Jenkinsfile.cleanup` | ❌ W0 | ⬜ pending |
| 44-02-02 | 02 | 2 | CACHE-02, CACHE-03 | T-44-02 | disableConcurrentBuilds() 防止并发 | manual | 手动触发 Pipeline + 检查日志 | ❌ W0 | ⬜ pending |
| 44-03-01 | 03 | 3 | JENK-01, JENK-02, CACHE-02, CACHE-03 | — | 全量端到端验证 | manual | 手动触发 + 日志验证 + 磁盘空间检查 | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `scripts/lib/cleanup.sh` — 扩展 3 个新函数（cleanup_jenkins_workspace, cleanup_pnpm_store, cleanup_npm_cache）
- [ ] `jenkins/Jenkinsfile.cleanup` — 定期清理 Pipeline（新文件）
- [ ] 手动验证: 触发 cleanup Pipeline + 检查日志输出 + 验证磁盘空间变化

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| workspace 目录被清理释放磁盘 | JENK-02 | 需要实际 Jenkins 运行环境 | 触发 cleanup Pipeline，检查 workspace 目录大小变化 |
| pnpm store prune 执行成功 | CACHE-02 | 需要实际 pnpm 环境 | 触发 cleanup Pipeline，检查日志中 prune 输出 |
| npm cache clean 执行成功 | CACHE-03 | 需要实际 npm 环境 | 触发 cleanup Pipeline，检查日志中 cache clean 输出 |
| cron 定期触发 | D-04 | 需要 Jenkins 长时间运行 | 检查 Jenkins build history 中是否有自动触发记录 |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
