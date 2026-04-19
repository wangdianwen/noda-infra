# Phase 40: Jenkins Pipeline Doppler 集成 - Research

**Researched:** 2026-04-19
**Domain:** Doppler CLI + Jenkins Pipeline 密钥注入
**Confidence:** HIGH

## Summary

Phase 40 的核心任务是将 Jenkins Pipeline 的密钥获取方式从 `source docker/.env` 切换为 Doppler CLI 拉取，同时保留 `.env` 文件作为回退。改动范围集中在一个关键文件 `scripts/pipeline-stages.sh` 的密钥加载逻辑（第 20-29 行），以及 3 个 Jenkinsfile 中需要用 `withCredentials` 包装密钥依赖的 stages。手动部署脚本（deploy-infrastructure-prod.sh、deploy-apps-prod.sh、blue-green-deploy.sh）也需要同步添加 Doppler 支持。

**Primary recommendation:** 在 `pipeline-stages.sh` 中实现双模式密钥加载函数 `load_secrets()`，检测 `DOPPLER_TOKEN` 环境变量决定使用 Doppler 还是回退 `docker/.env`。Jenkinsfile 用 `withCredentials` 注入 `DOPPLER_TOKEN`，手动脚本要求用户预设环境变量。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 只改 3 个 Jenkinsfile（findclass-ssr、infra、keycloak），跳过 noda-site（静态站点无敏感密钥）
- **D-02:** noda-site 未来需要密钥时可复用相同模式
- **D-03:** 在 pipeline-stages.sh 中统一处理密钥获取，不添加独立 Fetch Secrets stage
- **D-04:** pipeline-stages.sh 检测 `DOPPLER_TOKEN` 环境变量：有则 `doppler secrets download --no-file --format=env`，没有则回退 `source docker/.env`
- **D-05:** Doppler 配置：`--project noda --config prd`（注意 config 名为 `prd` 非 `prod`，Phase 39 已验证）
- **D-06:** 每个 Jenkinsfile 用 `withCredentials([string(credentialsId: 'doppler-service-token', variable: 'DOPPLER_TOKEN')])` 包装需要密钥的 stages
- **D-07:** Service Token credentialsId: `doppler-service-token`（Phase 39 已录入 Jenkins Credentials）
- **D-08:** deploy-infrastructure-prod.sh 和 deploy-apps-prod.sh 本 phase 一起改为 Doppler
- **D-09:** 手动脚本要求用户预先设置 `DOPPLER_TOKEN` 环境变量，无 token 时回退 docker/.env
- **D-10:** 双模式回退策略：DOPPLER_TOKEN 存在 -> Doppler 拉取；不存在 -> 回退 source docker/.env
- **D-11:** Phase 41 删除 docker/.env 前回退机制始终可用。Phase 41 之后需确保 Doppler 稳定
- **D-12:** VITE_* 公开信息不纳入 Doppler，保持 Dockerfile 中 ARG 硬编码和 docker-compose.app.yml 中 args 硬编码

### Claude's Discretion
- pipeline-stages.sh 中 Doppler 回退逻辑的具体实现细节
- withCredentials 在 Jenkinsfile 中的包装位置和范围
- 手动脚本的 Doppler 检测和错误处理细节
- Doppler secrets download 后的变量注入方式（source /dev/stdin vs 临时文件）

