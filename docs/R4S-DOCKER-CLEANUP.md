# r4s Docker 镜像清理指南

## 概述

r4s 服务器配置了自动 Docker 镜像清理任务，每周清理未使用的镜像以释放磁盘空间。

## 清理任务配置

### 宿主机 Cronjob

**文件位置**: `/opt/noda/cleanup-docker-images.sh`

**执行时间**: 每周日凌晨 5:00

**Crontab 配置**:
```cron
0 5 * * 0 /opt/noda/cleanup-docker-images.sh >> /var/log/docker-cleanup.log 2>&1
```

**查看日志**: `tail -f /var/log/docker-cleanup.log`

### 手动执行

在 r4s 宿主机上运行：
```bash
/opt/noda/cleanup-docker-images.sh
```

## 清理策略

脚本会安全地清理以下资源：

### 1. 悬空容器 (Dangling Containers)
- 已停止的无名容器（状态为 exited 或 created）
- 不被使用的容器

### 2. 悬空镜像 (Dangling Images)
- 无标签的镜像
- 不被任何容器使用的镜像层

### 3. 旧的 noda-apps 镜像
- 保留 `:latest` 标签
- 删除其他所有旧的 noda-apps 镜像
- 跳过正在运行中的镜像

### 4. 旧的 noda-ops 镜像
- 保留 `:latest` 和 `:test` 标签
- 删除其他所有旧的 noda-ops 镜像
- 跳过正在运行中的镜像

### 6. 构建缓存
- 清理未使用的构建缓存

## 清理前后对比

**清理前** (2026-05-21):
```
Images: 12 个，总计 11.46GB，可回收 5.94GB (51%)
```

**清理后** (2026-05-21):
```
Images: 6 个，总计 6.77GB，可回收 160.9MB (2%)
```

**回收空间**: 约 4.7GB

## 安全保护

脚本内置以下安全保护：

1. **检查运行中的容器** - 永不删除正在使用的镜像
2. **保留重要标签** - `latest`, `test` 标签始终保留
3. **静默失败** - 如果删除失败（镜像被占用），继续执行其他清理
4. **详细日志** - 记录所有删除操作的详细信息

## 更新清理脚本

如果需要修改清理策略：

1. 编辑本地文件：`scripts/backup/cleanup-docker-images.sh`
2. 上传到 r4s：
   ```bash
   scp -i ~/.ssh/id_noda_r4s scripts/backup/cleanup-docker-images.sh \
       root@192.168.100.1:/opt/noda/cleanup-docker-images.sh
   ```
3. 添加执行权限：
   ```bash
   ssh -i ~/.ssh/id_noda_r4s root@192.168.100.1 \
       "chmod +x /opt/noda/cleanup-docker-images.sh"
   ```
4. 测试运行：
   ```bash
   ssh -i ~/.ssh/id_noda_r4s root@192.168.100.1 \
       "/opt/noda/cleanup-docker-images.sh"
   ```

## 故障排查

### 清理未执行

检查 cron 服务状态：
```bash
# 查看 cron 日志
logread | grep cron

# 检查 crontab
crontab -l
```

### 镜像无法删除

如果镜像被容器占用，脚本会跳过该镜像。要强制删除：
```bash
# 停止所有容器
docker stop $(docker ps -aq)

# 然后手动清理
docker system prune -a
```

## 相关文件

- r4s 清理脚本: `/opt/noda/cleanup-docker-images.sh`
- r4s 日志文件: `/var/log/docker-cleanup.log`
- 本地源文件: `scripts/backup/cleanup-docker-images.sh` (仅供参考)
- noda-ops crontab: `deploy/crontab` (容器内备份任务)
