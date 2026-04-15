# Phase 21: 蓝绿容器管理 - Research

**Researched:** 2026-04-15
**Domain:** Docker 容器生命周期管理（docker run 独立管理蓝绿容器 + 状态文件追踪）
**Confidence:** HIGH

## Summary

Phase 21 将 findclass-ssr 从单容器 compose 管理迁移到蓝绿双容器 `docker run` 管理。核心工作包括：(1) 创建 `manage-containers.sh` 多子命令管理脚本，(2) 创建独立环境变量文件 `docker/env-findclass-ssr.env`，(3) 实现 `init` 子命令自动从 compose 单容器迁移到蓝绿架构，(4) 创建 `/opt/noda/active-env` 状态文件追踪活跃环境。

Phase 20 已将 nginx upstream 定义抽离到 `snippets/upstream-findclass.conf`（当前内容 `server findclass-ssr:3001`），Phase 21 的 init 将把此文件改为 `server findclass-ssr-blue:3001` 并 reload nginx。所有容器通过外部网络 `noda-network` 互联，nginx 通过 Docker 内置 DNS 解析容器名 `findclass-ssr-blue` / `findclass-ssr-green`。

**Primary recommendation:** 使用 `manage-containers.sh` 单脚本 7+ 子命令模式，完全复制 `setup-jenkins.sh` 的代码风格和模式。`docker run` 参数直接从 `docker-compose.app.yml` 中的 findclass-ssr 服务定义翻译。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 单脚本 `manage-containers.sh` 多子命令模式，与 `setup-jenkins.sh` 风格一致
- **D-02:** 子命令包含完整运维工具集：start、stop、status、init、restart、logs 等（7+ 个子命令）
- **D-03:** Phase 22 部署脚本通过 shell source 调用内部函数，复用启动/停止逻辑
- **D-04:** 创建独立 `docker/env-findclass-ssr.env` 文件，包含所有 findclass-ssr 需要的环境变量
- **D-05:** 管理脚本通过 `docker run --env-file` 传递变量，变量值中的 `${VAR}` 语法由脚本解析填充
- **D-06:** 环境变量与 docker-compose.app.yml 中的定义保持一致（NODE_ENV、DATABASE_URL、KEYCLOAK_*、RESEND_API_KEY）
- **D-07:** `init` 子命令自动执行完整迁移流程：检测 compose 容器 -> 停止 -> docker run 启动 blue -> 更新 nginx upstream -> 写状态文件
- **D-08:** 容器名：`findclass-ssr-blue` / `findclass-ssr-green`
- **D-09:** 保留现有标签 `noda.service-group=apps` + `noda.environment=prod`，新增 `noda.blue-green=blue/green`
- **D-10:** 容器安全配置沿用 docker-compose.app.yml：no-new-privileges、cap_drop:ALL、read_only、tmpfs /tmp、资源限制 512M/1CPU
- **D-11:** 日志配置沿用：json-file driver、max-size 10m、max-file 3
- **D-12:** restart 策略：unless-stopped

### Claude's Discretion
- 环境变量文件中具体哪些变量需要动态替换（如 `${POSTGRES_USER}`）vs 硬编码
- 子命令的参数设计细节（如 start 是否需要指定镜像标签）
- init 迁移时的错误恢复机制
- status 子命令的输出格式

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BLUE-01 | 同一时刻存在 blue 和 green 两个 findclass-ssr 容器实例，活跃容器对外服务，目标容器等待验证 | docker run 参数从 docker-compose.app.yml 翻译；noda-network 外部网络保证互联 |
| BLUE-03 | 活跃环境状态通过 `/opt/noda/active-env` 文件持久化追踪（内容为 `blue` 或 `green`） | init 子命令创建并写入初始值；status 子命令读取显示 |
| BLUE-04 | 蓝绿容器通过 `docker run` 独立管理生命周期，不通过 docker-compose.yml 管理 | manage-containers.sh 封装所有 docker run 操作；docker-compose.app.yml 保留仅用于 build |
| BLUE-05 | 蓝绿容器均在 `noda-network` Docker 网络上，nginx 通过容器名 DNS 解析访问 | `--network noda-network` 参数；Docker 内置 DNS 自动解析容器名 |
</phase_requirements>

