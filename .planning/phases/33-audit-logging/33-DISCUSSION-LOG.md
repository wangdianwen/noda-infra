# Phase 33: 审计日志系统 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-18
**Phase:** 33-audit-logging
**Areas discussed:** 日志保留和轮转策略, Jenkins Audit Trail 粒度, 审计日志目录结构

---

## 日志保留和轮转策略

| Option | Description | Selected |
|--------|-------------|----------|
| 保守保留（30/14天） | auditd 30天，Jenkins/sudo 14天，单文件50MB，总预算500MB | ✓ |
| 长期保留（90天） | 所有日志统一保留90天，单文件100MB，可能占1-2GB | |
| 最短保留（7天） | 所有日志仅保留7天，单文件20MB，审计窗口短 | |

**User's choice:** 保守保留（30/14天）
**Notes:** 平衡审计深度和磁盘占用，推荐方案

---

## Jenkins Audit Trail 粒度

| Option | Description | Selected |
|--------|-------------|----------|
| 仅 Pipeline 触发 | 只记录谁触发了哪个 Job、时间、参数。日志量小 | ✓ |
| Pipeline + 配置变更 | 增加 Job 配置修改、凭据变更、系统设置变更 | |
| 全量操作日志 | 所有 Jenkins 操作：触发+配置+登录+SCM变更 | |

**User's choice:** 仅 Pipeline 触发
**Notes:** 满足 AUDIT-03 最小要求，管理员活动通过 auditd + sudo 日志追踪

---

## 审计日志目录结构

| Option | Description | Selected |
|--------|-------------|----------|
| 分散存放（系统默认） | 各组件用系统默认路径，Phase 34 统一脚本分别配置 | ✓ |
| 统一目录 | 所有审计日志集中到 /var/log/noda/audit/，管理简单但配置复杂 | |

**User's choice:** 分散存放（系统默认）
**Notes:** auditd 系统默认 /var/log/audit/ 不宜修改，各组件保持默认路径

---

## Claude's Discretion

- auditd 规则具体写法（watch /usr/bin/docker vs syscall 监控）
- Jenkins Audit Trail 插件的具体配置方式
- logrotate 配置文件的具体参数
- 安装/验证脚本的具体名称和存放位置

## Deferred Ideas

None — discussion stayed within phase scope
