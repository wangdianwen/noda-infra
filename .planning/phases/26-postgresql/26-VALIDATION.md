---
phase: 26
slug: postgresql
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-17
---

# Phase 26 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash smoke tests（脚本 status 子命令 + 手动验证） |
| **Config file** | 无 |
| **Quick run command** | `bash scripts/setup-postgres-local.sh status` |
| **Full suite command** | 手动验证 4 项成功标准 |
| **Estimated runtime** | ~10 秒 |

---

## Sampling Rate

- **After every task commit:** Run `bash scripts/setup-postgres-local.sh status`
- **After every plan wave:** 验证对应成功标准
- **Before `/gsd-verify-work`:** 所有 4 项成功标准通过
- **Max feedback latency:** 10 秒

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 26-01-01 | 01 | 1 | LOCALPG-01 | T-26-01 / — | listen_addresses=localhost | smoke | `psql --version \| grep "17."` | ❌ W0 | ⬜ pending |
| 26-01-02 | 01 | 1 | LOCALPG-01 | T-26-01 | psql 在 PATH 中可用 | smoke | `which psql` | ❌ W0 | ⬜ pending |
| 26-01-03 | 01 | 1 | LOCALPG-03 | — | brew services 自启动 | smoke | `brew services list \| grep "postgresql@17.*started"` | ❌ W0 | ⬜ pending |
| 26-02-01 | 02 | 1 | LOCALPG-02 | T-26-02 | trust 仅限本地连接 | smoke | `psql -lqt \| grep noda_dev` | ❌ W0 | ⬜ pending |
| 26-02-02 | 02 | 1 | LOCALPG-02 | T-26-02 | trust 仅限本地连接 | smoke | `psql -lqt \| grep keycloak_dev` | ❌ W0 | ⬜ pending |
| 26-03-01 | 03 | 2 | LOCALPG-04 | — | 迁移数据完整性 | manual | `psql -d noda_dev -c "SELECT count(*) FROM courses;"` | ❌ W0 | ⬜ pending |
| 26-03-02 | 03 | 2 | LOCALPG-04 | — | schema 完整性 | manual | `psql -d keycloak_dev -c "\dt" \| wc -l` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] 无需独立测试文件——本阶段产物是 shell 脚本
- [ ] 验证通过 `setup-postgres-local.sh status` 子命令实现
- [ ] 成功标准验证为手动操作（安装 + 迁移 + 重启验证）

*Existing infrastructure covers all phase requirements — no framework install needed.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 重启后 PG 自动启动 | LOCALPG-03 | 需要重启 macOS | 重启电脑后运行 `brew services list` 验证 postgresql@17 为 started |
| Docker 数据完整迁移 | LOCALPG-04 | 需人工确认数据量一致 | 迁移前后对比 `psql -d noda_dev -c "SELECT count(*) FROM courses;"` |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
