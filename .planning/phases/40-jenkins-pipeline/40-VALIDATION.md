---
phase: 40
slug: jenkins-pipeline
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-19
---

# Phase 40 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ShellCheck + bash -n 语法检查（Infrastructure 项目无自动化测试框架） |
| **Config file** | .shellcheckrc |
| **Quick run command** | `bash -n scripts/pipeline-stages.sh && echo "syntax OK"` |
| **Full suite command** | 手动触发 Jenkins Pipeline 验证 |
| **Estimated runtime** | ~2 秒（语法检查） |

---

## Sampling Rate

- **After every task commit:** `bash -n scripts/pipeline-stages.sh`（语法检查）
- **After wave merge:** 手动 Jenkins Pipeline 触发验证
- **Phase gate:** 3 个 Pipeline 均成功执行一次完整部署

---

## Dimension 8: Coverage Matrix

| Req ID | Behavior | Test Type | Verification Method |
|--------|----------|-----------|-------------------|
| PIPE-01 | Doppler 密钥拉取到 shell 环境 | 手动 | `DOPPLER_TOKEN=xxx bash -c 'eval "$(doppler secrets download --no-file --format=env --project noda --config prd)" && echo $POSTGRES_USER'` |
| PIPE-02 | DOPPLER_TOKEN 不出现在 Jenkins 日志中 | 手动 | Jenkins Stage View 日志检查，确认 **** 遮蔽 |
| PIPE-03 | envsubst 模板正确替换 Doppler 密钥 | 手动 | Pipeline 部署后检查容器环境变量 |
| PIPE-04 | VITE_* 构建参数不受 Doppler 影响 | 手动 | Pipeline Build 阶段日志检查 |

---

## Wave 0 Gaps

- 无自动化测试框架。Infrastructure 项目（shell 脚本 + Docker Compose）无传统测试基础设施。
- 验证方式：bash 语法检查 + 手动 Pipeline 触发 + 容器运行时验证
