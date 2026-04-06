# Phase 8: 执行恢复脚本 - Research

**Researched:** 2026-04-06
**Domain:** PostgreSQL 数据库恢复脚本验证与测试
**Confidence:** HIGH

## Summary

阶段 8 的核心任务是**验证已实现的恢复脚本功能**，确保符合 RESTORE-01 到 RESTORE-04 四个需求。恢复脚本已在阶段 3 完整实现并通过 UAT 测试（5/5 通过），本阶段专注于正式验证、边界测试和文档补充。

经过代码审查和环境检查，发现以下关键事实：

1. **恢复功能已完整实现**：`restore-postgres.sh` 主脚本和 `lib/restore.sh` 库已实现所有四个需求（列出备份、指定恢复、恢复到不同数据库、完整性验证）。[VERIFIED: 代码审查]

2. **关键兼容性问题**：`restore.sh` 中的 `restore_database()` 和 `verify_backup_integrity()` 直接调用 `psql`/`pg_restore` 命令，但 macOS 宿主机上未安装 PostgreSQL 客户端工具。宿主机上只有 `sha256sum`（Darwin 版），缺少 `psql`、`pg_dump`、`pg_restore`、`numfmt`。容器内 `noda-infra-postgres-1` 有完整的 PostgreSQL 工具链。[VERIFIED: 环境检查]

3. **`verify.sh` 有宿主机/容器检测但 `restore.sh` 没有**：`verify.sh` 通过 `/.dockerenv` 检测运行环境，在宿主机时使用 `docker exec` 封装命令。但 `restore.sh` 没有这个逻辑，直接调用裸命令。[VERIFIED: 代码对比]

4. **`test_restore_quick.sh` 在宿主机上可运行**：它通过 `docker exec` 执行数据库操作（创建数据库、备份、恢复），但 `verify_backup_integrity()` 函数在第 58 行被直接调用，而该函数内部调用 `pg_restore -l`（无 docker exec 封装），在宿主机上会失败。[VERIFIED: 代码审查]

**Primary recommendation:** 验证恢复脚本在当前环境（macOS 宿主机 + Docker PostgreSQL 容器）下的实际运行能力，修复 `restore.sh` 中缺少 `docker exec` 封装的问题，然后运行端到端验证测试。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 创建自动化验证脚本 `verify-restore.sh`，对照阶段 8 的 4 个成功标准逐项测试并生成报告
- **D-02:** 验证脚本应测试每个成功标准，记录通过/失败状态和具体证据
- **D-03:** 复用阶段 3 的 UAT 测试结果作为基线，补充新的验证测试
- **D-04:** 创建 `08-VERIFICATION.md` 文档，包含 4 个主要部分（成功标准验证、测试用例覆盖、边界情况和错误处理、使用指南）
- **D-05:** 文档应包含具体命令示例和预期输出，便于运维人员使用
- **D-06:** 执行完整的端到端集成测试：备份 -> 云上传 -> 下载 -> 恢复 -> 验证
- **D-07:** 使用临时数据库进行测试，确保不影响生产环境
- **D-08:** 测试应验证整个数据链路的完整性，包括 B2 云存储的下载功能
- **D-09:** 网络故障处理：测试网络中断、B2 不可用、认证失败等场景的恢复能力
- **D-10:** 恢复失败场景：处理损坏的备份文件、磁盘空间不足、数据库连接失败
- **D-11:** 数据库冲突：处理恢复到已存在的数据库、权限不足、SQL 错误等情况
- **D-12:** 性能和并发：测试大文件恢复、并发恢复请求、部分下载恢复等场景
- **D-13:** 所有测试应在独立的 Docker 容器或临时数据库中执行
- **D-14:** 测试数据应使用小型测试数据库，避免长时间运行
- **D-15:** 测试后应自动清理临时资源（临时数据库、下载的备份文件）

