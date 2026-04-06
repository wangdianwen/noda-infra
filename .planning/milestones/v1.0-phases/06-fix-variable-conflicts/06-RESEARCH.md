# Phase 6: 修复变量冲突 - Research

**Researched:** 2026-04-06
**Domain:** Bash 脚本变量冲突修复 / 技术债务验证与文档化
**Confidence:** HIGH

## Summary

Phase 6 是一个 Gap Closure 阶段。根据代码库分析，CONTEXT.md 中列出的所有核心变量冲突问题在之前的提交中已实际修复。`lib/constants.sh` 统一定义了所有退出码，health.sh / db.sh / verify.sh 中的重复 `EXIT_*` 定义已被移除，SCRIPT_DIR 变量冲突已通过局部变量解决。

然而，研究发现了若干**尚未解决的不一致性**：(1) `alert.sh` 和 `metrics.sh` 使用裸变量名 `LIB_DIR` 而非 `_*_LIB_DIR` 前缀模式，存在潜在的命名冲突风险；(2) `db.sh`、`verify.sh`、`cloud.sh`、`restore.sh`、`test-verify.sh` 使用 EXIT_* 常量但未显式加载 `constants.sh`，依赖主脚本的加载顺序；(3) 残留的 `.bak` 文件需要清理。

**Primary recommendation:** 本阶段应以验证已有修复 + 补全遗漏的防御性加载 + 清理残留文件为核心任务，而非重新实现已完成的修复。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Phase 6 不涉及新的代码实现，而是文档化和验证已有修复
- **D-02:** 重点确认修复的完整性，避免遗漏任何潜在的冲突点
- **D-03:** 创建验证测试确保修复的有效性
- **D-04:** EXIT_SUCCESS 统一定义在 `lib/constants.sh`（commit f4826e1）
- **D-05:** 移除 health.sh 中的重复 EXIT_SUCCESS 定义（commit f4826e1）
- **D-06:** 使用局部变量解决 SCRIPT_DIR 冲突（commit 2857d8a、a74f859）
- **D-07:** config.sh 条件加载避免 readonly 变量冲突（commit 1b4fb62）
- **D-08:** 验证所有库文件都正确加载 constants.sh
- **D-09:** 确认没有重复的 EXIT_* 定义存在于任何库文件中
- **D-10:** 运行完整测试套件验证修复的有效性
- **D-11:** 创建 06-RESEARCH.md 记录问题分析和解决方案
- **D-12:** 创建 06-PLAN.md 记录验证和文档化计划
- **D-13:** 更新 STATE.md 记录 Phase 6 完成

### Claude's Discretion
- 验证测试的具体实现方式
- 文档的详细程度和结构
- 是否需要额外的重构或优化

### Deferred Ideas (OUT OF SCOPE)
无 -- 这是一个 Gap Closure 阶段，所有工作都聚焦在验证和文档化已有修复。
</user_constraints>

## Standard Stack

### Core (Bash 脚本系统)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Bash | 4+ | 运行时环境 | 项目全部脚本基于 Bash，使用 `set -euo pipefail` |
| shellcheck | 0.9+ | 静态分析 | Bash 脚本 Linter，检测变量冲突和未定义引用 |
| jq | 1.6+ | JSON 处理 | history.json 和 alert_history.json 读写 |
| pg_dump/pg_restore | 15+ | 备份恢复 | PostgreSQL 官方工具 |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| rclone | 1.60+ | 云存储操作 | B2 上传/下载/校验 |
| bc | any | 数学计算 | 磁盘空间百分比计算 |

**Installation:** 无需安装 -- 项目运行在 Docker 容器中，所有依赖已预装。

## Architecture Patterns

### Recommended Project Structure (已实现)
```
scripts/backup/
├── backup-postgres.sh       # 主脚本 (SCRIPT_DIR 入口)
├── restore-postgres.sh      # 恢复脚本 (SCRIPT_DIR 入口)
├── test-verify-weekly.sh    # 每周验证测试 (SCRIPT_DIR 入口)
├── lib/
│   ├── constants.sh         # 统一常量 (readonly 退出码 + 配置)
│   ├── config.sh            # 配置管理 (条件加载)
│   ├── log.sh               # 日志系统 (无依赖)
│   ├── util.sh              # 工具函数 (无依赖)
│   ├── health.sh            # 健康检查 (_HEALTH_LIB_DIR)
│   ├── db.sh                # 数据库操作 (_DB_LIB_DIR)
│   ├── verify.sh            # 备份验证 (_VERIFY_LIB_DIR)
│   ├── cloud.sh             # 云操作 (_CLOUD_LIB_DIR)
│   ├── restore.sh           # 恢复操作 (_RESTORE_LIB_DIR)
│   ├── test-verify.sh       # 测试验证 (_TEST_VERIFY_LIB_DIR)
│   ├── alert.sh             # 告警系统 (LIB_DIR) [见不一致性]
│   └── metrics.sh           # 指标系统 (LIB_DIR) [见不一致性]
└── tests/                   # 测试脚本
```

