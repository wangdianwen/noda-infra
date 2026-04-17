# Phase 30: 一键开发环境脚本 - Research

**Researched:** 2026-04-17
**Domain:** Shell 脚本 / 开发环境自动化 / Homebrew PostgreSQL
**Confidence:** HIGH

## Summary

Phase 30 的核心任务是创建 `setup-dev.sh` 一键脚本，封装 Phase 26 已完成的 `setup-postgres-local.sh`，为新开发者提供单一入口点搭建完整的本地开发环境。

**核心发现：** Phase 26 已经完成了所有重活——`setup-postgres-local.sh` 包含 540 行完整实现，覆盖 Homebrew 检测、PostgreSQL 安装、数据库创建、幂等检查、状态验证。setup-dev.sh 的角色是"编排层"而非"实现层"，主要负责：(1) 调用已有脚本，(2) 添加前置/后置步骤，(3) 提供开发者友好的状态报告。

**关键约束：** 现有脚本模式（`set -euo pipefail`、`source scripts/lib/log.sh`、步骤编号日志、子命令分发）必须在 setup-dev.sh 中保持一致。项目没有 shell 测试框架（bats/shellcheck 均未安装），测试策略需考虑这一现实。

**Primary recommendation:** setup-dev.sh 应为薄封装层（< 150 行），调用 `setup-postgres-local.sh install` 完成核心工作，额外添加 Homebrew 自身安装检查、环境验证报告和下一步指引。不要重复实现已有功能。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** setup-dev.sh 封装 setup-postgres-local.sh，不替换它
  - setup-dev.sh 调用 setup-postgres-local.sh install 进行 PostgreSQL 安装
  - setup-dev-local.sh 保持独立可用（直接管理 PG）
  - setup-dev.sh 额外处理环境配置和验证

- **D-02:** setup-dev.sh 负责完整的本地开发环境搭建
  - 步骤：1) 检查 Homebrew → 2) 安装 PostgreSQL → 3) 创建开发数据库 → 4) 验证环境
  - 不包含 Docker Compose 启动（开发环境不需要 Docker 服务）
  - 不包含 .env 文件创建（开发者从 .env.example 手动复制）

- **D-03:** 遵循 setup-postgres-local.sh 的幂等模式
  - 已安装的 PostgreSQL 不重新安装（brew list 检查）
  - 已存在的数据库不重新创建（psql 检查）
  - 已运行的服务不重新启动（brew services list 检查）
  - 重运行为 no-op，仅显示当前状态

- **D-04:** 复用 setup-postgres-local.sh 的 detect_homebrew_prefix() 逻辑
  - arm64 → /opt/homebrew
  - x86_64 → /usr/local
  - 不需要额外的架构处理

- **D-05:** 非交互式执行（无人值守安全）
  - 不使用 read -p 等待用户输入
  - 所有操作自动执行，步骤进度通过日志输出
  - 错误时停止并显示修复建议

- **D-06:** 脚本最后执行环境验证，输出状态报告
  - 检查 PostgreSQL 版本（应显示 17.x）
  - 检查开发数据库是否存在（noda_dev, keycloak_dev）
  - 检查 brew services 状态（应显示 started）
  - 输出成功或具体缺失项

- **D-07:** 脚本位于项目根目录 setup-dev.sh
  - 使用方式：`bash setup-dev.sh`
  - source scripts/lib/log.sh 复用日志函数
  - 调用 scripts/setup-postgres-local.sh install

### Claude's Discretion
- setup-dev.sh 具体步骤和日志格式
- 环境验证检查项的具体命令
- 错误信息的具体措辞

### Deferred Ideas (OUT OF SCOPE)
- **Docker Compose 开发环境启动** — 当前开发环境不需要 Docker，保持简单
- **.env 文件自动生成** — 开发者从 .env.example 复制更安全
- **IDE 配置集成** — 超出基础设施范围
- **多版本 PostgreSQL 支持** — 当前仅支持 17.x
- **Linux 支持** — 当前仅支持 macOS (Homebrew)

</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DEVEX-01 | 创建 setup-dev.sh 一键安装脚本，自动完成 Homebrew PG 安装 + 数据库初始化 + 配置 | 核心脚本调用 `setup-postgres-local.sh install`（已实现全部 PG 安装逻辑），额外需 Homebrew 自身安装检查 |
| DEVEX-02 | 脚本幂等设计——重复运行不会破坏现有数据或配置 | setup-postgres-local.sh 已实现完整幂等（brew list/psql/brew services 检查），setup-dev.sh 需在 Homebrew 检查层也保持幂等 |
| DEVEX-03 | 自动检测 Apple Silicon (/opt/homebrew) vs Intel (/usr/local)，适配 Homebrew 路径差异 | detect_homebrew_prefix() 已在 setup-postgres-local.sh 中实现并验证，setup-dev.sh 复用即可 |

