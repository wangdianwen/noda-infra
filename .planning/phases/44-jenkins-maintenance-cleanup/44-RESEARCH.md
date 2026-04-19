# Phase 44: Jenkins 维护清理 + 定期任务 - Research

**Researched:** 2026-04-20
**Domain:** Jenkins 构建清理 + pnpm/npm 缓存定期维护
**Confidence:** HIGH

## Summary

Phase 44 的核心任务是将低频维护类清理自动化：Jenkins 旧构建 workspace 释放磁盘、pnpm store 和 npm cache 的定期清理。本 phase 依赖 Phase 43 已建立的 cleanup.sh 共享库，只需扩展两个新函数（`cleanup_jenkins_workspace` 和 `cleanup_pnpm_store`/`cleanup_npm_cache`），并新建一个独立的 `Jenkinsfile.cleanup` Pipeline 来定期触发。

关键技术点：Jenkins cron trigger 语法、Jenkins workspace 清理策略（`deleteDir` vs 脚本遍历）、pnpm store prune 的安全使用、npm cache clean 命令。所有这些命令都已有成熟的 Jenkins Declarative Pipeline 模式支持。

**Primary recommendation:** 新建 `jenkins/Jenkinsfile.cleanup` 独立 Pipeline，cron 触发每周一凌晨 3 点执行，复用 cleanup.sh 扩展函数，支持 `FORCE` 参数强制触发。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 保留现有 `buildDiscarder(numToKeepStr: '20')` 不变。JENK-01 已由现有配置覆盖
- **D-02:** 新增 `cleanup_jenkins_workspace()` 函数到 cleanup.sh，清理 Jenkins workspace 中已完成构建的工作目录
- **D-03:** 使用 Jenkins periodic build（非 crontab/systemd timer），新建 `jenkins/Jenkinsfile.cleanup` 独立 Pipeline
- **D-04:** Pipeline 每周自动触发（`triggers { cron('0 3 * * 1') }`，每周一凌晨 3 点），同时支持手动触发参数 `FORCE=true` 强制执行
- **D-05:** Jenkinsfile.cleanup 复用 cleanup.sh 中的函数：pnpm store prune + npm cache clean + workspace 清理
- **D-06:** Pipeline 参数 `FORCE=true` 时忽略 7 天间隔限制，立即执行清理

### Claude's Discretion
- cleanup_jenkins_workspace() 的具体实现（遍历策略、目录判断逻辑）
- Jenkinsfile.cleanup 的 Pipeline 阶段设计
- pnpm store prune 和 npm cache clean 的具体命令参数
- 日志输出格式

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| JENK-01 | 清理 Jenkins 已完成的旧 Pipeline 构建（保留最近 N 次构建记录，删除更早的 artifacts 和构建目录） | D-01 确认已有 `buildDiscarder(numToKeepStr: '20')` 覆盖，无需额外实现 |
| JENK-02 | 清理 Jenkins workspace 中已完成构建的工作目录（释放磁盘空间） | cleanup.sh 扩展 `cleanup_jenkins_workspace()` 函数 + Jenkinsfile.cleanup 定期调用 |
| CACHE-02 | pnpm store 定期 prune（每 7 天一次，非每次部署），可通过参数强制触发 | cleanup.sh 扩展 `cleanup_pnpm_store()` + Jenkinsfile.cleanup cron 触发 + FORCE 参数 |
| CACHE-03 | npm cache 定期清理（`npm cache clean --force`），与 pnpm store prune 同频率 | cleanup.sh 扩展 `cleanup_npm_cache()` + 与 pnpm store prune 同一 Pipeline 阶段 |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Jenkins workspace 清理 | Jenkins Controller (宿主机) | -- | workspace 目录 `/var/lib/jenkins/workspace/` 由 Jenkins 控制器管理 |
| pnpm store prune | Jenkins Controller (宿主机) | -- | pnpm global store 在宿主机文件系统上，由 Jenkins 用户执行 |
| npm cache clean | Jenkins Controller (宿主机) | -- | npm cache 在宿主机文件系统上，由 Jenkins 用户执行 |
| 定期触发调度 | Jenkins Pipeline Engine | -- | 使用 Jenkins 内置 cron trigger，不依赖系统 crontab |

