# Phase 44: Jenkins 维护清理 + 定期任务 - Pattern Map

**Mapped:** 2026-04-20
**Files analyzed:** 2
**Analogs found:** 2 / 2

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `scripts/lib/cleanup.sh` | utility | batch | `scripts/lib/cleanup.sh`（现有文件扩展） | exact（同一文件） |
| `jenkins/Jenkinsfile.cleanup` | config | batch | `jenkins/Jenkinsfile.infra` | exact（同角色 + 同模式） |

## Pattern Assignments

### `scripts/lib/cleanup.sh`（utility, batch — 现有文件扩展）

**Analog:** 自身 — 在现有文件末尾追加 3 个新函数

**Source Guard 模式**（行 10-14）:
```bash
# Source Guard
if [[ -n "${_NODA_CLEANUP_LOADED:-}" ]]; then
    return 0
fi
_NODA_CLEANUP_LOADED=1
```

**函数定义模式 — 逐个提取自现有函数：**

**注释头 + 参数说明**（行 23-28，`cleanup_docker_build_cache` 为例）:
```bash
# -------------------------------------------
# Docker Build Cache 清理 (DOCK-01)
# -------------------------------------------
# 参数:
#   $1: 保留小时数（默认 BUILD_CACHE_RETENTION_HOURS，即 24）
# 返回：无（清理超过保留期的 build cache）
```

**标准函数体模式 — local 变量 + `|| true` 安全执行**（行 29-42）:
```bash
cleanup_docker_build_cache()
{
    local retention_hours="${1:-$BUILD_CACHE_RETENTION_HOURS}"

    log_info "清理 Docker build cache（保留 ${retention_hours} 小时内）..."

    local before_size
    before_size=$(docker buildx du 2>/dev/null | tail -1 | awk '{print $3 $4}' || echo "unknown")
    log_info "Build cache 当前大小: ${before_size}"

    docker buildx prune -f --filter "until=${retention_hours}h" 2>/dev/null || true

    log_success "Docker build cache 清理完成"
}
```

**条件跳过 + 计数模式**（行 50-62，`cleanup_dangling_images` 为例）:
```bash
cleanup_dangling_images()
{
    log_info "检查 dangling images..."

    local count
    count=$(docker images -f "dangling=true" -q 2>/dev/null | grep -c . || echo "0")

    if [ "$count" -gt 0 ]; then
        docker image prune -f 2>/dev/null || true
        log_success "Dangling images 清理完成: ${count} 个"
    else
        log_info "无需清理 dangling images"
    fi
}
```

**目录遍历 + 批量清理模式**（行 119-137，`cleanup_node_modules` 为例）:
```bash
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
```

**关键规则：**
- 每个函数以 `log_info` 开始 + `log_success` 结束
- 所有外部命令加 `2>/dev/null || true`，确保失败不传播
- 使用 `local` 声明所有变量
- 参数用 `${1:-默认值}` 提供默认值
- 新函数追加到文件末尾（在 wrapper 函数之后）

---

### `jenkins/Jenkinsfile.cleanup`（config, batch — 新文件）

**Analog:** `jenkins/Jenkinsfile.infra`（参数化 Pipeline，结构与本项目一致）

**文件头注释**（行 1-6）:
```groovy
#!/usr/bin/env groovy
// 统一基础设施 Jenkins Pipeline
// 7 阶段: Pre-flight -> Backup -> Human Approval -> Deploy -> Health Check -> Verify -> Cleanup
// 手动触发（无自动触发配置）
// 参数化服务选择: nginx / noda-ops / postgres
// 注意: Keycloak 有专用 Pipeline (keycloak-deploy)，不在此处部署
```

