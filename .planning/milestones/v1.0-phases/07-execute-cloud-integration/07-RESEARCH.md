# Phase 7: 执行云存储集成 - Research

**Researched:** 2026-04-06
**Domain:** Backblaze B2 云存储上传验证 + rclone + Bash 脚本测试
**Confidence:** HIGH

## Summary

Phase 7 是一个 Gap Closure 验证阶段，核心目标是验证 Phase 2 已实现的云存储集成功能（lib/cloud.sh）是否完整、正确且安全。经过详细的代码审查和实际 B2 连接测试，发现以下关键情况：

1. **cloud.sh 核心逻辑正确**：upload_to_b2 的重试机制（3 次指数退避 1s/2s/4s）、rclone check 校验和验证、cleanup_old_backups_b2 清理功能逻辑均正确。实际 B2 连接测试已验证成功（上传、校验、删除均正常）。

2. **发现 2 个需要修复的 BUG**：test_rclone.sh 使用了错误的 rclone 后端类型名 `backblazeb2`（正确应为 `b2`）和错误的配置属性名，导致该测试脚本无法正常运行。cloud.sh 缺少对 util.sh 的显式依赖（依赖调用者预先加载）。

3. **安全验证通过**：无硬编码凭证，.env.backup 已在 .gitignore 中且文件权限为 600，B2 凭证通过环境变量管理。

**Primary recommendation:** 以修复 test_rclone.sh 的 BUG 和 cloud.sh 的依赖问题为首要任务，然后运行完整测试套件验证所有功能。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Phase 7 是验证阶段，不涉及新的代码实现（除非发现 bug 需要修复）
- **D-02:** 验证覆盖四个方面：功能、测试、安全、性能
- **D-03:** 优先验证功能正确性，然后是测试通过，最后是安全和性能
- **D-04:** cloud.sh 的 upload_to_b2 函数能成功上传文件到 B2
- **D-05:** 上传失败时自动重试（最多 3 次，指数退避）
- **D-06:** 上传后通过 rclone check 验证文件完整性
- **D-07:** 7 天前的旧备份能被自动清理（本地和云端）
- **D-08:** test_rclone.sh 能成功验证 rclone 配置
- **D-09:** test_upload.sh 能成功上传测试文件到 B2
- **D-10:** 所有测试退出码为 0，无错误输出
- **D-11:** 所有凭证（B2 Key、数据库密码）通过环境变量传入
- **D-12:** 脚本中无硬编码凭证（grep 验证）
- **D-13:** 临时配置文件权限为 600
- **D-14:** B2 Application Key 仅拥有备份 bucket 的最低必要权限
- **D-15:** 上传速度符合预期（> 1MB/s 为正常）
- **D-16:** 重试机制工作正常（模拟失败场景）
- **D-17:** 大文件上传不超时（30 分钟超时设置）
- **D-18:** 使用测试数据库（test_backup_db）进行验证
- **D-19:** 不影响生产数据（keycloak_db、noda_prod）
- **D-20:** 测试数据使用小型数据库（减少上传时间）
- **D-21:** 使用现有的 B2 账户和 bucket
- **D-22:** 环境变量配置：B2_ACCOUNT_ID、B2_APPLICATION_KEY、B2_BUCKET_NAME
- **D-23:** B2 bucket 路径：backups/postgres/YYYY/MM/DD/

### Claude's Discretion
- 验证测试的具体实现方式（单元测试 vs 集成测试）
- 性能基准的具体阈值
- 发现 bug 时的修复优先级