### Pattern 1: 条件加载 readonly 变量 (已实现)
**What:** 使用变量存在性检查避免重复加载 `constants.sh` 的 readonly 变量
**When to use:** 任何需要 EXIT_* 常量的库文件
**Example:**
```bash
# alert.sh 和 metrics.sh 使用的模式 [VERIFIED: 代码库 lib/alert.sh:15, lib/metrics.sh:15]
if [[ -z "${EXIT_SUCCESS+x}" ]]; then
  source "$LIB_DIR/constants.sh"
fi
```

### Pattern 2: 局部变量避免 SCRIPT_DIR 冲突 (已实现)
**What:** 每个库文件使用带前缀的局部变量定位自身目录
**When to use:** 所有需要定位同目录其他库文件的场景
**Example:**
```bash
# 已统一使用 _*_LIB_DIR 前缀 [VERIFIED: 代码库 lib/db.sh:12, lib/verify.sh:12, lib/cloud.sh:14]
_DB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DB_LIB_DIR/log.sh"
```

### Pattern 3: type 检查避免重复 source 函数
**What:** 使用 `type` 命令检查函数是否已定义
**When to use:** 避免重复加载函数库
**Example:**
```bash
# health.sh 使用的模式 [VERIFIED: 代码库 lib/health.sh:21]
if ! type get_postgres_host &>/dev/null; then
  source "$_HEALTH_LIB_DIR/config.sh"
fi
```

### Anti-Patterns to Avoid
- **裸 LIB_DIR 变量名:** `alert.sh` 和 `metrics.sh` 使用 `LIB_DIR` 而非 `_ALERT_LIB_DIR` / `_METRICS_LIB_DIR`，如果多个库文件被同一脚本 source 且有同名变量，会导致路径覆盖 [VERIFIED: 代码库 lib/alert.sh:12, lib/metrics.sh:12]
- **隐式依赖加载顺序:** `db.sh`、`verify.sh`、`cloud.sh` 使用 EXIT_* 常量但不加载 `constants.sh`，依赖主脚本先加载。如果单独调用这些库或改变加载顺序，将导致未绑定变量错误 [VERIFIED: 代码库 lib/db.sh:62-65, lib/verify.sh:39, lib/cloud.sh:85]
- **残留 .bak 文件:** `db.sh.bak` 和 `db.sh.bak2` 仍存在于 lib 目录中，可能造成混淆 [VERIFIED: 文件系统]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Bash 变量冲突检测 | 自定义 grep 脚本 | `shellcheck` + `grep -r 'readonly EXIT_' lib/` | shellcheck 覆盖更多边界情况 |
| readonly 重复定义 | try/catch 包装 | 条件加载 `if [[ -z "${VAR+x}" ]]` | Bash 原生支持，简洁可靠 |
| 函数重复 source | 追踪数组 | `type -t function_name` 检查 | 已被 health.sh、alert.sh、metrics.sh 采用 |

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | 无 -- 脚本不修改数据库中的数据模式，history.json 和 alert_history.json 使用变量名作为 JSON 键，不涉及变量冲突 | 无 |
| Live service config | Docker 容器中的 crontab 引用 `/app/backup-postgres.sh` -- 路径不受变量冲突影响 | 无 |
| OS-registered state | 容器中的 PID 文件 `/tmp/backup-postgres.pid` -- 不涉及重命名 | 无 |
| Secrets/env vars | `.env.backup` 文件中的 `POSTGRES_HOST`、`BACKUP_DIR` 等配置 -- 与变量冲突无关 | 无 |
| Build artifacts | `lib/db.sh.bak` 和 `lib/db.sh.bak2` 是残留备份文件，不影响运行但应清理 | 代码清理（删除 .bak 文件） |

**Nothing found in category:** Stored data、Live service config、OS-registered state、Secrets/env vars -- 均与变量冲突修复无关。

## Common Pitfalls

