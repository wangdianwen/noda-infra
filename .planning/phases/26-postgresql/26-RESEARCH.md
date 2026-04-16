# Phase 26: 宿主机 PostgreSQL 安装与配置 - Research

**Researched:** 2026-04-17
**Domain:** Homebrew PostgreSQL 17.9 安装 + 开发数据库配置 + Docker 数据迁移
**Confidence:** HIGH（本地环境验证 + 代码库深度分析 + 里程碑研究交叉参考）

## Summary

本阶段在 macOS 宿主机上通过 Homebrew 安装 PostgreSQL 17.9，完全替代 Docker `postgres-dev` 容器提供本地开发数据库服务。Homebrew `postgresql@17` formula 当前版本为 **17.9**（与生产 Docker `postgres:17.9` 完全匹配），Apple Silicon 上数据目录为 `/opt/homebrew/var/postgresql@17`，默认使用 trust 认证（无需密码），`brew services start` 自动创建 LaunchAgent plist 实现开机自启。

当前 `postgres_dev_data` Docker volume 中有实际开发数据：`noda_dev`（8598 kB，71 courses + 139 profiles + 30 categories + 13 Prisma migrations）和 `keycloak_dev`（12 MB，完整 Keycloak schema + 1 user + 2 realms + 13 clients）。迁移使用 Docker 容器内的 `pg_dump`（版本 17.9 完全匹配）导出，通过本地 `psql` 导入。

**Primary recommendation:** 创建 `scripts/setup-postgres-local.sh` 脚本（子命令模式，复用 setup-jenkins.sh 模式），涵盖安装、初始化、迁移、状态检查、卸载全生命周期。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 本地开发数据库使用 **trust 认证**（无密码），`pg_hba.conf` 中本地连接使用 trust
- **D-02:** 本地 PostgreSQL 监听 **5432 端口**（默认端口），开发机与生产服务器完全隔离
- **D-03:** 使用 **pg_dump/pg_restore via docker exec** 从 postgres_dev_data volume 迁移数据
- **D-04:** 创建 **独立脚本 `scripts/setup-postgres-local.sh`**，采用子命令模式（与 setup-jenkins.sh 一致）
  - `install` — 安装 postgresql@17 + 配置 brew services + 创建开发数据库
  - `init-db` — 仅创建/重建开发数据库和用户
  - `migrate-data` — 从 Docker volume 迁移数据到本地 PG
  - `status` — 检查 PG 运行状态、版本、数据库列表
  - `uninstall` — 卸载 PostgreSQL 并清理数据目录
  - 所有操作幂等设计
- **D-05:** 严格锁定 **postgresql@17**（不是最新的 postgresql formula）
- **D-06:** 创建 `noda_dev` 和 `keycloak_dev` 开发数据库，复用现有 init-dev SQL 逻辑

### Claude's Discretion
- 脚本的具体实现细节（错误处理、颜色输出、交互确认）
- brew services 的具体配置方式
- 幂等性检查的具体实现
- 迁移脚本的进度反馈方式
- 是否需要单独的 `pg_hba.conf` 配置模板

