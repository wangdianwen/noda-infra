# Phase 61: 备份与网络迁移 - Validation Strategy

---
phase: 61
phase_slug: backup-network-migration
created: 2026-05-19
---

## Validation Approach

本阶段是纯验证/迁移阶段，不生成新代码。验证策略基于 RESEARCH.md 中的 Validation Architecture 部分，使用 SSH docker exec + curl 手动验证。

## Requirement → Test Map

| Req ID | Test Type | Verification Method | Pass Criteria |
|--------|-----------|---------------------|---------------|
| BACKUP-01 | integration | SSH docker exec `backup-postgres.sh` | 备份文件生成 + pg_restore 验证 |
| BACKUP-02 | integration | SSH docker exec rclone check | B2 bucket 中存在备份文件 |
| BACKUP-03 | integration | SSH docker exec `backup-doppler-secrets.sh --dry-run` | age 加密文件生成 |
| BACKUP-04 | integration | SSH docker exec `test-verify-weekly.sh` | 验证测试完成无错误 |
| BACKUP-05 | manual | `docker ps -a` on Mac | Mac noda-ops 容器状态为 Exited |
| NET-01 | integration | curl via Cloudflare + Tunnel 日志 | 外部访问返回 200 |
| NET-02 | integration | `docker port` + curl on r4s | 8080/8081/8443 端口映射正确 |
| NET-03 | integration | curl with /etc/hosts | pre-prod 域名路由返回正确内容 |

## Sampling Rate

- **Per task:** 每个 cronjob 独立验证，成功后才进行下一步（per D-05）
- **Per wave:** Wave 1 所有验证通过后才进入 Wave 2 清理
- **Phase gate:** 8/8 requirements 全部验证通过

## Nyquist Note

本阶段无代码生成，Nyquist 采样验证不适用。所有测试通过 SSH docker exec 执行远程命令验证。