### Pitfall 1: 隐式 EXIT_* 依赖 (关键发现)
**What goes wrong:** `db.sh`、`verify.sh`、`cloud.sh`、`restore.sh`、`test-verify.sh` 使用 EXIT_* 常量但从不显式加载 `constants.sh`。它们依赖调用者（主脚本）已经加载了 constants.sh。
**Why it happens:** 主脚本 `backup-postgres.sh` 第 20 行首先加载 `constants.sh`，然后加载所有库文件。在这种加载顺序下一切正常。但库文件头部的依赖注释不准确（如 db.sh 注释 "依赖：log.sh, util.sh"，未提及 constants.sh）。
**How to avoid:** 每个使用 EXIT_* 的库文件都应添加条件加载，如 alert.sh 和 metrics.sh 的模式。
**Warning signs:** `set -u`（nounset）模式下，如果库文件被单独 source 测试，将立即报 `EXIT_SUCCESS: unbound variable` 错误。

### Pitfall 2: 不一致的 LIB_DIR 命名
**What goes wrong:** `alert.sh` 和 `metrics.sh` 使用裸变量名 `LIB_DIR`，而其他 7 个库文件使用 `_ALERT_LIB_DIR` / `_METRICS_LIB_DIR` 等带前缀的变量名。当 metrics.sh source alert.sh（第 29 行），两者的 `LIB_DIR` 值相同（同在 lib/ 目录），所以目前不会出错，但这是非故意的一致而非设计保证。
**Why it happens:** alert.sh 和 metrics.sh 可能在不同时间编写，未遵循已建立的命名约定。
**How to avoid:** 统一使用 `_ALERT_LIB_DIR` 和 `_METRICS_LIB_DIR` 前缀。
**Warning signs:** 如果未来有库文件从不同目录 source alert.sh 或 metrics.sh，`LIB_DIR` 变量会被覆盖。

### Pitfall 3: test-verify-weekly.sh 语法错误
**What goes wrong:** `test-verify-weekly.sh` 第 318 行 `print_summary()` 后缺少函数调用括号，应为 `print_summary`（不带括号，作为命令调用），但实际上 `print_summary()` 会尝试定义新函数而非调用已有函数。
**Why it happens:** 括号导致 `()` 被解析为函数定义语法，而非函数调用。
**How to avoid:** 将 `print_summary()` 改为 `print_summary`。
**Warning signs:** 该语法实际上在 Bash 中会创建一个同名空函数并覆盖原函数，导致总结不打印。

### Pitfall 4: db.sh 使用硬编码连接参数
**What goes wrong:** `db.sh` 第 29 行 `discover_databases()` 和第 53 行 `backup_database()` 硬编码了 `-h noda-infra-postgres-1 -U postgres`，未使用 config.sh 的 getter 函数。而 health.sh 正确使用了 getter 函数。
**Why it happens:** db.sh 可能是早期实现，后续 health.sh 改进了模式但未回溯更新 db.sh。
**How to avoid:** 使用 `get_postgres_host()` / `get_postgres_user()` 等 getter 函数。
**Warning signs:** 如果 POSTGRES_HOST 环境变量被更改，db.sh 的数据库发现和备份将连接到错误的主机。

## Code Examples

### 条件加载 constants.sh 的推荐模式 (alert.sh 已使用)
```bash
# Source: [VERIFIED: lib/alert.sh:14-18]
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 条件 source constants.sh（避免重复定义 readonly 变量）
if [[ -z "${EXIT_SUCCESS+x}" ]]; then
  source "$LIB_DIR/constants.sh"
fi
```

### 局部变量目录定位的推荐模式
```bash
# Source: [VERIFIED: lib/db.sh:12, lib/cloud.sh:14, lib/verify.sh:12]
_DB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DB_LIB_DIR/log.sh"
source "$_DB_LIB_DIR/util.sh"
```

