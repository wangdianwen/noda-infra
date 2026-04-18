# Domain Pitfalls: Shell 基础设施脚本精简重构

**Domain:** noda-infra 项目 v1.7 代码精简与规整 -- 合并重复库文件、蓝绿部署脚本、清理一次性脚本、精简大文件
**Researched:** 2026-04-18
**Confidence:** HIGH（基于完整代码库审计，逐文件比对重复代码；Shell 脚本行为确定性高，不需要外部文档验证）

---

## Critical Pitfalls

### Pitfall 1: 合并 log.sh 后破坏备份系统 -- 两个 log.sh 接口不兼容

**What goes wrong:**
`scripts/lib/log.sh`（30 行）和 `scripts/backup/lib/log.sh`（87 行）看起来是"重复的日志库"，但实际上接口和功能完全不同：

| 特性 | scripts/lib/log.sh | scripts/backup/lib/log.sh |
|------|-------------------|--------------------------|
| 颜色支持 | `echo -e` 带 ANSI 颜色码 | 纯文本，无颜色 |
| `set -euo pipefail` | 无（调用者控制） | 有（第 9 行） |
| 额外函数 | 无 | `log_progress()`, `log_json()`, `log_structured()` |
| 调用方数量 | 26 个脚本 | 8 个 backup 脚本 + 3 个测试脚本 |

如果粗暴合并为一个 log.sh，会导致：
1. 备份系统调用 `log_progress()` 和 `log_structured()` 时函数不存在
2. `set -euo pipefail` 在库文件中的语义不同 -- 被其他脚本 `source` 时会影响调用者的错误处理行为
3. ANSI 颜色码在 cron 日志或 systemd journal 中显示为乱码

**Why it happens:**
两个 log.sh 的函数名完全相同（`log_info`, `log_warn`, `log_error`, `log_success`），让人误以为可以直接替换。但 backup 版本不使用颜色是因为它在 noda-ops 容器内运行（cron 触发），颜色码会污染日志文件。

**Consequences:**
- 备份脚本崩溃（`log_progress: command not found`），备份系统停摆
- 生产数据库失去定时备份保护
- Core Value "数据库永不丢失" 受到威胁

**Prevention:**
1. **不要合并两个 log.sh** -- 它们服务于不同的运行环境（宿主机 vs 容器内）
2. 如果一定要统一，backup 的 log.sh 应该是 lib/log.sh 的"无颜色超集"，但 `set -euo pipefail` 必须放在调用者而不是库文件中
3. 合并后必须运行 `scripts/backup/tests/test_backup.sh` 验证

**Detection:**
- `grep -r 'log_progress\|log_json\|log_structured' scripts/backup/` -- 如果合并后这三个函数不在统一库中，就会出问题

---

### Pitfall 2: 合并 health.sh 后 readonly 变量冲突导致脚本崩溃

**What goes wrong:**
`scripts/lib/health.sh`（69 行）只提供 `wait_container_healthy()` 函数。
`scripts/backup/lib/health.sh`（359 行）提供 `check_postgres_connection()`, `check_disk_space()`, `check_prerequisites()` 等函数，并且内部依赖 `constants.sh` 的 readonly 变量。

`scripts/backup/lib/constants.sh` 定义了大量 readonly 变量：
```bash
readonly EXIT_SUCCESS=0
readonly EXIT_CONNECTION_FAILED=1
readonly EXIT_BACKUP_FAILED=2
# ... 14 个 readonly 变量
```

如果合并 health.sh 且让备份脚本同时 source 统一的 health.sh，会触发 bash 的 readonly 重复定义错误：
```
bash: EXIT_SUCCESS: readonly variable
```

**Why it happens:**
- backup/lib/health.sh 第 20-23 行已经有条件加载逻辑来防止这个问题：
  ```bash
  if [[ -z "${EXIT_SUCCESS+x}" ]]; then
    source "$_HEALTH_LIB_DIR/constants.sh"
  fi
  ```
- 这个防御模式在合并后可能被意外删除
- 部署脚本（`deploy-*.sh`）先 source `lib/log.sh`，再 source `lib/health.sh`，但 backup 脚本的 source 链完全不同

**Consequences:**
- 备份脚本执行到 source 行时立即崩溃
- 由于 backup 是 cron 定时任务，错误不会立即被发现
- 可能长达 12 小时没有备份