### Claude's Discretion
- 验证脚本的具体输出格式和报告结构
- 集成测试的具体执行顺序和检查点
- 边界情况测试的优先级和覆盖范围
- 文档的具体组织结构和详细程度

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| RESTORE-01 | 提供一键恢复脚本，可从云存储下载并恢复数据库 | `restore-postgres.sh` 已实现，需验证 `restore.sh` 中 `docker exec` 封装缺失问题 |
| RESTORE-02 | 支持列出所有可用的备份文件（按时间排序） | `list_backups_b2()` 已实现，使用 rclone ls |
| RESTORE-03 | 支持恢复指定的数据库（不影响其他运行中的数据库） | `restore_database()` 已实现，但宿主机环境缺少 psql/pg_restore |
| RESTORE-04 | 支持恢复到不同的数据库名（用于安全测试） | `--database` 参数已实现，传递给 `restore_database()` |
</phase_requirements>

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---|---|---|---|
| bash | 3.2.57 (macOS) | 脚本运行时 | 系统自带，所有脚本基于 bash |
| rclone | 1.73.3 | B2 云存储访问 | 项目选定工具，Phase 7 已验证 [VERIFIED: 环境检查] |
| Docker | 29.1.3 | 容器化 PostgreSQL | 项目基础设施 [VERIFIED: 环境检查] |
| PostgreSQL (容器内) | 17.9 | 数据库引擎 | 容器内完整工具链（psql, pg_dump, pg_restore）[VERIFIED: docker exec] |

### Supporting
| Library/Tool | Version | Purpose | When to Use |
|---|---|---|---|
| jq | - | JSON 解析（元数据文件） | 元数据文件读取 |
| sha256sum | Darwin 1.0 | 校验和计算 | 备份验证 |
| bc | - | 浮点运算 | 文件大小格式化（list_backups_b2 中使用） |

### 已有脚本资产（可复用）
| 文件 | 功能 | 状态 |
|---|---|---|
| `scripts/backup/restore-postgres.sh` | 恢复主脚本（CLI 入口） | 已实现 |
| `scripts/backup/lib/restore.sh` | 恢复核心库（列出、下载、恢复、验证） | 已实现，有兼容性问题 |
| `scripts/backup/lib/cloud.sh` | B2 云操作库 | 已验证（Phase 7） |
| `scripts/backup/lib/verify.sh` | 备份验证库（有宿主机检测） | 已验证 |
| `scripts/backup/lib/config.sh` | 配置管理 | 已验证 |
| `scripts/backup/lib/constants.sh` | 常量定义 | 已验证 |
| `scripts/backup/tests/test_restore_quick.sh` | 快速恢复测试 | 已实现 |
| `scripts/backup/tests/test_restore.sh` | 完整恢复测试 | 已实现 |
| `scripts/backup/tests/create_test_db.sh` | 测试数据库创建/清理 | 已实现 |

## Architecture Patterns

### 项目已建立的脚本架构
```
scripts/backup/
├── restore-postgres.sh          # 恢复主脚本（CLI 入口）
├── backup-postgres.sh           # 备份主脚本（参考）
├── .env.backup                  # 环境配置
├── lib/
│   ├── constants.sh             # 统一常量定义（退出码等）
│   ├── config.sh                # 配置管理（.env.backup 加载）
│   ├── log.sh                   # 统一日志格式
│   ├── util.sh                  # 工具函数（时间戳、校验和）
│   ├── db.sh                    # 数据库操作（发现、备份）
│   ├── health.sh                # 健康检查
│   ├── cloud.sh                 # B2 云操作（rclone 封装）
│   ├── restore.sh               # 恢复核心库
│   ├── verify.sh                # 备份验证库
│   ├── alert.sh                 # 告警通知
│   └── metrics.sh               # 指标记录
└── tests/
    ├── create_test_db.sh        # 测试数据库创建
    ├── test_restore.sh          # 完整恢复测试
    ├── test_restore_quick.sh    # 快速恢复测试
    └── ...                      # 其他测试脚本
```

### Pattern 1: 宿主机/容器环境检测
**What:** 检测脚本是否在 Docker 容器内运行，选择正确的命令执行方式
**When to use:** 任何需要调用 PostgreSQL 工具（psql, pg_dump, pg_restore）的函数
**Example:**
```bash
# 来自 lib/verify.sh 的已有模式
if [[ -f /.dockerenv ]]; then
  # 容器内：直接使用命令
  pg_restore --list "$backup_file"
else
  # 宿主机：使用 docker exec 封装
  docker exec noda-infra-postgres-1 pg_restore --list "$backup_file"
fi
```
**Source:** [VERIFIED: lib/verify.sh 第 38-55 行]

