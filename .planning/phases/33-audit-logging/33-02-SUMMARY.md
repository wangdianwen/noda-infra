---
phase: 33-audit-logging
plan: 02
status: complete
started: "2026-04-18"
completed: "2026-04-18"
---

## Plan 33-02: Jenkins Audit Trail 插件 + logrotate

### Objective
创建 Jenkins Audit Trail 插件安装 Groovy 脚本和 logrotate 轮转配置，实现 Jenkins Pipeline 触发事件的审计记录。

### What was built
- `scripts/jenkins/init.groovy.d/05-audit-trail.groovy` — Audit Trail 插件安装脚本
  - 遵循 02-plugins.groovy 模式（import、Update Center、幂等安装）
  - 插件 ID: audit-trail
  - 已安装跳过，不重复安装
  - setup-jenkins.sh 步骤 7 的 cp *.groovy 自动包含，无需修改
- `config/logrotate/jenkins-audit-trail` — 日志轮转配置
  - daily + rotate 14 + maxsize 50M
  - 路径: /var/lib/jenkins/audit-trail/*.log
  - 文件权限: 0640 jenkins jenkins

### Key Decisions
- File Logger 需要通过 Jenkins UI 手动配置（API 不稳定），脚本仅负责插件安装
- 插件安装后 Jenkins 需要重启（由 setup-jenkins.sh 处理）

### Requirements Traceability
- AUDIT-03: Jenkins Audit Trail 记录 Pipeline 触发事件

### Self-Check
- [x] groovy 脚本包含 audit-trail 插件 ID
- [x] groovy 脚本包含 getPlugin 幂等检查
- [x] groovy 脚本包含 deploy 调用
- [x] logrotate 配置 rotate 14
- [x] logrotate 配置 maxsize 50M
- [x] logrotate 路径 /var/lib/jenkins/audit-trail
