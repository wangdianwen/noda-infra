# Feature Research: Noda v1.4 CI/CD 零停机部署

**Domain:** Jenkins CI/CD Pipeline + Docker Compose 蓝绿部署
**Researched:** 2026-04-14
**Confidence:** HIGH（基于项目代码库深度分析 + Jenkins pipeline 社区最佳实践）

---

## Feature Landscape

### Table Stakes（部署流水线必须具备）

缺少这些特性 = 部署流程不可靠、不安全、不可回退。这些是"编译失败不 down 站"承诺的基石。

| # | Feature | Why Expected | Complexity | Notes |
|---|---------|-------------|------------|-------|
| T1 | **Pipeline 阶段化（Build -> Test -> Deploy -> Verify）** | 没有 stage 划分的 pipeline 无法做阶段级失败处理和回滚，等于手动部署的脚本化复刻 | LOW | Jenkins Declarative Pipeline 原生支持 `stages`，用 `post { failure {} }` 捕获每阶段失败 |
| T2 | **镜像 Git SHA 标签** | 部署后无法追溯"线上跑的是哪个 commit" = 回滚盲目、审计断裂 | LOW | `docker build -t findclass-ssr:${GIT_COMMIT:0:12} .`，替换当前 `image: findclass-ssr:latest` |
| T3 | **构建失败阻止部署** | 当前 `deploy-apps-prod.sh` 先 build 再 up，build 失败脚本退出但无结构化记录 | LOW | Jenkins 天然支持：`sh 'docker compose build'` 失败 → stage 失败 → pipeline 中止 |
| T4 | **HTTP 健康检查验证** | 当前只做 Docker 容器级健康检查（`wget localhost:3001/api/health`），不验证外部可达性 | MEDIUM | 需要 curl 通过 nginx 访问 `http://localhost/health`（或 Cloudflare 外部 URL），验证完整链路 |
| T5 | **自动回滚** | 当前 `deploy-apps-prod.sh` 有 `rollback_app()` 但仅保存镜像 digest，回滚需要 compose override | MEDIUM | 蓝绿模式下回滚更简单：不切换流量即可，旧容器仍在运行 |
| T6 | **部署前数据库备份** | 当前 `deploy-infrastructure-prod.sh` 有 `check_recent_backup()` 逻辑，应用部署也应继承 | LOW | 直接复用 `scripts/lib/health.sh` 中的备份检查逻辑 |
| T7 | **Jenkins 宿主机原生安装/卸载脚本** | Jenkins 是新组件，必须有干净的安装和完全卸载能力，不留残留 | LOW | apt/brew install + systemd/launchd 管理，JENKINS_HOME 独立目录 |

### Differentiators（提升部署安全性和开发体验）

这些不是必须的，但能显著降低部署风险、提升团队信心。

| # | Feature | Value Proposition | Complexity | Notes |
|---|---------|-------------------|------------|-------|
| D1 | **蓝绿部署（零停机切换）** | 当前部署是 `--force-recreate`：先停旧容器再启新容器，存在停机窗口（30-60s SSR 冷启动）。蓝绿模式消除停机 | HIGH | 需要：双容器命名、nginx upstream 动态切换、状态文件追踪活跃环境。这是 v1.4 的核心价值 |
| D2 | **Lint + 单元测试门禁** | 编译错误在构建阶段就暴露，不进入部署流程 | MEDIUM | noda-apps 仓库集成 eslint/prettier + vitest，pipeline 中 `sh 'pnpm lint && pnpm test'` |
| D3 | **Pipeline 构建产物归档** | 失败时保留构建日志、容器日志，便于事后分析 | LOW | Jenkins `archiveArtifacts` + `docker compose logs` 捕获 |
| D4 | **手动触发 + 参数化** | 不做自动 CI 触发（单服务器不需要），支持 `BUILD_ID` 参数指定构建版本 | LOW | Jenkins `parameters { string(name: 'BUILD_ID') }` 或 `pipelineTriggers` 手动触发 |
| D5 | **部署通知（成功/失败）** | 部署结果主动通知，不需要手动检查 Jenkins UI | MEDIUM | 可集成邮件/Slack/Discord webhook。初始版本可用 Jenkins 内置邮件通知 |
| D6 | **Cloudflare CDN 缓存清除** | 部署后静态资源 hash 变了但 index.html 被 CDN 缓存，用户看到旧版本 | MEDIUM | Cloudflare API `POST /zones/{id}/purge_cache`，需要 CF API Token |

