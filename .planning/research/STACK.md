# Stack Research: Jenkins + Docker Blue-Green Deployment

**Domain:** CI/CD Pipeline with Zero-Downtime Docker Compose Deployment
**Researched:** 2026-04-14
**Confidence:** HIGH

## Recommended Stack

### Core: Jenkins CI/CD Server

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Jenkins LTS | 2.541.3 | CI/CD 控制器 | 最新 LTS (2026-03-18)，包含安全修复，稳定可靠 | HIGH |
| OpenJDK 21 (Eclipse Temurin) | 21.x | Jenkins 运行时 | Jenkins 官方推荐 JDK，2.541.x LTS 最低要求 Java 17+，Java 21 是当前最优选择 | HIGH |
| Jenkins Pipeline (workflow-aggregator) | 608.v67378e9d3db_1 | Pipeline 引擎 | Declarative Pipeline 语法，89.7% 安装率，Jenkins 标配 | HIGH |

### Jenkins 原生安装（宿主机）

选择在宿主机安装 Jenkins 而非 Docker 容器运行，原因如下：

1. **Docker socket 直接访问** — Jenkins 宿主机进程可以直接操作 `/var/run/docker.sock`，无需处理 Docker-in-Docker 的权限和 volume 挂载复杂性
2. **与现有架构一致** — noda-infra 项目的 Docker Compose 服务已经在宿主机运行，Jenkins 作为管理工具应与被管理对象在同一层
3. **systemd 服务管理** — 原生安装通过 systemd 管理，开机自启、日志查看、服务重启都是标准 Linux 操作
4. **无 Docker 网络隔离问题** — 避免 Jenkins 容器与 Docker Compose 服务之间的网络层复杂性

**安装方式 (Debian/Ubuntu)：**

```bash
# 前置：安装 Java 21
sudo apt update
sudo apt install fontconfig openjdk-21-jre

# 添加 Jenkins apt 源 (LTS)
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update
sudo apt install jenkins

# systemd 管理
sudo systemctl enable jenkins
sudo systemctl start jenkins
```

**Jenkins 用户配置关键点：**

Jenkins 安装后创建 `jenkins` 系统用户。此用户需要 Docker 操作权限：

```bash
# 将 jenkins 用户加入 docker 组
sudo usermod -aG docker jenkins

# 验证（重启 Jenkins 后）
sudo systemctl restart jenkins
```

### Blue-Green Deployment: Nginx Upstream 切换方案

**方案选择理由：** noda-infra 已有 Nginx 反向代理，upstream 块已定义（`findclass_backend`、`noda_site_backend`）。蓝绿部署利用 Nginx upstream 切换实现零停机，是单服务器场景下最简洁的方案。

| Component | Mechanism | Confidence |
|-----------|-----------|------------|
| Nginx upstream 切换 | 修改 upstream 块中 server 地址 + `nginx -s reload` | HIGH |
| Docker Compose 蓝绿容器 | `docker-compose.app.yml` 中定义 `findclass-ssr-blue` 和 `findclass-ssr-green` 两个服务 | HIGH |
| 健康检查网关 | 复用现有 `wait_container_healthy` 函数 + HTTP E2E curl 检查 | HIGH |

**蓝绿部署架构：**

```
                    ┌─────────────────┐
                    │   Cloudflare     │
                    │      CDN         │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  Cloudflare      │
                    │  Tunnel (noda-ops)│
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │     Nginx        │──── upstream: findclass_backend
                    │   (容器, :80)    │     切换指向 blue 或 green
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
     ┌────────▼───────┐    │    ┌─────────▼──────┐
     │ findclass-ssr   │    │    │ findclass-ssr    │
     │   (blue :3001)  │    │    │  (green :3002)  │
     └────────────────┘    │    └──────────────────┘
                           │
                    当前活跃 ←── Nginx upstream 指向
                    另一个是待部署版本
```

**实现要点：**

1. Nginx 配置使用 `include` 引入 upstream 文件（如 `/etc/nginx/conf.d/upstream-findclass.conf`）
2. Pipeline 部署脚本通过 `sed` 或 `cp` 切换 upstream 指向的端口，然后 `docker exec nginx nginx -s reload`
3. 两个容器使用不同端口（blue:3001, green:3002），但共享 `noda-network` 外部网络

### 必要的 Jenkins 插件

