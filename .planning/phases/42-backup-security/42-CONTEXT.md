# Phase 42: 备份与安全 - Context

**Gathered:** 2026-04-19
**Status:** Ready for planning

<domain>
## Phase Boundary

Doppler 密钥有定期 B2 快照备份（通过 noda-ops 容器 cron 每天运行），Git 历史中的敏感文件（.env.production, .sops.yaml, config/secrets.sops.yaml）已被 BFG 清除。

**涉及需求：** BACKUP-01（cron 定期 B2 快照）、BACKUP-02（Git 历史 BFG 清理）

**前置条件：** Phase 41 已完成 — Doppler 是唯一密钥源，明文 .env 已删除，backup-doppler-secrets.sh 脚本已存在。

</domain>

<decisions>
## Implementation Decisions

### Cron 备份调度
- **D-01:** 每天运行一次 Doppler 密钥备份（密钥变更频率低，但备份成本极低，每天备份确保安全）
- **D-02:** 在 noda-ops 容器的 entrypoint-ops.sh 中融入密钥备份 cron，与现有数据库备份一起调度
- **D-03:** DOPPLER_TOKEN 通过 docker-compose.yml 环境变量注入 noda-ops 容器（容器需要 Doppler CLI + token）

### BFG Git 历史清理
- **D-04:** 清理所有敏感文件：.env.production（3 次提交）+ .sops.yaml + config/secrets.sops.yaml
- **D-05:** 使用脚本自动化执行 BFG 清理 + force push（用户确认脚本内容后执行）
- **D-06:** BFG 执行后自动验证：检查 git log 中目标文件不再出现，生成验证报告
- **D-07:** docker/.env 从未被 git 追踪（始终在 .gitignore 中），不需要 BFG 清理

### Claude's Discretion
- backup-doppler-secrets.sh 是否需要修改以适应 noda-ops 容器环境（路径、依赖）
- noda-ops Dockerfile 是否需要安装 doppler CLI
- BFG 脚本的具体命令和参数
- cron 表达式的具体时间（避免和数据库备份冲突）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 密钥管理需求
- `.planning/REQUIREMENTS.md` — BACKUP-01, BACKUP-02 需求定义
- `.planning/ROADMAP.md` — Phase 42 范围和 Success Criteria
- `.planning/STATE.md` — 项目状态和已锁定决策

### 前序 Phase 决策
- `.planning/phases/39-infisical-infra/39-CONTEXT.md` — Doppler 工具选择和备份策略（D-05）
- `.planning/phases/40-jenkins-pipeline/40-CONTEXT.md` — Pipeline 密钥注入模式
- `.planning/phases/41-migration-cleanup/41-CONTEXT.md` — 明文文件删除和 SOPS 清理

### 现有备份脚本
- `scripts/backup/backup-doppler-secrets.sh` — Doppler 密钥离线备份脚本（已存在，需集成到 cron）
- `scripts/backup/lib/config.sh` — 备份系统配置加载
- `deploy/entrypoint-ops.sh` — noda-ops 容器入口脚本（现有 cron 机制）

### Docker Compose 配置
- `docker/docker-compose.yml` — noda-ops 服务定义（需添加 DOPPLER_TOKEN 环境变量）
- `docker/docker-compose.prod.yml` — 生产环境 overlay

### Git 历史敏感文件
- `.env.production` — 3 次提交（240c59e, c15faba, ad220f6），含 VERCEL_OIDC_TOKEN + 占位符密码
- `.sops.yaml` — SOPS 配置（Phase 41 删除，需 BFG 清理历史）
- `config/secrets.sops.yaml` — 加密密钥文件（Phase 41 删除，需 BFG 清理历史）

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/backup/backup-doppler-secrets.sh` — 完整的下载 → age 加密 → B2 上传流程，支持 --dry-run
- `deploy/entrypoint-ops.sh` — noda-ops 容器 cron 入口，已有数据库备份调度
- B2 凭据已配置在 noda-ops 环境变量中（B2_ACCOUNT_ID, B2_APPLICATION_KEY, B2_BUCKET_NAME）

### Established Patterns
- noda-ops 容器运行 cron 定时任务（数据库备份每 6 小时一次）
- age 加密 + B2 上传（backup-doppler-secrets.sh 已实现）
- Docker Compose 环境变量注入模式

### Integration Points
- `deploy/entrypoint-ops.sh` — 添加密钥备份 cron 行
- `docker/docker-compose.yml` — noda-ops 服务添加 DOPPLER_TOKEN 环境变量
- noda-ops Dockerfile — 可能需要安装 doppler CLI

### Git 历史分析结果
- `.env.production` 提交了 3 次，含 1 个真实 JWT（VERCEL_OIDC_TOKEN，已过期）+ 占位符密码
- `.sops.yaml` 和 `config/secrets.sops.yaml` 被 Phase 41 删除，历史中仍存在
- `docker/.env` 从未被 git 追踪，无需清理

</code_context>

<specifics>
## Specific Ideas

- backup-doppler-secrets.sh 的 AGE_PUBLIC_KEY 已硬编码在脚本中
- VERCEL_OIDC_TOKEN 已过期（exp: 1775207817 ≈ 2026-04-01），但清理 git 历史仍是最佳实践
- 占位符密码（postgres_password_change_me, admin_password_change_me）不是真实密钥
- BFG 脚本应在执行前列出将被清理的 commit 数量供用户确认

</specifics>

<deferred>
## Deferred Ideas

None — 讨论在 Phase 范围内完成。

</deferred>

---

*Phase: 42-backup-security*
*Context gathered: 2026-04-19*
