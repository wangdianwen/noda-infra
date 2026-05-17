# iStoreOS Docker 迁移陷阱

**域**: Docker Compose 服务迁移到低资源 ARM64 设备
**研究**: 2026-05-17
**整体置信度**: HIGH

## 执行摘要

从 Mac 迁移到 iStoreOS (NanoPi R4S) 面临多重挑战：有限的内存资源（3.77GB）、SD 卡存储限制、网络连接问题以及 iStoreOS 特有的系统限制。这些陷阱可能导致服务不稳定、数据丢失或部署失败。关键策略包括使用外部存储、精细内存管理、远程连接优化和完善的回滚机制。

## 关键陷阱分类

### 1. SD 卡存储陷阱

#### 1.1 覆盖层2 (overlay2) 性能瓶颈
**问题描述**: Docker 的 overlay2 存储驱动在 SD 卡上性能极差，特别是在频繁写操作的场景下
- **根因**: SD 卡的随机写入性能差，overlay2 需要频繁创建/更新层
- **后果**: 容器启动慢、日志写入延迟、IO 等待时间长
- **预防**: 
  - 将 Docker root 目录迁移到外部 USB SSD: `/mnt/mmc1-4/docker`
  - 使用 `docker run --storage-driver overlay2` 指定存储驱动
  - 定期清理未使用的镜像和容器

#### 1.2 SD 卡寿命问题
**问题描述**: Docker 的频繁写操作会快速消耗 SD 卡的写入周期
- **根因**: overlay2 日志、容器状态、镜像层都会写入 SD 卡
- **后果**: SD 卡提前损坏，数据丢失风险
- **预防**:
  - 使用高质量工业级 SD 卡（endurance grade）
  - 将 `/var/log` 挂载到 tmpfs 或外部存储
  - 限制容器日志大小和轮转频率
  ```bash
  # 在 docker-compose.yml 中为所有容器设置日志限制
  logging:
    driver: "json-file"
    options:
      max-size: "5m"
      max-file: "2"
  ```

#### 1.3 磁盘空间耗尽
**问题描述**: overlay2 快速膨胀，占满有限的空间
- **根因**: 旧的镜像层、未使用的容器、大量的日志文件
- **后果**: Docker 服务崩溃，容器无法启动
- **预防**:
  - 设置 `--storage-opt overlay2.size=50G` 限制容器大小
  - 定期运行 `docker system prune -a`（谨慎执行）
  - 监控磁盘使用率并设置告警

#### 1.4 数据库写入放大
**问题描述**: PostgreSQL 的 WAL 日志和事务日志在 SD 卡上产生大量写入
- **根因**: 数据库频繁的小块写入
- **后果**: SD 卡寿命急剧缩短，IO 性能瓶颈
- **预防**:
  - 为 PostgreSQL 使用外部 SSD 存储
  - 调整 PostgreSQL 配置减少写入频率
  - 增加 `fsync` 间隔（降低可靠性但延长寿命）

### 2. 内存不足陷阱

#### 2.1 OOM Killer 活跃
**问题描述**: 3.77GB 内存极易触发 OOM Killer，杀掉关键容器
- **根因**: 多个服务共享内存，没有预留系统资源
- **后果**: PostgreSQL 或 Keycloak 被杀，服务中断
- **预防**:
  ```yaml
  # docker-compose.yml 精确内存限制
  services:
    postgres:
      deploy:
        resources:
          limits:
            memory: 768M
          reservations:
            memory: 256M
    keycloak:
      deploy:
        resources:
          limits:
            memory: 640M
          reservations:
            memory: 256M
    findclass-ssr:
      deploy:
        resources:
          limits:
            memory: 1024M
          reservations:
            memory: 256M
  ```
  - 预留至少 512MB 给系统和其他进程
  - 设置 `memory-reservation` 防止被 OOM 杀死

