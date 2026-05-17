# Architecture Research: iStoreOS (r4s) Docker 迁移架构

**Domain:** Noda 基础设施服务从 Mac M4 迁移到 iStoreOS (NanoPi R4S)
**Researched:** 2026-05-17
**Confidence:** HIGH

## 系统总览

### 新架构概览

```
                                  浏览器
                                      |
                       +-------------+-------------+
                       |             |             |
              Cloudflare CDN  Mac M4 (Jenkins)  iStoreOS (r4s)
                       |             |             |
        class.noda.co.nz  +    apps-deploy   +    noda-infra
        auth.noda.co.nz   |     Pipeline     |  (PostgreSQL + Keycloak + Nginx + noda-ops)
        www.noda.co.nz    |   (SSH 远程部署)  |
        admin.noda.co.nz   +--------+---------+
                                      |
                              SSH 连接
                                  |
                             控制信号
                                  |
                          Docker API (通过 SSH)
                                  |
                          noda-infra 容器
                                  |
                          Docker 内部网络
                                  |
                      noda-network (bridge)
                          /          \
                 noda-apps-prod     findclass-ssr (blue/green)
                      |              |
               PostgreSQL 容器    SSR + API + 静态文件
                  |              |
                  |              |
              数据持久化        B2 备份 (r4s → Cloudflare → B2)
               /   \            /
         noda_prod noda_preprod  备份存储
              \    /            \
              Backblaze B2       \
                  |               \
                  +-----------------+
                       定时备份
```

### 架构变更概览

| 组件 | Mac 当前架构 | r4s 新架构 | 变更类型 |
|------|-------------|------------|----------|
| Jenkins | 运行在 Mac，本地执行 docker compose | 运行在 Mac，通过 SSH 远程操作 r4s Docker | **修改** (Jenkins Pipeline) |
| Docker Compose | Mac 上全量部署 | r4s 上部署基础设施，Mac 只保留 Jenkins | **修改** (远程部署模式) |
| 数据持久化 | Mac 本地存储 | r4s PostgreSQL + Backblaze B2 备份 | **修改** (数据迁移) |
| 网络架构 | Mac Docker 网桥 | r4s Docker 网桥 + 端口映射 (8080/8081/8443) | **修改** (端口映射) |
| 内存管理 | Mac 32GB 可用 | r4s 3.77GB + 限制策略 | **新增** (内存限制) |
| 备份系统 | Mac 运行 noda-ops | r4s 运行 noda-ops，备份存储在 B2 | **修改** (备份主体转移) |

## 1. 新的数据流架构

### 完整请求链路

```
1. 浏览器访问 class.noda.co.nz
2. Cloudflare DNS → CNAME → noda-ops Cloudflare Tunnel (r4s)
3. noda-ops → nginx:8080 (r4s, 内部网络)
4. Nginx 根据域名路由到内部服务：
   - class.noda.co.nz → findclass-ssr:3000 (r4s)
   - auth.noda.co.nz → keycloak:8080 (r4s)
   - www.noda.co.nz → static files (r4s)
   - admin.noda.co.nz → admin API (r4s)
5. 各服务通过 noda-network 内部通信
6. PostgreSQL 数据库：r4s 本地容器
7. 备份：r4s → B2 Cloud Storage
```

### r4s 上的服务分布

| 服务 | 容器名 | 端口 (r4s) | 网络 | 内存限制 |
|------|--------|------------|------|----------|
| PostgreSQL | noda-infra-postgres-prod | 5432 (内部) | noda-network | 768M |
| Keycloak | keycloak-blue/green | 8080 (内部) | noda-network | 640M |
| Nginx | noda-infra-nginx | 8080/8081/8443 → 80/81/443 | noda-network | 64M |
| noda-ops | noda-ops | - | noda-network | 256M |
| findclass-ssr | noda-apps-prod | 3000 (内部) | noda-network | 1G |

## 2. 跨机器部署架构

### SSH 远程部署模式

```bash
# Jenkins 在 Mac 上的执行模式
# 不是：docker compose up -d (本地)
# 而是：ssh r4s "docker compose up -d" (远程)

# 典型的 Jenkins Pipeline 步骤
stage('Deploy Infrastructure') {
    steps {
        sh '''
            # Mac Jenkins 通过 SSH 执行 r4s 上的 Docker 命令
            ssh r4s "
                cd /opt/noda/noda-infra
                docker compose -f docker/docker-compose.yml \
                             -f docker/docker-compose.prod.yml \
                             -f docker/docker-compose.r4s.yml \
                             up -d \$SERVICE
            "
            
            # 验证部署结果
            ssh r4s "docker ps --filter label=noda.environment=prod"
        '''
    }
}
```