</phase_requirements>

## Standard Stack

### Core — 无需安装新依赖

| 库/工具 | 版本 | 用途 | 为什么是标准选择 |
|---------|------|------|-----------------|
| bash | 3.2+ (macOS 自带) | 脚本运行时 | macOS 内置，所有开发者机器可用 [VERIFIED: 本机 bash --version] |
| Homebrew | 5.1.6 | 包管理器 | macOS 标准 PG 安装方式 [VERIFIED: brew --version] |
| postgresql@17 | 17.9 | 开发数据库 | 与生产 postgres:17.9 版本完全匹配 [VERIFIED: brew info postgresql@17] |
| setup-postgres-local.sh | 已存在 | PG 安装/初始化 | Phase 26 完成的 540 行脚本，包含所有 PG 管理功能 [VERIFIED: 文件存在] |
| scripts/lib/log.sh | 已存在 | 日志输出 | 项目标准日志库（log_info/success/warn/error） [VERIFIED: 文件存在] |

### 无需安装的原因

Phase 30 纯粹是 Shell 脚本编写，不需要任何 npm/pip 包。所有依赖（bash、Homebrew、PostgreSQL）要么是 macOS 内置，要么通过 Homebrew 安装（由脚本本身管理）。

**安装命令：** 无需安装任何新工具。

## Architecture Patterns

### 推荐项目结构

```
noda-infra/
├── setup-dev.sh                          # [新建] 一键开发环境入口
├── scripts/
│   ├── setup-postgres-local.sh           # [已有] PG 安装管理（Phase 26）
│   └── lib/
│       └── log.sh                        # [已有] 日志函数库
└── docs/
    └── DEVELOPMENT.md                    # [需更新] 开发环境文档
```

### Pattern 1: 薄编排层模式（推荐）

**What:** setup-dev.sh 作为编排脚本，调用已有专用脚本完成具体工作
**When to use:** 当已有脚本覆盖了大部分功能，只需要高层入口点时
**Example:**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/log.sh"

# 步骤 1/4: 检查 Homebrew
# 步骤 2/4: 安装 PostgreSQL（委托给 setup-postgres-local.sh）
bash "$SCRIPT_DIR/scripts/setup-postgres-local.sh install"
# 步骤 3/4: 环境验证
# 步骤 4/4: 显示状态报告
```

**来源:** 项目现有模式（setup-jenkins.sh 也采用类似子命令委托模式）[VERIFIED: scripts/setup-jenkins.sh]

### Pattern 2: 幂等检查模式

**What:** 每个操作前先检查是否已完成，已完成则跳过
**When to use:** 脚本需要支持重复运行
**Example:**

```bash
# 来自 setup-postgres-local.sh 的现有模式 [VERIFIED: scripts/setup-postgres-local.sh L99-107]
if brew list "$PG_FORMULA" &>/dev/null; then
  log_info "${PG_FORMULA} 已安装，跳过安装步骤"
else
  brew install "$PG_FORMULA"
