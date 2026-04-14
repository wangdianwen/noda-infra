# Domain Pitfalls: Noda v1.4 CI/CD 零停机蓝绿部署

**Domain:** Jenkins + Docker Compose 蓝绿部署（单服务器环境）
**Researched:** 2026-04-14
**Confidence:** MEDIUM（项目代码库深度分析 + 训练知识 + 社区最佳实践；Web 搜索遭遇限流，部分结论未经在线验证）

---

## Critical Pitfalls

### Pitfall 1: Docker Socket 挂载导致容器逃逸

**What goes wrong:**
Jenkins 容器挂载 `/var/run/docker.sock` 以执行 `docker compose build/up`。任何 Pipeline 脚本都可以通过 `docker run -v /:/hostRoot` 获取宿主机 root 权限，读取 `/etc/shadow`、SSH 密钥、`.env` 文件中的所有凭证。

**Why it happens:**
Jenkins 在 Docker 中运行、又要控制 Docker，最"简单"的做法就是挂载 socket。教程和博客大量使用这种模式，不提安全后果。项目 PROJECT.md 明确说"Jenkins 宿主机原生安装"就是为了避免这个问题。

**How to avoid:**
Jenkins 原生安装在宿主机上（不使用 Docker 容器），直接操作 Docker daemon。这消除了 socket 挂载的安全问题，同时简化了 Docker Compose 调用（无需处理容器内 docker CLI 的上下文路径问题）。

**Warning signs:**
- Jenkins 安装方案出现 `docker run -v /var/run/docker.sock:/var/run/docker.sock`
- Jenkinsfile 中出现 `docker.inside {}` 或 `docker.image().inside {}` 模式
- 任何 docker-compose.yml 中出现 `/var/run/docker.sock` 卷映射

**Phase to address:**
Phase 1（Jenkins 安装）。一旦选择了容器化安装，后续所有安全加固都是补丁。

---

### Pitfall 2: 蓝绿容器端口冲突

**What goes wrong:**
当前 findclass-ssr 使用固定容器名 `findclass-ssr` 和固定内部端口 3001。蓝绿部署需要同时运行两个实例（如 `findclass-blue` 和 `findclass-green`），但 nginx upstream 硬编码了 `findclass-ssr:3001`。如果直接用 Docker Compose 启动两个同 image 不同名的服务，nginx 不会自动发现新服务。

**Why it happens:**
Docker Compose 的服务发现依赖服务名（DNS）。当前架构中 nginx upstream 指向固定服务名 `findclass-ssr`。蓝绿切换需要 nginx 从 `findclass-blue` 切换到 `findclass-green`（或反过来），但 nginx 配置中没有这种动态能力。

**How to avoid:**
两种可行方案：

**方案 A（推荐，简单）：** 单一服务名 + 替换容器
- 保持 `findclass-ssr` 作为唯一服务名
- 先构建新镜像，停掉旧容器，启动新容器（名字相同）
- 不是真正的蓝绿，但配合 nginx `proxy_next_upstream` 和 `fail_timeout=0`（即时故障转移）可以实现极短中断
- 好处：不修改 nginx 配置，不修改 Docker Compose 服务定义

**方案 B（真正蓝绿）：** 两个服务名 + nginx upstream 切换
- 定义 `findclass-blue` 和 `findclass-green` 两个服务
- nginx upstream 通过 `include` 引用动态生成的配置文件
- 切换时修改 include 文件 + `nginx -s reload`
- 好处：零停机，新容器完全启动后再切换

**Warning signs:**
- docker-compose.app.yml 中 `container_name: findclass-ssr` 是固定值
- nginx `upstream findclass_backend` 硬编码 `server findclass-ssr:3001`
- 健康检查 `wget http://localhost:3001/api/health` 假设端口固定

**Phase to address:**
Phase 2（Pipeline 迁移）。在编写 Jenkinsfile 之前必须确定蓝绿策略，否则 Pipeline 逻辑无法设计。

---

### Pitfall 3: 数据库迁移破坏蓝绿共存

**What goes wrong:**
蓝绿部署的核心假设是两个版本可以同时运行。如果新版本包含数据库 schema 变更（如 `DROP COLUMN`、`RENAME TABLE`），旧版本会立即崩溃，因为它期望的列/表已经不存在。这导致回滚不可能。

