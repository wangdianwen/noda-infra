# Phase 41: 迁移与清理 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-19
**Phase:** 41-migration-cleanup
**Areas discussed:** secrets.sh 回退策略, SOPS 清理范围, 废弃脚本处理

---

## secrets.sh 回退策略

| Option | Description | Selected |
|--------|-------------|----------|
| 完全移除回退，强制 Doppler | DOPPLER_TOKEN 必须设置，否则报错退出 | ✓ |
| 保留回退但改为警告 | 回退到 docker/.env 但输出警告 | |
| 保留回退改为可选本地 .env | 开发环境可使用本地 .env | |

**User's choice:** 完全移除回退，强制 Doppler（与"直接创建上下文"一致）
**Notes:** Doppler 已成为唯一密钥源，移除回退逻辑简化代码并消除混淆

---

## SOPS 清理范围

| Option | Description | Selected |
|--------|-------------|----------|
| 全部删除 + 文档重写 | 删除所有 SOPS 文件/代码，重写 docs/secrets-management.md | ✓ |
| 仅删除核心文件 | 删除 .sops.yaml/secrets.sops.yaml/decrypt-secrets.sh，保留文档 | |
| 标记废弃不删除 | 添加废弃注释，Phase 42 再清理 | |

**User's choice:** 全部删除 + 文档重写
**Notes:** SOPS 已完全被 Doppler 替代，没有保留理由

---

## 废弃脚本处理

| Option | Description | Selected |
|--------|-------------|----------|
| 直接删除 | deploy-findclass-zero-deps.sh 已废弃，直接删除 | ✓ |
| 保留但移除 SOPS 代码 | 保留脚本框架，删除 SOPS 相关部分 | |
| 标记废弃 | 添加 DEPRECATED 注释，不删除 | |

**User's choice:** 直接删除（与"直接创建上下文"一致）
**Notes:** 已有替代部署方案（Jenkins Pipeline + 手动脚本），零依赖脚本不再需要

---

## Claude's Discretion

- verify-doppler-secrets.sh 覆盖范围更新
- setup-keycloak-full.sh 中 SOPS 替换的实现细节
- docs/secrets-management.md 重写深度
- .gitignore 清理范围

## Deferred Ideas

None — discussion stayed within phase scope