**Prevention:**
1. 不要合并 `scripts/lib/health.sh` 和 `scripts/backup/lib/health.sh` -- 它们解决完全不同的问题（容器健康检查 vs 数据库连接+磁盘空间检查）
2. 如果一定要统一命名，让 backup/lib/ 保留独立的库名（如 `backup-health.sh`），避免路径冲突
3. 任何涉及 `readonly` 的 source 操作都必须保留条件加载模式

**Detection:**
- `shellcheck` 检测不到这种运行时冲突（readonly 是 bash 运行时特性）
- 必须手动测试：`bash -c 'source constants.sh; source constants.sh'` -- 如果输出 "readonly variable" 就有问题

---

### Pitfall 3: 蓝绿部署脚本合并时丢失 findclass-ssr 的硬编码 URL

**What goes wrong:**
`scripts/blue-green-deploy.sh`（297 行）和 `scripts/keycloak-blue-green-deploy.sh`（297 行）结构几乎相同（7 步流程），但有细微差异：

| 差异点 | blue-green-deploy.sh | keycloak-blue-green-deploy.sh |
|--------|---------------------|-------------------------------|
| 步骤 1 | 构建镜像（`docker compose build`） | 拉取镜像（`docker pull`） |
| 健康检查 URL | `http://localhost:3001/api/health`（硬编码） | `http://localhost:${SERVICE_PORT}${HEALTH_PATH}`（参数化） |
| E2E 验证 URL | `http://${container_name}:3001/api/health`（硬编码） | `http://${container_name}:${SERVICE_PORT}${HEALTH_PATH}`（参数化） |
| 镜像清理 | 保留最近 N 个 SHA 标签 | 清理 dangling images |
| 额外步骤 | 无 | Compose 容器迁移检测（第 203-211 行） |

如果合并为一个参数化脚本，findclass-ssr 的硬编码 URL `3001/api/health` 必须被正确替换为 `${SERVICE_PORT}${HEALTH_PATH}`。但 manage-containers.sh 的默认值已经设置为 `SERVICE_PORT=3001` 和 `HEALTH_PATH=/api/health`，所以看起来没有问题。

**真正的风险**在于：blue-green-deploy.sh 的 `http_health_check()` 使用 `docker exec` 在**目标容器内部**执行 wget：
```bash
docker exec "$container" wget ... "http://localhost:3001/api/health"
```
而 keycloak-blue-green-deploy.sh 也用同样的模式但端口不同：
```bash
docker exec "$container" wget ... "http://localhost:${SERVICE_PORT}${HEALTH_PATH}"
```
pipeline-stages.sh 的 `http_health_check()` 却通过 **nginx 容器**执行 wget：
```bash
docker exec "$NGINX_CONTAINER" wget ... "http://${container}:${SERVICE_PORT}${HEALTH_PATH}"
```

三处 `http_health_check()` 实现的**执行上下文**不同（目标容器内部 vs nginx 容器），合并时必须保留这个区别。

**Consequences:**
- 健康检查失败导致部署被中止（新容器被认为不健康）
- 或更糟：健康检查通过了但 E2E 验证失败（因为 URL 错误但刚好返回了 200）

**Prevention:**
1. 合并前必须明确区分三种健康检查模式：容器内部检查 vs nginx 代理检查
2. 参数化时不只是替换端口号，还要保留执行上下文的差异
3. 合并后必须对 findclass-ssr 和 keycloak 各做一次完整的蓝绿部署测试

**Detection:**
- 在测试环境运行 `bash scripts/blue-green-deploy.sh .` 验证合并后的脚本
- 检查 Jenkins Stage View 确认 Health Check 和 E2E Verify 阶段通过

---

### Pitfall 4: 删除 verify-* 脚本后丧失环境验证能力

**What goes wrong:**
scripts/verify/ 目录下有 5 个验证脚本：
- `verify-apps.sh`
- `verify-infrastructure.sh`
- `verify-services.sh`
- `verify-findclass.sh`
- `quick-verify.sh`

这些脚本看起来是"一次性验证脚本"，可能在某个里程碑中创建后就不再使用。但如果删除后发现它们被 Jenkinsfile、cron 任务或部署后验证流程引用，就无法恢复（除非 git revert）。

**Why it happens:**
- `grep` 搜索 `source.*verify` 或 `bash.*verify` 可能找不到间接调用（如通过变量 `$VERIFY_SCRIPT` 调用）
- 验证脚本可能在故障排查时被运维人员手动执行，grep 搜不到人类习惯

**Consequences:**
- 下次部署出问题时没有快速验证脚本可用
- 需要重新编写验证逻辑，浪费时间