**Why it happens:**
Prisma migrate 通常在应用启动前运行。蓝绿部署时，新容器启动时运行迁移，立即修改了共享数据库。旧容器还在运行但 schema 已不兼容。如果新版本有问题需要回滚，数据库已经被修改，旧版本的迁移回滚可能无法安全执行。

**How to avoid:**
1. **Expand-Contract 模式**：只做加法迁移（ADD COLUMN、CREATE TABLE），不做破坏性迁移（DROP、RENAME）。破坏性操作延后到下一版本，此时旧容器已完全下线。
2. **迁移与部署分离**：在 Jenkins Pipeline 中，数据库迁移作为独立阶段执行，不与应用启动耦合。迁移先于部署运行，且必须确保向后兼容。
3. **Prisma 约束**：当前项目使用 Prisma 6.x，`prisma migrate deploy` 只执行 forward 迁移。这实际上符合蓝绿最佳实践（不做回滚迁移），但需要在 Pipeline 中正确处理。

**Warning signs:**
- `schema.prisma` 中删除了字段或重命名了表
- Pipeline 中迁移和应用启动在同一个步骤中执行
- 没有迁移兼容性检查（新 schema 是否被旧代码兼容）

**Phase to address:**
Phase 2（Pipeline 迁移）。Pipeline 的阶段设计必须明确迁移的执行时机和兼容性检查。

---

### Pitfall 4: 健康检查假阳性/假阴性

**What goes wrong:**
当前健康检查 `wget --spider http://localhost:3001/api/health` 是 TCP 层面的探活。但在蓝绿切换场景中，容器 "healthy" 不等于 "应用就绪"：
- **假阳性**：容器启动了，端口在监听，但应用还在做 Prisma Client 初始化/缓存预热，第一个请求会超时
- **假阴性**：`start_period: 60s` 太短，Node.js SSR 构建加载慢时健康检查过早判定为 unhealthy

**Why it happens:**
Docker 健康检查设计用于判断容器是否需要重启，不设计用于判断应用是否可以接收生产流量。蓝绿切换需要一个更强的"就绪检查"（readiness probe），而不仅仅是"存活检查"（liveness probe）。

**How to avoid:**
1. **区分两层检查**：
   - Docker HEALTHCHECK：用于容器编排（是否需要重启），保持现有配置
   - Jenkins Pipeline 就绪检查：用于流量切换决策，必须做 HTTP E2E 检查（不仅仅是 TCP）
2. **就绪检查必须验证**：
   - HTTP 200 响应（不是 TCP connect）
   - 响应时间在合理范围内（如 < 2s）
   - 如果是 SSR 服务，验证一个实际页面可以渲染（如 `curl -s -o /dev/null -w "%{http_code}" http://localhost:3001/`）
3. **检查间隔要足够长**：新容器启动后等待 `start_period` + 至少 2 个 `interval`，确保应用完全初始化

**Warning signs:**
- 切换流量后 nginx 返回 502/504
- 切换后第一个用户请求明显变慢（冷启动）
- Pipeline 中用 `sleep 30` 代替真正的健康检查

**Phase to address:**
Phase 3（蓝绿部署实现）。就绪检查是蓝绿切换的核心条件，必须在流量切换前实现。

---

### Pitfall 5: Jenkins Pipeline 部分失败状态不一致

**What goes wrong:**
蓝绿部署 Pipeline 通常有 5-6 个阶段：构建 -> 启动新容器 -> 健康检查 -> 切换流量 -> 停止旧容器 -> 清理。如果在第 3 阶段（健康检查）失败，Pipeline 可能已经构建了新镜像但没清理；如果第 4 阶段（切换流量）失败，nginx 可能指向不健康的容器。

**Why it happens:**
Jenkins Pipeline 的 `post` 块只有 `always`、`success`、`failure` 三种状态。如果 Pipeline 在流量切换阶段中断（如 Jenkins 重启、节点断连），没有一个明确的"回滚到已知安全状态"机制。旧容器可能已被停止但新容器未通过健康检查，导致服务完全不可用。