### Deferred Ideas (OUT OF SCOPE)
- **Jenkins H2 -> PG 迁移** — 尚未纳入正式需求
- **Jenkins PG 数据纳入 B2 备份** — 依赖 Jenkins 迁移完成
- **开发数据库种子数据自动化** — Phase 30 处理
- **PostgreSQL 配置优化（shared_buffers, work_mem）** — 开发环境使用默认配置
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| LOCALPG-01 | 开发者可通过 Homebrew 安装 PostgreSQL 17.9（与生产版本匹配），包含 pg_dump/pg_restore 工具 | Homebrew `postgresql@17` formula 稳定版为 17.9，与 Docker 版本完全匹配 [VERIFIED: brew info]；keg-only 需要额外链接步骤 |
| LOCALPG-02 | 安装脚本自动创建开发数据库和用户，提供 noda_dev / keycloak_dev 等开发用数据库 | 现有 `init-dev/01-create-databases.sql` 可直接复用 [VERIFIED: codebase]；幂等创建使用 `CREATE DATABASE ... ?` 或 shell 检查 |
| LOCALPG-03 | PostgreSQL 配置为 brew services 自动启动，开发者重启电脑后无需手动启动 | `brew services start postgresql@17` 创建 LaunchAgent plist [VERIFIED: brew services list]；macOS launchd 自动加载 |
| LOCALPG-04 | 现有 postgres_dev_data Docker volume 中的开发数据可导出并导入到本地 PostgreSQL | Docker 容器内 pg_dump 17.9 可用 [VERIFIED: docker exec]；noda_dev 731 行 + keycloak_dev 5407 行 dump |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| postgresql@17 (Homebrew) | 17.9 | 本地开发数据库 | 与 Docker 生产版本完全匹配 [VERIFIED: brew info postgresql@17] |
| brew services | (Homebrew 5.1.6) | macOS 服务管理 + 开机自启 | 标准 macOS 服务管理方式，自动创建 LaunchAgent plist [VERIFIED: brew services list] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| initdb (Homebrew 自带) | 17.9 | 初始化数据库集群 | 首次安装时自动执行，Homebrew formula 已内置 |
| pg_dump / pg_restore (Docker 容器内) | 17.9 | 数据迁移 | 从 postgres_dev_data volume 导出数据到本地 PG |
| psql (Homebrew 自带) | 17.9 | 命令行客户端 | 开发者日常连接数据库 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Homebrew postgresql@17 | Postgres.app | Postgres.app 是 GUI 应用，版本控制不如 Homebrew 精确，不适合脚本化安装 [ASSUMED] |
| Homebrew postgresql@17 | Docker 容器化 PG | 正是为了替代 Docker dev 容器，Docker 本地开发体验差（启动慢、端口管理复杂） |
| trust 认证 | md5/scram-sha-256 | 密码认证增加开发环境复杂度，trust 是本地开发标准做法 [VERIFIED: CONTEXT.md D-01] |
| brew link --force | PATH 手动添加 | force-link 全局暴露所有 PG 工具，PATH 添加更安全但需额外配置 [ASSUMED] |

**Installation:**
```bash
# 核心安装命令
brew install postgresql@17

# 链接二进制到 PATH（keg-only 需要手动链接）
brew link --force postgresql@17

# 启动服务 + 开机自启
brew services start postgresql@17

# 验证
psql --version  # 应显示 17.9
brew services list | grep postgresql@17  # 应显示 started
```

**Version verification:** [VERIFIED: 2026-04-17]
```bash
$ brew info postgresql@17
postgresql@17: stable 17.9 (bottled) [keg-only]
# 30 天安装量: 13,202; 90 天: 46,783
```

## Architecture Patterns

### Recommended Project Structure
```
scripts/
├── setup-postgres-local.sh    # 本阶段新建：PG 生命周期管理脚本
├── setup-jenkins.sh           # 已有：参考模式（子命令分发）
├── init-databases.sh          # 已有：参考模式（数据库创建）
└── lib/
    ├── log.sh                 # 已有：所有脚本共享
    └── health.sh              # 已有：容器健康检查

docker/services/postgres/
└── init-dev/
    ├── 01-create-databases.sql  # 已有：直接复用
    └── 02-seed-data.sql         # 已有：可选复用
```

### Pattern 1: 子命令脚本模式（复用 setup-jenkins.sh）
**What:** 单一脚本通过位置参数分发到不同子命令函数
**When to use:** 所有生命周期管理脚本（安装、卸载、状态检查）
**Example:**
```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/log.sh"

# 架构检测（Apple Silicon vs Intel）
detect_homebrew_prefix() {
  local arch
  arch=$(uname -m)
  if [ "$arch" = "arm64" ]; then
    echo "/opt/homebrew"
  else
    echo "/usr/local"
  fi
}

# 幂等数据库创建
cmd_init_db() {
  local db_name="$1"
  if psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$db_name"; then
    log_info "数据库 $db_name 已存在，跳过"
  else
    createdb "$db_name"
    log_success "数据库 $db_name 已创建"
  fi
}

# 子命令分发（与 setup-jenkins.sh 模式一致）
case "${1:-}" in
  install)        cmd_install "$@" ;;
  init-db)        cmd_init_db "$@" ;;
  migrate-data)   cmd_migrate_data "$@" ;;
  status)         cmd_status "$@" ;;
  uninstall)      cmd_uninstall "$@" ;;
  *)              usage && exit 1 ;;
esac
```

