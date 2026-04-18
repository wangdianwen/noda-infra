# Phase 38: 质量保证 - Research

**Researched:** 2026-04-19
**Domain:** Shell 脚本静态分析 (ShellCheck) + 格式化 (shfmt)
**Confidence:** HIGH

## Summary

本阶段对 `scripts/` 目录下 61 个 shell 脚本进行质量 pass：ShellCheck 零 error 确认 + shfmt 统一格式化 + 项目级配置文件建立。当前 ShellCheck 已达到 0 error（验证通过 exit code 0），但存在 116 个 warning 和 256 个 info/style 级别发现。约 55/61 文件使用 4 空格缩进，6 个文件使用 2 空格缩进。shfmt 未安装，需通过 `brew install shfmt` 安装（当前 Homebrew 最新版 3.13.1）。

**Primary recommendation:** 先安装 shfmt、创建配置文件（.editorconfig），再批量格式化（排除 DEPRECATED 脚本），最后创建 .shellcheckrc 抑制合理的 warning/info 级别发现，确保 `shellcheck` 和 `bash -n` 验证通过。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 当前 ShellCheck 已报告 0 error。创建 `.shellcheckrc` 文件记录项目级抑制规则（如 SC1091 source 路径动态解析、SC2154 环境变量等），确保未来新增代码也能通过检查
- **D-02:** 对 warning 级别问题按需抑制，不强制消除（部分 warning 为合理模式）
- **D-03:** 安装 shfmt（`brew install shfmt` 或 `go install`），使用 `-i 4 -ci -fn` 选项（4 空格缩进、switch case 缩进、函数大括号另起行）
- **D-04:** 创建 `.editorconfig` 或 `.shfmt` 配置文件固化格式规则
- **D-05:** 已标记 DEPRECATED 的脚本（deploy-findclass-zero-deps.sh）不格式化，避免无意义的变更
- **D-06:** 不修改 `docker/` 目录下的文件（Dockerfile、compose 文件不是 shell 脚本）

### Claude's Discretion
- 具体抑制哪些 ShellCheck warning（按实际情况判断）
- `.editorconfig` vs `.shfmt` 配置文件格式选择

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| QUAL-01 | 对 `scripts/` 下所有 .sh 文件运行 ShellCheck，消除 error 级别问题，warning 级别可按需抑制 | 当前 0 error 已确认（exit code 0），116 个 warning 和 256 个 info/style 需通过 .shellcheckrc 抑制 |
| QUAL-02 | 使用 shfmt 统一格式化 `scripts/` 下所有 .sh 文件，建立一致的代码风格 | shfmt 3.13.1 可通过 brew 安装，.editorconfig 支持 shfmt 读取配置 |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| ShellCheck 静态分析 | 开发环境 (CLI) | CI (未来) | 本地运行的 linter，不涉及运行时 |
| shfmt 格式化 | 开发环境 (CLI) | CI (未来) | 纯代码风格工具，不改变逻辑 |
| .shellcheckrc 配置 | 项目根目录 | — | 项目级配置文件，被 git 跟踪 |
| .editorconfig 配置 | 项目根目录 | — | 项目级配置文件，被 git 跟踪 |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| ShellCheck | 0.11.0 | Shell 脚本静态分析 | 行业标准 linter，覆盖 300+ 规则，已安装在 /opt/homebrew/bin/shellcheck [VERIFIED: 本机] |
| shfmt | 3.13.1 (Homebrew) | Shell 脚本格式化 | mvdan/sh 项目出品，支持 EditorConfig，行业唯一成熟的 shell formatter [VERIFIED: brew info] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| EditorConfig | (项目配置标准) | 跨编辑器代码风格配置 | shfmt 原生支持 .editorconfig，优于 .shfmt 格式 [CITED: github.com/mvdan/sh README] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| .editorconfig | .shfmt 专用配置文件 | .editorconfig 更通用（其他编辑器/语言也能用），shfmt 原生支持 [CITED: shfmt manpage] |
| .shellcheckrc 中的 disable | 逐文件 `# shellcheck disable=` 行内注释 | 项目级 .shellcheckrc 更集中、更易维护；但特定文件的特定抑制仍用行内注释 |

