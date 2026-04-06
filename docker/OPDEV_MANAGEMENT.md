# opdev 备份服务 - Docker Compose 管理指南

## 📋 概述

opdev 备份服务已成功集成到 **noda-infra** Docker Compose 分组中，与其他服务（postgres、nginx、keycloak 等）统一管理。

## 🚀 快速开始

### 启动所有服务（包括 opdev）
```bash
cd /path/to/noda-infra
docker-compose -f docker/docker-compose.yml up -d
```

### 仅启动 opdev 服务
```bash
docker-compose -f docker/docker-compose.yml up -d opdev
```

### 停止 opdev 服务
```bash
docker-compose -f docker/docker-compose.yml stop opdev
```

### 重启 opdev 服务
```bash
docker-compose -f docker/docker-compose.yml restart opdev
```

### 查看 opdev 日志
```bash
docker-compose -f docker/docker-compose.yml logs -f opdev
```

### 查看 opdev 服务状态
```bash
docker-compose -f docker/docker-compose.yml ps opdev
```

## 📊 服务列表

opdev 现在是 noda-infra 分组的一部分：

```
NAME                        STATUS
noda-infra-cloudflared-1    Up 15 hours
noda-infra-keycloak-1       Up 15 hours
noda-infra-nginx-1          Up 15 hours
noda-infra-postgres-1       Up 21 seconds (healthy)
opdev                       Up 21 seconds (health: starting)  ← 新增
```

## 🔧 配置文件

### 环境变量配置
编辑 `config/environments/.env` 或 `scripts/backup/.env.backup`：

```bash
# Backblaze B2 配置
B2_ACCOUNT_ID=00424f0b17dd82b0000000001
B2_APPLICATION_KEY=K0048667N4HUsLs35TYfyJzlY8i/Gx8
B2_BUCKET_NAME=noda-backups
B2_PATH=backups/postgres/

# 备份告警配置
ALERT_EMAIL=your-alert-email@example.com
```

### Docker Compose 配置
`docker/docker-compose.yml` 中的 opdev 服务定义：

```yaml
opdev:
  build:
    context: ..
    dockerfile: deploy/Dockerfile.backup
  image: noda-backup:latest
  container_name: opdev
  restart: unless-stopped
  environment:
    POSTGRES_HOST: noda-infra-postgres-1
    POSTGRES_PORT: 5432
    # ... 其他环境变量
  volumes:
    - ./volumes/backup:/tmp/postgres_backups
    - ./volumes/history:/app/history
    - ./volumes/logs:/var/log/noda-backup
  networks:
    - noda-network
  depends_on:
    - postgres
```

## 📁 目录结构

```
docker/
├── docker-compose.yml       # 主配置文件（包含 opdev）
└── volumes/
    ├── backup/              # 备份文件存储
    │   └── 2026/04/06/
    │       ├── globals_*.sql
    │       └── *_*.dump
    ├── history/             # 历史记录存储
    │   └── history.json
    └── logs/                # 日志文件存储
        ├── backup.log
        └── test.log
```

## 🧪 测试命令

### 手动执行备份
```bash
docker exec opdev sh -c 'cd /app && bash backup-postgres.sh'
```

### 手动执行验证测试
```bash
docker exec opdev sh -c 'cd /app && bash test-verify-weekly.sh'
```

### 查看备份文件
```bash
ls -lh docker/volumes/backup/$(date +%Y/%m/%d)/
```

### 查看日志
```bash
tail -f docker/volumes/logs/backup.log
```

## 🔍 故障排查

### opdev 无法启动
```bash
# 查看详细日志
docker-compose -f docker/docker-compose.yml logs --tail=100 opdev

# 检查依赖服务状态
docker-compose -f docker/docker-compose.yml ps postgres
```

### 备份失败
```bash
# 进入容器检查
docker exec -it opdev sh

# 测试数据库连接
docker exec opdev sh -c 'cd /app && source lib/health.sh && check_postgres_connection'

# 查看备份目录
docker exec opdev ls -lh /tmp/postgres_backups/
```

### B2 上传失败
```bash
# 测试 rclone 配置
docker exec opdev rclone ls b2:noda-backups/

# 检查 rclone 配置文件
docker exec opdev cat /root/.config/rclone/rclone.conf
```

## ⏰ 定时任务

opdev 容器内部的定时任务（Crontab）：

```cron
# 每天凌晨 3 点执行备份
0 3 * * * /app/backup-postgres.sh >> /var/log/noda-backup/backup.log 2>&1

# 每周日凌晨 3 点执行验证测试
0 3 * * 0 /app/test-verify-weekly.sh >> /var/log/noda-backup/test.log 2>&1

# 每 6 小时清理历史记录
0 */6 * * * /app/lib/metrics.sh cleanup 2>/dev/null || true

# 每天凌晨 4 点清理旧备份（7 天前）
0 4 * * * find /tmp/postgres_backups -type f -name "*.dump" -mtime +7 -delete 2>/dev/null || true
```

## 🔐 安全提醒

**请立即处理以下安全问题**：

1. **轮换 B2 Application Key**
   - 当前密钥：`K0048667N4HUsLs35TYfyJzlY8i/Gx8`
   - 登录 [Backblaze B2 控制台](https://secure.backblaze.com/b2_buckets.htm)
   - 删除旧密钥，创建新的 Limited Application Key

2. **修改数据库密码**
   - 当前为默认值，建议使用强密码

3. **配置告警邮箱**
   - 设置 `ALERT_EMAIL` 以接收备份失败告警

## 📖 相关文档

- [部署总结](../scripts/backup/DEPLOYMENT_SUMMARY.md) - 完整部署文档
- [Docker Compose 配置](./docker-compose.yml) - 服务定义
- [环境变量配置](../config/environments/.env.example) - 配置说明

---

*最后更新：2026-04-06*
*服务状态：运行中*
*容器名称：opdev*
*分组：noda-infra*
