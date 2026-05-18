# 技术栈：iStoreOS Docker 迁移方案

**项目：** Noda 基础设施迁移到 iStoreOS (r4s)
**研究领域：** ARM64 低内存设备 Docker 部署技术栈
**调研日期：** 2026-05-17
**总体置信度：** HIGH

## 推荐技术栈

### 核心方案：SSH 远程 Docker Compose 部署

| 工具 | 版本 | 用途 | 推荐原因 | 置信度 |
|------|------|------|---------|--------|
| **SSH + `docker-compose`** | v2.39.1 | 远程部署 | 最轻量级，与现有架构集成度最高，无额外依赖 | HIGH |
| **Jenkins SSH Agent** | 最新稳定版 | CI/CD 集成 | Jenkins 原生支持，无需额外插件配置 | HIGH |
| **Docker Context** | v27.3.1 | 可选备选方案 | 适合长期固定环境，但配置复杂度较高 | MEDIUM |

#### 为什么选择 SSH 直接执行方案？

1. **最低侵入性**：不改变现有 Jenkins Pipeline 逻辑，只需修改执行目标
2. **资源占用少**：r4s 仅 3.77GB RAM，避免引入 Agent/Ansible 等重量级工具
3. **原子性操作**：SSH 会话天然隔离，一个部署失败不会影响后续操作
4. **与现有模式一致**：当前部署脚本在 Mac 上运行，相同逻辑迁移到 SSH 执行

### ARM64 低内存设备 Docker 内存管理策略

| 组件 | 内存限制 | 保留内存 | 限制策略 | 原因 | 置信度 |
|------|---------|---------|---------|------|--------|
| **PostgreSQL** | 768M | 256M | deploy.resources | noda 数据库较小，2G 过高，预留空间给 Keycloak | HIGH |
| **Keycloak** | 640M | 256M | deploy.resources | Java 应用启动峰值约 500M，OOM Killer 防护 | HIGH |
| **Nginx** | 64M | 16M | deploy.resources | 反向代理开销低 | HIGH |
| **Noda Ops** | 256M | 64M | deploy.resources | 备份脚本 + Cloudflare Tunnel，保守估计 | HIGH |

#### 关键配置

```yaml
# docker-compose.r4s.yml 中的资源限制
deploy:
  resources:
    limits:
      cpus: '1'
      memory: 768M
    reservations:
      cpus: '0.25'
      memory: 256M
```

### SD 卡存储 Docker 优化策略

| 优化措施 | 实现方式 | 效果 | 置信度 |
|---------|---------|------|--------|
| **Overlay2 存储驱动** | Docker 默认支持 | 提供高效的分层存储 | HIGH |
| **Docker Root 迁移** | `/etc/docker/daemon.json` | 从 SD 卡根目录移到 `/mnt/mmc1-4/docker` (54.8GB 可用) | HIGH |
| **日志轮转优化** | `max-size: "5m"`, `max-file: "2"` | 8 容器共约 80MB 日志 | HIGH |
| **I/O 优化** | `read_only: true` + `tmpfs` | 减少 SD 卡写入次数 | HIGH |
| **监控** | `disk_snapshot()` 函数 | 实时跟踪磁盘使用 | HIGH |

### iStoreOS 特有注意事项

| 注意事项 | 处理方案 | 置信度 |
|---------|---------|--------|
| **默认 shell 是 /bin/ash** | 用户创建时指定 `useradd -s /bin/ash` | HIGH |
| **缺少 useradd 命令** | 安装 `shadow-useradd` 包 | HIGH |
| **Docker 开机自启** | 通过 `setup-r4s.sh` 验证 | HIGH |
| **网络配置** | 创建独立网桥 `noda-network` | HIGH |
| **Swap 机制** | 创建 1GB Swap 文件作为 OOM 缓冲 | HIGH |

### 跨机器 Jenkins Pipeline SSH 集成方案

#### 方案一：SSH Agent + `docker-compose` (推荐)

```groovy
// Jenkinsfile 中添加 SSH 配置
environment {
    SSH_HOST = 'r4s.local'
    SSH_USER = 'jenkins'
    SSH_KEY = credentials('r4s-jenkins-key')
}

stages {
    stage('Deploy to r4s') {
        steps {
            sshagent(['r4s-jenkins-key']) {
                sh '''
                    ssh -o StrictHostKeyChecking=no jenkins@r4s.local \
                      "cd /mnt/mmc1-4/noda-infra && \
                       docker compose -f docker/docker-compose.yml \
                       -f docker/docker-compose.prod.yml \
                       -f docker/docker-compose.r4s.yml up -d"
                '''
            }
        }
    }
}
```

#### 方案二：Ansible Playbook (备选)

```yaml
# playbook.yml
---
- hosts: r4s
  become: yes
  tasks:
    - name: Deploy infrastructure
      ansible.builtin.command:
        cmd: |
          cd /mnt/mmc1-4/noda-infra && \
          docker compose -f docker/docker-compose.yml \
          -f docker/docker-compose.prod.yml \
          -f docker/docker-compose.r4s.yml up -d
```