## Architecture Patterns

### 推荐的项目结构

```
scripts/
├── manage-containers.sh       # 新增：蓝绿容器管理主脚本（7+ 子命令）
├── lib/
│   ├── log.sh                 # 复用：结构化日志库
│   └── health.sh              # 复用：wait_container_healthy()
├── deploy/
│   └── deploy-apps-prod.sh    # 保留：手动回退方案
docker/
├── env-findclass-ssr.env      # 新增：findclass-ssr 环境变量文件
├── docker-compose.app.yml     # 保留：仅用于 docker compose build
config/nginx/snippets/
├── upstream-findclass.conf    # Phase 20 产出：init 时修改 server 地址
/opt/noda/                     # 运行时状态目录（宿主机）
├── active-env                 # 新增：内容为 blue 或 green
```

### Pattern 1: 单脚本多子命令（与 setup-jenkins.sh 一致）
**What:** 一个脚本文件包含所有子命令，通过 case 语句路由
**When to use:** 运维工具集，需要多个独立操作入口
**Example:**
```bash
# 来源: scripts/setup-jenkins.sh（已验证的现有模式）
case "${1:-}" in
  start)         cmd_start "$@" ;;
  stop)          cmd_stop "$@" ;;
  status)        cmd_status "$@" ;;
  init)          cmd_init "$@" ;;
  restart)       cmd_restart "$@" ;;
  logs)          cmd_logs "$@" ;;
  switch)        cmd_switch "$@" ;;
  *)             usage && exit 1 ;;
esac
```

### Pattern 2: docker run 参数从 compose 翻译
**What:** 将 docker-compose.app.yml 中的服务定义翻译为等效 docker run 命令
**When to use:** 从 compose 迁移到独立容器管理时
**Example（从 docker-compose.app.yml 翻译）:**
```bash
# 来源: docker/docker-compose.app.yml findclass-ssr 服务定义
# compose 配置              → docker run 参数
# security_opt:             → --security-opt no-new-privileges
# cap_drop: ALL             → --cap-drop ALL
# read_only: true           → --read-only
# tmpfs: /tmp               → --tmpfs /tmp
# deploy.resources.limits   → --memory 512m --cpus 1
# deploy.resources.reservations → --memory-reservation 128m
# restart: unless-stopped   → --restart unless-stopped
# logging.*                 → --log-driver json-file --log-opt max-size=10m --log-opt max-file=3
# networks: noda-network    → --network noda-network
# healthcheck.*             → --health-cmd --health-interval --health-timeout ...
# environment               → --env-file docker/env-findclass-ssr.env
# container_name            → --name findclass-ssr-blue
# labels                    → --label noda.service-group=apps ...
```

### Pattern 3: 状态文件读写
**What:** 通过文件系统持久化蓝绿状态，简单可靠
**When to use:** 无需分布式协调，单服务器部署
**Example:**
```bash
ACTIVE_ENV_FILE="/opt/noda/active-env"

# 读取
get_active_env() {
  cat "$ACTIVE_ENV_FILE" 2>/dev/null || echo "blue"
}

# 写入（原子操作）
set_active_env() {
  local env="$1"
  echo "$env" > "${ACTIVE_ENV_FILE}.tmp"
  mv "${ACTIVE_ENV_FILE}.tmp" "$ACTIVE_ENV_FILE"
}
```

