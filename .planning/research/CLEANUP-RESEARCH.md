# 部署后清理自动化研究

**Domain:** Docker + Jenkins + Node.js 构建残留清理
**Researched:** 2026-04-19
**Scope:** 部署 Pipeline 成功后自动清理所有构建残留和缓存

---

## 一、现有系统分析

### 当前清理能力（pipeline-stages.sh）

| 函数 | 清理范围 | 缺失 |
|------|---------|------|
| `pipeline_cleanup()` | 停止非活跃蓝绿容器 + SHA 镜像日期阈值清理 | 无 build cache 清理、无 pnpm/npm 缓存清理 |
| `pipeline_infra_cleanup()` | keycloak dangling images 清理 | 无 build cache、无备份文件清理 |
| `cleanup_by_date_threshold()` | 超过天数的 SHA 标签镜像 + dangling images | 无 build cache、无 network/volume 清理 |
| `cleanup_by_tag_count()` | 保留最近 N 个标签镜像 | 无 build cache |
| `cleanup_dangling()` | 无标签 dangling images | 范围太窄 |

### 当前 Jenkins 配置

所有 4 个 Jenkinsfile 已配置：
- `buildDiscarder(logRotator(numToKeepStr: '20'))` -- 保留最近 20 次构建日志
- 无 workspace 清理（构建后 workspace 保持原状）
- 无 build cache 清理
- 无 pnpm store 清理

### 服务架构（影响清理策略）

| 服务 | 构建方式 | 产生缓存 | 容器管理 |
|------|---------|---------|---------|
| findclass-ssr | `docker build` + pnpm install + Vite build | build cache + pnpm store + node_modules | 蓝绿 docker run |
| noda-site | `docker build` | build cache | 蓝绿 docker run |
| keycloak | `docker pull` 官方镜像 | pull cache | 蓝绿 docker run |
| nginx | `docker compose up` | 无构建缓存 | docker compose |
| noda-ops | `docker compose up --build` | build cache | docker compose |
| postgres | `docker compose restart` | 无构建缓存 | docker compose |

---

## 二、Docker 清理命令（Docker 24+ / 29.x 已验证）

### 2.1 Build Cache 清理 -- 最高优先级

Docker build cache 是磁盘占用最大的来源之一。每次 `docker build` 都会产生层缓存。

```bash
# 查看 build cache 磁盘占用
docker buildx du

# 清理所有 dangling build cache（推荐：部署后清理）
# --force 跳过确认提示（Pipeline 自动化必须）
docker buildx prune -f

# 清理所有 build cache（包括正在被引用的）
# 谨慎使用：下次构建需要完全重建所有层
docker buildx prune -f --all

# 只清理超过 24 小时的 build cache（推荐：保留最近构建的热缓存）
docker buildx prune -f --filter "until=24h"

# 清理并保留一定空间（Docker 28+ 使用 reserved-space）
# 适用于定期清理而非每次部署后
docker buildx prune -f --keep-storage=5GB
```

**推荐策略：** 部署成功后使用 `docker buildx prune -f --filter "until=24h"`。保留 24 小时内的缓存（下次构建可能复用），清理更早的缓存。

**Confidence: HIGH** -- Docker 官方文档验证

### 2.2 Image 清理

项目已有 `image-cleanup.sh` 的 3 个函数。以下是补充命令：

```bash
# 清理 dangling images（无标签的中间层镜像）
# 现有 cleanup_dangling() 已实现，等价于：
docker image prune -f

# 清理所有未使用的镜像（没有被任何容器引用的）
# 谨慎：会删除所有 stop 状态服务的镜像
docker image prune -f -a

# 清理超过 24 小时的未使用镜像
docker image prune -f -a --filter "until=24h"

# 查看镜像磁盘占用
docker system df -v
```

**推荐策略：** 继续使用现有的 `cleanup_by_date_threshold()` 做 SHA 标签镜像清理。在清理末尾加 `docker image prune -f` 补充清理 dangling images（与现有 `cleanup_dangling()` 合并）。

**Confidence: HIGH** -- Docker 官方文档验证

### 2.3 Container 清理

蓝绿部署产生的已停止容器需要清理：

```bash
# 清理所有已停止的容器
docker container prune -f

# 清理超过 24 小时的已停止容器
docker container prune -f --filter "until=24h"
```

**注意：** 当前 `pipeline_cleanup()` 已处理非活跃蓝绿容器的停止和删除。`docker container prune` 会补充清理可能遗漏的容器（如失败构建残留的容器）。

