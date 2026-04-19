# Phase 43: 清理共享库 + Pipeline 集成 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-19
**Phase:** 43-cleanup-pipeline
**Areas discussed:** 库关系, 调用方式, 快照格式, 验证策略

---

## cleanup.sh 与 image-cleanup.sh 关系

| Option | Description | Selected |
|--------|-------------|----------|
| 并存不合并 | image-cleanup.sh 专注镜像保留策略，cleanup.sh 专注部署后全面清理，pipeline_cleanup() 同时 source 两个库 | ✓ |
| cleanup.sh 包装 image-cleanup.sh | cleanup.sh 不提供 dangling images 函数，内部调用 image-cleanup.sh 的 cleanup_dangling() | |
| 合并为一个库 | 将 image-cleanup.sh 的 3 个函数迁入 cleanup.sh，删除 image-cleanup.sh | |

**User's choice:** 并存不合并（推荐）
**Notes:** 职责清晰分离：image-cleanup = 镜像保留策略，cleanup = 全面清理。不破坏已有的 source 引用。

---

## Pipeline 清理调用方式

| Option | Description | Selected |
|--------|-------------|----------|
| 逐个调用 | pipeline_cleanup() 中逐个调用 cleanup.sh 的各清理函数 | |
| 高层 wrapper | cleanup.sh 提供 cleanup_after_deploy()，pipeline_cleanup() 只需调用一个函数 | ✓ |

**User's choice:** 高层 wrapper（推荐）
**Notes:** 内部可配置（环境变量控制跳过某些步骤），但默认全部执行。

---

## 磁盘快照输出格式

| Option | Description | Selected |
|--------|-------------|----------|
| 纯日志文本 | disk_snapshot() 输出 df -h + docker system df 到 Jenkins 构建日志 | ✓ |
| 日志 + 文件写入 | 同时写入 ${WORKSPACE}/disk-snapshot-{timestamp}.log 文件 | |
| 结构化 JSON | 输出 JSON 格式（可脚本解析），可写入文件或直接日志 | |

**User's choice:** 纯日志文本（推荐）
**Notes:** 简单直接，不需要额外文件管理。部署前和清理后各输出一次，人工对比。

---

## 验证策略

| Option | Description | Selected |
|--------|-------------|----------|
| 手动 Pipeline 触发 | 手动触发 4 个 Pipeline，检查构建日志中清理输出和磁盘快照对比 | ✓ |
| 独立测试脚本 | 编写 scripts/test-cleanup.sh 逐个验证清理函数 | |
| 两者结合 | 先测试脚本验证函数级别，再 Pipeline 端到端验证 | |

**User's choice:** 手动 Pipeline 触发（推荐）
**Notes:** 最接近真实场景，4 个 Pipeline 依次触发验证。

---

## Claude's Discretion

- cleanup.sh 中各清理函数的具体签名和参数设计
- cleanup_after_deploy() 内部的执行顺序
- 环境变量覆盖的具体命名和默认值
- 是否需要 cleanup_after_infra_deploy() 作为 infra 专用 wrapper

## Deferred Ideas

None — discussion stayed within phase scope
