# Phase 29: 统一基础设施 Jenkins Pipeline - Research

**Researched:** 2026-04-17
**Domain:** Jenkins Declarative Pipeline 参数化 + 基础设施服务部署策略
**Confidence:** HIGH

## Summary

本阶段创建统一的 Jenkinsfile.infra，通过 `parameters { choice }` 选择目标基础设施服务（keycloak/nginx/noda-ops/postgres），每种服务使用独立的部署策略。核心工作是：(1) 创建 Jenkinsfile.infra 统一入口，(2) 在 pipeline-stages.sh 中新增 4 个服务的部署/健康检查/回滚函数，(3) 集成 pg_dump 自动备份，(4) 同步更新 deploy-infrastructure-prod.sh。

现有代码库已有完整的蓝绿部署框架（manage-containers.sh + pipeline-stages.sh + keycloak-blue-green-deploy.sh），基础设施 Pipeline 的主要工作是新增 nginx/noda-ops/postgres 三个服务的部署函数，而非重写已有逻辑。

**Primary recommendation:** 新增函数到 pipeline-stages.sh，Jenkinsfile.infra 使用 `when` 条件化阶段执行，Keycloak 复用 keycloak-blue-green-deploy.sh 脚本，nginx/noda-ops 使用 docker compose recreate，postgres 使用 compose restart + 人工确认。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 创建单一 Jenkinsfile.infra，使用 Jenkins `parameters { choice }` 选择目标服务（keycloak/nginx/noda-ops/postgres）
- **D-02:** Jenkinsfile.infra 的 Keycloak 部署复用 keycloak-blue-green-deploy.sh
- **D-03:** Nginx 使用 docker compose recreate 模式（秒级中断，非零停机）
- **D-04:** noda-ops 使用 docker compose recreate 模式
- **D-05:** Postgres 使用 compose restart + 备份恢复模式，人工确认门禁
- **D-06:** 部署 postgres/keycloak 前自动执行 pg_dump，备份路径 BACKUP_HOST_DIR/infra-pipeline/{service}/{timestamp}.sql.gz
- **D-07:** 每个服务使用专属健康检查函数
- **D-08:** 服务专属回滚策略（keycloak=切回旧容器，postgres=pg_restore，nginx/noda-ops=旧镜像标签）
- **D-09:** Postgres restart 前强制人工确认（30 分钟超时自动中止）
- **D-10:** 更新 deploy-infrastructure-prod.sh，移除已被 Pipeline 覆盖的 nginx/noda-ops

### Claude's Discretion
- Jenkinsfile.infra 具体阶段名称和参数定义细节
- 备份文件命名规则（timestamp 格式）
- 回滚超时时间和健康检查重试参数
- 备份文件清理策略
- compose 文件路径（base + prod overlay）