| Plugin | Version | Purpose | Why Needed | Confidence |
|--------|---------|---------|------------|------------|
| Pipeline (workflow-aggregator) | 608.v67378e9d3db_1 | Declarative Pipeline 引擎 | Jenkinsfile 执行，标准安装包含 | HIGH |
| Git | 最新稳定版 | SCM 集成 | 从 Git 仓库拉取代码和 Jenkinsfile | HIGH |
| Pipeline: Stage View | 最新稳定版 | Pipeline 可视化 | 阶段视图，查看每阶段状态 | HIGH |
| Credentials Binding | 最新稳定版 | 凭据管理 | 安全使用 Docker Hub 凭据、数据库密码等 | HIGH |
| Timestamper | 最新稳定版 | 构建日志时间戳 | 蓝绿部署调试时精确到秒的日志 | MEDIUM |

**不需要的插件：**

| Plugin | Why NOT Needed |
|--------|----------------|
| Docker Pipeline (docker-workflow) | 我们不需要 Jenkins 在容器内构建；Jenkins 在宿主机直接调用 `docker compose` 命令 |
| Blue Ocean | 已不再积极维护，经典 UI + Stage View 足够 |
| Kubernetes | 单服务器部署，无 K8s |
| GitHub Integration | 手动触发部署，不需要 PR hook |

### Pipeline as Code: Jenkinsfile

**语法选择：Declarative Pipeline**

选择 Declarative 而非 Scripted 的原因：
1. 语法结构清晰，`pipeline { stages { stage { steps { } } } }` 层次分明
2. 内置 `post { failure { } }` 块，天然支持回滚逻辑
3. 与 Jenkins Blue-Green 部署的阶段划分完美对应
4. 团队可读性更高，维护成本低

**Pipeline 结构（5 阶段）：**

```
Pipeline: deploy-findclass-ssr
  |
  +-- Stage 1: Checkout      — 拉取 noda-infra 仓库代码
  +-- Stage 2: Test          — lint + 单元测试（调用 noda-apps 的测试脚本）
  +-- Stage 3: Build         — docker compose build 构建新镜像
  +-- Stage 4: Deploy BG     — 蓝绿部署：启动新容器 → 健康检查 → Nginx 切换 → 停旧容器
  +-- Stage 5: Verify        — HTTP E2E 健康检查（curl class.noda.co.nz/api/health）
       |
       +-- post { failure }  — 自动回滚：切回旧 upstream + 停新容器
```

### 自动回滚机制

| 场景 | 回滚动作 | 触发条件 |
|------|---------|---------|
| 构建失败 | 不启动新容器，一切不变 | `docker compose build` 返回非零 |
| 新容器健康检查失败 | 切回旧 upstream，停新容器 | `wait_container_healthy` 超时 |
| E2E HTTP 检查失败 | 切回旧 upstream，停新容器 | curl 返回非 200 或超时 |
| 部署后人工确认回滚 | Pipeline `input` 步骤等待确认 | 手动触发 |

回滚原理与现有 `deploy-apps-prod.sh` 中的 `save_app_image_tags` / `rollback_app` 一致：
1. 部署前保存当前活跃的 blue/green 标识和镜像 digest
2. 失败时恢复 Nginx upstream 配置 + 重载 Nginx
3. 停止新启动的容器（旧容器保持运行）

### E2E 健康检查

| Check | Method | URL | Expected |
|-------|--------|-----|----------|
| 容器健康 | `docker inspect` | Docker healthcheck | `healthy` |
| HTTP API | `curl` | `http://findclass-ssr-{color}:3001/api/health` | HTTP 200 |
| 外部可达性 | `curl` | `https://class.noda.co.nz/api/health` | HTTP 200 |

**注意：** 外部可达性检查需要通过 Cloudflare Tunnel，如果 Cloudflare 本身有问题会导致误判。建议主要依赖内部检查，外部检查作为辅助参考。

## Docker Compose 变更

需要在 `docker-compose.app.yml` 中做以下结构调整：

```yaml
# 当前（单容器）:
services:
  findclass-ssr:
    container_name: findclass-ssr
    # ... 端口 3001

# 蓝绿部署（双容器，同一文件，同时只启动一个）:
services:
  findclass-ssr-blue:
    container_name: findclass-ssr-blue
    # ... 端口 3001, 标签 noda.slot=blue

  findclass-ssr-green:
    container_name: findclass-ssr-green
    # ... 端口 3002, 标签 noda.slot=green
```

**关键决策：** 不使用 Docker Compose profiles 或 extends，而是直接定义两个服务。原因：
1. `docker compose up` 可以精确指定启动哪个服务
2. 两个服务可以共存于同一网络，互不影响
3. 配置完全透明，易于调试

