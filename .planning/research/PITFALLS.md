# Domain Pitfalls: Noda v1.6 Docker 权限收敛 + Pipeline 强制执行

**Domain:** 限制 Docker 访问权限到单一服务用户（jenkins），禁止直接 docker compose / shell 脚本部署
**Researched:** 2026-04-17
**Confidence:** HIGH（项目代码库深度分析 + Docker/Linux 权限模型确定性知识；代码审计覆盖全部 28 个使用 docker 命令的脚本）

---

## Critical Pitfalls

### Pitfall 1: 完全锁定后无法紧急恢复——把自己关在门外

**What goes wrong:**
从 docker 组移除所有其他用户后，如果 jenkins 服务出现故障（Jenkins 不可用、Pipeline 卡死、数据库连接断开），运维人员无法通过 `docker compose` 命令操作任何容器。更危险的是：如果 Jenkins 本身无法启动（比如 H2/PG 数据损坏），就彻底失去了执行 docker 命令的途径，只能通过 SSH 用 `sudo` 恢复。如果 sudo 规则也配置不当，可能需要物理访问服务器恢复。

**Why it happens:**
- 项目当前架构中，jenkins 用户在 docker 组中（`setup-jenkins.sh` 第 160 行：`sudo usermod -aG docker jenkins`）
- 如果移除其他用户的 docker 组权限但没有提供替代的紧急访问路径，就会形成单点故障
- Jenkins Pipeline 中所有 `sh` 步骤都通过 jenkins 用户执行 docker 命令（`Jenkinsfile` 第 53-157 行）
- 备份脚本在 noda-ops 容器内执行（`docker-compose.yml` 第 61-102 行），不依赖宿主机 docker 权限
- 但 `deploy-infrastructure-prod.sh`、`deploy-apps-prod.sh` 等回退脚本由运维人员直接运行，需要 docker 权限

**How to avoid:**
1. **sudoers 白名单保留紧急部署路径**：为运维用户的 sudo 规则保留部署脚本执行权限
   ```
   # /etc/sudoers.d/noda-emergency
   <运维用户> ALL=(root) NOPASSWD: /opt/noda-infra/scripts/deploy/deploy-infrastructure-prod.sh
   <运维用户> ALL=(root) NOPASSWD: /opt/noda-infra/scripts/deploy/deploy-apps-prod.sh
   <运维用户> ALL=(root) NOPASSWD: /usr/bin/docker ps, /usr/bin/docker logs, /usr/bin/docker inspect
   ```
2. **分阶段锁定**：先限制 docker 组到 jenkins + 运维用户，观察一周无问题后再收紧 sudoers 规则
3. **"紧急解锁"脚本**：创建一个 root 专属脚本 `/usr/local/bin/noda-unlock-docker`，为指定用户临时恢复 docker 组权限（15 分钟后自动移除）
4. **文档化紧急流程**：在 PITFALLS.md 和 README 中写明"Jenkins 不可用时如何手动部署"

**Warning signs:**
- 运维用户执行 `docker ps` 报 `permission denied`
- Jenkins 不可用时无法通过手动脚本回退部署
- `sudo -l` 输出中不包含紧急部署脚本路径

**Phase to address:**
Phase 1（Docker 权限收敛设计阶段）。在实施任何权限变更前，必须先建立紧急恢复路径。

---

### Pitfall 2: 移除 docker 组后 Jenkins Pipeline 静默失败

**What goes wrong:**
Jenkins Pipeline 的每个阶段都通过 `sh` 步骤执行 bash 脚本，这些脚本内部大量调用 `docker` 命令。如果权限变更不完整（例如移除了运维用户的 docker 权限但意外影响了 jenkins 用户的组归属），Pipeline 会在第一个 `docker` 调用处失败。更隐蔽的是：Linux 的组变更需要用户重新登录才生效。如果 Jenkins 服务未重启（`systemctl restart jenkins`），jenkins 进程仍然使用旧的组列表，权限变更不会立即生效。但在下次 Jenkins 自动重启（如升级或服务器重启）后，新的组列表才生效——此时才发现 jenkins 用户已不在 docker 组中。

**Why it happens:**
- Linux 进程的补充组（supplementary groups）在进程启动时确定，运行时不会刷新
- Jenkins 以 systemd 服务运行（`setup-jenkins.sh` 第 165 行），`usermod -aG docker jenkins` 后需要 `systemctl restart jenkins` 才能让 jenkins 进程获得新的组
- 反过来也一样：`gpasswd -d jenkins docker` 后如果不重启 Jenkins，旧进程仍有 docker 权限
- 项目中 28 个脚本包含 docker 命令调用（通过 Grep 审计），其中 `pipeline-stages.sh`、`manage-containers.sh`、`blue-green-deploy.sh` 是 Pipeline 核心依赖

