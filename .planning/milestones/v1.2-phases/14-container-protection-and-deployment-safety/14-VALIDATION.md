---
phase: 14
slug: container-protection-and-deployment-safety
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-11
---

# Phase 14 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash / shellcheck + docker compose config validate |
| **Config file** | none — inline validation commands |
| **Quick run command** | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml config --quiet` |
| **Full suite command** | `shellcheck scripts/deploy/*.sh && docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml config` |
| **Estimated runtime** | ~10 seconds |

---

## Sampling Rate

- **After every task commit:** Run `docker compose config --quiet`
- **After every plan wave:** Run `shellcheck` + `docker compose config` + nginx config test
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 14-01-01 | 01 | 1 | D-01 | — | security_opt + cap_drop + read_only in prod overlay | config | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml config \| grep -c no-new-privileges` | ❌ W0 | ⬜ pending |
| 14-01-02 | 01 | 1 | D-02 | — | non-root user in Dockerfiles | file | `grep -c 'USER ' deploy/Dockerfile.noda-ops` | ❌ W0 | ⬜ pending |
| 14-02-01 | 02 | 1 | D-03 | — | logging config for all containers | config | `docker compose config \| grep -c 'max-size'` | ❌ W0 | ⬜ pending |
| 14-02-02 | 02 | 1 | D-04 | — | stop_grace_period for all services | config | `docker compose config \| grep -c 'stop_grace_period'` | ❌ W0 | ⬜ pending |
| 14-03-01 | 03 | 2 | D-05 | — | image tag save before deploy | file | `grep -c 'save_image_tags\|image_tags' scripts/deploy/deploy-infrastructure-prod.sh` | ❌ W0 | ⬜ pending |
| 14-03-02 | 03 | 2 | D-06 | — | auto backup before deploy | file | `grep -c 'backup-postgres' scripts/deploy/deploy-infrastructure-prod.sh` | ❌ W0 | ⬜ pending |
| 14-04-01 | 04 | 2 | D-07 | — | nginx upstream with retry | config | `grep -c 'proxy_next_upstream' config/nginx/conf.d/default.conf` | ❌ W0 | ⬜ pending |
| 14-04-02 | 04 | 2 | D-08 | — | custom error page | file | `test -f config/nginx/errors/50x.html` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `shellcheck` — lint all shell scripts
- [ ] nginx config syntax — `docker run --rm nginx nginx -t`

*Existing infrastructure (docker compose config validation) covers most phase requirements.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Container actually runs as non-root | D-02 | Requires running container | `docker exec noda-ops id` — verify uid != 0 |
| Rollback actually restores previous image | D-05 | Requires deploy failure simulation | Deploy → force failure → verify rollback → check container image |
| Nginx upstream failover works | D-07 | Requires backend down | Stop findclass-ssr → curl class.noda.co.nz → verify error page or recovery |
| Custom error page displays | D-08 | Requires backend down | Stop backend → curl → verify HTML content |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
