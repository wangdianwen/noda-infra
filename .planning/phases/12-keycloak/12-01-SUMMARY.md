---
phase: 12-keycloak
plan: 01
subsystem: infra
tags: [keycloak, docker, dev-environment, themes]

# Dependency graph
requires:
  - phase: 11-service-integration
    provides: docker-compose.dev.yml with postgres-dev service
provides:
  - keycloak-dev 独立开发容器（start-dev 模式，18080/19000 端口）
  - keycloak_dev 独立数据库（postgres-dev:5432）
  - 主题热重载目录骨架
affects: [13-主题开发, keycloak-configuration]

# Tech tracking
tech-stack:
  added: [keycloak-dev start-dev mode]
  patterns: [dev/prod keycloak isolation, localhost-only port binding]

key-files:
  created:
    - docker/services/keycloak/themes/noda/login/theme.properties
    - docker/services/keycloak/themes/noda/login/resources/css/styles.css
  modified:
    - docker/docker-compose.dev.yml

key-decisions:
  - "主题挂载路径修正为 themes/noda 而非 themes，避免双层嵌套"
  - "健康检查使用 8080 端口而非 9000（start-dev 不监听管理端口）"

patterns-established:
  - "keycloak-dev 服务独立于生产 keycloak，使用独立数据库和端口"

requirements-completed: [KCDEV-01, KCDEV-02, KCDEV-03]

# Metrics
duration: 14min
completed: 2026-04-11
---

# Phase 12 Plan 01: Keycloak 开发环境搭建 Summary

**keycloak-dev 独立容器（start-dev 模式）连接 keycloak_dev 数据库，主题目录热重载挂载，与生产完全隔离**

## Performance

- **Duration:** 14 min
- **Started:** 2026-04-11T02:19:18Z
- **Completed:** 2026-04-11T02:33:00Z
- **Tasks:** 2/3 completed（Task 3 为 checkpoint:human-verify，等待人工验证）
- **Files modified:** 3

## Accomplishments
- keycloak-dev 容器成功启动并健康运行，使用 start-dev 模式
- Admin Console 在 http://localhost:18080/ 可达（返回 302）
- keycloak_dev 数据库 schema 自动创建（Keycloak 自动初始化）
- 主题目录正确挂载到 /opt/keycloak/themes/noda/login/
- 端口仅绑定 127.0.0.1，不暴露公网

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建主题目录骨架 + 添加 keycloak-dev 服务** - `467c70f` (feat)
2. **Task 2: 启动 keycloak-dev 并验证服务运行** - `600cbd1` (fix)

## Files Created/Modified
- `docker/services/keycloak/themes/noda/login/theme.properties` - 主题配置（parent=keycloak）
- `docker/services/keycloak/themes/noda/login/resources/css/styles.css` - 主题 CSS 占位文件
- `docker/docker-compose.dev.yml` - 新增 keycloak-dev 服务定义

## Decisions Made
- 主题挂载路径从 `./services/keycloak/themes` 修正为 `./services/keycloak/themes/noda`，避免容器内双层 noda 目录嵌套
- 健康检查从 TCP 9000 端口改为 TCP 8080 端口，因为 start-dev 模式不监听 9000 管理端口

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] 修正主题目录挂载路径**
- **Found during:** Task 2（启动 keycloak-dev 并验证服务运行）
- **Issue:** 计划中指定 `./services/keycloak/themes:/opt/keycloak/themes/noda` 导致双层嵌套（themes/noda/noda/login/），Keycloak 主题发现机制无法正确定位主题
- **Fix:** 修改挂载路径为 `./services/keycloak/themes/noda:/opt/keycloak/themes/noda`
- **Files modified:** docker/docker-compose.dev.yml
- **Verification:** `docker exec noda-infra-keycloak-dev ls /opt/keycloak/themes/noda/login/` 显示 theme.properties 和 resources
- **Committed in:** 600cbd1

**2. [Rule 1 - Bug] 修正健康检查端口**
- **Found during:** Task 2（启动 keycloak-dev 并验证服务运行）
- **Issue:** start-dev 模式下 Keycloak 不监听 9000 管理端口，健康检查一直失败（starting -> unhealthy）
- **Fix:** 健康检查从 TCP 9000 改为 TCP 8080
- **Files modified:** docker/docker-compose.dev.yml
- **Verification:** 容器在约 20 秒内变为 healthy 状态
- **Committed in:** 600cbd1

**3. [Rule 3 - Blocking] 手动创建 keycloak_dev 数据库**
- **Found during:** Task 2（启动 keycloak-dev 并验证服务运行）
- **Issue:** postgres-dev 容器的 init-dev 脚本只在首次创建数据卷时执行，现有数据卷中没有 keycloak_dev 数据库
- **Fix:** 手动执行 `docker exec noda-infra-postgres-dev psql -U postgres -c "CREATE DATABASE keycloak_dev;"`
- **Files modified:** 无（运行时操作）
- **Verification:** Keycloak 成功连接并初始化 schema
- **Committed in:** 无（运行时操作，不需要提交）

---

**Total deviations:** 3 auto-fixed（2 Rule 1 bugs, 1 Rule 3 blocking）
**Impact on plan:** 所有修复都是必要的正确性修正。计划中的挂载路径和健康检查配置不适用于 start-dev 模式。

## Issues Encountered
- 环境变量需要通过 `--env-file` 显式指定路径（worktree 中没有 .env 文件）
- postgres-dev 数据卷已存在但缺少 keycloak_dev 数据库（init 脚本不重复执行）

## User Setup Required
None - 无外部服务配置需要。

## Next Phase Readiness
- keycloak-dev 容器运行正常，等待人工验证 Admin Console 登录和主题热重载
- Task 3 (checkpoint:human-verify) 需要人工验证后方可继续后续计划

---
*Phase: 12-keycloak*
*Completed: 2026-04-11*

## Self-Check: PASSED

- FOUND: docker/services/keycloak/themes/noda/login/theme.properties
- FOUND: docker/services/keycloak/themes/noda/login/resources/css/styles.css
- FOUND: docker/docker-compose.dev.yml
- FOUND: .planning/phases/12-keycloak/12-01-SUMMARY.md
- FOUND: 467c70f (Task 1 commit)
- FOUND: 600cbd1 (Task 2 commit)
