# Phase 45: Infra Pipeline 镜像清理补全 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-19
**Phase:** 45-infra-image-cleanup
**Areas discussed:** 镜像清理策略, 验证方式

---

## noda-ops 镜像清理策略

| Option | Description | Selected |
|--------|-------------|----------|
| cleanup_by_date_threshold | 保留容器在用镜像 + latest，删除所有其他旧 SHA 标签。与 findclass-ssr/keycloak 统一策略 | ✓ |
| cleanup_by_tag_count | 保留最近 N 个标签，删除更早的。适用于多版本保留场景 | |

**User's choice:** cleanup_by_date_threshold（推荐）
**Notes:** 统一策略，已在 findclass-ssr 和 keycloak Pipeline 中验证

## nginx 镜像清理策略

| Option | Description | Selected |
|--------|-------------|----------|
| 现有 dangling 清理已足够 | nginx 使用外部镜像，版本变更后旧镜像变 dangling。cleanup_after_infra_deploy() 中的 cleanup_dangling_images() 已覆盖 | ✓ |
| 额外添加 cleanup_by_date_threshold | 清理旧版本，但 nginx 是外部镜像，本地无多版本标签 | |

**User's choice:** 现有 dangling 清理已足够（推荐）
**Notes:** nginx 是外部预构建镜像，不需要本地多版本管理

## 验证方式

| Option | Description | Selected |
|--------|-------------|----------|
| 仅 noda-ops Pipeline | 只触发 noda-ops 部署，减小验证范围 | |
| noda-ops + nginx 两个 Pipeline | 触发两个服务，确认两种服务的清理日志都正常 | ✓ |

**User's choice:** noda-ops + nginx 两个 Pipeline
**Notes:** 全面验证两种服务的清理行为

## Claude's Discretion

- pipeline_infra_cleanup() 中 case 分支的具体代码修改
- 验证步骤的具体命令和日志检查项

## Deferred Ideas

None — discussion stayed within phase scope
