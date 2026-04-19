# Phase 44: Jenkins 维护清理 + 定期任务 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-20
**Phase:** 44-jenkins-maintenance-cleanup
**Areas discussed:** Jenkins 清理策略, 定期任务实现方式

---

## Jenkins 清理策略

| Option | Description | Selected |
|--------|-------------|----------|
| 保留 numToKeep=20 + 添加 workspace 清理 | 保留现有配置不变，添加 workspace 清理函数 | ✓ |
| 减少 numToKeep + workspace 清理 | 将保留数减少到 10，同时添加 workspace 清理 | |
| 不需要额外清理 | 当前 numToKeep=20 已足够 | |

**User's choice:** 保留 numToKeep=20 + 添加 workspace 清理
**Notes:** JENK-01 已由现有 buildDiscarder 覆盖，只需新增 JENK-02 workspace 清理

---

## 定期任务实现方式

| Option | Description | Selected |
|--------|-------------|----------|
| crontab | 系统级 crontab，简单可靠 | |
| systemd timer | 更复杂但更灵活 | |
| Jenkins periodic build | 复用 cleanup.sh，依赖 Jenkins 持续运行 | ✓ |

**User's choice:** Jenkins periodic build
**Notes:** 新建独立 Jenkinsfile.cleanup，每周自动触发 + 支持手动强制执行

---

## Jenkinsfile 组织

| Option | Description | Selected |
|--------|-------------|----------|
| 新建独立 Jenkinsfile | 新建 Jenkinsfile.cleanup，职责分离 | ✓ |
| 复用现有 Jenkinsfile | 在现有 Jenkinsfile 中添加 periodic trigger | |

**User's choice:** 新建独立 Jenkinsfile
**Notes:** 保持部署和清理职责分离

---

## Claude's Discretion

- cleanup_jenkins_workspace() 的具体实现
- Jenkinsfile.cleanup 的阶段设计
- pnpm/npm 清理命令参数

## Deferred Ideas

None
