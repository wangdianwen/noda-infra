---
phase: 41-migration-cleanup
plan: 02
status: complete
completed: "2026-04-19"
---

# Plan 41-02: SOPS 引用清理 + 文档更新 + .gitignore 清理

## What was built

清理所有脚本和文档中的 SOPS 引用，更新为 Doppler 密钥管理方案：

1. **setup-keycloak-full.sh** — SOPS 解密逻辑替换为 load_secrets() + 环境变量
2. **deploy-infrastructure-prod.sh** — 移除残留 SOPS 注释
3. **docs/secrets-management.md** — 完全重写为 Doppler 密钥管理文档
4. **7 个文档** — 移除/替换所有 SOPS 引用
5. **README.md** — 移除 SOPS 依赖
6. **.gitignore** — 清理 SOPS 模式，保留 docker/.env 和 config/keys/

## Key Decisions

- 文档中仅保留一处 SOPS 历史说明（secrets-management.md）
- .gitignore 保留 config/keys/（age 私钥仍用于备份加密）

## Key Files

| File | Action | Purpose |
|------|--------|---------|
| scripts/setup-keycloak-full.sh | modified | load_secrets() 替代 SOPS |
| scripts/deploy/deploy-infrastructure-prod.sh | modified | 移除 SOPS 注释 |
| docs/secrets-management.md | rewritten | Doppler 密钥管理文档 |
| docs/DEVELOPMENT.md | modified | SOPS → Doppler |
| docs/GETTING-STARTED.md | modified | SOPS → Doppler |
| docs/CONFIGURATION.md | modified | SOPS → Doppler |
| docs/KEYCLOAK_SCRIPTS.md | modified | SOPS → Doppler |
| docs/DEPLOYMENT_GUIDE.md | modified | SOPS → Doppler |
| docs/architecture.md | modified | SOPS → Doppler |
| docs/README.md | modified | SOPS → Doppler |
| README.md | modified | SOPS → Doppler |
| .gitignore | modified | 清理 SOPS 模式 |

## Verification

- `grep -rl 'sops\|SOPS' docs/ README.md --include='*.md'` — 仅 secrets-management.md 历史说明
- `! grep -qi 'sops' scripts/setup-keycloak-full.sh` — 无 SOPS 引用
- `! grep '.sops.yaml' .gitignore` — gitignore 已清理

## Self-Check: PASSED
