---
phase: 39-infisical-infra
plan: 02
status: complete
completed: 2026-04-19
---

# Plan 39-02: Doppler 项目创建 + 密钥导入 — 完成摘要

## Objective
在 Doppler 云端创建项目 "noda"，导入所有 15 个密钥，创建 read-only Service Token。

## What Was Built

### Doppler 项目配置
- 项目: `noda`（已创建）
- 环境: `prd`（Doppler 默认，非 `prod`）
- 密钥: 15 个全部导入

### scripts/verify-doppler-secrets.sh
密钥完整性验证脚本，包含：
- 15 个预期密钥完整列表（排除 VITE_* 和备份系统密钥）
- 通过 Service Token 认证验证
- 逐个密钥检查 + 通过/失败报告

### Service Token
- Token: `DOPPLER_TOKEN_REDACTED`
- 权限: Read-only（仅拉取密钥）
- 名称: `jenkins`

## Verification
- `doppler secrets --only-names --project noda --config prd` → 15 个密钥 ✅
- `doppler secrets download --format=env --no-file` → 完整 KEY=VALUE 输出 ✅
- `bash scripts/verify-doppler-secrets.sh` → 15/15 密钥完整 ✅
- 脚本语法正确 ✅

## Deviations
- Doppler 默认 config 名为 `prd` 而非 `prod`，已同步更新所有脚本

## Self-Check: PASSED

## Key Files
- `scripts/verify-doppler-secrets.sh` — 密钥完整性验证脚本