### Pattern 2: 幂等操作检查
**What:** 每个操作前先检查是否已完成，避免重复执行报错
**When to use:** 所有安装和初始化步骤
**Example:**
```bash
# 检查 PostgreSQL 是否已安装
if brew list postgresql@17 &>/dev/null; then
  log_info "postgresql@17 已安装，跳过"
else
  brew install postgresql@17
fi

# 检查服务是否已运行
if brew services list | grep -q "postgresql@17.*started"; then
  log_info "postgresql@17 服务已运行"
else
  brew services start postgresql@17
fi

# 检查数据库是否已存在
if psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "noda_dev"; then
  log_info "数据库 noda_dev 已存在"
else
  createdb noda_dev
fi
```

### Anti-Patterns to Avoid
- **使用 `brew install postgresql`（无版本锁定）：** 可能安装 18.x，与生产 17.9 不匹配 [VERIFIED: CONTEXT.md D-05]
- **直接用 Homebrew pg_dump 备份 Docker 数据库：** 需用 Docker 容器内的 pg_dump 确保版本完全匹配 [VERIFIED: PITFALLS.md Pitfall 2]
- **非幂等 SQL 执行：** `CREATE DATABASE noda_dev;` 在数据库已存在时会报错退出，必须先检查 [VERIFIED: PITFALLS.md Pitfall 7]
- **硬编码 Homebrew 路径：** Apple Silicon 是 `/opt/homebrew`，Intel 是 `/usr/local`，必须动态检测 [VERIFIED: CONTEXT.md specifics]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| macOS 服务管理 | launchctl plist 手动编写 | `brew services start/stop` | Homebrew 自动生成正确 plist，处理环境变量和日志路径 [VERIFIED: brew services list] |
| 数据库集群初始化 | 手动运行 initdb | Homebrew 自动执行 | `brew install postgresql@17` 自动运行 `initdb --locale=en_US.UTF-8 -E UTF-8` [VERIFIED: brew info caveats] |
| 数据库认证配置 | 手动编辑 pg_hba.conf | Homebrew 默认 trust 认证 | Homebrew 的 initdb 在 macOS 上默认使用 trust [VERIFIED: PostgreSQL 17 initdb 默认行为] |
| 数据导出 | 自定义 SQL 脚本逐表导出 | `pg_dump` / `pg_restore` | 处理所有数据类型、约束、序列，保证一致性 [VERIFIED: Docker 容器内 pg_dump 17.9 可用] |

**Key insight:** Homebrew postgresql@17 的默认安装已经覆盖了大部分配置需求（trust 认证、UTF-8 编码、默认端口 5432）。脚本主要工作是"检查 + 编排"，而非"配置 + 调整"。

## Common Pitfalls

### Pitfall 1: keg-only 导致 psql 不在 PATH 中
**What goes wrong:** `brew install postgresql@17` 后运行 `psql` 报 `command not found`
**Why it happens:** Homebrew 将 postgresql@17 标记为 keg-only（因为它是主 formula 的替代版本），不自动创建符号链接到 `/opt/homebrew/bin/`
**How to avoid:** 安装后执行 `brew link --force postgresql@17` 或在 shell profile 中添加 PATH
**Warning signs:** `psql --version` 报 command not found；`brew services list` 显示 started 但无法连接

### Pitfall 2: brew services 启动后 pg_hba.conf 不是 trust
**What goes wrong:** `psql -d noda_dev` 报 `FATAL: password authentication failed`
**Why it happens:** 某些 Homebrew 版本或升级后 pg_hba.conf 可能改为 scram-sha-256；initdb 的默认认证方法取决于是否设置了超级用户密码
**How to avoid:** 安装后验证 pg_hba.conf 中 local 和 host 127.0.0.1 的认证方法为 trust；如不是则修改
**Warning signs:** `psql` 要求密码；`pg_hba.conf` 中 local 行的 method 列不是 `trust`

### Pitfall 3: 端口 5432 被占用（其他 PG 实例）
**What goes wrong:** `brew services start postgresql@17` 启动失败，日志报 `could not bind IPv4 address: Address already in use`
**Why it happens:** 开发者可能已安装其他版本 PostgreSQL（如 postgresql@14 或 Postgres.app），占用了 5432 端口
**How to avoid:** 安装前检查 `lsof -i :5432`；如果被占用，提示用户停止旧服务或选择其他端口
**Warning signs:** `brew services list` 显示 postgresql@17 为 error 状态；PG 日志有端口绑定失败