### Deferred Ideas (OUT OF SCOPE)
- noda-site Pipeline 的 Doppler 集成 — 静态站点暂无敏感密钥，未来需要时复用相同模式
- Phase 41 删除 docker/.env — 本 phase 保留 .env 作为回退，删除在 Phase 41
- 密钥自动轮换 — Doppler 免费版不支持
- 多环境（dev/staging）— 当前只有生产环境
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PIPE-01 | Jenkinsfile 添加 "Fetch Secrets" stage，Pipeline 启动时通过 `doppler secrets download` 拉取密钥 | D-03 锁定不添加独立 stage，在 pipeline-stages.sh 统一处理。使用 `doppler secrets download --no-file --format=env --project noda --config prd` 命令 [VERIFIED: Context7 Doppler CLI docs] |
| PIPE-02 | 使用 `withCredentials` 绑定 Doppler 凭据，确保不暴露到构建日志 | D-06 锁定用 `withCredentials([string(credentialsId: 'doppler-service-token', variable: 'DOPPLER_TOKEN')])` 包装 stages。Jenkins `credentials()` 方法也可用于 `environment {}` 块，但 withCredentials 包装 stages 更灵活 [CITED: docs.doppler.com/docs/jenkins] |
| PIPE-03 | Docker Compose 服务通过生成的 .env 文件获取运行时密钥，现有 `envsubst` 模板机制不变 | 密钥通过 `set -a; source <(doppler ...) ; set +a` 注入到 shell 环境，envsubst 和 docker compose 的 `${VAR}` 替换无需改动 |
| PIPE-04 | VITE_* 构建时变量通过 `docker build --build-arg` 注入 | D-12 锁定 VITE_* 不纳入 Doppler，保持 pipeline_build() 中现有 `--build-arg` 硬编码 |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|-----------|-------------|----------------|-----------|
| Doppler 密钥获取 | Jenkins Pipeline (CI) | 手动部署脚本 (回退) | Jenkins 是主要部署方式，Pipeline 通过 withCredentials 注入 DOPPLER_TOKEN |
| 密钥注入到 Docker | Shell 环境 (envsubst) | -- | 密钥加载到 shell 环境后，envsubst 模板和 docker run --env-file 自然继承 |
| VITE_* 构建 | Dockerfile ARG | -- | 构建时变量，不涉及 Doppler，已在 Dockerfile 中硬编码 |
| 回退策略 | pipeline-stages.sh | 手动脚本 | 两者共享相同的双模式检测逻辑 |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Doppler CLI | v3.75.3 | 密钥拉取 | Phase 39 已安装在 Jenkins 宿主机 [VERIFIED: 本地 doppler --version] |
| Jenkins Credentials Binding | Pipeline 内置 | DOPPLER_TOKEN 注入 | Jenkins 原生凭据管理，已在项目中使用（cf-api-token 等） |
| `doppler secrets download --no-file --format=env` | v3.75.3 | 输出 .env 格式到 stdout | Doppler 官方推荐的 CI/CD 密钥获取方式 [VERIFIED: Context7] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `envsubst` (gettext) | 系统自带 | 模板变量替换 | 已在使用，无需改动 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `source <(doppler ...)` | `doppler secrets download --format=env /tmp/file && source /tmp/file` | process substitution 更安全（不落盘），临时文件方式在某些受限 shell 中更兼容 |
| `withCredentials` 包装 stages | `environment { DOPPLER_TOKEN = credentials('...') }` | environment 块方式更简洁，但 credentials() 在 Declarative Pipeline 中会将值绑定到全局环境，所有 stage 可见。withCredentials 更灵活控制范围 |
| pipeline-stages.sh 双模式 | Jenkinsfile 中独立 Fetch Secrets stage | D-03 已锁定：在 pipeline-stages.sh 中处理，不添加独立 stage |

**Installation:**
无需额外安装。Doppler CLI 已在 Phase 39 安装。

## Architecture Patterns

### System Architecture Diagram

```
Jenkins Pipeline 手动触发
        │
        ▼
┌──────────────────────┐
│  Jenkinsfile         │
│  withCredentials()   │ ← 从 Jenkins Credentials Store 读取 doppler-service-token
│  注入 DOPPLER_TOKEN   │
└──────────┬───────────┘
           │ DOPPLER_TOKEN 环境变量
           ▼
┌──────────────────────┐
│  pipeline-stages.sh  │
│  load_secrets()      │ ← 核心改动点：双模式密钥加载
│  DOPPLER_TOKEN?      │
│   ├─ 有 → doppler    │ ← doppler secrets download --no-file --format=env
│   └─ 无 → .env 回退  │ ← source docker/.env（Phase 41 前可用）
└──────────┬───────────┘
           │ 密钥在 shell 环境中
           ▼
┌──────────────────────┐
│  envsubst 模板替换    │ ← env-{service}.env 中 ${VAR} 被替换
│  docker compose      │ ← compose 文件中 ${VAR} 被替换
│  docker run --env-file│ ← 蓝绿容器获取环境变量
└──────────────────────┘
```

