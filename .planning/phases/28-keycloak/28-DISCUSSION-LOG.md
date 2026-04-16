# Phase 28: Keycloak 蓝绿部署基础设施 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-17
**Phase:** 28-keycloak
**Mode:** Auto (--auto)
**Areas discussed:** Keycloak 健康检查方式, 环境变量传递, 迁移策略, 部署脚本复用

---

## Keycloak 健康检查方式

| Option | Description | Selected |
|--------|-------------|----------|
| HTTP 端点检查 `/health/ready` | Keycloak 26.x health endpoint，准确反映服务就绪状态 | ✓ |
| TCP 端口检查 `8080` | 当前 compose 使用的方式，简单但不准确 | |

**User's choice:** HTTP 端点检查 `/health/ready` — auto-selected (recommended)
**Notes:** KC_HEALTH_ENABLED 已在生产配置中启用

---

## 环境变量传递

| Option | Description | Selected |
|--------|-------------|----------|
| env file 模板 (env-keycloak.env) | 与 findclass-ssr 蓝绿模式一致 | ✓ |
| docker run -e 逐个传递 | 直接在脚本中传递，灵活性高但维护困难 | |

**User's choice:** env file 模板 — auto-selected (recommended)

---

## 迁移策略

| Option | Description | Selected |
|--------|-------------|----------|
| manage-containers.sh init 子命令 | 与 findclass-ssr 迁移模式一致 | ✓ |
| 手动迁移脚本 | 独立脚本处理一次性迁移 | |

**User's choice:** manage-containers.sh init 子命令 — auto-selected (recommended)

---

## 部署脚本复用

| Option | Description | Selected |
|--------|-------------|----------|
| 复用 manage-containers.sh + 新建 keycloak-blue-green-deploy.sh | 参数化复用 + Keycloak 特化部署流程 | ✓ |
| 完全独立脚本 | 不依赖现有 manage-containers.sh | |

**User's choice:** 复用 + 新建 — auto-selected (recommended)

---

## Claude's Discretion

- env-keycloak.env 具体变量和默认值
- health endpoint 重试参数
- init 子命令交互流程
- Jenkinsfile.keycloak 环境变量配置
- 旧镜像保留策略

## Deferred Ideas

- Keycloak 版本升级（单独评估）
- Keycloak 数据库分库（当前共享足够）
- 多服务统一蓝绿脚本（Phase 29）
- Keycloak 配置自动化（不在范围内）
- 自动触发 Pipeline（保持手动触发）