**How to avoid:**
1. **状态文件跟踪**：在宿主机维护一个 `/opt/noda/active-color` 文件，记录当前活跃的是 blue 还是 green。Pipeline 的每个阶段读写这个文件，断点恢复时可以判断当前状态。
2. **幂等操作**：每个阶段的操作必须幂等。例如"启动新容器"阶段应该先检查容器是否已经在运行。
3. **回滚阶段必须在 failure 中触发**：
   ```groovy
   post {
       failure {
           // 读取状态文件，判断回滚策略
           // 如果流量已切换 -> 切回旧容器
           // 如果流量未切换 -> 确保旧容器仍在运行
       }
   }
   ```
4. **不要在流量切换后立即停止旧容器**：保留旧容器运行至少 5 分钟（观察期），确认新版本稳定后再清理。

**Warning signs:**
- Pipeline 中没有 `post { failure { ... } }` 块
- 回滚逻辑只在最后一步，不在每个关键阶段之后
- 没有状态跟踪文件，Pipeline 重跑时无法判断当前状态
- 旧容器在流量切换后立即被 `docker compose down`

**Phase to address:**
Phase 3（蓝绿部署实现）。Pipeline 的回滚和状态管理是整个蓝绿策略的保底机制。

---

### Pitfall 6: 磁盘空间耗尽导致构建失败

**What goes wrong:**
每次 Jenkins 构建会创建新的 Docker 镜像层。蓝绿部署意味着同时存在两个版本的镜像。在单服务器上，旧镜像不被清理会快速填满磁盘。一旦磁盘满，Docker 构建失败，`docker compose up` 失败，甚至 PostgreSQL 的 WAL 日志无法写入导致数据库崩溃。

**Why it happens:**
Docker 镜像层是增量的。每次 `pnpm install` + `tsc` + `vite build` 的产出都被缓存在 Docker 构建缓存中。findclass-ssr 的多阶段构建（Dockerfile.findclass-ssr）每层约 200-500MB，加上 pnpm store 和 node_modules，单次构建可能产生 1-2GB 的新数据。每周部署 2-3 次，一个月后磁盘增长 10-15GB。

**How to avoid:**
1. **Pipeline 末尾加清理步骤**：
   ```bash
   # 清理悬空镜像（无标签的旧构建层）
   docker image prune -f
   # 清理超过 7 天的构建缓存
   docker builder prune -f --filter "until=168h"
   ```
2. **只保留最近 N 个版本的镜像**：
   ```bash
   # 保留最近 2 个版本的 findclass-ssr 镜像
   docker images findclass-ssr --format '{{.ID}}' | tail -n +3 | xargs -r docker rmi
   ```
3. **定期全量清理 cron**：
   ```bash
   # 每周日凌晨执行
   0 3 * * 0 docker system prune -af --filter "until=168h" --volumes
   ```
4. **磁盘监控**：在 noda-ops 的健康检查中加入磁盘空间检查（`df -h / | tail -1 | awk '{print $5}' | sed 's/%//'`），超过 85% 时告警。

**Warning signs:**
- `docker compose build` 报 `no space left on device`
- Jenkins workspace 目录 `/var/lib/jenkins/workspace/` 超过 10GB
- `docker system df` 显示 Reclaimable > 50%
- PostgreSQL 日志出现 `could not write to file` 错误

