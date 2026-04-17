# Feature Research

**Domain:** CI/CD 强制执行 -- 确保所有容器部署仅通过 Jenkins Pipeline 完成
**Researched:** 2026-04-17
**Confidence:** HIGH（基于代码库深度分析 + Linux/Docker 安全机制验证 + Jenkins 审计插件官方文档）
**Supersedes:** v1.5 FEATURES.md（开发环境本地化 + 基础设施 CI/CD，已全部实现）

---

## Table Stakes

缺少会让系统不完整或不符合项目架构方向的功能。这些是 "CI/CD-only 部署" 的基线要求。

| # | Feature | Why Expected | Complexity | Notes |
|---|---------|--------------|------------|-------|
| T1 | **Docker 组权限收敛：仅 jenkins 用户** | 当前任何有 sudo 权限的用户都能执行 `docker compose up`，绕过 Pipeline。如果目标是 "所有容器只能通过 Jenkins Pipeline 上线"，那么 Docker 命令权限必须收敛到 jenkins 用户。这是强制的最小权限原则 | Low | `sudo usermod -aG docker jenkins` 已完成；需要从 docker 组移除其他用户（如 ubuntu/deploy），确保只有 jenkins + root 可执行 docker 命令；`/var/run/docker.sock` 权限 `srw-rw---- root:docker` 需验证 |
| T2 | **部署脚本权限锁定** | `scripts/deploy/deploy-apps-prod.sh` 和 `scripts/deploy/deploy-infrastructure-prod.sh` 是紧急回退脚本，任何用户都能直接执行。需要限制为仅 jenkins 用户可执行（`chown jenkins:jenkins` + `chmod 700`），确保正常部署路径只有 Pipeline 一条 | Low | 文件属主改为 `jenkins:jenkins`，权限改为 `700`（仅属主可读写执行）；紧急场景通过 sudo 切换到 jenkins 用户执行 |
| T3 | **操作系统级 Docker 命令审计** | 需要知道 "谁在什么时候执行了什么 docker 命令"，无论是否通过 Pipeline。这是审计追踪的基础层，即使 Pipeline 被绕过也能事后发现 | Med | Linux auditd 监控 `/var/run/docker.sock` 读写：`auditctl -w /var/run/docker.sock -p rwxa -k docker_access`；日志可通过 `ausearch -k docker_access` 查询；轻量级，不依赖任何额外服务 |
| T4 | **Jenkins Pipeline 操作审计** | Jenkins 自身需要记录 "谁触发了哪个 Pipeline、用了什么参数、结果如何"。这是合规性和可追溯性的核心要求 | Med | Jenkins Audit Trail 插件（436.vc0d1e79fc5a_3，4.09% 安装率）记录 Job 创建/配置/删除、构建触发、凭据使用、Groovy 脚本执行；支持 File logger（滚动文件）、Syslog 输出；配置在 Jenkins 全局设置中 |
| T5 | **Jenkins 权限矩阵细化** | 当前 Jenkins 使用 "Logged-in users can do anything" 全局权限模型。为了强制执行 "只有授权用户可以触发部署"，需要细粒度权限控制 | Med | Matrix Authorization Strategy 插件（3.2.9，91.0% 安装率）支持按用户/组配置权限：Overall Read、Job Build、Job Read 等；可限制非管理员只能触发特定 Job 而不能修改配置 |

## Differentiators

提升运维效率和安全性的增值功能。不是必须的，但显著提升系统的可维护性和合规性。