### Anti-Patterns to Avoid
- **在 docker-compose.app.yml 中定义 blue/green 双服务:** 违反 D-04 决策，compose 仅用于 build
- **手动拼接 docker run -e 传环境变量:** 变量多且含特殊字符时容易出错，应使用 --env-file
- **不加 healthcheck 启动容器:** wait_container_healthy() 依赖 Docker healthcheck，缺失会导致健康检查立即返回 "运行中"（health=none 分支）
- **忘记 --network noda-network:** 容器将进入默认 bridge 网络，nginx 无法通过容器名 DNS 解析

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 环境变量替换 | 自写 ${VAR} 模板引擎 | `envsubst` 或 `eval` | envsubst 处理边缘情况（空值、特殊字符、嵌套变量）更可靠，且是系统自带工具 [ASSUMED] |
| 容器健康检查 | 自写轮询脚本 | `wait_container_healthy()` (scripts/lib/health.sh) | 已有经过验证的实现，支持 starting/healthy/unhealthy/none 全状态处理 |
| 日志格式 | 自写日志函数 | `source scripts/lib/log.sh` | 项目统一格式，log_info/log_success/log_error/log_warn 带颜色 |
| nginx 配置验证 | 自写配置检查 | `docker exec noda-infra-nginx nginx -t` | nginx 自带的语法检查最权威 |
| nginx reload | 自写信号发送 | `docker exec noda-infra-nginx nginx -s reload` | Docker exec 是项目已建立的模式 |

**Key insight:** Phase 21 的核心是将 docker-compose.app.yml 中 findclass-ssr 的声明式配置翻译为 `docker run` 命令式调用。不是重新设计，而是翻译。

## Common Pitfalls

### Pitfall 1: docker run 缺少 healthcheck 导致 wait_container_healthy 误判
**What goes wrong:** 不加 `--health-cmd` 参数时，Docker 不为容器创建 healthcheck，`wait_container_healthy()` 走 `none` 分支直接返回成功
**Why it happens:** health.sh:46 的 `none` 分支直接认为 "运行中=健康"，跳过真正检查
**How to avoid:** docker run 必须包含完整的 healthcheck 参数（`--health-cmd`、`--health-interval`、`--health-timeout`、`--health-retries`、`--health-start-period`）
**Warning signs:** 容器启动后 wait_container_healthy 立即返回 "运行中"，但应用实际还在初始化中

### Pitfall 2: 环境变量文件中的 ${VAR} 不被替换
**What goes wrong:** `docker run --env-file` 不会解析文件中的 `${VAR}` 语法，直接作为字面量传递
**Why it happens:** Docker 的 --env-file 只做 `KEY=VALUE` 逐行读取，不做 shell 变量替换
**How to avoid:** 脚本需要先读取 env 文件模板，用 `envsubst` 或 `eval` 替换 `${VAR}` 为实际值，再写入临时文件传给 `--env-file`
**Warning signs:** 容器内 `DATABASE_URL` 包含字面 `${POSTGRES_USER}` 而非实际用户名

### Pitfall 3: noda-network 网络不存在时 docker run 静默失败
**What goes wrong:** `docker run --network noda-network` 在网络不存在时报错退出，但错误信息可能被忽略
**Why it happens:** 脚本执行 `set -euo pipefail` 会终止，但错误信息不够明确
**How to avoid:** start 子命令先检查 `docker network inspect noda-network` 是否成功
**Warning signs:** docker run 退出码 125 + "network noda-network not found"

### Pitfall 4: stop_grace_period 未传递导致容器强制退出
**What goes wrong:** docker run 默认 SIGKILL 超时为 10 秒，而 compose 中配置了 30 秒（stop_grace_period: 30s）
**Why it happens:** docker run 没有 `--stop-grace-period` 参数，需要通过 `--stop-timeout` 传递
**How to avoid:** 使用 `--stop-timeout 30` 对应 compose 的 `stop_grace_period: 30s`
**Warning signs:** 容器收到 SIGTERM 后 10 秒内被 SIGKILL，来不及完成清理

### Pitfall 5: init 迁移期间服务中断过长
**What goes wrong:** compose 容器停止 -> blue 容器启动 -> 健康检查通过 期间服务不可用
**Why it happens:** 单服务器无法同时运行两个实例做热切换
**How to avoid:** init 只在首次迁移时执行一次；后续部署走 Phase 22 的蓝绿流程（先启新容器再切流量）。init 前提示管理员确认可以短暂中断
**Warning signs:** init 执行超过 2 分钟

