# Phase 18: 容器标签分组 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-12
**Phase:** 18-container-labels
**Mode:** Auto (--auto)
**Areas discussed:** 标签值统一, 环境标签添加, 缺失标签修复

---

## 标签值统一（GRP-02）

| Option | Description | Selected |
|--------|-------------|----------|
| 保留 noda-apps | 2 个文件已使用，改 1 个文件 | |
| 统一为 apps | 更简洁，1 个文件已使用，改 2 个文件 | ✓ |

**[auto] Selected:** 统一为 apps — 更简洁，与 infra 对称，避免 noda 前缀重复

---

## 环境标签（GRP-01）

| Option | Description | Selected |
|--------|-------------|----------|
| 仅主 compose 文件 | base + prod + dev | |
| 全部 compose 文件 | 包括 simple.yml + dev-standalone.yml + app.yml | ✓ |

**[auto] Selected:** 全部 compose 文件 — 保持一致性

---

## 缺失标签修复

| Option | Description | Selected |
|--------|-------------|----------|
| 仅添加 environment 标签 | 不修复缺失的 service-group | |
| 完整修复 | 补全 postgres-dev 的 service-group + 添加 environment | ✓ |

**[auto] Selected:** 完整修复 — postgres-dev 应有完整的标签集

---

## Claude's Discretion

- label 格式细节（单行 vs 多行）
- simple.yml 中 cloudflared 的标签处理

## Deferred Ideas

None — all items within Phase 18 scope
