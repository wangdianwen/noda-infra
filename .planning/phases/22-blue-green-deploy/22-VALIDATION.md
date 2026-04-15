---
phase: 22
slug: blue-green-deploy
status: draft
nyquist_compliant: false
wave_0_complete: true
created: 2026-04-15
---

# Phase 22 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | 无自动化测试框架（纯 bash 脚本） |
| **Config file** | 无 |
| **Quick run command** | `bash -n scripts/blue-green-deploy.sh && bash -n scripts/rollback-findclass.sh` |
| **Full suite command** | 手动集成测试（生产环境执行完整部署流程） |
| **Estimated runtime** | ~3-5 分钟（手动集成测试） |

---

## Sampling Rate

- **After every task commit:** Run `bash -n scripts/blue-green-deploy.sh && bash -n scripts/rollback-findclass.sh`
- **After every plan wave:** 手动集成测试
- **Before `/gsd-verify-work`:** 完整部署流程手动验证
- **Max feedback latency:** 即时（bash -n 语法检查 < 1s）

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 22-01-01 | 01 | 1 | PIPE-02 | — | 镜像携带 Git SHA 标签 | syntax | `bash -n scripts/blue-green-deploy.sh` | ❌ W0 | ⬜ pending |
| 22-01-02 | 01 | 1 | TEST-03 | — | HTTP 健康检查重试 | syntax | `bash -n scripts/blue-green-deploy.sh` | ❌ W0 | ⬜ pending |
| 22-01-03 | 01 | 1 | TEST-04 | — | E2E 验证 nginx 链路 | syntax | `bash -n scripts/blue-green-deploy.sh` | ❌ W0 | ⬜ pending |
| 22-01-04 | 01 | 1 | TEST-05 | — | 失败时不切换流量 | syntax | `bash -n scripts/blue-green-deploy.sh` | ❌ W0 | ⬜ pending |
| 22-01-05 | 01 | 1 | PIPE-03 | — | 构建失败时中止 | syntax | `bash -n scripts/blue-green-deploy.sh` | ❌ W0 | ⬜ pending |
| 22-02-01 | 02 | 1 | TEST-05 | — | 回滚到上一容器 | syntax | `bash -n scripts/rollback-findclass.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Existing infrastructure covers all phase requirements. Bash 脚本通过 `bash -n` 语法检查 + 手动集成测试验证，不需要安装测试框架。

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 镜像 SHA 标签正确 | PIPE-02 | 需要 Docker 构建环境 | 构建后 `docker images findclass-ssr` 检查标签 |
| HTTP 健康检查重试逻辑 | TEST-03 | 需要运行中的容器 | 启动容器后执行部署脚本，观察健康检查日志 |
| E2E 验证 nginx 链路 | TEST-04 | 需要完整部署环境 | 部署后 curl 外部 URL 验证 |
| 失败时不切换流量 | TEST-05 | 需要模拟失败场景 | 修改健康检查端点使其失败，验证 upstream 未变更 |
| 构建失败时中止 | PIPE-03 | 需要 Docker 构建失败场景 | 构建一个会失败的 Dockerfile |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 1s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