**How to avoid:**
1. **测试顺序**：先在 `sudo -u jenkins docker ps` 验证权限，再触发 Pipeline
2. **变更后强制重启 Jenkins**：权限变更后执行 `systemctl restart jenkins`，等待 `wait_for_jenkins` 确认就绪
3. **验证脚本**：创建 `verify-jenkins-docker.sh` 脚本，以 jenkins 用户身份执行 docker 命令验证
   ```bash
   sudo -u jenkins docker ps --format "{{.Names}}" 2>/dev/null || echo "jenkins 用户无 docker 权限"
   ```
4. **Pipeline 前置检查增强**：在 `pipeline_preflight` 函数中添加 docker 权限检查
   ```bash
   docker info >/dev/null 2>&1 || { log_error "当前用户无 docker 权限"; exit 1; }
   ```

**Warning signs:**
- Jenkins 构建日志出现 `Got permission denied while trying to connect to the Docker daemon socket`
- `pipeline_preflight` 阶段失败但 Pre-flight 显示通过（docker 权限检查被跳过）
- `groups jenkins` 显示正确但 `sudo -u jenkins groups` 显示旧组列表（进程缓存问题）

**Phase to address:**
Phase 1（权限变更实施）。每次权限变更后必须验证 Jenkins + Docker 集成。

---

### Pitfall 3: 备份系统宿主机脚本失去 Docker 访问权限

**What goes wrong:**
虽然主要备份逻辑在 noda-ops 容器内运行（不依赖宿主机 docker 权限），但有几个关键脚本在宿主机上使用 `docker exec` 执行操作：
- `scripts/backup/lib/health.sh` 第 70 行：`docker exec "$postgres_host" pg_isready`
- `scripts/backup/lib/health.sh` 第 105-106 行：`docker exec "$postgres_host" psql`
- `scripts/backup/lib/health.sh` 第 356-357 行：`docker exec "$postgres_host" psql`（列出数据库）
- `scripts/deploy/deploy-infrastructure-prod.sh` 第 189 行：`docker exec noda-ops /app/backup/backup-postgres.sh`（部署前备份）
- `scripts/deploy/deploy-infrastructure-prod.sh` 第 141 行：`docker exec noda-ops cat /app/history/history.json`（检查备份时效性）

如果这些脚本由非 jenkins 用户执行（如 cron 任务、手动运维），权限限制会导致备份系统静默失败。

**Why it happens:**
- 宿主机上的备份相关脚本通过 `docker exec` 与容器交互，这需要 docker 组权限
- 如果 cron job 以非 jenkins 用户运行，或运维人员手动执行这些脚本，都会被权限阻止
- `deploy-infrastructure-prod.sh` 是 Jenkins 不可用时的紧急回退脚本（文件头注释明确说明），如果运维用户也无权限，紧急回退就不可用
- `verify-infrastructure.sh` 和 `verify-services.sh` 使用 `docker-compose ps` 检查服务状态，也需要 docker 权限

**How to avoid:**
1. **区分容器内 vs 宿主机脚本**：
   - 容器内脚本（noda-ops 中的 backup-postgres.sh）不受影响
   - 宿主机脚本（deploy-infrastructure-prod.sh、verify-*.sh）需要通过 sudoers 授权
2. **备份脚本的权限设计**：
   - noda-ops 容器内的定时备份（cron）继续正常运行——不依赖宿主机 docker
   - 宿主机上的备份验证/恢复脚本通过 sudoers 授权给特定用户
3. **sudoers 规则包含 docker exec**：
   ```
   <运维用户> ALL=(root) NOPASSWD: /usr/bin/docker exec noda-ops *
   <运维用户> ALL=(root) NOPASSWD: /usr/bin/docker exec noda-infra-postgres-prod *
   ```

**Warning signs:**
- noda-ops 容器的定时备份仍然正常（容器内执行），但手动触发的宿主机备份命令失败
- `deploy-infrastructure-prod.sh` 报 `docker exec: permission denied`
- 备份验证脚本无法查询数据库大小

**Phase to address:**
Phase 1（权限设计）。必须完整审计所有使用 docker 命令的脚本，逐个确认权限路径。

---

### Pitfall 4: docker compose 需要同时具备 Docker socket 权限和 compose 文件读取权限

**What goes wrong:**
`docker compose` 命令需要两个维度的权限：（1）Docker socket 访问（`/var/run/docker.sock`）；（2）compose 文件和环境文件的读取权限。只授权了 Docker socket 访问但忘记授权文件读取，docker compose 仍然会失败。项目中的 compose 文件涉及：
- `docker/docker-compose.yml`
- `docker/docker-compose.prod.yml`
- `docker/docker-compose.app.yml`
- `config/secrets.sops.yaml`（加密密钥）
- `docker/env-*.env`（环境变量模板）