### Pattern 2: 统一测试框架
**What:** 使用符号前缀的轻量级测试框架
**When to use:** 所有测试脚本
**Example:**
```bash
# 来自 test_restore.sh 的已有模式
test_start() { echo "▶️  测试: $1"; }
test_pass()  { echo "✅ 通过: $1"; ((TESTS_PASSED++)); }
test_fail()  { echo "❌ 失败: $1"; echo "   原因: $2"; ((TESTS_FAILED++)); }
```
**Source:** [VERIFIED: test_restore.sh 第 21-35 行]

### Pattern 3: Docker exec 数据库操作
**What:** 通过 docker exec 在 PostgreSQL 容器内执行 SQL 命令
**When to use:** 宿主机上执行任何数据库操作
**Example:**
```bash
# 来自 test_restore_quick.sh 的已有模式
docker exec noda-infra-postgres-1 psql -U postgres -d postgres -c "CREATE DATABASE test_db;"
docker exec noda-infra-postgres-1 pg_restore -U postgres -d target_db backup_file
```
**Source:** [VERIFIED: test_restore_quick.sh]

### Pattern 4: rclone 临时配置管理
**What:** 每次操作创建临时 rclone 配置文件，使用后清理
**When to use:** 任何 B2 云操作
**Example:**
```bash
# 来自 lib/cloud.sh
rclone_config=$(setup_rclone_config)
rclone ls "b2remote:${bucket}/${path}" --config "$rclone_config"
cleanup_rclone_config "$rclone_config"
```
**Source:** [VERIFIED: lib/cloud.sh 第 36-74 行]

### Anti-Patterns to Avoid
- **直接调用 psql/pg_restore 在宿主机上**: 宿主机没有 PostgreSQL 客户端工具，必须通过 `docker exec` 封装
- **忽略 set -euo pipefail**: 所有脚本必须使用严格模式
- **忘记清理 rclone 配置文件**: 包含 B2 凭证的临时文件必须删除
- **在测试中使用生产数据库**: 必须使用独立测试数据库（test_restore_* 前缀）

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---|---|---|---|
| B2 云存储访问 | 自定义 HTTP API 调用 | rclone + cloud.sh 封装 | Phase 7 已验证的成熟方案 |
| 备份验证逻辑 | 自定义文件格式检查 | pg_restore --list + verify.sh | 已有实现且经过验证 |
| 配置管理 | 自定义配置解析 | config.sh load_config() | 已有完整的优先级系统 |
| 日志输出 | 自定义日志函数 | log.sh（log_info/warn/error/success） | 项目统一的日志格式 |
| 临时文件管理 | 手动管理临时目录 | mktemp + cleanup_rclone_config | 已有安全模式 |

## Common Pitfalls

### Pitfall 1: restore.sh 缺少 docker exec 封装
**What goes wrong:** `restore_database()` 和 `verify_backup_integrity()` 直接调用 `psql`/`pg_restore`，在 macOS 宿主机上运行会报 "command not found" 错误
**Why it happens:** `restore.sh` 是在阶段 3 创建的，当时可能假设脚本会在容器内运行或有 PostgreSQL 客户端
**How to avoid:** 为 `restore.sh` 添加与 `verify.sh` 相同的 `/.dockerenv` 检测逻辑，在宿主机上使用 `docker exec` 封装
**Warning signs:** 运行 `./restore-postgres.sh --list-backups` 成功但 `--restore` 失败，错误信息为 "command not found"
**Confidence:** HIGH [VERIFIED: 代码审查 + 环境检查]

### Pitfall 2: test_restore_quick.sh 的 verify_backup_integrity 调用会失败
**What goes wrong:** 第 58 行直接调用 `verify_backup_integrity "$backup_file"`，该函数内部调用 `pg_restore -l`（无 docker exec 封装，在 restore.sh 的版本中）
**Why it happens:** `restore.sh` 中的 `verify_backup_integrity()` 和 `verify.sh` 中的 `verify_backup_readable()` 是不同的函数，前者没有环境检测
**How to avoid:** 修复 `restore.sh` 中的函数，或改用 `verify.sh` 中经过验证的函数
**Warning signs:** test_restore_quick.sh 在第 3 步（验证）失败
**Confidence:** HIGH [VERIFIED: 代码审查]

