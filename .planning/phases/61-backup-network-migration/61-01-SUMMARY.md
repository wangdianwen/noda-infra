---
phase: 61-backup-network-migration
plan: 01
status: partial
created: 2026-05-19
---

# Plan 61-01: 验证 r4s 备份 cronjob

## 结果

| 验证项 | 状态 | 说明 |
|--------|------|------|
| pg_dump 备份 | ✅ 通过 | 5 个数据库 + 全局对象全部备份成功 |
| B2 云端上传 | ✅ 通过 | 6 个文件上传到 B2，校验和验证通过 |
| Doppler 密钥备份 | ⚠️ 跳过 | DOPPLER_TOKEN 未在 docker-compose 环境变量中配置 |
| 周验证测试 | ❌ 失败 | config.sh source 时清空 B2 凭证，list_b2_backups 返回空 |

## 详细结果

### pg_dump 备份 (BACKUP-01)
- 备份目录: /tmp/postgres_backups/2026/05/18/
- 数据库: keycloak (242KB), noda_agent (9KB), noda_preprod (58KB), noda_prod (260KB), postgres (1KB)
- 全局对象: globals_20260518_204347.sql (946B)
- 耗时: 6s (备份) + 10s (上传)

### B2 云端上传 (BACKUP-02)
- 路径: b2remote:noda-backups/backups/postgres/2026/05/18/
- 校验和验证通过
- 旧备份清理正常（7天策略）

### Doppler 密钥备份 (BACKUP-03)
- 原因: `docker exec noda-ops env | grep DOPPLER_TOKEN` 返回空值
- docker-compose.yml 引用 `${DOPPLER_TOKEN}` 但 .env/.env.prod 中未设置
- **需要在 docker/.env.prod 中添加 DOPPLER_TOKEN**

### 周验证测试 (BACKUP-04)
- 原因: `config.sh` 第 72 行 `B2_ACCOUNT_ID="${DEFAULT_B2_ACCOUNT_ID}"` 在 source 时用空默认值覆盖了环境变量
- `load_config()` 恢复了凭证，但 `list_b2_backups` 中的 `setup_rclone_config` 创建的临时配置文件凭证为空
- **这是代码缺陷**，需要修复 config.sh 的加载顺序

## 关键发现

1. noda-ops 容器健康运行（Up 24 hours, healthy）
2. supervisord、cron、cloudflared 进程正常
3. rclone 配置正确（entrypoint-ops.sh 初始化的配置文件可用）
4. SSH 访问: `ssh -i ~/.ssh/id_noda_r4s root@192.168.100.1`

## 后续行动

- [ ] 配置 DOPPLER_TOKEN 到 docker/.env.prod
- [ ] 修复 config.sh B2 凭证加载顺序（建议在 source 阶段不覆盖非空的 env vars）