### Pitfall 6: envsubst 替换过度（替换了不应替换的变量）
**What goes wrong:** `$HOSTNAME`、`$HOME` 等 shell 内置变量被意外替换
**Why it happens:** `envsubst` 默认替换所有 `$VAR` 格式
**How to avoid:** 使用 `envsubst '$POSTGRES_USER $POSTGRES_PASSWORD $RESEND_API_KEY'` 指定只替换哪些变量 [ASSUMED]
**Warning signs:** 容器内环境变量值包含意外的系统路径或主机名

## Code Examples

### docker run 完整命令（从 docker-compose.app.yml 翻译）
```bash
# 来源: docker/docker-compose.app.yml findclass-ssr 服务定义
# 每个参数都来自 compose 中的对应字段

docker run -d \
  --name "findclass-ssr-blue" \
  --network noda-network \
  --restart unless-stopped \
  --stop-timeout 30 \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  --read-only \
  --tmpfs /tmp \
  --memory 512m \
  --memory-reservation 128m \
  --cpus 1 \
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  --env-file /tmp/findclass-ssr-blue.env \
  --label noda.service-group=apps \
  --label noda.environment=prod \
  --label noda.blue-green=blue \
  --health-cmd "wget --quiet --tries=1 --spider http://localhost:3001/api/health || exit 1" \
  --health-interval 30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 60s \
  findclass-ssr:latest
```

### 环境变量文件模板
```bash
# docker/env-findclass-ssr.env（模板，含 ${VAR} 占位符）
# 来源: docker/docker-compose.app.yml findclass-ssr.environment

NODE_ENV=production
DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@noda-infra-postgres-prod:5432/noda_prod
DIRECT_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@noda-infra-postgres-prod:5432/noda_prod
KEYCLOAK_URL=https://auth.noda.co.nz
KEYCLOAK_INTERNAL_URL=http://noda-infra-keycloak-prod:8080
KEYCLOAK_REALM=noda
KEYCLOAK_CLIENT_ID=noda-frontend
RESEND_API_KEY=${RESEND_API_KEY:-}
```

### init 子命令核心流程
```bash
# 来源: CONTEXT.md D-07 决策
cmd_init() {
  # 1. 检测 compose 管理的 findclass-ssr 容器
  local current_image
  current_image=$(docker inspect --format='{{.Config.Image}}' findclass-ssr 2>/dev/null || echo "")

  if [ -z "$current_image" ]; then
    log_error "未找到运行中的 findclass-ssr 容器"
    log_info "请先通过 deploy-apps-prod.sh 部署"
    exit 1
  fi

  # 2. 确认中断提示
  log_warn "init 将短暂中断 findclass-ssr 服务（约 60-90 秒）"
  read -p "确认继续？[y/N] " -r
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

  # 3. 停止 compose 容器
  log_info "停止 compose 管理的 findclass-ssr 容器..."
  docker compose -f docker/docker-compose.app.yml stop findclass-ssr
  docker compose -f docker/docker-compose.app.yml rm -f findclass-ssr

  # 4. 启动 blue 容器（使用相同镜像）
  log_info "启动 blue 容器（镜像: ${current_image}）..."
  # ... docker run 命令 ...

  # 5. 等待健康检查
  wait_container_healthy findclass-ssr-blue 90

  # 6. 更新 nginx upstream
  cat > config/nginx/snippets/upstream-findclass.conf <<EOF
upstream findclass_backend {
    server findclass-ssr-blue:3001 max_fails=3 fail_timeout=30s;
}
EOF
  docker exec noda-infra-nginx nginx -s reload

  # 7. 写入状态文件
  mkdir -p /opt/noda
  echo "blue" > /opt/noda/active-env

  log_success "蓝绿架构初始化完成！活跃环境: blue"
}
```

### get_inactive_env 辅助函数
```bash
# 获取非活跃环境名（蓝绿互补）
get_inactive_env() {
  local active
  active=$(get_active_env)
  if [ "$active" = "blue" ]; then
    echo "green"
  else
    echo "blue"
  fi
}
```

