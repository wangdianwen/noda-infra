---
phase: 53-keycloak-doppler
plan: 03
subsystem: infra
tags: doppler, pre-prod, secrets-management, isolation, keycloak, postgresql

# Dependency graph
requires:
  - phase: 53-keycloak-doppler
    plan: 01
    provides: noda_preprod database and preprod_app user
  - phase: 53-keycloak-doppler
    plan: 02
    provides: noda-preprod Keycloak realm and pre.auth.noda.co.nz configuration
provides:
  - Doppler pre config with noda_preprod and noda-preprod isolation
  - Parameterized secrets.sh supporting DOPPLER_CONFIG environment variable
  - Pre-prod environment variable template (env-noda-apps-preprod.env)
  - Three-layer isolation verification script (database, Keycloak, Doppler)
affects: [Phase 54 - Pre-prod Pipeline, Phase 55 - Pre-prod Deployment]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - DOPPLER_CONFIG environment variable for config selection
    - CLI Token (dp.ct.*) vs Service Token (dp.st.*) validation
    - Three-sed-pattern DATABASE_URL replacement (trailing /, query params, trailing space)

key-files:
  created:
    - scripts/doppler-setup.sh
    - docker/env-noda-apps-preprod.env
    - scripts/verify-preprod-isolation.sh
  modified:
    - scripts/lib/secrets.sh

key-decisions:
  - "DOPPLER_TOKEN 为 CLI Token（dp.ct.*）才能执行 doppler-setup.sh，防止 Service Token 权限不足"
  - "DATABASE_URL 使用三模式 sed 替换覆盖所有 PostgreSQL URL 格式"
  - "DOPPLER_TOKEN 未设置时跳过 doppler-setup.sh 执行，仅完成文件创建（按计划要求）"

patterns-established:
  - "参数化 config 选择：DOPPLER_CONFIG 环境变量控制加载哪个 Doppler config"
  - "Token 类型校验：脚本启动时验证 DOPPLER_TOKEN 前缀（dp.ct. vs dp.st.）"
  - "三层数据隔离：数据库（noda_preprod）、Keycloak realm（noda-preprod）、Doppler config（pre）"

requirements-completed: [SEC-01]

# Metrics
duration: 2min
completed: 2026-05-08T03:42:15Z
---

# Phase 53 Plan 03: Doppler Pre Config + 隔离验证 Summary

**Doppler pre-prod config 初始化脚本，参数化密钥加载库，pre-prod 环境变量模板，三层隔离验证（数据库、Keycloak、Doppler）**

## Performance

- **Duration:** 2 min (101 seconds)
- **Started:** 2026-05-08T03:40:37Z
- **Completed:** 2026-05-08T03:42:15Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- **参数化 secrets.sh**：支持 DOPPLER_CONFIG 环境变量，默认 prd（向后兼容），日志显示实际 config 名称
- **Doppler pre config 初始化脚本**：doppler-setup.sh 从 prd 克隆创建 pre config，修改关键密钥（POSTGRES_DB、KEYCLOAK_REALM、DATABASE_URL、DIRECT_URL），创建 Service Token，验证 Token 类型（CLI Token only）
- **Pre-prod 环境变量模板**：env-noda-apps-preprod.env 指向 noda_preprod 数据库、noda-preprod realm、pre.auth.noda.co.nz
- **三层隔离验证脚本**：verify-preprod-isolation.sh 验证数据库、Keycloak、Doppler 隔离，包含 prod 安全检查

## Task Commits

Each task was committed atomically:

1. **Task 1: 参数化 secrets.sh + 创建 doppler-setup.sh + 创建 env-noda-apps-preprod.env** - `e0c64f4` (feat)
2. **Task 2: 创建 verify-preprod-isolation.sh** - `7811c0f` (feat)

**Plan metadata:** Pending final metadata commit

## Files Created/Modified

### Created
- `scripts/doppler-setup.sh` - Doppler pre config 初始化脚本（克隆 prd → pre，修改密钥，创建 Service Token，验证 Token 类型）
- `docker/env-noda-apps-preprod.env` - Pre-prod 环境变量模板（DATABASE_URL 指向 noda_preprod，KEYCLOAK_REALM=noda-preprod）
- `scripts/verify-preprod-isolation.sh` - 三层隔离验证脚本（数据库、Keycloak、Doppler）

### Modified
- `scripts/lib/secrets.sh` - 参数化 DOPPLER_CONFIG 环境变量，默认 prd（向后兼容）

## Deviations from Plan

None - plan executed exactly as written.

**Note:** DOPPLER_TOKEN 环境变量未设置，按计划要求跳过 doppler-setup.sh 执行，仅完成文件创建任务。脚本语法和配置验证全部通过。

## Issues Encountered

None - all verifications passed on first attempt.

## User Setup Required

### Doppler Pre Config 初始化（手动执行）

**前置条件：** 需要有效的 Doppler CLI Token（dp.ct.*）

```bash
# 1. 导入 CLI Token（Doppler Dashboard -> Settings -> CLI -> Generate Token）
export DOPPLER_TOKEN='dp.ct.xxx'

# 2. 执行初始化脚本（创建 pre config 并配置密钥）
bash scripts/doppler-setup.sh

# 3. 保存输出的 Service Token（后续配置到 Jenkins Credentials）
# Token 格式：dp.st.pre.xxx
```

### 隔离验证（初始化后执行）

```bash
# 使用 pre config Service Token 验证三层隔离
export DOPPLER_TOKEN='dp.st.pre.xxx'
bash scripts/verify-preprod-isolation.sh
```

**预期输出：** 所有检查项通过，exit 0

## Next Phase Readiness

### 已完成
- Doppler pre config 初始化脚本已创建，可手动执行
- Pre-prod 环境变量模板已创建
- 三层隔离验证脚本已创建
- secrets.sh 已参数化，支持 DOPPLER_CONFIG=pre

### 待手动完成
- 执行 doppler-setup.sh 创建 Doppler pre config（需要 DOPPLER_TOKEN）
- 执行 verify-preprod-isolation.sh 验证三层隔离

### 阻塞项
- Doppler pre config 必须在 Phase 54（Pre-prod Pipeline）之前创建（PIPE-01 需要 DOPPLER_CONFIG=pre）

### 下一阶段准备
- Phase 53 完成，进入 Phase 54（Pre-prod Pipeline）
- Pipeline 将使用 DOPPLER_CONFIG=pre 加载 pre-prod 密钥
- verify-preprod-isolation.sh 可作为 Pipeline 的验证阶段

---
*Phase: 53-keycloak-doppler*
*Plan: 03*
*Completed: 2026-05-08*