更复杂的是，`manage-containers.sh` 的 `get_host_snippets_dir` 函数（第 138-150 行）通过 `docker inspect` 获取 nginx 挂载路径，然后写入 nginx upstream 配置文件。如果 jenkins 用户无权写入该目录，蓝绿切换的 upstream 更新会失败。

**Why it happens:**
- Docker socket 权限（docker 组）和文件系统权限（文件属主/模式）是两套独立的权限系统
- Jenkins workspace 中的文件默认属于 jenkins 用户，读取通常没问题
- 但 `config/nginx/snippets/` 目录可能属于其他用户（如 root），写入需要额外权限
- `/opt/noda/active-env` 状态文件也涉及写入权限（`manage-containers.sh` 第 76-94 行）

**How to avoid:**
1. **完整权限矩阵审计**：
   | 路径 | 操作 | 需要的权限 | 当前属主 |
   |------|------|-----------|---------|
   | `/var/run/docker.sock` | 读写 | docker 组 | root:docker 660 |
   | `docker/docker-compose*.yml` | 读取 | 文件读取 | jenkins:jenkins |
   | `config/secrets.sops.yaml` | 读取 | 文件读取 | 需确认 |
   | `config/nginx/snippets/*.conf` | 读写 | 文件写入 | 需确认 |
   | `/opt/noda/active-env*` | 读写 | 文件写入 | 需确认 |
   | `docker/env-*.env` | 读取 | 文件读取 | 需确认 |
2. **验证脚本**：权限变更后运行完整的端到端验证
   ```bash
   # 以 jenkins 用户身份测试
   sudo -u jenkins docker compose -f docker/docker-compose.yml config
   sudo -u jenkins touch config/nginx/snippets/upstream-findclass.conf
   sudo -u jenkins sh -c 'echo "blue" > /opt/noda/active-env'
   ```
3. **文件属主预设**：在权限收敛前，将所有必要的配置文件/目录属主改为 jenkins

**Warning signs:**
- `docker compose config` 成功但 `docker compose up` 失败（文件读取权限不足导致 envsubst 失败）
- 蓝绿切换报 `Permission denied: upstream-findclass.conf`
- `set_active_env` 函数报无法写入 `/opt/noda/active-env`

**Phase to address:**
Phase 1（权限设计 + 文件属主整理）。必须在实施 docker 组限制前完成。

---

### Pitfall 5: sudoers 规则中的通配符被滥用导致权限提升

**What goes wrong:**
如果 sudoers 规则使用通配符授权 docker 命令（如 `jenkins ALL=(root) NOPASSWD: /usr/bin/docker *`），获得 sudo 权限的任何人都可以通过 docker 执行任意操作获得完整 root 权限。例如 `sudo docker run -v /:/host -it alpine chroot /host` 即可获得 root shell。即使用 sudoers 授权特定脚本（如 `NOPASSWD: /opt/noda-infra/scripts/deploy/deploy-infrastructure-prod.sh`），如果脚本中有未加引号的变量或可被符号链接攻击的路径，仍然可以被利用。

**Why it happens:**
- sudoers 的通配符 `*` 不是正则表达式，不匹配 `/` 和 `?`，但仍可匹配任意参数
- Docker 的子命令本身就可以被用来做权限提升（mount root 文件系统、privileged 容器等）
- 项目中的 `manage-containers.sh` 接受环境变量控制 docker run 参数（`EXTRA_DOCKER_ARGS`），如果通过 sudo 执行，攻击者可以注入任意 docker 参数
- `deploy-apps-prod.sh` 接受命令行参数 `$1` 作为 IMAGE_TAG，如果未严格验证可能被利用

**How to avoid:**
1. **不要用 sudoers 授权原始 docker 命令**：只授权封装好的脚本，不授权 `docker *`
2. **脚本内部参数验证**：在所有被 sudoers 授权的脚本开头添加严格参数校验
   ```bash
   # 验证 IMAGE_TAG 只包含允许的字符
   if [[ ! "${IMAGE_TAG}" =~ ^[a-zA-Z0-9_.:-]+$ ]]; then
       log_error "非法镜像标签: ${IMAGE_TAG}"
       exit 1
   fi
   ```
3. **脚本防篡改**：sudoers 授权的脚本必须属于 root 且不可写
   ```bash
   sudo chown root:root /opt/noda-infra/scripts/deploy/deploy-infrastructure-prod.sh
   sudo chmod 755 /opt/noda-infra/scripts/deploy/deploy-infrastructure-prod.sh
   ```