**推荐策略：** 在 `pipeline_cleanup()` 之后追加 `docker container prune -f --filter "until=24h"`，清理超过 1 天的已停止容器。

**Confidence: HIGH**

### 2.4 Network 清理

```bash
# 清理未使用的网络
docker network prune -f

# 清理超过 24 小时的未使用网络
docker network prune -f --filter "until=24h"
```

**注意：** `noda-network` 是 external 网络，`docker network prune` 只删除匿名网络和未使用的自定义网络，不会删除 external 网络。安全使用。

**推荐策略：** 添加 `docker network prune -f`。网络本身不占多少磁盘空间，但会清理 iptables 规则和桥接设备，避免系统资源泄漏。

**Confidence: HIGH**

### 2.5 Volume 清理 -- 最高风险

```bash
# 查看卷磁盘占用
docker volume ls -q | xargs docker volume inspect --format '{{ .Name }}: {{ .Mountpoint }}'

# 清理未被任何容器引用的匿名卷
# 注意：默认只删除匿名卷（anonymous volumes），不删除命名卷
docker volume prune -f

# 危险！清理所有未被容器引用的卷（包括命名卷）
# 绝对不要在生产环境使用 - 除非确认 postgres_data 卷有容器在使用
docker volume prune -f --all
```

**安全规则：**

| 卷名 | 类型 | 是否清理 | 原因 |
|------|------|---------|------|
| `postgres_data` | named volume | 绝对不清理 | 数据库数据，项目核心价值 |
| `noda-network` | external network | 不清理 | 被 nginx/keycloak/postgres 使用 |
| 匿名卷 | anonymous | 可以清理 | build 产生的临时数据 |
| `docker/volumes/backup` | bind mount | 按策略清理 | 备份文件，有独立保留策略 |

**推荐策略：** 仅使用 `docker volume prune -f`（不加 `--all`）。只清理匿名卷，保留所有命名卷。postgres_data 是命名卷，安全。

**Confidence: HIGH**

### 2.6 一键全清理（参考，不建议直接使用）

```bash
# docker system prune 组合命令（了解行为，不建议 Pipeline 中直接使用）
# 等价于: container prune + network prune + image prune(dangling) + buildx prune
docker system prune -f

# 包含卷（只用匿名卷模式）
docker system prune -f --volumes

# 清理所有未使用镜像 + 卷（极度危险）
docker system prune -f -a --volumes
```

**不推荐使用 `docker system prune` 的原因：**
1. 缺乏细粒度控制 -- 无法区分 build cache 的时间过滤
2. 错误信息不易定位 -- 一个命令做了太多事
3. 不符合项目现有的分步清理风格

**推荐策略：** 分别调用各个 `prune` 子命令，每步记录日志和回收空间。

**Confidence: HIGH**

---

## 三、pnpm / Node.js 缓存清理

### 3.1 pnpm Store 清理

pnpm 使用全局内容寻址存储（content-addressable store），所有项目共享同一份包文件（硬链接）。

```bash
# 查看 pnpm store 路径
pnpm store path
# 典型路径: /home/jenkins/.local/share/pnpm/store 或 /root/.local/share/pnpm/store

# 查看 pnpm store 磁盘占用
du -sh "$(pnpm store path)"

# 清理未被任何项目引用的包
pnpm store prune
```

**`pnpm store prune` 行为：**
- 移除 store 中不被任何项目引用的包
- 项目通过 symlink 注册到 store，pnpm 能追踪活跃使用
- 不影响正在使用的包
- 可以安全在生产服务器上运行
- 不建议每次部署都运行 -- 频繁 prune + re-download 会降低构建速度

**推荐策略：** 每 7 天运行一次 `pnpm store prune`（而非每次部署）。因为 Jenkins 服务器上只有 noda-infra 和 noda-apps 两个项目使用 pnpm，store 增长缓慢。

**Confidence: HIGH** -- pnpm 官方文档验证

### 3.2 npm Cache 清理

如果 Pipeline 中有 `npm install`（例如 Jenkins 初始化脚本），需要清理 npm 缓存：

```bash
# 查看 npm 缓存路径
npm config get cache
# 典型路径: /home/jenkins/.npm

# 查看 npm 缓存磁盘占用
du -sh "$(npm config get cache)"

# 清理 npm 缓存（npm v5+ 自动管理缓存，通常不需要手动清理）
npm cache clean --force

# 验证缓存完整性（不清理，仅检查）
npm cache verify
```

