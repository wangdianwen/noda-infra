# Phase 23: Pipeline 集成与测试门禁 - Research

**Researched:** 2026-04-15
**Domain:** Jenkins Declarative Pipeline + 蓝绿部署集成 + 质量门禁
**Confidence:** HIGH

## Summary

Phase 23 的核心任务是创建 Jenkinsfile（8 阶段 Declarative Pipeline）并配置 Jenkins 作业从 SCM 读取它。研究确认所有前置依赖（Phase 19 Jenkins 安装、Phase 21 容器管理脚本、Phase 22 蓝绿部署脚本）已在代码库中就绪，函数接口清晰可复用。

关键发现：(1) Jenkins "Pipeline script from SCM" 模式是最干净的方案，Jenkinsfile 放在 noda-infra 仓库的 `jenkins/Jenkinsfile` 路径，Phase 19 的 `03-pipeline-job.groovy` 需要更新为引用该路径；(2) 8 阶段中每个阶段可直接调用 `blue-green-deploy.sh` 中已存在的函数（`http_health_check`, `e2e_verify`, `cleanup_old_images`）和 `manage-containers.sh` 中的函数（`run_container`, `update_upstream`, `reload_nginx`）；(3) lint/test 阶段需要在 Jenkins 宿主机安装 Node.js + pnpm，这是唯一的宿主机前置依赖。

**Primary recommendation:** 创建 `jenkins/Jenkinsfile` 使用 Declarative Pipeline 语法，通过 `dir()` 步骤在 workspace 中分别 checkout noda-infra 和 noda-apps 两个仓库，每个阶段用 `sh` 调用已有的 bash 函数。同时更新 `03-pipeline-job.groovy` 从占位 script 改为 "Pipeline script from SCM" 模式。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Jenkinsfile 放在 noda-infra 仓库（路径 `jenkins/Jenkinsfile`），通过更新 Phase 19 的 `03-pipeline-job.groovy` 引用
- **D-02:** Jenkinsfile 使用 Declarative Pipeline 语法（非 Scripted）
- **D-03:** 8 阶段细粒度拆分：Pre-flight -> Build -> Test -> Deploy -> Health Check -> Switch -> Verify -> Cleanup
- **D-04:** 每阶段调用独立脚本或函数，不一次性调用 `blue-green-deploy.sh`
- **D-05:** Jenkins Stage View 展示每阶段通过/失败状态
- **D-06:** Jenkins 通过 Git SCM 插件配置 noda-apps 仓库，使用 SSH key 或 PAT 认证
- **D-07:** Pipeline 从 noda-infra checkout Jenkinsfile，再 checkout noda-apps 到子目录
- **D-08:** Git 凭据存储在 Jenkins Credentials 中，通过 `credentials()` 引用
- **D-09:** lint/test 直接在 Jenkins workspace 中执行（`pnpm lint` 和 `pnpm test`），需安装 Node.js + pnpm
- **D-10:** lint/test 在 noda-apps 源码目录执行，复用已有 `package.json` scripts
- **D-11:** lint 或 test 不通过则 Pipeline 中止（TEST-01, TEST-02）
- **D-12:** 仅部署失败时归档日志，成功时不归档
- **D-13:** 归档内容包括构建日志 + 失败容器 docker logs
- **D-14:** 使用 Jenkins `archiveArtifacts` 归档日志文件