**Installation:**
```bash
# shfmt 通过 Homebrew 安装
brew install shfmt

# ShellCheck 已安装，无需操作
# 验证版本
shellcheck --version   # 0.11.0
shfmt --version        # 3.13.1
```

**Version verification:** ShellCheck 0.11.0 已确认 [VERIFIED: 本机]。shfmt 3.13.1 为 Homebrew stable 版本 [VERIFIED: brew info shfmt]。

## Architecture Patterns

### System Architecture Diagram

```
开发者工作区
    │
    ├── 1. 编辑脚本 ──────────→ 源码 scripts/**/*.sh
    │                              │
    ├── 2. shfmt -l -w scripts/ ──→ 格式化后源码
    │                              │
    ├── 3. shellcheck scripts/ ──→ 零 error 报告
    │                              │
    └── 4. bash -n 验证 ────────→ 语法正确确认
                                   │
                            ┌──────┴──────┐
                            │ 配置文件层   │
                            │ .editorconfig│ ← shfmt 读取
                            │ .shellcheckrc│ ← shellcheck 读取
                            └─────────────┘
```

### Recommended Project Structure
```
noda-infra/
├── .editorconfig          # shfmt + 编辑器通用配置（新建）
├── .shellcheckrc          # ShellCheck 项目级配置（新建）
├── scripts/               # 61 个 shell 脚本
│   ├── backup/            # 备份系统（核心价值，谨慎修改）
│   │   ├── lib/           # 11 个库文件
│   │   └── tests/         # 12 个测试文件
│   ├── deploy/            # 部署脚本（含 DEPRECATED 文件，排除）
│   ├── lib/               # 共享库（5 个文件）
│   ├── utils/             # 工具脚本（2 个文件）
│   └── *.sh               # 顶层脚本（24 个文件）
└── docker/                # 不修改（D-06）
```

### Pattern 1: .editorconfig 配置（推荐方案）
**What:** 使用 .editorconfig 统一 shell 脚本格式化规则，shfmt 原生支持
**When to use:** 本项目的所有 shell 脚本
**Example:**
```ini
# .editorconfig — shfmt 读取的配置
# Source: https://github.com/mvdan/sh/blob/master/cmd/shfmt/shfmt.1.scd

[*.sh]
indent_style = space
indent_size = 4
shell_variant = bash
switch_case_indent = true
function_next_line = true
```
shfmt 的关键配置映射（从 shfmt manpage）[VERIFIED: github.com/mvdan/sh]:
- `indent_style = space` + `indent_size = 4` → 等同 `-i 4`
- `switch_case_indent = true` → 等同 `-ci`
- `function_next_line = true` → 等同 `-fn`

### Pattern 2: .shellcheckrc 配置
**What:** 项目级 ShellCheck 抑制规则，集中管理
**When to use:** 所有 shell 脚本的静态分析
**Example:**
```bash
# .shellcheckrc
# Source: https://github.com/koalaman/shellcheck/blob/master/shellcheck.1.md

# 指定 shell 方言
shell=bash

# 允许跟踪 source 的外部文件
external-sources=true

# 搜索路径：脚本目录 + 项目 scripts/lib
source-path=SCRIPTDIR
source-path=SCRIPTDIR/../lib
source-path=SCRIPTDIR/../../lib

# 抑制项目级合理 warning
# SC2034: 变量"未使用"（实际由 source 的文件使用，如 constants.sh 中的常量）
disable=SC2034

# SC2155: declare 和 assign 分开（项目中广泛使用 local var=$(cmd) 模式）
disable=SC2155
```

### Pattern 3: 排除 DEPRECATED 文件
**What:** 使用 .editorconfig ignore 规则或 shfmt 命令行排除
**When to use:** 排除 deploy-findclass-zero-deps.sh
**Example:**
```ini
# .editorconfig 中的排除规则
[scripts/deploy/deploy-findclass-zero-deps.sh]
ignore = true
```

