---
phase: 19-jenkins
plan: 02
subsystem: infra
tags: [jenkins, groovy, init-scripts, ci-cd, security]

# Dependency graph
requires:
  - phase: 19-jenkins/01
    provides: "setup-jenkins.sh install 子命令会复制 groovy 脚本到 JENKINS_HOME/init.groovy.d/"
provides:
  - "init.groovy.d 脚本实现 Jenkins 首次启动自动化配置（管理员用户、插件、安全策略、Pipeline 作业）"
  - "管理员凭据模板文件 jenkins-admin.env.example"
affects: [19-jenkins, phase-23-jenkinsfile]

# Tech tracking
tech-stack:
  added: [jenkins-init-groovy, HudsonPrivateSecurityRealm, UpdateCenter API]
  patterns: [init.groovy.d-first-boot-automation, idempotent-groovy-scripts, env-file-credentials]

key-files:
  created:
    - scripts/jenkins/init.groovy.d/01-security.groovy
    - scripts/jenkins/init.groovy.d/02-plugins.groovy
    - scripts/jenkins/init.groovy.d/03-pipeline-job.groovy
    - scripts/jenkins/config/jenkins-admin.env.example
    - scripts/jenkins/config/.gitignore
  modified: []

key-decisions:
  - "管理员凭据从 .admin.env 文件读取，回退到环境变量，无凭据时跳过安全配置并打印警告"
  - "01-security.groovy 先 setSecurityRealm 再 getUser，确保用户存在性检查正确"
  - "Pipeline 作业使用 createProjectFromXML 而非 WorkflowJob 构造器，更可靠"

patterns-established:
  - "Groovy 脚本幂等模式: 所有操作先检查存在性再执行（用户/插件/作业）"
  - "凭据文件保护模式: .example 模板入库 + .gitignore 排除实际凭据"

requirements-completed: [JENK-04]

# Metrics
duration: 3min
completed: 2026-04-14
---

# Phase 19 Plan 02: Jenkins 首次启动自动化配置 Summary

**3 个 init.groovy.d 脚本实现 Jenkins 首次启动自动化：管理员用户创建 + CSRF 保护 + 5 个插件安装 + noda-apps-deploy Pipeline 作业预创建**

## Performance

- **Duration:** 3 min
- **Started:** 2026-04-14T11:19:36Z
- **Completed:** 2026-04-14T11:22:37Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- 创建 3 个幂等 Groovy 脚本，实现 Jenkins 首次启动全自动化配置
- 安全脚本包含管理员用户创建、CSRF 保护、禁用匿名读取、跳过 Setup Wizard
- 插件脚本安装 Git、Pipeline、Pipeline Stage View、Credentials Binding、Timestamper 5 个必需插件
- Pipeline 作业脚本预创建 noda-apps-deploy 占位作业（Phase 23 填充实际 Jenkinsfile）
- 管理员凭据模板文件 + .gitignore 保护，防止实际凭据入库

## Task Commits

Each task was committed atomically:

1. **Task 1: 创建 3 个 Groovy 脚本** - `28754f0` (feat)
2. **Task 2: 创建凭据模板 + .gitignore** - `9fdf92c` (feat)

## Files Created/Modified
- `scripts/jenkins/init.groovy.d/01-security.groovy` - 管理员用户创建 + CSRF 保护 + 禁用匿名读取 + 跳过 Setup Wizard
- `scripts/jenkins/init.groovy.d/02-plugins.groovy` - 安装 5 个必需插件（幂等检查）
- `scripts/jenkins/init.groovy.d/03-pipeline-job.groovy` - 预创建 noda-apps-deploy Pipeline 占位作业
- `scripts/jenkins/config/jenkins-admin.env.example` - 管理员凭据模板（JENKINS_ADMIN_USER + JENKINS_ADMIN_PASSWORD）
- `scripts/jenkins/config/.gitignore` - 排除 jenkins-admin.env 实际凭据文件

## Decisions Made

1. **先 setSecurityRealm 再 getUser** - 01-security.groovy 中必须先调用 `instance.setSecurityRealm(hudsonRealm)` 再调用 `hudsonRealm.getUser(adminUser)`，否则 getUser 始终返回 null（因为默认 SecurityRealm 不是 HudsonPrivateSecurityRealm）
2. **createProjectFromXML 而非 WorkflowJob 构造器** - 03-pipeline-job.groovy 使用 XML 配置创建作业，比直接构造 WorkflowJob 更可靠（自动处理 config.xml 持久化）
3. **无凭据时安全跳过** - 01-security.groovy 在无法获取管理员密码时打印警告并 return，不阻止 Jenkins 启动（对应 T-19-07 威胁模型：accept 处置）

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Groovy 脚本就绪，等待 Plan 01 的 setup-jenkins.sh install 子命令集成
- Phase 23 将填充 noda-apps-deploy Pipeline 作业的实际 Jenkinsfile 内容

---
*Phase: 19-jenkins*
*Completed: 2026-04-14*

## Self-Check: PASSED

- All 5 created files verified on disk
- Both task commits (28754f0, 9fdf92c) verified in git log
- SUMMARY.md created at .planning/phases/19-jenkins/19-02-SUMMARY.md
