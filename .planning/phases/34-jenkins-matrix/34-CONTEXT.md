# Phase 34: Jenkins 权限矩阵 + 统一管理脚本 - Context

**Gathered:** 2026-04-18
**Status:** Ready for planning

<domain>
## Phase Boundary

Jenkins 内部权限细化（管理员全权限/普通用户只触发），权限配置可通过统一脚本 `setup-docker-permissions.sh` 一键 apply/verify/rollback。

**In scope:**
- Matrix Authorization Strategy 插件安装 + Groovy init 脚本自动配置
- 两角色权限矩阵：Admin（全权限）+ Developer（最小权限：触发 Pipeline + 查看结果）
- `setup-docker-permissions.sh` 编排器脚本，整合 Phase 31-33 所有配置
- apply/verify/rollback 三个子命令
- verify 输出终端文本格式，快速失败

**Out of scope:**
- 定期审计检查脚本（Future requirement）
- chattr +i 锁定关键配置文件（Future requirement）
- LDAP/OIDC 外部认证集成（Out of Scope in REQUIREMENTS.md）
- Jenkins H2 → PostgreSQL 迁移（v1.7 范围）

</domain>

<decisions>
## Implementation Decisions

### Jenkins 权限矩阵角色设计
- **D-01:** 两角色方案：Admin（全权限）+ Developer（最小权限）
- **D-02:** Developer 权限范围：触发 Pipeline（Job/Build）+ 查看构建历史（Job/Read）+ 查看 Console Output（Run/Read）
- **D-03:** Developer 不能：修改 Job 配置、访问凭证、修改系统设置、访问 Script Console、删除构建
- **D-04:** 权限矩阵通过 Groovy init 脚本自动配置（复用 setup-jenkins.sh 已有的 Groovy 脚本模式）

### 统一脚本整合方式
- **D-05:** `setup-docker-permissions.sh` 作为编排器（orchestrator），调用现有脚本的子命令
- **D-06:** 现有脚本保持独立可用，不重复实现逻辑
- **D-07:** apply 执行顺序按 Phase 顺序：31（socket + 文件权限）→ 32（sudoers）→ 33（auditd + sudo 日志）→ 34（Jenkins 权限矩阵）

### rollback 回滚范围
- **D-08:** 全量回滚：恢复 Phase 31-34 所有配置到 v1.6 前的状态
- **D-09:** 回滚前强制交互确认（输入 YES），显示将要回滚的配置列表
- **D-10:** rollback 通过调用各独立脚本的 uninstall/undo 子命令实现

### verify 验证报告
- **D-11:** 输出格式为终端文本：每行 `[PASS/FAIL] 检查项描述`
- **D-12:** 快速失败模式：遇到第一个 FAIL 立即退出并返回非零状态码
- **D-13:** 检查项覆盖所有 Phase 31-34 的配置：socket 属组、文件权限、sudoers 规则、auditd 规则、sudo 日志、Jenkins 权限矩阵

### Claude's Discretion
- Matrix Authorization Strategy 插件的具体安装方式（Groovy 脚本 vs CLI）
- Groovy init 脚本中权限矩阵的具体 API 调用
- verify 检查项的具体实现方式
- 脚本错误处理和日志格式
- macOS/Linux 双平台兼容（复用现有模式）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 项目级规划
- `.planning/ROADMAP.md` — Phase 34 目标、依赖关系、成功标准
- `.planning/REQUIREMENTS.md` — JENKINS-03, JENKINS-04, PERM-05 详细需求
- `.planning/PROJECT.md` — 已锁定决策（Socket 属组方案 A、Pipeline 零代码修改）

### 现有实现（被整合的脚本）
- `scripts/apply-file-permissions.sh` — Phase 31 权限应用脚本（apply/verify/hook 子命令）
- `scripts/undo-permissions.sh` — Phase 31 最小回滚脚本（backup/undo 子命令）
- `scripts/install-sudoers-whitelist.sh` — Phase 32 sudoers 白名单（install/verify/uninstall 子命令）
- `scripts/install-auditd-rules.sh` — Phase 33 auditd 规则（install/verify/uninstall 子命令）
- `scripts/install-sudo-log.sh` — Phase 33 sudo 日志（install/verify/uninstall 子命令）
- `scripts/setup-jenkins.sh` — Jenkins 安装脚本，已有 Groovy 脚本模式可复用
- `scripts/break-glass.sh` — Phase 32 Break-Glass 脚本

### 前期阶段上下文
- `.planning/phases/31-docker-socket/31-CONTEXT.md` — Docker socket 权限收敛上下文
- `.planning/phases/32-sudoers-breakglass/32-CONTEXT.md` — sudoers 白名单 + Break-Glass 上下文
- `.planning/phases/33-audit-logging/33-CONTEXT.md` — 审计日志系统上下文

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/setup-jenkins.sh` — 已有 Groovy 脚本模式（第 6 步安全域配置），可复用相同模式安装 Matrix Authorization Strategy 插件和配置权限矩阵
- `scripts/apply-file-permissions.sh` — 已有 apply/verify 子命令模式，编排器可直接调用
- `scripts/install-sudoers-whitelist.sh` — 已有 install/verify/uninstall 三件套模式
- `scripts/install-auditd-rules.sh` + `scripts/install-sudo-log.sh` — 同上模式
- `scripts/undo-permissions.sh` — 已有 backup + undo 回滚模式
- `scripts/lib/log.sh` — 项目日志函数库

### Established Patterns
- 编排器模式：新脚本调用现有脚本的子命令（不重复实现逻辑）
- 安装脚本三件套：install/verify/uninstall（Phase 32-33 已建立）
- Groovy init 脚本：setup-jenkins.sh 中的 Groovy 自动化模式
- 日志目录权限：640 root:jenkins
- macOS/Linux 双平台兼容（detect_platform 函数模式）
- root 权限执行（sudo bash scripts/...）

### Integration Points
- setup-docker-permissions.sh 整合 4 个独立脚本的子命令
- Jenkins 权限矩阵通过 Groovy init 脚本配置（$JENKINS_HOME/init.groovy.d/）
- rollback 调用各脚本的 uninstall/undo 子命令，按反序执行（34 → 33 → 32 → 31）
- verify 汇总所有脚本的 verify 子命令结果

</code_context>

<specifics>
## Specific Ideas

- Admin 角色：Overall/Administer（全权限）
- Developer 角色：Overall/Read + Job/Read + Job/Build + Run/Read（最小权限）
- setup-docker-permissions.sh 子命令：apply（编排 Phase 31→32→33→34）、verify（汇总所有检查）、rollback（反序 34→33→32→31 + 交互确认）
- verify 输出格式：`[PASS] Docker socket 属组为 root:jenkins` 或 `[FAIL] Docker socket 属组为 root:docker（期望 root:jenkins）`

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 34-jenkins-matrix*
*Context gathered: 2026-04-18*
