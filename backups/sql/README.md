# 数据库备份说明

## 备份文件

### noda_prod_YYYYMMDD_HHMMSS.sql
生产数据库完整备份，包含：
- 课程数据（425+ 条）
- 教师档案（318+ 条）
- 分类数据（30+ 条）
- 数据源配置

## 恢复方法

```bash
# 方法 1: 使用 docker exec
docker exec -i noda-infra-postgres-1 psql -U postgres -d noda_prod < backups/sql/noda_prod_YYYYMMDD_HHMMSS.sql

# 方法 2: 临时容器恢复
docker run --rm -v noda-infra_postgres_data:/var/lib/postgresql/data \
  -v $(pwd):/backup postgres:17.9 \
  sh -c "cd /backup && psql -U postgres -d noda_prod < noda_prod_YYYYMMDD_HHMMSS.sql"
```

## 自动备份

建议设置 cron 任务自动备份：
```bash
# 每天凌晨 2 点备份
0 2 * * * docker exec noda-infra-postgres-1 pg_dump -U postgres -d noda_prod --no-owner --no-acl --clean > ~/project/noda-infra/backups/sql/noda_prod_$(date +\%Y\%m\%d).sql
```

## 保留策略

- 保留最近 7 天的每日备份
- 保留每周日的备份（4 周）
- 手动备份重要更新前