### 子命令列表（建议 8 个）
```
init          — 首次迁移：compose 单容器 → 蓝绿 blue 容器
start <env>   — 启动指定环境容器（blue 或 green）
stop <env>    — 停止指定环境容器
restart <env> — 重启指定环境容器
status        — 显示蓝绿容器和活跃环境状态
logs <env>    — 查看指定环境容器日志
switch <env>  — 切换活跃环境（修改 upstream + reload nginx + 更新状态文件）
usage         — 显示帮助信息
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| docker compose 管理应用容器 | docker run 独立管理蓝绿容器 | Phase 21 (2026-04-15) | compose 仅用于 build，生产容器由 manage-containers.sh 管理 |
| 单容器 findclass-ssr | 蓝绿双容器 findclass-ssr-blue + findclass-ssr-green | Phase 21 (2026-04-15) | 零停机部署基础 |
| upstream 指向 findclass-ssr | upstream 指向 findclass-ssr-blue 或 findclass-ssr-green | Phase 20+21 (2026-04-15) | nginx 流量切换基础 |

**Deprecated/outdated:**
- `docker-compose.app.yml` 中 findclass-ssr 的 `container_name: findclass-ssr`: 将不再用于生产运行，仅用于构建

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `envsubst` 可用且支持指定变量名列表（`envsubst '$VAR1 $VAR2'`） | 环境变量管理 | 低 — envsubst 是 gettext 包的标准工具，大多数 Linux 发行版预装 |
| A2 | `docker run --stop-timeout` 等同于 compose 的 `stop_grace_period` | 容器安全配置 | 低 — Docker 官方文档确认 [VERIFIED: Docker 文档] |
| A3 | Docker 内置 DNS 可以解析同一 external 网络上的容器名（如 `findclass-ssr-blue`） | 网络配置 | 低 — 这是 Docker 的标准行为 |
| A4 | `docker compose build findclass-ssr` 仍可正常构建镜像（compose 文件不修改服务定义） | 构建流程 | 无风险 — compose 文件完全保留，只是不用于运行 |
| A5 | 生产服务器上 `/opt/noda/` 目录可由当前用户写入 | 状态文件 | 中 — 可能需要 sudo 或调整权限 |

## Open Questions

1. **envsubst 是否已在生产服务器上安装？**
   - What we know: 生产服务器是 Debian/Ubuntu
   - What's unclear: gettext 包是否已安装
   - Recommendation: 脚本开头检查 `command -v envsubst`，缺失时提示安装或回退到 eval 方案

2. **/opt/noda/ 目录权限**
   - What we know: 状态文件路径确定为 `/opt/noda/active-env`
   - What's unclear: 生产服务器上谁有写权限（需要 root 还是当前用户）
   - Recommendation: 脚本中用 `sudo mkdir -p /opt/noda` 和 `sudo chown` 设置权限，或 init 中处理

3. **是否需要 switch 子命令？**
   - What we know: CONTEXT.md D-02 说 7+ 子命令；Phase 22 的部署脚本需要切换能力
   - What's unclear: switch 是否在 Phase 21 范围内（ROADMAP 说 Phase 22 是"蓝绿部署核心流程"）
   - Recommendation: 在 Phase 21 中实现 switch 子命令（修改 upstream + reload nginx + 更新状态文件），因为它是容器管理的核心操作，Phase 22 只是编排调用

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | 容器管理 | ✓ (本地) | 29.1.3 | — |
| docker compose | 构建 | ✓ (本地) | v2 (内置于 Docker) | — |
| bash | 脚本执行 | ✓ | 3.2.57 (macOS) / 生产: Linux | — |
| noda-network | 容器互联 | ✓ | external | 脚本中检查并报错 |
| nginx 容器 | upstream reload | ✗ (本地无) | — | 生产部署时验证 |
| findclass-ssr 镜像 | init/start | ✗ (本地无) | — | 生产构建后执行 |
| envsubst | 环境变量替换 | ✗ (macOS 不自带) | — | 脚本中检查，或使用 eval 回退 |
| Docker 内置 DNS | 容器名解析 | ✓ (Docker 标准) | — | — |

**Missing dependencies with no fallback:**
- 无阻塞依赖（本地开发环境不需要运行容器）

**Missing dependencies with fallback:**
- envsubst：若不可用，使用 `eval echo` 替代方案（但安全性略低）
- nginx/findclass-ssr 容器：本地跳过在线验证，生产部署时执行完整验证

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bash 单元测试（手动 bash -n 语法检查 + docker 集成测试） |
| Config file | 无 — 脚本类测试不需要框架 |
| Quick run command | `bash -n scripts/manage-containers.sh && echo "syntax OK"` |
| Full suite command | `bash scripts/manage-containers.sh status 2>&1` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BLUE-01 | blue/green 容器独立启停 | integration | `bash scripts/manage-containers.sh start blue && docker ps --filter name=findclass-ssr-blue` | Wave 0 |
| BLUE-01 | 容器在 noda-network 上 | integration | `docker inspect findclass-ssr-blue --format='{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}'` | Wave 0 |
| BLUE-03 | active-env 文件正确读写 | unit | `source scripts/manage-containers.sh; get_active_env` | Wave 0 |
| BLUE-04 | docker run 管理容器 | integration | `docker inspect findclass-ssr-blue --format='{{.HostConfig.NetworkMode}}'` | Wave 0 |
| BLUE-05 | nginx DNS 解析容器名 | integration | `docker exec noda-infra-nginx wget -qO- http://findclass-ssr-blue:3001/api/health` | Wave 0 |