**Pipeline 骨架 — options + parameters**（行 19-35）:
```groovy
pipeline {
    agent any

    environment {
        PROJECT_ROOT = "${WORKSPACE}"
        COMPOSE_BASE = "-f docker/docker-compose.yml -f docker/docker-compose.prod.yml"
    }

    options {
        // 禁止并发构建，防止两个 Pipeline 同时操作基础设施服务
        disableConcurrentBuilds()
        // 保留最近 20 次构建日志
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timestamps()
    }

    parameters {
        choice(
            name: 'SERVICE',
            choices: ['nginx', 'noda-ops', 'postgres'],
            description: '选择要部署的基础设施服务'
        )
    }
```

**Stage 调用模式 — source + sh 调用函数**（行 38-44）:
```groovy
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
```

**条件执行 stage**（行 49-54）:
```groovy
        stage('Backup') {
            when {
                expression { params.SERVICE == 'postgres' }
            }
            steps {
                // ...
            }
        }
```

**post 块**（行 117-131）:
```groovy
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
```

**Jenkinsfile.cleanup 与现有 Jenkinsfile 的差异点：**

| 属性 | 现有 Jenkinsfile | Jenkinsfile.cleanup |
|------|------------------|---------------------|
| triggers | 无（手动触发） | `cron('0 3 * * 1')`（每周一 03:00） |
| parameters | choice（服务选择） | booleanParam（FORCE 强制执行） |
| buildDiscarder | `numToKeepStr: '20'` | `numToKeepStr: '10'`（清理日志保留更少） |
| sh 调用 | `source scripts/pipeline-stages.sh` | `source scripts/lib/cleanup.sh`（直接用清理函数） |
| environment | DOPPLER_TOKEN, COMPOSE_BASE 等 | 无需 Doppler，无需 COMPOSE_BASE |

---

## Shared Patterns

### 日志函数调用
**Source:** `scripts/lib/log.sh`
**Apply to:** cleanup.sh 所有新函数

每个 cleanup.sh 函数必须以 `source scripts/lib/log.sh` 的方式间接使用（Jenkinsfile 中 sh 块调用 `source scripts/lib/log.sh`）。函数内部使用：
- `log_info "描述..."` — 开始操作
- `log_success "描述完成"` — 操作成功
- `log_warn "描述..."` — 可恢复的异常

### `|| true` 安全执行
**Source:** `scripts/lib/cleanup.sh` 全文件
**Apply to:** 所有新 cleanup 函数中的外部命令

```bash
pnpm store prune || true
npm cache clean --force 2>/dev/null || true
rm -rf "$dir" || true
```

所有清理命令必须加 `|| true`，确保单项清理失败不影响后续清理步骤。

### Jenkinsfile sh 块模式
**Source:** `jenkins/Jenkinsfile.infra` 行 40-44
**Apply to:** Jenkinsfile.cleanup 所有 stage

```groovy
stage('Stage Name') {
    steps {
        sh '''
            source scripts/lib/log.sh
            source scripts/lib/cleanup.sh
            cleanup_function_name
        '''
    }
}
```

每个 sh 块必须先 `source log.sh` 再 `source cleanup.sh`，然后调用函数。

### Source Guard
**Source:** `scripts/lib/cleanup.sh` 行 10-14
**Apply to:** cleanup.sh 文件（已有，新增函数不需要额外 guard）

```bash
if [[ -n "${_NODA_CLEANUP_LOADED:-}" ]]; then
    return 0
fi
_NODA_CLEANUP_LOADED=1
```

新函数追加在 Source Guard 之后，自然受到保护。

## No Analog Found

无。所有文件都有精确的类比对象：
- `cleanup.sh` 扩展：在自身基础上追加函数（精确匹配）
- `Jenkinsfile.cleanup`：与 `Jenkinsfile.infra` 结构一致（精确匹配）

## Metadata

**Analog search scope:** `scripts/lib/`, `jenkins/`
**Files scanned:** 6（cleanup.sh, log.sh, image-cleanup.sh, Jenkinsfile.findclass-ssr, Jenkinsfile.infra, Jenkinsfile.keycloak）
**Pattern extraction date:** 2026-04-20