### Deferred Ideas (OUT OF SCOPE)
无 -- 这是一个验证阶段，所有工作聚焦在验证现有实现。
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| UPLOAD-01 | 备份文件自动上传到 Backblaze B2 云存储（使用 rclone） | cloud.sh upload_to_b2() 已实现，rclone copy 命令正确，B2 连接已验证成功 [VERIFIED: 实际 B2 上传测试通过] |
| UPLOAD-02 | 上传失败时自动重试（指数退避，最多 3 次） | cloud.sh 第 110-139 行实现了 3 次重试，指数退避 1s/2s/4s [VERIFIED: 代码审查] |
| UPLOAD-03 | 上传后自动验证校验和（rclone check） | cloud.sh verify_upload_checksum() 使用 rclone check --one-way [VERIFIED: 实际校验测试通过] |
| UPLOAD-04 | 应用层保留策略自动清理 7 天前的旧备份（本地和云端） | cleanup_old_backups_b2() 使用 rclone delete --min-age 7d [VERIFIED: 语法测试通过] |
| UPLOAD-05 | 自动清理未完成的上传文件（B2 lifecycle + rclone） | 需要验证 B2 Lifecycle Rules 是否已配置；rclone 不产生未完成上传（原子操作）[ASSUMED] |
| SECURITY-01 | 所有凭证通过环境变量管理，绝不硬编码 | grep 搜索确认无硬编码凭证 [VERIFIED: grep 审查通过] |
| SECURITY-02 | 使用最低权限的 B2 Application Key | .env.backup 注释声明仅限 noda-backups bucket + backups/ 前缀 + writeFiles/deleteFiles/listFiles [VERIFIED: .env.backup 文档确认] |
</phase_requirements>

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|-------------|---------|---------|--------------|
| rclone | v1.73.3 | B2 云存储文件操作 | 官方支持的 B2 后端，支持校验和验证 [VERIFIED: 本机安装检查] |
| bash | 5.x | 脚本运行时 | 项目已有脚本全部基于 bash + set -euo pipefail |
| jq | 1.7.1 | JSON 处理 | 指标和历史记录的 JSON 文件操作 [VERIFIED: 本机安装检查] |

### Supporting
| Library/Tool | Version | Purpose | When to Use |
|-------------|---------|---------|-------------|
| sha256sum | Darwin 1.0 | SHA-256 校验和计算 | 本地备份完整性验证 |
| mktemp | system | 临时文件创建 | rclone 配置文件管理 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| rclone | b2 CLI tool | b2 CLI 功能更基础，不支持 rclone check 校验和比对。rclone 是更成熟的选择 |
| 指数退避重试 | rclone 内置重试 | rclone 内置重试无指数退避，应用层实现更灵活 |

## Architecture Patterns

### 现有项目结构
```
scripts/backup/
├── backup-postgres.sh       # 主脚本（7 步流程）
├── .env.backup              # 环境配置（gitignored，权限 600）
├── lib/
│   ├── constants.sh         # 退出码和常量
│   ├── config.sh            # 配置加载 + B2 getter 函数
│   ├── log.sh               # 日志输出
│   ├── util.sh              # 工具函数（get_date_path 等）
│   ├── health.sh            # 健康检查
│   ├── db.sh                # 数据库操作
│   ├── verify.sh            # 备份验证
│   ├── cloud.sh             # 云操作（Phase 2 实现）
│   ├── alert.sh             # 告警系统
│   └── metrics.sh           # 指标追踪
└── tests/
    ├── test_rclone.sh       # rclone 配置测试（有 BUG）
    ├── test_upload.sh       # 上传端到端测试
    ├── test_b2_config.sh    # B2 配置验证
    ├── cleanup_b2_tests.sh  # B2 测试清理
    └── list_b2.sh           # B2 文件列表
```

### Pattern 1: rclone 临时配置文件模式
**What:** 每次操作创建临时配置文件，操作完成后删除
**When to use:** 所有 B2 操作（上传、验证、清理）
**Example:**
```bash
# Source: lib/cloud.sh setup_rclone_config()
# 正确的配置格式（type=b2, account/key）
rclone_config=$(mktemp)
chmod 600 "$rclone_config"
cat > "$rclone_config" <<EOF
[b2remote]
type = b2
account = $b2_account_id
key = $b2_application_key
EOF
# 使用后清理
rm -f "$rclone_config"
```

### Pattern 2: 指数退避重试
**What:** 3 次重试，等待时间指数增长（1s, 2s, 4s）
**When to use:** 上传操作失败时
**Example:**
```bash
# Source: lib/cloud.sh upload_to_b2()
while [[ $attempt -le $max_retries ]]; do
  if rclone copy ...; then
    if verify_upload_checksum ...; then
      return 0  # 成功
    fi
  fi
  ((attempt++))
  if [[ $attempt -le $max_retries ]]; then
    local wait_time=$((2 ** (attempt - 1)))  # 1, 2, 4
    sleep $wait_time
  fi
done
```