### Deferred Ideas (OUT OF SCOPE)
- Postgres 蓝绿部署
- Keycloak 版本升级
- 自动触发 Pipeline
- Pipeline 并发控制（infra-deploy 与 findclass-deploy 互斥）
- 邮件通知
- 部署历史记录
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PIPELINE-01 | 创建 Jenkinsfile.infra，通过 Jenkins choice 参数选择目标服务 | Jenkins `parameters { choice }` 语法，现有 Jenkinsfile/Jenkinsfile.keycloak 参考结构 |
| PIPELINE-02 | pipeline-stages.sh 新增基础设施服务专用部署函数 | 现有 pipeline_deploy/pipeline_health_check 函数模式，4 个服务各自策略 |
| PIPELINE-03 | 每个服务使用独立部署策略 | D-02~D-05 锁定策略：keycloak=蓝绿、nginx=recreate、noda-ops=recreate、postgres=restart |
| PIPELINE-04 | 部署前自动执行 pg_dump 全量备份 | docker exec postgres pg_dump 模式，BACKUP_HOST_DIR 路径，备份验证 |
| PIPELINE-05 | 部署后自动执行健康检查 | 4 种健康检查：pg_isready / HTTP /health/ready / nginx -t + curl / docker ps |
| PIPELINE-06 | 健康检查失败自动回滚 | 4 种回滚：keycloak=蓝绿切回 / postgres=pg_restore / nginx/noda-ops=旧镜像 recreate |
| PIPELINE-07 | 关键操作前 Jenkins input 步骤 | Postgres restart 前 input 门禁，30 分钟超时 |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Jenkins Declarative Pipeline | Jenkins LTS 2.541.x | Pipeline 定义语法 | 项目已使用，3 个 Jenkinsfile 已建立模式 [VERIFIED: codebase] |
| Jenkins `parameters { choice }` | Jenkins 内置 | 服务选择下拉菜单 | Declarative Pipeline 标准参数类型 [CITED: jenkins.io/doc] |
| Jenkins `input` step | Jenkins 内置 | 人工确认门禁 | Pipeline 标准 Step，支持 message + timeout + submitter [CITED: jenkins.io/doc] |
| `when` directive | Jenkins 内置 | 条件化阶段执行 | 根据 SERVICE 参数决定哪些阶段执行 [CITED: jenkins.io/doc] |
| docker compose | v2 | 容器管理 | 项目已使用双文件 overlay 模式 [VERIFIED: codebase] |
| bash | 4+ | 脚本函数库 | pipeline-stages.sh 已有 600+ 行 bash 函数 [VERIFIED: codebase] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `keycloak-blue-green-deploy.sh` | 现有 | Keycloak 蓝绿部署 | D-02 复用，不重写 |
| `manage-containers.sh` | 现有 | 蓝绿容器管理 | Keycloak 蓝绿容器生命周期 |
| `pipeline-stages.sh` | 现有 | Pipeline 阶段函数库 | 新增 infra 专用函数到现有文件 |
| `scripts/lib/health.sh` | 现有 | 容器健康检查 | `wait_container_healthy` 复用 |
| `scripts/lib/log.sh` | 现有 | 日志输出 | 所有新函数使用 log_info/log_error |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| 单一 Jenkinsfile.infra | 每个服务独立 Jenkinsfile | 统一 Pipeline 减少维护成本；独立 Pipeline 更灵活但 4 个文件维护负担大 |
| `when` 条件化阶段 | 脚本内 if/else 分发 | `when` 在 Stage View 显示更清晰（跳过阶段灰色标记）；脚本内分发更灵活但 Stage View 不直观 |
| docker compose recreate | docker stop + rm + run | compose 管理的容器用 compose recreate 保持配置一致；蓝绿管理的容器用 docker run |

**Installation:**
无新依赖安装。所有工具已在项目中使用。

## Architecture Patterns

### Recommended Project Structure
```
jenkins/
├── Jenkinsfile              # findclass-ssr 蓝绿 Pipeline（不变）
├── Jenkinsfile.keycloak     # Keycloak 蓝绿 Pipeline（保留参考）
├── Jenkinsfile.noda-site    # noda-site 蓝绿 Pipeline（不变）
└── Jenkinsfile.infra        # 新增：统一基础设施 Pipeline
scripts/
├── pipeline-stages.sh       # 新增：pipeline_deploy_nginx/noda_ops/postgres 等函数
├── keycloak-blue-green-deploy.sh  # Keycloak 蓝绿脚本（D-02 复用）
├── manage-containers.sh     # 蓝绿容器管理（不变）
└── deploy/deploy-infrastructure-prod.sh  # 精简：移除 nginx/noda-ops 逻辑
```

### Pattern 1: Jenkins `parameters { choice }` 服务选择
**What:** Jenkins Declarative Pipeline 的参数化构建，用户在触发时选择目标服务
**When to use:** Pipeline 需要根据不同输入执行不同逻辑
**Example:**
```groovy
// Source: Jenkins Declarative Pipeline 官方文档
pipeline {
    agent any
    parameters {
        choice(
            name: 'SERVICE',
            choices: ['keycloak', 'nginx', 'noda-ops', 'postgres'],
            description: '选择要部署的基础设施服务'
        )
    }
    stages {
        stage('Backup') {
            when {
                anyOf {
                    expression { params.SERVICE == 'keycloak' }
                    expression { params.SERVICE == 'postgres' }
                }
            }
            steps { /* ... */ }
        }
    }
}
```