## Alternatives Considered

### Jenkins 安装方式

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| 宿主机 apt 安装 | Docker 容器运行 | Docker-in-Docker 需挂载 `/var/run/docker.sock`，权限模型复杂；Jenkins 容器内执行 `docker compose` 命令需要额外工具安装；网络隔离导致与 Docker Compose 服务通信困难 |
| Jenkins LTS | Jenkins Weekly | Weekly 版本更新频繁但不保证稳定性，生产环境必须用 LTS |
| | GitHub Actions | 需要公网可访问的 runner，单服务器架构不适合；且项目已有手动部署流程，迁移成本高 |
| | GitLab CI | 需要安装 GitLab 实例，资源消耗远大于 Jenkins；项目不需要 GitLab 的完整 DevOps 平台功能 |

### 蓝绿部署实现方案

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| Nginx upstream 切换 | Docker 负载均衡（两个容器同时运行） | 单服务器资源有限，两个 findclass-ssr 实例同时运行会超出内存限制（每个 512MB limit）；且应用有状态（SSR session），负载均衡可能导致不一致 |
| | 端口直接替换（停旧启新） | 存在停机窗口（旧容器停 → 新容器启动 → 健康检查通过），不符合零停机目标 |
| | Traefik 自动路由 | 需要引入新的反向代理组件，替代现有 Nginx 架构，改动范围过大 |
| | Docker Compose `scale` + Nginx 负载均衡 | 与应用架构不匹配（SSR 有状态），且单服务器资源受限 |

### CI/CD 触发方式

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| 手动触发 | Git push 自动触发 | 项目更新频率低（周级别），手动触发更可控；自动触发需要配置 webhook + Jenkins 与 GitHub 的集成，增加攻击面 |
| | 定时触发 | 无意义，代码变更不频繁 |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Jenkins Docker 容器安装 | Docker-in-Docker 权限管理复杂，与宿主机 Docker socket 交互需要特殊处理 | 宿主机 apt 原生安装 |
| Blue Ocean UI 插件 | 已停止维护，社区推荐使用经典 UI + Stage View | Pipeline Stage View |
| Jenkins Scripted Pipeline | CPS 变换导致 `NotSerializableException` 频发，调试困难 | Declarative Pipeline |
| Shared Libraries | 项目规模小（一个 Jenkinsfile），引入 Shared Libraries 是过度工程化 | 直接在 Jenkinsfile 中写所有逻辑 |
| Docker Pipeline 插件 | 设计用于 Pipeline 中运行 Docker 容器作为构建环境，不是用于管理宿主机的 Docker Compose 服务 | 直接 `sh 'docker compose ...'` 命令 |
| Jenkins Configuration as Code (JCasC) | 单服务器、单一 Jenkinsfile 场景下，JCasC 配置比手动初始化更复杂 | 手动初始化 Jenkins + 在 UI 中配置必要参数 |

## Stack Patterns by Variant

**如果服务器资源充足（8GB+ RAM）：**
- 可以考虑让两个 findclass-ssr 实例同时运行一段时间
- 在 Nginx 切换后等待 30 秒再停旧容器，确保所有长连接完成
- 默认配置即可，因为当前方案已经是最保守的

**如果需要回滚到旧版本镜像：**
- 每次部署前用 `docker image tag` 保存当前镜像为 `findclass-ssr:rollback`
- 回滚时直接 `docker compose up` 使用 rollback tag
- 不依赖 Docker registry，纯本地镜像管理

**如果需要部署其他应用（noda-site 等）：**
- 同样的蓝绿模式，定义 `noda-site-blue` 和 `noda-site-green`
- Nginx 的 `noda_site_backend` upstream 做同样的切换
- 复用 Pipeline 框架，参数化服务名

## Version Compatibility

| Component | Version | Compatible With | Notes |
|-----------|---------|-----------------|-------|
| Jenkins LTS 2.541.x | 2.541.3 | Java 17, 21, 25 | 2.555.1+ 仅支持 Java 21/25，当前选 Java 21 最安全 |
| OpenJDK 21 | 21.x | Jenkins 2.541.x | 使用 Eclipse Temurin 发行版 |
| Pipeline Plugin | 608.v67378e9d3db_1 | Jenkins 2.479.3+ | 随 LTS 一起更新即可 |
| Docker Compose | v2 (已安装) | Jenkins `sh` 步骤 | Jenkins 以 jenkins 用户执行 docker compose，需要 docker 组权限 |
| Nginx | 1.25-alpine | `nginx -s reload` | 需要从 Jenkins 通过 `docker exec` 发送 reload 信号 |