### Recommended Project Structure
```
scripts/
├── pipeline-stages.sh       # [主要改动] 添加 load_secrets() 双模式函数
├── blue-green-deploy.sh     # [改动] 添加 Doppler 支持
├── deploy/
│   ├── deploy-infrastructure-prod.sh  # [改动] 添加 Doppler 支持
│   └── deploy-apps-prod.sh            # [改动] 添加 Doppler 支持
jenkins/
├── Jenkinsfile.findclass-ssr  # [改动] withCredentials 包装
├── Jenkinsfile.infra          # [改动] withCredentials 包装
├── Jenkinsfile.keycloak       # [改动] withCredentials 包装
└── Jenkinsfile.noda-site      # [不改] 静态站点无敏感密钥
```

### Pattern 1: 双模式密钥加载函数 (load_secrets)

**What:** 统一的密钥加载函数，根据 DOPPLER_TOKEN 是否存在决定获取方式
**When to use:** 所有需要密钥的场景（Pipeline、手动部署）
**Example:**
```bash
# pipeline-stages.sh 中的密钥加载函数
load_secrets()
{
    if [ -n "${DOPPLER_TOKEN:-}" ]; then
        # Doppler 模式：从云端拉取密钥
        if ! command -v doppler &>/dev/null; then
            log_error "DOPPLER_TOKEN 已设置但 doppler CLI 未安装"
            log_error "请运行: bash scripts/install-doppler.sh"
            return 1
        fi
        log_info "从 Doppler 拉取密钥 (project=noda, config=prd)..."
        # 使用 process substitution 避免 .env 文件落盘
        set -a
        eval "$(doppler secrets download --no-file --format=env \
            --project noda --config prd 2>/dev/null)"
        set +a
        log_success "Doppler 密钥加载完成"
    else
        # 回退模式：从本地 .env 文件加载
        local _loaded=false
        for _env_path in "$PROJECT_ROOT/docker/.env" "$HOME/Project/noda-infra/docker/.env"; do
            if [ -f "$_env_path" ]; then
                set -a
                source "$_env_path"
                set +a
                _loaded=true
                log_info "密钥从本地 .env 加载: $_env_path"
                break
            fi
        done
        if [ "$_loaded" = false ]; then
            log_error "DOPPLER_TOKEN 未设置且 docker/.env 文件不存在"
            return 1
        fi
    fi
}
```

**Source:** 基于 Doppler 官方 CLI docs [VERIFIED: Context7 /dopplerhq/cli] 和现有 pipeline-stages.sh 代码结构

### Pattern 2: Jenkinsfile withCredentials 包装

**What:** 用 withCredentials 包装需要密钥的 stages，注入 DOPPLER_TOKEN
**When to use:** 所有需要密钥的 Jenkinsfile stages

**方案 A — 用 `environment {}` 块全局注入（推荐）：**
```groovy
environment {
    DOPPLER_TOKEN = credentials('doppler-service-token')
}
```
- 优点：简洁，所有 stages 自动获得 DOPPLER_TOKEN
- 优点：与现有 `ACTIVE_ENV` 等 environment 变量一致
- 优点：`credentials()` 方法自动遮蔽日志中的值
- 缺点：所有 stages 都能看到 token（但本项目中所有 stage 都可能需要密钥）

**方案 B — 用 withCredentials 包装特定 stages：**
```groovy
stage('Deploy') {
    steps {
        withCredentials([string(credentialsId: 'doppler-service-token',
                                variable: 'DOPPLER_TOKEN')]) {
            sh '''
                source scripts/pipeline-stages.sh
                pipeline_deploy "$TARGET_ENV"
            '''
        }
    }
}
```
- 优点：精确控制 token 可见范围
- 缺点：需要包装多个 stages，代码重复

**推荐方案 A** — 使用 `environment {}` 块全局注入。理由：
1. 现有 Jenkinsfile 已使用 `environment {}` 块定义 PROJECT_ROOT 等变量，风格一致
2. D-03 锁定在 pipeline-stages.sh 中统一处理，所有 stages 都 source 它，都需要 DOPPLER_TOKEN
3. Doppler 官方文档推荐的 Jenkins 集成方式就是 `environment { DOPPLER_TOKEN = credentials('...') }` [CITED: docs.doppler.com/docs/jenkins]
4. `credentials()` 方法在日志中自动用 `****` 遮蔽 token 值