| # | Feature | Value Proposition | Complexity | Notes |
|---|---------|-------------------|------------|-------|
| D1 | **紧急访问（Break-Glass）机制文档化** | 紧急场景（Jenkins 宕机、服务器故障）需要绕过 Pipeline 直接部署。需要有文档化的流程和审计追踪，而不是随意的 "用 sudo 直接跑" | Low | 流程：sudo 切换到 jenkins 用户 -> 执行部署脚本 -> 事后记录到 Incident Log；不引入额外工具（无 HashiCorp Vault、无 SSH 代理），保持简单 |
| D2 | **部署脚本 wrapper + 日志记录** | 在紧急回退脚本执行时自动记录 "谁、什么时候、为什么绕过了 Pipeline"，使紧急访问同样可审计 | Low | 创建 `scripts/deploy/break-glass-deploy.sh` wrapper：记录当前用户、时间戳、原因（交互式输入）到 `/var/log/noda/break-glass.log`；然后 sudo -u jenkins 执行实际脚本 |
| D3 | **auditd 日志轮转与保留策略** | 审计日志会持续增长，需要配置轮转防止磁盘满。生产环境的审计日志通常保留 90 天 | Low | `/etc/audit/rules.d/audit.rules` 持久化规则；`/etc/audit/auditd.conf` 配置 `max_log_file` + `num_logs`；不引入外部 SIEM |
| D4 | **Jenkins H2 -> PostgreSQL 迁移**（延续） | Jenkins 数据库从 H2 迁移到 PostgreSQL，使 Jenkins 配置变更和 Pipeline 构建记录可纳入现有的 B2 备份体系。与审计日志互补 -- Jenkins 审计数据也在 PG 中，不会被 H2 文件损坏丢失 | Med | v1.5 遗留需求，已在 PROJECT.md Active 列表中；依赖 T1 完成（本地 PG 可用）；Jenkins 需停机 5-15 分钟 |
| D5 | **定期权限审查提醒** | 权限配置会随时间漂移（新用户加入、临时权限忘记移除）。定期提醒审查防止权限腐化 | Low | 在 Jenkins 描述或 Wiki 中记录每季度审查 docker 组成员和 Jenkins 权限矩阵；不引入自动化审查工具 |

## Anti-Features

明确不构建的功能。这些看起来合理但在本项目场景下是过度工程化。

| # | Anti-Feature | Why Avoid | What to Do Instead |
|---|-------------|-----------|-------------------|
| A1 | **Docker Socket Proxy（如 Tecnativa docker-socket-proxy）** | 在 docker.sock 前放一个代理过滤 API 调用，可以限制特定 docker 命令。但项目只有单服务器 + 2 个需要 docker 权限的用户（root + jenkins），引入代理增加故障点和维护成本 | Linux 文件权限（docker 组成员控制）已足够；root 不可避免有 docker 权限，jenkins 用户是唯一需要 docker 的服务账户 |
| A2 | **Rootless Docker** | 每个 Docker 命令运行在自己的用户空间，安全隔离更强。但需要重新配置所有 Docker Compose 文件、卷挂载路径、端口绑定；生产环境已经稳定运行，迁移风险远大于安全收益 | 使用 Linux 用户组权限控制 docker.sock 访问 + auditd 监控 |
| A3 | **HashiCorp Vault 或类似密钥管理系统** | 用于 Break-Glass 凭据的临时发放和自动过期。项目只有 1-2 个管理员，不需要企业级密钥管理 | sudo 切换到 jenkins 用户 + 事后文档记录 + auditd 日志 |
| A4 | **Jenkins Configuration as Code (JCasC)** | 用 YAML 声明式配置 Jenkins，包括权限矩阵和审计配置。但项目只有 4 个 Pipeline + 1 个管理员，JCasC 的学习成本和维护复杂度超过收益 | Matrix Auth 插件 UI 配置 + Audit Trail 插件 UI 配置；配置变更通过 Git 管理的 groovy 脚本实现 |
| A5 | **SSH 跳板机 / Teleport / Boundary** | 通过访问代理记录所有 SSH 会话，提供终端录制回放。项目是单服务器，SSH 访问本身就是跳板 | auditd 监控 docker.sock 已覆盖关键操作；SSH 日志（`/var/log/auth.log`）记录谁何时登录 |
| A6 | **CI/CD 门禁自动触发审批（如 Slack/PagerDuty 集成）** | 部署前自动发送审批请求到协作工具。项目部署频率低（周级别），手动在 Jenkins UI 点击 Build Now + input 确认已足够 | 保持 Jenkins 手动触发 + input 门禁模式 |
| A7 | **Docker 镜像签名/内容信任** | Docker Content Trust 确保只运行签名镜像。项目所有镜像都是本地构建或官方镜像，没有从外部 Registry 拉取自定义镜像的需求 | 信任本地构建过程 + Git 版本控制；镜像标签包含 Git SHA 已提供可追溯性 |
| A8 | **SELinux / AppArmor Docker 策略** | 强制访问控制限制容器行为。项目服务器是 Ubuntu（默认无 SELinux），AppArmor 配置复杂度高 | Docker 默认 capability 限制 + `read_only: true` + `tmpfs` 已在 Compose 中配置 |

## Feature Dependencies

依赖关系决定实现顺序。