### Claude's Discretion
- Jenkinsfile 各阶段具体调用哪些脚本/函数
- noda-apps 仓库的具体 Git URL 和分支配置
- Node.js/pnpm 在 Jenkins 宿主机的安装方式
- 日志归档的文件名格式和保留策略

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PIPE-01 | Pipeline 按 8 阶段执行 | Jenkins Declarative Pipeline `stages` 块原生支持多阶段，每阶段可独立调用 bash 函数 |
| PIPE-04 | Pipeline 手动触发，不支持自动触发 | Jenkins 作业不配置 `triggers`，默认仅通过 "Build Now" 手动触发 |
| PIPE-05 | 部署失败时自动归档构建日志和容器日志 | `post { failure {} }` 块中 `sh 'docker logs ... > file'` + `archiveArtifacts` |
| TEST-01 | Test 阶段执行 `pnpm lint`，不通过则中止 | Test stage 中 `sh 'cd noda-apps && pnpm lint'`，非零退出码自动中止 Pipeline |
| TEST-02 | Test 阶段执行 `pnpm test`，不通过则中止 | Test stage 中 `sh 'cd noda-apps && pnpm test'`，紧接 lint 之后 |
</phase_requirements>

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|-------------|---------|---------|--------------|
| Jenkins LTS | 2.541.3 | CI/CD 控制器 | Phase 19 已安装，宿主机原生运行 [VERIFIED: Phase 19 CONTEXT.md] |
| Declarative Pipeline | workflow-aggregator 608.v | Pipeline 语法引擎 | Phase 19 已安装插件 [VERIFIED: 02-plugins.groovy] |
| Git Plugin | 已安装 | SCM checkout | Phase 19 已安装 [VERIFIED: 02-plugins.groovy] |
| Credentials Binding | 已安装 | 安全引用凭据 | Phase 19 已安装 [VERIFIED: 02-plugins.groovy] |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| Node.js 21+ | pnpm lint/test 执行环境 | Test 阶段执行 `pnpm lint && pnpm test` |
| pnpm 10+ | 包管理器，安装依赖和执行脚本 | `pnpm install && pnpm lint && pnpm test` |
| Timestamper Plugin | 构建日志时间戳 | Phase 19 已安装，自动生效 [VERIFIED: 02-plugins.groovy] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Jenkinsfile in noda-infra repo | Jenkinsfile in noda-apps repo | noda-infra 是基础设施仓库，Jenkinsfile 与部署脚本同仓库更一致；noda-apps 仓库是应用代码，放 Jenkinsfile 混合了关注点 [ASSUMED] |
| `withCredentials` 绑定凭据 | `credentials()` in checkout | checkout 步骤的 `credentialsId` 参数直接引用 Jenkins Credentials 中的 SSH key，不需要 withCredentials 包装 [CITED: jenkins.io/doc/pipeline/steps/credentials-binding/] |
| Docker 内执行 lint/test | 宿主机直接执行 | D-09 已锁定为宿主机执行，避免在容器内安装 Node.js 的额外复杂度 [VERIFIED: CONTEXT.md D-09] |

**Installation:**
```bash
# Jenkins 宿主机需要安装 Node.js + pnpm（如果尚未安装）
# 方式 1：手动安装
curl -fsSL https://deb.nodesource.com/setup_21.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pnpm

# 方式 2：通过 Jenkins tools 配置自动安装（在 Jenkinsfile 中声明）
# 推荐方式 1，因为 D-09 要求宿主机直接执行
```

**Version verification:** Node.js 和 pnpm 版本在 Jenkins 宿主机上验证，本地开发环境已有 Node.js v24.12.0 和 pnpm 10.29.3。

## Architecture Patterns

### Recommended Project Structure
```
noda-infra/
+-- jenkins/
|   +-- Jenkinsfile                    # Phase 23 新增：8 阶段 Declarative Pipeline
|   +-- init.groovy.d/
|   |   +-- 03-pipeline-job.groovy     # Phase 23 修改：从占位 script 改为 SCM 引用
+-- scripts/
|   +-- blue-green-deploy.sh           # Phase 22 产出，函数被 Jenkinsfile 调用
|   +-- manage-containers.sh           # Phase 21 产出，函数被 Jenkinsfile 调用
|   +-- rollback-findclass.sh          # Phase 22 产出，紧急回滚用
|   +-- lib/
|   |   +-- log.sh                     # 日志库
|   |   +-- health.sh                  # 健康检查库
```