4. **禁止符号链接攻击**：sudoers 中使用绝对路径，脚本内部也使用绝对路径

**Warning signs:**
- `sudo -l` 显示 `NOPASSWD: /usr/bin/docker *`（过于宽泛）
- sudoers 授权的脚本文件权限为 `777` 或属主不是 root
- 脚本中存在未引用的变量展开（`$@` 未加引号）

**Phase to address:**
Phase 1（sudoers 规则设计）。sudoers 规则必须在实施前经过安全审计。

---

### Pitfall 6: 新组成员不立即生效——uid/gid 缓存陷阱

**What goes wrong:**
`usermod -aG docker jenkins` 执行后，jenkins 用户的组变更不会立即反映在已运行的进程中。Linux 内核在进程创建时（`fork`/`exec`）读取 `/etc/group`，但已运行的进程使用的是启动时的组列表。这意味着：
- 如果 Jenkins 正在运行，`usermod` 后 jenkins 进程仍无法访问 docker socket
- 如果在 `gpasswd -d jenkins docker` 后不重启 Jenkins，jenkins 进程仍保留 docker 权限
- `newgrp docker` 只影响当前 shell，不影响 systemd 管理的服务

**Why it happens:**
- Linux 进程的补充组列表在 `execve` 时由内核从 `/etc/group` 读取
- systemd 服务在 `systemctl start` 时读取用户组，运行中不会刷新
- `usermod` 只修改 `/etc/group` 文件，不通知已运行进程
- `sg docker -c "command"` 或 `newgrp docker` 只影响子进程

**How to avoid:**
1. **变更后重启服务**：任何组变更后必须重启 Jenkins
   ```bash
   sudo usermod -aG docker jenkins
   sudo systemctl restart jenkins
   # 等待 Jenkins 就绪
   ```
2. **验证脚本包含进程级检查**：
   ```bash
   # 检查 jenkins 进程的实际组（不是 /etc/group）
   pid=$(pgrep -u jenkins -f jenkins.war | head -1)
   cat /proc/$pid/status | grep Groups
   ```
3. **变更记录**：每次权限变更后在审计日志中记录操作时间和验证结果

**Warning signs:**
- `groups jenkins` 显示 docker 但 `sudo -u jenkins docker ps` 报 permission denied
- `cat /proc/$(pgrep -f jenkins.war)/status | grep Groups` 不包含 docker GID
- Jenkins 重启后突然能（或不能）执行 docker 命令

**Phase to address:**
Phase 1（权限变更实施）。所有权限变更后必须重启 Jenkins 并验证。

---

### Pitfall 7: 权限变更后忘记更新 setup-jenkins.sh 安装脚本

**What goes wrong:**
`setup-jenkins.sh` 第 160 行硬编码了 `sudo usermod -aG docker jenkins`。如果 v1.6 的权限模型改为"jenkins 不在 docker 组，而是通过其他机制访问 Docker"，这个安装脚本会在重新安装 Jenkins 时创建不安全的权限配置。更严重的是：`setup-jenkins.sh uninstall` 第 240 行执行 `sudo gpasswd -d jenkins docker`，如果新权限模型中 jenkins 本来就不在 docker 组，这个命令虽然无害但暗示了旧的权限模型仍然被代码引用。

**Why it happens:**
- 安装/卸载脚本的生命周期比配置变更长
- 开发者通常只修改当前的权限配置，忘记同步更新安装脚本
- `setup-jenkins.sh` 的 `cmd_status` 函数（第 298 行）检查 jenkins 是否在 docker 组中——如果新模型不再依赖 docker 组，这个检查会误报

**How to avoid:**
1. **同步更新安装脚本**：权限模型变更后，立即更新 `setup-jenkins.sh` 中所有相关代码
2. **权限检查函数统一化**：创建 `scripts/lib/docker-permissions.sh`，所有脚本（包括安装脚本和 Pipeline 脚本）统一调用
3. **测试安装脚本**：在测试环境中执行 `setup-jenkins.sh uninstall && setup-jenkins.sh install` 验证完整生命周期

**Warning signs:**
- `setup-jenkins.sh status` 报 jenkins 不在 docker 组（但实际通过其他机制有权限）
- 重新安装 Jenkins 后权限模型回退到旧的 docker 组模式
- 安装脚本的输出与实际权限配置不一致

**Phase to address:**
Phase 2（部署脚本权限锁定）。安装脚本更新必须在权限变更实施后同步完成。

---

## Moderate Pitfalls

### Pitfall 1: 部署脚本所有者/权限不正确导致 sudoers 规则失效