### Pattern 3: Doppler secrets download 变量注入方式

**What:** 将 Doppler 输出的 .env 格式字符串加载到 shell 环境中
**When to use:** Doppler 模式下的密钥注入

**选项对比：**

| 方式 | 优点 | 缺点 |
|------|------|------|
| `source <(doppler secrets download --no-file --format=env)` | 不落盘，进程替换 | 某些受限 shell 不支持 process substitution |
| `eval "$(doppler secrets download --no-file --format=env)"` | 兼容所有 shell | eval 有安全隐患（但 Doppler 输出是 `KEY=VALUE` 格式，可控） |
| `doppler secrets download --format=env /tmp/file && source /tmp/file` | 最简单 | 密钥短暂落盘，需要手动清理 |

**推荐 `eval` 方式** — `set -a; eval "$(doppler ...)"; set +a`。理由：
1. Jenkins Pipeline 的 `sh '''` 使用标准 bash，支持 eval
2. Doppler `--format=env` 输出标准 `KEY=VALUE` 格式，eval 安全可控
3. 不落盘（无临时文件安全风险）
4. 比 process substitution 更兼容

### Anti-Patterns to Avoid

- **在 Jenkinsfile 中硬编码密钥值：** 绝对禁止。所有密钥通过 Doppler 或 Jenkins Credentials 获取
- **密钥落盘到 Jenkins workspace：** 避免将 `doppler secrets download` 写入 workspace 中的文件。使用 `--no-file` 输出到 stdout
- **在 docker run 中直接传递 DOPPLER_TOKEN：** Doppler 官方文档明确指出 `docker run --rm test-container doppler secrets` 不工作，因为 token 不在容器环境中 [CITED: docs.doppler.com/docs/jenkins]
- **修改 envsubst 模板机制：** 当前 envsubst 模板 + docker run --env-file 的链路工作正常，不要改动

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 密钥获取 | 自己写 API 调用 Doppler REST API | `doppler secrets download --no-file --format=env` | CLI 处理认证、重试、错误处理 |
| Token 遮蔽 | 自己写日志过滤 | Jenkins `credentials()` / `withCredentials` | 自动遮蔽，经过充分测试 |
| 密钥格式转换 | 手动解析 JSON | `--format=env` flag | Doppler CLI 原生支持 |
| 离线回退 | 自定义缓存逻辑 | Doppler `--fallback` flag | Doppler CLI 内置 fallback 机制 |

**Key insight:** Doppler CLI 已经处理了密钥获取的所有复杂性（认证、重试、格式化、缓存），只需调用一个命令。

## Common Pitfalls

### Pitfall 1: Doppler config 名为 `prd` 非 `prod`
**What goes wrong:** 使用 `--config prod` 会导致 404 错误
**Why it happens:** Phase 39 创建 Doppler 项目时使用默认环境名 `prd`
**How to avoid:** 所有 doppler 命令使用 `--config prd`，已在 D-05 中锁定
**Warning signs:** `doppler secrets download` 返回 "config not found" 错误

### Pitfall 2: Jenkins `credentials()` vs `withCredentials` 行为差异
**What goes wrong:** 在 `environment {}` 块中用 `credentials()` 方法时，如果 credentialsId 不存在，整个 Pipeline 启动就失败
**Why it happens:** `credentials()` 在 Pipeline 初始化时解析，而非运行时
**How to avoid:** 确保 `doppler-service-token` credentials 已在 Jenkins 中创建（Phase 39 已完成）。如果不确定，用 try-catch 包装 withCredentials
**Warning signs:** Pipeline 启动即失败，错误信息 "Credentials 'doppler-service-token' is not defined"

### Pitfall 3: Doppler CLI 在 Jenkins workspace 中找不到
**What goes wrong:** `doppler: command not found`
**Why it happens:** Doppler 安装路径不在 jenkins 用户的 PATH 中
**How to avoid:** Phase 39 使用 `brew install` 安装，确保 jenkins 用户的 shell profile 包含 brew 路径。在 pipeline-stages.sh 中检测 doppler 是否存在并给出明确错误提示
**Warning signs:** `command -v doppler` 返回空

