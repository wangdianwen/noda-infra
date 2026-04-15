# Phase 21: 蓝绿容器管理 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-15
**Phase:** 21-蓝绿容器管理
**Areas discussed:** 管理脚本命令结构, 环境变量传递方式, 初始迁移策略, 容器命名与标签策略

---

## 管理脚本命令结构

| Option | Description | Selected |
|--------|-------------|----------|
| 单脚本多子命令 | manage-containers.sh，子命令 start/stop/status/init。与 setup-jenkins.sh 模式一致 | ✓ |
| 多个专用脚本 | start-container.sh、stop-container.sh、container-status.sh。职责分离 | |
| 函数库（无 CLI） | shell 函数库供 Phase 22 source 调用 | |

**User's choice:** 单脚本多子命令

### 子命令范围

| Option | Description | Selected |
|--------|-------------|----------|
| 4 个子命令 | start、stop、status、init。简洁覆盖需求 | |
| 5 个子命令（含 switch） | 增加切换功能子命令 | |
| 7+ 个子命令（完整运维） | start、stop、status、init、restart、logs 等。功能完备 | ✓ |

**User's choice:** 7+ 个子命令（完整运维）
**Notes:** 与 setup-jenkins.sh 7 个子命令风格一致，提供完整运维工具集

---

## 环境变量传递方式

| Option | Description | Selected |
|--------|-------------|----------|
| 独立 env 文件 | docker/env-findclass-ssr.env，--env-file 传递 | ✓ |
| 脚本内从 .env 读取 | 从 docker/.env 读取并拼接 docker run -e | |
| 硬编码在 docker run 命令 | 直接 -e 传递，简单但不灵活 | |

**User's choice:** 独立 env 文件
**Notes:** 变量值中的 ${VAR} 引用由脚本解析填充

---

## 初始迁移策略

| Option | Description | Selected |
|--------|-------------|----------|
| 脚本 init 自动迁移 | init 子命令自动检测 compose 容器，停止并启动 blue，更新 nginx 和状态文件 | ✓ |
| 仅初始化状态 | init 只创建状态文件和目录，不迁移容器 | |
| 文档指引手动迁移 | 提供文档指导管理员手动执行 | |

**User's choice:** 脚本 init 自动迁移
**Notes:** 一次性完成从单容器到蓝绿架构的迁移

---

## 容器命名与标签策略

| Option | Description | Selected |
|--------|-------------|----------|
| 保留 + 新增蓝绿标签 | 保留 noda.service-group=apps + noda.environment=prod，新增 noda.blue-green=blue/green | ✓ |
| 仅用容器名区分 | 不加标签，仅通过容器名 | |
| 替换 environment 标签 | noda.environment 改为 blue/green | |

**User's choice:** 保留 + 新增蓝绿标签
**Notes:** 可通过 `docker ps --filter label=noda.blue-green=blue` 快速筛选

---

## Claude's Discretion

- 环境变量文件中动态替换 vs 硬编码的具体设计
- 子命令参数设计细节
- init 迁移时的错误恢复机制
- status 子命令的输出格式

## Deferred Ideas

None — discussion stayed within phase scope