### Anti-Patterns to Avoid
- **直接 `shfmt -w scripts/` 不排除文件:** 会格式化 DEPRECATED 脚本和可能误格式化非目标文件。应使用 `.editorconfig` 的 `ignore = true` 或 `-f` 找到文件后排除 [CITED: shfmt manpage]
- **在 .shellcheckrc 中 disable=all:** 会隐藏所有有价值的检查。应逐条抑制并注释原因 [CITED: shellcheck manpage]
- **格式化后不验证语法:** shfmt 可能改变 heredoc、字符串处理等边界情况。必须用 `bash -n` 和 `shellcheck` 双重验证 [ASSUMED]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Shell 静态分析 | 自写 grep/awk 检查脚本 | ShellCheck | 300+ 规则，覆盖 glob/word-splitting/变量引用等复杂场景 [VERIFIED: shellcheck.net] |
| Shell 格式化 | 手动调整缩进/空格 | shfmt | AST 感知格式化，不会破坏 heredoc/字符串 [VERIFIED: mvdan/sh] |
| 项目级格式配置 | 自写 .shfmt 配置 | .editorconfig | shfmt 原生支持 EditorConfig，且编辑器也能读取 [VERIFIED: shfmt manpage] |

**Key insight:** Shell 脚本的格式化不是简单的"缩进替换"——heredoc、子 shell、管道、case 语句等结构的正确格式化需要 AST 解析。shfmt 是目前唯一成熟的 shell AST formatter。

## Common Pitfalls

### Pitfall 1: shfmt 格式化破坏 heredoc 或字符串
**What goes wrong:** shfmt 可能改变 heredoc 内容的缩进或字符串中的空格
**Why it happens:** 某些 heredoc 使用 `<<-`（tab-stripping），shfmt 可能将 tab 转为 space 导致 heredoc 内容变化
**How to avoid:** 格式化后用 `bash -n` 验证每个文件；用 `git diff` 审查变更
**Warning signs:** 格式化后脚本运行异常，heredoc 内容被修改

### Pitfall 2: ShellCheck SC1091 的 source 路径问题
**What goes wrong:** SC1091 "Not following: file was not specified as input" 出现 76 次
**Why it happens:** ShellCheck 默认不跟踪 `source` 的外部文件（安全策略）
**How to avoid:** 在 .shellcheckrc 中设置 `external-sources=true`，配合 `source-path=SCRIPTDIR` 指定搜索路径 [CITED: shellcheck manpage RC FILES section]
**Warning signs:** 大量 SC1091 误报

### Pitfall 3: 格式化产生大量 diff 影响代码审查
**What goes wrong:** 61 个文件一次性格式化，diff 巨大，难以审查
**Why it happens:** 缩进变化（2 空格 → 4 空格）、函数大括号位置变化、引号规范化等
**How to avoid:** 分批提交：先提交 .editorconfig + .shellcheckrc，再提交格式化变更（确保逻辑无变化）
**Warning signs:** 单次 commit 修改 5000+ 行

### Pitfall 4: backup 系统脚本被意外破坏
**What goes wrong:** 格式化改变备份/恢复脚本的行为
**Why it happens:** backup/ 目录下 25 个脚本包含关键的数据库操作逻辑
**How to avoid:** 格式化 backup/ 脚本后必须用 `bash -n` 逐文件验证；shfmt 是纯格式化工具（AST→text），不会改变逻辑 [VERIFIED: mvdan/sh README]
**Warning signs:** backup 脚本格式化后 `bash -n` 报错

