---
phase: 52
slug: 52-基础设施镜像清理
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-21
---

# Phase 52 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | 无独立测试框架（Docker 构建验证 + 功能性测试） |
| **Config file** | 无 |
| **Quick run command** | `docker build -f deploy/Dockerfile.noda-ops -t noda-ops:test .` |
| **Full suite command** | 构建验证 + 容器启动 + 二进制可用性检查 |
| **Estimated runtime** | ~120 seconds |

---

## Sampling Rate

- **After every task commit:** `docker build` 验证构建成功
- **After every plan wave:** 全部镜像构建 + 运行时二进制可用性检查
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 120 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 52-01-01 | 01 | 1 | INFRA-01 | T-52-01 | 构建工具不泄漏到运行时 | smoke | `docker run --rm noda-ops:test sh -c "which wget gnupg curl 2>/dev/null; echo exit: \$?"` | W0 | ⬜ pending |
| 52-01-02 | 01 | 1 | INFRA-01 | T-52-02 | cloudflared/doppler 二进制可用 | smoke | `docker run --rm noda-ops:test cloudflared --version && docker run --rm noda-ops:test doppler --version` | W0 | ⬜ pending |
| 52-02-01 | 02 | 1 | INFRA-02 | — | backup Dockerfile 仅 1 个 RUN | unit | `grep -c "^RUN" deploy/Dockerfile.backup` | ✅ | ⬜ pending |
| 52-02-02 | 02 | 1 | INFRA-02 | — | backup 构建成功 | smoke | `docker build -f deploy/Dockerfile.backup -t noda-backup:test .` | W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] 无独立测试文件 — 本 phase 以 Docker 构建验证为主，不需要 pytest/jest 框架
- [ ] 验证步骤内联在 task 中（构建验证 + 二进制检查 + 运行时脚本可用性）

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| noda-ops 容器启动后 supervisor/crontab/rclone 正常工作 | INFRA-01 | 需要 Docker Compose 完整环境 + doppler 密钥 | `docker compose up noda-ops` → 检查日志确认备份脚本可运行 |
| backup 容器 pg_dump 功能正常 | INFRA-02 | 需要 PostgreSQL 连接 | `docker compose up backup` → 触发手动备份 → 验证 B2 上传 |

*If none: "All phase behaviors have automated verification."*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