**What goes wrong:**
sudoers 中授权了脚本路径，但脚本文件的权限允许非 root 用户修改。攻击者可以替换脚本内容为 `bash -i` 获得交互式 root shell。或者更隐蔽地，在脚本中注入 `docker run -v /:/host alpine chroot /host` 命令。

**How to avoid:**
```bash
sudo chown root:root /opt/noda-infra/scripts/deploy/*.sh
sudo chmod 755 /opt/noda-infra/scripts/deploy/*.sh
# 验证
ls -la /opt/noda-infra/scripts/deploy/*.sh
```

---

### Pitfall 2: 审计日志配置不当导致磁盘空间耗尽

**What goes wrong:**
操作审计日志如果配置为记录所有 docker 命令（包括 Pipeline 中的高频 `docker inspect`、`docker logs`），可能在短时间内产生大量日志。如果日志轮转未配置，根分区会被填满，导致所有服务崩溃。

**How to avoid:**
- 审计日志只记录写操作（`docker run`、`docker stop`、`docker rm`、`docker compose up/down`），不记录读操作
- 配置 logrotate（每天轮转，保留 30 天）
- 审计日志存储在独立分区或 `/var/log/audit/`

---

### Pitfall 3: Nginx upstream 配置文件写入权限与蓝绿部署冲突

**What goes wrong:**
蓝绿部署通过 `manage-containers.sh` 的 `update_upstream` 函数写入 `config/nginx/snippets/upstream-*.conf` 文件。如果这些文件的属主/权限在收敛过程中被改为 root:root 644，jenkins 用户无法写入，蓝绿切换会失败。当前 `get_host_snippets_dir` 函数通过 `docker inspect` 获取挂载路径，实际写入位置取决于 Docker volume 的挂载源。

**How to avoid:**
```bash
# 确保 jenkins 可写入 nginx snippets 目录
sudo chown -R jenkins:jenkins /path/to/config/nginx/snippets/
# 或者使用 ACL
sudo setfacl -m u:jenkins:rw /path/to/config/nginx/snippets/upstream-*.conf
```

---

### Pitfall 4: 环境变量文件（env template）权限泄露密钥

**What goes wrong:**
收敛过程中如果调整文件权限，可能意外暴露包含敏感信息的环境变量文件。例如 `docker/env-findclass-ssr.env` 包含 `POSTGRES_PASSWORD` 和 `RESEND_API_KEY`。如果为了方便调试将这些文件设为 `644`（所有人可读），任何系统用户都可以看到数据库密码。

**How to avoid:**
```bash
# 敏感文件必须 600 或 640
chmod 600 docker/env-*.env
chown jenkins:jenkins docker/env-*.env
# 验证
find docker/ -name "*.env" -exec ls -la {} \;
```

---

## Minor Pitfalls

### Pitfall 1: verify 脚本使用 docker-compose（v1 命令）而非 docker compose

**What goes wrong:**
`verify-infrastructure.sh` 和 `verify-services.sh` 使用 `docker-compose`（带连字符的 v1 命令）而非 `docker compose`（v2 插件命令）。在权限收敛后，如果 sudoers 只授权了 `/usr/bin/docker`（v2 插件），`docker-compose`（独立二进制）可能不在授权范围内。

**How to avoid:**
将所有 `docker-compose` 调用统一为 `docker compose`，或确保 sudoers 同时授权两种命令形式。

---

### Pitfall 2: 容器日志查看权限被过度限制

**What goes wrong:**
紧急排查时需要查看容器日志（`docker logs --tail 100`）。如果 sudoers 只授权了部署脚本，运维人员无法直接查看日志，只能通过 Jenkins 的 Stage View 查看构建日志中的 `docker logs` 输出。如果 Jenkins 不可用，就彻底失去了查看容器日志的途径。

**How to avoid:**
sudoers 中为运维用户保留只读 docker 命令权限：
```
<运维用户> ALL=(root) NOPASSWD: /usr/bin/docker ps, /usr/bin/docker logs *, /usr/bin/docker inspect *
```

---

### Pitfall 3: 权限变更前未完整备份当前权限状态

**What goes wrong:**
权限收敛后发现问题需要回退，但忘记变更前的精确权限配置。`getent group docker` 显示当前成员，但不记录历史。回退时只能猜测原始配置。