**注意：** 项目使用 pnpm 而非 npm 作为包管理器。npm cache 可能因为 corepack 或其他工具间接使用而产生，但通常很小。

**推荐策略：** 不在 Pipeline 中清理 npm cache。如果磁盘紧张，可在月度维护中运行 `npm cache clean --force`。

**Confidence: HIGH**

### 3.3 node_modules 清理

Jenkins workspace 中的 `noda-apps/` 目录会在 `pipeline_test()` 阶段执行 `pnpm install --frozen-lockfile`，产生 `node_modules/` 目录。

```bash
# 查看 node_modules 磁盘占用（典型 200-500MB）
du -sh "$WORKSPACE/noda-apps/node_modules" 2>/dev/null

# 清理 Jenkins workspace 中的 node_modules
rm -rf "$WORKSPACE/noda-apps/node_modules"

# 清理所有 workspace 中的 node_modules（包括子项目）
find "$WORKSPACE" -name "node_modules" -type d -prune -exec rm -rf {} \;
```

**推荐策略：** 在 Cleanup 阶段末尾删除 `noda-apps/node_modules`。因为每次构建都会 `pnpm install --frozen-lockfile` 重新生成，保留无意义。这通常回收 200-500MB 空间。

**但是注意：** 对于 noda-site 和 findclass-ssr Pipeline，`noda-apps` 是 checkout 出来的子目录，构建完成后可以整个清理。对于 keycloak Pipeline，没有 noda-apps 目录。

**Confidence: HIGH**

### 3.4 pnpm 缓存 vs pnpm store -- 区分

| 概念 | 路径 | 作用 | 清理命令 |
|------|------|------|---------|
| pnpm store | `~/.local/share/pnpm/store/v3` | 全局包硬链接存储 | `pnpm store prune` |
| pnpm cache | `~/.cache/pnpm`（或 `$XDG_CACHE_HOME/pnpm`） | HTTP 请求缓存、注册表元数据 | `pnpm store prune` 会清理 |
| node_modules | 项目目录下 | 当前项目依赖 | `rm -rf node_modules` |

---

## 四、Jenkins Workspace 清理

### 4.1 构建日志保留

所有 4 个 Jenkinsfile 已配置 `buildDiscarder(logRotator(numToKeepStr: '20'))`，保留最近 20 次构建日志。这已经足够。

**无需变更。**

**Confidence: HIGH**

### 4.2 Jenkinsfile Cleanup 阶段中的 Workspace 清理

当前 Pipeline 的 Cleanup 阶段只处理容器和镜像，不处理 workspace 文件。

**推荐的 workspace 清理策略：**

```bash
# 1. 清理构建产物（noda-apps 目录）
# findclass-ssr 和 noda-site Pipeline 产生 noda-apps checkout + node_modules
if [ -d "$WORKSPACE/noda-apps" ]; then
    log_info "清理 noda-apps workspace..."
    du -sh "$WORKSPACE/noda-apps" 2>/dev/null || true
    rm -rf "$WORKSPACE/noda-apps"
    log_success "noda-apps workspace 已清理"
fi

# 2. 清理部署失败日志（成功部署后这些日志不再需要）
rm -f "$WORKSPACE/deploy-failure-container.log"
rm -f "$WORKSPACE/deploy-failure-nginx.log"
rm -f "$WORKSPACE/deploy-failure-infra.log"

# 3. 清理临时文件
find "$WORKSPACE" -name "*.tmp" -type f -delete 2>/dev/null || true
```

**不要清理的 workspace 文件：**
- `scripts/` -- Pipeline 函数库，下次构建需要
- `docker/` -- Docker Compose 配置
- `config/` -- Nginx 配置
- `deploy/` -- Dockerfile
- `.git/` -- Git 仓库

**Confidence: HIGH**

### 4.3 Jenkins Home 磁盘监控

Jenkins 构建日志存储在 `$JENKINS_HOME/jobs/` 目录下：

```bash
# Jenkins 磁盘占用分析
du -sh /var/lib/jenkins/
du -sh /var/lib/jenkins/jobs/
du -sh /var/lib/jenkins/workspace/
du -sh /var/lib/jenkins/.cache/ 2>/dev/null || true

# 查看各 job 磁盘占用
du -sh /var/lib/jenkins/jobs/*/builds/ 2>/dev/null | sort -rh | head -10
```

**Confidence: HIGH**