fi
```

### Anti-Patterns to Avoid

- **重复实现已有功能:** setup-dev.sh 不应重新实现 detect_homebrew_prefix() 或数据库创建逻辑，这些已在 setup-postgres-local.sh 中完成
- **交互式提示:** 根据 D-05 决策，不使用 `read -p` 等待用户输入（setup-postgres-local.sh 的 uninstall 除外，但那不在本脚本范围内）
- **硬编码 Homebrew 路径:** 不应硬编码 `/opt/homebrew` 或 `/usr/local`，必须通过 detect_homebrew_prefix() 动态检测
- **在 setup-dev.sh 中添加子命令:** setup-dev.sh 是单一用途脚本（一键安装），不需要 install/status/uninstall 子命令体系——那些由 setup-postgres-local.sh 提供

## Don't Hand-Roll

| 问题 | 不要自己构建 | 使用现有方案 | 原因 |
|------|-------------|-------------|------|
| PostgreSQL 安装 | 自己写 brew install + 初始化逻辑 | `setup-postgres-local.sh install` | 已包含 10 步完整流程（架构检测、安装、链接、端口检查、服务启动、pg_hba.conf 配置、数据库创建、摘要输出） |
| 架构检测 | 写 uname -m 判断 | `setup-postgres-local.sh` 内的 `detect_homebrew_prefix()` | 已验证支持 arm64 和 x86_64 |
| 数据库创建 | 写 psql/createdb 逻辑 | `setup-postgres-local.sh` 的 `cmd_init_db()` | 已实现幂等检查（psql -lqt 查询已存在数据库） |
| 日志输出 | 自己写 echo/printf | `source scripts/lib/log.sh` | 项目标准，带颜色和统一格式 |
| 环境验证 | 写一套全新的检查 | 复用 `setup-postgres-local.sh status` 子命令 | 已包含 5 项检查（安装/服务/连接/数据库/版本） |

**Key insight:** Phase 26 的 setup-postgres-local.sh 是一个功能完整的 540 行脚本，setup-dev.sh 的大部分工作只需正确调用它。

## Common Pitfalls

### Pitfall 1: Homebrew 未安装

**What goes wrong:** 新 Mac 可能没有安装 Homebrew，脚本直接调用 brew 命令会失败
**Why it happens:** 开发者可能刚拿到新机器，Homebrew 不是 macOS 内置的
**How to avoid:** setup-dev.sh 第一步检查 `command -v brew`，如不存在则提示安装命令
**Warning signs:** `brew: command not found`

### Pitfall 2: setup-postgres-local.sh install 的 pg_hba.conf 修改需要重启

**What goes wrong:** install 命令可能修改 pg_hba.conf 并重启 PostgreSQL，如果此时有其他 PG 连接会被断开
**Why it happens:** Homebrew 默认安装的 pg_hba.conf 可能使用 scram-sha-256 而非 trust
**How to avoid:** 这是 setup-postgres-local.sh 已处理的行为，setup-dev.sh 不需要额外处理；但在日志中让开发者知道可能发生重启
**Warning signs:** setup-postgres-local.sh 输出 "pg_hba.conf 认证方法非 trust，将自动修正"

### Pitfall 3: 端口 5432 被 Docker postgres-dev 占用

**What goes wrong:** 如果开发者仍运行 Docker 版 postgres-dev 容器，本地 PG 启动会失败
**Why it happens:** Phase 27 清理了 compose 定义但旧容器可能仍存在
**How to avoid:** setup-postgres-local.sh install 已包含端口冲突检查（步骤 5/10），会提示开发者停止旧容器
**Warning signs:** "端口 5432 已被占用"

### Pitfall 4: PATH 中没有 Homebrew 的 PostgreSQL 二进制

**What goes wrong:** postgresql@17 是 keg-only，brew link --force 可能需要手动执行
**Why it happens:** Homebrew 不自动链接 keg-only formula
**How to avoid:** setup-postgres-local.sh install 已包含步骤 4/10（链接二进制文件），setup-dev.sh 调用后 psql 应该在 PATH 中可用
**Warning signs:** `psql: command not found`（但 setup-postgres-local.sh install 应该已修复）

### Pitfall 5: 脚本位置假设

**What goes wrong:** 如果 setup-dev.sh 被从非项目根目录执行，路径解析可能失败
**Why it happens:** 使用相对路径或硬编码路径
**How to avoid:** 使用 `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` 和 `PROJECT_ROOT` 变量，与 setup-postgres-local.sh 的模式一致
**Warning signs:** "No such file or directory" 错误

## Code Examples

### setup-dev.sh 骨架（基于项目现有模式）

```bash
#!/bin/bash
set -euo pipefail

# ============================================
# 一键开发环境搭建脚本
# ============================================
# 功能：新开发者运行一个命令即可搭建完整的本地开发环境
# 用途：封装 setup-postgres-local.sh，提供一站式入口
# 使用：bash setup-dev.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/log.sh"

# 常量
SETUP_PG="$SCRIPT_DIR/scripts/setup-postgres-local.sh"
TOTAL_STEPS=4

# ============================================
# 检查 Homebrew 是否已安装
# ============================================
check_homebrew() {
  log_info "步骤 1/${TOTAL_STEPS}: 检查 Homebrew"
  if command -v brew &>/dev/null; then
    log_success "Homebrew 已安装 ($(brew --version | head -1))"
  else
    log_error "Homebrew 未安装"
    log_info "安装命令: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
  fi
}