#### 2.2 Swap 配置不当
**问题描述**: iStoreOS 默认无 swap 或配置不当
- **根因**: Docker 无法限制 swap 使用，系统可能严重 swap
- **后果**: 系统响应极慢，无法处理负载
- **预防**:
  ```bash
  # 创建 1GB swap 文件（r4s 3.77GB 内存）
  dd if=/dev/zero of=/mnt/mmc1-4/swapfile bs=1M count=1024
  chmod 600 /mnt/mmc1-4/swapfile
  mkswap /mnt/mmc1-4/swapfile
  swapon /mnt/mmc1-4/swapfile
  
  # 添加到 fstab
  echo '/mnt/mmc1-4/swapfile none swap sw 0 0' >> /etc/fstab
  
  # 调整 swappiness（建议 60）
  sysctl vm.swappiness=60
  echo 'vm.swappiness=60' >> /etc/sysctl.conf
  ```

#### 2.3 Docker 内存回收问题
**问题描述**: ARM64 平台上 Docker 内存回收机制可能失效
- **根因**: cgroup v2 配置不完整
- **后果**: 内存泄漏，系统逐渐变慢
- **预防**:
  ```bash
  # 修复 cgroup 配置
  sudo nano /etc/default/grub
  # 在 GRUB_CMDLINE_LINUX_DEFAULT 中添加：
  cgroup_enable=memory swapaccount=1
  
  sudo update-grub
  sudo reboot
  ```

### 3. 数据库迁移陷阱

#### 3.1 pg_dump/restore 字符集问题
**问题描述**: Mac 和 iStoreOS 默认字符集不同，导致数据损坏
- **根因**: Mac 可能使用 UTF-8-MAC，Linux 使用标准 UTF-8
- **后果**: 中文乱码、特殊字符丢失
- **预防**:
  ```bash
  # 明确指定字符集导出
  pg_dump -h localhost -U postgres noda_prod \
    --encoding=UTF-8 \
    --no-owner \
    --no-privileges \
    -f backup.sql
  
  # 导入时明确字符集
  psql -h r4s-ip -U postgres noda_prod \
    --encoding=UTF-8 \
    -f backup.sql
  ```

#### 3.2 跨平台事务一致性
**问题描述**: pg_dump 和 restore 之间数据可能变化
- **根因**: 导出过程中仍有写入操作
- **后果**: 数据不一致，部分丢失
- **预防**:
  ```bash
  # 1. 设置维护模式
  docker exec postgres psql -U postgres -c "ALTER DATABASE noda_prod SET default_transaction_read_only = true;"
  
  # 2. 导出数据
  pg_dump ... > backup.sql
  
  # 3. 恢复数据库
  psql ... -f backup.sql
  
  # 4. 取消维护模式
  docker exec postgres psql -U postgres -c "ALTER DATABASE noda_prod SET default_transaction_read_only = false;"
  ```

#### 3.3 WAL 日志迁移问题
**问题描述**: PostgreSQL WAL 文件在 ARM64 设备上的存储位置和权限
- **根因**: Linux 和 macOS 的文件系统实现差异
- **后果**: 数据库无法启动或数据损坏
- **预防**:
  - 使用 `pg_dump --format=directory` 备份整个数据目录
  - 确保 `/var/lib/postgresql/data` 目录权限正确
  - 在目标系统上初始化新数据库，然后复制数据文件

### 4. 网络陷阱

#### 4.1 Docker 网桥配置冲突
**问题描述**: iStoreOS 可能使用特殊网络配置，与 Docker 网桥冲突
- **根因**: OpenWrt 派生系统有自定义网络脚本
- **后果**: 容器无法访问外部网络或内部通信失败
- **预防**:
  ```bash
  # 检查当前 Docker 网络配置
  docker network ls
  docker network inspect bridge
  
  # 创建自定义网络避免冲突
  docker network create --driver bridge --subnet=172.20.0.0/16 noda-net
  
  # 在 docker-compose.yml 中使用
  networks:
    default:
      external:
        name: noda-net
  ```

#### 4.2 端口映射问题
**问题描述**: 端口被占用或映射不正确
- **根因**: iStoreOS 上的服务可能占用 80/443 端口
- **后果**: Nginx 无法启动，服务无法访问
- **预防**:
  - 检查端口占用: `netstat -tlnp | grep :80`
  - 如果被占用，修改 iStoreOS Web UI 中的端口映射
  - 使用 Docker Compose 端口映射覆盖

