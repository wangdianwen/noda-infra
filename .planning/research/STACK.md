# Stack Research: v1.7 Shell 脚本重构与代码精简

**Domain:** Shell/Bash 脚本重构 — 静态分析、格式化、测试、重复代码消除
**Researched:** 2026-04-18
**Confidence:** HIGH

## 核心结论

项目有 65 个 Shell 脚本（约 15,137 行），核心问题是重复代码和过大单文件。重构工具链需要三个层次：**静态分析（ShellCheck）** 发现代码质量问题，**格式化（shfmt）** 统一风格，**测试（Bats）** 保证重构不破坏功能。不需要引入任何运行时依赖——所有工具都是开发工具，仅在重构阶段和 CI 中使用。

## Recommended Stack

### Core: 静态分析与质量检查

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| ShellCheck | v0.11.0 (2025-08-03) | Shell 脚本静态分析 | Shell 脚本领域唯一的工业级 linter，检测 300+ 种常见错误（未引用变量、不安全的算术、SC 前缀错误码）。v0.11.0 新增 SC2329（未调用函数检测）对重构中识别死代码极其有用 | HIGH |
| shfmt | v3.13.1 (2026-04-06) | Shell 脚本格式化 | 基于 mvdan/sh parser 的唯一成熟的 shell 格式化工具。支持 EditorConfig，`-s` 简化模式可自动简化冗余语法。v3.13.1 新增 `.zshrc`/`.bash_profile` 文件名自动检测 shell 方言 | HIGH |

### Core: 测试框架

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| Bats (Bash Automated Testing System) | v1.13.0 (2025-11-07) | Shell 脚本单元测试 | Shell 脚本测试的事实标准。TDD 风格 `@test` 语法，`run`/`assert` 模式，v1.13.0 新增 `--abort` fail-fast 和 `--negative-filter`。项目已有 12 个手写测试脚本（scripts/backup/tests/），但不是 Bats 格式 | HIGH |

### Supporting: 重构辅助工具

| Tool | Purpose | When to Use | Confidence |
|------|---------|-------------|------------|
| `diff` + `source` 验证 | 重构前后功能等价性验证 | 每次合并重复脚本后，对比 `source` 后的函数签名和行为 | HIGH |
| `bash -n` (syntax check) | 语法检查无需执行 | 每次修改后快速验证，ShellCheck 已包含此功能 | HIGH |
| `git diff --stat` | 重构前后行数对比 | 每个 phase 结束后统计精简效果 | HIGH |
| `.shellcheckrc` | 项目级 ShellCheck 配置 | 全局排除不适用的规则、设置 source-path | HIGH |

## 与项目现状的映射

### 重复文件分析与工具使用策略

| 重复类型 | 涉及文件 | 行数差异 | 推荐工具 | 策略 |
|---------|---------|---------|---------|------|
| 日志库 | `scripts/lib/log.sh` vs `scripts/backup/lib/log.sh` | 33 行 vs 87 行 | ShellCheck + 手动合并 | backup 版本功能更多（log_progress/log_json/log_structured），合并后以 backup 版本为基础，scripts 版本的彩色输出作为可选功能 |
| 健康检查库 | `scripts/lib/health.sh` vs `scripts/backup/lib/health.sh` | 69 行 vs 358 行 | ShellCheck + 手动合并 | 完全不同的功能：前者是 Docker 容器健康检查，后者是 PostgreSQL 连接+磁盘空间检查。不应合并，应重命名消除混淆 |
| 蓝绿部署 | `scripts/blue-green-deploy.sh` vs `scripts/keycloak-blue-green-deploy.sh` | 297 行 vs 297 行，差异 264 行 | ShellCheck + 手动参数化 | 264 行差异中大部分是服务特定常量和健康检查 URL 参数化，核心逻辑完全相同。提取 `deploy_service()` 函数，两个脚本变为配置文件 |
| 大文件 | `pipeline-stages.sh` (1108行), `setup-jenkins.sh` (1029行) | - | ShellCheck + 函数提取 | ShellCheck 的 SC2329（未调用函数）可识别死代码；函数提取后按职责分组到独立文件 |

### 工具安装与配置

```bash
# ============================================
# 开发工具安装（macOS 开发机 + Linux 生产服务器）
# ============================================

# ShellCheck v0.11.0
brew install shellcheck          # macOS
# Linux: 下载预编译二进制
# scversion="v0.11.0"
# wget -qO- "https://github.com/koalaman/shellcheck/releases/download/${scversion}/shellcheck-${scversion}.linux.x86_64.tar.xz" | tar -xJv
# sudo cp "shellcheck-${scversion}/shellcheck" /usr/local/bin/

# shfmt v3.13.1
brew install shfmt               # macOS
# Linux:
# go install mvdan.cc/sh/v3/cmd/shfmt@latest
# 或下载二进制: https://github.com/mvdan/sh/releases

# Bats v1.13.0（仅开发时需要）
brew install bats-core           # macOS
# Linux:
# git clone https://github.com/bats-core/bats-core.git /tmp/bats-core
# cd /tmp/bats-core && sudo ./install.sh /usr/local

# 验证版本
shellcheck --version             # 预期: 0.11.0
shfmt --version                  # 预期: v3.13.1
bats --version                   # 预期: 1.13.0
```

