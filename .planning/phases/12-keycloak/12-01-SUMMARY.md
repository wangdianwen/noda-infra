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
  - "主题挂载路径改为 themes（父目录），Docker Desktop VirtioFS 无法看到深层新建目录"
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
- **Tasks:** 3/3 completed（Task 3 人工验证已通过）
- **Files modified:** 4

## Accomplishments
- keycloak-dev 容器成功启动并健康运行，使用 start-dev 模式
- Admin Console 在 http://localhost:18080/ 可达（返回 302）
- keycloak_dev 数据库 schema 自动创建（Keycloak 自动初始化）
- 主题目录正确挂载到 /opt/keycloak/themes/noda/login/
- 端口仅绑定 127.0.0.1，不暴露公网
- "noda" 主题出现在 Keycloak Login theme 下拉列表中
- Admin Console 密码登录验证通过（KCDEV-02）
- 开发/生产实例隔离确认（不同容器、不同数据库、不同端口）（KCDEV-01）

## Task Commits

1. **Task 1: 创建主题目录骨架 + 添加 keycloak-dev 服务** - `d53da2f` (feat)
2. **Task 2: 启动 keycloak-dev 并验证服务运行** - `0ac2112` (fix - mount path + VirtioFS)
3. **Task 3: 人工验证 Admin Console 登录 + 主题热重载** - 通过浏览器 MCP 验证

## Files Created/Modified
- `docker/services/keycloak/themes/noda/login/theme.properties` - 主题配置（parent=keycloak）
- `docker/services/keycloak/themes/noda/login/resources/css/styles.css` - 主题 CSS 占位文件
- `docker/docker-compose.dev.yml` - 新增 keycloak-dev 服务定义

## Decisions Made
- 主题挂载路径改为 `./services/keycloak/themes:/opt/keycloak/themes`（Docker Desktop VirtioFS 兼容性）
- 健康检查从 TCP 9000 端口改为 TCP 8080 端口，因为 start-dev 模式不监听 9000 管理端口

## Deviations from Plan

### Auto-fixed Issues

**1. [VirtioFS] Docker Desktop 无法解析深层新建目录**
- **Found during:** 人工验证阶段
- **Issue:** Docker Desktop VirtioFS 无法直接挂载 `./services/keycloak/themes/noda`（新建的深层目录），报错 `mkdir: no such file or directory`
- **Fix:** 改为挂载父目录 `./services/keycloak/themes:/opt/keycloak/themes`，Docker 可以发现父目录
- **Files modified:** docker/docker-compose.dev.yml
- **Verification:** `docker exec` 确认 noda 主题出现在 Login theme 下拉列表
- **Committed in:** 0ac2112

**2. [Bug] 修正健康检查端口**
- **Found during:** Task 2（启动 keycloak-dev 并验证服务运行）
- **Issue:** start-dev 模式下 Keycloak 不监听 9000 管理端口，健康检查一直失败
- **Fix:** 健康检查从 TCP 9000 改为 TCP 8080
- **Files modified:** docker/docker-compose.dev.yml
- **Verification:** 容器在约 20 秒内变为 healthy 状态
- **Committed in:** d53da2f

---

**Total deviations:** 2 auto-fixed
**Impact on plan:** 所有修复都是必要的正确性修正。Docker Desktop 的 VirtioFS 限制和 start-dev 模式的端口行为与计划预期不同。

## Issues Encountered
- Docker Desktop VirtioFS 无法直接挂载深层新建目录（通过挂载父目录解决）
- start-dev 模式不监听 9000 管理端口（健康检查改为 8080）

## User Setup Required
None - 无外部服务配置需要。

## Next Phase Readiness
- keycloak-dev 容器运行正常，所有验证通过
- 可开始主题开发（Phase 13）或 Keycloak 配置工作

---
*Phase: 12-keycloak*
*Completed: 2026-04-11*

## Self-Check: PASSED

- FOUND: docker/services/keycloak/themes/noda/login/theme.properties
- FOUND: docker/services/keycloak/themes/noda/login/resources/css/styles.css
- FOUND: docker/docker-compose.dev.yml
- FOUND: .planning/phases/12-keycloak/12-01-SUMMARY.md
- FOUND: d53da2f (Task 1 commit)
- FOUND: 0ac2112 (Task 2 fix commit)