### Pattern 2: `when` 条件化阶段
**What:** 使用 `when` 指令根据 SERVICE 参数决定阶段是否执行
**When to use:** 不同服务需要不同的 Pipeline 阶段
**Example:**
```groovy
// Source: Jenkins Declarative Pipeline 文档
stage('Human Approval') {
    when {
        expression { params.SERVICE == 'postgres' }
    }
    steps {
        input message: '确认重启 PostgreSQL?', ok: '确认重启', submitterParameter: 'approver'
        timeout(time: 30, unit: 'MINUTES') {
            input message: '等待确认...'
        }
    }
}
```

### Pattern 3: nginx/noda-ops Docker Compose Recreate
**What:** 使用 `docker compose up -d --force-recreate --no-deps` 重建容器
**When to use:** 无状态或可接受秒级中断的服务
**Example:**
```bash
# Source: deploy-infrastructure-prod.sh 已有模式
# 保存当前镜像标签（用于回滚）
CURRENT_IMAGE=$(docker inspect --format='{{.Image}}' noda-infra-nginx 2>/dev/null)

# Recreate 容器
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
    up -d --force-recreate --no-deps nginx

# 回滚：使用保存的镜像标签
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
    up -d --force-recreate --no-deps nginx  # 需要生成 rollback overlay
```

### Pattern 4: pg_dump Pipeline 备份
**What:** 部署前通过 docker exec 执行 pg_dump，备份到指定路径
**When to use:** 部署 keycloak 或 postgres 前自动备份
**Example:**
```bash
# Source: scripts/backup/lib/db.sh backup_database() + scripts/backup/verify-restore.sh
# 单库备份（keycloak 数据库）
docker exec noda-infra-postgres-prod pg_dump -U postgres -Fc keycloak | gzip > /path/backup.sql.gz

# 全库备份（postgres 服务重启前）
docker exec noda-infra-postgres-prod pg_dumpall -U postgres | gzip > /path/backup.sql.gz

# 备份验证
FILE_SIZE=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file")
[ "$FILE_SIZE" -gt 1024 ]  # > 1KB
```

### Anti-Patterns to Avoid
- **在 Groovy 中写部署逻辑**: Jenkins Pipeline 最佳实践是通过 `sh` 调用 bash 函数，不在 Groovy 中写复杂逻辑 [CITED: jenkins.io/doc/book/pipeline/pipeline-best-practices]
- **不保存回滚信息就执行 recreate**: 必须先保存当前镜像 digest，否则无法回滚
- **在 Pipeline 中直接 docker compose down**: 会影响所有服务，必须用 `--no-deps` 只操作目标服务
- **跳过备份直接重启 postgres**: D-06 锁定备份失败则中止部署，不可跳过

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Keycloak 蓝绿部署 | 新写蓝绿逻辑 | keycloak-blue-green-deploy.sh | 已有完整 7 步蓝绿流程，含健康检查和自动回滚 [VERIFIED: codebase] |
| 蓝绿容器管理 | 新写容器生命周期 | manage-containers.sh | 已支持参数化 SERVICE_NAME/PORT/UPSTREAM [VERIFIED: codebase] |
| 容器健康检查轮询 | 新写轮询逻辑 | wait_container_healthy() | health.sh 已有完善的状态机：running/healthy/unhealthy/starting [VERIFIED: codebase] |
| 镜像回滚 overlay | 新写回滚逻辑 | deploy-infrastructure-prod.sh rollback_images() | 已有 compose rollback overlay 生成逻辑 [VERIFIED: codebase] |
| 部署前备份 | 新写备份流程 | docker exec noda-ops /app/backup/backup-postgres.sh 或 docker exec postgres pg_dump | 已有成熟备份系统 [VERIFIED: codebase] |

**Key insight:** 项目已有 v1.0-v1.4 四个里程碑积累的脚本库，本阶段主要是"粘合"而非"建造"。

## Runtime State Inventory