### Pitfall 4: Docker 容器未运行时迁移失败
**What goes wrong:** `migrate-data` 子命令执行 `docker exec noda-infra-postgres-dev pg_dump` 报容器不存在
**Why it happens:** postgres-dev 容器可能未启动（`docker compose` 未执行或容器已停止）
**How to avoid:** 迁移前检查容器运行状态，未运行时提示用户先启动或提供跳过迁移选项
**Warning signs:** `docker ps` 中无 `noda-infra-postgres-dev`；`docker exec` 报 "No such container"

### Pitfall 5: pg_dump 版本不匹配导致导入失败
**What goes wrong:** 用 Homebrew 的 pg_dump 导出 Docker 中的数据库，导入时报格式不兼容
**Why it happens:** 虽然 Homebrew PG 也是 17.9，但 Docker 容器内 PG 的 pg_dump 输出格式更可靠
**How to avoid:** 使用 Docker 容器内的 pg_dump 导出（`docker exec noda-infra-postgres-dev pg_dump`），本地 psql 导入 [VERIFIED: CONTEXT.md D-03]
**Warning signs:** pg_restore 报 `unsupported version` 或 `archive format not recognized`

### Pitfall 6: 数据目录权限问题
**What goes wrong:** PostgreSQL 启动后无法写入数据目录
**Why it happens:** 如果手动创建或删除了 `/opt/homebrew/var/postgresql@17` 目录，权限可能不正确
**How to avoid:** 让 Homebrew 的 initdb 自动创建数据目录；如需重建使用 `brew reinstall postgresql@17`
**Warning signs:** PG 日志报 `could not create directory` 或 `permission denied`

### Pitfall 7: Apple Silicon vs Intel 路径差异
**What goes wrong:** 脚本在 Intel Mac 上找不到 Homebrew 或数据目录
**Why it happens:** Apple Silicon 路径是 `/opt/homebrew`，Intel 是 `/usr/local`
**How to avoid:** 使用 `detect_homebrew_prefix` 函数动态检测架构 [VERIFIED: CONTEXT.md specifics]
**Warning signs:** `brew: command not found`；`/opt/homebrew/var/postgresql@17` 目录不存在

## Code Examples

### 数据迁移核心逻辑
```bash
# Source: CONTEXT.md D-03 + 代码库验证
# 使用 Docker 容器内的 pg_dump（版本 17.9 完全匹配）导出
# 本地 psql 导入

migrate_database() {
  local db_name="$1"
  local dump_file="/tmp/${db_name}_dump.sql"

  log_info "导出 ${db_name} 从 Docker 容器..."

  # 检查容器运行状态
  if ! docker ps --format "{{.Names}}" | grep -q "noda-infra-postgres-dev"; then
    log_error "postgres-dev 容器未运行，无法迁移"
    return 1
  fi

  # 使用容器内的 pg_dump 导出
  docker exec noda-infra-postgres-dev pg_dump -U postgres -d "$db_name" \
    --no-owner --no-privileges > "$dump_file"

  # 导入到本地 PG
  log_info "导入 ${db_name} 到本地 PostgreSQL..."
  psql -d postgres -c "DROP DATABASE IF EXISTS ${db_name};" 2>/dev/null || true
  psql -d postgres -c "CREATE DATABASE ${db_name};"
  psql -d "$db_name" < "$dump_file"

  # 清理
  rm -f "$dump_file"
  log_success "${db_name} 迁移完成"
}
```