**Prevention:**
1. **先标记为废弃，不直接删除**：在文件头部添加 `# DEPRECATED: 此脚本不再使用，将在 v1.8 删除`
2. 等一个完整的里程碑周期后再确认无人使用
3. 确保核心验证逻辑已存在于 `pipeline-stages.sh` 的 `pipeline_verify()` 和 `pipeline_infra_verify()` 中

**Detection:**
- `grep -r 'verify-apps\|verify-infrastructure\|verify-services\|verify-findclass\|quick-verify' . --include='*.sh' --include='*.groovy' --include='Jenkinsfile*'` -- 搜索所有引用

---

### Pitfall 5: 精简 pipeline-stages.sh 时破坏 Jenkins Pipeline 阶段函数签名

**What goes wrong:**
`pipeline-stages.sh`（1109 行）是整个 Jenkins Pipeline 的核心函数库。Jenkinsfile 中通过 `sh` 步骤调用这些函数：
```groovy
// Jenkinsfile 中的调用方式
sh "source scripts/pipeline-stages.sh && pipeline_preflight '${APPS_DIR}'"
sh "source scripts/pipeline-stages.sh && pipeline_build '${APPS_DIR}' '${GIT_SHA}'"
```

如果精简时修改了函数名（如 `pipeline_preflight` 改为 `preflight`）或参数签名（如添加了新参数），Jenkinsfile 中的调用不会报编译错误 -- 它们是字符串拼接的 shell 命令，只在运行时才会失败。

**Why it happens:**
- Jenkinsfile 的 `sh` 步骤是字符串拼接，没有类型检查
- 函数签名变更不会触发任何编译时错误
- Jenkins Pipeline 测试需要实际运行，不能简单 `bash -n` 检查

**Consequences:**
- 部署 Pipeline 在运行时崩溃
- 如果是 `pipeline_switch` 或 `pipeline_cleanup` 失败，可能导致服务停机

**Prevention:**
1. **任何 pipeline_* 函数的重命名必须同步修改 Jenkinsfile**
2. 精简前先 `grep 'pipeline_' Jenkinsfile*` 列出所有引用
3. 精简后在测试环境触发一次完整的 Pipeline 运行
4. 保留旧函数名作为废弃别名（wrapper），废弃一个版本周期后再删除

**Detection:**
- `grep -n 'pipeline_' Jenkinsfile Jenkinsfile.* scripts/pipeline-stages.sh` -- 交叉对比调用点
- 在 Jenkinsfile 中搜索所有 `sh "...pipeline_..."` 模式

---

## Moderate Pitfalls

### Pitfall 6: source 链断裂 -- manage-containers.sh 被合并或移动后 6 个调用方崩溃

**What goes wrong:**
`manage-containers.sh` 被 6 个脚本通过 `source` 加载：
- `blue-green-deploy.sh`
- `keycloak-blue-green-deploy.sh`
- `rollback-findclass.sh`
- `pipeline-stages.sh`
- `setup-jenkins-pipeline.sh`
- `prepare-jenkins-pipeline.sh`

它同时支持两种模式：
1. **直接执行**（带 source guard：`BASH_SOURCE[0] == ${0}`）-- 子命令分发
2. **被 source** -- 仅加载函数，不执行任何命令

如果合并或移动这个文件，所有 6 个调用方的 `source` 路径都会断裂。

**Prevention:**
1. 如果移动文件，在旧位置创建兼容 wrapper：`source "$PROJECT_ROOT/scripts/new-location.sh"`
2. 如果拆分文件，保留 `manage-containers.sh` 作为聚合入口，source 所有拆分后的文件
3. `grep -r 'source.*manage-containers' scripts/` 确认所有调用方已更新

### Pitfall 7: 合并 http_health_check 和 e2e_verify 的三处重复定义时丢失行为差异

**What goes wrong:**
这三个函数在 4 个文件中有不同的实现细节：

| 位置 | http_health_check 执行方式 | 默认重试 |
|------|--------------------------|---------|
| blue-green-deploy.sh | `docker exec $container wget localhost:3001` | 30x4s |
| keycloak-blue-green-deploy.sh | `docker exec $container wget localhost:${SERVICE_PORT}` | 45x4s |
| rollback-findclass.sh | `docker exec $container wget localhost:3001` | 10x3s |
| pipeline-stages.sh | `docker exec $NGINX_CONTAINER wget $container:${SERVICE_PORT}` | 30x4s |