```
[T1: Docker 组权限收敛]
    |
    +--> [T2: 部署脚本权限锁定]（权限收敛后才锁定脚本，否则影响其他用户正常工作）
    |
    +--> [T5: Jenkins 权限矩阵细化]（权限收敛后细化 Jenkins 侧控制）
    |
    +--> [D1: Break-Glass 文档化]（权限收敛后必须提供紧急访问替代方案）
    |      |
    |      +--> [D2: 部署脚本 wrapper]（文档化流程的自动化实现）
    |
    +--> [D5: 定期权限审查提醒]（依赖权限模型稳定后制定审查流程）

[T3: auditd Docker 命令审计]（独立，可在任何时间点完成）
    |
    +--> [D3: auditd 日志轮转配置]（审计启用后配置轮转）

[T4: Jenkins Audit Trail 插件]（独立，可在任何时间点完成）

[D4: Jenkins H2 -> PG 迁移]（独立，但建议在 T1 后执行以保持逻辑一致）
```

### 依赖说明

1. **T1 -> T2**：Docker 权限收敛是前提。如果先锁定脚本但其他用户还在用 docker 命令，会造成锁定不一致
2. **T1 -> D1**：权限收紧后，紧急访问流程必须同步就绪，否则生产故障时无法快速恢复
3. **T1 -> T5**：操作系统层权限收敛和 Jenkins 层权限细化应配合实施
4. **T3 独立**：auditd 监控与权限控制是正交的 -- 它记录 "发生了什么"，不控制 "能不能做"
5. **T4 独立**：Jenkins 审计与操作系统审计互补但不依赖

### 并行化机会

- T3（auditd）和 T4（Jenkins Audit Trail）可以并行实施，分别覆盖 OS 层和应用层
- D1（Break-Glass 文档）和 T3/T4 可以并行，一个是流程文档，一个是技术实施

## Feature 详细分析

### T1: Docker 组权限收敛

**当前状态：** jenkins 用户已在 docker 组中（`setup-jenkins.sh` 步骤 8 完成）。需要检查是否有其他用户也在 docker 组中。

**实施步骤：**
1. 检查当前 docker 组成员：`getent group docker`
2. 移除非必要用户：`sudo gpasswd -d <username> docker`
3. 验证 `/var/run/docker.sock` 权限：`ls -la /var/run/docker.sock`（应为 `srw-rw---- root:docker`）
4. 验证 jenkins 用户仍可执行 docker 命令：`sudo -u jenkins docker ps`

**注意事项：**
- root 用户永远有 docker 权限（通过 capability 而非组），无需额外处理
- 移除用户的 docker 组权限后，该用户的现有 session 需要 `newgrp docker` 或重新登录才生效
- 如果部署脚本中使用 `sudo docker compose`，sudo 默认不保留补充组（docker）。需要确保脚本以 jenkins 用户身份运行（Pipeline 自然满足）

**Complexity: Low** -- 几条命令即可完成，核心是确认影响范围。

**Confidence: HIGH** -- Linux 组权限机制成熟稳定，已在 `setup-jenkins.sh` 中验证。

### T2: 部署脚本权限锁定

**当前状态：** `scripts/deploy/deploy-apps-prod.sh` 和 `scripts/deploy/deploy-infrastructure-prod.sh` 的权限和属主未特殊配置，任何用户可读取执行。

**实施步骤：**
1. 更改属主：`sudo chown jenkins:jenkins scripts/deploy/deploy-*.sh`
2. 限制权限：`sudo chmod 700 scripts/deploy/deploy-*.sh`（仅 jenkins 可读写执行）
3. 验证：`ls -la scripts/deploy/deploy-*.sh`（应为 `-rwx------ jenkins jenkins`）
4. 更新 `CLAUDE.md` 文档：紧急部署需要 `sudo -u jenkins bash scripts/deploy/...`

**紧急场景流程（Break-Glass）：**
```bash
# 1. 记录访问原因
echo "$(date -Iseconds) $(whoami) EMERGENCY_DEPLOY [原因]" >> /var/log/noda/break-glass.log

# 2. 切换到 jenkins 用户执行
sudo -u jenkins bash scripts/deploy/deploy-apps-prod.sh
```

**Complexity: Low** -- 文件权限操作，两个文件。

**Confidence: HIGH** -- 标准 Unix 文件权限。

### T3: 操作系统级 Docker 命令审计（auditd）