### Pattern 1: Pipeline Script from SCM
**What:** Jenkins 作业从 Git 仓库读取 Jenkinsfile，而非在作业配置中内联 Pipeline script
**When to use:** Jenkinsfile 存储在代码仓库中，需要版本控制
**Example:**
```groovy
// 03-pipeline-job.groovy 更新后的 configXml
def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Noda Apps 蓝绿部署 Pipeline</description>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>NODA_INFRA_REPO_URL</url>
          <credentialsId>noda-infra-git-credentials</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
    </scm>
    <scriptPath>jenkins/Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>'''
```
[CITED: jenkins.io/doc/book/pipeline/getting-started/#defining-a-pipeline-in-scm]

### Pattern 2: Multi-Repo Checkout with dir()
**What:** Jenkinsfile 在一个仓库，应用代码在另一个仓库，通过 `dir()` 步骤分别 checkout
**When to use:** Pipeline 配置和构建目标在不同 Git 仓库
**Example:**
```groovy
pipeline {
    agent any
    stages {
        stage('Pre-flight') {
            steps {
                // Jenkinsfile 所在仓库已自动 checkout（SCM 配置）
                // 额外 checkout noda-apps 到子目录
                dir('noda-apps') {
                    checkout([
                        $class: 'GitSCM',
                        branches: [[name: '*/main']],
                        userRemoteConfigs: [[
                            url: 'git@github.com:user/noda-apps.git',
                            credentialsId: 'noda-apps-git-credentials'
                        ]]
                    ])
                }
            }
        }
    }
}
```
[CITED: jenkins.io/doc/book/pipeline/jenkinsfile/ — checkout step 文档]

### Pattern 3: Source Bash Functions in Jenkinsfile
**What:** Jenkinsfile 通过 `sh` 步骤 source bash 函数库，调用已有函数
**When to use:** 复用 Phase 21/22 已创建的 bash 函数，避免重写逻辑
**Example:**
```groovy
stage('Deploy') {
    steps {
        sh '''
            source scripts/lib/log.sh
            source scripts/manage-containers.sh
            # 调用 manage-containers.sh 中的函数
            TARGET_ENV=$(get_inactive_env)
            run_container "$TARGET_ENV" "findclass-ssr:${GIT_SHA}"
        '''
    }
}
```
[VERIFIED: scripts/manage-containers.sh 中的函数可被 source 调用]

### Pattern 4: Failure Archival with post Block
**What:** 使用 `post { failure {} }` 在部署失败时捕获容器日志
**When to use:** PIPE-05 要求失败时归档日志
**Example:**
```groovy
post {
    failure {
        script {
            sh "docker logs findclass-ssr-${env.TARGET_ENV} > deploy-failure-container.log 2>&1 || true"
            // 捕获 nginx 错误日志
            sh "docker logs noda-infra-nginx > deploy-failure-nginx.log 2>&1 || true"
        }
        archiveArtifacts artifacts: 'deploy-failure-*.log', allowEmptyArchive: true
    }
}
```
[CITED: jenkins.io/doc/pipeline/steps/workflow-basic-steps/ — archiveArtifacts 步骤]

### Anti-Patterns to Avoid
- **在 Jenkinsfile 中写复杂 Groovy 逻辑:** Declarative Pipeline 中应避免 `@NonCPS`、复杂循环、try-catch。所有复杂逻辑放在 bash 脚本中，Jenkinsfile 只做 `sh` 调用 [CITED: jenkins.io/doc/book/pipeline/pipeline-best-practices/]
- **双引号字符串中暴露密钥:** 使用单引号 `sh '...'` 防止 Groovy 插值暴露环境变量中的密钥 [CITED: jenkins.io/doc/pipeline/steps/credentials-binding/ — 安全注意事项]
- **在 environment 块中调用 shell 命令获取动态值:** `environment { TARGET_ENV = sh(...) }` 在 Declarative Pipeline 中可用但可读性差，推荐在需要时用 `script` 块 [ASSUMED]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Git 凭据管理 | 自定义 SSH key 管理逻辑 | Jenkins Credentials + `credentialsId` | Jenkins 内置凭据管理支持 SSH key、PAT、用户名密码，自动遮蔽日志中的密钥 [CITED: jenkins.io/doc/pipeline/steps/credentials-binding/] |
| 构建日志归档 | 自定义日志文件管理 | `archiveArtifacts` + Jenkins 内置构建历史 | Jenkins 内置 artifact 管理，支持保留策略、按构建号索引 [CITED: jenkins.io/doc/pipeline/steps/workflow-basic-steps/] |
| 容器健康检查 | 新写健康检查逻辑 | `blue-green-deploy.sh` 中的 `http_health_check()` | Phase 22 已实现，经过测试，参数灵活 [VERIFIED: scripts/blue-green-deploy.sh:36-61] |
| E2E 验证 | 新写 E2E 验证逻辑 | `blue-green-deploy.sh` 中的 `e2e_verify()` | Phase 22 已实现，处理了 nginx 容器无 curl 的降级方案 [VERIFIED: scripts/blue-green-deploy.sh:72-123] |
| 容器启动 | 新写 docker run 命令 | `manage-containers.sh` 中的 `run_container()` | Phase 21 已实现，包含完整的资源限制、健康检查、安全配置 [VERIFIED: scripts/manage-containers.sh:117-158] |

**Key insight:** Phase 21/22 已创建了所有需要的 bash 函数。Jenkinsfile 的核心价值是把它们组装成 8 阶段 Pipeline，而不是重写任何逻辑。

## Common Pitfalls

### Pitfall 1: Jenkinsfile 中 environment 块的执行时机
**What goes wrong:** `environment { GIT_SHA = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim() }` 在全局 environment 块中执行时，当前目录是 Jenkins workspace 根（noda-infra），不是 noda-apps。如果 workspace 尚未 checkout，`git` 命令会失败。
**Why it happens:** Declarative Pipeline 的 `environment` 块在 agent 分配后、stages 执行前求值。
**How to avoid:** 在 Pre-flight stage 中 checkout 两个仓库后再获取 GIT_SHA，或者使用 `script` 块延迟求值。
**Warning signs:** `fatal: not a git repository` 错误出现在 Pipeline 日志开头。

### Pitfall 2: dir() 步骤的路径持久性
**What goes wrong:** `dir('noda-apps') { checkout ... }` 只在该块内切换目录。后续 stage 中需要 `dir('noda-apps')` 再次进入。
**Why it happens:** 每个 `sh` 步骤都在 workspace 根执行，`dir()` 作用域仅限其块内。
**How to avoid:** 每个需要 noda-apps 代码的 stage 都用 `dir('noda-apps') { ... }`，或者在 `sh` 命令中用 `cd noda-apps && ...`。
**Warning signs:** `pnpm: command not found` 或 `package.json not found` 错误。

### Pitfall 3: 03-pipeline-job.groovy 更新与幂等性冲突
**What goes wrong:** `03-pipeline-job.groovy` 中有幂等检查 `if (instance.getItem(jobName) != null) { return }`。如果 Jenkins 已创建占位作业，更新 groovy 脚本后重新执行不会更新作业配置。
**Why it happens:** Phase 19 的 groovy 脚本设计为首次创建时执行一次，之后幂等跳过。
**How to avoid:** 更新 `03-pipeline-job.groovy` 时需要：要么（a）先删除旧作业再重新创建，要么（b）修改 groovy 脚本为"更新模式"（检查并更新 configXml），要么（c）直接在 Jenkins UI 中手动更新作业配置指向 SCM Jenkinsfile。推荐（c）因为 Phase 19 的 init.groovy.d 是一次性执行的。
**Warning signs:** 修改了 groovy 文件但 Jenkins 作业仍是旧的 placeholder。

### Pitfall 4: pnpm lint/test 的退出码传播
**What goes wrong:** `sh 'cd noda-apps && pnpm install && pnpm lint && pnpm test'` 如果 pnpm lint 失败，因为 `set -e` 隐式生效，pnpm test 不会执行，但 Jenkins 可能只显示整个 sh 步骤失败，不区分是 lint 还是 test 失败。
**Why it happens:** 多命令串联时，Jenkins 只记录第一个失败命令的退出码。
**How to avoid:** 将 lint 和 test 拆分为两个独立的 `sh` 步骤（在同一个 stage 中），这样 Jenkins Stage View 会清楚显示哪个步骤失败。
**Warning signs:** Stage View 显示 "Test" stage 失败但无法区分 lint 还是 test。

### Pitfall 5: post failure 块中 TARGET_ENV 变量可能未定义
**What goes wrong:** 如果 Pipeline 在设置 TARGET_ENV 之前就失败（比如 Pre-flight 阶段），`post { failure {} }` 中的 `docker logs findclass-ssr-${env.TARGET_ENV}` 会展开为 `docker logs findclass-ssr-null`。
**Why it happens:** `environment` 块中的变量可能在失败时尚未求值。
**How to avoid:** 在 post failure 块中用 `|| true` 防止 docker logs 失败导致二次错误，并检查变量是否已设置。
**Warning signs:** `docker logs` 报错 "No such container: findclass-ssr-null"。

### Pitfall 6: Jenkins workspace 残留影响下次构建
**What goes wrong:** 如果上次构建失败留下 `noda-apps/` 目录，下次构建的 checkout 可能冲突。
**Why it happens:** Jenkins workspace 默认不会被自动清理。
**How to avoid:** 使用 `options { skipDefaultCheckout() }` + 手动 checkout 控制精确行为，或在 Pre-flight 阶段添加 `cleanWs()` 清理上次残留。
**Warning signs:** 构建使用了旧代码而非最新代码。

## Code Examples

### Jenkinsfile 骨架结构（8 阶段）

```groovy
// Source: 综合自 Jenkins 官方文档 + 项目 CONTEXT.md 决策
#!/usr/bin/env groovy

pipeline {
    agent any

    environment {
        // 注意：这些变量在 agent 分配后、checkout 前求值
        // GIT_SHA 需要在 checkout 后获取，因此在 stages 中用 script 块
        PROJECT_ROOT = "${WORKSPACE}"
        ACTIVE_ENV = sh(
            script: 'cat /opt/noda/active-env 2>/dev/null || echo blue',
            returnStdout: true
        ).trim()
        TARGET_ENV = "${env.ACTIVE_ENV == 'blue' ? 'green' : 'blue'}"
    }

    options {
        // 禁止并发构建，防止两个 Pipeline 同时操作蓝绿容器
        disableConcurrentBuilds()
        // 构建日志保留策略
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timestamps()
    }

    stages {
        stage('Pre-flight') {
            steps {
                // workspace 已从 noda-infra checkout（SCM 配置）
                // 额外 checkout noda-apps
                dir('noda-apps') {
                    checkout([
                        $class: 'GitSCM',
                        branches: [[name: '*/main']],
                        userRemoteConfigs: [[
                            url: 'NODA_APPS_REPO_URL',
                            credentialsId: 'noda-apps-git-credentials'
                        ]]
                    ])
                }
                // 获取 noda-apps 的 Git SHA
                script {
                    env.GIT_SHA = sh(
                        script: 'git -C noda-apps rev-parse --short HEAD',
                        returnStdout: true
                    ).trim()
                }
                // 前置检查
                sh '''
                    docker info >/dev/null 2>&1 || { echo "Docker daemon 不可用"; exit 1; }
                    source scripts/lib/log.sh
                    source scripts/manage-containers.sh
                    if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
                        echo "ERROR: nginx 容器未运行"
                        exit 1
                    fi
                    docker network inspect noda-network >/dev/null 2>&1 || {
                        echo "ERROR: Docker 网络 noda-network 不存在"
                        exit 1
                    }
                '''
            }
        }

        stage('Build') {
            steps {
                sh """
                    docker compose -f docker/docker-compose.app.yml build findclass-ssr
                    docker tag findclass-ssr:latest "findclass-ssr:${GIT_SHA}"
                    echo "镜像构建完成: findclass-ssr:${GIT_SHA}"
                """
            }
        }

        stage('Test') {
            steps {
                dir('noda-apps') {
                    sh 'pnpm install --frozen-lockfile'
                    sh 'pnpm lint'
                    sh 'pnpm test'
                }
            }
        }

        stage('Deploy') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/manage-containers.sh

                    TARGET_CONTAINER=$(get_container_name "$TARGET_ENV")

                    # 停止旧目标容器（如果存在）
                    if [ "$(is_container_running "$TARGET_CONTAINER")" = "true" ]; then
                        docker stop -t 30 "$TARGET_CONTAINER"
                        docker rm "$TARGET_CONTAINER"
                    fi

                    # 启动新目标容器
                    run_container "$TARGET_ENV" "findclass-ssr:${GIT_SHA}"
                '''
            }
        }

        stage('Health Check') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/blue-green-deploy.sh 2>/dev/null || true
                    # source blue-green-deploy.sh 不会执行 main()，只加载函数

                    TARGET_CONTAINER="findclass-ssr-${TARGET_ENV}"
                    http_health_check "$TARGET_CONTAINER" 30 4
                '''
            }
        }

        stage('Switch') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/manage-containers.sh

                    update_upstream "$TARGET_ENV"

                    if ! docker exec "$NGINX_CONTAINER" nginx -t; then
                        echo "ERROR: nginx 配置验证失败"
                        update_upstream "$ACTIVE_ENV"
                        exit 1
                    fi

                    reload_nginx
                    set_active_env "$TARGET_ENV"
                '''
            }
        }

        stage('Verify') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/blue-green-deploy.sh 2>/dev/null || true
                    e2e_verify "$TARGET_ENV" 5 2
                '''
            }
        }

        stage('Cleanup') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/blue-green-deploy.sh 2>/dev/null || true
                    cleanup_old_images 5
                '''
            }
        }
    }

    post {
        failure {
            script {
                // 捕获目标容器日志（如果存在）
                sh "docker logs findclass-ssr-${env.TARGET_ENV} > deploy-failure-container.log 2>&1 || true"
                // 捕获 nginx 日志
                sh 'docker logs noda-infra-nginx --tail 50 > deploy-failure-nginx.log 2>&1 || true'
                // 清理失败的目标容器
                sh "docker rm -f findclass-ssr-${env.TARGET_ENV} 2>/dev/null || true"
            }
            archiveArtifacts artifacts: 'deploy-failure-*.log', allowEmptyArchive: true
        }
        success {
            echo "部署成功: ${env.TARGET_ENV} 现在是活跃环境 (镜像: findclass-ssr:${env.GIT_SHA})"
        }
    }
}
```
[CITED: jenkins.io/doc/book/pipeline/syntax/ — Declarative Pipeline 结构; VERIFIED: 项目代码库 scripts/]

### 03-pipeline-job.groovy 更新为 SCM 模式

```groovy
// 关键变更：CpsFlowDefinition（内联 script）-> CpsScmFlowDefinition（从 SCM 读取）
// 需要将 definition class 从 CpsFlowDefinition 改为 CpsScmFlowDefinition
// Script Path 设置为 jenkins/Jenkinsfile
// 需要配置 noda-infra 仓库的 Git URL 和凭据

// 注意：幂等性问题 — 如果作业已存在（Phase 19 创建的占位作业），需要先删除再重新创建
// 或者使用 instance.getItem(jobName).updateByXml(newXml) 更新配置
```
[CITED: jenkins.io/doc/book/pipeline/getting-started/#defining-a-pipeline-in-scm]

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|-------------|-----------------|--------------|--------|
| Jenkins 内联 Pipeline script | Pipeline script from SCM | Jenkins 2.x+ | Jenkinsfile 版本控制，代码审查 |
| Scripted Pipeline | Declarative Pipeline | Pipeline plugin 2.5+ | 更简洁的语法，更好的 IDE 支持 |
| Freestyle Job 链 | 单个 Pipeline 多 stage | Pipeline plugin | 原子化执行，统一视图 |

**Deprecated/outdated:**
- Blue Ocean UI 插件：已停止维护，使用经典 UI + Stage View [ASSUMED]
- Shared Libraries：单 Jenkinsfile 场景下过度工程化，直接在 Jenkinsfile 中写逻辑 [VERIFIED: CONTEXT.md CLAUDE.md]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | noda-apps 仓库已有 `pnpm lint` 和 `pnpm test` 脚本在 `package.json` 中 | Test 阶段 | 需要先在 noda-apps 中配置 lint/test，否则 Test 阶段会失败 |
| A2 | noda-apps 仓库的 Git URL 使用 SSH 或 HTTPS 格式 | Pre-flight | 需要确认实际 URL 和认证方式 |
| A3 | `blue-green-deploy.sh` 的 main() 函数在 source 时不会自动执行 | Deploy/Health Check | 需要确认 `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` 保护是否足够 |
| A4 | Jenkins 宿主机已安装或可以安装 Node.js + pnpm | Test 阶段 | 如果宿主机无法安装，Test 阶段无法执行 |
| A5 | noda-infra 仓库是私有的，需要凭据 checkout | 03-pipeline-job.groovy | 如果是公开仓库，可能不需要凭据 |
| A6 | E2E 验证失败时应执行回滚（切换回旧环境），但 CONTEXT.md 中未明确 | Verify 阶段 | 需要确认是否在 Jenkinsfile 的 Verify stage 中包含回滚逻辑 |

## Open Questions (RESOLVED)

1. **noda-apps 仓库的 `package.json` 是否已有 lint 和 test 脚本？**
   - What we know: CONTEXT.md D-10 说"复用 noda-apps 已有的 `package.json` scripts"
   - What's unclear: noda-apps 仓库不在当前代码库中，无法验证
   - Recommendation: Plan 中假设已有，但在 Pre-flight 阶段添加检查 `grep -q '"lint"' noda-apps/package.json`
   - RESOLVED: Plan 23-02 Task 1 在 pipeline_preflight() 中添加了 package.json lint/test 脚本检查

2. **03-pipeline-job.groovy 的更新策略？**
   - What we know: Phase 19 创建了占位作业，幂等检查会跳过已存在的作业
   - What's unclear: 更新 groovy 脚本后如何让 Jenkins 重新应用配置
   - Recommendation: 在 Plan 23-01 中明确说明——更新 groovy 脚本后需手动操作（删除旧作业 + 重启 Jenkins），或在 groovy 中改为"更新模式"
   - RESOLVED: Plan 23-01 Task 2 使用 updateByXml 策略更新已存在作业的配置

3. **Verify 阶段失败后是否需要回滚？**
   - What we know: Phase 22 的 `blue-green-deploy.sh` main() 中 E2E 失败后自动回滚
   - What's unclear: Jenkinsfile 的 Verify stage 中 `e2e_verify()` 失败后，是在 stage 内回滚还是在 `post { failure }` 中回滚
   - Recommendation: 在 Verify stage 内用 `catchError` 或 `when` 处理回滚逻辑，因为回滚需要知道当前活跃环境
   - RESOLVED: Verify 失败后 Pipeline 进入 post failure 块，pipeline_failure_cleanup 清理失败容器；流量未切换所以无需回滚

4. **Node.js/pnpm 安装方式？**
   - What we know: D-09 锁定宿主机安装，Claude's Discretion 决定安装方式
   - What's unclear: 宿主机是否已有 Node.js
   - RESOLVED: Plan 23-02 Task 1 在 pipeline_preflight() 中添加了 Node.js/pnpm 可用性检查，未安装时输出明确的安装指引
   - Recommendation: Plan 中添加一个检查步骤，如果未安装则报错提示手动安装

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Jenkins LTS | Pipeline 执行 | 需 Phase 19 已执行 | 2.541.3 | -- |
| Docker | Build/Deploy/Cleanup 阶段 | 需宿主机确认 | -- | -- |
| Node.js + pnpm | Test 阶段 | 需宿主机确认 | -- | 可跳过 Test 阶段（降级） |
| Git | SCM checkout | Jenkins 自带 | -- | -- |
| nginx 容器 | Switch/Verify 阶段 | 需基础设施运行 | -- | -- |
| noda-network | Deploy 阶段 | 需基础设施运行 | -- | -- |

**Missing dependencies with no fallback:**
- Jenkins 实例必须已安装并运行（Phase 19 前置条件）
- Docker daemon 必须运行
- 基础设施服务（nginx、PostgreSQL、noda-network）必须运行

**Missing dependencies with fallback:**
- Node.js + pnpm：如果未安装，Test 阶段会失败。可考虑在 Jenkinsfile 中添加 `tools { nodejs 'NodeJS-21' }` 配合 Jenkins 全局工具配置自动安装

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | 手动验证 + Jenkins Pipeline 执行验证 |
| Config file | 无独立测试框架，通过 Jenkins 构建验证 |
| Quick run command | `jenkins/Jenkinsfile` 语法检查：无（Jenkins 内部验证） |
| Full suite command | 手动触发 Jenkins 构建 + 验证 8 阶段执行结果 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PIPE-01 | 8 阶段 Pipeline 执行 | manual | Jenkins 手动触发构建 | N/A |
| PIPE-04 | 手动触发（无自动触发） | manual | 检查 Jenkins 作业配置无 triggers | N/A |
| PIPE-05 | 失败时日志归档 | manual | 模拟失败构建，检查归档文件 | N/A |
| TEST-01 | pnpm lint 阻止部署 | manual | 模拟 lint 失败，验证 Pipeline 中止 | N/A |
| TEST-02 | pnpm test 阻止部署 | manual | 模拟 test 失败，验证 Pipeline 中止 | N/A |

### Sampling Rate
- **Per task commit:** 无自动化测试，手动检查 Jenkinsfile 语法
- **Per wave merge:** 手动触发 Jenkins 构建验证
- **Phase gate:** 全部 5 个需求在 Jenkins 环境中手动验证通过

### Wave 0 Gaps
- Jenkinsfile 语法验证需要 Jenkins 实例运行（本地无 Jenkins）
- Plan 23-01 完成后需要访问 Jenkins UI 验证作业配置
- Plan 23-02 完成后需要实际触发构建验证全流程
- 建议在验证阶段使用 `blue-green-deploy.sh status` 检查容器状态

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Jenkins 管理员认证（Phase 19 已配置 HudsonPrivateSecurityRealm） |
| V3 Session Management | yes | Jenkins 内置会话管理 + CSRF 保护（Phase 19 已配置） |
| V4 Access Control | yes | Jenkins FullControlOnceLoggedInAuthorizationStrategy（Phase 19） |
| V5 Input Validation | yes | Jenkinsfile 中避免 Groovy 插值注入，使用单引号字符串 |
| V6 Cryptography | no | Pipeline 不处理加密操作 |

### Known Threat Patterns for Jenkins + Docker

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 凭据泄露（日志中打印密钥） | Information Disclosure | Jenkins Credentials 自动遮蔽 + 使用单引号 `sh` 命令 |
| Docker socket 权限滥用 | Elevation of Privilege | jenkins 用户仅加入 docker 组，不使用 root |
| Pipeline 注入（Groovy 代码注入） | Tampering | Declarative Pipeline 限制 Groovy 灵活性 + sandbox |
| workspace 残留敏感信息 | Information Disclosure | `cleanWs()` 清理 + `disableConcurrentBuilds()` |

## Sources

### Primary (HIGH confidence)
- [Jenkins Pipeline 官方文档](https://www.jenkins.io/doc/book/pipeline/) — Declarative Pipeline 语法、结构、概念
- [Jenkins Pipeline Syntax 参考](https://www.jenkins.io/doc/book/pipeline/syntax/) — environment、post、stages、options、parameters 指令详解
- [Jenkins Getting Started: Pipeline in SCM](https://www.jenkins.io/doc/book/pipeline/getting-started/#defining-a-pipeline-in-scm) — CpsScmFlowDefinition 配置
- [Jenkins Credentials Binding Plugin](https://www.jenkins.io/doc/pipeline/steps/credentials-binding/) — withCredentials、credentialsId 使用
- 项目代码库: `scripts/blue-green-deploy.sh`, `scripts/manage-containers.sh`, `scripts/jenkins/init.groovy.d/03-pipeline-job.groovy` — 所有已有函数和接口

### Secondary (MEDIUM confidence)
- `.planning/research/FEATURES.md` — Pipeline 8 阶段设计草稿、蓝绿架构分析
- `.planning/phases/19-jenkins/19-CONTEXT.md` — Jenkins 端口 8888、Pipeline 作业名 noda-apps-deploy
- `.planning/phases/22-blue-green-deploy/22-CONTEXT.md` — 部署脚本接口、健康检查策略
- `.planning/phases/21-blue-green-containers/21-CONTEXT.md` — manage-containers.sh 函数接口

### Tertiary (LOW confidence)
- noda-apps 仓库的 `package.json` 是否已有 lint/test 脚本 [ASSUMED]
- Jenkins 宿主机是否已安装 Node.js + pnpm [ASSUMED]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有依赖在项目代码库中已验证，Jenkins 插件 Phase 19 已安装
- Architecture: HIGH — Jenkins Declarative Pipeline 模式成熟，与已有 bash 函数集成点清晰
- Pitfalls: HIGH — 基于 Jenkins 官方文档和项目实际代码分析，常见陷阱有明确规避方案
- Test/lint 集成: MEDIUM — noda-apps 仓库的 package.json 配置未在当前代码库中验证

**Research date:** 2026-04-15
**Valid until:** 2026-05-15（Jenkins Pipeline 语法稳定，30 天内不会有大变化）