**Phase to address:**
Phase 2（Pipeline 迁移）。清理步骤必须在第一个 Pipeline 中就包含，不能延后。

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Jenkins 容器化 + Docker socket 挂载 | 快速搭建，一条命令启动 | 完整的宿主机 root 权限暴露，Pipeline 脚本可执行任意 docker 命令 | 绝不可接受 |
| Pipeline 中 `sleep 30` 代替健康检查 | 简单，"大多数情况够用" | 新版本启动慢时假通过，启动快时浪费时间 | 仅在 POC 阶段 |
| 不做镜像清理 | 少写代码，构建更快 | 磁盘耗尽导致全服务宕机 | 绝不可接受 |
| 固定 blue/green 服务名 | 简化 Docker Compose | 每次 Jenkinsfile 都要知道"哪个是活跃的"，配置与状态耦合 | 可接受（配合状态文件） |
| 跳过数据库迁移兼容性检查 | 部署更快 | 无法回滚的数据库 schema 变更导致全服务不可用 | 仅在无 schema 变更时 |
| Jenkins 全局凭证用明文环境变量 | 配置简单 | 任何 Pipeline 可以读取所有凭证 | 仅在开发环境 |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Jenkins -> Docker Compose | Jenkins workspace 路径与 docker-compose.yml 中的相对路径不匹配（如 `context: ../../noda-apps`） | Jenkins Pipeline 使用绝对路径，或通过 `dir()` 切换到正确的工作目录 |
| Jenkins -> Nginx reload | `docker exec nginx nginx -s reload` 在 nginx 配置有语法错误时静默失败 | 先执行 `docker exec nginx nginx -t`，确认配置正确后再 reload |
| Jenkins -> Docker build | Docker Compose 使用 BuildKit 缓存，Dockerfile 修改未生效 | 关键修改后使用 `docker build --no-cache`，或 Pipeline 中明确 `--no-cache` 参数 |
| Jenkins -> GitHub | SSH key 权限问题导致 git clone 失败 | Jenkins 宿主机上配置 deploy key，确保 `~jenkins/.ssh/` 权限正确 |
| Jenkins -> .env 文件 | Jenkins 环境与 docker compose 的 `.env` 文件不同步 | 使用 sops 解密后注入，不维护两套凭证 |
| Jenkins -> Cloudflare | 部署后忘记清除 CDN 缓存，用户看到旧版本 | Pipeline 最后一步调用 Cloudflare API 清除缓存（`/client/v4/zones/{id}/purge_cache`） |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| 同时构建两个蓝绿镜像 | 构建时间翻倍，内存不足 OOM | 只构建目标颜色，不同时构建 | 2GB 以下内存服务器 |
| Docker BuildKit 缓存膨胀 | `docker system df` 显示 Build Cache 占用超过 50% | 定期 `docker builder prune` | 每次构建 |
| Jenkins workspace 积累 | `/var/lib/jenkins/workspace/` 超过 5GB | Pipeline 中 `cleanWs()` 或 `dir('target') { deleteDir() }` | 每周 |
| 大量旧镜像 | `docker images` 列表有几十个 `<none>` 标签 | Pipeline 末尾 `docker image prune -f` | 每次构建 |
| Prisma generate 在每次构建中 | 构建时间增加 30-60 秒 | Docker 构建缓存层优化，依赖不变时跳过 | 每次 build |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Jenkins 容器挂载 Docker socket | 完整的宿主机 root 权限暴露 | Jenkins 原生安装（PROJECT.md 已明确） |
| Jenkins Web UI 无认证或弱密码 | 任何人可触发部署、读取凭证 | 启用安全领域（Security Realm），使用 Matrix Authorization，强密码 |
| Jenkinsfile 中明文写入凭证 | Pipeline 代码泄露即泄露所有凭证 | 使用 Jenkins Credentials Store + `withCredentials` 块 |
| Jenkins SSH 私钥放在 workspace | 构建产物中包含私钥 | 使用 `sshagent` 步骤，不写入文件系统 |
| 未限制 Jenkins 执行器数量 | 并发构建耗尽服务器资源（内存/CPU/磁盘） | 限制执行器数量为 1-2（单服务器场景） |
| Jenkins 未配置 CSRF 保护 | CSRF 攻击可触发任意构建 | 启用 "Prevent Cross Site Request Forgery exploits" |
| 旧容器未清理 | 旧容器可能仍有活跃连接，暴露攻击面 | 蓝绿切换后设置合理观察期再清理（如 5 分钟） |

---

## "Looks Done But Isn't" Checklist

