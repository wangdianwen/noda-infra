---
phase: 41-migration-cleanup
plan: 03
status: complete
completed: "2026-04-19"
---

# Plan 41-03: 删除明文文件和 SOPS 文件

## What was built

安全删除 6 个文件，完成从 SOPS 到 Doppler 的迁移：

1. **docker/.env** — 14 个基础设施密钥（已迁移到 Doppler）
2. **.env.production** — 前端 + SMTP 密钥（已迁移到 Doppler）
3. **.sops.yaml** — SOPS 配置
4. **config/secrets.sops.yaml** — 加密密钥文件
5. **scripts/utils/decrypt-secrets.sh** — SOPS 解密脚本
6. **scripts/deploy/deploy-findclass-zero-deps.sh** — 已废弃脚本

## Preserved Files

- `scripts/backup/.env.backup` — 备份系统独立密钥
- `config/environments/.env.production.template` — 新环境参考模板
- `config/environments/.env.example` — 示例模板
- `config/keys/git-age-key.txt` — age 私钥（backup-doppler-secrets.sh 使用）

## Key Decisions

- docker/.env 不在 Git 跟踪中（被 .gitignore 覆盖），仅从文件系统删除
- 备份系统和 age 密钥完全不受影响

## Key Files

| File | Action | Purpose |
|------|--------|---------|
| docker/.env | deleted | 明文密钥已迁移 |
| .env.production | deleted (git rm) | 前端密钥已迁移 |
| .sops.yaml | deleted (git rm) | SOPS 配置废弃 |
| config/secrets.sops.yaml | deleted (git rm) | 加密密钥废弃 |
| scripts/utils/decrypt-secrets.sh | deleted (git rm) | 解密脚本废弃 |
| scripts/deploy/deploy-findclass-zero-deps.sh | deleted (git rm) | 废弃脚本 |

## Verification

- `! test -f docker/.env` — 已删除
- `! test -f .sops.yaml` — 已删除
- `test -f scripts/backup/.env.backup` — 备份完好
- `test -f config/keys/git-age-key.txt` — age 密钥保留
- `! grep -rq 'sops\|SOPS' scripts/ --include='*.sh'` — scripts/ 无残留
- `! grep -rq 'sops\|SOPS' docs/ README.md --include='*.md'` — docs/ 无残留

## Self-Check: PASSED