### 需要的 SSH 配置

1. **SSH 密钥认证**
   ```bash
   # 在 Mac Jenkins 服务器上
   ssh-keygen -t ed25519 -f ~/.ssh/r4s-noda
   ssh-copy-id -i ~/.ssh/r4s-noda.pub root@r4s-ip
   ```

2. **SSH 配置文件**
   ```bash
   # ~/.ssh/config
   Host r4s-noda
       HostName 192.168.1.100  # r4s 实际 IP
       User root
       IdentityFile ~/.ssh/r4s-noda
       StrictHostKeyChecking no
       ServerAliveInterval 60
       ServerAliveCountMax 3
   ```

3. **Jenkins Pipeline 增强功能**
   - 需要封装 SSH 命令函数
   - 错误处理和重试机制
   - 并发控制（防止多个 Pipeline 同时操作 r4s）

## 3. 数据持久化架构

### PostgreSQL 数据库迁移

1. **数据导出 (Mac)**
   ```bash
   # 在 Mac 上导出当前数据库
   docker exec noda-infra-postgres-prod pg_dump -U postgres noda_prod > noda_prod_backup.sql
   docker exec noda-infra-postgres-prod pg_dump -U postgres noda_preprod > noda_preprod_backup.sql
   ```

2. **数据导入 (r4s)**
   ```bash
   # 在 r4s 上初始化数据库
   docker exec -i noda-infra-postgres-prod psql -U postgres < noda_prod_backup.sql
   docker exec -i noda-infra-postgres-prod psql -U postgres < noda_preprod_backup.sql
   ```

3. **持久化存储优化**
   ```yaml
   # docker-compose.r4s.yml - PostgreSQL 优化
   postgres:
     deploy:
       resources:
         limits:
           memory: 768M  # 从 2G 压缩到 768M
         reservations:
           memory: 256M
     volumes:
       - postgres_data:/var/lib/postgresql/data
       - ./services/postgres/backup:/var/lib/postgresql/backup  # 定期备份
   ```

### Backblaze B2 备份架构

| 组件 | 位置 | 说明 |
|------|------|------|
| 备份脚本 | r4s noda-ops 容器 | pg_dump + B2 上传 |
| 备份频率 | 每 6 小时一次 | 自动定时任务 |
| 备份保留 | 30 天滚动 | 自动清理旧备份 |
| 备份验证 | 每日校验 | 检查备份完整性 |

### 数据同步策略

```bash
# r4s 上的备份脚本增强
backup-postgres.sh:
  1. 执行 pg_dump (本地)
  2. 压缩备份文件 (gzip)
  3. 上传到 B2 (r4s → Cloudflare → B2)
  4. 更新备份历史记录
  5. 清理 30 天前的备份

# 监控脚本
backup-verify.sh:
  1. 从 B2 下载最新备份
  2. 验证备份文件完整性
  3. 测试恢复流程
```

## 4. 内存分配架构

### r4s 内存总预算 (3.77 GiB)

| 服务 | 限制 | 预留 | 总计 | 用途说明 |
|------|------|------|------|----------|
| PostgreSQL | 768M | 256M | 1024M | 数据库主要消耗 |
| Keycloak | 640M | 256M | 896M | Java 应用启动峰值 |
| Nginx | 64M | 16M | 80M | 反向代理 |
| noda-ops | 256M | 64M | 320M | 备份 + Cloudflare Tunnel |
| findclass-ssr | 1024M | 256M | 1280M | SSR + API + 静态文件 |
| **系统预留** | - | 256M | 256M | 系统进程、OOM 缓冲 |
| **总计** | **2752M** | **1152M** | **3904M** | 约 3.77 GiB |

### 内存限制策略

1. **硬限制 (limits)**：防止 OOM Killer
   ```yaml
   deploy:
     resources:
       limits:
         memory: 1G    # 硬限制
         cpus: '1'     # CPU 限制
   ```

2. **软限制 (reservations)**：保证最小资源
   ```yaml
   deploy:
     resources:
       reservations:
         memory: 256M  # 最小保证
         cpus: '0.25'  # 最小 CPU
   ```