## Standard Stack

### Core

| Library/Tool | Version | Purpose | Why Standard |
|-------------|---------|---------|--------------|
| Jenkins Declarative Pipeline | 2.541.x LTS | Pipeline 引擎 | 项目已统一使用，4 个 Jenkinsfile 均为 Declarative 语法 [VERIFIED: 代码库] |
| cleanup.sh | Phase 43 建立 | 清理函数共享库 | 已有 Docker/Node.js/文件清理函数，需扩展 [VERIFIED: scripts/lib/cleanup.sh] |
| pnpm CLI | 10.29.3 | 包管理器 | 项目 Node.js 包管理器，store prune 命令内置 [VERIFIED: CONTEXT.md code_context] |
| npm CLI | 11.7.0 | Node.js 包管理器 | `npm cache clean --force` 清理缓存 [VERIFIED: CONTEXT.md code_context] |

### Supporting

| Library/Tool | Version | Purpose | When to Use |
|-------------|---------|---------|-------------|
| `triggers { cron() }` | Jenkins 内置 | 定时触发 Pipeline | Jenkinsfile.cleanup 每周定期执行 [CITED: jenkins.io/doc/book/pipeline/syntax] |
| `booleanParam` | Jenkins 内置 | Pipeline 参数 | FORCE=true 强制触发清理 [CITED: jenkins.io/doc/book/pipeline/syntax] |
| `buildDiscarder(logRotator())` | Jenkins 内置 | 构建历史保留策略 | 所有 Jenkinsfile 已配置 numToKeepStr: '20' [VERIFIED: 4 个 Jenkinsfile] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Jenkins periodic build | Linux crontab | crontab 更简单但脱离 Jenkins 管理，无法在 Jenkins UI 查看执行历史和日志；Jenkins cron 可在 Stage View 中查看每次执行状态 [ASSUMED] |
| Jenkins periodic build | systemd timer | systemd timer 需要写 .service + .timer 文件，不如 Jenkins Pipeline 灵活（不支持手动触发、参数化）[ASSUMED] |
| cleanup.sh 扩展函数 | Jenkins cleanWs 插件 | cleanWs 只清理当前构建的 workspace，不能跨 workspace 清理其他项目的残留目录 [CITED: jenkins.io/doc/pipeline/steps/ws-cleanup] |

**Installation:**
无需安装新包。所有工具已在环境中就绪。

## Architecture Patterns

### System Architecture Diagram

```
Jenkins Controller (宿主机)
┌─────────────────────────────────────────────────┐
│                                                 │
│  ┌─────────────────────────┐                    │
│  │ Jenkinsfile.cleanup     │◄── cron 每周一 03:00│
│  │ (独立 Pipeline)          │◄── 手动 + FORCE    │
│  └──────────┬──────────────┘                    │
│             │ source                            │
│             ▼                                   │
│  ┌─────────────────────────┐                    │
│  │ cleanup.sh (共享库)      │                    │
│  │                         │                    │
│  │ + cleanup_jenkins_      │──► /var/lib/jenkins│
│  │   workspace()           │    /workspace/*    │
│  │                         │                    │
│  │ + cleanup_pnpm_store()  │──► pnpm global     │
│  │                         │    store 目录       │
│  │                         │                    │
│  │ + cleanup_npm_cache()   │──► npm cache 目录  │
│  │                         │                    │
│  │ disk_snapshot()         │──► df -h 输出      │
│  └─────────────────────────┘                    │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Recommended Project Structure

```
jenkins/
├── Jenkinsfile.findclass-ssr   # 现有 - 应用蓝绿部署
├── Jenkinsfile.noda-site       # 现有 - 站点蓝绿部署
├── Jenkinsfile.keycloak        # 现有 - Keycloak 蓝绿部署
├── Jenkinsfile.infra           # 现有 - 基础设施部署
└── Jenkinsfile.cleanup         # 新增 - 定期清理 Pipeline

