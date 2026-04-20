---
phase: 48
slug: docker-hygiene
status: draft
nyquist_compliant: false
wave_0_complete: true
created: 2026-04-20
---

# Phase 48 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Docker build + 手动验证 |
| **Config file** | 无 |
| **Quick run command** | `docker build -f deploy/Dockerfile.noda-ops ..` |
| **Full suite command** | 构建全部 4 个 Dockerfile + test-verify 功能验证 |
| **Estimated runtime** | ~120 秒 |

---

## Sampling Rate

- **After every task commit:** `docker build` 验证改动后的 Dockerfile
- **After every plan wave:** 构建全部受影响的 Dockerfile
- **Before `/gsd-verify-work`:** 全部构建通过 + test-verify 功能验证
- **Max feedback latency:** 60 秒（单个 Dockerfile 构建时间）

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 48-01-01 | 01 | 1 | HYGIENE-01 | — | .dockerignore 排除敏感文件（.planning、.env） | build | `docker build -f deploy/Dockerfile.noda-ops ..` | N/A | ⬜ pending |
| 48-01-01 | 01 | 1 | HYGIENE-02 | — | COPY --chown 替代 RUN chown | build | `docker history <image> \| grep chown` | N/A | ⬜ pending |
| 48-01-01 | 01 | 1 | HYGIENE-03 | — | test-verify 基础镜像升级 | build | `docker build -f scripts/backup/docker/Dockerfile.test-verify .` | N/A | ⬜ pending |
| 48-02-01 | 02 | 2 | HYGIENE-01/02/03 | — | 全部 Dockerfile 构建通过 | build | 见 Plan 02 Task 1 | N/A | ⬜ pending |
| 48-02-02 | 02 | 2 | HYGIENE-03 | — | test-verify 功能验证 | manual | 手动运行 test-verify-weekly.sh | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Existing infrastructure covers all phase requirements. Docker build 是内置验证机制，无需额外测试框架。

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| test-verify 完整功能验证 | HYGIENE-03 | 需要 prod 数据库连接 + pg_restore 测试 | 通过 Jenkins 部署后手动执行 test-verify 验证脚本 |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
