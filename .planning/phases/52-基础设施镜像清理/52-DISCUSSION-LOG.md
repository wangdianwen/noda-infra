# Phase 52: 基础设施镜像清理 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-21
**Phase:** 52-基础设施镜像清理
**Areas discussed:** noda-ops 多阶段构建, backup Dockerfile 层合并, 运行时依赖精简

---

## noda-ops 多阶段构建

| Option | Description | Selected |
|--------|-------------|----------|
| 方案 A：多阶段构建 | 干净隔离 wget/gnupg 到构建阶段，运行时镜像完全不含构建工具 | ✓ |
| 方案 B：安装后卸载 | 单 RUN 内安装+下载+卸载，简单但不如多阶段干净 | |

**User's choice:** 方案 A：多阶段构建
**Notes:** 用户偏好干净的构建隔离

---

## backup Dockerfile 层合并

| Option | Description | Selected |
|--------|-------------|----------|
| 合并为 1 个 RUN | apk add + mkdir + touch + chmod 全部合并，最精简 | ✓ |
| 合并为 2 个 RUN | apk add 为一个，mkdir+chmod 为另一个，稍分层 | |

**User's choice:** 合并为 1 个 RUN
**Notes:** 追求最精简

---

## 运行时依赖精简

| Option | Description | Selected |
|--------|-------------|----------|
| 移除 curl | backup 脚本未使用，健康检查用 pg_isready | ✓ |
| 保留 curl | debug 场景方便，占用空间很小 | |

**User's choice:** 移除 curl
**Notes:** curl 在 noda-ops 运行时无实际调用

### 保留确认
- jq：alert.sh、db.sh、metrics.sh、verify.sh 大量使用 — 保留
- coreutils：db.sh 使用 numfmt（GNU 独有） — 保留

---

## Claude's Discretion

- 多阶段构建的具体 Dockerfile 结构
- RUN 指令合并的具体顺序和格式
- 是否同时优化 test-verify Dockerfile

## Deferred Ideas

None — discussion stayed within phase scope
