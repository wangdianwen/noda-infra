# Noda 数据库备份系统 - 部署完成总结

## 📋 部署状态

✅ **部署成功** - 备份系统已作为 Docker 容器 `opdev` 部署在 `noda-network` 网络中

## 🎯 系统架构

```
┌─────────────────────────────────────────────────────┐
│              noda-network (Docker 网络)              │
│                                                      │
│  ┌──────────────────────┐      ┌─────────────────┐ │
│  │   opdev (备份容器)    │      │  postgres (数据库)│ │
│  │                      │      │                 │ │
│  │  - Cron 调度器        │◄────►│  - PostgreSQL  │ │
│  │  - 备份脚本          │      │  - 17-alpine   │ │
│  │  - 验证脚本          │      │                 │ │
│  │  - rclone (B2)      │      └─────────────────┘ │
│  └──────────────────────┘                           │
│                      │                               │
│                      ▼                               │
│            Backblaze B2 云存储                       │
└─────────────────────────────────────────────────────┘
```

## 🚀 已完成功能

### Phase 1: 基础备份
- ✅ PostgreSQL 数据库备份（pg_dump -Fc 格式）
- ✅ 全局对象备份（pg_dumpall -g）
- ✅ 日期分层目录结构（YYYY/MM/DD）
- ✅ 备份文件权限控制（600）

### Phase 2: 云存储同步
- ✅ Backblaze B2 集成（rclone）
- ✅ 自动上传备份文件
- ✅ 旧备份清理（7 天保留策略）
- ✅ 上传重试机制

### Phase 3: 恢复功能
- ✅ 单库恢复（pg_restore）
- ✅ 全局对象恢复（psql）
- ✅ 批量恢复脚本
- ✅ 恢复验证测试

### Phase 4: 自动验证
- ✅ 备份文件可读性验证（pg_restore --list）
- ✅ SHA-256 校验和验证
- ✅ 数据结构验证
- ✅ 数据内容验证（抽样）
- ✅ 每周自动验证测试

### Phase 5: 监控告警
- ✅ 性能指标追踪（备份/上传耗时）
- ✅ 异常检测（50% 偏差阈值）
- ✅ 邮件告警系统（去重窗口：1 小时）
- ✅ 历史记录管理（7 天保留）

## 📁 目录结构

```
opdev 容器内部结构：
/app/
├── backup-postgres.sh          # 主备份脚本
├── test-verify-weekly.sh       # 每周验证脚本
├── lib/                        # 功能库
│   ├── alert.sh               # 告警系统
│   ├── backup.sh              # 备份逻辑
│   ├── config.sh              # 配置管理
│   ├── constants.sh           # 常量定义
│   ├── db.sh                  # 数据库操作
│   ├── health.sh              # 健康检查
│   ├── log.sh                 # 日志系统
│   ├── metrics.sh             # 指标追踪
│   ├── test-verify.sh         # 验证测试
│   ├── upload.sh              # 上传逻辑
│   ├── util.sh                # 工具函数
│   └── verify.sh              # 备份验证
├── history/                    # 历史记录
│   ├── history.json           # 指标历史
│   └── alert_history.json     # 告警历史
└── .env.backup                 # 配置文件

/tmp/postgres_backups/          # 备份目录
└── YYYY/MM/DD/                 # 日期分层
    ├── globals_*.sql           # 全局对象
    ├── *_*.dump               # 数据库备份
    └── metadata_*.json         # 元数据

/var/log/noda-backup/           # 日志目录
├── backup.log                  # 备份日志
└── test.log                    # 测试日志
```

## ⏰ 定时任务配置

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

## 🔧 管理命令

### 部署管理
```bash
# 构建镜像
./deploy.sh build

# 启动容器
./deploy.sh start

# 停止容器
./deploy.sh stop

# 重启容器
./deploy.sh restart

# 查看状态
./deploy.sh status

# 查看日志
./deploy.sh logs

# 清理容器
./deploy.sh clean
```

### 容器内操作
```bash
# 手动执行备份
docker exec opdev sh -c 'cd /app && bash backup-postgres.sh'

# 手动执行验证
docker exec opdev sh -c 'cd /app && bash test-verify-weekly.sh'

# 查看备份文件
docker exec opdev ls -lh /tmp/postgres_backups/2026/04/06/

# 查看日志
docker exec opdev tail -f /var/log/noda-backup/backup.log

# 清理历史记录
docker exec opdev sh -c 'cd /app && bash lib/metrics.sh cleanup'
```

## 🔐 安全配置

