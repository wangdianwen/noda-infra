---
phase: 38-quality-assurance
plan: 01
status: complete
---

# Plan 38-01: ShellCheck/shfmt 配置基础设施

## What was built

安装 shfmt 3.13.1 并创建项目级配置基础设施：

- `.editorconfig` — shfmt 格式化规则（4 空格缩进、bash 方言、case 缩进、函数大括号另起行）
- `.shellcheckrc` — ShellCheck 项目级抑制规则（SC2034 未使用变量、SC2155 local+assign 合并）

## Key Decisions

- 使用 `.editorconfig`（而非 `.shfmt`）作为配置格式，shfmt 原生支持且更通用
- 排除 DEPRECATED 脚本 `deploy-findclass-zero-deps.sh`（`.editorconfig` ignore 规则）
- SC2034 和 SC2155 全局抑制（项目模式决定，逐文件修改风险大于收益）

## Verification

- `shfmt --version` → 3.13.1
- `shfmt -f scripts/ | wc -l` → 60 文件（正确排除 DEPRECATED）
- `shellcheck -S error scripts/**/*.sh` → exit 0（0 error）
- `.editorconfig` 包含 `shell_variant = bash`, `function_next_line = true`
- `.shellcheckrc` 包含 `shell=bash`, `external-sources=true`, `disable=SC2034`, `disable=SC2155`

## Key Files

### Created
- `.editorconfig` — shfmt 格式化配置 + 编辑器通用配置
- `.shellcheckrc` — ShellCheck 项目级抑制规则

## Deviations

无偏差，完全按计划执行。