### Anti-Features（明确不做的特性）

这些看起来合理，但在单服务器 Docker Compose 环境下是过度设计或会引入不必要复杂度。

| # | Anti-Feature | Why Requested | Why Problematic | Alternative |
|---|-------------|--------------|-----------------|-------------|
| A1 | **Jenkins 容器化部署** | "所有东西都该在 Docker 里" | Jenkins 需要 `docker.sock` 访问来管理其他容器，容器化后 Docker-in-Docker 安全风险大；项目只有一台服务器，Jenkins 直接操作宿主机 Docker 最简单 | 宿主机原生安装 Jenkins，直接访问 `/var/run/docker.sock` |
| A2 | **多节点 Agent 分布式构建** | "Jenkins 最佳实践是 controller/agent 分离" | 只有一台服务器，分 controller/agent 增加网络配置复杂度，无性能收益 | 单节点 `agent any`，所有构建在 Jenkins 所在服务器执行 |
| A3 | **自动 Git push/webhook 触发部署** | "代码推送自动部署" | 单服务器生产环境，自动部署风险高于手动触发。代码 push 后可能需要协调数据库迁移、配置变更 | 手动触发 Jenkins Job，保留人工审批环节 |
| A4 | **Kubernetes 编排** | "生产就该用 K8s" | 项目只有 7 个容器，K8s 引入 etcd、control plane、RBAC 等复杂度，运维成本 10x | Docker Compose + blue-green nginx 切换，足够可靠 |
| A5 | **Canary 发布 / 金丝雀部署** | "渐进式发布更安全" | 单服务器无法分流百分比流量，需要负载均衡器支持。蓝绿部署已经提供"全量验证再切换"的安全保障 | 蓝绿部署：新版本 100% 验证通过后再切换 |
| A6 | **镜像仓库（Docker Registry）** | "构建镜像应该推到 registry" | 单服务器场景，镜像构建和使用在同一台机器，`docker build` 的本地镜像即可。自建 registry 增加存储和维护负担 | 本地镜像 + Git SHA 标签追踪，`docker images` 管理 |
| A7 | **蓝绿切换用外部 KV 存储（Consul/etcd）** | "状态文件不可靠" | 引入新分布式组件只为存一个 active_color 状态，过度设计 | 文件 `/opt/noda/active-env` 追踪活跃环境，简单可靠，Jenkins 重启不影响 |

---

## Feature Dependencies

```
[T1: Pipeline 阶段化]
    └──required-by──> [T5: 自动回滚]（回滚需要 post-failure hook）
    └──required-by──> [T4: HTTP 健康检查]（检查是独立 stage）
    └──required-by──> [T3: 构建失败阻止部署]（阶段划分天然阻止）

[T2: 镜像 Git SHA 标签]
    └──required-by──> [D1: 蓝绿部署]（蓝绿需要区分新旧镜像版本）
    └──required-by──> [T5: 自动回滚]（回滚需要知道回滚到哪个镜像）

[T7: Jenkins 安装脚本]
    └──required-by──> [所有其他特性]（Jenkins 是所有 pipeline 的基础）

[D1: 蓝绿部署]
    ├──requires──> [T2: 镜像 Git SHA 标签]（区分新旧版本）
    ├──requires──> [T4: HTTP 健康检查]（切换前验证新环境）
    ├──requires──> [T5: 自动回滚]（验证失败不切换 = 自动保留旧环境）
    └──requires──> [Nginx upstream 切换机制]（流量切换基础设施）

[D2: Lint + 测试门禁]
    └──requires──> [T1: Pipeline 阶段化]（lint/test 是独立 stage）
    └──requires──> [noda-apps 仓库测试配置]（前置条件）

[D6: CDN 缓存清除]
    └──requires──> [T1: Pipeline 阶段化]（部署后 stage 执行清除）
    └──requires──> [Cloudflare API Token]（凭证配置）

[A3: 自动触发] ──conflicts──> [D4: 手动触发]（互斥选择，选手动）
```