### 4.4 infra-pipeline 备份文件清理

`pipeline_backup_database()` 在 `docker/volumes/backup/infra-pipeline/{service}/` 下创建 `.sql.gz` 备份文件。当前没有清理旧备份的逻辑。

```bash
# 清理超过 N 天的 infra-pipeline 备份文件
# 参数: $1 = 备份目录, $2 = 保留天数（默认 30）
cleanup_old_backups()
{
    local backup_dir="$1"
    local retention_days="${2:-30}"

    if [ ! -d "$backup_dir" ]; then
        return 0
    fi

    local deleted=0
    # macOS 兼容：BSD find 使用 -mtime +N（最后修改时间超过 N 天）
    find "$backup_dir" -name "*.sql.gz" -type f -mtime +"${retention_days}" -print -delete | while read -r f; do
        deleted=$((deleted + 1))
    done

    log_info "备份清理: ${backup_dir}，删除 ${deleted} 个超过 ${retention_days} 天的备份"
}
```

**推荐策略：** 保留 30 天的部署前备份。findclass-ssr 部署频率约每周一次，30 天约保留 4 个备份。

**Confidence: MEDIUM** -- 保留天数需要根据实际部署频率调整

---

## 五、磁盘用量监控（部署前后对比）

### 5.1 Docker 磁盘监控命令

```bash
# Docker 总磁盘占用（概览）
docker system df

# Docker 详细磁盘占用（含每个镜像/容器/卷/缓存的大小）
docker system df -v

# 仅查看回收空间估算（预演 prune，不实际删除）
docker system df --format "table {{.Type}}\t{{.Size}}\t{{.Reclaimable}}"
```

### 5.2 宿主机磁盘监控

```bash
# 宿主机整体磁盘使用
df -h /var/lib/docker 2>/dev/null || df -h /
df -h /var/lib/jenkins 2>/dev/null || true

# Docker 目录磁盘占用
du -sh /var/lib/docker/
du -sh /var/lib/docker/overlay2/ 2>/dev/null || true  # 镜像层
du -sh /var/lib/docker/buildkit/ 2>/dev/null || true  # build cache

# Jenkins 目录磁盘占用
du -sh /var/lib/jenkins/workspace/
du -sh /var/lib/jenkins/jobs/
```

### 5.3 推荐的监控函数

```bash
# 磁盘快照：部署前后对比
disk_snapshot()
{
    local label="$1"
    echo "=== 磁盘快照: ${label} ==="
    echo "宿主机: $(df -h / | awk 'NR==2{print $5 " 已用 (" $3 "/" $2 ")"}')"
    echo "Docker: $(docker system df --format '{{.Size}}' | head -1)"
    echo "Docker 可回收: $(docker system df --format '{{.Reclaimable}}' | head -1)"
    echo ""
}

# 使用方式：
# disk_snapshot "部署前"
# ... 部署过程 ...
# disk_snapshot "清理前"
# ... 清理过程 ...
# disk_snapshot "清理后"
```

**Confidence: HIGH**

---

## 六、集成架构 -- 推荐实现方案

### 6.1 新建 scripts/lib/cleanup.sh 共享库

将清理逻辑独立为共享库，与 `image-cleanup.sh` 并列：

```
scripts/lib/
  log.sh              -- 日志函数
  image-cleanup.sh    -- 镜像清理（已有）
  cleanup.sh          -- 新增：综合清理（build cache + node_modules + workspace + 备份）
  deploy-check.sh     -- 部署检查
  secrets.sh          -- 密钥管理
  platform.sh         -- 平台检测
```

### 6.2 清理函数设计

```bash
# cleanup.sh 函数清单（建议实现）

# 1. cleanup_docker_build_cache()    -- 清理 Docker build cache
#    参数: $1 = 保留小时数（默认 24）
#    命令: docker buildx prune -f --filter "until=${hours}h"

# 2. cleanup_dangling_images()       -- 清理 dangling images
#    命令: docker image prune -f
#    （替代现有 cleanup_dangling()，功能相同但用 docker image prune）

# 3. cleanup_stopped_containers()    -- 清理已停止容器
#    参数: $1 = 保留小时数（默认 24）
#    命令: docker container prune -f --filter "until=${hours}h"

# 4. cleanup_unused_networks()       -- 清理未使用网络
#    命令: docker network prune -f

# 5. cleanup_anonymous_volumes()     -- 清理匿名卷（不含命名卷）
#    命令: docker volume prune -f
#    安全：不会删除 postgres_data 等命名卷

# 6. cleanup_node_modules()          -- 清理 workspace 中 node_modules
#    参数: $1 = workspace 路径

# 7. cleanup_pnpm_store()            -- pnpm store prune
#    命令: pnpm store prune

# 8. cleanup_old_infra_backups()     -- 清理旧 infra-pipeline 备份
#    参数: $1 = 保留天数（默认 30）

# 9. cleanup_jenkins_temp_files()    -- 清理 Jenkins 临时文件
#    命令: rm -f deploy-failure-*.log, find .tmp files
```

