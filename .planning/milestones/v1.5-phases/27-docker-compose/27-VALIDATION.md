---
phase: 27
slug: docker-compose
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-17
---

# Phase 27 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Docker Compose config 验证 + grep 断言 |
| **Config file** | none |
| **Quick run command** | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml config 2>&1 \| grep -c postgres-dev` |
| **Full suite command** | 手动验证 4 项成功标准 |
| **Estimated runtime** | ~5 秒 |

---

## Sampling Rate

- **After every task commit:** Run compose config grep 验证
- **After every plan wave:** 完整 4 项成功标准验证
- **Before `/gsd-verify-work`:** 全部 5 项 CLEANUP 需求通过
- **Max feedback latency:** 5 秒

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 27-01-01 | 01 | 1 | CLEANUP-01 | — | N/A | smoke | `docker compose config \| grep -c postgres-dev` → 0 | ❌ W0 | ⬜ pending |
| 27-01-02 | 01 | 1 | CLEANUP-02 | — | N/A | smoke | `docker compose config \| grep -c keycloak-dev` → 0 | ❌ W0 | ⬜ pending |
| 27-01-03 | 01 | 1 | CLEANUP-03 | — | N/A | smoke | `docker compose config \| grep "8081"` → found | ❌ W0 | ⬜ pending |
| 27-02-01 | 02 | 1 | CLEANUP-04 | — | N/A | unit | `grep -c postgres-dev deploy-infrastructure-prod.sh` → 0 | ❌ W0 | ⬜ pending |
| 27-03-01 | 03 | 2 | CLEANUP-05 | — | N/A | smoke | `test -f docker-compose.dev-standalone.yml && echo FAIL \|\| echo PASS` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] 无需额外测试框架 — Docker Compose config 验证 + grep 即可覆盖
- [ ] 现有 `scripts/utils/validate-docker.sh` 可用于配置语法验证

*Existing infrastructure covers all phase requirements.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 生产服务部署不受影响 | Phase gate | 需要实际部署验证 | 确认 docker compose config 输出包含 postgres、keycloak、nginx、noda-ops |

---

## Validation Sign-Off

- [ ] All tasks have automated verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
