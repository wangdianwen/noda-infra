# 数据库恢复指南

本文档提供完整的数据库恢复步骤和常见问题解决方案。

## 备份文件位置

备份文件存储在以下目录：

- **容器内路径**: `/var/lib/postgresql/backup/YYYY/MM/DD/`
- **宿主机路径**: `/var/lib/docker/volumes/noda-infra_postgres_data/_data/backup/YYYY/MM/DD/`

## 备份文件命名

备份文件使用以下命名格式：

- **数据库备份**: `{db_name}_{YYYYMMDD_HHmmss}.dump`
- **全局对象**: `globals_{YYYYMMDD_HHmmss}.sql`
- **元数据**: `metadata_{db_name}_{YYYYMMDD_HHmmss}.json`

示例：
```
keycloak_db_20260406_143000.dump
globals_20260406_143000.sql
metadata_keycloak_db_20260406_143000.json
```

## 恢复步骤

### 1. 查看可用备份

```bash
# 列出最近的备份
ls -lth /var/lib/docker/volumes/noda-infra_postgres_data/_data/backup/2026/04/06/

# 查看元数据
cat /var/lib/docker/volumes/noda-infra_postgres_data/_data/backup/2026/04/06/metadata_keycloak_db_20260406_143000.json | jq
```

### 2. 恢复全局对象（可选）

全局对象包括角色和表空间定义，通常在恢复数据库之前先恢复：

```bash
# 恢复角色和表空间定义
docker exec -i noda-infra-postgres-1 psql -U postgres -d postgres < \
  /var/lib/docker/volumes/noda-infra_postgres_data/_data/backup/2026/04/06/globals_20260406_143000.sql
```

### 3. 恢复单个数据库

**恢复到原数据库（会覆盖现有数据）：**

```bash
docker exec noda-infra-postgres-1 pg_restore -U postgres -d keycloak_db \
  /var/lib/postgresql/backup/2026/04/06/keycloak_db_20260406_143000.dump
```

**恢复到新数据库（用于测试）：**

```bash
# 创建新数据库
docker exec noda-infra-postgres-1 psql -U postgres -d postgres -c "CREATE DATABASE keycloak_db_test;"

# 恢复到新数据库
docker exec noda-infra-postgres-1 pg_restore -U postgres -d keycloak_db_test \
  /var/lib/postgresql/backup/2026/04/06/keycloak_db_20260406_143000.dump
```

### 4. 验证恢复结果

```bash
# 检查数据库是否恢复成功
docker exec noda-infra-postgres-1 psql -U postgres -d keycloak_db -c "\dt"

# 检查表数量
docker exec noda-infra-postgres-1 psql -U postgres -d keycloak_db -t -c \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';"

# 检查特定表的记录数
docker exec noda-infra-postgres-1 psql -U postgres -d keycloak_db -t -c \
  "SELECT COUNT(*) FROM user_entity;"
```

## 测试模式验证（D-43）

使用主脚本的测试模式验证完整备份和恢复流程：

```bash
# 运行测试模式
bash scripts/backup/backup-postgres.sh --test

# 测试模式会自动：
# 1. 创建测试数据库
# 2. 执行备份
# 3. 恢复到新数据库
# 4. 验证数据完整性
# 5. 清理测试资源
```

测试模式使用独立的测试数据库（`test_backup_db`），不会影响生产数据。

## 常见问题

### Q1: 恢复时提示数据库已存在？

**A**: 有两种解决方案：

1. **删除现有数据库（谨慎操作）**：
   ```bash
   docker exec noda-infra-postgres-1 psql -U postgres -d postgres -c "DROP DATABASE keycloak_db;"
   docker exec noda-infra-postgres-1 psql -U postgres -d postgres -c "CREATE DATABASE keycloak_db;"
   ```

2. **恢复到新的数据库名称**：
   ```bash
   docker exec noda-infra-postgres-1 psql -U postgres -d postgres -c "CREATE DATABASE keycloak_db_restored;"
   docker exec noda-infra-postgres-1 pg_restore -U postgres -d keycloak_db_restored /path/to/backup.dump
   ```

### Q2: 恢复时提示角色不存在？

**A**: 先恢复全局对象（`globals_*.sql` 文件）：

```bash
docker exec -i noda-infra-postgres-1 psql -U postgres -d postgres < /path/to/globals_20260406_143000.sql
```

全局对象文件包含所有角色和表空间定义。

### Q3: 如何验证备份文件是否完整？

**A**: 使用 `pg_restore --list` 查看备份内容：

```bash
docker exec noda-infra-postgres-1 pg_restore --list /var/lib/postgresql/backup/2026/04/06/keycloak_db_20260406_143000.dump
```

如果输出包含完整的 TOC（Table of Contents），说明备份文件完整。

也可以检查元数据文件中的 SHA-256 校验和：

```bash
# 查看元数据中的校验和
cat /path/to/metadata_keycloak_db_20260406_143000.json | jq '.checksum'

# 计算实际文件的校验和
sha256sum /path/to/keycloak_db_20260406_143000.dump
```

### Q4: 如何使用测试模式验证备份系统？

**A**: 运行测试模式脚本：

```bash
bash scripts/backup/backup-postgres.sh --test
```

测试模式会：
1. 创建测试数据库（`test_backup_db`）
2. 插入测试数据
3. 执行完整备份
4. 恢复到新数据库（`test_backup_db_restore`）
5. 验证数据完整性
6. 清理测试资源

所有测试通过说明备份系统工作正常。

### Q5: 恢复失败后如何排查问题？

**A**: 按照以下步骤排查：

1. **检查备份文件完整性**：
   ```bash
   docker exec noda-infra-postgres-1 pg_restore --list /path/to/backup.dump
   ```

2. **检查数据库日志**：
   ```bash
   docker logs noda-infra-postgres-1 --tail 100
   ```

3. **检查磁盘空间**：
   ```bash
   docker exec noda-infra-postgres-1 df -h /var/lib/postgresql/data
   ```

4. **检查权限**：
   ```bash
   docker exec noda-infra-postgres-1 psql -U postgres -d postgres -c "\du"
   ```

## 注意事项

- ⚠️ **恢复到生产数据库前，先恢复到测试数据库验证**
- ⚠️ **恢复会覆盖目标数据库的所有数据，不可逆**
- ⚠️ **确保磁盘空间充足（数据库大小 × 2）**
- ⚠️ **恢复期间数据库可能不可用**
- ✅ **使用 `--test` 模式可以在不影响生产的情况下验证备份系统**
- ✅ **每次备份都会生成元数据文件，包含校验和和文件信息**

## 恢复流程图

```
1. 查看可用备份
   ↓
2. 检查备份文件完整性（pg_restore --list）
   ↓
3. 恢复全局对象（可选）
   ↓
4. 恢复数据库（pg_restore）
   ↓
5. 验证恢复结果（表数量、记录数）
   ↓
6. 应用程序连接测试
```

## 联系支持

如果遇到问题，请联系运维团队并提供以下信息：

- 备份文件路径
- 错误消息（完整输出）
- PostgreSQL 版本：17.9
- 数据库大小
- 磁盘空间使用情况

---

**最后更新**: 2026-04-06
**PostgreSQL 版本**: 17.9
**备份系统版本**: Phase 1 (本地备份核心)
