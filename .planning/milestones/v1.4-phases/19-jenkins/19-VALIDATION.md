---
phase: 19
slug: jenkins
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-14
---

# Phase 19 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash script testing（手动验证 + shellcheck 静态分析） |
| **Config file** | none — 脚本直接在生产服务器执行 |
| **Quick run command** | `bash -n scripts/setup-jenkins.sh && shellcheck scripts/setup-jenkins.sh` |
| **Full suite command** | `bash scripts/setup-jenkins.sh status`（需生产服务器） |
| **Estimated runtime** | ~5 seconds（语法检查）/ 需远程执行（功能验证） |

---

## Sampling Rate

- **After every task commit:** Run `bash -n scripts/setup-jenkins.sh`（语法检查）
- **After every plan wave:** Run `shellcheck scripts/setup-jenkins.sh`（静态分析）
- **Before `/gsd-verify-work`:** 在生产服务器执行 install + status + show-password 验证
- **Max feedback latency:** 5 seconds（本地语法检查）/ 需远程执行（功能验证）

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 19-01-01 | 01 | 1 | JENK-01, JENK-03 | T-19-03 | jenkins 用户仅通过 docker 组权限操作 Docker | syntax | `bash -n scripts/setup-jenkins.sh` | ❌ W0 | ⬜ pending |
| 19-01-02 | 01 | 1 | JENK-02, JENK-04 | — | N/A | syntax | `bash -n scripts/setup-jenkins.sh && shellcheck scripts/setup-jenkins.sh` | ❌ W0 | ⬜ pending |
| 19-02-01 | 02 | 1 | JENK-04 | T-19-04, T-19-06 | 管理员凭据 .admin.env 权限 600 + groovy 脚本幂等 + 首次配置后删除 | file_exists | `test -f scripts/jenkins/init.groovy.d/01-security.groovy` | ❌ W0 | ⬜ pending |
| 19-02-02 | 02 | 1 | JENK-04 | T-19-04 | .admin.env 被 .gitignore 排除 + 权限 600 | file_exists | `test -f scripts/jenkins/config/jenkins-admin.env.example && test -f scripts/jenkins/config/.gitignore` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `scripts/setup-jenkins.sh` — 脚本文件存在且语法正确
- [ ] `scripts/jenkins/init.groovy.d/01-security.groovy` — 管理员用户 + 安全策略脚本
- [ ] `scripts/jenkins/init.groovy.d/02-plugins.groovy` — 插件安装脚本
- [ ] `scripts/jenkins/init.groovy.d/03-pipeline-job.groovy` — Pipeline 作业创建脚本
- [ ] `scripts/jenkins/config/jenkins-admin.env.example` — 管理员凭据模板

*All Wave 0 items are local file creation — no test framework installation needed.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Jenkins 安装后服务运行 | JENK-01 | 需要 Debian/Ubuntu 生产服务器 | `systemctl status jenkins` 显示 active (running) |
| Jenkins 完全卸载 | JENK-02 | 需要 Debian/Ubuntu 生产服务器 | `dpkg -l jenkins` 不存在 + `ls /var/lib/jenkins` 不存在 |
| jenkins 用户 Docker 权限 | JENK-03 | 需要 Docker daemon 运行 | `sudo -u jenkins docker ps` 返回容器列表 |
| 获取初始管理员密码 | JENK-04 | 需要 Jenkins 运行 | `bash scripts/setup-jenkins.sh show-password` 显示密码 |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 5s（本地）/ 需远程（功能）
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
