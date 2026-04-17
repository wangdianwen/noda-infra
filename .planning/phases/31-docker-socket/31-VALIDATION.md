---
phase: 31
slug: docker-socket
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-18
---

# Phase 31 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ShellCheck (静态分析) + 手动验证脚本 |
| **Config file** | 无（使用 shellcheck 命令行） |
| **Quick run command** | `shellcheck scripts/undo-permissions.sh` |
| **Full suite command** | `shellcheck scripts/undo-permissions.sh scripts/setup-jenkins.sh` |
| **Estimated runtime** | ~2 秒 |

---

## Sampling Rate

- **After every task commit:** `shellcheck` 修改的 shell 脚本
- **After every plan wave:** 完整 shellcheck 所有修改脚本
- **Before `/gsd-verify-work`:** 生产服务器端到端验证
- **Max feedback latency:** 5 秒

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 31-01-01 | 01 | 1 | PERM-01 | — | jenkins 用户可执行 docker ps | manual-only | `sudo -u jenkins docker ps` | N/A | ⬜ pending |
| 31-01-02 | 01 | 1 | PERM-02 | — | 重启后 socket 属组持久化 | manual-only | `ls -la /var/run/docker.sock` | N/A | ⬜ pending |
| 31-02-01 | 02 | 1 | PERM-03 | — | 4 个脚本权限 750 root:jenkins | unit | `stat -c '%a %U:%G' scripts/deploy/*.sh scripts/pipeline-stages.sh scripts/manage-containers.sh` | N/A | ⬜ pending |
| 31-02-02 | 02 | 1 | PERM-04 | — | post-merge hook 存在且可执行 | unit | `test -x .git/hooks/post-merge` | Wave 0 | ⬜ pending |
| 31-02-03 | 02 | 1 | JENKINS-02 | — | 备份脚本正常工作 | manual-only | `sudo -u jenkins docker exec noda-infra-postgres-prod pg_isready` | N/A | ⬜ pending |
| 31-01-03 | 01 | 1 | PERM-01 | — | 非 jenkins 用户无法 docker ps | manual-only | `sudo -u admin docker ps` (expect failure) | N/A | ⬜ pending |
| 31-01-04 | 01 | 1 | JENKINS-01 | — | 4 个 Pipeline 端到端正常 | manual-only | Jenkins UI 手动触发 | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `scripts/undo-permissions.sh` — 需创建（最小回滚脚本）

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| jenkins 用户 docker 访问 | PERM-01 | 需生产服务器 + Docker daemon 运行 | `sudo -u jenkins docker ps` |
| 非 jenkins 用户被拒绝 | PERM-01 | 需生产服务器 + 非 jenkins 用户 | `sudo -u admin docker ps` (expect permission denied) |
| 重启后权限持久化 | PERM-02 | 需重启 Docker 服务 | `sudo systemctl restart docker && ls -la /var/run/docker.sock` |
| Pipeline 端到端 | JENKINS-01 | 需 Jenkins 运行 + 4 个 Job | Jenkins UI 手动触发每个 Pipeline |
| 备份兼容性 | JENKINS-02 | 需生产容器运行 | `sudo -u jenkins docker exec noda-infra-postgres-prod pg_isready` |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
