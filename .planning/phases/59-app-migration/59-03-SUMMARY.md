---
phase: 59-app-migration
plan: 03
subsystem: infra
tags: [docker, r4s, preprod, database-isolation]

requires:
  - phase: 59-02
    provides: "prod 容器运行、compose 经验、healthcheck 修复"
provides:
  - "noda-apps-preprod 容器运行 (healthy)"
  - "数据库隔离验证（prod=noda_prod, preprod=noda_preprod）"
affects: [60]

tech-stack:
  added: []
  patterns: [sed-envsubst-fallback, docker-run-preprod]

key-files:
  created: []
  modified: []

key-decisions:
  - "r4s 没有 envsubst，用 sed 替代环境变量替换"
  - "preprod 使用 docker run（非 compose）启动，--memory 512m"
  - "健康检查直接用 127.0.0.1（从 59-02 经验复用）"

patterns-established:
  - "Alpine 无 envsubst 时用 sed 做变量替换"

requirements-completed: [APP-02]

duration: 10min
completed: 2026-05-18
---

# Phase 59 Plan 03 Summary

**noda-apps-preprod 容器在 r4s 上启动，数据库隔离验证通过（noda_preprod vs noda_prod）**

## Performance

- **Duration:** ~10 min
- **Tasks:** 7

## Accomplishments

- preprod 容器 healthy，内存 293.4MiB/512MiB
- 数据库隔离确认：prod→noda_prod, preprod→noda_preprod
- 6 个容器全部运行（4 基础 + prod + preprod）
- r4s 内存充裕：2.3GB 可用

## Deviations from Plan

- `envsubst` 不存在于 r4s Alpine，改用 sed 替代
- 健康检查直接用 127.0.0.1（复用 59-02 的 IPv6 修复）

## Next Phase Readiness

- Phase 59 全部完成，可继续 Phase 60（CI/CD 改造）

---
*Phase: 59-app-migration*
*Completed: 2026-05-18*
