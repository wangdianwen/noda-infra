# Phase 44: Jenkins 维护清理 + 定期任务 - Context

**Gathered:** 2026-04-20
**Status:** Ready for planning

<domain>
## Phase Boundary

Jenkins 旧构建清理（workspace 目录释放磁盘）+ pnpm/npm 定期清理 cron（Jenkins periodic build 触发）。

**涉及需求：** JENK-01, JENK-02, CACHE-02, CACHE-03

**前置条件：** Phase 43 已完成 — cleanup.sh 共享库已建立

</domain>

<decisions>
## Implementation Decisions

### Jenkins 清理策略
- **D-01:** 保留现有 `buildDiscarder(numToKeepStr: '20')` 不变。JENK-01 已由现有配置覆盖
- **D-02:** 新增 `cleanup_jenkins_workspace()` 函数到 cleanup.sh，清理 Jenkins workspace 中已完成构建的工作目录

### 定期任务实现
- **D-03:** 使用 Jenkins periodic build（非 crontab/systemd timer），新建 `jenkins/Jenkinsfile.cleanup` 独立 Pipeline
- **D-04:** Pipeline 每周自动触发（`triggers { cron('0 3 * * 1') }`，每周一凌晨 3 点），同时支持手动触发参数 `FORCE=true` 强制执行

### Pipeline 功能
- **D-05:** Jenkinsfile.cleanup 复用 cleanup.sh 中的函数：pnpm store prune + npm cache clean + workspace 清理
- **D-06:** Pipeline 参数 `FORCE=true` 时忽略 7 天间隔限制，立即执行清理

### Claude's Discretion
- cleanup_jenkins_workspace() 的具体实现（遍历策略、目录判断逻辑）
- Jenkinsfile.cleanup 的 Pipeline 阶段设计
- pnpm store prune 和 npm cache clean 的具体命令参数
- 日志输出格式

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 需求定义
- `.planning/REQUIREMENTS.md` §JENK-01, JENK-02, CACHE-02, CACHE-03 — Phase 44 涉及的所有需求
- `.planning/ROADMAP.md` §Phase 44 — 目标、依赖、成功标准

### 现有实现（必须参考）
- `scripts/lib/cleanup.sh` — 现有清理库，需扩展 workspace 清理函数
- `jenkins/Jenkinsfile.findclass-ssr` — 现有 Jenkinsfile 模式参考（buildDiscarder、参数定义）
- `jenkins/Jenkinsfile.infra` — Infra Pipeline 模式参考

### 前序 Phase 决策
- `.planning/phases/43-cleanup-pipeline/43-CONTEXT.md` — cleanup.sh 架构和 Source Guard 模式

</canonical_refs>

<code_context>
## Existing Code Insights

### 当前状态
- 所有 4 个 Jenkinsfile 已有 `buildDiscarder(logRotator(numToKeepStr: '20'))`
- 无 crontab（`crontab -l` 为空）
- pnpm 10.29.3 + npm 11.7.0 已安装
- cleanup.sh 已有 Docker/Node.js/文件清理函数，需扩展 Jenkins workspace 清理

### Established Patterns
- Jenkins Declarative Pipeline 语法（所有 Jenkinsfile 统一）
- cleanup.sh Source Guard 模式
- `|| true` 确保清理失败不传播

### Integration Points
- `scripts/lib/cleanup.sh` — 添加 `cleanup_jenkins_workspace()` 和 `cleanup_pnpm_store()` / `cleanup_npm_cache()` 函数
- `jenkins/Jenkinsfile.cleanup` — 新文件，定期清理 Pipeline

</code_context>

<specifics>
## Specific Ideas

- Jenkins workspace 清理目标：`/var/lib/jenkins/workspace/` 下已完成构建的工作目录
- pnpm store prune：`pnpm store prune` 命令，移除未引用的包
- npm cache clean：`npm cache clean --force`
- Jenkins cron trigger 语法：`cron('0 3 * * 1')` = 每周一 03:00

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---
*Phase: 44-jenkins-maintenance-cleanup*
*Context gathered: 2026-04-20*