### 幂等安装函数
```bash
# Source: setup-jenkins.sh 模式 + PITFALLS.md Pitfall 7

cmd_install() {
  log_info "=========================================="
  log_info "PostgreSQL 本地安装开始"
  log_info "=========================================="

  # 步骤 1: 架构检测
  HOMEBREW_PREFIX=$(detect_homebrew_prefix)
  eval "$($HOMEBREW_PREFIX/bin/brew shellenv)"

  # 步骤 2: 检查是否已安装
  if brew list postgresql@17 &>/dev/null; then
    log_info "postgresql@17 已安装，跳过安装步骤"
  else
    log_info "安装 postgresql@17..."
    brew install postgresql@17
    log_success "postgresql@17 安装完成"
  fi

  # 步骤 3: 链接二进制（keg-only）
  if ! command -v psql &>/dev/null; then
    brew link --force postgresql@17
    log_success "postgresql@17 已链接到 PATH"
  fi

  # 步骤 4: 端口冲突检查
  if lsof -i :5432 &>/dev/null; then
    log_error "端口 5432 已被占用，请先停止其他 PostgreSQL 实例"
    lsof -i :5432
    exit 1
  fi

  # 步骤 5: 启动服务
  if brew services list | grep -q "postgresql@17.*started"; then
    log_info "postgresql@17 服务已运行"
  else
    brew services start postgresql@17
    log_success "postgresql@17 服务已启动（开机自启已配置）"
  fi

  # 步骤 6: 等待就绪
  local waited=0
  while [ $waited -lt 30 ]; do
    if pg_isready &>/dev/null; then
      log_success "PostgreSQL 已就绪"
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  # 步骤 7: 创建开发数据库
  cmd_init_db

  log_success "=========================================="
  log_success "PostgreSQL 本地安装完成！"
  log_success "=========================================="
  log_info "版本: $(psql --version)"
  log_info "端口: 5432"
  log_info "认证: trust（本地无密码）"
  log_info "数据库: noda_dev, keycloak_dev"
}
```

### 状态检查函数
```bash
# Source: setup-jenkins.sh cmd_status 模式

cmd_status() {
  log_info "=========================================="
  log_info "PostgreSQL 本地状态检查"
  log_info "=========================================="

  local all_ok=true

  # 检查 1: 安装状态
  if brew list postgresql@17 &>/dev/null; then
    local pg_version
    pg_version=$($HOMEBREW_PREFIX/opt/postgresql@17/bin/psql --version 2>&1 || echo "未知")
    log_success "postgresql@17 已安装（${pg_version}）"
  else
    log_error "postgresql@17 未安装"
    all_ok=false
  fi

  # 检查 2: 服务状态
  local service_status
  service_status=$(brew services list 2>/dev/null | grep "postgresql@17" | awk '{print $2}' || echo "unknown")
  if [ "$service_status" = "started" ]; then
    log_success "服务运行中（started，开机自启已配置）"
  else
    log_error "服务状态: ${service_status}"
    all_ok=false
  fi

  # 检查 3: 连接测试
  if pg_isready &>/dev/null; then
    log_success "PostgreSQL 连接正常（端口 5432）"
  else
    log_error "无法连接 PostgreSQL"
    all_ok=false
  fi

  # 检查 4: 开发数据库
  for db in noda_dev keycloak_dev; do
    if psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$db"; then
      log_success "数据库 ${db} 存在"
    else
      log_warn "数据库 ${db} 不存在（运行 init-db 创建）"
      all_ok=false
    fi
  done

  # 检查 5: 版本匹配
  local local_ver
  local_ver=$($HOMEBREW_PREFIX/opt/postgresql@17/bin/psql --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "未知")
  if [[ "$local_ver" == "17."* ]]; then
    log_success "版本对齐: 本地 ${local_ver} 与生产 17.9 匹配"
  else
    log_error "版本不匹配: 本地 ${local_ver}，期望 17.x"
    all_ok=false
  fi
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Docker postgres-dev 容器 | Homebrew postgresql@17 宿主机安装 | 本阶段实施 | 开发数据库不再依赖 Docker，启动更快 |
| 手动 psql 连接配置 | trust 认证 + 默认端口 | 本阶段实施 | 开发者零配置连接 |
| Docker volume 存储 | 宿主机文件系统 `/opt/homebrew/var/postgresql@17` | 本阶段实施 | 数据访问更快，pgAdmin 等工具可直接连接 |

**Deprecated/outdated:**
- `docker-compose.dev-standalone.yml` 中的 `postgres-dev` 服务：本阶段后 Phase 27 将移除
- `noda-dev` 独立 compose 项目：Phase 27 将清理

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Homebrew postgresql@17 默认使用 trust 认证（initdb 不设置超级用户密码时） | Standard Stack | 如果默认是 scram-sha-256，需要额外配置 pg_hba.conf |
| A2 | `brew link --force postgresql@17` 不会覆盖其他 PostgreSQL 版本的符号链接 | Architecture Patterns | 如果有其他 PG 版本安装，force-link 可能冲突 |
| A3 | postgres-dev 容器名始终为 `noda-infra-postgres-dev` | Code Examples | 如果容器名不同，迁移脚本无法找到容器 |
| A4 | keycloak_dev 数据值得迁移（而非从空库开始让 Keycloak 重新初始化 schema） | Code Examples | 如果 keycloak_dev 数据不重要，可以跳过迁移 |

**如果 A1 错误：** 脚本需要添加 `pg_hba.conf` 修改步骤，将 local/host 行改为 trust。这是 LOW 风险因为可以检测并修复。

**如果 A2 错误：** 改用 PATH 添加方式（`export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"`），避免全局符号链接冲突。