### Pitfall 3: list_backups_b2 依赖 rclone 配置的正确性
**What goes wrong:** 如果 .env.backup 中的 B2 凭证过期或错误，列出备份会静默失败（输出空列表而非错误）
**Why it happens:** `rclone ls` 失败时 `|| true` 吞掉了错误，返回空结果
**How to avoid:** 验证 B2 凭证有效性，在列出结果为空时区分"没有备份"和"连接失败"
**Warning signs:** --list-backups 输出为空但没有错误信息
**Confidence:** MEDIUM [VERIFIED: 代码审查 restore.sh 第 43 行]

### Pitfall 4: 恢复操作需要交互确认
**What goes wrong:** `restore_database()` 第 205-209 行使用 `read -p` 等待用户确认，自动化测试中会阻塞
**Why it happens:** 安全设计要求恢复前确认
**How to avoid:** 测试脚本使用 `echo "yes" | restore_database ...` 管道输入确认
**Warning signs:** 测试脚本在恢复步骤挂起
**Confidence:** HIGH [VERIFIED: test_restore_quick.sh 第 68 行已有此模式]

### Pitfall 5: util.sh 中 calculate_checksum 使用 sha256sum
**What goes wrong:** macOS 上有 sha256sum（Darwin 版本 1.0），但不是所有 macOS 版本都有
**Why it happens:** macOS 和 Linux 的校验和工具不同
**How to avoid:** 检查 sha256sum 是否可用，不可用时回退到 shasum -a 256
**Warning signs:** 校验和计算报错
**Confidence:** MEDIUM [VERIFIED: sha256sum 在当前 macOS 环境可用]

### Pitfall 6: 备份文件路径映射
**What goes wrong:** B2 上的备份文件路径是 `backups/postgres/YYYY/MM/DD/filename`，但下载时需要正确构建路径
**Why it happens:** `download_backup()` 使用 `rclone copy` 下载整个目录中的匹配文件
**How to avoid:** 确保 `get_b2_path()` 返回的路径与实际 B2 结构匹配
**Warning signs:** 下载成功但找不到文件
**Confidence:** HIGH [VERIFIED: cloud.sh 第 119-123 行]

## Code Examples

### 已有的恢复脚本核心函数调用链
```bash
# 来源: restore-postgres.sh + lib/restore.sh [VERIFIED: 代码审查]
# 列出备份
./scripts/backup/restore-postgres.sh --list-backups
# -> main() -> list_backups_b2()
# -> setup_rclone_config() -> rclone ls -> cleanup_rclone_config()

# 恢复到不同数据库（RESTORE-04）
./scripts/backup/restore-postgres.sh --restore dbname_20260406_081638.dump --database test_restored
# -> main() -> download_backup() -> restore_database()
# -> setup_rclone_config() -> rclone copy -> cleanup_rclone_config()
# -> psql DROP/CREATE -> pg_restore -> 验证表数量

# 仅验证备份（RESTORE-01 的验证部分）
./scripts/backup/restore-postgres.sh --restore dbname_20260406_081638.dump --verify
# -> main() -> download_backup() -> verify_backup_integrity()
```

### 已有的测试数据库模式
```bash
# 来源: test_restore_quick.sh [VERIFIED: 代码审查]
# 在容器内创建测试数据库
docker exec noda-infra-postgres-1 psql -U postgres -d postgres \
  -c "DROP DATABASE IF EXISTS test_restore_quick;"
docker exec noda-infra-postgres-1 psql -U postgres -d postgres \
  -c "CREATE DATABASE test_restore_quick;"

# 创建测试数据
docker exec noda-infra-postgres-1 psql -U postgres -d test_restore_quick <<SQL
CREATE TABLE users (id SERIAL PRIMARY KEY, name VARCHAR(100));
INSERT INTO users (name) VALUES ('Alice'), ('Bob'), ('Charlie');
SQL

# 使用管道输入确认恢复
echo "yes" | restore_database "$backup_file" "test_restore_restored"

# 清理
docker exec noda-infra-postgres-1 psql -U postgres -d postgres \
  -c "DROP DATABASE IF EXISTS test_restore_quick;"
```

