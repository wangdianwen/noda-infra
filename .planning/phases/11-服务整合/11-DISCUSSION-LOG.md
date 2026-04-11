# Phase 11: 服务整合 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-11
**Phase:** 11-服务整合
**Areas discussed:** 目录结构迁移, Docker 分组标签, Compose 文件整理

---

## 目录结构迁移

| Option | Description | Selected |
|--------|-------------|----------|
| 现状整理 | 保持 noda-apps 独立仓库，Dockerfile 留在 deploy/，只整理路径引用 | ✓ |
| 创建 noda-apps/ 子目录 | 在 noda-infra 内创建子目录，迁入 Dockerfile 和配置 | |
| 迁入外部仓库 | 将 Dockerfile 迁入 noda-apps 仓库 | |

**User's choice:** 现状整理（推荐）
**Notes:** noda-apps 是独立应用代码仓库，不需要将基础设施配置迁入。只需统一 Dockerfile 路径引用。

---

## Docker 分组标签

| Option | Description | Selected |
|--------|-------------|----------|
| 基础设施 vs 应用 | infra 组（postgres, keycloak, noda-ops, nginx）+ apps 组（findclass-ssr） | ✓ |
| 统一 noda + role 标签 | 所有服务统一 noda 标签，通过 role 区分 | |
| 仅描述性 labels | 不分组，只添加描述 | |

**User's choice:** 基础设施 vs 应用（推荐）
**Notes:** 双组标签，可通过 `--filter label=project=noda-apps` 过滤

---

## Compose 文件整理

| Option | Description | Selected |
|--------|-------------|----------|
| 全部更新 | 5 个变体全部更新 labels 和路径 | ✓ |
| 只更新核心 | base + prod + app | |
| 合并精简 | 删除 simple/standalone | |

**User's choice:** 全部更新（推荐）
**Notes:** 确保所有变体文件标签和路径一致

---

## Claude's Discretion

- 具体 labels 键名和格式
- 部署脚本是否需要更新
- 废弃路径引用清理

## Deferred Ideas

None
