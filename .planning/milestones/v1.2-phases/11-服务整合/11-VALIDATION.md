---
phase: 11
slug: 11-服务整合
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-11
---

# Phase 11 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Shell 脚本验证（Docker Compose config 检查） |
| **Config file** | 无 |
| **Quick run command** | `cd docker && docker compose config >/dev/null 2>&1` |
| **Full suite command** | `cd docker && docker compose -f docker-compose.yml config && docker compose -f docker-compose.app.yml config && docker compose -f docker-compose.simple.yml config` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd docker && docker compose config >/dev/null 2>&1`
- **After every plan wave:** Run full suite command
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 11-01-01 | 01 | 1 | GROUP-01 | — | N/A | smoke | `cd docker && docker compose -f docker-compose.yml config \| grep -A5 dockerfile` | ✅ | ⬜ pending |
| 11-01-02 | 01 | 1 | GROUP-01 | — | N/A | smoke | `cd docker && docker compose -f docker-compose.app.yml config \| grep -A5 dockerfile` | ✅ | ⬜ pending |
| 11-02-01 | 02 | 1 | GROUP-02 | — | N/A | smoke | `grep -r "noda.service-group" docker/docker-compose*.yml \| wc -l` | ✅ | ⬜ pending |
| 11-02-02 | 02 | 1 | GROUP-02 | — | N/A | smoke | `grep -r "noda.service-group" docker/docker-compose*.yml \| wc -l` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] 验证脚本：`docker compose config` 对所有 6 个 compose 文件执行通过
- [ ] 标签验证：`docker ps --filter "label=noda.service-group" --format json` 输出正确分组

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| 服务正常启动 | GROUP-01 | 需要实际部署环境 | 部署后 `docker compose ps` 确认所有服务 running |
| 容器分组过滤 | GROUP-02 | 需要运行中的容器 | `docker ps --filter "label=noda.service-group=apps" --format "{{.Names}}"` 应显示 findclass-ssr |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