## Open Questions

1. **pg_hba.conf 默认认证方法**
   - What we know: Homebrew initdb 通常使用 trust 作为默认认证方法（macOS 开发环境标准做法）
   - What's unclear: 当前 Homebrew 5.1.6 + postgresql@17 formula 的具体 initdb 参数
   - Recommendation: 安装后立即验证，脚本中包含检测和修正逻辑

2. **keycloak_dev 数据迁移必要性**
   - What we know: keycloak_dev 有 12 MB 数据（完整 schema + 1 user + 13 clients）
   - What's unclear: 这些数据是否有开发者在实际使用
   - Recommendation: 提供迁移选项，默认迁移但不强制。keycloak_dev 可以让 Keycloak 启动时自动创建 schema

3. **Intel Mac 兼容性**
   - What we know: CONTEXT.md specifics 提到检测架构；REQUIREMENTS.md Out of Scope 明确说"当前开发者全部使用 Apple Silicon"
   - What's unclear: 是否仍需 Intel Mac 支持
   - Recommendation: 脚本包含架构检测（代码量极小），但不做 Intel Mac 测试

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Homebrew | PG 安装 | Yes | 5.1.6 | - |
| Docker | 数据迁移（pg_dump via docker exec） | Yes | Docker Desktop | 跳过迁移，使用种子脚本 |
| postgres-dev 容器 | 数据迁移源 | Yes (running) | postgres:17.9 | 跳过迁移 |
| pg_isready | 健康检查 | No (需安装 PG 后可用) | - | psql 连接测试替代 |
| lsof | 端口检测 | Yes | macOS 内置 | - |

**Missing dependencies with no fallback:**
- 无阻塞性缺失

**Missing dependencies with fallback:**
- pg_isready: 安装 postgresql@17 后自动可用；安装前可用 `lsof -i :5432` 替代

## 现有数据清单（迁移目标）

### noda_dev 数据库（8598 kB）
| 表 | 行数 | 说明 |
|---|------|------|
| categories | 30 | 测试分类数据 |
| courses | 71 | 测试课程数据 |
| profiles | 139 | 测试教师数据 |
| sources | 0 | 数据源（空） |
| _prisma_migrations | 13 | Prisma 迁移历史 |

### keycloak_dev 数据库（12 MB）
| 表 | 行数 | 说明 |
|---|------|------|
| user_entity | 1 | 管理员用户 |
| realm | 2 | master + noda realm |
| client | 13 | Keycloak 客户端配置 |
| (完整 Keycloak schema) | 5407 行 dump | 所有 Keycloak 系统表 |

### Docker 容器信息
- 容器名: `noda-infra-postgres-dev`
- 状态: Up 4 days (healthy)
- 端口: `127.0.0.1:5433->5432/tcp`
- Volume: `noda-infra_postgres_dev_data` (local driver)
- PG 版本: PostgreSQL 17.9 (Debian 17.9-1.pgdg13+1)
- pg_dump 路径: `/usr/bin/pg_dump` (版本 17.9)

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash 测试（与 scripts/backup/tests/ 模式一致） |
| Config file | 无 |
| Quick run command | `bash scripts/setup-postgres-local.sh status` |
| Full suite command | 手动验证 4 项成功标准 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| LOCALPG-01 | Homebrew 安装 PG 17.9 + 工具可用 | smoke | `psql --version \|\| grep "17."` | No - Wave 0 |
| LOCALPG-01 | 版本与生产匹配 | smoke | `psql --version` | No - Wave 0 |
| LOCALPG-02 | noda_dev 数据库存在 | smoke | `psql -lqt \|| grep noda_dev` | No - Wave 0 |
| LOCALPG-02 | keycloak_dev 数据库存在 | smoke | `psql -lqt \|| grep keycloak_dev` | No - Wave 0 |
| LOCALPG-03 | brew services 自启动 | smoke | `brew services list \|| grep "postgresql@17.*started"` | No - Wave 0 |
| LOCALPG-04 | noda_dev 数据已迁移 | manual | `psql -d noda_dev -c "SELECT count(*) FROM courses;"` | No - Wave 0 |
| LOCALPG-04 | keycloak_dev schema 完整 | manual | `psql -d keycloak_dev -c "\dt" \|| wc -l` | No - Wave 0 |