### 6.3 pipeline_cleanup() 增强（修改现有函数）

在 `pipeline-stages.sh` 中的 `pipeline_cleanup()` 末尾追加：

```bash
pipeline_cleanup()
{
    # === 现有逻辑（保持不变）===
    # 停掉非活跃容器
    # SHA 镜像日期阈值清理 / dangling images 清理

    # === 新增清理逻辑 ===
    source "$PROJECT_ROOT/scripts/lib/cleanup.sh"

    # 1. Docker build cache 清理（保留 24 小时热缓存）
    cleanup_docker_build_cache 24

    # 2. 已停止容器清理
    cleanup_stopped_containers 24

    # 3. 未使用网络清理
    cleanup_unused_networks

    # 4. 匿名卷清理
    cleanup_anonymous_volumes

    # 5. node_modules 清理（仅限 noda-apps checkout）
    cleanup_node_modules "$WORKSPACE"

    # 6. 临时文件清理
    cleanup_jenkins_temp_files

    # 磁盘快照（清理后）
    disk_snapshot "清理后"
}
```

### 6.4 pipeline_infra_cleanup() 增强

```bash
pipeline_infra_cleanup()
{
    local service="$1"
    # === 现有逻辑（保持不变）===
    # ...

    # === 新增 ===
    source "$PROJECT_ROOT/scripts/lib/cleanup.sh"

    # 1. Docker build cache（noda-ops 使用 docker build）
    if [ "$service" = "noda-ops" ]; then
        cleanup_docker_build_cache 24
    fi

    # 2. 旧备份清理
    cleanup_old_infra_backups "${service}" 30

    # 3. 通用 Docker 清理
    cleanup_dangling_images
    cleanup_unused_networks
}
```

### 6.5 可配置保留策略

通过环境变量控制保留策略，所有默认值在 `cleanup.sh` 头部定义：

```bash
# 保留策略（可通过环境变量覆盖）
BUILD_CACHE_RETENTION_HOURS="${BUILD_CACHE_RETENTION_HOURS:-24}"
CONTAINER_RETENTION_HOURS="${CONTAINER_RETENTION_HOURS:-24}"
IMAGE_RETENTION_DAYS="${IMAGE_RETENTION_DAYS:-7}"        # 已有
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
PNPM_STORE_PRUNE_FREQUENCY="${PNPM_STORE_PRUNE_FREQUENCY:-7}"  # 天
```

---

## 七、安全考量 -- 什么是绝对不能清理的

### 7.1 红线清单

| 项目 | 为什么不能清理 | 风险 |
|------|--------------|------|
| `postgres_data` 命名卷 | 数据库数据，项目核心价值 | 数据永久丢失 |
| 正在运行的容器 | 提供生产服务 | 服务中断 |
| 当前活跃蓝绿镜像 | 回滚需要 | 无法回滚 |
| `noda-network` external 网络 | 所有服务通信依赖 | 全部服务不可用 |
| `/opt/noda/active-env*` 文件 | 蓝绿路由状态 | 路由混乱 |
| `config/nginx/` 配置 | Nginx 路由 | 网站不可访问 |
| `docker-compose.yml` | 服务定义 | 无法管理服务 |

### 7.2 安全防护措施

```bash
# 1. 清理容器前确认不是运行状态
cleanup_stopped_containers()
{
    # docker container prune 只清理已停止容器，安全
    # 但加 --filter "until=24h" 进一步保护最近停止的容器
    docker container prune -f --filter "until=${1:-24}h"
}

# 2. 清理卷只用匿名模式
cleanup_anonymous_volumes()
{
    # 不使用 --all 标志，只清理匿名卷
    # postgres_data 是命名卷，不会被删除
    docker volume prune -f  # 注意：不加 --all
}

# 3. 清理镜像前保留 current + previous
# 现有 cleanup_by_date_threshold 已实现此逻辑
# 额外保护：保留 latest 标签
# cleanup_by_tag_count 也已保留 latest

# 4. 不清理 build cache 中最近 24 小时的
# 使用 --filter "until=24h" 而非 --all
```

