# 回滚 Runbook

> **最后更新**: 2026-05-19
> **适用场景**: r4s 故障导致生产服务不可用，需要快速切回 Mac 运行

## 触发条件

以下情况触发回滚流程：

1. **r4s 完全不可达**: SSH 无法连接，物理故障
2. **r4s Docker 服务异常**: `docker ps` 显示所有服务停止或反复重启
3. **r4s 网络故障**: Cloudflare Tunnel 无法连接，外部无法访问
4. **数据完整性风险**: PostgreSQL 损坏且无法从本地恢复
5. **性能严重退化**: 服务响应时间 > 30 秒持续 5 分钟以上

## 回滚前准备

### 检查清单

- [ ] 确认 r4s 故障现象
- [ ] 尝试 r4s 快速修复（5 分钟内）
- [ ] 记录故障时间点（用于数据恢复决策）
- [ ] 通知相关人员回滚计划

### Mac 环境验证

```bash
# 1. Docker 环境检查
docker --version
docker compose version

# 2. 网络检查
docker network ls | grep noda-network

# 3. 镜像检查
docker images | grep -E "postgres|nginx|noda-ops|keycloak|noda-apps"

# 4. 端口检查
for port in 80 443 5432 8080; do
  lsof -i :$port || echo "Port $port: FREE"
done
```

## 回滚步骤

### 步骤 1: Cloudflare Tunnel 回切（2 分钟）

**目标**: 将 Cloudflare Tunnel 从 r4s 切回 Mac

**操作**:

```bash
# 1.1. 停止 r4s 上的 noda-ops 容器（包含 cloudflared）
ssh root@192.168.100.1 "docker stop noda-ops"

# 1.2. 确认 r4s Tunnel 已停止（可选验证）
ssh root@192.168.100.1 "docker ps | grep noda-ops"

# 1.3. 在 Mac 上启动 noda-ops（启动 Cloudflare Tunnel）
cd /Users/dianwenwang/Project/noda-infra
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d noda-ops

# 1.4. 验证 Tunnel 连接
docker logs noda-ops -f  # 应该看到 "tunnel run" 启动成功
```

**验证**:

```bash
# 检查 Mac 上 cloudflared 进程
docker exec noda-ops ps aux | grep cloudflared

# 测试外部访问
curl -I https://class.noda.co.nz
curl -I https://auth.noda.co.nz
```

**预估耗时**: 2 分钟

**回退**: 如果 Mac noda-ops 启动失败，检查 `.env` 中 `CLOUDFLARE_TUNNEL_TOKEN`

---

### 步骤 2: PostgreSQL 数据恢复（10-30 分钟）

**目标**: 在 Mac 上恢复到最近的数据库备份

**决策**: 根据故障时间点选择恢复策略

| 故障场景 | 恢复策略 | 预估时间 |
|---------|---------|----------|
| r4s 完全不可达（< 12 小时） | 下载最新备份并恢复 | 20 分钟 |
| r4s PostgreSQL 单独损坏 | 下载最新备份并恢复 | 20 分钟 |
| 数据完整性未知 | 下载最新备份 + 人工验证 | 30 分钟 |

**操作**:

```bash
# 2.1. 下载最新备份（从 B2）
# 先列出备份文件
cd /tmp
b2 ls noda-backups backups/postgres/ | tail -5

# 下载最新备份
B2_FILE=$(b2 ls noda-backups backups/postgres/ | tail -1)
b2 download-file noda-backups "backups/postgres/$B2_FILE" "/tmp/latest_backup.dump"

# 2.2. 验证备份文件
pg_restore --list /tmp/latest_backup.dump | head -20

# 2.3. 停止 r4s 上的 postgres（如果 r4s 可达）
ssh root@192.168.100.1 "docker stop noda-infra-postgres-prod"

# 2.4. 在 Mac 上启动 PostgreSQL 容器
cd /Users/dianwenwang/Project/noda-infra
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d postgres

# 2.5. 等待 PostgreSQL 健康检查通过
docker exec noda-infra-postgres-prod pg_isready -U nodauser

# 2.6. 恢复数据库
docker exec -i noda-infra-postgres-prod pg_restore -U nodauser -d nodaprod -c < /tmp/latest_backup.dump

# 2.7. 验证数据
docker exec -it noda-infra-postgres-prod psql -U nodauser -d nodaprod -c "SELECT COUNT(*) FROM users;"
```

