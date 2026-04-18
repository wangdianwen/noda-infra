---
phase: 33
slug: audit-logging
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-18
---

# Phase 33 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Shell script verification (bash assertions) |
| **Config file** | none — verification built into scripts |
| **Quick run command** | `sudo install-audit-rules.sh verify` |
| **Full suite command** | `sudo install-audit-rules.sh verify && sudo -u jenkins docker ps && ausearch -k docker-cmd -ts recent` |
| **Estimated runtime** | ~10 seconds |

---

## Sampling Rate

- **After every task commit:** Run `install-audit-rules.sh verify` (or relevant verify subcommand)
- **After every plan wave:** Full suite — auditd verify + Jenkins Audit Trail check + sudo log check
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 33-01-01 | 01 | 1 | AUDIT-01 | — | auditd 规则监控 docker 命令 | integration | `ausearch -k docker-cmd -ts recent` | — | ⬜ pending |
| 33-01-02 | 01 | 1 | AUDIT-02 | — | auditd 日志 root 只读 | integration | `ls -la /var/log/audit/audit.log` | — | ⬜ pending |
| 33-02-01 | 02 | 1 | AUDIT-03 | — | Jenkins Audit Trail 记录 Pipeline 触发 | integration | `ls -la $JENKINS_HOME/audit-trail/` | — | ⬜ pending |
| 33-03-01 | 03 | 1 | AUDIT-04 | — | sudo 操作记录到独立日志 | integration | `grep COMMAND /var/log/sudo-logs/sudo.log` | — | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `install-audit-rules.sh` — auditd 规则安装/验证/卸载脚本
- [ ] `install-sudo-log.sh` — sudo 日志配置安装/验证脚本
- [ ] auditd 包已安装（`dpkg -l auditd`）

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Jenkins Audit Trail File Logger 配置 | AUDIT-03 | 需要 Jenkins UI 手动配置 File Logger 输出路径 | Jenkins 管理 → Audit Trail → 添加 File Logger → 设置路径 |
| auditd 日志权限验证（root 只读） | AUDIT-02 | 需要 root 权限检查文件权限 | `ls -la /var/log/audit/audit.log` 确认权限 600 root:root |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