### Pitfall 5: -ln (language dialect) 默认行为
**What goes wrong:** `.sh` 扩展名默认被 shfmt 识别为 POSIX，但项目全部使用 `#!/bin/bash`
**Why it happens:** shfmt 的 auto 检测：`.sh` 扩展名默认 POSIX，但会被有效 shebang 覆盖 [CITED: shfmt manpage]
**How to avoid:** 在 .editorconfig 中设置 `shell_variant = bash`，或确保所有脚本有 `#!/bin/bash` shebang（已确认 61/61 都有）
**Warning signs:** shfmt 对 bash 特有语法（数组、`[[`）报错

## Code Examples

### 安装和验证 shfmt
```bash
# 安装 shfmt
brew install shfmt

# 验证版本
shfmt --version
# 预期: 3.13.1

# 列出需要格式化的文件（dry-run）
shfmt -f scripts/

# 查看格式化差异（不写入）
shfmt -d scripts/
```

### 批量格式化（排除 DEPRECATED）
```bash
# 方法：使用 find 排除 DEPRECATED 文件，逐文件格式化
find scripts/ -name '*.sh' \
  ! -name 'deploy-findclass-zero-deps.sh' \
  -exec shfmt -w {} +

# 验证语法
find scripts/ -name '*.sh' -exec bash -n {} \;

# 验证 ShellCheck
shellcheck scripts/**/*.sh
```

### .editorconfig 完整配置
```ini
# .editorconfig
# https://editorconfig.org
root = true

[*]
end_of_line = lf
charset = utf-8
insert_final_newline = true
trim_trailing_whitespace = true

[*.sh]
indent_style = space
indent_size = 4
shell_variant = bash
switch_case_indent = true
function_next_line = true

# 排除 DEPRECATED 脚本
[scripts/deploy/deploy-findclass-zero-deps.sh]
ignore = true
```
Source: [CITED: github.com/mvdan/sh/blob/master/cmd/shfmt/shfmt.1.scd]

### .shellcheckrc 完整配置
```bash
# .shellcheckrc — Noda 基础设施项目级 ShellCheck 配置
# 文档: https://github.com/koalaman/shellcheck/blob/master/shellcheck.1.md

# Shell 方言
shell=bash

# 允许跟踪 source 的外部文件
external-sources=true

# Source 搜索路径
source-path=SCRIPTDIR
source-path=SCRIPTDIR/../lib
source-path=SCRIPTDIR/../../lib

# SC2034: 变量未使用
# 原因: constants.sh 和 lib/ 文件定义的常量/变量由 source 的调用方使用
# ShellCheck 无法跨文件追踪变量使用，导致大量误报
disable=SC2034

# SC2155: Declare and assign separately
# 原因: 项目中广泛使用 `local var=$(cmd)` 模式
# 虽然可能掩盖返回值，但这是 bash 社区常见模式，逐文件修改风险大于收益
disable=SC2155
```
Source: [CITED: github.com/koalaman/shellcheck/blob/master/shellcheck.1.md]

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| shfmt `-kp` (keep-padding) | `-kp` 已 DEPRECATED | shfmt v3.x [CITED: shfmt manpage] | 不要使用 `-kp` 选项 |
| `.shfmt` 配置文件 | `.editorconfig` | shfmt v3.x [CITED: shfmt manpage] | 使用 .editorconfig 代替 |
| ShellCheck `--exclude` 命令行 | `.shellcheckrc` 文件 | ShellCheck 0.7+ | 项目级配置更集中 |
| ShellCheck `source-path=SCRIPTDIR` | 无需 `-x` 标志 | ShellCheck 0.9+ | external-sources=true 替代 -x |

**Deprecated/outdated:**
- shfmt `-kp` (`--keep-padding`): 已标记为 DEPRECATED，将在下个大版本移除 [CITED: shfmt manpage]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | shfmt 格式化不会改变脚本逻辑，但格式化后仍需 bash -n 验证 | Anti-Patterns | 低 — shfmt 基于 AST，但有 heredoc 边界情况 |
| A2 | 所有 61 个脚本的 `#!/bin/bash` shebang 会被 shfmt 正确识别为 bash 方言 | Pitfall 5 | 低 — 已验证 61/61 都有 `#!/bin/bash` |
| A3 | .editorconfig 的 `[scripts/deploy/deploy-findclass-zero-deps.sh]` ignore 规则会被 shfmt 尊重 | Pattern 3 | 中 — 需要安装后验证；如果不生效，改用 find 排除 |