### 已有的宿主机/容器检测模式（来自 verify.sh）
```bash
# 来源: lib/verify.sh 第 38-55 行 [VERIFIED: 代码审查]
verify_backup_readable() {
  local backup_file=$1

  if [[ -f /.dockerenv ]]; then
    # 容器内：直接使用 pg_restore
    if PGPASSWORD=$POSTGRES_PASSWORD pg_restore --list -h noda-infra-postgres-1 -U postgres "$backup_file" > /dev/null 2>&1; then
      log_success "备份文件可读性验证通过"
      return 0
    fi
  else
    # 宿主机：使用 docker exec
    if docker exec noda-infra-postgres-1 pg_restore --list "$backup_file" > /dev/null 2>&1; then
      log_success "备份文件可读性验证通过"
      return 0
    fi
  fi
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|---|---|---|---|
| 直接调用 psql/pg_restore | docker exec 封装 | Phase 1（verify.sh） | restore.sh 未跟进，需修复 |
| 固定 B2 路径 | 动态日期路径 (YYYY/MM/DD) | Phase 2 | 备份按日期组织 |

**Deprecated/outdated:**
- restore.sh 中的 `verify_backup_integrity()` 函数：应复用 verify.sh 中更完善的 `verify_backup_readable()` 函数

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|---|---|---|---|---|
| Docker | PostgreSQL 容器 | ✓ | 29.1.3 | - |
| rclone | B2 云操作 | ✓ | 1.73.3 | - |
| PostgreSQL 容器 | 数据库操作 | ✓ | 17.9 (healthy) | - |
| psql (宿主机) | restore.sh 恢复操作 | ✗ | - | docker exec 封装 |
| pg_restore (宿主机) | restore.sh 恢复操作 | ✗ | - | docker exec 封装 |
| sha256sum | 校验和计算 | ✓ | Darwin 1.0 | shasum -a 256 |
| bc | 文件大小格式化 | ✓ | - | - |
| jq | JSON 解析 | ✓ | - | - |
| numfmt | 大小格式化 | ✗ | - | 纯数字输出 |

**Missing dependencies with no fallback:**
- 无阻塞性缺失。psql/pg_restore 通过 docker exec 封装解决。

**Missing dependencies with fallback:**
- numfmt 不可用 -> db.sh 中已使用 `|| echo $current_size` 作为回退，不影响功能

## Validation Architecture

### Test Framework
| Property | Value |
|---|---|
| Framework | Bash 轻量级测试（test_start/test_pass/test_fail 模式） |
| Config file | 无独立配置文件 |
| Quick run command | `bash scripts/backup/tests/test_restore_quick.sh` |
| Full suite command | `bash scripts/backup/tests/test_restore.sh && bash scripts/backup/restore-postgres.sh --list-backups` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|---|---|---|---|---|
| RESTORE-01 | 一键恢复脚本从 B2 下载并恢复 | integration | `bash scripts/backup/restore-postgres.sh --restore <file>` | ✓ 脚本存在 |
| RESTORE-02 | 列出 B2 备份按时间排序 | smoke | `bash scripts/backup/restore-postgres.sh --list-backups` | ✓ 脚本存在 |
| RESTORE-03 | 恢复指定数据库不影响其他 | integration | `bash scripts/backup/tests/test_restore_quick.sh` | ✓ 脚本存在 |
| RESTORE-04 | 恢复到不同数据库名 | integration | `bash scripts/backup/restore-postgres.sh --restore <f> --database test_x` | ✓ 脚本存在 |

### Sampling Rate
- **Per task commit:** `bash scripts/backup/tests/test_restore_quick.sh`
- **Per wave merge:** 完整恢复流程测试（list + restore + verify）
- **Phase gate:** 所有 4 个需求的验证测试通过

### Wave 0 Gaps
- [ ] `scripts/backup/verify-restore.sh` -- 自动化验证脚本（D-01），对照 4 个成功标准逐项测试
- [ ] `restore.sh` 中 `restore_database()` 和 `verify_backup_integrity()` 需要 docker exec 封装修复
- [ ] `restore-postgres.sh` 的 `--restore` 在宿主机上需要文件路径处理（下载到宿主机 vs 容器内路径）

## Security Domain

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---|---|---|
| V2 Authentication | yes | PostgreSQL 密码通过 .pgpass / PGPASSWORD 管理 |
| V4 Access Control | yes | B2 Application Key 限制为最小权限 |
| V5 Input Validation | yes | 文件名格式正则验证（restore.sh 第 102-104 行） |
| V6 Cryptography | no | 无自定义加密需求 |

### Known Threat Patterns for Bash/PostgreSQL Restore
| Pattern | STRIDE | Standard Mitigation |
|---|---|---|
| SQL injection via db name | Tampering | 文件名正则验证 `[^_]+_[0-9]{8}_[0-9]{6}` |
| Credential exposure in logs | Information Disclosure | rclone 配置临时文件使用 chmod 600 |
| B2 credential leakage | Information Disclosure | .env.backup 在 .gitignore 中 |
| Accidental production DB drop | Denial of Service | 恢复前交互确认 + 目标数据库名验证 |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|---|---|---|
| A1 | Phase 3 UAT 测试 5/5 通过的结果仍然有效 | Summary | 需要重新运行验证 |
| A2 | B2 凭证仍然有效（.env.backup 中的密钥未过期） | Environment | 列出/下载备份会失败 |
| A3 | restore.sh 在设计时没有考虑宿主机运行环境 | Pitfall 1 | 可能有其他未发现的环境假设 |
| A4 | verify-restore.sh 应遵循 verify.sh 的宿主机检测模式 | Architecture | 需要另外设计 |

## Open Questions (RESOLVED)

1. **restore.sh 是否应该在宿主机上直接运行？**
   - What we know: 脚本在宿主机上运行，但调用了容器内才有的工具
   - What's unclear: 是否应该让脚本在容器内运行，还是修复宿主机兼容性
   - Recommendation: 添加 docker exec 封装（与 verify.sh 保持一致），这是最小改动方案
   - RESOLVED: 采用 Recommendation 方案，Plan 08-01 Task 1 实现 docker exec 封装

2. **B2 凭证是否仍然有效？**
   - What we know: .env.backup 中有凭证配置
   - What's unclear: 这些凭证是否已过期或被撤销
   - Recommendation: 验证计划第一步运行 `rclone listremotes` 或 `--list-backups` 验证连接性
   - RESOLVED: Plan 08-02 Task 1 中 test_list_backups() 作为第一步验证 B2 连接性，失败时明确报告

3. **restore.sh 中的 verify_backup_integrity 和 verify.sh 中的 verify_backup_readable 是否应该合并？**
   - What we know: 两个函数功能重叠但实现不同
   - What's unclear: 是否应该让 restore.sh 复用 verify.sh 的函数
   - Recommendation: 保持独立但让 restore.sh 的函数采用 verify.sh 的环境检测模式
   - RESOLVED: 采用 Recommendation 方案，两个函数保持独立，restore.sh 的函数添加 verify.sh 的环境检测模式

## Sources

### Primary (HIGH confidence)
- 代码审查: `scripts/backup/restore-postgres.sh`, `lib/restore.sh`, `lib/verify.sh`, `lib/cloud.sh`, `lib/config.sh`, `lib/constants.sh`
- 代码审查: `scripts/backup/tests/test_restore_quick.sh`, `test_restore.sh`, `create_test_db.sh`
- 环境检查: Docker 29.1.3, rclone 1.73.3, PostgreSQL 17.9 (healthy)
- 项目规划: `.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md`, `.planning/STATE.md`
- 阶段 3 UAT: `.planning/phases/03-restore-scripts/03-UAT.md` (5/5 通过)

### Secondary (MEDIUM confidence)
- 阶段 3 计划: `.planning/phases/03-restore-scripts/03-01-PLAN.md`
- 阶段 6 验证: `.planning/phases/06-fix-variable-conflicts/06-VALIDATION.md`

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - 所有工具版本通过环境检查确认
- Architecture: HIGH - 通过完整代码审查确认
- Pitfalls: HIGH - 通过代码审查和环境检查发现关键兼容性问题
- Security: MEDIUM - 基于代码审查，未进行渗透测试

**Research date:** 2026-04-06
**Valid until:** 2026-05-06（稳定环境，30 天有效）
