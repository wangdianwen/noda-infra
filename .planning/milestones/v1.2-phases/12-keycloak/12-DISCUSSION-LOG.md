# Phase 12: Keycloak 双环境 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-11
**Phase:** 12-keycloak
**Areas discussed:** 启动模式, 端口与网络设计, 开发环境初始化, 主题热重载机制

---

## Keycloak 启动模式

| Option | Description | Selected |
|--------|-------------|----------|
| start-dev | Keycloak 内置开发模式，自动禁用主题缓存、关闭 HTTPS、放宽安全限制 | ✓ |
| start + dev 参数 | 使用生产模式 start 命令，手动配置禁用缓存参数 | |
| 你来决定 | 交给 Claude 判断 | |

**User's choice:** start-dev（推荐）
**Notes:** 开箱即用满足 KCDEV-02/03 需求，无需额外配置

---

## 端口与网络设计

### 端口方案

| Option | Description | Selected |
|--------|-------------|----------|
| 18080 + 19000 | HTTP: 18080，管理: 19000。与 prod 端口对应，易记忆 | ✓ |
| 8082 + 9002 | HTTP: 8082，管理: 9002。端口连续但与 prod 无对应关系 | |

**User's choice:** 18080 + 19000（推荐）

### 网络方案

| Option | Description | Selected |
|--------|-------------|----------|
| 复用 noda-network | 与 postgres-dev 保持一致模式，可直接访问 postgres-dev | ✓ |
| 独立 dev 网络 | 更严格隔离，但需额外配置跨网络访问 | |

**User's choice:** 复用 noda-network（推荐）

---

## 开发环境初始化

### Realm 初始化

| Option | Description | Selected |
|--------|-------------|----------|
| 手动创建 | 在 Admin Console 手动创建 noda realm 和测试用户 | ✓ |
| 自动导入 realm | 通过 REST API 或 realm-export.json 自动导入 | |
| 半自动（脚本可选） | 提供一键脚本但不自动运行 | |

**User's choice:** 手动创建（推荐）
**Notes:** 简单直接，不会创建难以维护的自动化脚本

### Google OAuth

| Option | Description | Selected |
|--------|-------------|----------|
| 仅密码登录 | 开发环境只开启密码登录，不配置 Google OAuth | ✓ |
| 密码登录 + 可选 Google 文档 | 默认密码登录，提供 Google OAuth 配置说明 | |

**User's choice:** 仅密码登录（推荐）
**Notes:** 避免在 Google Cloud Console 添加 localhost 回调 URL

---

## 主题热重载机制

### 主题挂载

| Option | Description | Selected |
|--------|-------------|----------|
| 宿主机目录挂载 | 将宿主机主题目录读写挂载到 Keycloak themes 目录 | ✓ |
| JAR 部署 | 将主题打包为 JAR 放入 providers 目录 | |

**User's choice:** 宿主机目录挂载（推荐）
**Notes:** 修改文件后 start-dev 自动重新加载，适合开发迭代

### 主题类型

| Option | Description | Selected |
|--------|-------------|----------|
| 标准 login 主题 | Freemarker 模板 + CSS 覆盖，Keycloak 推荐方式 | ✓ |
| Phase 13 再决定 | 留到 Phase 13 再决定 | |

**User's choice:** 标准 login 主题（推荐）
**Notes:** 为 Phase 13 自定义主题开发提供基础

---

## Claude's Discretion

- keycloak-dev 容器名格式
- 数据库连接字符串具体参数
- start-dev 额外 JVM 参数
- keycloak-dev healthcheck 配置

## Deferred Ideas

无 — 讨论保持在 phase 范围内