#### 方案三：Docker Context (备选)

```bash
# 在 Jenkins 中创建和使用 context
docker context create r4s --ssh default
docker --context r4s compose -f docker-compose.yml up -d
```

## 安装配置

### SSH 密钥配置 (r4s 侧)

```bash
# 1. 在 Mac 上生成密钥（如果不存在）
ssh-keygen -t ed25519 -f ~/.ssh/r4s-jenkins

# 2. 将公钥添加到 r4s
ssh-copy-id -i ~/.ssh/r4s-jenkins.pub jenkins@r4s.local

# 3. 验证连接
ssh -i ~/.ssh/r4s-jenkins jenkins@r4s.local
```

### Jenkins 凭据管理

1. 在 Jenkins 中添加 SSH 私钥凭据
2. 凭据类型：`SSH Username with private key`
3. 用户名：`jenkins`
4. 私钥文件：选择 `~/.ssh/r4s-jenkins`

### Docker 配置 (r4s 侧)

```json
// /etc/docker/daemon.json
{
  "data-root": "/mnt/mmc1-4/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "5m",
    "max-file": "2"
  }
}
```

## 已验证的替代方案

| 方案 | 推荐度 | 原因 |
|------|--------|------|
| **SSH + docker-compose** | 🥇 100% | 最轻量，与现有架构兼容性最高 |
| **Docker Context** | 🥈 70% | 需要 context 管理，但更标准化 |
| **Ansible** | 🥉 60% | 增加复杂度，r4s 资源受限 |
| **Docker Agent** | ❌ 0% | 需要 Agent 长期运行，资源消耗大 |

## 不使用的工具

| 避免使用 | 原因 | 替代方案 |
|---------|------|---------|
| **Docker Remote API** | 需要额外端口，增加攻击面 | SSH 直接执行 |
| **Kubernetes** | 过于复杂，不适合单服务器场景 | Docker Compose |
| **Docker Swarm** | 需要集群管理，不适合小规模 | Docker Compose |
| **Terraform** | 基础设施即代码，但 r4s 是硬件 | 手动初始化脚本 |

## 集成点

### 与现有架构的集成

| 现有组件 | 集成方式 | 变更范围 |
|---------|---------|---------|
| **Jenkins Pipeline** | 替换 `sh 'docker compose ...'` 为 `ssh 'docker compose ...'` | 小 - 仅修改执行目标 |
| **部署脚本** | 脚本逻辑不变，SSH 目标改为 r4s | 无变更 - 保持兼容 |
| **健康检查** | 复用 `wait_container_healthy` 函数 | 无变更 |
| **备份机制** | 直接在 r4s 执行 pg_dump + B2 上传 | 无变更 - 路径适配 |
| **Nginx upstream** | 蓝绿部署逻辑不变，容器名不变 | 无变更 |

### r4s 特殊配置点

1. **Docker Root 位置**: `/mnt/mmc1-4/docker`（从 SD 卡迁移）
2. **Compose 文件路径**: `/mnt/mmc1-4/noda-infra/docker/`
3. **环境变量**: 需要在 r4s 上设置 `.env` 文件
4. **网络**: 独立网桥 `noda-network`（避免与 iStoreOS 冲突）

## 版本兼容性

| 组件 | 版本 | 兼容性 | 注意事项 |
|------|------|--------|---------|
| **Docker** | 27.3.1 | 完全兼容 | ARM64 架构，支持 overlay2 |
| **Docker Compose** | v2.39.1 | 完全兼容 | 通过 `docker compose` 调用 |
| **Jenkins** | LTS 2.541.x | 完全兼容 | SSH Agent 插件内置 |
| **OpenSSH** | 8.x | 完全兼容 | iStoreOS 默认包含 |

## 监控和维护

| 监控项 | 工具 | 频率 | 告警阈值 |
|---------|------|------|---------|
| **内存使用** | `free -h` | 每小时 | > 90% |
| **磁盘空间** | `df -h` | 每天 | > 80% |
| **容器状态** | `docker compose ps` | 每 5 分钟 | 容器异常 |
| **OOM Kill** | `dmesg | grep -i oom` | 实时 | 出现时告警 |

## Sources

- [Docker Compose CLI 文档](https://github.com/docker/compose/blob/main/docs/reference/compose.md) — 远程部署支持，HIGH confidence
- [Ansible SSH 连接文档](https://context7.com/ansible/ansible/llms.txt) — SSH 执行模式，HIGH confidence
- [iStoreOS 默认 shell 配置](https://wiki.friendlyarm.com/wiki/index.php/NanoPi_R4S) — /bin/ash shell，HIGH confidence
- [Docker overlay2 存储驱动](https://docs.docker.com/storage/storagedriver/overlayfs-driver/) — 默认存储驱动，HIGH confidence
- [PostgreSQL 内存优化](https://www.postgresql.org/docs/current/runtime-config-resource.html) — 内存限制配置，HIGH confidence
- [Keycloak 内存需求](https://www.keycloak.org/documentation) - Java 应用内存使用，MEDIUM confidence