关键差异：
- **执行容器不同**：前三个在目标容器内执行，pipeline-stages.sh 在 nginx 容器内执行
- **回滚脚本的重试更激进**：10x3s = 30s（紧急恢复要快），而不是 30x4s = 120s
- **Keycloak 的超时更长**：45x4s = 180s（Java 启动慢）

如果粗暴合并为一个函数，这些差异会被抹平。

**Prevention:**
1. 参数化所有差异点：执行容器、重试次数、间隔时间、URL 模板
2. 每个调用方必须明确传递自己的参数，不依赖默认值
3. 回滚脚本的特殊参数（快速重试）必须在调用处显式指定

### Pitfall 8: backup 子系统 set -euo pipefail 语义差异

**What goes wrong:**
backup/ 目录下的库文件（lib/*.sh）全部在文件头部有 `set -euo pipefail`。当这些文件被 `source` 到主脚本中时，`pipefail` 的行为会影响主脚本的所有管道命令。

而 scripts/ 目录下的 lib 文件（log.sh, health.sh）**没有** `set -euo pipefail`，依赖调用者自己设置。

如果合并 backup/lib/ 文件到 scripts/lib/，需要统一 `set -euo pipefail` 的策略。

**Prevention:**
1. 库文件中不应该有 `set -euo pipefail` -- 这个设置应该由入口脚本（被直接执行的脚本）控制
2. 合并时移除 backup/lib/*.sh 文件头部的 `set -euo pipefail`
3. 确保所有 backup 入口脚本（backup-postgres.sh, restore-postgres.sh）自己有 `set -euo pipefail`

### Pitfall 9: deploy-findclass-zero-deps.sh 可能被删除但仍有用途

**What goes wrong:**
`scripts/deploy/deploy-findclass-zero-deps.sh` 看起来是早期版本的部署脚本，但可能在某些场景下仍然有用（如无 Jenkins 的最小部署环境）。

**Prevention:**
1. 在删除前搜索 Jenkinsfile 和文档中的引用
2. 确认 deploy-apps-prod.sh 已完全覆盖其功能
3. 如不确定，标记为废弃而不是删除

### Pitfall 10: 精简 setup-jenkins.sh 时丢失 groovy 自动化脚本引用

**What goes wrong:**
`setup-jenkins.sh` 引用了外部 groovy 脚本和配置文件：
- `GROOVY_SRC_DIR="$SCRIPT_DIR/jenkins/init.groovy.d"`（第 39 行）
- `ADMIN_ENV_TEMPLATE="$SCRIPT_DIR/jenkins/config/jenkins-admin.env.example"`（第 40 行）

如果精简 setup-jenkins.sh 时改变了 `$SCRIPT_DIR` 的解析方式（如拆分到子目录），这些路径会失效。

**Prevention:**
1. 不改变 `$SCRIPT_DIR` 的计算方式（`cd "$(dirname "${BASH_SOURCE[0]}")" && pwd`）
2. 如果移动文件，更新相对路径引用
3. 精简后运行 `bash -n scripts/setup-jenkins.sh` 确认语法正确

---

## Minor Pitfalls

### Pitfall 11: shellcheck 误报导致"修复"引入真正的 bug

**What goes wrong:**
`shellcheck` 会对以下模式发出警告，但在本项目中这些是正确的写法：
- `$(cat "$ACTIVE_ENV_FILE")` -- shellcheck 建议 `< "$ACTIVE_ENV_FILE" read -r`，但项目中 `get_active_env()` 使用 `cat` 是故意的（单行文件）
- `$((total - keep_count))` -- 在 `[[ ]]` 中使用时，shellcheck 可能对某些版本报算术表达式警告
- `${SERVICE_PORT:-3001}` 在双引号字符串中的展开 -- shellcheck SC2086 警告，但这里需要不带引号展开到命令参数中

**Prevention:**
1. 不要盲目修复 shellcheck 警告 -- 先理解是否为误报
2. 对已验证的误报添加 `# shellcheck disable=SCXXXX` 注释
3. 每次修改后运行 `shellcheck` 但仅关注新增的警告

### Pitfall 12: macOS vs Linux 兼容代码被误删

**What goes wrong:**
`pipeline-stages.sh` 中有大量 macOS/BSD 兼容代码：
```bash
if date -v-1d >/dev/null 2>&1; then
    today_minus1=$(date -v-1d +"%Y/%m/%d")  # macOS
else
    today_minus1=$(date -d "yesterday" +"%Y/%m/%d")  # Linux
fi
```

开发在 macOS 上进行，生产在 Linux 上运行。精简时可能认为这些兼容代码"多余"而删除。

**Prevention:**
1. 保留所有 `date -v` / `date -d` 双平台兼容代码
2. 保留所有 `stat -f` / `stat -c` 双平台兼容代码
3. 可以抽象为平台检测函数减少重复，但不能删除分支

### Pitfall 13: 清理 envsubst 相关代码时破坏 Keycloak 部署

**What goes wrong:**
`manage-containers.sh` 中的 `prepare_env_file()` 函数有 Keycloak 专用逻辑：
```bash
if [ -f "/opt/noda/active-env-keycloak" ]; then
    export KEYCLOAK_ACTIVE_CONTAINER="keycloak-$(cat /opt/noda/active-env-keycloak)"
fi
```

这段代码看起来与 findclass-ssr 无关，但实际上 findclass-ssr 的环境变量需要 `KEYCLOAK_ACTIVE_CONTAINER`（因为 findclass-ssr 需要知道当前活跃的 Keycloak 容器来构造内部 URL）。

**Prevention:**
1. 不要因为代码看起来"只跟 Keycloak 有关"就移到 keycloak 专用文件
2. `prepare_env_file()` 中的所有逻辑对所有使用 env 模板的服务都有影响
3. 修改后测试 findclass-ssr 的登录功能（OAuth 链路依赖正确的 KEYCLOAK_ACTIVE_CONTAINER）

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| 合并 log.sh | Pitfall 1: 接口不兼容 | 不合并，保留两个独立 log.sh |
| 合并 health.sh | Pitfall 2: readonly 冲突 | 不合并，解决不同问题 |
| 合并蓝绿部署脚本 | Pitfall 3: 硬编码 URL + 执行上下文 | 参数化所有差异点，测试两个服务 |
| 删除 verify-* 脚本 | Pitfall 4: 丧失验证能力 | 先标记废弃，下个版本再删 |
| 精简 pipeline-stages.sh | Pitfall 5: 函数签名变更 | 同步修改 Jenkinsfile |
| 移动 manage-containers.sh | Pitfall 6: source 链断裂 | 保留旧路径兼容 wrapper |
| 合并 http_health_check | Pitfall 7: 行为差异丢失 | 参数化，不依赖默认值 |
| 精简 backup/lib/*.sh | Pitfall 8: set -euo pipefail | 库文件中移除，入口脚本保留 |

---

## 安全重构策略

### 原则 1: 不合并解决不同问题的库

以下文件对虽然名字相似，但解决完全不同的问题，不应该合并：
- `scripts/lib/health.sh`（容器健康检查）vs `scripts/backup/lib/health.sh`（数据库连接+磁盘空间检查）
- `scripts/lib/log.sh`（宿主机彩色日志）vs `scripts/backup/lib/log.sh`（容器内纯文本日志+结构化日志）

### 原则 2: 先标记废弃，再确认后删除

对任何可能不再使用的脚本，执行两步走：
1. 添加 `# DEPRECATED: <reason>` 注释，保留一个完整里程碑周期
2. 下个里程碑确认无引用后删除

### 原则 3: 参数化差异，不抹平差异

蓝绿部署脚本合并时，保留行为差异作为参数：
```bash
# 好的做法：参数化差异
http_health_check() {
    local container="$1"
    local executor="${2:-$container}"        # 默认在目标容器内执行
    local max_retries="${3:-30}"
    local interval="${4:-4}"
    local health_url="${5:-http://localhost:${SERVICE_PORT}${HEALTH_PATH}}"
    # ...
}
```

### 原则 4: 修改后必须测试的场景清单

任何重构完成后，必须验证以下场景：
1. `bash scripts/backup/backup-postgres.sh --dry-run` -- 备份系统不受影响
2. `bash scripts/manage-containers.sh status` -- 蓝绿容器管理正常
3. Jenkins Pipeline 完整运行一次（至少 Pre-flight + Build + Deploy 阶段）
4. `bash scripts/rollback-findclass.sh --help` -- 紧急回滚脚本可执行
5. `shellcheck scripts/pipeline-stages.sh` -- 无新增错误

---

## Sources

- 代码库文件逐行审计（全部 57 个 .sh 文件）
- 重复代码比对：log.sh (2), health.sh (2), http_health_check (4处), e2e_verify (4处)
- source 链分析：manage-containers.sh (6 个调用方), pipeline-stages.sh (Jenkinsfile 引用)
- readonly 变量冲突测试：constants.sh 的 14 个 readonly 定义
