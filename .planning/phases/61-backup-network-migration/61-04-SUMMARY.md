---
phase: 61-backup-network-migration
plan: 04
status: complete
created: 2026-05-19
---

# Plan 61-04: 修复 Phase 61 验证缺口

## 结果

3 个缺口全部修复，周验证测试通过：

| # | 缺口 | 状态 | 修复 |
|---|------|------|------|
| 1 | config.sh B2 凭证覆盖 | ✅ 修复 | config.sh 第 72-75 行改用 `${VAR:-${DEFAULT}}` 保留环境变量；r4s 通过 volume 挂载覆盖 |
| 2 | DOPPLER_TOKEN 缺失 | ✅ 修复 | 创建 Doppler service token 并配置到 docker/.env；添加 /root/.doppler tmpfs |
| 3 | pre-prod hosts 配置 | ✅ 修复 | /etc/hosts 改为 192.168.100.1，curl https://class.noda.test:8443 返回 200 |
| 4 | 周验证测试 download_failed | ✅ 修复 | test-verify.sh 两个 bug：stdout log 污染 + PGPASSWORD 缺失（commit e301e71） |

## 根因分析

### 周验证测试失败（2 个 bug）

**Bug 1: stdout 污染**
- `log_info`/`log_success` 输出到 stdout，而 `download_latest_backup` 和 `create_test_database` 通过 `echo` 返回值也走 stdout
- 调用方 `backup_file=$(download_latest_backup "$db_name")` 收到 5 行字符串
- `[[ ! -f "$backup_file" ]]` 检查多行路径失败 → download_failed
- 修复：所有 log 调用重定向到 stderr（`>&2`）

**Bug 2: PGPASSWORD 缺失**
- `test-verify.sh` 中 9 处 `psql`/`pg_restore` 调用没有设置 `PGPASSWORD`
- 容器内 PostgreSQL 需要密码认证，导致 `fe_sendauth: no password supplied`
- 其他库（db.sh, verify.sh）都使用 `PGPASSWORD=$POSTGRES_PASSWORD`，test-verify.sh 遗漏了
- 修复：所有调用添加 `PGPASSWORD="$POSTGRES_PASSWORD"`

## 关键修改

- `scripts/backup/lib/config.sh`: B2 变量保留环境变量（commit e6d70c1）
- `docker/docker-compose.prod.yml`: noda-ops 添加 `/root/.doppler` tmpfs（commit 89de664）
- `docker/docker-compose.r4s.yml`: noda-ops 挂载修复后的 config.sh + test-verify.sh（commit 89de664, e301e71）
- `scripts/backup/lib/test-verify.sh`: stdout 污染修复 + PGPASSWORD 添加（commit e301e71）
- `docker/.env`: 添加 DOPPLER_TOKEN（未提交，含敏感信息）

## 验证结果

| 验证项 | 结果 |
|--------|------|
| pre-prod HTTPS (class.noda.test:8443) | ✅ HTTP 200 |
| Doppler 密钥备份 | ✅ 加密并上传 B2 成功 |
| B2 文件列表 | ✅ 12 个文件可见 |
| 周验证测试 (keycloak) | ✅ 5/5 步骤通过，88 个表恢复，126 条记录验证 |
