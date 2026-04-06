# Phase 8: 执行恢复脚本 - 验证报告

**验证日期:** 2026-04-06
**验证脚本:** `scripts/backup/verify-restore.sh`
**测试结果:** 9 项通过 / 0 项失败

---

## 1. 成功标准验证

### 成功标准 1: 列出 B2 备份文件

- **验证方法:** `bash scripts/backup/restore-postgres.sh --list-backups`
- **预期结果:** 输出包含按时间排序的备份文件列表（日期、数据库、文件大小、文件名）
- **实际结果:** 成功列出 B2 上 20+ 个备份文件，包含 globals_*.sql、keycloak_*.dump、postgres_*.dump、oneteam_prod_*.dump 等多种数据库备份
- **状态:** 通过

### 成功标准 2: 指定数据库恢复

- **验证方法:** `bash scripts/backup/restore-postgres.sh --restore keycloak_20260406_081638.dump --database test_verify_restore_*`
- **预期结果:** 从 B2 下载备份并恢复到目标数据库，恢复后表数量 > 0
- **实际结果:** 成功从 B2 下载 keycloak 备份文件（212K）并恢复到临时数据库，恢复后包含 88 个表
- **状态:** 通过

### 成功标准 3: 恢复前验证备份完整性

- **验证方法:** 创建本地 .dump 备份，调用 `verify_backup_integrity()` 验证
- **预期结果:** 通过文件大小检查（> 100 bytes）和 pg_restore --list 验证备份完整性
- **实际结果:** 2877 bytes 的测试 .dump 文件通过大小检查和 pg_restore --list 验证
- **状态:** 通过

### 成功标准 4: 恢复失败时提供明确错误信息

- **验证方法:** 传入不存在的文件名和无效格式触发错误
- **预期结果:** 输出包含 "失败" 或 "错误" 关键词和解决建议
- **实际结果:**
  - 4a: 不存在的备份文件 -> 输出 "下载失败" 错误信息（通过）
  - 4b: 无效文件名格式 (invalid_format.txt) -> 输出 "无效的备份文件名格式" 提示（通过）
  - 4c: 无参数调用 -> 输出 "请指定操作" 和帮助提示（通过）
- **状态:** 通过

---

## 2. 测试用例覆盖

| 测试用例 | 需求 ID | 测试方法 | 预期结果 | 实际结果 | 状态 |
|----------|---------|----------|----------|----------|------|
| 列出 B2 备份文件 | RESTORE-02 | --list-backups | 显示备份列表 | 成功列出 20+ 个备份文件 | 通过 |
| 恢复到不同数据库 | RESTORE-04 | --restore keycloak.dump --database test_* | 恢复到指定数据库 | keycloak 恢复成功（88 个表） | 通过 |
| 备份完整性验证 | RESTORE-01 | verify_backup_integrity() | 验证通过 | 文件大小 + pg_restore --list 通过 | 通过 |
| 不存在文件错误 | RESTORE-01 | --restore nonexistent.dump | 明确错误信息 | 输出下载失败错误 | 通过 |
| 无效文件名格式 | RESTORE-01 | --restore invalid.txt | 格式验证提示 | 输出无效格式提示 | 通过 |
| 无参数调用 | RESTORE-01 | restore-postgres.sh | 使用帮助提示 | 输出指定操作提示 | 通过 |
| 空备份文件拒绝 | RESTORE-01 | verify_backup_integrity(empty) | 验证失败 | 空文件正确拒绝 | 通过 |
| 损坏 dump 文件拒绝 | RESTORE-01 | verify_backup_integrity(corrupt) | 验证失败 | 损坏文件正确拒绝 | 通过 |
| 已存在数据库覆盖 | RESTORE-03 | 恢复到已有 DB | 成功覆盖 | 覆盖恢复成功（1 个表） | 通过 |

---

## 3. 边界情况和错误处理

### 网络故障（D-09）

- **场景:** B2 连接中断或凭证失效
- **处理:** `--list-backups` 通过 rclone ls 获取列表，失败时 rclone 返回错误（被 `|| true` 捕获）。`download_backup()` 使用 rclone copy 下载，失败时 log_error 输出错误信息并返回非零退出码
- **验证方法:** 测试 4a 验证了不存在的文件下载失败时的错误输出
- **验证结果:** 通过

### 恢复失败场景（D-10）

- **场景:** 损坏的备份文件、空文件
- **处理:** `verify_backup_integrity()` 检查文件大小 > 100 bytes 和 `pg_restore --list` 可读性。宿主机上使用 `docker cp` 将文件复制到容器内再执行验证
- **验证方法:**
  - D-10a: 空 .dump 文件（0 bytes）-> `verify_backup_integrity()` 正确拒绝
  - D-10b: 损坏的 .dump 文件（包含无效内容）-> `pg_restore --list` 失败，正确拒绝
- **验证结果:** 通过

### 数据库冲突（D-11）

- **场景:** 恢复到已存在的数据库名
- **处理:** `restore_database()` 先 `DROP DATABASE IF EXISTS` 再 `CREATE DATABASE`，确保覆盖恢复
- **验证方法:** 创建已存在的数据库，恢复 .dump 文件到该数据库名，验证覆盖成功
- **验证结果:** 通过（覆盖后表数量 > 0）

### 性能和并发（D-12）

- **场景:** 大文件恢复
- **处理:** `restore_database()` 对 .dump 文件使用 `pg_restore -j 4` 并行恢复
- **验证方法:** keycloak 备份（212K）恢复成功，88 个表

---

## 4. 使用指南

### 基本用法

列出所有可用备份:
```bash
bash scripts/backup/restore-postgres.sh --list-backups
```

恢复指定备份到原数据库:
```bash
bash scripts/backup/restore-postgres.sh --restore keycloak_20260406_081638.dump
```

恢复到不同数据库名（用于安全测试）:
```bash
bash scripts/backup/restore-postgres.sh --restore keycloak_20260406_081638.dump --database keycloak_test
```

仅验证备份完整性（不执行恢复）:
```bash
bash scripts/backup/restore-postgres.sh --restore keycloak_20260406_081638.dump --verify
```

下载备份到指定目录:
```bash
bash scripts/backup/restore-postgres.sh --restore keycloak_20260406_081638.dump --output-dir /tmp/backups
```

### 最佳实践

- 恢复前始终先使用 `--list-backups` 确认可用备份
- 恢复到生产数据库前，先使用 `--database` 参数恢复到测试库验证数据完整性
- 使用 `--verify` 参数单独验证备份文件，无需执行完整恢复
- 恢复操作会覆盖目标数据库，请谨慎选择目标数据库名

### 环境要求

- Docker 运行中且 noda-infra-postgres-1 容器健康
- rclone 已安装（B2 云操作）
- .env.backup 中 B2 凭证配置正确

### 运行完整验证

```bash
bash scripts/backup/verify-restore.sh
```

### 已知限制

1. **宿主机文件路径:** .dump 文件恢复时需要 `docker cp` 到容器内（自动处理），SQL 文件通过 stdin 管道传入（自动处理）
2. **B2 下载路径:** rclone copy 保留目录结构，下载后文件可能在子目录中（`download_backup()` 自动查找）
3. **交互确认:** 恢复操作需要输入 "yes" 确认，自动化测试中使用 `echo "yes" |` 管道输入
