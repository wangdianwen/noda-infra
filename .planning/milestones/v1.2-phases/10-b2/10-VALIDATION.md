---
phase: 10
slug: b2
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-11
---

# Phase 10 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash + 手动验证 |
| **Config file** | 无 |
| **Quick run command** | `bash -n scripts/backup/lib/health.sh`（语法检查） |
| **Full suite command** | 容器内 `backup-postgres.sh --dry-run` |
| **Estimated runtime** | ~30 秒 |

---

## Sampling Rate

- **After every task commit:** `bash -n scripts/backup/lib/{modified_file}.sh`（语法检查）
- **After every plan wave:** 容器内 dry-run 验证
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 秒

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 10-01-01 | 01 | 1 | BFIX-01 | T-10-01 / — | crontab 路径与 Dockerfile COPY 路径一致 | manual | 对比 Dockerfile COPY 与 crontab 路径 | N/A | ⬜ pending |
| 10-01-02 | 01 | 1 | BFIX-01 | — | N/A | manual | 容器内执行 backup-postgres.sh，检查 B2 控制台 | N/A | ⬜ pending |
| 10-02-01 | 02 | 1 | BFIX-02 | — | N/A | unit | `bash -n health.sh` + 模拟空间不足 | ❌ W0 | ⬜ pending |
| 10-02-02 | 02 | 1 | BFIX-02 | — | 磁盘检查返回 EXIT_DISK_SPACE_INSUFFICIENT | unit | 模拟空间不足场景验证退出码 | ❌ W0 | ⬜ pending |
| 10-03-01 | 03 | 1 | BFIX-03 | T-10-01 | 文件名正则验证 `^[^_]+_[0-9]{8}_[0-9]{6}\.(sql\|dump)$` | unit | `bash -n restore.sh` + rclone ls 输出模拟 | ❌ W0 | ⬜ pending |
| 10-03-02 | 03 | 1 | BFIX-03 | — | 下载路径正确处理 YYYY/MM/DD/ 子目录 | unit | 验证 rclone copy --include 路径匹配 | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] 测试可能采用手动验证方式（在容器内执行），而非独立测试文件
- [ ] `bash -n` 语法检查覆盖所有修改的脚本

*注意：此阶段为 Bash 运维脚本修复，无传统测试框架。验证方式以语法检查 + 容器内手动测试为主。*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| B2 上传成功验证 | BFIX-01 | 需要 B2 凭证和网络访问 | 容器内执行 backup-postgres.sh，检查 B2 控制台 |
| 磁盘空间告警触发 | BFIX-02 | 需要容器环境和真实挂载点 | 模拟小容量挂载点验证告警行为 |
| B2 下载验证 | BFIX-03 | 需要 B2 凭证和网络访问 | 容器内执行 download_backup，验证文件完整性 |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