### type 检查避免重复 source 函数
```bash
# Source: [VERIFIED: lib/health.sh:21-23]
if ! type get_postgres_host &>/dev/null; then
  source "$_HEALTH_LIB_DIR/config.sh"
fi
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| 每个 lib 文件各自定义 EXIT_* | 统一在 constants.sh 中 readonly 声明 | commit f4826e1 | 消除重复定义冲突 |
| 使用全局 SCRIPT_DIR | 使用 _*_LIB_DIR 局部变量 | commit 2857d8a, a74f859 | 消除 SCRIPT_DIR 变量覆盖 |
| 直接 source config.sh | 使用 type 检查条件 source | commit 1b4fb62 | 避免重复加载 readonly 变量 |

**Deprecated/outdated:**
- `db.sh.bak` / `db.sh.bak2`: 修复前的备份文件，应删除

## Assumptions Log

> 所有 claims 均通过代码库直接验证，无 [ASSUMED] 标记。

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| - | (无 [ASSUMED] claims) | - | - |

**If this table is empty:** All claims in this research were verified or cited -- no user confirmation needed.

## Open Questions

1. **D-01 "不涉及新的代码实现" vs 发现的不一致性**
   - What we know: CONTEXT.md D-01 说"不涉及新的代码实现"，但研究发现了若干真实的代码不一致性（隐式依赖、LIB_DIR 命名、硬编码连接参数、.bak 残留）
   - What's unclear: "不涉及新代码" 是严格指"不写任何代码"还是"不开发新功能但可以修复小问题"
   - Recommendation: 在 PLAN 中将这些分为两个层次：(a) 验证任务（纯验证，不改动代码），(b) 可选修复任务（小的代码清理，需要用户确认）

2. **test-verify-weekly.sh 的 print_summary() 语法**
   - What we know: 第 318 行 `print_summary()` 带括号，在 Bash 中会被解析为函数定义而非函数调用
   - What's unclear: 这是真实的 bug 还是有意为之（测试脚本中，后续代码可能不依赖此输出）
   - Recommendation: 标记为待确认的 bug，如果确认则需要修复

## Environment Availability

> 本阶段为代码验证和文档化，无外部依赖。

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Bash 4+ | 脚本运行 | ✓ | macOS 默认 | -- |
| shellcheck | 静态分析 (可选) | 需确认 | -- | 使用 grep 手动验证 |
| Docker | 端到端测试 | ✓ | 24+ | -- |
| jq | JSON 处理 | ✓ | 1.6+ | -- |

**Missing dependencies with no fallback:**
- 无

**Missing dependencies with fallback:**
- shellcheck -- 可使用 grep + 代码审查替代

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash 脚本 + 端到端测试（非 formal test framework） |
| Config file | 无 |
| Quick run command | `bash -n scripts/backup/lib/*.sh` (语法检查) |
| Full suite command | Docker 容器端到端测试（参考 TEST_REPORT.md） |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| D-08 | 所有库文件正确加载 constants.sh | unit | `grep -c 'source.*constants.sh\\|EXIT_SUCCESS+x' scripts/backup/lib/*.sh` | -- Wave 0 |
| D-09 | 无重复 EXIT_* 定义 | unit | `grep -r '^readonly EXIT_' scripts/backup/lib/*.sh` | -- Wave 0 |
| D-10 | 完整测试套件通过 | e2e | Docker 容器运行 backup-postgres.sh | -- Wave 0 |

### Sampling Rate
- **Per task commit:** `bash -n scripts/backup/lib/*.sh` (语法检查)
- **Per wave merge:** `grep -r 'readonly EXIT_' scripts/backup/lib/ | grep -v constants.sh` (确认无重复)
- **Phase gate:** 全部验证通过

### Wave 0 Gaps
- [ ] 无 formal test framework -- 使用 grep + bash -n + 端到端测试替代
- [ ] 已有 TEST_REPORT.md 记录端到端测试结果（17/17 通过）

*(If no gaps: "现有验证手段足够覆盖本阶段需求")*

## Security Domain

> 本阶段为技术债务验证和文档化，不涉及安全功能变更。

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | 不涉及 |
| V3 Session Management | no | 不涉及 |
| V4 Access Control | no | 不涉及 |
| V5 Input Validation | no | 不涉及 |
| V6 Cryptography | no | 不涉及 |

### Known Threat Patterns for Bash Script Maintenance

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 残留 .bak 文件泄露历史信息 | Information Disclosure | 删除 .bak 文件 |
| 硬编码连接参数 | Tampering | 使用 getter 函数 |

## Sources

### Primary (HIGH confidence)
- 代码库直接验证 -- 所有 lib/*.sh 文件逐一阅读分析
- git 历史记录 -- CONTEXT.md 引用的 commit (f4826e1, 2857d8a, a74f859, 1b4fb62, 0af4989)
- TEST_REPORT.md -- 端到端测试报告 (17/17 通过)

### Secondary (MEDIUM confidence)
- CONTEXT.md -- Phase 6 上下文文档（记录已完成的修复）

### Tertiary (LOW confidence)
- 无

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- 直接验证代码库中的所有文件
- Architecture: HIGH -- 逐一分析了 12 个 lib 文件和 3 个主脚本的加载模式
- Pitfalls: HIGH -- 通过代码审查发现实际的不一致性

**Research date:** 2026-04-06
**Valid until:** 30 天（Bash 脚本模式稳定）