### Dependency Notes

- **T1 (Pipeline 阶段化) 是所有其他特性的基础：** Jenkins Declarative Pipeline 的 `stages` + `post` 是其他特性挂载的骨架。没有它，回滚、健康检查、测试门禁都无法结构化实现。
- **T2 (Git SHA 标签) 是蓝绿部署的前提：** 蓝绿需要明确区分"新镜像"和"旧镜像"。当前 `findclass-ssr:latest` 标签无法区分版本。SHA 标签让 `findclass-ssr:abc1234` 和 `findclass-ssr:def5678` 共存。
- **D1 (蓝绿) 依赖链最长：** 需要 T2 + T4 + T5 + nginx 改造。这意味着蓝绿是最后实现的特性。
- **T7 (Jenkins 安装) 必须最先完成：** 没有 Jenkins 实例，所有 pipeline 特性无法开发和测试。

---

## MVP Definition

### Launch With（v1.4）

最小可行 CI/CD -- 手动触发、构建验证、零停机部署、自动回滚。

- [ ] **T7: Jenkins 宿主机安装/卸载脚本** -- 没有 Jenkins 就没有 pipeline
- [ ] **T1: Pipeline 阶段化** -- Build -> Test -> Deploy -> Verify 四阶段骨架
- [ ] **T2: 镜像 Git SHA 标签** -- 版本可追溯，蓝绿的基础
- [ ] **T3: 构建失败阻止部署** -- Jenkins 天然支持，`sh` 失败即中止
- [ ] **T6: 部署前数据库备份** -- 复用现有备份逻辑
- [ ] **D1: 蓝绿部署** -- v1.4 核心价值，零停机切换
- [ ] **T4: HTTP 健康检查** -- 蓝绿切换前的验证门槛
- [ ] **T5: 自动回滚** -- 蓝绿模式下等于"不切换流量"，最简实现

### Add After Validation（v1.4.x）

核心 pipeline 稳定后追加的增强。

- [ ] **D2: Lint + 单元测试门禁** -- 需要 noda-apps 仓库配合配置测试框架
- [ ] **D3: 构建产物归档** -- Jenkins `archiveArtifacts` + 失败时容器日志
- [ ] **D4: 参数化构建** -- 支持指定 BUILD_ID 或分支名
- [ ] **D6: Cloudflare CDN 缓存清除** -- 需要配置 CF API Token

### Future Consideration（v2+）

有明确需求时再考虑。

- [ ] **D5: 部署通知** -- 多人协作时才有价值，当前单人维护不需要
- [ ] **多环境 pipeline（dev/staging/prod）** -- 当前 dev 环境是按需手动启动
- [ ] **Pipeline as Code（Jenkinsfile in noda-apps repo）** -- 需要 noda-apps 仓库配置 Jenkins 多分支 pipeline
- [ ] **基础设施服务的蓝绿部署** -- PostgreSQL/Keycloak 有状态，蓝绿复杂度远高于无状态应用

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority | Rationale |
|---------|-----------|---------------------|----------|-----------|
| T7: Jenkins 安装 | HIGH | LOW | P1 | 所有 pipeline 的基础，必须最先完成 |
| T1: Pipeline 阶段化 | HIGH | LOW | P1 | Jenkins Declarative Pipeline 骨架，成本极低 |
| T2: Git SHA 标签 | HIGH | LOW | P1 | 一行 Dockerfile/build 参数变更 |
| T3: 构建失败阻止部署 | HIGH | LOW | P1 | Jenkins 天然支持，无需额外代码 |
| T6: 部署前备份 | MEDIUM | LOW | P1 | 复用现有脚本，成本极低 |
| D1: 蓝绿部署 | HIGH | HIGH | P1 | 核心价值但复杂度高，需要 nginx 改造 + 双容器管理 |
| T4: HTTP 健康检查 | HIGH | MEDIUM | P1 | 蓝绿的前提条件，需要设计检查策略 |
| T5: 自动回滚 | HIGH | MEDIUM | P1 | 蓝绿模式下"不切换"即回滚，但仍需结构化实现 |
| D2: Lint + 测试 | MEDIUM | MEDIUM | P2 | 需要 noda-apps 仓库配合，依赖外部仓库变更 |
| D3: 产物归档 | MEDIUM | LOW | P2 | Jenkins 内置功能，配置即可 |
| D4: 参数化构建 | LOW | LOW | P2 | Jenkins `parameters` 块，简单但非紧急 |
| D6: CDN 缓存清除 | MEDIUM | MEDIUM | P2 | 需要额外 API Token 配置和 Cloudflare API 集成 |
| D5: 部署通知 | LOW | MEDIUM | P3 | 单人维护场景价值低 |

