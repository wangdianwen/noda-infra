---
phase: 39-infisical-infra
plan: 03
status: complete
completed: 2026-04-19
---

# Plan 39-03: Doppler 密钥离线备份脚本 — 完成摘要

## Objective
创建 Doppler 密钥离线备份脚本，实现 age 加密 + B2 上传的两层备份策略。

## What Was Built

### scripts/backup/backup-doppler-secrets.sh
自动化备份脚本，包含：
- `doppler secrets download` 下载密钥（管道传递给 age，明文不落盘）
- `age -r` 公钥加密（使用 .sops.yaml 中已有的 age 公钥）
- `b2 upload-file` 上传加密文件到 B2
- `--dry-run` 模式支持（仅下载加密，不上传）
- age 公钥回退读取 .sops.yaml

## Verification
- `bash -n` 语法正确 ✅
- `doppler secrets download` 命令存在 ✅
- `age -r` 加密步骤存在 ✅
- `b2 upload-file` 上传步骤存在 ✅
- `--dry-run` 参数支持 ✅
- DOPPLER_TOKEN 环境变量检查 ✅
- 临时文件清理 ✅
- .sops.yaml 公钥回退 ✅

## Self-Check: PASSED

## Key Decisions
- 使用 age 加密（与现有 SOPS 工具链一致）
- 管道方式处理密钥（明文不写入磁盘）
- B2 bucket: noda-backups, 路径前缀: doppler-backup/

## Key Files
- `scripts/backup/backup-doppler-secrets.sh` — Doppler 密钥离线备份脚本
