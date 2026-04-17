# Phase 19: Jenkins 安装与基础配置 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-14
**Phase:** 19-jenkins
**Areas discussed:** 端口配置, 脚本功能范围, 卸载清理深度, 首次启动安全配置

---

## Jenkins 端口选择

| Option | Description | Selected |
|--------|-------------|----------|
| 保持 8080 | 默认端口，Keycloak 8080 仅在 Docker 内部，实际不冲突 | |
| 改为 8888 | 通过 systemd override 配置，彻底避免与 Keycloak 混淆 | ✓ |
| Claude 决定 | 用户不关心具体端口 | |

**User's choice:** 改为 8888
**Notes:** 避免运维时混淆 Jenkins 8080 和 Keycloak 内部 8080

---

## 脚本功能范围

| Option | Description | Selected |
|--------|-------------|----------|
| 最小集 | 仅 install + uninstall + help | |
| 运维实用集 | install/uninstall/status/show-password | |
| 完整运维工具 | 上述全部 + restart/upgrade/reset-password | ✓ |

**User's choice:** 完整运维工具
**Notes:** 7 个子命令：install, uninstall, status, show-password, restart, upgrade, reset-password

---

## 卸载清理深度

| Option | Description | Selected |
|--------|-------------|----------|
| 完全清理 | 包+数据+日志+APT源+用户+组，全部移除 | ✓ |
| 保守清理 | 仅移除包和组，保留 /var/lib/jenkins | |
| Claude 决定 | 用户不关心 | |

**User's choice:** 完全清理
**Notes:** 移除 Jenkins 包、/var/lib/jenkins、/var/log/jenkins、APT 源、systemd override、docker 组成员、jenkins 用户

---

## 首次启动安全配置

| Option | Description | Selected |
|--------|-------------|----------|
| 手动配置 | 脚本只安装和获取密码，安全配置在 Web UI 手动完成 | |
| 自动化配置 | install 后自动调用 API/CLI 完成安全配置 | ✓ |
| Claude 决定 | 用户不关心 | |

**User's choice:** 自动化配置
**Notes:** 四项自动化：(1)管理员用户创建 (2)插件预安装 (3)安全加固 (4)创建 Pipeline 作业

### 自动化配置详细选择

| Option | Selected |
|--------|----------|
| 管理员用户创建 | ✓ |
| 插件预安装（Git, Pipeline, Stage View, Credentials Binding, Timestamper） | ✓ |
| 安全加固（CSRF、禁用匿名读取、Agent 安全策略） | ✓ |
| 创建 Pipeline 作业 | ✓ |

---

## Claude's Discretion

- Jenkins 初始配置的具体实现方式（groovy init 脚本 vs jenkins-cli vs REST API）
- 管理员凭据的存储位置和格式
- Pipeline 作业模板的具体内容

## Deferred Ideas

None — discussion stayed within phase scope