---

## Competitor Feature Analysis

对比同类单服务器 Docker 部署方案的特征覆盖。

| Feature | 通用 Jenkins Pipeline | GitHub Actions self-hosted | CapRover / Dokku | Noda 方案 |
|---------|----------------------|--------------------------|-------------------|-----------|
| 蓝绿部署 | 需自行实现 | 需自行实现 | 内置（但黑盒） | 自行实现，基于 nginx upstream 切换 |
| 自动回滚 | `post { failure }` | `if: failure()` | 有但不可控 | `post { failure }` + 保留旧容器 |
| 健康检查 | 自行脚本 | 自行脚本 | 内置 | HTTP E2E curl 检查 |
| 零停机 | 需自行实现 | 需自行实现 | 内置 | nginx upstream reload（毫秒级切换） |
| 版本追溯 | Git tag + image tag | Git SHA | Git deploy | Git SHA 镜像标签 |
| 基础设施管理 | 无（只管应用） | 无 | 无 | 复用现有部署脚本 |
| 复杂度 | 中（需写 Jenkinsfile） | 低（YAML） | 低（平台抽象） | 中（透明可控） |

**选择 Jenkins 的理由：** 项目已有 bash 部署脚本和 Docker Compose 基础设施管理，Jenkins 是最小侵入的选择 -- 把现有脚本包装进 pipeline stages，而不是重写整个部署流程。GitHub Actions 需要自托管 runner（等于另一个 Jenkins），CapRover/Dokku 要求迁移到它们的抽象层（放弃现有 Docker Compose 配置）。

---

## 蓝绿部署架构详细分析

### 当前部署模式（有停机）

```
deploy-apps-prod.sh 执行流程:
  1. 验证基础设施
  2. 保存当前镜像 digest
  3. docker compose build findclass-ssr
  4. docker compose up -d --force-recreate findclass-ssr  ← 停机点！
     - 停止旧容器 -> 启动新容器 -> 等待健康检查（60s start_period）
  5. 健康检查通过 / 失败回滚
```

**停机窗口：** `--force-recreate` 导致旧容器停止后、新容器健康前，nginx upstream 中 findclass-ssr 不可达。用户看到 502 错误页。

### 蓝绿部署模式（零停机）

```
新部署流程:
  1. 读取活跃环境状态文件: /opt/noda/active-env (内容: "blue" 或 "green")
  2. 确定目标环境: 如果活跃是 blue，目标是 green，反之亦然
  3. 构建镜像: docker build -t findclass-ssr:{SHA} .
  4. 启动目标容器: docker run --name findclass-ssr-green -p 3002:3001 findclass-ssr:{SHA}
  5. 等待目标容器健康: 检查 localhost:3002/api/health
  6. HTTP E2E 验证: curl http://localhost:3002/ 完整页面响应
  7. 切换 nginx upstream: 将 findclass_backend 指向 green:3001
  8. nginx -s reload (graceful, 毫秒级)
  9. 更新状态文件: echo "green" > /opt/noda/active-env
  10. 停止旧容器: docker stop findclass-ssr-blue

  失败时（步骤 5-6 失败）:
  - 不执行步骤 7-10
  - 删除失败的 green 容器
  - blue 容器持续运行，用户无感知
```

### Nginx 切换机制

**当前 nginx 配置（需要改造）：**
```nginx
upstream findclass_backend {
    server findclass-ssr:3001 max_fails=3 fail_timeout=30s;
}
```

**蓝绿模式需要：**
```nginx
# 方案 A: include 文件切换（推荐）
# nginx/conf.d/default.conf
upstream findclass_backend {
    include /etc/nginx/conf.d/findclass-upstream.conf;
}

# findclass-upstream.conf (由 pipeline 更新)
server findclass-ssr-green:3001 max_fails=3 fail_timeout=30s;
```