3. **Swap 文件配置** (r4s 特需)
   ```bash
   # 创建 2GB Swap 文件作为 OOM 缓冲
   dd if=/dev/zero of=/mnt/mmc1-4/swapfile bs=1M count=2048
   chmod 600 /mnt/mmc1-4/swapfile
   mkswap /mnt/mmc1-4/swapfile
   swapon /mnt/mmc1-4/swapfile
   ```

4. **监控和告警**
   ```bash
   # r4s 上的内存监控脚本
   check-memory.sh:
     1. 检查各容器内存使用
     2. 警告：使用率 > 80%
     3. 告警：使用率 > 95%
     4. 自动清理缓存
   ```

## 5. 网络架构

### r4s Docker 网络配置

```yaml
# docker-compose.yml
networks:
  noda-network:
    external: true
    name: noda-network
    driver: bridge
    internal: false  # 允许外部访问

# docker-compose.r4s.yml - 端口映射
ports:
  - "8080:80"      # Web 端口映射
  - "8081:81"      # Admin 端口映射
  - "8443:443"     # HTTPS 端口映射
```

### DNS 和路由

| 服务 | 容器名 | 内部端口 | 外部端口 (r4s) | 访问方式 |
|------|--------|----------|----------------|----------|
| Nginx | noda-infra-nginx | 80/81/443 | 8080/8081/8443 | 浏览器直接访问 |
| findclass-ssr | noda-apps-prod | 3000 | - | 通过 Nginx 代理 |
| PostgreSQL | noda-infra-postgres-prod | 5432 | - | 仅内部访问 |
| Keycloak | keycloak | 8080 | - | 通过 Nginx 代理 |

### Cloudflare 集成

```
r4s
├── Docker 容器 (noda-infra)
│   ├── nginx:8080 → 80 (内部)
│   └── noda-ops (Cloudflare Tunnel)
│       ├── /opt/bin/cloudflared
│       └── tunnel 配置
└── 外部访问
    └── Cloudflare Tunnel
        └── class.noda.co.nz → r4s:8080
```

## 6. 构建顺序建议

### Phase 1: r4s 环境准备 (无外部依赖)

1. **网络配置** (30 分钟)
   - 创建 Docker 独立网桥 `noda-network`
   - 配置端口映射 (8080/8081/8443)
   - 测试网络连通性

2. **存储准备** (20 分钟)
   - 创建 Docker Root 目录 `/mnt/mmc1-4/docker`
   - 配置权限和挂载点
   - 创建备份目录 `/mnt/mmc1-4/backups`

3. **Swap 配置** (10 分钟)
   - 创建 2GB Swap 文件
   - 启用并测试 Swap

**验证：**
```bash
# 在 r4s 上验证
docker network ls | grep noda-network
df -h | grep mmc1-4
free -h
```

### Phase 2: 基础设施迁移 (依赖 Phase 1)

1. **数据迁移** (60 分钟)
   - 从 Mac 导出 PostgreSQL 数据
   - 在 r4s 上导入数据
   - 验证数据完整性

2. **部署基础设施** (45 分钟)
   - 在 r4s 上启动 PostgreSQL + Nginx + noda-ops
   - 配置 Cloudflare Tunnel
   - 测试外部访问

3. **备份系统迁移** (30 分钟)
   - 在 r4s 上配置 B2 备份
   - 测试备份流程
   - 验证备份恢复

**验证：**
```bash
# 测试数据库连接
ssh r4s "docker exec noda-infra-postgres-prod psql -U postgres -c 'SELECT 1'"
# 测试外部访问
curl https://class.noda.co.nz/health
```

### Phase 3: 应用部署 (依赖 Phase 2)

1. **Jenkins Pipeline 改造** (90 分钟)
   - 添加 SSH 远程部署功能
   - 修改 Jenkinsfile.infra 和 Jenkinsfile.apps
   - 添加 r4s 部署目标

2. **蓝绿部署适配** (60 分钟)
   - 更新 manage-containers.sh 支持 SSH
   - 修改 upstream 配置以适应远程架构
   - 测试蓝绿切换

3. **应用部署测试** (45 分钟)
   - 部署 findclass-ssr 到 r4s
   - 测试功能完整性
   - 性能基准测试

**验证：**
```bash
# 测试应用部署
ssh r4s "docker ps --filter label=noda.environment=prod"
# 测试蓝绿切换
ssh r4s "cat /opt/noda/active-env"
```