## Installation

```bash
# ============================================
# Jenkins 宿主机安装（一次性）
# ============================================

# 1. 安装 Java 21
sudo apt update
sudo apt install fontconfig openjdk-21-jre
java -version  # 确认: openjdk 21.x

# 2. 安装 Jenkins LTS
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update
sudo apt install jenkins

# 3. 配置 Jenkins 用户权限
sudo usermod -aG docker jenkins

# 4. 可选：修改 Jenkins 端口（如果 8080 与 Keycloak 冲突）
sudo systemctl edit jenkins
# 添加:
# [Service]
# Environment="JENKINS_PORT=8888"

# 5. 启动 Jenkins
sudo systemctl enable jenkins
sudo systemctl start jenkins

# 6. 获取初始密码
sudo cat /var/lib/jenkins/secrets/initialAdminPassword

# 7. 浏览器访问 http://<server-ip>:8080
#    - 安装建议插件
#    - 创建管理员用户
#    - 额外安装: Pipeline Stage View（通常已包含）

# ============================================
# Jenkins 卸载（如果需要）
# ============================================
sudo systemctl stop jenkins
sudo systemctl disable jenkins
sudo apt remove --purge jenkins
sudo rm -rf /var/lib/jenkins /var/cache/jenkins /var/log/jenkins
sudo rm /etc/apt/sources.list.d/jenkins.list
sudo rm /etc/apt/keyrings/jenkins-keyring.asc
```

## 与现有架构的集成点

| 现有组件 | 集成方式 | 变更范围 |
|---------|---------|---------|
| `docker-compose.app.yml` | 添加 blue/green 双服务定义 | 中等 — 重构 findclass-ssr 为两个服务 |
| `config/nginx/conf.d/default.conf` | upstream 改为 `include` 引用可切换文件 | 小 — 添加 upstream include |
| `scripts/lib/health.sh` | Pipeline 直接复用 `wait_container_healthy` | 无变更 |
| `deploy-apps-prod.sh` | 逻辑迁移到 Jenkinsfile，脚本保留作为回退 | 新增 Jenkinsfile，脚本不变 |
| `scripts/deploy/deploy-apps-prod.sh` | 保留作为无 Jenkins 时的手动部署入口 | 无变更 |
| `scripts/lib/log.sh` | Pipeline 中通过 `sh` 步骤调用 | 无变更 |

## Sources

- [Jenkins LTS Changelog](https://www.jenkins.io/changelog-stable/) — 确认 2.541.3 为最新 LTS (2026-03-18)，HIGH confidence
- [Jenkins Linux 安装文档](https://www.jenkins.io/doc/book/installing/linux/) — Debian/Ubuntu apt 安装步骤，HIGH confidence
- [Jenkins Java 支持策略](https://www.jenkins.io/doc/book/platform-information/support-policy-java/) — 2.541.x 支持 Java 17/21/25，HIGH confidence
- [Jenkins Pipeline 文档](https://www.jenkins.io/doc/book/pipeline/) — Declarative Pipeline 语法参考，HIGH confidence
- [Jenkins Docker Pipeline 集成](https://www.jenkins.io/doc/book/pipeline/docker/) — 确认不需要 Docker Pipeline 插件，HIGH confidence
- [Jenkins Pipeline 最佳实践](https://www.jenkins.io/doc/book/pipeline/pipeline-best-practices/) — 使用 `sh` 而非 Groovy 逻辑，HIGH confidence
- [Jenkins systemd 服务管理](https://www.jenkins.io/doc/book/system-administration/systemd-services/) — 配置 Jenkins 服务，HIGH confidence
- [Pipeline Plugin (workflow-aggregator)](https://plugins.jenkins.io/workflow-aggregator/) — 版本 608.v67378e9d3db_1，89.7% 安装率，HIGH confidence
- [Docker Pipeline Plugin (docker-workflow)](https://plugins.jenkins.io/docker-workflow/) — 确认不适合本场景，HIGH confidence
- 项目代码: `docker/docker-compose.app.yml`, `config/nginx/conf.d/default.conf`, `scripts/deploy/deploy-apps-prod.sh` — 现有架构分析

---
*Stack research for: Noda v1.4 CI/CD 零停机部署*
*Researched: 2026-04-14*
