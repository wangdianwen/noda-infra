# Phase 33: 审计日志系统 - Context

**Gathered:** 2026-04-18
**Status:** Ready for planning

<domain>
## Phase Boundary

所有 docker 命令执行和 Jenkins Pipeline 操作被完整记录，日志不可篡改且不会占满磁盘。

**In scope:**
- auditd 内核审计规则：监控所有 docker 命令执行（含用户、时间、命令参数）
- auditd 日志保护：root 只读，普通用户不可篡改
- Jenkins Audit Trail 插件：记录 Pipeline 触发事件
- sudo 操作日志：通过 sudoers Defaults logfile 配置独立日志文件
- 日志轮转：所有审计日志源配置合理的保留策略，防止磁盘占满

**Out of scope:**
- setup-docker-permissions.sh 统一脚本（Phase 34）
- Jenkins 权限矩阵（Phase 34）
- 定期审计检查脚本（Future requirement）
- chattr +i 锁定关键配置文件（Future requirement）

</domain>

<decisions>
## Implementation Decisions

### 日志保留和轮转策略
- **D-01:** auditd 日志保留 30 天，Jenkins Audit Trail / sudo 日志保留 14 天
- 单文件最大 50MB，总审计日志磁盘预算 500MB
- auditd 使用自带 logrotate 机制（/etc/logrotate.d/auditd 或 auditd.conf max_log_file）
- Jenkins Audit Trail 通过 logrotate 管理轮转
- sudo 日志通过 logrotate 管理轮转

### Jenkins Audit Trail 粒度
- **D-02:** 仅记录 Pipeline 触发事件（谁触发了哪个 Job、时间、参数）
- 满足 AUDIT-03 要求的最小粒度
- 管理员配置变更等操作通过 auditd + sudo 日志追踪（不重复记录）
- 日志输出到 JENKINS_HOME/audit-trail/ 目录

### 审计日志目录结构
- **D-03:** 各组件使用系统默认路径，分散存放
  - auditd → `/var/log/audit/`（系统默认）
  - sudo → `/var/log/sudo-logs/`（sudoers Defaults logfile 配置）
  - Break-Glass → `/var/log/noda/break-glass.log`（Phase 32 已建立）
  - Jenkins Audit Trail → `$JENKINS_HOME/audit-trail/`
- Phase 34 setup-docker-permissions.sh 统一脚本将分别配置各路径的轮转和权限

### Claude's Discretion
- auditd 规则具体写法（watch /usr/bin/docker vs syscall 监控）
- Jenkins Audit Trail 插件的具体配置方式
- logrotate 配置文件的具体参数
- 安装/验证脚本的具体名称和存放位置

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 项目级规划
- `.planning/ROADMAP.md` — Phase 33 目标、依赖关系、成功标准
- `.planning/REQUIREMENTS.md` — AUDIT-01 至 AUDIT-04 详细需求
- `.planning/PROJECT.md` — 项目约束和决策历史

### 现有实现
- `scripts/break-glass.sh` — 已有 log_audit() 写入 /var/log/noda/break-glass.log（Phase 32 建立）
- `scripts/install-sudoers-whitelist.sh` — sudoers 规则安装脚本（Phase 32），可参考安装模式
- `scripts/setup-jenkins.sh` — Jenkins 安装配置脚本，需添加 Audit Trail 插件安装步骤
- `scripts/apply-file-permissions.sh` — 权限应用脚本模式可复用
- `scripts/lib/log.sh` — 项目日志函数库

### 前期阶段上下文
- `.planning/phases/31-docker-socket/31-CONTEXT.md` — Docker socket 权限收敛上下文
- `.planning/phases/32-sudoers-breakglass/32-CONTEXT.md` — sudoers 白名单 + Break-Glass 上下文

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/setup-jenkins.sh` — 已有 Jenkins 插件安装步骤（第 5 步），可添加 Audit Trail 插件安装
- `scripts/install-sudoers-whitelist.sh` — 安装/验证/卸载三件套模式，可复用于 auditd 规则安装
- `scripts/break-glass.sh` — log_audit() 函数和 /var/log/noda/ 目录结构已建立

### Established Patterns
- 安装脚本三件套模式：install/verify/uninstall 子命令（Phase 32 建立）
- 日志目录权限：640 root:jenkins（Phase 32 break-glass.log 模式）
- /etc/sudoers.d/ 目录放置自定义规则（Phase 32 建立）
- setup-jenkins.sh 步骤式安装（可添加 Audit Trail 插件步骤）

### Integration Points
- auditd 规则监控 /usr/bin/docker 执行（Phase 31 socket 属组收敛后，只有 jenkins 用户执行 docker）
- sudoers Defaults 需追加到 Phase 32 创建的 /etc/sudoers.d/noda-docker-readonly 文件或新建独立文件
- Jenkins Audit Trail 插件安装在 $JENKINS_HOME，日志存储在 $JENKINS_HOME/audit-trail/
- Phase 34 setup-docker-permissions.sh 将整合审计规则安装和验证

</code_context>

<specifics>
## Specific Ideas

- auditd 规则使用 `-k docker-cmd` key 标记（Success Criteria 1 要求 `ausearch -k docker-cmd` 可查询）
- sudo 日志通过在 sudoers 文件中添加 `Defaults logfile=/var/log/sudo-logs/sudo.log` 配置
- Jenkins Audit Trail 插件配置为仅记录 Pipeline 触发事件

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 33-audit-logging*
*Context gathered: 2026-04-18*