**技术选择：** Linux auditd 是内核级审计框架，无需额外安装（Ubuntu 默认包含）。与 syslog 或自定义脚本相比，auditd 的优势是：
- 内核级监控，无法被用户空间程序绕过
- 结构化日志，支持 `ausearch` 精确查询
- 独立于被审计对象（即使 docker daemon 被操控，auditd 日志仍在）

**实施步骤：**
1. 确认 auditd 安装并运行：`sudo systemctl status auditd`
2. 添加 Docker socket 监控规则：
   ```
   # /etc/audit/rules.d/docker.rules
   -w /var/run/docker.sock -p rwxa -k docker_access
   ```
3. 加载规则：`sudo augenrules --load`
4. 验证：执行一次 `docker ps`，然后 `sudo ausearch -k docker_access -ts recent`
5. 配置日志轮转（D3）

**日志内容示例：**
```
type=SYSCALL msg=audit(2026-04-17 12:00:00.123) : arch=x86_64 syscall=connect success=yes
  auid=1000 uid=1000 gid=998 ses=1
  comm="docker" exe="/usr/bin/docker"
  key="docker_access"
```
- `auid`：实际用户 ID（即使通过 sudo 也能追踪到原始用户）
- `uid/gid`：执行时的用户/组
- `comm/exe`：执行的命令和路径

**注意：** auditd 监控的是文件系统级别的 read/write/execute/attribute-change 事件。对于 Unix socket（docker.sock），主要捕获的是 connect 操作。这意味着每次有人执行 `docker` 命令（连接 docker.sock）都会被记录。

**磁盘影响：** 每次 docker 命令约 500 字节日志。按每天 50 次 docker 命令估算，约 25KB/天，可忽略。

**Complexity: Med** -- auditd 本身简单，但规则配置和日志查询需要理解 auditd 格式。

**Confidence: HIGH** -- Linux auditd 是成熟稳定的内核子系统。Docker 官方安全文档推荐使用 auditd 监控 Docker 相关文件。

