# Phase 42: 备份与安全 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-19
**Phase:** 42-backup-security
**Areas discussed:** Cron 备份调度, BFG Git 历史清理

---

## Cron 备份调度

| Option | Description | Selected |
|--------|-------------|----------|
| 每天一次 | 和现有数据库备份同步，每天自动备份密钥 | ✓ |
| 每周一次 | 密钥变更频率很低，每周备份足够 | |
| 融入现有备份 cron | backup-doppler-secrets.sh 加入 noda-ops cron | ✓ |

**运行环境：**

| Option | Description | Selected |
|--------|-------------|----------|
| Jenkins 宿主机 cron | 宿主机 cron 直接调用 | |
| noda-ops 容器 cron | 和数据库备份一起运行，复用 B2 凭据 | ✓ |
| Jenkins Pipeline stage | 作为 Pipeline 独立 stage | |

**Cron 集成方式：**

| Option | Description | Selected |
|--------|-------------|----------|
| 融入 entrypoint cron | 在 entrypoint-ops.sh 中添加密钥备份 cron 行 | ✓ |
| 独立 cron 条目 | 密钥备份脚本独立运行 | |

**Doppler 认证：**

| Option | Description | Selected |
|--------|-------------|----------|
| 环境变量注入 | docker-compose.yml 中添加 DOPPLER_TOKEN | ✓ |
| 挂载配置目录 | 挂载宿主机 Doppler 配置 | |

**Notes:** backup-doppler-secrets.sh 已存在完整流程，只需集成到 noda-ops cron + 注入 DOPPLER_TOKEN

---

## BFG Git 历史清理

**清理范围：**

| Option | Description | Selected |
|--------|-------------|----------|
| 只清 .env.production | 唯一被提交过的密钥文件 | |
| 清理所有敏感文件 | .env.production + .sops.yaml + secrets.sops.yaml | ✓ |
| 跳过 BFG | 风险大于收益 | |

**执行方式：**

| Option | Description | Selected |
|--------|-------------|----------|
| 手动执行 | 记录步骤到文档，用户手动执行 | |
| 脚本自动化 | 脚本自动执行 BFG + force push | ✓ |

**验证方式：**

| Option | Description | Selected |
|--------|-------------|----------|
| 自动验证 + 报告 | BFG 后自动检查 git log | ✓ |
| 只清理不验证 | 验证留给手动检查 | |

**Notes:**
- docker/.env 从未被 git 追踪，不需要 BFG 清理
- .env.production 中的密码是占位符（postgres_password_change_me），非真实密钥
- VERCEL_OIDC_TOKEN JWT 已过期

---

## Claude's Discretion

- backup-doppler-secrets.sh 容器环境适配（路径、依赖）
- noda-ops Dockerfile doppler CLI 安装
- BFG 脚本具体命令和参数
- cron 时间表达式（避免和数据库备份冲突）

## Deferred Ideas

None — 讨论在 Phase 范围内完成。