**验证**:

```bash
# 检查表数量
docker exec -it noda-infra-postgres-prod psql -U nodauser -d nodaprod -c "\dt"

# 检查关键表数据
docker exec -it noda-infra-postgres-prod psql -U nodauser -d nodaprod -c "
  SELECT COUNT(*) FROM users;
  SELECT COUNT(*) FROM classes;
  SELECT COUNT(*) FROM bookings;
"
```

**预估耗时**: 20-30 分钟（取决于备份大小和网络速度）

**回退**: 如果恢复失败，检查备份文件完整性，尝试次新备份

---

### 步骤 3: 应用服务回切（5 分钟）

**目标**: 在 Mac 上启动所有应用服务

**操作**:

```bash
# 3.1. 停止 r4s 上的应用服务（如果 r4s 可达）
ssh root@192.168.100.1 "
  docker stop noda-infra-keycloak-prod
  docker stop findclass-ssr
  docker stop noda-site
"

# 3.2. 在 Mac 上启动所有服务
cd /Users/dianwenwang/Project/noda-infra
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d

# 3.3. 等待服务健康检查
# Keycloak
docker exec noda-infra-keycloak-prod curl -f http://localhost:8080/health/ready || exit 1

# findclass-ssr
docker exec findclass-ssr curl -f http://localhost:3001/api/health || exit 1

# 3.4. 检查容器状态
docker ps | grep -E "keycloak|findclass-ssr|noda-site"
```

**验证**:

```bash
# Keycloak 管理台
curl -I https://auth.noda.co.nz/admin/

# 主应用健康检查
curl https://class.noda.co.nz/api/health

# 官网健康检查
curl -I https://www.noda.co.nz
```

**预估耗时**: 5 分钟

**回退**: 如果应用启动失败，检查日志 `docker logs <container>`

---

### 步骤 4: Keycloak 回切（3 分钟）

**目标**: 确保 Keycloak 在 Mac 上正常运行

**注意**: Keycloak 在步骤 3 中已启动，这里做额外验证

**操作**:

```bash
# 4.1. 检查 Keycloak 容器状态
docker ps | grep keycloak

# 4.2. 验证 Keycloak 健康检查
docker exec noda-infra-keycloak-prod curl -f http://localhost:8080/health/ready

# 4.3. 验证外部访问
curl -I https://auth.noda.co.nz/realms/noda/.well-known/openid-configuration
```

**验证**:

```bash
# 登录测试（手动）
# 1. 访问 https://class.noda.co.nz
# 2. 点击 "登录"
# 3. 选择 Google 登录
# 4. 验证能成功登录并重定向回应用
```

**预估耗时**: 3 分钟

**回退**: 如果 Keycloak 无法启动，检查数据库连接（Keycloak 依赖 PostgreSQL）

---

## 总体恢复时间预估

| 步骤 | 预估时间 | 累计时间 |
|------|----------|----------|
| 1. Cloudflare Tunnel 回切 | 2 分钟 | 2 分钟 |
| 2. PostgreSQL 数据恢复 | 20-30 分钟 | 22-32 分钟 |
| 3. 应用服务回切 | 5 分钟 | 27-37 分钟 |
| 4. Keycloak 回切验证 | 3 分钟 | 30-40 分钟 |

**总恢复时间**: 30-40 分钟

---

## 验证清单

回滚完成后，逐项验证：

### 外部访问

- [ ] `https://class.noda.co.nz` 可访问
- [ ] `https://auth.noda.co.nz` 可访问
- [ ] `https://www.noda.co.nz` 可访问
- [ ] `https://admin.noda.co.nz` 可访问

### 功能验证

- [ ] 用户可以登录（Google OAuth）
- [ ] 用户可以查看课程列表
- [ ] 用户可以创建预订
- [ ] 管理员可以登录管理后台

### 数据一致性检查

