---
phase: 41
slug: migration-cleanup
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-19
---

# Phase 41 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash smoke tests（无自动化测试框架） |
| **Config file** | 无 |
| **Quick run command** | `DOPPLER_TOKEN='dp.st.prd.xxx' bash scripts/verify-doppler-secrets.sh` |
| **Full suite command** | `bash scripts/verify-doppler-secrets.sh && grep -rl 'sops\|SOPS' scripts/ 2>/dev/null || true` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash scripts/verify-doppler-secrets.sh`
- **After every plan wave:** Full suite + `grep -rl 'sops\|SOPS\|decrypt-secrets' scripts/ docs/`
- **Before `/gsd-verify-work`:** Full suite must pass
- **Max feedback latency:** 10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 41-01-01 | 01 | 1 | MIGR-01 | T-41-01 | verify 脚本覆盖 17 个密钥（含 GOOGLE_CLIENT_*） | smoke | `grep 'GOOGLE_CLIENT_ID' scripts/verify-doppler-secrets.sh` | ✅ | ⬜ pending |
| 41-01-02 | 01 | 1 | MIGR-03 | T-41-03 | load_secrets() 不含 docker/.env 回退 | unit | `grep -c 'docker/.env' scripts/lib/secrets.sh` | ✅ | ⬜ pending |
| 41-01-03 | 01 | 1 | MIGR-01 | — | backup-doppler-secrets.sh age 公钥硬编码 | unit | `grep 'AGE_PUBLIC_KEY' scripts/backup/backup-doppler-secrets.sh` | ✅ | ⬜ pending |
| 41-02-01 | 02 | 1 | MIGR-04 | T-41-04 | setup-keycloak-full.sh 无 SOPS 引用 | unit | `grep -c 'sops\|SOPS\|decrypt' scripts/setup-keycloak-full.sh` | ✅ | ⬜ pending |
| 41-02-02 | 02 | 1 | MIGR-04 | — | docs/ 和 README.md 无 SOPS 引用 | unit | `grep -rl 'sops\|SOPS' docs/ README.md 2>/dev/null` | - | ⬜ pending |
| 41-03-01 | 03 | 2 | MIGR-03/01 | T-41-02 | docker/.env 和 .env.production 不存在 | manual | `ls docker/.env .env.production 2>&1` | - | ⬜ pending |
| 41-03-02 | 03 | 2 | MIGR-04/02 | T-41-04 | SOPS 文件已删除 + backup/.env.backup 保留 | manual | `ls .sops.yaml scripts/backup/.env.backup 2>&1` | - | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- verify-doppler-secrets.sh 已存在（Phase 39 创建）
- grep 可用于 SOPS 残留扫描
- 现有基础设施覆盖所有阶段需求

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 文件删除确认 | MIGR-03 | 需验证文件系统状态 | `ls docker/.env .env.production .sops.yaml config/secrets.sops.yaml scripts/utils/decrypt-secrets.sh 2>&1` |
| 备份系统独立 | MIGR-02 | 需验证 .env.backup 存在且内容完整 | `cat scripts/backup/.env.backup` |
| 服务正常运行 | MIGR-01/03 | 需验证 Docker 服务在删除密钥文件后正常 | `docker compose ps` + `curl https://class.noda.co.nz/api/health` |

---

## Validation Sign-Off

- [ ] All tasks have automated verify or manual verification instructions
- [ ] Sampling continuity: no 3 consecutive tasks without verification
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