> 本阶段是新增 Pipeline + 函数，不涉及重命名或迁移。以下为变更影响分析：

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | postgres_data volume 中的生产数据 | 不直接修改。pg_dump 备份只读操作，postgres restart 不影响数据卷 |
| Live service config | noda-ops 容器内的 crontab/supervisord 配置 | recreate 会重建容器，配置由 docker-compose.yml 环境变量注入，无持久化配置丢失 |
| OS-registered state | 无 | 无操作 |
| Secrets/env vars | docker/.env 中 POSTGRES_PASSWORD 等 | Pipeline 通过 docker exec 在容器内执行 pg_dump，凭据已在容器环境中 |
| Build artifacts | noda-ops:latest 镜像（compose build） | recreate 时 compose 会自动 rebuild（如 Dockerfile 有变更） |

## Common Pitfalls

### Pitfall 1: Jenkins `input` 超时未处理导致 Pipeline 挂起
**What goes wrong:** `input` 步骤默认无超时，Pipeline 会永远等待人工确认
**Why it happens:** Jenkins `input` 没有内置超时参数，需要外部 `timeout` 包裹
**How to avoid:** 必须用 `timeout(time: 30, unit: 'MINUTES') { input ... }` 包裹，超时后 Pipeline 自动中止 [CITED: jenkins.io/doc/pipeline/steps/input]
**Warning signs:** Pipeline 执行日志长时间停留在 input 步骤

### Pitfall 2: docker compose recreate 不带 `--no-deps` 影响其他服务
**What goes wrong:** `docker compose up --force-recreate nginx` 会同时重启 nginx 的 depends_on 依赖
**Why it happens:** docker compose 默认启动服务的所有依赖
**How to avoid:** 必须加 `--no-deps` 参数：`docker compose up -d --force-recreate --no-deps nginx`
**Warning signs:** recreate nginx 时 postgres 也被重启

### Pitfall 3: pg_dump 输出通过管道丢失退出码
**What goes wrong:** `docker exec postgres pg_dump | gzip > file.sql.gz` — 如果 pg_dump 失败，gzip 仍会创建空文件
**Why it happens:** bash 管道默认不检查中间命令退出码（仅检查最后一个）
**How to avoid:** 使用 `set -o pipefail`（已在脚本中设置）或使用 `docker exec postgres pg_dump -f /tmp/backup.sql` 然后 docker cp
**Warning signs:** 备份文件大小为 0 或非常小

### Pitfall 4: compose overlay 回滚时容器名不匹配
**What goes wrong:** 回滚 overlay 指定了镜像 digest，但 compose 用 service name 而非 container_name 启动
**Why it happens:** rollback_images() 生成的 overlay 只设置 `image:` 字段，container_name 由 docker-compose.yml 保持一致
**How to avoid:** 回滚 overlay 只覆盖 `image:` 字段，其他配置由 base + prod overlay 提供 [VERIFIED: deploy-infrastructure-prod.sh rollback_images()]
**Warning signs:** 回滚后容器名变了

### Pitfall 5: Keycloak 部署函数不设置环境变量直接调用 keycloak-blue-green-deploy.sh
**What goes wrong:** keycloak-blue-green-deploy.sh 需要大量环境变量（SERVICE_NAME/PORT/UPSTREAM_NAME 等），不设置会使用默认值
**Why it happens:** 脚本内部有默认值但默认是 findclass-ssr 的参数
**How to avoid:** 调用前设置完整的环境变量：SERVICE_NAME=keycloak, SERVICE_PORT=8080, UPSTREAM_NAME=keycloak_backend 等 [VERIFIED: keycloak-blue-green-deploy.sh 行 23-37]
**Warning signs:** 部署了错误的容器（findclass-ssr 而非 keycloak）

### Pitfall 6: Postgres restart 导致所有依赖服务断连
**What goes wrong:** postgres restart 期间 keycloak/findclass-ssr/noda-ops 全部断连数据库
**Why it happens:** 所有服务共享 postgres，restart 有 5-10 秒不可用窗口
**How to avoid:** (1) Pipeline 信息提示影响范围，(2) 人工确认门禁让管理员选择维护窗口，(3) D-09 已锁定 input 步骤
**Warning signs:** 健康检查阶段大量失败

## Code Examples

### Jenkinsfile.infra 骨架结构（参考现有 3 个 Jenkinsfile）