```bash
# PostgreSQL 连接检查
docker exec -it noda-infra-postgres-prod psql -U nodauser -d nodaprod

# 在 psql 中执行：
\dt  # 列出所有表
SELECT COUNT(*) FROM users;
SELECT COUNT(*) FROM classes;
SELECT COUNT(*) FROM bookings;
SELECT MAX(created_at) FROM bookings;  # 确认最新数据时间
```

### 容器健康状态

```bash
# 所有容器应该都是 "healthy" 状态
docker ps --format "table {{.Names}}\t{{.Status}}"
```

---

## 数据一致性注意事项

### 回滚期间的数据丢失风险

1. **时间窗口**: 从最近一次备份到故障发生期间的数据更改会丢失
   - **每日备份**: 凌晨 3:00 执行
   - **最大数据丢失**: 24 小时（如果故障发生在第二天凌晨 2:59）

2. **缓解措施**:
   - 关键操作（如支付）有第三方确认，可从支付平台恢复
   - 用户预订数据可以从用户操作日志部分恢复
   - 定期备份频率可根据业务需求调整

### 回滚后的数据同步

1. **如果 r4s 恢复**: 需要将 Mac 上的新数据同步回 r4s
   - 从 Mac 导出 PostgreSQL 数据库
   - 在 r4s 上恢复数据库
   - 验证数据一致性后再次切换到 r4s

2. **如果 r4s 永久损坏**: Mac 成为新的生产环境
   - 更新 DNS 记录（如果需要）
   - 更新监控和告警配置
   - 更新备份脚本（Mac 本地备份）

---

## 常见问题排查

### 问题 1: Cloudflare Tunnel 无法连接

**症状**: Mac 上 noda-ops 容器启动失败，日志显示认证错误

**排查**:
```bash
# 检查 .env 中的 TOKEN
grep CLOUDFLARE_TUNNEL_TOKEN docker/.env

# 查看 cloudflared 日志
docker logs noda-ops
```

**解决**: 重新生成 Tunnel token 或联系 Cloudflare 支持

---

### 问题 2: PostgreSQL 恢复失败

**症状**: `pg_restore` 报错 "database is not empty"

**排查**:
```bash
# 使用 -c 参数清理已有数据库
docker exec -i noda-infra-postgres-prod pg_restore -U nodauser -d nodaprod -c < /tmp/latest_backup.dump
```

**解决**: 删除并重建数据库
```bash
docker exec -it noda-infra-postgres-prod psql -U nodauser -c "DROP DATABASE nodaprod;"
docker exec -it noda-infra-postgres-prod psql -U nodauser -c "CREATE DATABASE nodaprod OWNER nodauser;"
docker exec -i noda-infra-postgres-prod pg_restore -U nodauser -d nodaprod < /tmp/latest_backup.dump
```

---

### 问题 3: 应用服务无法启动

**症状**: 容器反复重启

**排查**:
```bash
# 查看容器日志
docker logs findclass-ssr
docker logs noda-infra-keycloak-prod

# 检查依赖服务是否启动
docker ps | grep postgres
```

**解决**: 确保依赖服务（PostgreSQL、Keycloak）先启动

---

### 问题 4: 端口冲突

**症状**: 容器启动失败，日志显示 "port is already allocated"

**排查**:
```bash
# 查找占用端口的进程
lsof -i :80
lsof -i :5432
```

**解决**: 停止占用端口的进程或修改端口映射

---

## 回滚后长期运行

如果 r4s 无法恢复，Mac 需要长期运行生产服务：

### 资源检查

```bash
# Mac 内存使用
top -o mem

# Docker 资源限制
docker stats --no-stream
```

### 监控恢复

- 重新配置监控告警（Prometheus/Grafana）
- 恢复日志收集（如果使用 ELK/Loki）
- 恢复定期备份任务

### 下一次迁移计划

记录故障原因，规划下一次迁移到新服务器的方案

---

## 变更历史

| 日期 | 变更内容 | 作者 |
|------|----------|------|
| 2026-05-19 | 创建回滚 Runbook | Claude (Phase 62-02) |

---

**重要提醒**:
1. 本 Runbook 仅在 r4s 故障时使用
2. 任何回滚操作都会导致数据丢失（从最近备份到故障时刻）
3. 回滚前必须通知所有相关人员
4. 回滚后必须验证所有关键功能