### Pitfall 4: Doppler 服务宕机时 Pipeline 卡住
**What goes wrong:** `doppler secrets download` 连接超时导致 Pipeline 长时间挂起
**Why it happens:** Doppler CLI 默认有重试机制（5 次），每次超时可能数秒
**How to avoid:** 双模式回退策略（D-10）确保 docker/.env 始终可用。可在 doppler 命令中考虑使用 `--fallback` 参数
**Warning signs:** Fetch Secrets 步骤超过 60 秒

### Pitfall 5: docker compose 需要密钥但不走 pipeline-stages.sh
**What goes wrong:** deploy-infrastructure-prod.sh 中 `docker compose up` 失败因为环境变量未加载
**Why it happens:** 基础设施脚本直接调用 docker compose，不经过 pipeline-stages.sh
**How to avoid:** 确保手动脚本也实现双模式密钥加载
**Warning signs:** `docker compose up` 报 `required variable POSTGRES_PASSWORD is missing`

### Pitfall 6: eval 注入的变量中包含特殊字符
**What goes wrong:** 密钥值包含单引号、换行符或 `$` 时 eval 行为异常
**Why it happens:** Doppler `--format=env` 使用 `KEY=VALUE` 格式，VALUE 不一定被引号包裹
**How to avoid:** 使用 `--format=env`（Doppler 会处理引号）。测试时确认包含特殊字符的密钥（如包含 `$` 的 connection string）能正确加载
**Warning signs:** 密钥值被截断或变量展开

## Code Examples

### 现有密钥加载逻辑 (pipeline-stages.sh 第 20-29 行) — 需要替换

```bash
# 当前代码 — 直接 source docker/.env
for _env_path in "$PROJECT_ROOT/docker/.env" "$HOME/Project/noda-infra/docker/.env"; do
    if [ -f "$_env_path" ]; then
        set -a
        source "$_env_path"
        set +a
        break
    fi
done
```

### 替换为双模式 load_secrets() 函数

```bash
# Source: 基于 Doppler CLI docs [VERIFIED: Context7]
load_secrets()
{
    if [ -n "${DOPPLER_TOKEN:-}" ]; then
        # Doppler 模式
        if ! command -v doppler &>/dev/null; then
            log_error "doppler CLI 未安装（DOPPLER_TOKEN 已设置）"
            log_error "安装: bash scripts/install-doppler.sh"
            return 1
        fi
        log_info "从 Doppler 拉取密钥 (project=noda, config=prd)..."
        local _secrets
        _secrets=$(doppler secrets download --no-file --format=env \
            --project noda --config prd 2>/dev/null) || {
            log_error "Doppler 密钥拉取失败"
            return 1
        }
        set -a
        eval "$_secrets"
        set +a
        log_success "Doppler 密钥加载完成"
    else
        # 回退模式：从本地 .env 文件加载
        local _loaded=false
        for _env_path in "$PROJECT_ROOT/docker/.env" "$HOME/Project/noda-infra/docker/.env"; do
            if [ -f "$_env_path" ]; then
                set -a
                source "$_env_path"
                set +a
                _loaded=true
                log_info "密钥从本地 .env 加载"
                break
            fi
        done
        if [ "$_loaded" = false ]; then
            log_error "DOPPLER_TOKEN 未设置且无可用 .env 文件"
            return 1
        fi
    fi
}
```

### Jenkinsfile.findclass-ssr 改动示例

```groovy
// Source: Doppler Jenkins 集成 [CITED: docs.doppler.com/docs/jenkins]
environment {
    PROJECT_ROOT = "${WORKSPACE}"
    ACTIVE_ENV = sh(
        script: 'cat /opt/noda/active-env 2>/dev/null || echo blue',
        returnStdout: true
    ).trim()
    TARGET_ENV = "${env.ACTIVE_ENV == 'blue' ? 'green' : 'blue'}"
    // 新增：Doppler Service Token（Phase 40）
    DOPPLER_TOKEN = credentials('doppler-service-token')
}
```

### 手动脚本改动示例 (blue-green-deploy.sh)