**方案 A 选择理由：** `include` 文件 + `nginx -s reload` 是最简单可靠的方式。不需要引入 Consul Template、lua-nginx-module 或 Traefik 等新依赖。

### Docker Compose 蓝绿适配

**关键决策：蓝绿容器不通过 docker-compose.yml 管理**

理由：
1. docker-compose.yml 的 `container_name: findclass-ssr` 是唯一的，无法同时运行两个同名容器
2. 蓝绿需要两个容器共存（findclass-ssr-blue + findclass-ssr-green），compose 不天然支持
3. Jenkins pipeline 直接用 `docker run` 启动目标容器，绕过 compose 的命名限制

**compose 文件的角色变化：**
- docker-compose.app.yml 中的 `findclass-ssr` 服务定义变为"初始部署"和"回退参考"
- 蓝绿部署由 Jenkins pipeline 直接管理容器生命周期
- compose 仍用于 `build` 阶段的镜像构建

### 端口分配

| 容器 | 内部端口 | 宿主机端口 | 备注 |
|------|---------|-----------|------|
| findclass-ssr-blue | 3001 | 3001（Docker 网络） | Docker 内部网络访问，不映射到宿主机 |
| findclass-ssr-green | 3001 | 3002（Docker 网络） | Docker 内部网络访问，不映射到宿主机 |
| nginx | 80 | 80 | 通过 Docker 内部网络访问 blue:3001 或 green:3001 |

**注意：** blue 和 green 容器都在 `noda-network` 上。nginx 通过 Docker DNS 解析 `findclass-ssr-blue` 和 `findclass-ssr-green` 服务名。端口 3001 是容器内部端口，两个容器各自独立。

---

## Health Check 策略

### 两层健康检查

| 层 | 检查方式 | 目的 | 失败后果 |
|----|---------|------|---------|
| L1: 容器级 | Docker healthcheck（已在 compose 中配置） | 确认容器进程健康 | 容器标记为 unhealthy |
| L2: HTTP E2E | curl 通过 nginx 访问外部 URL | 确认完整请求链路可达 | 阻止流量切换 |

### L2 E2E 检查详细设计

```bash
# 检查新容器直接可达（绕过 nginx）
curl -sf http://localhost:3001/api/health -o /dev/null

# 检查新容器通过 nginx 可达（如果 nginx 已切换）
# 注意：蓝绿模式下，切换前 nginx 指向旧容器
# 所以 E2E 检查分两步：

# Step 1: 直接检查新容器健康
curl -sf http://findclass-ssr-green:3001/api/health

# Step 2: 切换后验证（nginx reload 后）
# 等待 2 秒让 nginx worker 完成切换
sleep 2
curl -sf http://localhost/health -H "Host: class.noda.co.nz"
```

**重试策略：** 最多重试 10 次，每次间隔 5 秒，总超时 50 秒。覆盖 findclass-ssr 的 60 秒 `start_period`。

---

## Pipeline Stage 详细设计