```groovy
// Source: 基于 jenkins/Jenkinsfile + Jenkinsfile.keycloak 模式
pipeline {
    agent any

    parameters {
        choice(
            name: 'SERVICE',
            choices: ['keycloak', 'nginx', 'noda-ops', 'postgres'],
            description: '选择要部署的基础设施服务'
        )
    }

    environment {
        PROJECT_ROOT = "${WORKSPACE}"
        COMPOSE_BASE = "-f docker/docker-compose.yml -f docker/docker-compose.prod.yml"
        BACKUP_HOST_DIR = "${WORKSPACE}/docker/volumes/backup"
    }

    options {
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timestamps()
    }

    stages {
        stage('Pre-flight') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/pipeline-stages.sh
                    pipeline_infra_preflight "$SERVICE"
                '''
            }
        }

        stage('Backup') {
            when {
                anyOf {
                    expression { params.SERVICE == 'keycloak' }
                    expression { params.SERVICE == 'postgres' }
                }
            }
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/pipeline-stages.sh
                    pipeline_backup_database "$SERVICE"
                '''
            }
        }

        stage('Human Approval') {
            when {
                expression { params.SERVICE == 'postgres' }
            }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: """确认重启 PostgreSQL?
                    服务: ${params.SERVICE}
                    备份状态: 请查看上方 Backup 阶段日志
                    影响范围: Keycloak、findclass-ssr、noda-ops 将短暂断连数据库
                    """.stripIndent()
                }
            }
        }

        stage('Deploy') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/pipeline-stages.sh
                    pipeline_infra_deploy "$SERVICE"
                '''
            }
        }

        stage('Health Check') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/pipeline-stages.sh
                    pipeline_infra_health_check "$SERVICE"
                '''
            }
        }

        stage('Verify') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/pipeline-stages.sh
                    pipeline_infra_verify "$SERVICE"
                '''
            }
        }

        stage('Cleanup') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/pipeline-stages.sh
                    pipeline_infra_cleanup "$SERVICE"
                '''
            }
        }
    }

    post {
        failure {
            script {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/pipeline-stages.sh
                    pipeline_infra_failure_cleanup "$SERVICE"
                '''
                archiveArtifacts artifacts: 'deploy-failure-*.log', allowEmptyArchive: true
            }
        }
        success {
            echo "基础设施服务 ${params.SERVICE} 部署成功"
        }
    }
}
```

### pipeline-stages.sh 新增函数：pipeline_backup_database

```bash
# Source: 基于 scripts/backup/lib/db.sh backup_database() 模式
# 基于 scripts/deploy/deploy-infrastructure-prod.sh run_pre_deploy_backup() 模式

# pipeline_backup_database - 部署前自动备份
# 参数: $1 = SERVICE (keycloak/postgres)
# 环境变量: BACKUP_HOST_DIR
pipeline_backup_database() {
  local service="$1"
  local backup_dir="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}/infra-pipeline/${service}"
  local timestamp=$(date +"%Y%m%d-%H%M%S")
  local backup_file="${backup_dir}/${timestamp}.sql.gz"

  mkdir -p "$backup_dir"

  log_info "部署前备份: $service -> $backup_file"

  if [ "$service" = "keycloak" ]; then
    # 备份 keycloak 数据库
    docker exec noda-infra-postgres-prod pg_dump -U postgres --clean --if-exists keycloak \
      | gzip > "$backup_file"
  elif [ "$service" = "postgres" ]; then
    # 备份所有数据库
    docker exec noda-infra-postgres-prod pg_dumpall -U postgres --clean --if-exists \
      | gzip > "$backup_file"
  else
    log_info "$service 不需要备份（无持久化数据）"
    return 0
  fi

  # 验证备份文件大小 > 1KB
  local file_size
  file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
  if [ "$file_size" -lt 1024 ]; then
    log_error "备份文件异常（${file_size} 字节），中止部署"
    return 1
  fi

  log_success "备份完成: $backup_file (${file_size} bytes)"
  # 导出备份文件路径供后续回滚使用
  INFRA_BACKUP_FILE="$backup_file"
  export INFRA_BACKUP_FILE
}
```

### pipeline-stages.sh 新增函数：pipeline_infra_deploy