#### 4.3 DNS 解析问题
**问题描述**: 容器内 DNS 解析失败
- **根因**: iStoreOS 的 DNS 配置与 Docker 冲突
- **后果**: 服务无法启动，认证失败
- **预防**:
  ```yaml
  # 在 docker-compose.yml 中设置 DNS
  services:
    keycloak:
      dns:
        - 8.8.8.8
        - 1.1.1.1
      environment:
        - DNS_POLICY=none
  ```

### 5. SSH 远程部署陷阱

#### 5.1 连接超时和断开
**问题描述**: SSH 连接频繁超时或断开
- **根因**: ARM64 设备性能不足，长命令执行超时
- **后果**: 部署失败，服务状态不一致
- **预防**:
  ```bash
  # 在 ~/.ssh/config 中配置
  Host r4s
    HostName r4s-ip
    User root
    Port 22
    ServerAliveInterval 60
    ServerAliveCountMax 3
    ControlMaster auto
    ControlPath ~/.ssh/master-%r@%h:%p
    ControlPersist 600
  ```

#### 5.2 命令执行超时
**问题描述**: Docker Compose 操作超时
- **根因**: SD 卡 IO 慢，容器启动时间长
- **后果**: 部署脚本失败，环境不完整
- **预防**:
  ```bash
  # 使用 timeout 命令保护长时间运行的操作
  timeout 600 docker-compose -H ssh://root@r4s up -d
  
  # 或设置 SSH 超时
  ssh -o ConnectTimeout=30 -o ServerAliveInterval=60 r4s
  ```

#### 5.3 权限问题
**问题描述**: jenkins 用户无法操作 Docker
- **根因**: iStoreOS 的用户组配置不同
- **后果**: 部署失败，权限被拒绝
- **预防**:
  ```bash
  # 在 r4s 上执行
  usermod -a -G docker jenkins
  chmod 666 /var/run/docker.sock
  ```

### 6. iStoreOS 特有限制

#### 6.1 Swap 限制支持缺失
**问题描述**: Docker 显示 "WARNING: No swap limit support"
- **根因**: 内核未启用 cgroup swap accounting
- **后果**: 无法限制容器 swap 使用，系统可能不稳定
- **预防**:
  ```bash
  # 修改 GRUB 配置
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="cgroup_enable=memory swapaccount=1"/' /etc/default/grub
  update-grub
  reboot
  ```

#### 6.2 OpenWrt 特定服务冲突
**问题描述**: iStoreOS 基于 OpenWrt，内置服务与 Docker 冲突
- **根因**: 内置的 Nginx、防火墙等
- **后果**: 端口冲突，网络策略冲突
- **预防**:
  - 在 Web UI 中禁用内置的 Nginx
  - 配置防火墙允许 Docker 容器访问
  - 使用 Docker 网络而非 OpenWrt LAN

#### 6.3 包管理器差异
**问题描述**: opkg 与 apt 的包管理差异
- **根因**: iStoreOS 使用 opkg，与 Linux 标准不同
- **后果**: 依赖安装失败，系统不稳定
- **预防**:
  - 使用 Docker 容器运行所有服务
  - 避免 opkg 安装 Docker 相关包
  - 所有依赖在容器内解决

### 7. 迁移期间陷阱

#### 7.1 停机窗口过长
**问题描述**: 迁移过程导致长时间服务中断
- **根因**: 需要完全停止服务来迁移数据库
- **后果**: 业务中断，用户投诉
- **预防**:
  - 选择低峰期迁移
  - 准备详细的迁移时间表
  - 提前通知用户维护窗口