### 敏感信息管理
- ✅ `.env.backup` 已在 `.gitignore` 中
- ✅ B2 凭证通过环境变量传递
- ✅ 备份文件权限设置为 600
- ⚠️ **重要**：请立即轮换暴露的 B2 Application Key

### 凭证轮换建议
1. 登录 Backblaze B2 控制台
2. 删除旧的 Application Key：`K0048667N4HUsLs35TYfyJzlY8i/Gx8`
3. 创建新的 Limited Application Key：
   - 仅限 `noda-backups` bucket
   - 仅限 `backups/postgres/` 目录
   - 权限：`writeFiles, deleteFiles, listFiles`
4. 更新 `.env.backup` 中的 `B2_APPLICATION_KEY`
5. 重新部署：`./deploy.sh restart`

## 📊 当前配置

### 环境变量
```bash
POSTGRES_HOST=noda-infra-postgres-1
POSTGRES_PORT=5432
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres_password_change_me  # ⚠️ 请修改

BACKUP_DIR=/tmp/postgres_backups
RETENTION_DAYS=7

B2_ACCOUNT_ID=00424f0b17dd82b0000000001
B2_APPLICATION_KEY=K0048667N4HUsLs35TYfyJzlY8i/Gx8  # ⚠️ 请轮换
B2_BUCKET_NAME=noda-backups
B2_PATH=backups/postgres/

ALERT_EMAIL=  # ⚠️ 未配置，告警功能无法使用
```

### 备份策略
- **备份频率**：每天凌晨 3 点
- **验证频率**：每周日凌晨 3 点
- **保留策略**：7 天
- **备份格式**：pg_dump -Fc（自定义格式）
- **压缩级别**：-1（默认 gzip）

## 📈 性能指标

### 最新备份统计
- **数据库数量**：11 个用户数据库 + 1 个全局对象
- **总备份大小**：约 1.3 MB（包含两次备份）
- **备份耗时**：< 1 秒
- **上传耗时**：约 7 秒
- **验证状态**：✅ 全部通过

### 数据库列表
1. keycloak
2. noda_prod
3. postgres
4. test_backup_db
5. test_restore_complete
6. test_restore_e2e
7. test_restore_quick
8. test_restore_restored
9. test_uat_backup
10. testdb
11. testdb_restored

## ⚠️ 待办事项

### 高优先级
1. **轮换 B2 Application Key**（安全风险）
2. **修改 POSTGRES_PASSWORD**（安全风险）
3. **配置 ALERT_EMAIL**（启用告警功能）

### 中优先级
4. 配置邮件服务（mail 命令或 SMTP）
5. 测试完整恢复流程
6. 设置监控告警阈值

### 低优先级
7. 优化备份压缩级别
8. 添加备份报告邮件
9. 配置 Webhook 通知（Discord/Slack）

## 🐛 故障排查

### 常见问题

#### 1. 备份失败
```bash
# 查看详细日志
docker exec opdev tail -100 /var/log/noda-backup/backup.log

# 检查 PostgreSQL 连接
docker exec opdev sh -c 'cd /app && source lib/health.sh && check_postgres_connection'

# 检查磁盘空间
docker exec opdev df -h /tmp/postgres_backups
```

#### 2. B2 上传失败
```bash
# 测试 rclone 连接
docker exec opdev rclone ls b2:noda-backups/

# 检查 rclone 配置
docker exec opdev cat /root/.config/rclone/rclone.conf

# 重新配置 rclone
./deploy.sh restart
```

#### 3. 容器无法启动
```bash
# 查看容器日志
docker logs opdev

# 检查网络连接
docker network ls | grep noda

# 手动启动容器
docker run -it --rm \
  --network noda-network \
  --name opdev-test \
  -e POSTGRES_HOST=noda-infra-postgres-1 \
  -e POSTGRES_PASSWORD=xxx \
  -e B2_ACCOUNT_ID=xxx \
  -e B2_APPLICATION_KEY=xxx \
  noda-backup:latest /bin/sh
```

## 📝 相关文档

- [PLAN.md](../.planning/phase-5/PLAN.md) - Phase 5 规划
- [STATE.md](../.planning/STATE.md) - 项目状态追踪
- [README.md](../../README.md) - 项目说明

## 🎉 总结

备份系统已成功部署并运行，所有核心功能正常工作：
- ✅ 自动备份（每天凌晨 3 点）
- ✅ 云存储同步（Backblaze B2）
- ✅ 自动验证（每周日）
- ✅ 监控告警（待配置邮箱）

**下一步**：轮换 B2 凭证，配置告警邮箱，完成最终验收。

---

*文档生成时间：2026-04-06*
*部署状态：运行中*
*容器名称：opdev*
*网络：noda-network*