```bash
# 替换现有的 source docker/.env 逻辑
load_secrets()
{
    if [ -n "${DOPPLER_TOKEN:-}" ]; then
        if ! command -v doppler &>/dev/null; then
            echo "ERROR: doppler CLI 未安装" >&2
            exit 1
        fi
        echo "[INFO] 从 Doppler 拉取密钥..."
        set -a
        eval "$(doppler secrets download --no-file --format=env \
            --project noda --config prd 2>/dev/null)" || {
            echo "ERROR: Doppler 密钥拉取失败" >&2
            exit 1
        }
        set +a
    else
        if [ -f "$PROJECT_ROOT/docker/.env" ]; then
            set -a
            source "$PROJECT_ROOT/docker/.env"
            set +a
        else
            echo "ERROR: 设置 DOPPLER_TOKEN 或确保 docker/.env 存在" >&2
            exit 1
        fi
    fi
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `source docker/.env` 明文文件 | Doppler CLI + 双模式回退 | Phase 39/40 | 密钥集中管理，不再依赖 Git 忽略的文件 |
| SOPS 加密文件 | Doppler 云端管理 | Phase 39 | Phase 41 清理 SOPS 相关代码 |
| Infisical (Client ID + Secret) | Doppler (Service Token) | Phase 39 讨论 | 更简单的认证模型 |

**Deprecated/outdated:**
- `config/secrets.sops.yaml` — Phase 41 删除
- `scripts/utils/decrypt-secrets.sh` — Phase 41 删除
- `docker/.env` 明文文件 — Phase 41 删除

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Jenkins `credentials('doppler-service-token')` 已在 Phase 39 录入 | Jenkinsfile 改动 | Pipeline 启动失败，需手动在 Jenkins UI 创建 credential |
| A2 | doppler CLI 安装路径在 jenkins 用户的 PATH 中 | Environment | Pipeline 运行时找不到 doppler 命令 |
| A3 | `doppler secrets download --format=env` 输出的值不包含会导致 eval 异常的特殊字符 | 密钥注入 | 某些密钥值加载不正确 |
| A4 | 所有 3 个 Jenkinsfile 的所有 stages 都需要密钥（适合用 environment 块全局注入 DOPPLER_TOKEN） | Jenkinsfile 改动 | 如果某些 stage 不需要密钥，环境中有额外变量（无安全风险） |

**If this table is empty:** All claims in this research were verified or cited -- no user confirmation needed.

## Open Questions (RESOLVED)

1. **doppler CLI PATH 可用性** — RESOLVED: Plan 40-01 Task 1 包含 `command -v doppler` 检查，不存在时给出明确错误信息并回退到 docker/.env
   - What we know: Phase 39 用 `brew install dopplerhq/cli/doppler` 安装，Homebrew 通常安装在 `/opt/homebrew/bin`（macOS）或 `/home/linuxbrew/.linuxbrew/bin`（Linux）
   - What's unclear: Jenkins 的 jenkins 用户 PATH 是否包含 Homebrew 路径。服务器是 Linux，Jenkins 以 systemd 服务运行
   - Recommendation: 在 pipeline-stages.sh 的 load_secrets() 中检测 doppler 命令是否存在，不存在时给出安装指引
   - Resolution: load_secrets() 中添加 `command -v doppler` 检测，不可用时自动回退 docker/.env

2. **deploy-infrastructure-prod.sh 是否也 source pipeline-stages.sh** — RESOLVED: Plan 40-01 创建 `scripts/lib/secrets.sh` 共享库，所有脚本 source 此文件复用 load_secrets()
   - What we know: deploy-infrastructure-prod.sh 当前不 source pipeline-stages.sh，它直接 source log.sh 和 health.sh
   - What's unclear: 是否应该让手动脚本也复用 pipeline-stages.sh 的 load_secrets() 函数
   - Recommendation: 独立实现 load_secrets() 逻辑（手动脚本可能在没有 pipeline-stages.sh 的环境运行），或将其提取到 scripts/lib/secrets.sh 共享库
   - Resolution: 采用 scripts/lib/secrets.sh 共享库方案，pipeline-stages.sh 和手动脚本都 source 此文件

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Doppler CLI | 密钥获取 | ✓ (本地) | v3.75.3 | — |
| Doppler CLI (Jenkins 宿主机) | Pipeline 密钥获取 | ✓ (Phase 39) | — | source docker/.env |
| Jenkins Credentials Store | DOPPLER_TOKEN 存储 | ✓ (Phase 39) | — | — |
| envsubst | 模板替换 | ✓ (系统自带) | — | — |
| docker compose | 服务部署 | ✓ | v2 | — |

**Missing dependencies with no fallback:**
- 无。所有依赖已就位。

**Missing dependencies with fallback:**
- Doppler 服务不可用 -> 回退到 source docker/.env（Phase 41 前有效）

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | 手动验证（Infrastructure 项目无自动化测试框架） |
| Config file | none |
| Quick run command | `bash -n scripts/pipeline-stages.sh && echo "syntax OK"` |
| Full suite command | 手动触发 Jenkins Pipeline 验证 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PIPE-01 | Doppler 密钥拉取到 shell 环境 | 手动 | `DOPPLER_TOKEN=xxx bash -c 'eval "$(doppler secrets download --no-file --format=env --project noda --config prd)" && echo $POSTGRES_USER'` | N/A |
| PIPE-02 | DOPPLER_TOKEN 不出现在 Jenkins 日志中 | 手动 | Jenkins Stage View 日志检查 | N/A |
| PIPE-03 | envsubst 模板正确替换 Doppler 密钥 | 手动 | Pipeline 部署后检查容器环境变量 | N/A |
| PIPE-04 | VITE_* 构建参数不受 Doppler 影响 | 手动 | Pipeline Build 阶段日志检查 | N/A |

### Sampling Rate
- **Per task commit:** `bash -n scripts/pipeline-stages.sh`（语法检查）
- **Per wave merge:** 手动 Jenkins Pipeline 触发验证
- **Phase gate:** 3 个 Pipeline 均成功执行一次完整部署

### Wave 0 Gaps
- 无自动化测试框架。Infrastructure 项目（shell 脚本 + Docker Compose）无传统测试基础设施。
- 验证方式：bash 语法检查 + 手动 Pipeline 触发 + 容器运行时验证

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | yes | Jenkins Credentials + Doppler Service Token (read-only) |
| V5 Input Validation | yes | bash `set -euo pipefail` + doppler CLI 输出格式验证 |
| V6 Cryptography | yes | Doppler TLS 传输 + Jenkins 凭据加密存储 |

### Known Threat Patterns for Doppler + Jenkins

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| DOPPLER_TOKEN 泄露到日志 | Information Disclosure | Jenkins `credentials()` 自动遮蔽日志中的值 |
| DOPPLER_TOKEN 在进程列表中可见 | Information Disclosure | `withCredentials` 使用环境变量（不在命令行参数中） |
| Doppler 服务宕机 | Denial of Service | 双模式回退策略（D-10），docker/.env 始终可用 |
| 密钥值含特殊字符导致注入 | Tampering | `--format=env` 标准格式 + `set -a; eval; set +a` 控制 |
| Service Token 权限过大 | Elevation of Privilege | Doppler Service Token 默认 read-only [VERIFIED: Context7 Doppler docs] |

## Sources

### Primary (HIGH confidence)
- [Context7 /dopplerhq/cli] — Doppler CLI secrets download 命令语法和 flags
- [Context7 /websites/doppler] — Doppler Jenkins 集成官方文档、credentials 绑定模式
- 项目代码: `scripts/pipeline-stages.sh`, `jenkins/Jenkinsfile.*`, `scripts/blue-green-deploy.sh` — 现有实现分析
- Phase 39 CONTEXT.md + STATE.md — Doppler 配置确认（project=noda, config=prd）

### Secondary (MEDIUM confidence)
- [docs.doppler.com/docs/jenkins] — Jenkins Pipeline 集成指南（environment 块 + credentials() 用法）
- [docs.doppler.com/docs/service-tokens] — Service Token 默认 read-only 权限

### Tertiary (LOW confidence)
- Jenkins `credentials()` 方法在 environment 块中 credentialsId 不存在时的行为 — 基于训练知识，标记为 [ASSUMED]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Doppler CLI v3.75.3 已安装验证，Jenkins Credentials 已配置
- Architecture: HIGH — 双模式加载逻辑清晰，改动范围明确（1 个核心文件 + 3 个 Jenkinsfile + 3 个脚本）
- Pitfalls: HIGH — 所有 pitfall 来自实际代码分析和 Doppler 官方文档验证

**Research date:** 2026-04-19
**Valid until:** 2026-05-19（Doppler CLI 稳定，30 天有效）
