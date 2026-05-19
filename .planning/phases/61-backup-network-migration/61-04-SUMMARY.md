---
phase: 61-backup-network-migration
plan: 04
status: partial
created: 2026-05-19
---

# Plan 61-04: 修复 Phase 61 验证缺口

## 结果

3 个缺口中修复了 2 个，1 个需要进一步调查：

| # | 缺口 | 状态 | 修复 |
|---|------|------|------|
| 1 | config.sh B2 凭证覆盖 | ✅ 修复 | config.sh 第 72-75 行改用 `${VAR:-${DEFAULT}}` 保留环境变量；r4s 通过 volume 挂载覆盖 |
| 2 | DOPPLER_TOKEN 缺失 | ✅ 修复 | 创建 Doppler service token 并配置到 docker/.env；添加 /root/.doppler tmpfs |
| 3 | pre-prod hosts 配置 | ✅ 修复 | /etc/hosts 改为 192.168.100.1，curl https://class.noda.test:8443 返回 200 |

## 未解决

- **周验证测试 (BACKUP-04)**: `test-verify-weekly.sh --databases "keycloak"` 仍然 download_failed。B2 连接正常（list_b2_backups 返回文件列表），但脚本内部的下载链路存在其他问题，需要进一步调查。

## 关键修改

- `scripts/backup/lib/config.sh`: B2 变量保留环境变量（commit e6d70c1）
- `docker/docker-compose.prod.yml`: noda-ops 添加 `/root/.doppler` tmpfs（commit 89de664）
- `docker/docker-compose.r4s.yml`: noda-ops 挂载修复后的 config.sh（commit 89de664）
- `docker/.env`: 添加 DOPPLER_TOKEN（未提交，含敏感信息）

## 验证结果

| 验证项 | 结果 |
|--------|------|
| pre-prod HTTPS (class.noda.test:8443) | ✅ HTTP 200 |
| Doppler 密钥备份 | ✅ 加密并上传 B2 成功 |
| B2 文件列表 | ✅ 12 个文件可见 |
| 周验证测试 | ❌ download_failed（需调查） |