### 7.3 清理函数幂等性

所有清理函数必须是幂等的：
- 重复运行不会报错
- 没有东西可清理时静默返回
- 使用 `-f` 标志跳过确认提示（Pipeline 自动化必须）
- 使用 `2>/dev/null || true` 防止错误传播

---

## 八、功能矩阵 -- 各 Pipeline 需要的清理

| 清理项 | findclass-ssr | noda-site | keycloak | infra (nginx/noda-ops/postgres) |
|--------|:---:|:---:|:---:|:---:|
| 停止非活跃蓝绿容器 | YES | YES | YES | NO（compose 管理） |
| SHA 标签镜像清理 | YES | YES | NO | NO |
| Dangling images | YES | YES | YES | YES |
| Build cache | YES | YES | NO | noda-ops: YES |
| 已停止容器 | YES | YES | YES | YES |
| 未使用网络 | YES | YES | YES | YES |
| 匿名卷 | YES | YES | YES | YES |
| node_modules | YES | YES | NO | NO |
| pnpm store prune | 每 7 天 | 每 7 天 | NO | NO |
| infra-pipeline 备份 | NO | NO | NO | YES |
| 部署失败日志 | YES | YES | YES | YES |
| 磁盘快照 | YES | YES | YES | YES |

---

## 九、推荐实现优先级

### Phase 1：高价值 + 低风险（立即实现）

1. **Docker build cache 清理** -- 单次构建可产生 500MB+ 缓存
2. **node_modules 清理** -- 每次 200-500MB
3. **磁盘用量监控** -- 部署前后对比
4. **部署失败日志清理** -- 成功部署后删除

### Phase 2：中等价值（同批实现）

5. **已停止容器清理** -- 补充现有蓝绿容器清理
6. **未使用网络清理** -- 清理 iptables 规则
7. **匿名卷清理** -- 清理构建临时卷
8. **infra-pipeline 备份清理** -- 防止备份无限增长

### Phase 3：低频维护（可选）

9. **pnpm store prune** -- 每 7 天运行一次（可放在 cron 或特定 Pipeline 参数中）
10. **Jenkins 旧构建清理** -- 已有 `buildDiscarder(logRotator(numToKeepStr: '20'))`

---

## 十、Pitfalls（陷阱与注意事项）

### Pitfall 1：docker system prune -a 会删除蓝绿 standby 镜像

**问题：** `docker system prune -a` 删除所有没有被运行容器引用的镜像。蓝绿部署中 standby 方的镜像没有被容器引用（容器已停止），会被删除。

**后果：** 紧急回滚时无法快速启动旧镜像，需要重新构建。

**预防：** 不使用 `docker system prune -a`。使用现有的 `cleanup_by_date_threshold()` 保留最近 N 天的镜像。

### Pitfall 2：docker volume prune --all 会删除 postgres_data

**问题：** 如果 postgres 容器恰好不在运行（如维护期间），`docker volume prune --all` 会删除 postgres_data 卷。

**后果：** 数据库数据永久丢失。这是项目核心价值。

**预防：** 永远只使用 `docker volume prune -f`（不加 `--all`）。命名卷只在没有容器引用且使用 `--all` 时才会被删除。不加 `--all` 时只删除匿名卷。

### Pitfall 3：pnpm store prune 在构建过程中运行导致安装失败

**问题：** 如果 `pnpm store prune` 与 `pnpm install` 同时运行，可能删除正在下载的包。

**后果：** 构建失败。

**预防：** 只在 Cleanup 阶段（构建完成后）运行 `pnpm store prune`。且建议每 7 天一次，而非每次部署。

### Pitfall 4：清理 Workspace 时删除了 Pipeline 依赖的 scripts/

**问题：** 如果 workspace 清理过于激进，删除了 `scripts/pipeline-stages.sh` 等文件，后续 Pipeline 步骤会失败。

**后果：** Pipeline 执行 Cleanup 阶段时，source 加载文件失败。

**预防：** 只清理 `noda-apps/` 子目录和临时文件。不清理 `scripts/`、`docker/`、`config/`、`deploy/`。

### Pitfall 5：Build cache 清理导致首次构建变慢

**问题：** `docker buildx prune --all` 清理所有 build cache，下次构建需要从零下载所有依赖和重新编译。

