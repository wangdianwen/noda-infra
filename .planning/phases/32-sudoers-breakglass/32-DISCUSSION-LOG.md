# Phase 32: sudoers 白名单 + Break-Glass 紧急机制 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-18
**Phase:** 32-sudoers-breakglass
**Areas discussed:** Break-Glass 验证方式, Jenkins 可用性判断, Break-Glass 操作范围, docker exec 归类

---

## Break-Glass 验证方式

| Option | Description | Selected |
|--------|-------------|----------|
| sudo 密码复用 | 管理员输入自己的 sudo 密码，复用 PAM 认证，零额外配置 | ✓ |
| 独立密码文件 | 创建 /opt/noda/break-glass-passphrase.sha256，独立密码管理 | |
| 仅组员身份检查 | 只检查用户是否在 admin 组，无需密码 | |

**User's choice:** sudo 密码复用
**Notes:** 复用现有系统认证机制，安全性由 PAM 保证，零额外运维成本

---

## Jenkins 可用性判断

| Option | Description | Selected |
|--------|-------------|----------|
| HTTP 健康检查 | curl Jenkins API 端点，超时或非 200 即认为不可用 | ✓ |
| 进程检查 | pgrep -f jenkins.war 检查进程存在 | |
| 双层检查 | 同时检查进程和 HTTP 端点 | |

**User's choice:** HTTP 健康检查
**Notes:** 能检测进程存在但服务异常的情况（OOM、线程死锁等），比进程检查更可靠

---

## Break-Glass 操作范围

| Option | Description | Selected |
|--------|-------------|----------|
| 仅部署脚本 | 只能调用 deploy-apps-prod.sh 和 deploy-infrastructure-prod.sh | ✓ |
| 交互式 jenkins shell | 以 jenkins 用户身份打开交互式 bash | |
| 受控菜单 | 预定义菜单：部署应用/基础设施/回滚/重启服务 | |

**User's choice:** 仅部署脚本
**Notes:** 安全可控，部署脚本内部已包含回滚逻辑

---

## docker exec 归类

| Option | Description | Selected |
|--------|-------------|----------|
| 禁止（严格模式） | docker exec 归类为写入命令，sudoers 白名单不包含 | ✓ |
| 受限允许 | 通过 sudoers 封装脚本过滤只允许只读 exec 命令 | |

**User's choice:** 禁止（严格模式）
**Notes:** 符合最小权限原则。管理员需要调试时使用 sudo -u jenkins 或 Break-Glass 机制

---

## Claude's Discretion

- sudoers 规则具体实现方式（Cmnd_Alias vs 封装脚本）
- Break-Glass 脚本名称、存放位置、参数设计
- HTTP 健康检查的具体端点和超时时间
- 审计日志存储路径和格式

## Deferred Ideas

None — discussion stayed within phase scope
