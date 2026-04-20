# Phase 48: 全局 Docker 卫生实践 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-20
**Phase:** 48-docker-hygiene
**Areas discussed:** .dockerignore 粒度, COPY --chown 范围, test-verify 兼容性

---

## .dockerignore 粒度

| Option | Description | Selected |
|--------|-------------|----------|
| 按构建上下文定制 | deploy/ 综合排除 + scripts/backup/docker/ 精简版，与实际 COPY 指令对齐 | ✓ |
| 统一模板 | 两个目录都用相同的排除规则 | |
| Claude 自行决定 | 由规划阶段根据 COPY 指令决定 | |

**User's choice:** 按构建上下文定制（推荐）
**Notes:** deploy/ 有 4 个 Dockerfile 共享构建上下文，需要综合排除；test-verify 独立上下文，精简即可

---

## COPY --chown 范围

| Option | Description | Selected |
|--------|-------------|----------|
| 只改稳定的 4 个 | backup、noda-ops、noda-site、test-verify，findclass-ssr 留给 Phase 49-51 | ✓ |
| 全部 5 个都改 | 包含 findclass-ssr，保证 Phase 48 独立完成 | |
| 最小改动 | 只改有 RUN chown 的指令 | |

**User's choice:** 只改稳定的 4 个（推荐）
**Notes:** findclass-ssr 的 Dockerfile 将在 Phase 49-51 被大幅重写（移除 Python、切 Alpine），现在改了也会被覆盖

---

## test-verify 兼容性

| Option | Description | Selected |
|--------|-------------|----------|
| Pipeline 部署 + 手动验证 | 通过 Jenkins 部署后手动执行 test-verify 验证 | ✓ |
| 信任兼容性 | prod PG 已是 17，不额外验证 | |
| 先本地测试再集成 | docker build + run 手动测试后再集成 | |

**User's choice:** Pipeline 部署 + 手动验证（推荐）
**Notes:** prod PostgreSQL 已是 17，pg_dump/pg_restore 客户端升级到 17 理论上完全兼容，但仍需实际验证

---

## Claude's Discretion

- 每个 .dockerignore 的具体排除条目
- COPY --chown 的用户/组值
- test-verify 其他依赖版本是否更新

## Deferred Ideas

- findclass-ssr COPY --chown — Phase 49-51
- findclass-ssr .dockerignore — Phase 49-51