scripts/lib/
├── log.sh                      # 现有 - 日志函数
├── cleanup.sh                  # 现有 + 扩展 - 添加 3 个新函数
└── image-cleanup.sh            # 现有 - 镜像清理（不修改）
```

### Pattern 1: cleanup.sh 函数扩展模式

**What:** 在现有 cleanup.sh 中添加新函数，遵循 Source Guard 和 `|| true` 模式
**When to use:** 所有新增清理函数
**Example:**

```bash
# Source: scripts/lib/cleanup.sh 现有模式

# -------------------------------------------
# pnpm Store 定期清理 (CACHE-02)
# -------------------------------------------
# 参数:
#   $1: 强制模式（"force" 忽略 7 天间隔检查）
# 返回：无（移除未引用的 pnpm 包）
cleanup_pnpm_store()
{
    local force_mode="${1:-}"

    if [ "$force_mode" != "force" ]; then
        # 检查距离上次 prune 是否超过 7 天
        # (实现: 检查标记文件时间戳)
        local marker_file="${HOME}/.cache/noda-cleanup/pnpm-prune-marker"
        if [ -f "$marker_file" ]; then
            local last_prune
            last_prune=$(stat -f '%m' "$marker_file" 2>/dev/null || stat -c '%Y' "$marker_file" 2>/dev/null || echo "0")
            local now
            now=$(date +%s)
            local age_days=$(( (now - last_prune) / 86400 ))
            if [ "$age_days" -lt 7 ]; then
                log_info "pnpm store prune 跳过（距上次仅 ${age_days} 天，需 >= 7 天）"
                return 0
            fi
        fi
    fi

    log_info "pnpm store prune（清理未引用包）..."
    local before_size
    before_size=$(du -sh "$(pnpm store path)" 2>/dev/null | awk '{print $1}' || echo "unknown")
    log_info "pnpm store 当前大小: ${before_size}"

    pnpm store prune || true

    # 更新标记文件时间戳
    mkdir -p "${HOME}/.cache/noda-cleanup" 2>/dev/null || true
    touch "$marker_file" 2>/dev/null || true

    log_success "pnpm store prune 完成"
}

# -------------------------------------------
# npm Cache 定期清理 (CACHE-03)
# -------------------------------------------
cleanup_npm_cache()
{
    log_info "npm cache clean --force..."
    npm cache clean --force 2>/dev/null || true
    log_success "npm cache 清理完成"
}