**How to avoid:**
```bash
# 变更前备份权限状态
getent group docker > /root/pre-v1.6-docker-group.txt
ls -la /var/run/docker.sock > /root/pre-v1.6-socket-perms.txt
find /opt/noda-infra -name "*.sh" -exec ls -la {} \; > /root/pre-v1.6-script-perms.txt
sudo -l > /root/pre-v1.6-sudo-rules.txt 2>&1
```

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| 用 docker 组代替 sudoers 白名单 | 配置简单，一行 `usermod` | jenkins 用户有完整 root 等价权限，无法限制子命令 | 仅在单用户服务器且无其他用户时 |
| 不更新 setup-jenkins.sh | 节省测试时间 | 新安装的 Jenkins 使用旧的权限模型，安全策略不一致 | 绝不可接受 |
| sudoers 用通配符 `docker *` | 避免逐条列出子命令 | 任何可通过 sudo 执行 docker 的用户可获取 root | 绝不可接受 |
| 审计日志只记录脚本执行 | 配置简单 | 无法追溯是谁在什么时候执行了什么 docker 操作 | 仅在初期试运行阶段（1-2 周） |
| 跳过文件属主审计 | 节省审计时间 | jenkins 用户可能无法写入 nginx upstream 文件导致蓝绿切换失败 | 绝不可接受 |
| 不测试紧急回退流程 | 节省测试时间 | 真正需要手动回退时发现权限不足 | 绝不可接受 |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Jenkins -> Docker socket | `chmod 666 /var/run/docker.sock` 解决权限问题 | 使用 docker 组成员或 sudoers，绝不要 666（所有用户可访问，且 Docker 重启后失效） |
| Jenkins -> compose 文件 | 只考虑 socket 权限，忘记 compose 文件读取权限 | 同时验证 `docker compose config` 能成功执行 |
| sudoers -> 部署脚本 | 授权 `docker *` 通配符，可被利用获取 root | 只授权特定脚本路径，脚本内部验证参数 |
| Jenkins 重启 -> Pipeline 状态 | 重启 Jenkins 期间正在运行的 Pipeline 丢失 | 重启前确认无正在运行的构建，或等待当前构建完成 |
| noda-ops 备份 -> 宿主机权限 | 误以为宿主机权限限制会影响容器内备份 | noda-ops 容器内 cron 不依赖宿主机 docker 权限，只有宿主机上的 `docker exec` 调用受影响 |
| Nginx upstream -> 文件写入 | 忘记授权 jenkins 写入 nginx snippets 目录 | 权限变更后测试 `manage-containers.sh switch` 完整流程 |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| sudoers 规则过多 | 每次 `sudo` 执行都需解析所有规则，Pipeline 启动变慢 | 保持 sudoers 规则精简（少于 20 条），使用独立的 sudoers.d 文件 | 超过 100 条规则时 |
| 审计日志 I/O 开销 | 每次 docker 命令都写审计日志，高频 `docker inspect` 时磁盘 I/O 瓶颈 | 审计日志排除读操作，只记录写操作 | 每分钟超过 50 次 docker 命令时 |
| ACL 查找开销 | 大量 `setfacl` 规则导致文件访问变慢 | 用传统 owner/group 权限代替 ACL，仅在必要时使用 ACL | ACL 规则超过 50 条时 |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| jenkins 用户在 docker 组 | jenkins 被入侵 = 容器逃逸 = root 权限 | 长期方案：使用 rootless docker 或 sudoers 白名单；短期：确保 jenkins 只能通过 Pipeline 执行 docker 命令 |
| sudoers 授权 `/usr/bin/docker *` | 任何有 sudo 权限的用户可 `sudo docker run -v /:/host` 获得 root | 只授权封装脚本，不授权原始 docker 命令 |
| 部署脚本可被非 root 修改 | 恶意用户替换脚本内容获取 root | `chown root:root` + `chmod 755` |
| 审计日志存储在根分区 | 日志膨胀导致根分区满，所有服务崩溃 | 审计日志存储在独立分区，配置 logrotate |
| 环境变量文件权限过宽 | 数据库密码泄露 | `chmod 600` + `chown jenkins:jenkins` |
| 紧急解锁脚本无时间限制 | 临时权限变为永久权限 | 使用 `at` 或 `systemd timer` 在 15 分钟后自动收回权限 |

---

## "Looks Done But Isn't" Checklist

