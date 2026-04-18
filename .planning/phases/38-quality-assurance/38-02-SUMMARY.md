---
phase: 38-quality-assurance
plan: 02
status: complete
---

# Plan 38-02: 批量格式化所有活跃 shell 脚本

## What was built

使用 shfmt 3.13.1 批量格式化 56 个活跃 shell 脚本，建立一致的代码风格。

主要变更：
- 6 个文件从 2 空格缩进改为 4 空格（主要是 backup/tests/ 目录）
- ~57 个文件函数声明大括号移至下一行（`name() {` → `name()` + `{` 另起行）
- case 语句统一缩进
- 空格、引号等格式统一

## Key Decisions

- `.editorconfig` 的 `ignore = true` 规则未被 shfmt 3.13.1 尊重（A3 假设风险确认），改用 `find` 排除 DEPRECATED 文件
- DEPRECATED 脚本 `deploy-findclass-zero-deps.sh` 确认未被修改

## Verification

- `find scripts/ -name '*.sh' ! -name 'deploy-findclass-zero-deps.sh' -exec shfmt -d {} \;` → 0 差异
- `shellcheck -S error scripts/**/*.sh` → exit 0（0 error）
- `find scripts/ -name '*.sh' -exec bash -n {} \;` → exit 0（61 文件全部通过）
- `git diff --name-only scripts/deploy/deploy-findclass-zero-deps.sh` → 无输出（未修改）

## Key Files

### Modified
- `scripts/**/*.sh` — 56 个活跃 shell 脚本（格式化）
- 未修改：`scripts/deploy/deploy-findclass-zero-deps.sh`（DEPRECATED）

## Deviations

- `.editorconfig` ignore 规则未生效：shfmt 3.13.1 不支持 EditorConfig 的 `ignore = true` 指令用于单个文件路径匹配。改用 `find` 命令行排除，功能等效。