## Open Questions

1. **shfmt 格式化差异量**
   - What we know: 55/61 文件已用 4 空格缩进，6 个用 2 空格
   - What's unclear: `-fn` (function_next_line) 会改变多少函数声明的 brace 位置；目前约 57 个文件用 `name() {` 同行风格，4 个文件用换行风格
   - Recommendation: 先 `shfmt -d scripts/` 查看预期变更量，再决定是否需要分批提交

2. **SC2155 抑制 vs 修复**
   - What we know: 50 处 `local var=$(cmd)` 模式，分布在 backup/ 系统和多个脚本中
   - What's unclear: 是否值得逐文件修复（`local var; var=$(cmd)`）
   - Recommendation: 按用户决定 D-02，在 .shellcheckrc 中全局抑制（成本最低，风险最低）

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| ShellCheck | QUAL-01 | 已安装 | 0.11.0 | — |
| shfmt | QUAL-02 | 未安装 | — | `brew install shfmt` (Homebrew 5.1.6 已安装) |
| Homebrew | shfmt 安装 | 已安装 | 5.1.6 | — |
| bash | bash -n 验证 | 已安装 | (系统) | — |

**Missing dependencies with no fallback:**
- shfmt: 需通过 `brew install shfmt` 安装（Phase 执行第一步）

**Missing dependencies with fallback:**
- None

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | ShellCheck 0.11.0 + bash -n (无测试框架) |
| Config file | 无 — 本阶段创建 .shellcheckrc |
| Quick run command | `shellcheck scripts/**/*.sh` |
| Full suite command | `shellcheck scripts/**/*.sh && find scripts/ -name '*.sh' -exec bash -n {} \;` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| QUAL-01 | ShellCheck 零 error | smoke | `shellcheck -S error scripts/**/*..sh; echo $?` | 0 error 已确认 |
| QUAL-02 | shfmt 格式化后所有脚本风格一致 | smoke | `shfmt -d scripts/ \| wc -l` (应为 0) | 需要 Wave 0 安装 shfmt |
| QUAL-01 | .shellcheckrc 配置文件存在 | smoke | `test -f .shellcheckrc` | Wave 0 创建 |
| QUAL-02 | .editorconfig 配置文件存在 | smoke | `test -f .editorconfig` | Wave 0 创建 |
| QUAL-01+02 | 格式化后 bash -n 语法检查通过 | smoke | `find scripts/ -name '*.sh' -exec bash -n {} \;` | 当前已通过 |

### Sampling Rate
- **Per task commit:** `shellcheck scripts/**/*.sh && find scripts/ -name '*.sh' -exec bash -n {} \;`
- **Per wave merge:** `shellcheck scripts/**/*.sh && shfmt -d scripts/`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] 安装 shfmt: `brew install shfmt`
- [ ] 创建 `.editorconfig` — covers QUAL-02 配置
- [ ] 创建 `.shellcheckrc` — covers QUAL-01 配置

## Security Domain

> 本阶段不涉及安全敏感变更（纯格式化和静态分析配置），security enforcement 可降级。

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | no | 不涉及输入处理 |
| V6 Cryptography | no | 不涉及加密 |

### Known Threat Patterns for Shell Scripts

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| SC2086 (未引用变量) | Tampering | shfmt 不修复引用；ShellCheck SC2086 是 info 级别，不阻塞 |
| SC2046 (word splitting) | Tampering | 2 处 warning，可按需修复或抑制 |

## Current State Audit

### ShellCheck 发现分布（实测数据）

| 严重级别 | 数量 | 说明 |
|----------|------|------|
| error | 0 | 已达标 |
| warning | 116 | 主要是 SC2034(51), SC2155(50), SC1090(5), SC2046(2), SC2064(1), SC2124(1) |
| info | 372 | 主要是 SC2086(114), SC1091(76), SC2034(51), SC2155(50), SC2329(14), SC2016(4), SC2162(2) |
| style | 374 | 各类风格建议 |