**后果：** 构建时间从 3 分钟增加到 10+ 分钟。

**预防：** 使用 `--filter "until=24h"` 保留最近 24 小时的热缓存。或者使用 `--keep-storage=5GB` 保留一定量缓存。

### Pitfall 6：并发 Pipeline 清理冲突

**问题：** 如果两个 Pipeline 同时运行清理，可能产生竞争条件（如同时 prune 同一个资源）。

**后果：** 清理命令报错（但不影响部署结果，因为清理失败不应阻止 Pipeline）。

**预防：** 已有 `disableConcurrentBuilds()` 配置。清理函数使用 `|| true` 确保失败不传播。

### Pitfall 7：infra-pipeline 备份无限增长

**问题：** `pipeline_backup_database()` 每次部署前创建备份，但没有清理旧备份的逻辑。

**后果：** 备份文件在 `docker/volumes/backup/infra-pipeline/` 下无限增长。

**预防：** 实现 `cleanup_old_infra_backups()` 函数，保留最近 30 天的备份。

---

## 十一、完整清理函数模板

```bash
#!/bin/bash
# ============================================
# 综合清理共享库
# ============================================
# 提供 Docker / Node.js / Jenkins 部署后清理函数
# 依赖：log.sh
# 安全：所有函数均为幂等操作，失败不传播
# ============================================

# Source Guard
if [[ -n "${_NODA_CLEANUP_LOADED:-}" ]]; then
    return 0
fi
_NODA_CLEANUP_LOADED=1

# ============================================
# 保留策略（可通过环境变量覆盖）
# ============================================
BUILD_CACHE_RETENTION_HOURS="${BUILD_CACHE_RETENTION_HOURS:-24}"
CONTAINER_RETENTION_HOURS="${CONTAINER_RETENTION_HOURS:-24}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# -------------------------------------------
# Docker Build Cache 清理
# -------------------------------------------
cleanup_docker_build_cache()
{
    local retention_hours="${1:-$BUILD_CACHE_RETENTION_HOURS}"

    log_info "清理 Docker build cache（保留 ${retention_hours} 小时内）..."

    local before_size
    before_size=$(docker buildx du 2>/dev/null | tail -1 | awk '{print $3 $4}' || echo "unknown")

    docker buildx prune -f --filter "until=${retention_hours}h" 2>/dev/null || true

    log_success "Docker build cache 清理完成"
}

# -------------------------------------------
# Dangling Images 清理
# -------------------------------------------
cleanup_dangling_images()
{
    log_info "清理 dangling images..."

    local count
    count=$(docker images -f "dangling=true" -q 2>/dev/null | grep -c . || echo "0")

    if [ "$count" -gt 0 ]; then
        docker image prune -f 2>/dev/null || true
        log_success "Dangling images 清理完成: ${count} 个"
    else
        log_info "无需清理 dangling images"
    fi
}

# -------------------------------------------
# 已停止容器清理
# -------------------------------------------
cleanup_stopped_containers()
{
    local retention_hours="${1:-$CONTAINER_RETENTION_HOURS}"

    log_info "清理超过 ${retention_hours} 小时的已停止容器..."

    docker container prune -f --filter "until=${retention_hours}h" 2>/dev/null || true

    log_success "已停止容器清理完成"
}

# -------------------------------------------
# 未使用网络清理
# -------------------------------------------
cleanup_unused_networks()
{
    log_info "清理未使用的 Docker 网络..."

    docker network prune -f 2>/dev/null || true

    log_success "未使用网络清理完成"
}

# -------------------------------------------
# 匿名卷清理（安全：不删除命名卷）
# -------------------------------------------
cleanup_anonymous_volumes()
{
    log_info "清理匿名卷..."

    # 注意：不加 --all，只清理匿名卷
    # postgres_data 是命名卷，不会被删除
    docker volume prune -f 2>/dev/null || true

    log_success "匿名卷清理完成"
}

# -------------------------------------------
# node_modules 清理
# -------------------------------------------
cleanup_node_modules()
{
    local workspace="$1"

    if [ -z "$workspace" ]; then
        return 0
    fi

    local target="$workspace/noda-apps/node_modules"
    if [ -d "$target" ]; then
        local size
        size=$(du -sh "$target" 2>/dev/null | awk '{print $1}' || echo "unknown")
        log_info "清理 node_modules (${size})..."
        rm -rf "$target"
        log_success "node_modules 清理完成"
    else
        log_info "无 node_modules 需要清理"
    fi
}

# -------------------------------------------
# Jenkins 临时文件清理
# -------------------------------------------
cleanup_jenkins_temp_files()
{
    local workspace="${1:-$WORKSPACE}"

    rm -f "$workspace/deploy-failure-container.log" 2>/dev/null || true
    rm -f "$workspace/deploy-failure-nginx.log" 2>/dev/null || true
    rm -f "$workspace/deploy-failure-infra.log" 2>/dev/null || true
    find "$workspace" -name "*.tmp" -type f -delete 2>/dev/null || true

    log_info "临时文件清理完成"
}

# -------------------------------------------
# infra-pipeline 备份清理
# -------------------------------------------
cleanup_old_infra_backups()
{
    local service="$1"
    local retention_days="${2:-$BACKUP_RETENTION_DAYS}"
    local backup_dir="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}/infra-pipeline/${service}"

    if [ ! -d "$backup_dir" ]; then
        return 0
    fi

    log_info "清理 ${service} 旧备份（保留 ${retention_days} 天）..."

    local deleted=0
    find "$backup_dir" -name "*.sql.gz" -type f -mtime +"${retention_days}" -print -delete 2>/dev/null | while read -r f; do
        deleted=$((deleted + 1))
    done

    log_success "备份清理完成: ${service}，删除 ${deleted} 个超过 ${retention_days} 天的备份"
}

# -------------------------------------------
# 磁盘快照（监控用）
# -------------------------------------------
disk_snapshot()
{
    local label="$1"

    echo "=== 磁盘快照: ${label} ==="
    echo "宿主机: $(df -h / | awk 'NR==2{print $5 " 已用 (" $3 "/" $2 ")"}')"

    # Docker 磁盘概览（静默失败：Docker daemon 可能不可用）
    docker system df 2>/dev/null | head -5 || echo "Docker: 不可用"

    echo ""
}

# -------------------------------------------
# pnpm store 清理（建议每 7 天运行一次）
# -------------------------------------------
cleanup_pnpm_store()
{
    if ! command -v pnpm >/dev/null 2>&1; then
        return 0
    fi

    log_info "pnpm store prune..."
    local store_path
    store_path=$(pnpm store path 2>/dev/null || echo "")

    if [ -n "$store_path" ]; then
        local before_size
        before_size=$(du -sm "$store_path" 2>/dev/null | awk '{print $1}' || echo "unknown")
        log_info "pnpm store 当前: ${before_size}MB"
    fi

    pnpm store prune 2>/dev/null || true

    log_success "pnpm store prune 完成"
}
```