**来源：** [Docker Engine Security](https://docs.docker.com/engine/security/) -- Docker 官方文档确认 auditd 作为推荐的安全监控方式。

### T4: Jenkins Pipeline 操作审计

**插件选择：** Audit Trail 插件（ID: `audit-trail`，版本 436.vc0d1e79fc5a_3）

**记录的事件：**
- Job 创建、配置、删除
- 构建触发（谁触发的、触发原因）
- 构建开始和结束
- 凭据使用
- Groovy 脚本执行（Script Console 是高风险入口）

**配置方案：** File logger（滚动文件）
- 日志路径：`/var/lib/jenkins/logs/audit/audit-%g.log`
- 文件数量：5 个轮转文件
- 文件大小：10MB 每文件
- 格式：`<timestamp> <user> <action> <uri>`

**与 auditd 的关系：**
- auditd 记录 "谁在操作系统层执行了 docker 命令"
- Audit Trail 记录 "谁在 Jenkins 中触发了部署 Pipeline、用了什么参数"
- 两者互补：正常路径通过 Jenkins Audit Trail 追踪，绕过路径通过 auditd 发现

**安装：** 在 Jenkins Plugin Manager 中安装，或通过 `setup-jenkins-pipeline.sh` 自动安装。

**Complexity: Med** -- 插件安装简单，但 URI pattern 配置需要根据实际需求调整默认值。

**Confidence: HIGH** -- 基于 Jenkins 官方插件文档验证。

**来源：** [Jenkins Audit Trail Plugin](https://plugins.jenkins.io/audit-trail/) -- 官方插件文档。

### T5: Jenkins 权限矩阵细化

**插件选择：** Matrix Authorization Strategy 插件（ID: `matrix-auth`，版本 3.2.9，91.0% 安装率）

**当前状态：** Jenkins 使用默认的 "Logged-in users can do anything" 策略。这意味着任何能登录 Jenkins 的用户都可以触发任何 Job、修改任何配置。

**目标权限模型：**

| 权限 | admin 用户 | 普通用户 | 匿名 |
|------|-----------|---------|-------|
| Overall/Administer | Yes | No | No |
| Overall/Read | Yes | Yes | No |
| Job/Read | Yes | Yes | No |
| Job/Build | Yes | Yes（仅限触发） | No |
| Job/Configure | Yes | No | No |
| Job/Delete | Yes | No | No |
| Credentials/View | Yes | No | No |
| Script Console | Yes | No | No |

**关键设计决策：**
- 普通用户可以触发部署（Job/Build），但不能修改 Job 配置（Job/Configure）
- Script Console 仅限管理员 -- 这是最危险的入口，可以执行任意 Groovy 代码
- 匿名用户完全禁止访问 -- 没有任何公开的 Jenkins 信息

**与 Authorize Project 插件的关系：** 当前项目不需要 Authorize Project。该插件用于控制 "构建以什么身份运行"，我们的 Pipeline 以 jenkins 系统用户身份运行 shell 命令，不需要用户级别的权限切换。

**Complexity: Med** -- 权限矩阵需要仔细配置，但 Matrix Auth UI 直观。

**Confidence: HIGH** -- Matrix Authorization Strategy 是 Jenkins 最广泛使用的权限插件（91% 安装率）。

**来源：** [Jenkins Matrix Authorization Plugin](https://plugins.jenkins.io/matrix-auth/) -- 官方插件文档。

### D1: 紧急访问（Break-Glass）机制文档化

**场景：**
- Jenkins 服务器宕机，无法通过 UI 触发部署
- Pipeline 执行中 Jenkins 崩溃，需要手动完成或回滚
- 网络问题导致无法访问 Jenkins UI
- 紧急安全修复需要在 5 分钟内部署

**Break-Glass 流程：**
1. 确认 Jenkins 不可用（尝试 `curl http://localhost:8888`）
2. 通过 SSH 登录服务器
3. 执行 Break-Glass wrapper 脚本：
   ```bash
   sudo bash scripts/deploy/break-glass-deploy.sh [apps|infra] "紧急原因描述"
   ```
4. wrapper 脚本自动记录日志并切换到 jenkins 用户执行实际部署
5. 事后在 Incident Log 中记录完整事件

**为什么不引入更复杂的方案：**
- 项目只有 1-2 个管理员
- 部署频率低（周级别）
- Jenkins 不可用是极小概率事件（宿主机原生安装，不是容器）
- sudo + 文件日志 + auditd 已提供足够的审计追踪

**Complexity: Low** -- 主要是文档 + 一个简单的 wrapper 脚本。

**Confidence: HIGH** -- sudo 切换用户 + 日志记录是标准的 Linux 管理模式。

### D2: 部署脚本 Break-Glass Wrapper

**脚本功能：**
```bash
#!/bin/bash
# break-glass-deploy.sh
# 用法：sudo bash scripts/deploy/break-glass-deploy.sh [apps|infra] "原因"
LOG_FILE="/var/log/noda/break-glass.log"
mkdir -p "$(dirname "$LOG_FILE")"

WHO=$(whoami)
REAL_USER="${SUDO_USER:-$WHO}"
REASON="${2:-未提供原因}"
TIMESTAMP=$(date -Iseconds)

echo "${TIMESTAMP} user=${REAL_USER} action=$1 reason=\"${REASON}\"" >> "$LOG_FILE"

case "$1" in
  apps)  sudo -u jenkins bash scripts/deploy/deploy-apps-prod.sh ;;
  infra) sudo -u jenkins bash scripts/deploy/deploy-infrastructure-prod.sh ;;
  *)     echo "Usage: $0 [apps|infra] \"原因\""; exit 1 ;;
esac
```

**Complexity: Low** -- 20 行脚本。

### D3: auditd 日志轮转与保留策略

**配置：** `/etc/audit/auditd.conf`
```
max_log_file = 50          # 每个日志文件最大 50MB
num_logs = 5               # 保留 5 个轮转文件
max_log_file_action = ROTATE
space_left = 75            # 磁盘剩余 75MB 时告警
space_left_action = SYSLOG
```

**估算：** 50MB * 5 = 250MB 最大磁盘占用。按每天 25KB 增长，可保留约 200 天日志。

**持久化规则：** `/etc/audit/rules.d/docker.rules`（augenrules 会自动加载此目录下的规则）

**Complexity: Low** -- 配置文件修改。

## MVP Definition

### 第一阶段：权限收敛（v1.6 核心）

最小可行产品 -- 确保只有 Jenkins 能部署容器。

- [ ] T1: Docker 组权限收敛 -- 操作系统层强制执行
- [ ] T2: 部署脚本权限锁定 -- 文件系统层配合
- [ ] D1: Break-Glass 文档化 -- 权限收敛后必须同步提供紧急方案

### 第二阶段：审计能力（v1.6 补充）

部署可追溯性。

- [ ] T3: auditd Docker 命令审计 -- 操作系统层审计
- [ ] T4: Jenkins Audit Trail -- 应用层审计
- [ ] D3: auditd 日志轮转 -- 防止磁盘溢出

### 第三阶段：权限细化（v1.6 增强）

Jenkins 内部权限控制。

- [ ] T5: Jenkins 权限矩阵 -- 细化谁可以触发什么 Job
- [ ] D2: Break-Glass Wrapper 脚本 -- 自动化紧急访问记录

### 后续版本（v1.7+）

- [ ] D4: Jenkins H2 -> PG 迁移 -- 从 PROJECT.md Active 列表继承
- [ ] D5: 定期权限审查提醒 -- 流程成熟后制定

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| T1: Docker 组权限收敛 | HIGH | LOW | P1 |
| T2: 部署脚本权限锁定 | HIGH | LOW | P1 |
| D1: Break-Glass 文档化 | HIGH | LOW | P1 |
| T3: auditd 审计 | MEDIUM | MEDIUM | P2 |
| T4: Jenkins Audit Trail | MEDIUM | MEDIUM | P2 |
| D3: auditd 日志轮转 | LOW | LOW | P2 |
| T5: Jenkins 权限矩阵 | MEDIUM | MEDIUM | P3 |
| D2: Break-Glass Wrapper | MEDIUM | LOW | P3 |
| D4: Jenkins H2 -> PG | MEDIUM | MEDIUM | Future |
| D5: 权限审查提醒 | LOW | LOW | Future |

**Priority key:**
- P1: 权限收敛的核心，必须完成
- P2: 审计能力，应该完成
- P3: 权限细化，锦上添花
- Future: 后续版本

## 与现有架构的集成点

| 现有组件 | 集成方式 | 变更范围 |
|---------|---------|---------|
| `setup-jenkins.sh` | 步骤 8 已有 `usermod -aG docker jenkins`；需要添加 "移除其他用户" 步骤 | 小 -- 添加检查和移除逻辑 |
| `scripts/deploy/deploy-*.sh` | 文件权限修改（`chown` + `chmod`） | 极小 -- 2 个文件的权限 |
| `CLAUDE.md` | 更新紧急部署流程文档 | 小 -- 文档更新 |
| `scripts/setup-jenkins-pipeline.sh` | 添加 Audit Trail 和 Matrix Auth 插件到自动安装列表 | 小 -- 添加 2 个插件 |
| `jenkins/Jenkinsfile*` | 无需修改 -- Pipeline 逻辑不变 | 无变更 |
| `docker/docker-compose*.yml` | 无需修改 -- 容器配置不变 | 无变更 |
| `config/nginx/` | 无需修改 -- 反向代理不变 | 无变更 |

## Sources

- 项目代码库分析（HIGH confidence）：
  - `scripts/setup-jenkins.sh`（Jenkins 安装脚本，步骤 8 Docker 权限配置）
  - `scripts/setup-jenkins-pipeline.sh`（Pipeline 配置脚本，可扩展安装审计插件）
  - `scripts/deploy/deploy-apps-prod.sh`（应用部署脚本，需权限锁定）
  - `scripts/deploy/deploy-infrastructure-prod.sh`（基础设施部署脚本，需权限锁定）
  - `jenkins/Jenkinsfile`、`jenkins/Jenkinsfile.infra`（Pipeline 结构，无需修改）
  - `scripts/lib/log.sh`（日志库，Break-Glass wrapper 可复用）
- [Docker Engine Security](https://docs.docker.com/engine/security/) -- Docker 官方安全文档，确认 auditd 监控 docker.sock 的推荐方式，HIGH confidence
- [Jenkins Audit Trail Plugin](https://plugins.jenkins.io/audit-trail/) -- 版本 436.vc0d1e79fc5a_3，记录 Jenkins 操作审计日志，HIGH confidence
- [Jenkins Matrix Authorization Strategy Plugin](https://plugins.jenkins.io/matrix-auth/) -- 版本 3.2.9，91.0% 安装率，细粒度权限控制，HIGH confidence
- [Jenkins Authorize Project Plugin](https://plugins.jenkins.io/authorize-project/) -- 确认本项目不需要此插件（Pipeline 以 jenkins 系统用户运行），HIGH confidence
- Linux auditd -- 内核审计子系统，Ubuntu 默认安装，成熟稳定，HIGH confidence
- PROJECT.md -- v1.6 milestone 目标和 Active 需求列表

---
*Feature research for: Noda v1.6 Jenkins Pipeline 强制执行*
*Researched: 2026-04-17*