## .shellcheckrc 配置（项目根目录）

```ini
# noda-infra ShellCheck 配置
# 文档: https://github.com/koalaman/shellcheck/wiki/Directive

# shell 方言
shell=bash

# source 路径：相对于脚本目录查找 source 文件
source-path=SCRIPTDIR

# 允许 source 任何文件（项目中有大量 source 语句）
external-sources=true

# 启用可选检查
enable=quote-safe-variables
enable=check-unassigned-uppercase
enable=require-variable-ranges

# 排除不适用的规则
# SC2155: declare and assign separately（项目风格允许合并声明赋值）
disable=SC2155

# SC2034: unused variable（backup/lib/constants.sh 定义大量常量，部分可能未使用）
disable=SC2034
```

## .editorconfig 配置（项目根目录，shfmt 会读取）

```ini
# Shell 脚本格式化配置
[*.sh]
indent_style = space
indent_size = 4
# shfmt 选项: -i 4 -fn (4空格缩进, 函数起始花括号换行)
```

## 使用命令

```bash
# ============================================
# 日常重构工作流
# ============================================

# 1. 修改前：记录当前状态
shellcheck -f json scripts/lib/log.sh > /tmp/before.json

# 2. 修改脚本...

# 3. 修改后：验证 ShellCheck 错误数没有增加
shellcheck scripts/lib/log.sh

# 4. 格式化（先检查差异，再写入）
shfmt -d scripts/lib/log.sh       # 查看差异
shfmt -w scripts/lib/log.sh       # 写入格式化结果

# 5. 语法检查（ShellCheck 已包含，快速单独检查）
bash -n scripts/lib/log.sh

# 6. 全量检查（CI 中使用）
shellcheck scripts/**/*.sh
shfmt -d scripts/**/*.sh
```

## Alternatives Considered

### 静态分析工具

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| ShellCheck | bashate (OpenStack) | 规则少（约 30 条 vs ShellCheck 300+ 条），不支持 bash 高级特性，已多年不活跃 |
| ShellCheck | SobboleScan | 学术原型，不维护 |
| ShellCheck | 自定义 grep/sed 检查 | 不可靠，维护成本高，ShellCheck 已覆盖所有常见错误 |

### 格式化工具

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| shfmt | beautify_bash (Python) | 已停止维护，不支持 bash 高级语法 |
| shfmt | editor auto-format | 无法在 CI 中统一执行 |
| shfmt | 手动格式化 | 不可靠，无法保证一致性 |

### 测试框架

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| Bats | shellspec | 语法更接近 RSpec 但社区更小；项目现有测试是手写 bash 脚本，迁移到 Bats 改动更小 |
| Bats | shunit2 | Google 出品但已停止维护（最后 release 2018），功能远不如 Bats |
| Bats | 手写测试脚本（项目现状） | 项目已有 12 个手写测试脚本，但没有断言框架，测试失败依赖 exit code，不好维护。Bats 的 `assert_output`/`assert_success` 更清晰 |

### 重复代码检测

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| `diff` + 人工审查 | CPD (PMD Copy-Paste Detector) | CPD 不支持 Shell 语法，只能做纯文本匹配 |
| `diff` + 人工审查 | SonarQube | 需要安装完整平台，过度工程化 |
| `diff` + 人工审查 | 自定义脚本检测重复函数 | 投入产出比低，项目只有 65 个脚本，人工审查可控 |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| bashate | 规则太少（30条 vs ShellCheck 300+条），OpenStack 项目已不积极维护 | ShellCheck |
| shunit2 | 最后 release 2018 年，不支持 TAP 协议，功能远不如 Bats | Bats |
| ShellCheck `disable=all` | 完全禁用检查，失去静态分析的价值 | 逐条禁用特定 SC 编号 |
| 大规模自动化重构工具 | Shell 脚本没有安全的 AST 级别自动重构工具，awk/sed 替换会破坏字符串内容 | 手动重构 + ShellCheck 验证 |
| ctags/cscope | 设计用于 C/C++ 代码浏览，对 Shell 脚本的函数识别不可靠 | `grep -n "^function\|^[a-z_]*() {" scripts/*.sh` |
| IDE 重构功能 | VS Code/Zed 的 Shell 重构支持极其有限（无 rename symbol、无 extract function） | 手动重构 + shfmt 格式化 |

## 重构验证策略

### 分层验证