#### 7.2 回滚策略缺失
**问题描述**: 迁移失败后无法快速回滚
- **根因**: 没有保留原环境或备份
- **后果**: 修复时间长，风险高
- **预防**:
  - 迁移前创建完整快照
  - 保留原 Mac 服务运行直到验证完成
  - 准备一键回滚脚本
  ```bash
  # 回滚脚本示例
  #!/bin/bash
  # 1. 停止 r4s 服务
  ssh r4s "docker-compose down"
  
  # 2. 恢复 Mac 服务
  docker-compose -f docker-compose.prod.yml up -d
  
  # 3. 切换 DNS 指向 Mac
  # ...
  ```

#### 7.3 数据完整性验证不足
**问题描述**: 迁移后数据不一致
- **根因**: 没有验证迁移的数据完整性
- **后果**: 应用错误，业务数据问题
- **预防**:
  - 迁移后执行数据校验
  - 比较关键表的记录数
  - 测试所有功能

## 阶段处理建议

### Phase 58: 远程部署集成
- **处理陷阱**: SSH 连接优化、权限设置、网络配置
- **关键任务**: 
  - 配置 SSH 密钥认证
  - 设置 SSH 连接优化参数
  - 验证远程 Docker 操作
  - 测试基础服务部署

### Phase 59: 内存和存储优化
- **处理陷阱**: 内存限制、Swap 配置、SD 卡优化
- **关键任务**:
  - 实施容器内存限制
  - 创建并激活 Swap 文件
  - 配置 Docker Root 迁移
  - 设置日志轮转策略

### Phase 60: 数据迁移
- **处理陷阱**: 数据库迁移、字符集问题、数据一致性
- **关键任务**:
  - 执行数据导出/导入
  - 验证数据完整性
  - 配置数据库优化
  - 测试备份恢复

### Phase 61: 生产切换
- **处理陷阱**: 服务中断、回滚策略、监控告警
- **关键任务**:
  - 执行最终验证
  - 准备回滚机制
  - 切换流量到 r4s
  - 完善监控告警

## 验证清单

- [ ] SD 卡使用率 < 50%
- [ ] 内存使用率 < 80%
- [ ] Swap 文件已激活
- [ ] Docker 网络配置正确
- [ ] PostgreSQL 数据完整
- [ ] Keycloak 认证正常
- [ ] SSH 连接稳定
- [ ] 蓝绿部署可用
- [ ] 回滚脚本测试通过

## 置信度评估

| 领域 | 置信度 | 原因 |
|------|--------|------|
| SD 卡陷阱 | HIGH | 多个实际案例验证，Stack Overflow 和论坛广泛讨论 |
| 内存陷阱 | HIGH | ARM64 低内存设备常见问题，Docker 文档明确说明 |
| 数据库迁移 | MEDIUM | 跨平台迁移较少讨论，但字符集问题有明确解决方案 |
| 网络陷阱 | HIGH | iStoreOS 基于 OpenWrt，网络配置冲突常见 |
| SSH 部署 | HIGH | SSH 超时问题在 ARM64 设备上普遍存在 |
| iStoreOS 特限 | HIGH | 官方 GitHub issue 和社区讨论证实 |
| 迁移策略 | HIGH | 经典迁移模式，有成熟方法论 |

## 来源

- [Docker overlay2 性能优化指南](https://blog.csdn.net/SimTrans/article/details/160441751) - HIGH confidence
- [iStoreOS GitHub Issue #1461](https://github.com/istoreos/istoreos/issues/1461) - HIGH confidence
- [Raspberry Pi Docker SD 卡问题](https://www.reddit.com/r/docker/comments/mxb2zm/looking_for_help_varlibdockeroverlay2_files/) - HIGH confidence
- [ARM64 Docker 内存限制最佳实践](https://stackoverflow.com/questions/78105286/docker-build-with-low-ram-causing-oom-raspberry-pi-4b) - MEDIUM confidence
- [PostgreSQL 跨平台迁移指南](https://dba.stackexchange.com/questions/35112/issues-with-encoding-and-pg-dump-restore-between-windows-and-linux) - MEDIUM confidence
- [SSH 远程部署超时问题](https://github.com/docker/compose/issues/8544) - MEDIUM confidence

---
*Pitfalls research for: iStoreOS (r4s) Docker 迁移*
*Researched: 2026-05-17*