---

## 十二、置信度评估

| 研究领域 | 置信度 | 来源 | 备注 |
|---------|--------|------|------|
| Docker build cache 清理命令 | HIGH | Docker 官方文档 (Context7) | `docker buildx prune` 是标准命令 |
| Docker image/container/network/volume prune | HIGH | Docker 官方文档 (Context7) | 所有 prune 子命令行为已验证 |
| pnpm store prune | HIGH | pnpm 官方文档 (Context7) | 只删除未被引用的包，安全 |
| Jenkins buildDiscarder | HIGH | Jenkins 官方文档 (Context7) | 已配置，无需变更 |
| Jenkins workspace 清理 | MEDIUM | Jenkins 文档 + 社区实践 | 手动 rm -rf 是最可靠方式 |
| 保留策略数值（24h/7d/30d） | MEDIUM | 最佳实践推测 | 需要根据实际部署频率调整 |
| 估算磁盘回收量 | LOW | 未在生产环境测量 | 需要在实现后实际测量 |

---

## 十三、Source

- Docker pruning 文档: https://github.com/docker/docs/blob/main/content/manuals/engine/manage-resources/pruning.md -- HIGH confidence
- Docker CLI system prune: https://github.com/docker/cli/blob/master/docs/reference/commandline/system_prune.md -- HIGH confidence
- pnpm store prune: https://pnpm.io/cli/store -- HIGH confidence
- Jenkins buildDiscarder: https://www.jenkins.io/doc/book/pipeline/syntax -- HIGH confidence
- Jenkins Pipeline best practices: https://www.jenkins.io/doc/book/pipeline/pipeline-best-practices -- HIGH confidence
- 项目源码: `scripts/pipeline-stages.sh`, `scripts/lib/image-cleanup.sh`, `jenkins/Jenkinsfile.*` -- 已完整审查
