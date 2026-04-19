---
phase: 45-infra-image-cleanup
plan: 02
subsystem: infra
tags: [docker, jenkins, cleanup, verification]

requires:
  - phase: 45-infra-image-cleanup
    plan: 01
    provides: split case branches with cleanup_by_date_threshold for noda-ops
provides:
  - E2E verification of noda-ops cleanup in Jenkins Pipeline
  - nginx cleanup code verified via code review (Pipeline blocked by pre-existing DNS issue)
affects: [infra-deploy, noda-ops, nginx]

tech-stack:
  added: []
  patterns: []

key-files:
  created: []
  modified: []

key-decisions:
  - "noda-ops Pipeline verification passed: cleanup_by_date_threshold called correctly"
  - "nginx Pipeline blocked by pre-existing DNS resolution failure (findclass-ssr-blue upstream), unrelated to Phase 45"

patterns-established: []

requirements-completed: [IMG-01, IMG-02]

duration: 15min
completed: 2026-04-19
---

# Phase 45: Infra Image Cleanup Summary — Plan 02

**E2E verification: noda-ops cleanup_by_date_threshold confirmed in Pipeline logs; nginx cleanup verified via code review**

## Performance

- **Duration:** 15 min
- **Started:** 2026-04-19
- **Completed:** 2026-04-19
- **Tasks:** 1 (partial — nginx Pipeline blocked by pre-existing issue)
- **Files modified:** 0

## Accomplishments
- noda-ops infra Pipeline (build #7) ran successfully with `cleanup_by_date_threshold "noda-ops"` in Cleanup stage
- Build logs confirm: "镜像清理: 清理 noda-ops 未使用的旧镜像..."
- postgres_data volume verified safe after Pipeline runs
- noda-ops image list clean: only `latest` tag remains after cleanup
- nginx cleanup code verified via code review (case branch outputs "无需额外清理（dangling 清理由通用 wrapper 处理）")

## Issues Encountered

### nginx Pipeline DNS Resolution Failure (PRE-EXISTING, NOT Phase 45 related)

**Problem:** nginx infra Pipeline (builds #8, #9, #10) failed with `host not found in upstream "findclass_backend"`. The `upstream-findclass.conf` references `findclass-ssr-blue:3001`, but after `--force-recreate`, the Docker DNS cannot resolve the hostname at nginx startup time.

**Root cause:** nginx `--force-recreate` creates a new container that must resolve all upstream hostnames at startup. If Docker DNS hasn't propagated for `findclass-ssr-blue`, nginx fails to start and enters a restart loop.

**Fix:** Manually running `docker compose up -d --force-recreate --no-deps nginx` resolves the issue (DNS is available by that time).

**Action needed:** Separate from Phase 45 — nginx upstream configuration needs blue-green deployment support (dynamic upstream switching) to prevent this DNS race condition.

## Next Phase Readiness
- Phase 45 code changes verified for noda-ops
- nginx cleanup verified via code review
- Outstanding: nginx Pipeline DNS issue needs separate fix (blue-green upstream support)

---
*Phase: 45-infra-image-cleanup*
*Completed: 2026-04-19*
