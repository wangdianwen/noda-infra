# Phase 38: 质量保证 - Context

**Gathered:** 2026-04-19
**Status:** Ready for planning

<domain>
## Phase Boundary

scripts/ 目录下所有 .sh 文件通过 ShellCheck 零 error 检查并有一致的代码风格。纯机械化质量 pass，不引入新功能。

</domain>

<decisions>
## Implementation Decisions

### ShellCheck (QUAL-01)
- **D-01:** 当前 ShellCheck 已报告 0 error。创建 `.shellcheckrc` 文件记录项目级抑制规则（如 SC1091 source 路径动态解析、SC2154 环境变量等），确保未来新增代码也能通过检查
- **D-02:** 对 warning 级别问题按需抑制，不强制消除（部分 warning 为合理模式）

### shfmt 格式化 (QUAL-02)
- **D-03:** 安装 shfmt（`brew install shfmt` 或 `go install`），使用 `-i 4 -ci -fn` 选项（4 空格缩进、switch case 缩进、函数大括号另起行）
- **D-04:** 创建 `.editorconfig` 或 `.shfmt` 配置文件固化格式规则

### 排除范围
- **D-05:** 已标记 DEPRECATED 的脚本（deploy-findclass-zero-deps.sh）不格式化，避免无意义的变更
- **D-06:** 不修改 `docker/` 目录下的文件（Dockerfile、compose 文件不是 shell 脚本）

### Claude's Discretion
- 具体抑制哪些 ShellCheck warning（按实际情况判断）
- `.editorconfig` vs `.shfmt` 配置文件格式选择

</decisions>

<canonical_refs>
## Canonical References

- `.planning/REQUIREMENTS.md` — QUAL-01, QUAL-02 需求定义
- `.planning/ROADMAP.md` — Phase 38 范围
- `.planning/config.json` — 项目配置

</canonical_refs>

<code_context>
## Existing Code Insights

### 当前状态
- 61 个 shell 脚本在 scripts/ 目录下
- ShellCheck 已安装（/opt/homebrew/bin/shellcheck），当前 0 error
- shfmt 未安装，需要安装
- 无 `.shellcheckrc` 或 `.editorconfig` 配置文件

### 关键文件
- `scripts/lib/` — 共享库（Phase 35 提取）
- `scripts/deploy/` — 部署脚本（Phase 36 统一蓝绿部署）
- `scripts/backup/` — 备份系统（核心价值，谨慎修改）
- `scripts/deploy/deploy-findclass-zero-deps.sh` — DEPRECATED，排除

</code_context>

<specifics>
## Specific Ideas

- 先安装 shfmt，再统一格式化，最后运行 ShellCheck 确认无新增 error
- 格式化后需要验证所有脚本的 `bash -n` 语法检查仍然通过
- Phase 35-37 的重构可能引入了一些风格不一致，这是预期的

</specifics>

<deferred>
## Deferred Ideas

None — 讨论保持在 phase 范围内

</deferred>

---

*Phase: 38-quality-assurance*
*Context gathered: 2026-04-19*
