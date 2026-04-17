---
phase: 30
slug: dev-setup
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-17
---

# Phase 30 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | 无 shell 测试框架（手动验证） |
| **Config file** | none |
| **Quick run command** | `bash setup-dev.sh` |
| **Full suite command** | `bash setup-dev.sh && psql -l` |
| **Estimated runtime** | ~30 秒 |

---

## Sampling Rate

- **After every task commit:** 静态检查（grep 验证文件内容和结构）
- **After every plan wave:** 手动运行 `bash setup-dev.sh` 验证端到端
- **Before `/gsd-verify-work`:** 全量验证（首次运行 + 重复运行 + 架构检测）
- **Max feedback latency:** 手动验证（Shell 脚本无自动化测试）

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 30-01-01 | 01 | 1 | DEVEX-01 | — | N/A | grep | `grep -c 'setup-postgres-local.sh' setup-dev.sh` | ⬜ W0 | ⬜ pending |
| 30-01-02 | 01 | 1 | DEVEX-02 | — | N/A | grep | `grep -c 'brew list' setup-dev.sh` | ⬜ W0 | ⬜ pending |
| 30-01-03 | 01 | 1 | DEVEX-03 | — | N/A | grep | `grep -c 'detect_homebrew_prefix\\|uname -m' setup-dev.sh` | ⬜ W0 | ⬜ pending |
| 30-02-01 | 02 | 1 | DEVEX-01 | — | N/A | grep | `grep -c 'setup-dev.sh' docs/DEVELOPMENT.md` | ⬜ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

*Existing infrastructure covers all phase requirements.* Shell 脚本项目无测试框架依赖，所有验证通过 grep + 手动运行完成。

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 首次运行完整流程 | DEVEX-01 | 需要干净 macOS 环境 | `bash setup-dev.sh` 观察输出，确认 PostgreSQL 安装、数据库创建、验证通过 |
| 重复运行幂等性 | DEVEX-02 | 需要已完成首次运行 | 再次 `bash setup-dev.sh`，确认 no-op 行为，无错误 |
| Apple Silicon 路径 | DEVEX-03 | 需要特定硬件 | 在 M-series Mac 上运行，确认 /opt/homebrew 路径 |
| Intel Mac 路径 | DEVEX-03 | 需要特定硬件 | 在 Intel Mac 上运行，确认 /usr/local 路径 |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency: 手动验证（Shell 脚本项目，可接受）
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