| 层次 | 工具 | 目的 | 何时执行 |
|------|------|------|---------|
| L1: 语法 | `bash -n` / ShellCheck | 确保脚本可解析 | 每次保存后 |
| L2: 格式 | `shfmt -d` | 统一代码风格 | 每次 commit 前 |
| L3: 语义 | `shellcheck -S warning` | 检测潜在运行时错误 | 每次 commit 前 |
| L4: 功能 | 手动测试 / Bats | 确保行为不变 | 合并重复代码后 |
| L5: 集成 | Jenkins Pipeline | 生产环境端到端验证 | phase 完成后 |

### 重复代码合并的安全流程

```
1. shellcheck 原始两个文件（记录 warning 数量）
2. diff 两个文件，标记差异点
3. 编写合并后的新文件
4. shellcheck 新文件（warning 数量不应增加）
5. shfmt -w 新文件
6. source 新文件 + 调用函数验证（手动或 Bats）
7. 更新所有引用点的 source 路径
8. 删除旧文件
9. grep 确认无残留引用
10. git commit（一个逻辑变更一次 commit）
```

## 版本兼容性

| Component | Version | Compatible With | Notes |
|-----------|---------|-----------------|-------|
| ShellCheck v0.11.0 | 2025-08-03 | macOS (arm64/x86_64), Linux (x86_64/aarch64) | 预编译二进制，无运行时依赖 |
| shfmt v3.13.1 | 2026-04-06 | macOS, Linux | Go 单二进制文件，无依赖 |
| Bats v1.13.0 | 2025-11-07 | macOS (bash 3.2+), Linux (bash 4.0+) | macOS 自带 bash 3.2 兼容 |
| `.shellcheckrc` | ShellCheck 0.7.0+ | 当前 v0.11.0 完全支持 | - |
| `.editorconfig` | shfmt v3.0+ | 当前 v3.13.1 完全支持 | shfmt 会读取 .editorconfig 中的 indent 设置 |

## 与现有架构的集成点

| 现有组件 | 集成方式 | 变更范围 |
|---------|---------|---------|
| `scripts/pipeline-stages.sh` (1108行) | ShellCheck 分析 + 函数提取拆分 | 大 — 核心重构目标 |
| `scripts/setup-jenkins.sh` (1029行) | ShellCheck 分析 + 子命令拆分 | 大 — 核心重构目标 |
| `scripts/manage-containers.sh` (659行) | ShellCheck 分析 + 函数提取 | 中 |
| `scripts/lib/log.sh` + `scripts/backup/lib/log.sh` | 合并为单一日志库 | 中 — 需更新所有 source 路径 |
| `scripts/lib/health.sh` + `scripts/backup/lib/health.sh` | 重命名消除混淆（功能不同） | 小 — 仅重命名 |
| `scripts/blue-green-deploy.sh` + `scripts/keycloak-blue-green-deploy.sh` | 参数化为单一脚本 | 中 — 核心重构目标 |
| `scripts/verify/*.sh` (5个脚本) | 评估是否删除（一次性验证脚本） | 小 — 删除或合并 |
| `jenkins/Jenkinsfile.*` | 可选：添加 ShellCheck 阶段 | 小 — 可在后续 milestone 做 |
| 现有测试脚本 (`scripts/backup/tests/*.sh`) | 保持现状，不强制迁移 Bats | 无 — 本次不涉及 |

## Sources

- [ShellCheck GitHub Releases](https://github.com/koalaman/shellcheck/releases) — v0.11.0 (2025-08-03) 最新稳定版，HIGH confidence
- [ShellCheck Wiki - Directive](https://github.com/koalaman/shellcheck/wiki/Directive) — .shellcheckrc 配置语法，HIGH confidence
- [ShellCheck Wiki - Ignore](https://github.com/koalaman/shellcheck/wiki/Ignore) — disable/enable 规则方法，HIGH confidence
- [Context7 /koalaman/shellcheck] — ShellCheck 安装、配置、规则信息，HIGH confidence
- [shfmt GitHub Releases](https://github.com/mvdan/sh/releases) — v3.13.1 (2026-04-06) 最新稳定版，HIGH confidence
- [Bats-core GitHub Releases](https://github.com/bats-core/bats-core/releases) — v1.13.0 (2025-11-07) 最新稳定版，HIGH confidence
- [GitHub API: /repos/koalaman/shellcheck/releases/latest](https://api.github.com/repos/koalaman/shellcheck/releases/latest) — 版本号验证，HIGH confidence
- [GitHub API: /repos/mvdan/sh/releases/latest](https://api.github.com/repos/mvdan/sh/releases/latest) — 版本号验证，HIGH confidence
- [GitHub API: /repos/bats-core/bats-core/releases/latest](https://api.github.com/repos/bats-core/bats-core/releases/latest) — 版本号验证，HIGH confidence
- 项目代码: `scripts/lib/log.sh`, `scripts/backup/lib/log.sh`, `scripts/lib/health.sh`, `scripts/backup/lib/health.sh`, `scripts/blue-green-deploy.sh`, `scripts/keycloak-blue-green-deploy.sh` — 重复代码分析

---
*Stack research for: Noda v1.7 Shell 脚本重构与代码精简*
*Researched: 2026-04-18*