```groovy
pipeline {
    agent any

    environment {
        GIT_SHA = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
        ACTIVE_ENV = sh(script: 'cat /opt/noda/active-env 2>/dev/null || echo blue', returnStdout: true).trim()
        TARGET_ENV = "${env.ACTIVE_ENV == 'blue' ? 'green' : 'blue'}"
    }

    stages {
        stage('Pre-flight') {
            steps {
                // 验证基础设施服务健康
                sh 'bash scripts/verify/verify-infrastructure.sh'
                // 验证数据库备份足够新
                sh 'bash scripts/lib/backup-check.sh'
            }
        }

        stage('Build') {
            steps {
                // 构建镜像，打 Git SHA 标签
                sh "docker build -t findclass-ssr:${GIT_SHA} -f deploy/Dockerfile.findclass-ssr ../noda-apps"
            }
        }

        stage('Test') {
            steps {
                // 未来: lint + 单元测试
                // sh 'docker run --rm findclass-ssr:${GIT_SHA} pnpm test'
                echo 'Test stage placeholder (v1.4.x: add lint + unit test)'
            }
        }

        stage('Deploy Target') {
            steps {
                // 启动目标环境容器（不影响活跃环境）
                sh """
                    docker run -d \
                        --name findclass-ssr-${TARGET_ENV} \
                        --network noda-network \
                        -e NODE_ENV=production \
                        -e DATABASE_URL=... \
                        findclass-ssr:${GIT_SHA}
                """
            }
        }

        stage('Health Check') {
            steps {
                // 等待目标容器健康
                sh """
                    for i in \$(seq 1 10); do
                        if curl -sf http://findclass-ssr-${TARGET_ENV}:3001/api/health; then
                            echo "Target healthy"
                            exit 0
                        fi
                        sleep 5
                    done
                    echo "Health check failed"
                    exit 1
                """
            }
        }

        stage('Switch Traffic') {
            steps {
                // 更新 nginx upstream 指向目标容器
                sh """
                    echo 'server findclass-ssr-${TARGET_ENV}:3001 max_fails=3 fail_timeout=30s;' \
                        > /opt/noda/findclass-upstream.conf
                    docker exec noda-infra-nginx nginx -s reload
                """
                // 更新活跃环境状态
                sh "echo ${TARGET_ENV} > /opt/noda/active-env"
            }
        }

        stage('Post-switch Verify') {
            steps {
                // 切换后 E2E 验证
                sh 'curl -sf http://localhost/health -H "Host: class.noda.co.nz"'
            }
        }

        stage('Cleanup Old') {
            steps {
                // 停止并移除旧容器
                sh "docker stop findclass-ssr-${ACTIVE_ENV} || true"
                sh "docker rm findclass-ssr-${ACTIVE_ENV} || true"
                // 清理旧镜像
                sh 'docker image prune -f --filter "until=168h"'
            }
        }
    }

    post {
        failure {
            // 清理失败的目标容器（活跃环境未受影响）
            sh "docker rm -f findclass-ssr-${TARGET_ENV} || true"
            // 捕获日志
            sh "docker logs findclass-ssr-${TARGET_ENV} > deployment-failure.log 2>&1 || true"
            archiveArtifacts artifacts: 'deployment-failure.log', allowEmptyArchive: true
        }
        success {
            echo "Deployment successful: ${TARGET_ENV} is now active (image: ${GIT_SHA})"
        }
    }
}
```

---

## 现有脚本迁移映射

| 现有脚本步骤 | Jenkins Pipeline Stage | 变更 |
|------------|----------------------|------|
| `verify-infrastructure.sh` | Pre-flight | 无变更，直接调用 |
| `save_app_image_tags()` | Pre-flight | 蓝绿模式下不需要，旧容器保留直到切换成功 |
| `docker compose build` | Build | 改为 `docker build -t findclass-ssr:${SHA}` |
| `docker compose up --force-recreate` | Deploy Target | 改为 `docker run` 启动目标环境容器 |
| `wait_container_healthy()` | Health Check | 改为直接 curl 目标容器 |
| 无 | Switch Traffic（新增） | nginx upstream 切换 + reload |
| 无 | Post-switch Verify（新增） | 通过 nginx 验证完整链路 |
| 无 | Cleanup Old（新增） | 停止旧容器 |
| `rollback_app()` | post { failure } | 蓝绿模式：删除失败容器即可，无需 compose overlay |

---

## Sources

- 项目代码库：`scripts/deploy/deploy-apps-prod.sh`（当前部署流程）
- 项目代码库：`scripts/deploy/deploy-infrastructure-prod.sh`（基础设施部署流程，回滚逻辑参考）
- 项目代码库：`scripts/lib/health.sh`（健康检查工具函数）
- 项目代码库：`docker/docker-compose.app.yml`（应用服务定义）
- 项目代码库：`config/nginx/conf.d/default.conf`（nginx 反向代理配置，upstream 定义）
- Jenkins Declarative Pipeline 官方文档：`stages`、`post`、`environment` 语法
- Jenkins Docker Pipeline 插件：`docker.build()`、`docker.withServer()` API
- Docker Compose v2：`docker compose` CLI（项目已使用）
- Nginx upstream 切换：`include` 指令 + `nginx -s reload` graceful reload
- 蓝绿部署模式：Nginx blog "Blue-Green Deployments" 社区实践

---
*Feature research for: Noda v1.4 CI/CD 零停机部署*
*Researched: 2026-04-14*