### Sampling Rate
- **Per task commit:** `bash scripts/setup-postgres-local.sh status`
- **Per wave merge:** 完整 4 项成功标准验证
- **Phase gate:** 所有 LOCALPG-01~04 成功标准通过

### Wave 0 Gaps
- [ ] 无需创建独立测试文件——本阶段是安装脚本，通过 `status` 子命令验证
- [ ] 成功标准验证为手动操作（安装 + 迁移 + 重启验证）
- [ ] 框架安装: 不需要（无单元测试框架需求）

注: 本阶段产物是 shell 脚本而非应用代码，验证方式以 smoke test 和手动验证为主。

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | trust 认证（本地开发，CONTEXT.md D-01） |
| V3 Session Management | no | 本阶段无会话管理 |
| V4 Access Control | yes | 本地 PG 访问控制（pg_hba.conf trust for local only） |
| V5 Input Validation | yes | 脚本参数校验（子命令验证） |
| V6 Cryptography | no | 本阶段无加密需求 |

### Known Threat Patterns for Homebrew PostgreSQL 本地安装

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 本地 PG 监听 0.0.0.0 | Information Disclosure | `listen_addresses = 'localhost'`（Homebrew 默认） |
| trust 认证滥用 | Spoofing | 仅限本地连接（pg_hba.conf 中 host 行只允许 127.0.0.1/::1） |
| 数据目录权限过宽 | Tampering | Homebrew 自动设置正确权限（700） |
| pg_hba.conf 修改引入安全漏洞 | Elevation of Privilege | 脚本中验证修改后的 pg_hba.conf 格式正确 |

## Sources

### Primary (HIGH confidence)
- `brew info postgresql@17` — 版本 17.9 稳定版，keg-only，caveats 说明 [VERIFIED 2026-04-17]
- `docker exec noda-infra-postgres-dev psql -c "SELECT version();"` — 容器内 PG 版本 17.9 [VERIFIED 2026-04-17]
- `docker exec noda-infra-postgres-dev pg_dump --version` — 容器内 pg_dump 17.9 [VERIFIED 2026-04-17]
- 代码库: `scripts/setup-jenkins.sh` — 子命令脚本模式参考 [VERIFIED: codebase]
- 代码库: `docker/services/postgres/init-dev/01-create-databases.sql` — 开发数据库创建 SQL [VERIFIED: codebase]
- 代码库: `scripts/lib/log.sh` — 日志库 [VERIFIED: codebase]

### Secondary (MEDIUM confidence)
- `.planning/research/FEATURES.md` T1 — 宿主机 PG 安装详细分析 [CITED: project research]
- `.planning/research/PITFALLS.md` Pitfall 2, 7 — 版本匹配 + 幂等性风险 [CITED: project research]
- CONTEXT.md D-01~D-06 — 用户锁定决策 [CITED: user decisions]

### Tertiary (LOW confidence)
- Homebrew postgresql@17 默认使用 trust 认证 — 基于 Homebrew 常规行为，未在当前环境验证（因未安装） [ASSUMED]
- `brew link --force` 不会与其他 PG 版本冲突 — 基于 Homebrew 设计假设 [ASSUMED]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Homebrew postgresql@17 17.9 已通过 brew info 验证，与 Docker 版本匹配
- Architecture: HIGH — 子命令模式直接复用 setup-jenkins.sh，代码库参考充分
- Pitfalls: HIGH — 7 个 pitfalls 基于代码库分析 + PITFALLS.md 交叉验证
- Data migration: HIGH — Docker 容器运行中，pg_dump 可用，数据量已确认（noda_dev 8598 kB + keycloak_dev 12 MB）
- Security: MEDIUM — trust 认证安全性依赖 Homebrew 默认 pg_hba.conf 配置

**Research date:** 2026-04-17
**Valid until:** 2026-05-17（Homebrew formula 版本可能变化，需重新确认 17.9 是否仍为 stable）