# -------------------------------------------
# Jenkins Workspace 清理 (JENK-02)
# -------------------------------------------
# 参数:
#   $1: Jenkins workspace 根路径（默认 /var/lib/jenkins/workspace）
# 返回：无（清理已完成构建的工作目录残留）
cleanup_jenkins_workspace()
{
    local workspace_root="${1:-/var/lib/jenkins/workspace}"

    if [ ! -d "$workspace_root" ]; then
        log_info "Jenkins workspace 目录不存在: $workspace_root"
        return 0
    fi

    log_info "检查 Jenkins workspace: $workspace_root"

    # 遍历 workspace 下所有子目录
    local cleaned=0
    for dir in "$workspace_root"/*/; do
        [ -d "$dir" ] || continue
        local dirname
        dirname=$(basename "$dir")
        local size
        size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}' || echo "0")
        # 清理策略: 删除 @tmp 目录（SCM checkout 临时目录）和大尺寸残留
        if [[ "$dirname" == *@tmp ]]; then
            log_info "清理 @tmp 目录: $dirname (${size})"
            rm -rf "$dir" || true
            cleaned=$((cleaned + 1))
        fi
    done

    log_success "Jenkins workspace 清理完成: ${cleaned} 个临时目录已清理"
}
```

### Pattern 2: Jenkinsfile.cleanup Pipeline 结构

**What:** 独立清理 Pipeline，cron 触发 + 手动触发
**When to use:** 定期维护任务

```groovy
// Source: Jenkins Declarative Pipeline 文档模式
// https://www.jenkins.io/doc/book/pipeline/syntax

pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
    }

    triggers {
        cron('0 3 * * 1')  // 每周一 03:00 UTC
    }

    parameters {
        booleanParam(
            name: 'FORCE',
            defaultValue: false,
            description: '强制执行清理（忽略 7 天间隔限制）'
        )
    }

    stages {
        stage('Pre-flight') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    echo "清理模式: ${FORCE:-false}"
                    echo "触发原因: ${currentBuild.buildCauses}"
                    docker info >/dev/null 2>&1 || exit 1
                '''
            }
        }

        stage('Disk Snapshot (Before)') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/lib/cleanup.sh
                    disk_snapshot "清理前"
                '''
            }
        }

        stage('Jenkins Workspace Cleanup') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/lib/cleanup.sh
                    cleanup_jenkins_workspace
                '''
            }
        }

        stage('Package Cache Cleanup') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/lib/cleanup.sh
                    if [ "${FORCE}" = "true" ]; then
                        cleanup_pnpm_store "force"
                    else
                        cleanup_pnpm_store
                    fi
                    cleanup_npm_cache
                '''
            }
        }

        stage('Disk Snapshot (After)') {
            steps {
                sh '''
                    source scripts/lib/log.sh
                    source scripts/lib/cleanup.sh
                    disk_snapshot "清理后"
                '''
            }
        }
    }

    post {
        success {
            echo '定期清理完成'
        }
        failure {
            echo '定期清理失败，请检查日志'
        }
    }
}
```

### Anti-Patterns to Avoid

- **直接 crontab/systemd timer 脚本**: 脱离 Jenkins 管理体系，无法在 UI 查看历史和日志，违反 D-03 决策
- **cleanWs 插件替代 workspace 清理**: cleanWs 只清理当前构建的 workspace，不能清理其他项目的残留目录
- **每次部署都执行 pnpm store prune**: pnpm store prune 后首次 install 需要重新下载所有包，降低部署速度。CONTEXT.md D-04 明确每 7 天一次
- **删除所有 @tmp 目录时不加保护**: Jenkins 可能正在使用某些 @tmp 目录，需确保不在构建过程中执行

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Jenkins 构建历史清理 | 自写 Groovy 清理脚本 | `buildDiscarder(logRotator(numToKeepStr: '20'))` | Jenkins 内置功能已覆盖 JENK-01，现有 4 个 Jenkinsfile 均已配置 |
| Jenkins workspace 清理 | 调用 Jenkins REST API 清理 | `cleanup_jenkins_workspace()` bash 函数 | 直接文件系统操作更简单可靠，不需要 Jenkins API 认证 |
| pnpm 包清理 | `rm -rf` pnpm store 目录 | `pnpm store prune` | 官方命令只移除未引用包，保留正在使用的包 [CITED: pnpm.io/cli/store] |
| npm 缓存清理 | `rm -rf` npm cache 目录 | `npm cache clean --force` | 官方命令，安全清理缓存 |
| 定期任务调度 | Linux crontab | Jenkins `triggers { cron() }` | D-03 锁定决策，统一在 Jenkins 内管理 |

**Key insight:** 本 phase 几乎不需要造轮子。所有核心功能都有成熟的 CLI 命令或 Jenkins 内置功能。工作重心是"组合调用"而非"实现逻辑"。

## Common Pitfalls

### Pitfall 1: Jenkins cron 时区问题

**What goes wrong:** `cron('0 3 * * 1')` 使用 Jenkins 控制器的系统时区。如果服务器时区不是预期的，凌晨 3 点可能变成其他时间
**Why it happens:** Jenkins cron 不支持时区参数，直接使用 JVM 默认时区
**How to avoid:** 确认服务器时区配置（`timedatectl`），如需 UTC+12 则用 `TZ=Asia/Auckland` 环境变量
**Warning signs:** 清理任务在非预期时间执行

### Pitfall 2: pnpm store prune 与 install 冲突

**What goes wrong:** pnpm install 正在运行时执行 `pnpm store prune` 导致安装失败
**Why it happens:** pnpm 文档明确警告 "This command is prohibited when a store server is running"
**How to avoid:** 清理 Pipeline 使用 `disableConcurrentBuilds()` + 与部署 Pipeline 不重叠的时间窗口（凌晨 3 点 vs 白天部署）
**Warning signs:** pnpm install 失败 + `pnpm store prune` 同一时间执行

### Pitfall 3: Jenkins cron 语法使用 H 符号

**What goes wrong:** Jenkins 推荐使用 `H` 而非固定数字来分散负载（如 `H 3 * * 1`），但本项目中 Jenkins 是单服务器，无需分散
**Why it happens:** 盲目复制 Jenkins 文档示例
**How to avoid:** 使用固定时间 `0 3 * * 1`，不使用 `H`。单服务器不存在多节点负载分散需求 [ASSUMED]
**Warning signs:** 清理时间不确定

### Pitfall 4: workspace @tmp 目录清理时机

**What goes wrong:** Jenkins 正在 checkout 时删除了 @tmp 目录
**Why it happens:** Jenkins 使用 `workspace-name@tmp` 作为 SCM checkout 临时目录，构建完成后通常不清理
**How to avoid:** `disableConcurrentBuilds()` 确保清理 Pipeline 独占运行。但需注意：清理 Pipeline 本身也会创建 @tmp 目录
**Warning signs:** Jenkins checkout 失败 + 清理 Pipeline 同时运行

### Pitfall 5: 首次运行参数未生效

**What goes wrong:** Jenkins Declarative Pipeline 首次运行时 parameters 块未生效，`params.FORCE` 为 null
**Why it happens:** Jenkins 需要运行一次 Pipeline 后才会注册参数定义
**How to avoid:** 首次需手动运行一次（Jenkins 会自动读取 Jenkinsfile 并注册参数），第二次运行时参数才生效。在 Pre-flight 阶段使用 `${FORCE:-false}` 提供默认值
**Warning signs:** `params.FORCE` 为 null 或报错

## Code Examples

### pnpm store prune 命令

```bash
# Source: https://pnpm.io/cli/store [VERIFIED: Context7]

# 查看 pnpm store 大小
pnpm store path  # 输出 store 路径
du -sh "$(pnpm store path)"

# 清理未引用的包（安全：只移除不被任何项目引用的包）
pnpm store prune

# 注意：store server 运行时此命令被禁止
# 注意：不要频繁执行（prune 后首次 install 需重新下载）
```

### npm cache clean 命令

```bash
# Source: npm CLI 内置命令 [ASSUMED]

# 查看 npm cache 位置和大小
npm cache ls  # 列出缓存条目
du -sh "$(npm config get cache)"

# 强制清理 npm 缓存
npm cache clean --force

# 注意：npm v5+ 默认不需要手动清理（自动管理），但 --force 可强制执行
```

### Jenkins Declarative Pipeline cron + parameters

```groovy
// Source: https://www.jenkins.io/doc/book/pipeline/syntax [CITED]

pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
    }

    triggers {
        cron('0 3 * * 1')  // 每周一 03:00
    }

    parameters {
        booleanParam(name: 'FORCE', defaultValue: false, description: '强制执行清理')
    }

    stages {
        stage('Example') {
            steps {
                echo "FORCE = ${params.FORCE}"
            }
        }
    }
}
```

### 7 天间隔标记文件模式

```bash
# 标记文件方案：检查距离上次 prune 是否超过 7 天
MARKER_FILE="${HOME}/.cache/noda-cleanup/pnpm-prune-marker"

check_prune_interval()
{
    local force="$1"
    if [ "$force" = "force" ]; then
        return 0  # 强制模式，跳过间隔检查
    fi

    if [ -f "$MARKER_FILE" ]; then
        local last_epoch
        last_epoch=$(stat -f '%m' "$MARKER_FILE" 2>/dev/null || stat -c '%Y' "$MARKER_FILE" 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date +%s)
        local age_days=$(( (now_epoch - last_epoch) / 86400 ))
        if [ "$age_days" -lt 7 ]; then
            log_info "距上次 prune 仅 ${age_days} 天，跳过（需 >= 7 天）"
            return 1
        fi
    fi
    return 0
}

# 执行 prune 后更新标记
update_prune_marker()
{
    mkdir -p "$(dirname "$MARKER_FILE")" 2>/dev/null || true
    touch "$MARKER_FILE" 2>/dev/null || true
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| 手动 crontab 管理 | Jenkins Pipeline cron | 项目起始 | 所有清理任务在 Jenkins UI 可追溯 |
| `cleanWs` 插件清理 workspace | bash 脚本遍历清理 | Phase 44 | 更灵活，可清理跨项目残留 |
| 每次 deploy 都 prune | 7 天间隔 + 标记文件 | Phase 44 D-04 | 避免首次安装变慢 |

**Deprecated/outdated:**
- Jenkins `cleanWs` 插件: 仅清理当前构建 workspace，不适合跨项目残留清理场景
- `WsCleanup` (旧版): 已被 `cleanWs` 替代，但两者都不适合本场景

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Jenkins cron 使用系统时区，不支持时区参数 | Pitfall 1 | 清理在非预期时间执行 |
| A2 | 单服务器不需要 H 分散策略 | Pitfall 3 | 不影响功能，但可能在文档中被质疑 |
| A3 | `npm cache clean --force` 在 npm 11.x 中仍然可用 | Code Examples | 命令可能已变更，需验证 |
| A4 | Jenkins workspace @tmp 目录可安全删除 | Pattern 1 | 可能影响正在运行的构建 |

## Open Questions

1. **Jenkins 服务器时区**
   - What we know: Jenkins 运行在 Linux 宿主机上
   - What's unclear: 服务器实际配置的时区（UTC? NZST?）
   - Recommendation: 部署前检查 `timedatectl`，如有需要调整 cron 时间

2. **Jenkins workspace 实际目录结构**
   - What we know: 标准 Jenkins workspace 在 `/var/lib/jenkins/workspace/`
   - What's unclear: 实际有哪些子目录、是否有 @tmp 残留
   - Recommendation: 在 cleanup_jenkins_workspace 中先用 `ls -la` 列出目录再清理

3. **pnpm store 是否使用 store server**
   - What we know: pnpm store prune 在 store server 运行时被禁止
   - What's unclear: 项目是否使用了 pnpm store server
   - Recommendation: 默认未使用（项目规模小），如有则 `pnpm store prune` 会报错并被 `|| true` 吞掉

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| pnpm CLI | pnpm store prune | ✓ (服务器) | 10.29.3 | -- |
| npm CLI | npm cache clean | ✓ (服务器) | 11.7.0 | -- |
| Jenkins LTS | Pipeline cron trigger | ✓ (服务器) | 2.541.3 | -- |
| bash | 清理脚本执行 | ✓ | 系统内置 | -- |

**Missing dependencies with no fallback:**
- None

**Missing dependencies with fallback:**
- None

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Jenkins Pipeline 手动验证 |
| Config file | 无独立测试框架 |
| Quick run command | 手动触发 `cleanup` Pipeline |
| Full suite command | 手动触发 + 检查日志 + 验证磁盘空间 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| JENK-01 | buildDiscarder 保留最近 20 次构建 | 验证已有 | `grep -r "buildDiscarder" jenkins/` | ✓ 现有 Jenkinsfile |
| JENK-02 | workspace 目录被清理 | 手动验证 | 手动触发 Pipeline + 检查日志 | - Wave 0 |
| CACHE-02 | pnpm store prune 执行 | 手动验证 | 手动触发 Pipeline + 检查日志 | - Wave 0 |
| CACHE-03 | npm cache clean 执行 | 手动验证 | 手动触发 Pipeline + 检查日志 | - Wave 0 |

### Sampling Rate
- **Per task commit:** 无自动测试（bash 函数验证通过 `bash -n` 语法检查）
- **Per wave merge:** 无自动测试
- **Phase gate:** 手动触发 cleanup Pipeline，验证全部 4 个阶段执行成功

### Wave 0 Gaps
- [ ] `jenkins/Jenkinsfile.cleanup` -- 定期清理 Pipeline（新文件）
- [ ] cleanup.sh 扩展 -- 3 个新函数（cleanup_jenkins_workspace, cleanup_pnpm_store, cleanup_npm_cache）
- [ ] 手动验证: 触发 cleanup Pipeline + 检查日志输出 + 验证磁盘空间变化

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Jenkins 已有认证体系 |
| V3 Session Management | no | 不涉及 |
| V4 Access Control | yes | Jenkins Pipeline 以 jenkins 用户执行，需要 docker 组权限 |
| V5 Input Validation | yes | FORCE 参数为 booleanParam，Jenkins 自动验证 |
| V6 Cryptography | no | 不涉及 |

### Known Threat Patterns for Jenkins + bash cleanup

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 路径遍历删除 | Tampering | workspace_root 使用硬编码默认值，不接受外部输入 |
| 符号链接攻击 | Tampering | `rm -rf` 不跟随符号链接（bash 默认行为） |
| 竞态条件（构建中删除） | Denial of Service | `disableConcurrentBuilds()` 防止并发 |
| pnpm store prune 破坏 install | Denial of Service | 7 天间隔 + 凌晨 3 点低峰期执行 |

## Sources

### Primary (HIGH confidence)
- Context7 `/websites/pnpm_io` - pnpm store prune 命令文档和行为说明
- Context7 `/websites/jenkins_io_doc` - Jenkins Declarative Pipeline cron trigger、parameters、buildDiscarder 语法
- Context7 `/websites/jenkins_io_doc` - Jenkins cleanWs/deleteDir workspace 清理步骤
- 代码库: `scripts/lib/cleanup.sh` - 现有清理库结构和 Source Guard 模式
- 代码库: `jenkins/Jenkinsfile.*` - 4 个现有 Jenkinsfile 的 Declarative Pipeline 模式
- 代码库: `scripts/pipeline-stages.sh` - Pipeline 阶段函数库和调用模式

### Secondary (MEDIUM confidence)
- CONTEXT.md D-01~D-06 - Phase 44 锁定决策
- REQUIREMENTS.md JENK-01/02, CACHE-02/03 - 需求定义
- ROADMAP.md Phase 44 - 目标和成功标准
- Phase 43 CONTEXT.md - cleanup.sh 架构和 Source Guard 模式

### Tertiary (LOW confidence)
- npm cache clean --force 在 npm 11.x 中的可用性 [ASSUMED，基于 npm 长期稳定的 CLI]
- Jenkins workspace @tmp 目录安全删除假设 [ASSUMED]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - 所有组件均为项目已使用的成熟工具，无需新安装
- Architecture: HIGH - 遵循现有 Pipeline 模式（Declarative + cleanup.sh 函数库），模式已在 Phase 43 验证
- Pitfalls: MEDIUM - Jenkins cron 时区和 pnpm store server 场景需要实际部署时验证

**Research date:** 2026-04-20
**Valid until:** 2026-05-20 (稳定 — 纯 bash + Jenkins 内置功能，变化率低)