# ============================================
# 安装 PostgreSQL（委托给 setup-postgres-local.sh）
# ============================================
install_postgresql() {
  log_info "步骤 2/${TOTAL_STEPS}: 安装 PostgreSQL + 创建开发数据库"
  bash "$SETUP_PG" install
}

# ============================================
# 环境验证
# ============================================
verify_environment() {
  log_info "步骤 3/${TOTAL_STEPS}: 环境验证"
  bash "$SETUP_PG" status
}

# ============================================
# 显示下一步指引
# ============================================
show_next_steps() {
  log_info "步骤 4/${TOTAL_STEPS}: 下一步"
  log_success "=========================================="
  log_success "开发环境就绪！"
  log_success "=========================================="
  log_info "连接数据库: psql -d noda_dev"
  log_info "查看 PG 状态: bash scripts/setup-postgres-local.sh status"
  log_info "查看开发文档: docs/DEVELOPMENT.md"
}

# ============================================
# 主流程
# ============================================
log_info "=========================================="
log_info "Noda 开发环境一键搭建"
log_info "=========================================="

check_homebrew
install_postgresql
verify_environment
show_next_steps
```

**来源:** 基于 setup-postgres-local.sh 和 setup-jenkins.sh 的现有模式 [VERIFIED: scripts/setup-postgres-local.sh, scripts/setup-jenkins.sh]

### 环境验证复用

```bash
# setup-postgres-local.sh status 已包含完整的 5 项检查：
# 检查 1/5: postgresql@17 安装状态
# 检查 2/5: 服务状态（brew services）
# 检查 3/5: 连接测试（pg_isready）
# 检查 4/5: 开发数据库（noda_dev, keycloak_dev）
# 检查 5/5: 版本匹配（主版本号 17）
# setup-dev.sh 直接调用 bash "$SETUP_PG" status 即可
```

**来源:** [VERIFIED: scripts/setup-postgres-local.sh L266-335]

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Docker postgres-dev 容器 | Homebrew 本地 PostgreSQL | Phase 26 (v1.5) | 开发环境不再依赖 Docker 运行数据库 |
| 手动 brew install + 手动配置 | setup-postgres-local.sh install | Phase 26 (v1.5) | 自动化 PG 安装和初始化 |
| 多步手动搭建 | setup-dev.sh 一键 | Phase 30 (本阶段) | 新开发者一行命令完成环境搭建 |

**Deprecated/outdated:**
- `docker-compose.dev.yml` 中的 `postgres-dev` 服务定义（Phase 27 已清理）
- `docker-compose.dev-standalone.yml`（如仍存在则应已清理）

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | 新 Mac 开发者一定会有 Homebrew 或愿意安装它 | Architecture Patterns | 低 — Homebrew 是 macOS 开发标准，如果不装则脚本明确提示安装命令 |
| A2 | setup-postgres-local.sh install 的 exit code 可靠反映成功/失败 | Code Examples | 低 — 脚本使用 `set -euo pipefail`，任何失败都会非零退出 |
| A3 | docs/DEVELOPMENT.md 的"本地开发数据库"段落已引用 setup-postgres-local.sh，setup-dev.sh 只需在末尾提示"查看开发文档" | Code Examples | 低 — 已验证 DEVELOPMENT.md 包含相关段落 |
| A4 | 项目没有 shell 测试框架（bats），且 Phase 30 不需要引入 | Validation Architecture | 中 — 如果 planner 认为需要测试，需要额外引入 bats-core |

## Open Questions

1. **setup-dev.sh 是否需要 --verbose 标志？**
   - What we know: CONTEXT.md specific ideas 提到了 --verbose 标志
   - What's unclear: 是否属于 Claude's Discretion 还是 Deferred
   - Recommendation: 标记为 Claude's Discretion，planner 可自行决定。脚本默认简洁，verbose 可选添加。实际上 setup-postgres-local.sh 的日志已经很详细，setup-dev.sh 主要是编排层，--verbose 的价值有限

2. **setup-dev.sh 失败时的错误恢复？**
   - What we know: setup-postgres-local.sh install 内部已有错误处理（端口冲突、启动超时等）
   - What's unclear: 如果 setup-postgres-local.sh install 在中途失败，setup-dev.sh 是否需要提供清理建议
   - Recommendation: 依赖 setup-postgres-local.sh 的错误处理，setup-dev.sh 只需捕获非零退出码并显示通用修复建议（如 "运行 bash scripts/setup-postgres-local.sh status 查看详情"）

## Environment Availability

> Step 2.6: 本机环境审计

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| bash | 脚本运行时 | Yes | 3.2.57 | macOS 内置，无替代 |
| Homebrew | PG 安装 | Yes | 5.1.6 | 脚本检测并提示安装 |
| postgresql@17 (formula) | 开发数据库 | Available (未安装) | 17.9 | 脚本自动安装 |
| psql / pg_isready | 数据库操作 | No (PG 未安装) | — | 安装 PG 后自动可用 |
| bats (测试框架) | Shell 测试 | No | — | 手动测试或引入 bats-core |
| shellcheck | 脚本静态检查 | No | — | 可选，不阻塞 |

**Missing dependencies with no fallback:**
- 无阻塞项 — 所有必需依赖要么已存在（bash），要么由脚本自动安装（PostgreSQL）

**Missing dependencies with fallback:**
- bats/shellcheck — 测试和静态检查工具缺失，可手动验证或后续引入

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | 无（项目没有 shell 测试框架） |
| Config file | 无 |
| Quick run command | `bash setup-dev.sh`（手动验证） |
| Full suite command | 不适用 |

### Phase Requirements -> Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DEVEX-01 | 运行 setup-dev.sh 完成 PG 安装+数据库初始化 | manual-only | `bash setup-dev.sh` | Wave 0 新建 |
| DEVEX-02 | 重复运行 setup-dev.sh 不破坏已有数据 | manual-only | `bash setup-dev.sh` (第二次运行) | Wave 0 新建 |
| DEVEX-03 | Apple Silicon 和 Intel Mac 路径正确检测 | manual-only | 在两种架构上分别运行 | Wave 0 新建 |

### Justification for Manual-Only

DEVEX-01/02/03 都涉及系统状态修改（安装软件、创建数据库），自动化测试需要 mock brew/psql 等系统命令，在纯 shell 项目中成本远高于收益。setup-postgres-local.sh 的核心逻辑已在 Phase 26 验证过。

### Sampling Rate
- **Per task commit:** 手动运行 `bash setup-dev.sh` 验证
- **Per wave merge:** 手动完整流程验证（首次运行 + 重复运行）
- **Phase gate:** 在 Apple Silicon Mac 上完成首次+重复运行验证

### Wave 0 Gaps
- [ ] `setup-dev.sh` — 主脚本（本阶段核心交付物）
- [ ] `docs/DEVELOPMENT.md` 更新 — 添加 setup-dev.sh 使用说明

## Security Domain

> 本阶段不涉及网络服务、认证、加密或外部访问。安全影响极低。

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | 不涉及认证 |
| V3 Session Management | no | 不涉及会话 |
| V4 Access Control | no | 不涉及访问控制 |
| V5 Input Validation | yes | 脚本参数验证（不接受参数，风险极低） |
| V6 Cryptography | no | 不涉及加密 |

### Known Threat Patterns for Shell Scripts

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 命令注入 | Tampering | 脚本不接受外部参数，无注入面 |
| 路径劫持 | Tampering | 使用绝对路径引用 scripts/，`set -euo pipefail` 保护 |

## Sources

### Primary (HIGH confidence)
- `scripts/setup-postgres-local.sh` — Phase 26 创建的完整 PG 管理脚本，540 行，所有核心逻辑的来源
- `scripts/lib/log.sh` — 项目标准日志库，4 个函数
- `scripts/setup-jenkins.sh` — 同类脚本参考（子命令模式、日志复用）
- `scripts/init-databases.sh` — 数据库列表参考（noda_prod, keycloak 为生产；noda_dev, keycloak_dev 为开发）
- `docs/DEVELOPMENT.md` — 当前开发文档，需要更新的目标文件
- `brew info postgresql@17` — 确认 formula 版本 17.9，与生产对齐

### Secondary (MEDIUM confidence)
- `.planning/phases/26-postgresql/26-CONTEXT.md` — Phase 26 决策上下文（引用但未直接读取）
- `.planning/phases/27-docker-compose/27-CONTEXT.md` — Phase 27 清理决策（引用但未直接读取）

### Tertiary (LOW confidence)
- 无 — 所有核心发现均来自代码和文档的直接验证

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 全部依赖已在本机验证存在或可用
- Architecture: HIGH — 基于项目现有 3 个同类脚本的模式分析
- Pitfalls: HIGH — 所有 pitfall 均从 setup-postgres-local.sh 代码中识别

**Research date:** 2026-04-17
**Valid until:** 2026-05-17（稳定，Homebrew/PostgreSQL 不频繁变更）
