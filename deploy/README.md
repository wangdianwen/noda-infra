# Noda 数据库备份系统 - 部署指南

## 📦 部署架构

```
opdev (Docker Container)
├── cron 服务（定时调度）
│   ├── 每天 03:00 - 执行备份
│   ├── 周日 03:00 - 执行验证测试
│   └── 每 6 小时 - 清理历史记录
├── backup-postgres.sh（备份脚本）
├── test-verify-weekly.sh（测试脚本）
└── 挂载卷
    ├── ./deploy/volumes/backup（备份文件）
    ├── ./deploy/volumes/history（历史记录）
    └── ./deploy/volumes/logs（日志文件）
```

## 🚀 快速开始

### 1. 配置环境变量

```bash
# 复制配置模板
cp scripts/backup/.env.example scripts/backup/.env.backup

# 编辑配置文件
vim scripts/backup/.env.backup
```

**必需配置**：
```bash
POSTGRES_HOST=noda-infra-postgres-1  # 或 host.docker.internal
POSTGRES_PORT=5432
POSTGRES_USER=postgres

B2_ACCOUNT_ID=your_account_id
B2_APPLICATION_KEY=your_application_key
B2_BUCKET_NAME=noda-backups
B2_PATH=backups/postgres/

ALERT_EMAIL=your_email@example.com  # 可选
```

### 2. 构建镜像

```bash
./deploy.sh build
```

### 3. 启动服务

```bash
./deploy.sh start
```

### 4. 验证状态

```bash
./deploy.sh status
```

## 📋 部署脚本命令

```bash
./deploy.sh build    # 构建 Docker 镜像
./deploy.sh start    # 启动容器
./deploy.sh stop     # 停止容器
./deploy.sh restart  # 重启容器
./deploy.sh logs     # 查看容器日志
./deploy.sh status   # 查看容器状态
./deploy.sh clean    # 清理容器
```

## 📊 监控和日志

### 查看实时日志

```bash
# 容器日志
./deploy.sh logs

# 备份日志
tail -f deploy/volumes/logs/backup.log

# 测试日志
tail -f deploy/volumes/logs/test.log
```

### 进入容器调试

```bash
docker exec -it opdev bash
```

### 手动触发备份

```bash
docker exec opdev /app/backup-postgres.sh
```

### 手动触发测试

```bash
docker exec opdev /app/test-verify-weekly.sh
```

## 🔧 配置说明

### 定时任务（Crontab）

```cron
# 每天凌晨 3:00 执行备份
0 3 * * * /app/backup-postgres.sh >> /var/log/noda-backup/backup.log 2>&1

# 每周日凌晨 3:00 执行验证测试
0 3 * * 0 /app/test-verify-weekly.sh >> /var/log/noda-backup/test.log 2>&1

# 每 6 小时清理旧历史记录
0 */6 * * * /app/lib/metrics.sh cleanup 2>/dev/null || true

# 每天凌晨 4:00 清理旧备份文件
0 4 * * * find /tmp/postgres_backups -type f -name "*.dump" -mtime +7 -delete 2>/dev/null || true
```

### 修改定时任务

编辑 `deploy/crontab`，然后重新构建镜像：

```bash
./deploy.sh stop
./deploy.sh build
./deploy.sh start
```

## 🗂️ 数据卷

| 卷路径 | 容器内路径 | 用途 |
|--------|-----------|------|
| `./deploy/volumes/backup` | `/tmp/postgres_backups` | 备份文件存储 |
| `./deploy/volumes/history` | `/app/history` | 历史记录（指标和告警） |
| `./deploy/volumes/logs` | `/var/log/noda-backup` | 日志文件 |

## 🔒 安全建议

1. **轮换 B2 Key**
   - 定期（每 6 个月）轮换 B2 Application Key
   - 使用最小权限原则（仅限指定 bucket）

2. **文件权限**
   ```bash
   chmod 600 scripts/backup/.env.backup
   ```

3. **日志管理**
   - 定期检查日志文件大小
   - 配置日志轮转（可选）

4. **网络安全**
   - 容器仅内网访问
   - 限制数据库访问 IP

## 🛠️ 故障排查

### 容器无法启动

```bash
# 查看容器日志
docker logs opdev

# 检查配置文件
cat scripts/backup/.env.backup

# 验证环境变量
docker exec opdev env | grep -E "POSTGRES|B2_"
```

### 备份失败

```bash
# 查看备份日志
tail -100 deploy/volumes/logs/backup.log

# 手动测试数据库连接
docker exec opdev pg_isready -h $POSTGRES_HOST -p $POSTGRES_PORT

# 测试 B2 连接
docker exec opdev rclone ls b2:noda-backups
```

### 测试失败

```bash
# 查看测试日志
tail -100 deploy/volumes/logs/test.log

# 手动运行测试
docker exec opdev /app/test-verify-weekly.sh
```

## 📈 性能优化

1. **备份文件大小**
   - 监控单个数据库备份大小
   - 考虑启用压缩

2. **网络带宽**
   - 上传失败时检查网络速度
   - 调整 rclone 并发数

3. **磁盘空间**
   - 定期清理旧备份文件
   - 监控卷使用率

## 🔄 更新和升级

### 更新脚本

```bash
# 拉取最新代码
git pull

# 重新构建镜像
./deploy.sh stop
./deploy.sh build
./deploy.sh start
```

### 零停机升级

```bash
# 启动新容器（不同名称）
docker run -d --name opdev-new ...

# 验证新容器正常后切换
docker stop opdev
docker rm opdev
docker rename opdev-new opdev
```

## 📞 支持

如有问题，请检查：
1. 日志文件：`deploy/volumes/logs/`
2. 容器状态：`./deploy.sh status`
3. 配置文件：`scripts/backup/.env.backup`