### Top ShellCheck Codes（按频率排序）

| Code | 级别 | 数量 | 说明 | 建议处理 |
|------|------|------|------|----------|
| SC2086 | info | 114 | 变量未双引号包裹 | .shellcheckrc disable（安全风险低，修复量大） |
| SC1091 | info | 76 | source 文件未指定为输入 | .shellcheckrc: external-sources=true + source-path |
| SC2034 | warning | 51 | 变量未使用（常量文件误报） | .shellcheckrc disable=SC2034 |
| SC2155 | warning | 50 | local 和 assign 未分开 | .shellcheckrc disable=SC2155 |
| SC2329 | info | 14 | 函数从未被调用（库文件误报） | .shellcheckrc disable=SC2329 |
| SC1090 | warning | 5 | 非常量 source 路径 | .shellcheckrc: source-path=SCRIPTDIR |
| SC2016 | info | 4 | 单引号中的表达式不展开 | 逐个判断（可能是误报） |
| SC2162 | info | 2 | read 不需要 -r 以外的参数 | 可修复或抑制 |
| SC2046 | warning | 2 | 命令替换需要引号 | 可修复或抑制 |
| SC2064 | warning | 1 | trap 中应使用单引号 | 可修复 |
| SC2124 | warning | 1 | 数组赋值给字符串 | 可修复 |

### 缩进风格分布

| 风格 | 文件数 | 文件 |
|------|--------|------|
| 4 空格缩进 | 55 | 大部分脚本 |
| 2 空格缩进 | 6 | scripts/lib/log.sh, scripts/backup/tests/{list_b2,cleanup_b2_tests,test_b2_config,test_upload,test_restore_quick}.sh |
| 无缩进（wrapper） | 5 | blue-green-deploy-findclass.sh, rollback-keycloak.sh, rollback-findclass.sh, keycloak-blue-green-deploy.sh, backup/lib/constants.sh |

### 其他发现

| 检查项 | 状态 |
|--------|------|
| shebang 一致性 | 61/61 使用 `#!/bin/bash` |
| `set -euo pipefail` | 55/61 有，6 个 lib/库文件无（正常：库文件被 source，不应设置 set） |
| Tab 缩进 | 0 个文件使用 tab（全部为 space） |
| 语法检查 (bash -n) | 61/61 通过 |
| DEPRECATED 标记 | deploy-findclass-zero-deps.sh 已标记 |

## Sources

### Primary (HIGH confidence)
- [VERIFIED: 本机] ShellCheck 0.11.0 安装在 /opt/homebrew/bin/shellcheck
- [VERIFIED: brew info] shfmt 3.13.1 (stable) 可通过 Homebrew 安装
- [CITED: github.com/mvdan/sh/blob/master/cmd/shfmt/shfmt.1.scd] shfmt 完整 manpage — flags, EditorConfig 支持, ignore 规则
- [CITED: github.com/koalaman/shellcheck/blob/master/shellcheck.1.md] ShellCheck 完整 manpage — directives, rc files, source-path
- [VERIFIED: 实测] ShellCheck 0 error 确认（exit code 0）
- [VERIFIED: 实测] 61 个脚本 bash -n 全部通过

### Secondary (MEDIUM confidence)
- [CITED: Context7 /mvdan/sh] shfmt EditorConfig 配置示例

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — ShellCheck 和 shfmt 版本已通过本机/Homebrew 验证
- Architecture: HIGH — 配置文件格式从官方 manpage 确认
- Pitfalls: HIGH — ShellCheck 发现分布基于实测数据（372 个发现）
- 格式化影响评估: MEDIUM — shfmt -d 差异量需安装后实测

**Research date:** 2026-04-19
**Valid until:** 2026-05-19（稳定工具，30 天有效期）