### Pattern 3: 凭证管理（环境变量 + .env.backup）
**What:** 配置优先级：命令行参数 > 环境变量 > .env.backup 文件 > 默认值
**When to use:** 所有需要凭证的场景

### Anti-Patterns to Avoid
- **直接使用 rclone config create 交互命令**: 在脚本中使用 `rclone config create` 需要 `--non-interactive` 和正确的后端类型名。test_rclone.sh 使用了错误的后端名 `backblazeb2`（应为 `b2`）
- **不清理临时文件**: rclone 配置文件包含凭证，必须在操作完成后删除

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 校验和比对 | 自定义 hash 比对脚本 | rclone check --one-way | rclone 内置 B2 SHA1 比对，考虑了 B2 的分块上传机制 |
| 重试逻辑 | 手动 while 循环 | 已在 cloud.sh 中实现 | 指数退避已正确实现，无需重写 |
| B2 API 调用 | 直接调用 B2 REST API | rclone B2 后端 | rclone 处理认证、重试、大文件分块等复杂逻辑 |

## Common Pitfalls

### Pitfall 1: rclone B2 后端类型名错误
**What goes wrong:** 使用 `backblazeb2` 而非 `b2` 作为后端类型名
**Why it happens:** B2 曾被称为 "Backblaze B2"，部分文档使用旧名称
**How to avoid:** 始终使用 `type = b2` 在配置文件中
**Warning signs:** `rclone config create` 报错 "couldn't find backend for type"
**Current status:** test_rclone.sh 存在此 BUG，需要修复 [VERIFIED: rclone help backends 确认正确名称为 "b2"]

### Pitfall 2: rclone config create 属性名错误
**What goes wrong:** 使用 `--b2-account-id` 和 `--b2-account-key` 而非 `account` 和 `key`
**Why it happens:** 误以为 rclone 属性名与 API 参数名一致
**How to avoid:** 使用正确的属性名 `account=xxx key=xxx`
**Warning signs:** 配置文件中凭证为空或 rclone 认证失败
**Current status:** test_rclone.sh 存在此 BUG [VERIFIED: rclone config create test 确认正确属性名]

### Pitfall 3: cloud.sh 隐式依赖 util.sh
**What goes wrong:** cloud.sh 使用 `get_date_path()` 但未显式 source util.sh
**Why it happens:** cloud.sh 假设调用者已加载 util.sh（backup-postgres.sh 和 test_upload.sh 确实如此）
**How to avoid:** 在 cloud.sh 中添加 util.sh 的条件加载
**Warning signs:** 单独 source cloud.sh 时报错 "get_date_path: command not found"
**Current status:** 潜在问题，当前调用链安全但不够健壮

### Pitfall 4: test_rclone.sh 主函数跳过 B2 测试
**What goes wrong:** test_rclone.sh 的 main() 函数只运行 rclone 安装检查，跳过所有 B2 相关测试
**Why it happens:** 原始设计为 Wave 0 测试，B2 函数尚未实现时跳过
**How to avoid:** 更新 main() 函数运行所有 5 个测试
**Warning signs:** 运行 test_rclone.sh 只看到 "rclone 已安装" 但不测试 B2 连接

## Code Examples

### 正确的 B2 连接测试（修复 test_rclone.sh 后应使用的方式）
```bash
# Source: 基于实际 rclone v1.73.3 验证
# 正确方式：直接写入配置文件（与 cloud.sh 一致）
rclone_config=$(mktemp)
chmod 600 "$rclone_config"
cat > "$rclone_config" <<EOF
[b2remote]
type = b2
account = $b2_account_id
key = $b2_application_key
EOF

# 验证配置
rclone listremotes --config "$rclone_config" | grep -q "b2remote:"

# 测试连接
rclone lsd "b2remote:$b2_bucket_name" --config "$rclone_config"

# 清理
rm -f "$rclone_config"
```

