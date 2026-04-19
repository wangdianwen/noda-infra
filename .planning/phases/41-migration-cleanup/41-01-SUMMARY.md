---
phase: 41-migration-cleanup
plan: 01
status: complete
completed: "2026-04-19"
---

# Plan 41-01: 密钥验证扩展 + secrets.sh Doppler-only + backup 公钥改造

## What was built

3 个脚本更新，为删除明文文件和 SOPS 代码做准备：

1. **verify-doppler-secrets.sh** — EXPECTED_SECRETS 从 15 扩展到 17 个（添加 GOOGLE_CLIENT_ID/SECRET）
2. **secrets.sh** — load_secrets() 移除 docker/.env 回退，DOPPLER_TOKEN 未设置时 return 1
3. **backup-doppler-secrets.sh** — age 公钥硬编码为默认值，不再依赖 .sops.yaml

## Key Decisions

- Doppler 成为唯一密钥源，无本地文件回退
- age 公钥（可安全公开）硬编码为默认值，环境变量仍可覆盖

## Key Files

| File | Action | Purpose |
|------|--------|---------|
| scripts/verify-doppler-secrets.sh | modified | 添加 Google OAuth 密钥验证 |
| scripts/lib/secrets.sh | modified | Doppler-only 模式 |
| scripts/backup/backup-doppler-secrets.sh | modified | 硬编码 age 公钥 |

## Verification

- `bash -n` 全部通过
- `grep 'GOOGLE_CLIENT_ID' scripts/verify-doppler-secrets.sh` — 确认新增
- `! grep 'source.*docker' scripts/lib/secrets.sh` — 确认无回退
- `! grep '.sops.yaml' scripts/backup/backup-doppler-secrets.sh` — 确认无 SOPS 依赖

## Self-Check: PASSED
