# Phase 36: 蓝绿部署统一 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-18
**Phase:** 36-blue-green-unify
**Areas discussed:** 构建步骤归属, 镜像清理策略, 回滚脚本通用化

---

## 构建步骤归属

| Option | Description | Selected |
|--------|-------------|----------|
| 内置模式切换 | 统一脚本内通过 IMAGE_SOURCE 环境变量区分（build/pull/none） | ✓ |
| 外部处理 | 构建/拉取由 Jenkinsfile 在调用部署脚本前完成 | |
| 独立构建脚本 | 构建步骤抽取为独立小脚本 | |

**User's choice:** 内置模式切换
**Notes:** Jenkinsfile 无需改动，统一入口保持简洁

---

## 镜像清理策略

| Option | Description | Selected |
|--------|-------------|----------|
| 环境变量参数化 | CLEANUP_METHOD 环境变量（tag-count/dangling/none） | ✓ |
| 统一为 tag-count | 两种服务都用 cleanup_by_tag_count | |
| 从部署脚本移除 | 清理由 Jenkins Pipeline 独立步骤处理 | |

**User's choice:** 环境变量参数化
**Notes:** keycloak wrapper 传 dangling，findclass-ssr 默认 tag-count

---

## 回滚脚本通用化范围

| Option | Description | Selected |
|--------|-------------|----------|
| 双服务通用化 | rollback-findclass.sh 参数化 + rollback-keycloak.sh wrapper | ✓ |
| 仅 findclass 范围 | 只改硬编码值，不改名不改架构 | |
| 单一回滚脚本 | 合并为 rollback.sh | |

**User's choice:** 双服务通用化
**Notes:** 回滚能力覆盖两个服务，参数化方式复用 manage-containers.sh 的环境变量模式

---

## Claude's Discretion

- 统一脚本的具体环境变量命名
- wrapper 脚本的具体实现方式（exec vs source）
- SHA 标签逻辑参数化
- compose 迁移检查逻辑纳入方式

## Deferred Ideas

None