- [ ] **蓝绿部署:** 实现了容器切换但 nginx upstream 没有更新 -- 验证 `docker exec nginx nginx -T | grep upstream` 指向新容器
- [ ] **健康检查:** 容器 Docker HEALTHCHECK 通过但应用未就绪 -- 验证 HTTP E2E 检查（`curl -sf http://localhost:3001/`），不仅仅是 TCP connect
- [ ] **回滚:** Pipeline 有回滚步骤但回滚后 nginx 仍指向失败的容器 -- 验证回滚逻辑包含 nginx upstream 切换
- [ ] **清理:** Pipeline 有 `docker image prune` 但只清理悬空镜像，未清理旧版本镜像 -- 验证 `docker images` 中无超过 2 个版本的同一镜像
- [ ] **凭证:** Jenkins 可以触发构建但 `.env` 文件中凭证与 Jenkins Credentials 不同步 -- 验证 sops 解密流程在 Jenkins 环境中正确工作
- [ ] **日志:** 蓝绿切换成功但没有审计记录 -- 验证 Jenkins build log 记录了切换前后状态
- [ ] **Cloudflare 缓存:** 部署成功但用户看到旧版本 -- 验证 Pipeline 最后一步调用 Cloudflare purge cache API
- [ ] **构建缓存:** Dockerfile 修改后构建使用了缓存层 -- 验证关键修改使用 `--no-cache` 参数

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Docker socket 暴露 | HIGH（需重建 Jenkins 环境） | 1. 停止 Jenkins 容器 2. 审计是否有可疑 docker 操作 3. 重新安装为原生 4. 轮换所有凭证 |
| 蓝绿切换失败（流量指向不健康容器） | MEDIUM（分钟级恢复） | 1. `docker exec nginx nginx -t` 检查配置 2. 手动切回旧 upstream 配置 3. `docker exec nginx nginx -s reload` 4. 确认旧容器仍在运行 |
| 数据库迁移不兼容 | HIGH（可能无法回滚） | 1. 停止新容器 2. 检查迁移是否可逆 3. 如果不可逆，保持新版本运行并紧急修复 4. 如果可逆，运行回滚迁移 + 恢复旧容器 |
| 磁盘空间耗尽 | MEDIUM（需要手动清理） | 1. `docker system df` 定位占用 2. `docker system prune -af --volumes` 清理 3. 如果 postgres 数据卷受影响，从 B2 备份恢复 |
| Jenkins Pipeline 中断 | LOW（重新触发） | 1. 检查状态文件确定当前阶段 2. 手动确认旧容器状态 3. 重新触发 Pipeline（幂等设计会跳过已完成阶段） |
| 健康检查假阳性导致切换到未就绪容器 | MEDIUM（短暂服务降级） | 1. nginx `proxy_next_upstream` 会自动故障转移回旧容器（如果仍在运行） 2. 如果旧容器已停止，手动重启旧容器并切回 |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Docker socket 挂载 | Phase 1: Jenkins 安装 | Jenkins 运行在宿主机，不在 Docker 容器中 |
| 蓝绿容器端口冲突 | Phase 2: Pipeline 迁移 | nginx upstream 可动态切换，两个实例可共存 |
| 数据库迁移不兼容 | Phase 2: Pipeline 迁移 | Pipeline 中迁移与应用启动分离，迁移向后兼容 |
| 健康检查假阳性/假阴性 | Phase 3: 蓝绿部署 | 就绪检查为 HTTP E2E，不仅仅是 TCP connect |
| Pipeline 部分失败 | Phase 3: 蓝绿部署 | 有状态文件 + 幂等操作 + failure 回滚逻辑 |
| 磁盘空间耗尽 | Phase 2: Pipeline 迁移 | Pipeline 末尾有清理步骤 + 定期 cron 清理 |
| Nginx 配置语法错误 | Phase 3: 蓝绿部署 | 切换前执行 `nginx -t`，失败不执行 reload |
| Cloudflare 缓存未清除 | Phase 3: 蓝绿部署 | Pipeline 最后一步调用 purge cache API |
| Jenkins 安全配置缺失 | Phase 1: Jenkins 安装 | Web UI 有认证、CSRF 启用、凭证使用 Credentials Store |

---

## Sources

- 项目代码库：`docker/docker-compose.app.yml`（findclass-ssr 服务定义、健康检查配置）
- 项目代码库：`deploy/Dockerfile.findclass-ssr`（多阶段构建、构建缓存分析）
- 项目代码库：`config/nginx/conf.d/default.conf`（upstream 硬编码、切换机制）
- 项目代码库：`scripts/deploy/deploy-apps-prod.sh`（现有部署流程、回滚逻辑）
- 项目代码库：`scripts/lib/health.sh`（健康检查实现细节）
- `.planning/PROJECT.md`（v1.4 目标：Jenkins 宿主机原生安装）
- Docker 官方文档：`docker system prune`、`docker image prune`、BuildKit 缓存
- Jenkins 官方文档：Pipeline `post` 块、Credentials Store、CSRF 保护
- Nginx 官方文档：`nginx -s reload` 平滑重载机制
- Prisma 文档：`prisma migrate deploy`（只执行 forward 迁移）
- 社区最佳实践：蓝绿部署 Expand-Contract 模式

---

*Pitfalls research for: Noda v1.4 CI/CD 零停机蓝绿部署*
*Researched: 2026-04-14*