- [ ] **Docker 权限收敛:** `groups <用户>` 显示无 docker 但进程缓存仍有权限 -- 验证：`cat /proc/$(pgrep -f jenkins.war)/status | grep Groups` 不包含 docker GID
- [ ] **Docker 权限收敛:** `groups jenkins` 显示在 docker 组但 Pipeline 仍报 permission denied -- 验证：重启 Jenkins 后触发一次完整 Pipeline
- [ ] **sudoers 白名单:** `sudo -l` 显示正确但脚本执行时仍被拒 -- 验证：`sudo -u <用户> sudo -n /path/to/script.sh` 能成功执行
- [ ] **部署脚本锁定:** 脚本有 `x` 权限但被授权用户无法执行 -- 验证：脚本路径的每一级目录都有 `x` 权限（`namei -l /opt/noda-infra/scripts/deploy/deploy-apps-prod.sh`）
- [ ] **紧急回退测试:** 运维用户可执行紧急部署脚本 -- 验证：`sudo -u <运维用户> sudo -n bash scripts/deploy/deploy-infrastructure-prod.sh --skip-backup`
- [ ] **Nginx upstream 写入:** jenkins 可写入 upstream 配置文件 -- 验证：`sudo -u jenkins sh -c 'echo "test" > config/nginx/snippets/upstream-findclass.conf.tmp && rm config/nginx/snippets/upstream-findclass.conf.tmp'`
- [ ] **审计日志轮转:** 审计日志不会无限增长 -- 验证：`logrotate -d /etc/logrotate.d/noda-audit` 显示正确的轮转配置
- [ ] **备份系统不受影响:** noda-ops 容器内备份正常运行 -- 验证：`docker exec noda-ops bash -c 'pg_isready -h noda-infra-postgres-prod'`
- [ ] **蓝绿部署完整流程:** 权限收敛后完整蓝绿部署可执行 -- 验证：触发 Jenkins Pipeline 并观察 Deploy -> Switch -> Verify 全阶段通过

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| 锁定后无法访问 Docker | HIGH（需 root/sudo 恢复） | 1. SSH 以 root 登录 2. `usermod -aG docker <用户>` 3. `systemctl restart jenkins`（如果影响了 jenkins）4. 验证 docker 命令可用 |
| Jenkins Pipeline 失败（权限原因） | LOW（重启 Jenkins 即可） | 1. `systemctl restart jenkins` 2. 等待 `wait_for_jenkins` 3. 重新触发 Pipeline |
| 备份脚本失败（宿主机权限） | MEDIUM（需修改 sudoers） | 1. 在 sudoers 中添加 `docker exec` 白名单 2. 验证 `sudo docker exec noda-ops pg_isready` |
| 蓝绿切换失败（upstream 写入） | LOW（修改文件属主） | 1. `chown jenkins:jenkins config/nginx/snippets/` 2. 验证 `update_upstream` 函数可写入 |
| sudoers 规则配置错误 | MEDIUM（需 visudo 修复） | 1. `sudo visudo -f /etc/sudoers.d/noda-*` 2. 修正规则 3. `sudo -l` 验证 |
| 审计日志填满磁盘 | MEDIUM（需清理 + 配置轮转） | 1. `find /var/log/audit -mtime +7 -delete` 2. 配置 logrotate 3. 考虑独立分区 |
| 权限回退到变更前状态 | LOW（有备份） | 1. 参考 `/root/pre-v1.6-*.txt` 备份文件 2. 逐一恢复 docker 组成员和文件权限 |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 锁定后无法紧急恢复 | Phase 1: Docker 权限收敛设计 | `sudo -u <运维用户> bash scripts/deploy/deploy-infrastructure-prod.sh --skip-backup` 成功执行 |
| Jenkins Pipeline 静默失败 | Phase 1: 权限变更实施 | `systemctl restart jenkins` 后触发完整 Pipeline 通过 |
| 备份系统权限丢失 | Phase 1: 权限设计（审计） | `docker exec noda-ops pg_isready` 成功；`deploy-infrastructure-prod.sh` 部署前备份步骤成功 |
| compose 文件读取权限 | Phase 1: 文件属主审计 | `sudo -u jenkins docker compose -f docker/docker-compose.yml config` 成功 |
| sudoers 通配符权限提升 | Phase 1: sudoers 规则设计 | `sudo -l` 不包含 `docker *` 通配符规则 |
| uid/gid 缓存陷阱 | Phase 1: 权限变更实施 | `cat /proc/$(pgrep -f jenkins.war)/status \| grep Groups` 反映正确的组列表 |
| 安装脚本未更新 | Phase 2: 部署脚本锁定 | `setup-jenkins.sh uninstall && setup-jenkins.sh install` 产生正确的权限配置 |
| upstream 写入权限 | Phase 1: 文件属主审计 | `manage-containers.sh switch` 完整流程通过 |
| 审计日志磁盘满 | Phase 3: 审计日志实施 | `logrotate -d` 显示正确轮转配置 |
| env 文件权限泄露 | Phase 1: 文件属主审计 | `find docker/ -name "*.env" -perm /o+r` 返回空 |

---

## Phase-Specific Warnings