```bash
# Source: 基于 scripts/deploy/deploy-infrastructure-prod.sh + keycloak-blue-green-deploy.sh

# pipeline_infra_deploy - 根据服务类型调用对应部署策略
# 参数: $1 = SERVICE
pipeline_infra_deploy() {
  local service="$1"

  case "$service" in
    keycloak)
      pipeline_deploy_keycloak
      ;;
    nginx)
      pipeline_deploy_nginx
      ;;
    noda-ops)
      pipeline_deploy_noda_ops
      ;;
    postgres)
      pipeline_deploy_postgres
      ;;
    *)
      log_error "未知服务: $service"
      return 1
      ;;
  esac
}

# pipeline_deploy_keycloak - 调用 keycloak-blue-green-deploy.sh
pipeline_deploy_keycloak() {
  log_info "Keycloak 蓝绿部署（复用 keycloak-blue-green-deploy.sh）"
  # 设置 Keycloak 专用环境变量
  export SERVICE_NAME="keycloak"
  export SERVICE_PORT="8080"
  export UPSTREAM_NAME="keycloak_backend"
  export HEALTH_PATH="/health/ready"
  export ACTIVE_ENV_FILE="/opt/noda/active-env-keycloak"
  export UPSTREAM_CONF="$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf"
  export SERVICE_GROUP="infra"
  export CONTAINER_MEMORY="1g"
  export CONTAINER_MEMORY_RESERVATION="512m"
  export CONTAINER_READONLY="false"

  bash "$PROJECT_ROOT/scripts/keycloak-blue-green-deploy.sh"
}

# pipeline_deploy_nginx - Docker Compose recreate
pipeline_deploy_nginx() {
  log_info "Nginx 重建部署（docker compose recreate）"

  # 保存当前镜像 digest（用于回滚）
  INFRA_ROLLBACK_IMAGE=$(docker inspect --format='{{.Image}}' noda-infra-nginx 2>/dev/null || echo "")
  export INFRA_ROLLBACK_IMAGE
  log_info "保存当前镜像: ${INFRA_ROLLBACK_IMAGE:0:12}..."

  docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
    up -d --force-recreate --no-deps nginx

  log_success "Nginx 重建完成"
}

# pipeline_deploy_noda_ops - Docker Compose recreate
pipeline_deploy_noda_ops() {
  log_info "noda-ops 重建部署（docker compose recreate）"

  INFRA_ROLLBACK_IMAGE=$(docker inspect --format='{{.Image}}' noda-ops 2>/dev/null || echo "")
  export INFRA_ROLLBACK_IMAGE
  log_info "保存当前镜像: ${INFRA_ROLLBACK_IMAGE:0:12}..."

  # noda-ops 需要先 build 再 up（使用 Dockerfile.noda-ops）
  docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
    build noda-ops
  docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
    up -d --force-recreate --no-deps noda-ops

  log_success "noda-ops 重建完成"
}

# pipeline_deploy_postgres - Compose restart（需要备份+人工确认已完成）
pipeline_deploy_postgres() {
  log_info "PostgreSQL 重启部署（docker compose restart）"

  docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
    restart postgres

  log_success "PostgreSQL 重启完成"
}
```

### pipeline-stages.sh 新增函数：健康检查

