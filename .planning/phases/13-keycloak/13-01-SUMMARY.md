---
phase: 13-keycloak
plan: 01
subsystem: ui
tags: [keycloak, css, theme, patternfly, branding]

# Dependency graph
requires:
  - phase: 12-keycloak
    provides: 主题骨架文件（theme.properties + 空 styles.css）+ Docker 挂载配置
provides:
  - Noda 品牌色 CSS 覆盖（Pounamu Green #0D9B6A）
  - 修复 theme.properties（添加 styles=css/styles.css）
  - PatternFly v4 变量覆盖 + 直接选择器覆盖
affects: [keycloak-login, auth-noda-co-nz]

# Tech tracking
tech-stack:
  added: []
  patterns: [pf4-variable-override, direct-selector-override]

key-files:
  created: []
  modified:
    - docker/services/keycloak/themes/noda/login/theme.properties
    - docker/services/keycloak/themes/noda/login/resources/css/styles.css

key-decisions:
  - "使用 PatternFly v4 全局变量覆盖（:root 级别）批量修改主色，配合直接选择器覆盖硬编码值"
  - "使用 !important 仅在 login.css 硬编码值无法通过变量覆盖的位置（卡片边框、焦点环）"

patterns-established:
  - "CSS Override Pattern: :root 变量覆盖 + 直接选择器覆盖，最小化修改范围"

requirements-completed: [THEME-01, THEME-02]

# Metrics
duration: 6min
completed: 2026-04-11
---

# Phase 13 Plan 01: Keycloak Login Theme Brand Overrides Summary

**Noda 品牌主题 CSS 覆盖：修复 theme.properties 加载声明 + PatternFly v4 变量覆盖（Pounamu Green #0D9B6A）+ 直接选择器覆盖（卡片边框、焦点环、圆角 0.5rem）**

## Performance

- **Duration:** 6 min
- **Started:** 2026-04-11T04:07:52Z
- **Completed:** 2026-04-11T04:14:27Z
- **Tasks:** 2 of 3 complete（Task 3 为 checkpoint:human-verify，等待人工视觉验证）
- **Files modified:** 2

## Accomplishments
- 修复 theme.properties 添加 `styles=css/styles.css` 声明，解决 CSS 文件不被加载的阻塞性问题（Pitfall 1）
- 实现完整的 Noda 品牌色覆盖：PatternFly v4 全局变量（6 个变量）+ 直接选择器（7 个覆盖规则）
- Dev 环境 keycloak-dev 容器验证通过：登录页 HTML 正确引用 noda 主题 CSS，无外部 CDN 引用
- noda realm 创建成功并设置 loginTheme 为 noda

## Task Commits

1. **Task 1: 修复 theme.properties + 填充 styles.css 品牌色覆盖** - `f3bcf38` (feat)

## Files Created/Modified
- `docker/services/keycloak/themes/noda/login/theme.properties` - 添加 styles=css/styles.css 声明
- `docker/services/keycloak/themes/noda/login/resources/css/styles.css` - Noda 品牌色 CSS 覆盖（PatternFly v4 变量 + 直接选择器）

## Decisions Made
- 使用 PF4 全局变量覆盖（:root 级别）批量修改主色，减少代码量并提高可维护性
- `!important` 仅在 login.css 硬编码值无法通过变量覆盖的位置使用（卡片边框、焦点环）
- 不覆盖布局/间距/排版属性，保留 Keycloak 默认组件结构（遵循 D-05）

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- Dev 环境 noda realm 需要通过 Admin REST API 创建（keycloak-dev 使用独立 postgres-dev 数据库，与生产隔离）。已通过 curl 成功创建 noda realm 并设置 loginTheme 为 noda。
- Worktree 文件与 Docker 容器挂载路径不同（容器挂载主仓库路径），验证时需临时复制文件到主仓库路径。验证完成后已恢复主仓库文件为原始状态。

## Next Phase Readiness

- Task 1 和 Task 2 已完成，等待 Task 3 人工视觉验证
- 用户需在浏览器中访问 `http://localhost:18080/realms/noda/account` 验证品牌色效果
- 验证通过后，生产环境需在 Keycloak Admin Console 中将 noda realm 的 Login Theme 设置为 noda 并重启容器

---
*Phase: 13-keycloak*
*Completed: 2026-04-11*

## Self-Check: PASSED

- [x] theme.properties 文件存在
- [x] styles.css 文件存在
- [x] Commit f3bcf38 存在于 git log
- [x] theme.properties 包含 styles=css/styles.css
- [x] styles.css 包含 #0D9B6A 品牌色
- [x] styles.css 包含 0.5rem 圆角