### 校验和验证的正确实现（cloud.sh 中已正确实现）
```bash
# Source: lib/cloud.sh verify_upload_checksum()
rclone check "$local_dir" "$remote_path" \
  --config "$rclone_config" \
  --one-way \
  --combined /dev/null \
  --quiet
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| rclone 后端名 "backblazeb2" | rclone 后端名 "b2" | rclone >= 1.40+ | test_rclone.sh 使用旧名称会失败 |
| rclone config 属性 --b2-account-id | 属性 account | rclone 新版本 | test_rclone.sh 使用旧属性名会失败 |

**Deprecated/outdated:**
- `backblazeb2` 作为 rclone 后端类型名：已被 `b2` 替代 [VERIFIED: rclone help backends]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | B2 Lifecycle Rules 已配置用于清理未完成上传（UPLOAD-05） | Phase Requirements | 如果未配置，需要通过 B2 控制台手动设置 |
| A2 | B2 Application Key 权限仅限 writeFiles/deleteFiles/listFiles + backups/ 前缀 | SECURITY-02 验证 | .env.backup 中注释声明了权限限制，但未实际验证 Key 权限 |
| A3 | 上传速度 > 1MB/s 在正常网络条件下可达 | 性能验证 | 取决于网络环境，小文件可能达不到此速度 |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| rclone | B2 上传/验证/清理 | Yes | v1.73.3 | -- |
| jq | JSON 处理（metrics/alerts） | Yes | 1.7.1 | -- |
| bash | 脚本运行时 | Yes | system | -- |
| sha256sum | 校验和计算 | Yes | Darwin 1.0 | -- |
| Docker | PostgreSQL 容器 | Yes | system | -- |
| PostgreSQL | 备份源数据库 | Yes | (in Docker) | -- |
| B2 网络连接 | 云存储访问 | Yes | -- | -- |
| B2 credentials | B2 认证 | Yes | (in .env.backup) | -- |

**Missing dependencies with no fallback:**
- 无 -- 所有必需依赖均已安装和配置

**Missing dependencies with fallback:**
- 无

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash 脚本（自建测试） |
| Config file | 无 -- 每个 test_*.sh 独立运行 |
| Quick run command | `bash scripts/backup/tests/test_b2_config.sh` |
| Full suite command | `bash scripts/backup/tests/test_upload.sh` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| UPLOAD-01 | 上传文件到 B2 | 集成测试 | `bash scripts/backup/tests/test_upload.sh` | Yes |
| UPLOAD-02 | 失败自动重试 | 单元测试（代码审查） | 代码审查 cloud.sh 第 110-139 行 | N/A |
| UPLOAD-03 | 校验和验证 | 集成测试 | `bash scripts/backup/tests/test_upload.sh`（步骤 5） | Yes |
| UPLOAD-04 | 7 天旧备份清理 | 集成测试 | `bash scripts/backup/tests/test_upload.sh`（步骤 6） | Yes |
| UPLOAD-05 | 未完成上传清理 | 手动验证 | 检查 B2 Lifecycle Rules | N/A |
| SECURITY-01 | 无硬编码凭证 | 静态分析 | `grep -rn "K0048\|00424f" scripts/backup/lib/` | Yes |
| SECURITY-02 | 最低权限 Key | 手动验证 | B2 控制台检查 Application Key 权限 | N/A |

### Sampling Rate
- **Per task commit:** `bash scripts/backup/tests/test_b2_config.sh`
- **Per wave merge:** `bash scripts/backup/tests/test_upload.sh`
- **Phase gate:** test_upload.sh 退出码为 0

### Wave 0 Gaps
- test_rclone.sh 需要修复后端类型名和属性名（BUG 修复）
- test_rclone.sh main() 函数需要更新以运行完整 B2 测试套件
- 无需安装额外框架

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | B2 Application Key 认证（通过环境变量） |
| V5 Input Validation | yes | validate_b2_credentials() 验证凭证非空 |
| V6 Cryptography | yes | rclone 使用 HTTPS 传输加密；B2 服务端加密（SSE-B2） |

### Known Threat Patterns for Bash + rclone + B2

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 凭证泄露（.env.backup 暴露） | Information Disclosure | .gitignore 排除 + 文件权限 600 [VERIFIED] |
| 临时配置文件残留 | Information Disclosure | mktemp + 操作后 rm -f [VERIFIED: cloud.sh cleanup_rclone_config()] |
| 硬编码凭证 | Tampering | grep 审查确认无硬编码 [VERIFIED] |
| B2 Key 权限过大 | Elevation of Privilege | Application Key 限制到 bucket + 前缀 [VERIFIED: .env.backup 注释] |

## Discoveries: Existing B2 Data

实际 B2 连接测试确认 bucket 中已有生产备份数据：
- `noda-backups/backups/postgres/2026/04/06/` 目录下存在 8 个 globals 文件、3 个 keycloak dump、3 个 noda_prod dump、5 个 oneteam_prod dump、1 个 postgres dump
- 文件格式符合命名规范：`{db_name}_{YYYYMMDD_HHmmss}.dump`
- 这意味着 cloud.sh 的 upload_to_b2 功能已经在生产环境中成功使用过

## Discoveries: Identified BUGs

### BUG 1: test_rclone.sh 使用错误的后端类型名（严重）
**位置:** `scripts/backup/tests/test_rclone.sh` 第 136、186、239 行
**问题:** 使用 `backblazeb2` 而非 `b2`
**影响:** test_rclone.sh 的测试 3-5 全部失败
**修复:** 将 `backblazeb2` 替换为 `b2`，并使用正确的属性传递方式
**验证:** `rclone help backends` 确认正确名称为 `b2` [VERIFIED]

### BUG 2: test_rclone.sh main() 跳过 B2 测试（中等）
**位置:** `scripts/backup/tests/test_rclone.sh` 第 292-330 行 main() 函数
**问题:** 只运行 test_rclone_installed()，跳过 test_b2_credentials/test_rclone_config/test_b2_connection/test_b2_operations
**影响:** 即使 B2 配置错误也不会被发现
**修复:** 在 main() 中调用所有 5 个测试函数
**验证:** 代码审查确认 [VERIFIED]

### BUG 3: cloud.sh 缺少 util.sh 显式依赖（低）
**位置:** `scripts/backup/lib/cloud.sh` 第 97 行使用 get_date_path()
**问题:** cloud.sh 未 source util.sh，依赖调用者预先加载
**影响:** 单独使用 cloud.sh 时 get_date_path 不可用
**修复:** 添加 util.sh 的条件加载（与 alert.sh/metrics.sh 的模式一致）
**验证:** 代码审查确认 [VERIFIED]

## Open Questions

1. **B2 Lifecycle Rules 是否已配置（UPLOAD-05）？**
   - What we know: Phase 2 RESEARCH.md 描述了 Lifecycle Rules 方案
   - What's unclear: 是否实际在 B2 控制台创建了 Lifecycle Rules
   - Recommendation: 验证阶段通过 B2 控制台或 API 检查

2. **B2 Application Key 的实际权限是否与声明一致（SECURITY-02）？**
   - What we know: .env.backup 注释声明了权限限制
   - What's unclear: Key 是否真的只限于 writeFiles/deleteFiles/listFiles + backups/ 前缀
   - Recommendation: 使用 `rclone lsd` 测试越权操作验证

3. **cleanup_old_backups_b2 的 --min-age 方向是否正确？**
   - What we know: rclone delete --min-age 7d 表示"删除 7 天前的文件"
   - What's unclear: 无
   - Recommendation: 已验证正确 [VERIFIED: rclone delete --help 确认]

## Sources

### Primary (HIGH confidence)
- 实际 B2 连接测试 - 上传/校验/删除操作全部通过
- rclone help backends - 确认正确后端类型名为 `b2`
- rclone delete --help - 确认 --min-age 语义正确
- 代码审查 cloud.sh/config.sh/test_rclone.sh - 所有文件逐行审查

### Secondary (MEDIUM confidence)
- .env.backup 注释 - B2 Key 权限声明（未通过 B2 API 实际验证权限）
- Phase 2 RESEARCH.md - Lifecycle Rules 方案描述

### Tertiary (LOW confidence)
- 无

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - rclone v1.73.3 已安装并实际测试通过
- Architecture: HIGH - 所有代码文件已审查，B2 连接已验证
- Pitfalls: HIGH - 通过实际测试发现 3 个 BUG
- Security: MEDIUM - 代码审查确认无硬编码凭证，但 B2 Key 实际权限未通过 API 验证

**Research date:** 2026-04-06
**Valid until:** 2026-05-06（stable - rclone B2 后端稳定）