### Sampling Rate
- **Per task commit:** `bash -n scripts/manage-containers.sh`
- **Per wave merge:** `bash -n scripts/manage-containers.sh`（本地语法检查）
- **Phase gate:** 生产环境执行 init -> start -> status 验证完整流程

### Wave 0 Gaps
- [ ] `scripts/manage-containers.sh` — 所有子命令实现
- [ ] `docker/env-findclass-ssr.env` — 环境变量文件
- [ ] 无测试框架安装需求（bash 脚本使用 `bash -n` 语法检查 + docker 集成测试）

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | yes | 脚本需要检查当前用户是否有 docker 组权限 |
| V5 Input Validation | yes | 子命令参数验证（env 必须是 blue/green） |
| V6 Cryptography | no | — |

### Known Threat Patterns for Docker 容器管理

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 容器逃逸 | Privilege Escalation | --security-opt no-new-privileges + --cap-drop ALL + --read-only [VERIFIED: docker-compose.app.yml] |
| 资源耗尽 | Denial of Service | --memory 512m --cpus 1 限制 [VERIFIED: docker-compose.app.yml] |
| 环境变量泄露 | Information Disclosure | env 文件权限控制（600），不在日志中打印敏感值 |
| nginx 配置注入 | Tampering | 原子写入 upstream 文件（tmpfile + mv）；nginx -t 验证后才 reload |

## Sources

### Primary (HIGH confidence)
- `docker/docker-compose.app.yml` — findclass-ssr 服务完整定义（docker run 参数的翻译来源）
- `docker/docker-compose.yml` — noda-network 外部网络定义
- `config/nginx/snippets/upstream-findclass.conf` — Phase 20 产出，当前上游定义
- `scripts/setup-jenkins.sh` — 单脚本多子命令模式参考
- `scripts/lib/health.sh` — wait_container_healthy() 实现
- `scripts/lib/log.sh` — 日志库实现
- `.planning/phases/21-blue-green-containers/21-CONTEXT.md` — Phase 21 决策

### Secondary (MEDIUM confidence)
- `.planning/phases/20-nginx/20-01-SUMMARY.md` — Phase 20 完成状态确认
- `.planning/phases/20-nginx/20-CONTEXT.md` — Phase 20 决策（upstream 切换接口）
- `.planning/ROADMAP.md` — Phase 21/22/23 范围划分

### Tertiary (LOW confidence)
- envsubst 指定变量名语法（`envsubst '$VAR1 $VAR2'`）— 标准用法但未在本机验证

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 全部基于现有代码库验证，docker run 参数直接从 compose 翻译
- Architecture: HIGH — 遵循已建立的 setup-jenkins.sh 模式，无新架构设计
- Pitfalls: HIGH — 基于对 Docker run 和项目现有代码的精确分析

**Research date:** 2026-04-15
**Valid until:** 2026-05-15（Docker 核心行为稳定，30 天有效期合理）