```bash
# Source: 基于 pipeline-stages.sh http_health_check + scripts/lib/health.sh

# pipeline_infra_health_check - 服务专属健康检查
# 参数: $1 = SERVICE
pipeline_infra_health_check() {
  local service="$1"

  case "$service" in
    keycloak)
      # 由 keycloak-blue-green-deploy.sh 内部处理健康检查
      # 此处做二次验证：检查新容器确实在运行
      local active_env
      active_env=$(cat /opt/noda/active-env-keycloak 2>/dev/null || echo "blue")
      wait_container_healthy "keycloak-${active_env}" 180
      ;;
    nginx)
      # nginx -t 验证配置 + curl 验证 HTTP 响应
      docker exec noda-infra-nginx nginx -t
      wait_container_healthy "noda-infra-nginx" 30
      ;;
    noda-ops)
      # 容器 running 即可（无 HTTP 端点）
      wait_container_healthy "noda-ops" 60
      ;;
    postgres)
      # pg_isready 验证数据库可连接
      docker exec noda-infra-postgres-prod pg_isready -h localhost -p 5432
      wait_container_healthy "noda-infra-postgres-prod" 90
      ;;
    *)
      log_error "未知服务: $service"
      return 1
      ;;
  esac
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| 手动 deploy-infrastructure-prod.sh | Jenkins Pipeline 统一管理 | Phase 29 | nginx/noda-ops 部署自动化 |
| Keycloak 独立 Jenkinsfile.keycloak | 统一到 Jenkinsfile.infra | Phase 29 | 单一入口管理所有基础设施服务 |
| 部署前手动检查备份 | Pipeline 自动 pg_dump + 验证 | Phase 29 | 备份不再是人工步骤 |

**Deprecated/outdated:**
- deploy-infrastructure-prod.sh 中的 nginx/noda-ops 部署逻辑：迁移到 Pipeline 后从脚本中移除（D-10）

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Jenkins `input` 步骤在 `timeout` 包裹下超时后自动中止 Pipeline | Architecture Patterns | Pipeline 永远挂起等待确认 |
| A2 | docker compose `--no-deps` 参数不会重启依赖服务 | Architecture Patterns | postgres 被连带重启 |
| A3 | noda-ops 容器重建后 Cloudflare Tunnel 自动恢复 | Pattern 3 | Tunnel 断开需要手动重连 |
| A4 | nginx recreate 后 Cloudflare CDN 缓存的静态资源 URL（带 hash）仍有效 | Pattern 3 | CDN 缓存清除需要额外步骤 |
| A5 | pg_dumpall 的 `--clean --if-exists` 选项生成的备份可以通过 psql 直接恢复 | Code Examples | 回滚失败需要其他恢复方式 |

## Open Questions

1. **noda-ops 是否需要 build 阶段？**
   - What we know: docker-compose.yml 中 noda-ops 使用 `build:` 而非 `image:`，意味着 compose up 会自动 build
   - What's unclear: 是否需要在 recreate 前显式 `docker compose build noda-ops`
   - Recommendation: `docker compose up --build --force-recreate --no-deps noda-ops` 一步完成

2. **postgres restart 的回滚策略？**
   - What we know: D-08 锁定 pg_restore 回滚，但 pg_dumpall 输出是 plain SQL 格式
   - What's unclear: 如果 postgres restart 后数据损坏（极低概率），pg_restore 流程是什么
   - Recommendation: 备份使用 `pg_dumpall --clean --if-exists`，恢复时 `psql -f backup.sql`，记录在 Pipeline 日志中

3. **Keycloak 备份是 pg_dump 还是直接复用 noda-ops 容器的备份脚本？**
   - What we know: D-06 指定 pg_dump，但 noda-ops 容器已有完整备份脚本
   - What's unclear: 是否应该 `docker exec noda-ops /app/backup/backup-postgres.sh` 还是直接 `docker exec postgres pg_dump`
   - Recommendation: 使用 `docker exec postgres pg_dump`（更轻量，Pipeline 专用备份不触发云上传）

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Jenkins | Pipeline 执行 | N/A（服务器端） | 2.541.x LTS | 手动 deploy-infrastructure-prod.sh |
| Docker Compose | 容器管理 | N/A（服务器端） | v2 | -- |
| bash | pipeline-stages.sh | N/A（服务器端） | 4+ | -- |
| pg_dump/pg_dumpall | 备份 | 在 postgres 容器内 | 17.9 | -- |

**Missing dependencies with no fallback:**
- 无（所有依赖在服务器端已就绪）

**Missing dependencies with fallback:**
- Jenkins 不可用时使用 deploy-infrastructure-prod.sh 手动回退

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash 脚本测试（手动验证） |
| Config file | 无 |
| Quick run command | `bash -n scripts/pipeline-stages.sh`（语法检查） |
| Full suite command | 手动在 Jenkins 触发 Pipeline 验证 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PIPELINE-01 | Jenkinsfile.infra choice 参数 | 手动 | Jenkins UI 验证 | Wave 0 |
| PIPELINE-02 | 4 个服务部署函数 | unit | `bash -n scripts/pipeline-stages.sh` | Wave 0 |
| PIPELINE-03 | 各服务独立策略 | 集成 | Jenkins 手动触发各服务 | Wave 0 |
| PIPELINE-04 | pg_dump 自动备份 | 集成 | `docker exec postgres pg_dump` 验证 | Wave 0 |
| PIPELINE-05 | 健康检查 | 集成 | Pipeline Health Check 阶段 | Wave 0 |
| PIPELINE-06 | 自动回滚 | 集成 | 模拟健康检查失败 | Wave 0 |
| PIPELINE-07 | input 门禁 | 手动 | Jenkins UI 验证 | Wave 0 |

### Sampling Rate
- **Per task commit:** `bash -n scripts/pipeline-stages.sh`（语法检查）
- **Per wave merge:** Jenkins 手动触发 Pipeline
- **Phase gate:** 4 个服务各自 Pipeline 执行成功

### Wave 0 Gaps
- [ ] `jenkins/Jenkinsfile.infra` — 新建文件
- [ ] `scripts/pipeline-stages.sh` — 新增 infra 专用函数（约 200 行）
- [ ] `scripts/deploy/deploy-infrastructure-prod.sh` — 移除 nginx/noda-ops 逻辑

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Jenkins 用户认证 + 手动触发 |
| V3 Session Management | yes | Jenkins 会话管理（内置） |
| V4 Access Control | yes | Jenkins 权限控制 + input submitterParameter |
| V5 Input Validation | yes | SERVICE 参数 choice 限制（固定列表，不可注入） |
| V6 Cryptography | no | 不涉及加密操作 |

### Known Threat Patterns for Jenkins Pipeline

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Pipeline 参数注入 | Tampering | `choice` 参数类型限制输入为固定列表 |
| 备份文件泄露 | Information Disclosure | 备份目录权限 600，BACKUP_HOST_DIR 不在 web 根目录 |
| 未授权触发部署 | Elevation of Privilege | Jenkins disableConcurrentBuilds + 手动触发 + 人工确认 |
| postgres restart 数据丢失 | Denial of Service | pg_dump 备份 + 备份验证 + 人工确认门禁 |

## Sources

### Primary (HIGH confidence)
- jenkins/Jenkinsfile — findclass-ssr Pipeline 9 阶段结构 [VERIFIED: codebase]
- jenkins/Jenkinsfile.keycloak — Keycloak Pipeline 7 阶段结构 [VERIFIED: codebase]
- jenkins/Jenkinsfile.noda-site — noda-site Pipeline 8 阶段结构 [VERIFIED: codebase]
- scripts/pipeline-stages.sh — 600+ 行 Pipeline 阶段函数库 [VERIFIED: codebase]
- scripts/keycloak-blue-green-deploy.sh — Keycloak 蓝绿部署 7 步流程 [VERIFIED: codebase]
- scripts/manage-containers.sh — 蓝绿容器管理 8 子命令 [VERIFIED: codebase]
- scripts/deploy/deploy-infrastructure-prod.sh — 基础设施手动部署 7 步流程 [VERIFIED: codebase]
- scripts/lib/health.sh — 容器健康检查库 [VERIFIED: codebase]
- scripts/lib/log.sh — 日志库 [VERIFIED: codebase]
- docker/docker-compose.yml — 基础服务定义 [VERIFIED: codebase]
- docker/docker-compose.prod.yml — 生产 overlay [VERIFIED: codebase]
- config/nginx/conf.d/default.conf — nginx 主配置 [VERIFIED: codebase]

### Secondary (MEDIUM confidence)
- Jenkins Declarative Pipeline 文档 — parameters/when/input 语法 [CITED: jenkins.io/doc/book/pipeline]
- Jenkins Pipeline Best Practices — sh 步骤优于 Groovy 逻辑 [CITED: jenkins.io/doc/book/pipeline/pipeline-best-practices]

### Tertiary (LOW confidence)
- Jenkins `input` 步骤在 `timeout` 内超时行为 [ASSUMED: 需验证]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有组件已在项目中使用
- Architecture: HIGH — 现有 3 个 Jenkinsfile 提供完整模式参考
- Pitfalls: HIGH — 基于 v1.4 里程碑 5 个 Phase 的实践经验

**Research date:** 2026-04-17
**Valid until:** 2026-05-17（30 天，稳定技术栈）