| Phase | Likely Pitfall | Mitigation |
|-------|---------------|------------|
| Phase 1: Docker 权限设计 | 过度设计 sudoers 规则导致调试困难 | 先用最小规则集，逐步收紧；每条规则都有注释说明用途 |
| Phase 1: 权限变更实施 | 变更期间 Jenkins 正在执行 Pipeline | 变更前确认 Jenkins 无正在运行的构建 |
| Phase 1: 文件属主审计 | 漏掉某个关键文件的权限 | 使用 `namei -l` 追踪每个脚本访问路径上的所有目录权限 |
| Phase 2: 部署脚本锁定 | 脚本锁定后无法快速修补紧急 bug | 保留 root 用户的直接修改权限 |
| Phase 2: 安装脚本同步 | 安装脚本与新权限模型不一致 | 在测试环境执行完整的 install -> verify -> uninstall 生命周期 |
| Phase 3: 审计日志 | 审计日志泄露敏感信息（环境变量值） | 审计日志只记录命令名称和参数模式，不记录环境变量值 |
| 全局: 回归验证 | 权限变更影响范围超出预期 | 每次权限变更后运行完整的端到端验证（Pipeline + 手动回退 + 备份检查） |

---

## 权限变更安全测试协议

权限变更的测试必须按以下顺序执行，不可跳过任何步骤：

```
1. 预检查（变更前快照）
   ├── getent group docker > /root/pre-change-docker-group.txt
   ├── ls -la /var/run/docker.sock > /root/pre-change-socket.txt
   ├── find /opt/noda-infra -name "*.sh" -exec ls -la {} \; > /root/pre-change-scripts.txt
   └── sudo -l > /root/pre-change-sudo.txt

2. 变更执行（单步变更 + 验证）
   ├── 执行单个权限变更命令
   ├── 立即验证：groups, id, ls -la
   └── 如果验证失败：立即回退，不继续

3. Jenkins 重启
   ├── systemctl restart jenkins
   ├── 等待 wait_for_jenkins
   └── sudo -u jenkins docker ps

4. Pipeline 端到端测试
   ├── 触发 Jenkinsfile 完整构建
   ├── 确认所有阶段通过
   └── 检查构建日志无 permission denied

5. 紧急回退路径测试
   ├── sudo -u <运维用户> docker ps
   ├── sudo -u <运维用户> docker logs noda-infra-postgres-prod --tail 5
   └── sudo -u <运维用户> bash scripts/deploy/deploy-infrastructure-prod.sh --skip-backup

6. 备份系统测试
   ├── docker exec noda-ops pg_isready -h noda-infra-postgres-prod
   └── 确认 noda-ops 容器内 cron 定时任务不受影响

7. 回归快照（变更后）
   ├── 重复步骤 1 的所有命令，保存为 post-change-*.txt
   └── diff pre-change-*.txt post-change-*.txt 确认只变更了预期内容
```

---

## Sources

- 项目代码库审计（28 个使用 docker 命令的脚本）
  - `scripts/setup-jenkins.sh`（jenkins 用户 docker 组配置、安装/卸载流程）
  - `scripts/manage-containers.sh`（蓝绿容器管理、docker run/exec/inspect 调用）
  - `scripts/blue-green-deploy.sh`（蓝绿部署、健康检查）
  - `scripts/pipeline-stages.sh`（Pipeline 阶段函数、备份时效性检查）
  - `scripts/deploy/deploy-infrastructure-prod.sh`（基础设施部署、docker compose 操作）
  - `scripts/deploy/deploy-apps-prod.sh`（应用部署、docker compose build/up）
  - `scripts/backup/lib/health.sh`（宿主机上通过 docker exec 执行 pg_isready/psql）
  - `scripts/lib/health.sh`（容器健康检查、docker inspect/logs 调用）
  - `scripts/verify/*.sh`（服务验证、docker-compose ps/exec 调用）
  - `scripts/utils/validate-docker.sh`（Docker Compose 配置验证）
- Jenkinsfile 分析
  - `jenkins/Jenkinsfile`（9 阶段 Pipeline、sh 步骤全部依赖 docker 命令）
  - `jenkins/Jenkinsfile.infra`（7 阶段基础设施 Pipeline、docker compose 操作）
  - `jenkins/Jenkinsfile.noda-site`（noda-site 蓝绿部署）
  - `jenkins/Jenkinsfile.keycloak`（Keycloak 蓝绿部署）
- Docker Compose 配置
  - `docker/docker-compose.yml`（noda-ops 容器内备份配置）
  - `docker/docker-compose.app.yml`（蓝绿容器定义）
- Nginx 配置
  - `config/nginx/snippets/upstream-*.conf`（蓝绿切换目标文件）
- `.planning/PROJECT.md`（v1.6 目标：Docker 权限收敛、部署脚本权限锁定、操作审计日志）

---
*Pitfalls research for: Noda v1.6 Jenkins Pipeline 强制执行 — Docker 权限收敛*
*Researched: 2026-04-17*
