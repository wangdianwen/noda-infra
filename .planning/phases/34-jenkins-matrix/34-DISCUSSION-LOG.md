# Phase 34: Jenkins 权限矩阵 + 统一管理脚本 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-18
**Phase:** 34-jenkins-matrix
**Areas discussed:** Jenkins 权限矩阵角色设计, 统一脚本整合方式, rollback 回滚范围, verify 验证报告

---

## Jenkins 权限矩阵角色设计

| Option | Description | Selected |
|--------|-------------|----------|
| 两角色 | Admin（全权限）+ Developer（触发 Pipeline + 查看结果），简单明了，符合单服务器 1-2 人场景 | ✓ |
| 三角色 | Admin + Developer + Viewer（只读），多一个纯查看角色 | |

**User's choice:** 两角色（推荐）
**Notes:** 单服务器 1-2 管理员场景，三角色过度设计

### Developer 权限范围

| Option | Description | Selected |
|--------|-------------|----------|
| 最小权限 | 触发 Pipeline + 查看构建历史 + 查看 Console Output | ✓ |
| 标准权限 | 最小权限 + 取消构建 + SCM 变更 | |
| 宽松权限 | 标准权限 + 重新运行失败构建 + 配置构建参数 | |

**User's choice:** 最小权限（推荐）
**Notes:** 符合 Success Criteria 1 的严格要求

### 配置方式

| Option | Description | Selected |
|--------|-------------|----------|
| Groovy init 脚本 | 自动配置，复用 setup-jenkins.sh 已有模式，重启后自动生效 | ✓ |
| 手动 UI 配置 | 在 Jenkins UI 中手动配置，简单但不可重复 | |

**User's choice:** Groovy init 脚本（推荐）
**Notes:** 复用现有 Groovy 脚本模式，可重复执行

---

## 统一脚本整合方式

| Option | Description | Selected |
|--------|-------------|----------|
| 编排器模式 | setup-docker-permissions.sh 调用现有脚本的子命令，不重复实现逻辑 | ✓ |
| 函数库重写 | 抽取核心逻辑到共享函数库，重构现有脚本 | |

**User's choice:** 编排器模式（推荐）
**Notes:** 现有脚本保持独立可用，新脚本只负责编排顺序和汇总结果

### apply 执行顺序

| Option | Description | Selected |
|--------|-------------|----------|
| 按 Phase 顺序 | 31（socket + 文件权限）→ 32（sudoers）→ 33（auditd + sudo 日志）→ 34（Jenkins） | ✓ |
| 按功能分组 | 权限（31+32）→ 审计（33）→ Jenkins（34） | |

**User's choice:** 按 Phase 顺序（推荐）
**Notes:** 按依赖顺序，先确保基础设施权限就绪再配置审计和 Jenkins

---

## rollback 回滚范围

| Option | Description | Selected |
|--------|-------------|----------|
| 全量回滚 | 回滚 Phase 31-34 所有配置，恢复到 v1.6 前状态 | ✓ |
| 部分回滚 | 仅回滚 Phase 31-33，保留 Jenkins 权限矩阵 | |
| 无统一回滚 | 各脚本独立 uninstall，手动按需执行 | |

**User's choice:** 全量回滚（推荐）
**Notes:** 符合 Success Criteria 4 的要求

### 回滚安全

| Option | Description | Selected |
|--------|-------------|----------|
| 交互确认 | 回滚前强制输入 YES，显示回滚配置列表 | ✓ |
| 跳过确认 | 直接执行回滚，有误操作风险 | |

**User's choice:** 交互确认（推荐）
**Notes:** 回滚会放宽安全配置，必须有明确的用户确认

---

## verify 验证报告

### 输出格式

| Option | Description | Selected |
|--------|-------------|----------|
| 终端文本 | 每行 [PASS/FAIL] 检查项描述，简单明了 | ✓ |
| JSON 可选 | 结构化输出，加 --json 参数切换 | |

**User's choice:** 终端文本（推荐）
**Notes:** 简单明了，适合脚本解析和人工阅读

### 失败处理

| Option | Description | Selected |
|--------|-------------|----------|
| 快速失败 | 遇到第一个 FAIL 立即退出，返回非零状态码 | ✓ |
| 全量检查 | 运行所有检查，最后汇总 PASS/FAIL 计数 | |

**User's choice:** 快速失败（推荐）
**Notes:** 适合 CI/CD 集成

---

## Claude's Discretion

- Matrix Authorization Strategy 插件的具体安装方式
- Groovy init 脚本中权限矩阵的具体 API 调用
- verify 检查项的具体实现方式
- 脚本错误处理和日志格式
- macOS/Linux 双平台兼容

## Deferred Ideas

None — discussion stayed within phase scope