### Phase 4: 监控和维护 (依赖 Phase 3)

1. **监控配置** (60 分钟)
   - 配置 r4s 系统监控
   - 设置内存和 CPU 告警
   - 集成到现有监控系统

2. **文档更新** (30 分钟)
   - 更新 CLAUDE.md
   - 创建运维手册
   - 更新故障排查指南

**验证：**
```bash
# 测试监控
curl http://r4s-ip:8080/health
# 验证备份
ssh r4s "ls -la /mnt/mmc1-4/backups"
```

## 7. 关键集成点

### 新增的文件和配置

| 文件 | 用途 | Phase |
|------|------|-------|
| `docker/docker-compose.r4s.yml` | r4s 特定配置（内存、端口） | Phase 1 |
| `scripts/ssh-deploy.sh` | 封装 SSH 远程部署逻辑 | Phase 3 |
| `jenkins/Jenkinsfile.r4s` | r4s 特定的部署 Pipeline | Phase 3 |
| `config/r4s/monitoring.conf` | r4s 监控配置 | Phase 4 |

### 需要修改的文件

| 文件 | 修改内容 | 复杂度 | Phase |
|------|---------|--------|-------|
| `jenkins/Jenkinsfile.infra` | 添加 SSH 远程部署步骤 | 中 | Phase 3 |
| `jenkins/Jenkinsfile.apps` | 支持远程应用部署 | 中 | Phase 3 |
| `scripts/manage-containers.sh` | 增加远程容器管理 | 高 | Phase 3 |
| `scripts/lib/deploy-check.sh` | 添加远程健康检查 | 低 | Phase 3 |
| `CLAUDE.md` | 更新架构说明和部署流程 | 低 | Phase 4 |

### 不需要修改的文件

| 文件 | 原因 |
|------|------|
| `docker/docker-compose.yml` | 基础配置通用，r4s overlay 覆盖即可 |
| `docker/docker-compose.prod.yml` | 生产配置通用，r4s overlay 覆盖即可 |
| `config/nginx/conf.d/default.conf` | Nginx 配置通用，r4s 使用相同配置 |
| `scripts/lib/log.sh` | 日志功能通用 |

## 8. 风险与缓解措施

### 关键风险

1. **网络不稳定**
   - **风险**：SSH 连接中断导致部署失败
   - **缓解**：添加重试机制、超时控制、本地缓存

2. **内存不足**
   - **风险**：r4s 3.77GB 内存紧张
   - **缓解**：严格内存限制、Swap 文件、监控告警

3. **数据丢失**
   - **风险**：迁移过程中数据损坏
   - **缓解**：多重备份、迁移前后验证、增量迁移

4. **服务中断**
   - **风险**：迁移期间服务不可用
   - **缓解**：蓝绿部署、回滚机制、维护窗口

### 监控指标

| 指标 | 阈值 | 告警方式 |
|------|------|----------|
| r4s 内存使用率 | > 80% | 邮件/Slack |
| 容器重启次数 | > 10/小时 | 邮件/Slack |
| 数据库连接数 | > 80% | 邮件/Slack |
| 备份成功率 | < 100% | 邮件/Slack |
| SSH 连接延迟 | > 2s | 邮件/Slack |

## 9. 迁移后架构优势

### 性能提升
- **网络**：r4s 专用硬件，性能更稳定
- **内存**：精确控制，避免资源浪费
- **网络**：专用网桥，减少网络冲突

### 运维简化
- **架构**：Mac 只负责 CI/CD，r4s 负责运行
- **部署**：统一的远程部署模式
- **监控**：集中式监控和告警

### 扩展性
- **硬件**：可轻松迁移到其他 ARM 设备
- **服务**：预留资源，支持未来扩展
- **网络**：支持更多服务接入

## Sources

- 项目当前架构：`docker/docker-compose.yml`, `docker/docker-compose.prod.yml`, `docker/docker-compose.r4s.yml`
- 部署脚本：`scripts/deploy/deploy-apps-prod.sh`, `scripts/deploy/deploy-infrastructure-prod.sh`
- Jenkins Pipeline：`jenkins/Jenkinsfile.infra`, `jenkins/Jenkinsfile.apps`
- 网络配置：`config/nginx/conf.d/default.conf`
- Phase 57 记录：已完成 r4s 环境初始化脚本和 Docker Compose r4s overlay

---
*Architecture research for: iStoreOS (r4s) Docker 迁移*
*Researched: 2026-05-17*