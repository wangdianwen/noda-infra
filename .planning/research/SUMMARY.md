# Project Research Summary

**Project:** Noda v1.7 -- Shell 脚本重构与代码精简
**Domain:** Shell/Bash 脚本重构 -- 静态分析、重复代码消除、蓝绿部署统一
**Researched:** 2026-04-18
**Confidence:** HIGH

## Executive Summary

Noda v1.7 的目标是精简项目中的 65 个 Shell 脚本（约 15,137 行），消除约 670 行重复代码，将两个蓝绿部署脚本合并为一个参数化入口。研究结论是：不需要引入任何运行时依赖。重构工具链由 ShellCheck（静态分析）、shfmt（格式化）、Bats（测试）三件套组成，全部是开发工具。核心重构策略是"提取共享库 + 环境变量参数化"——将 `http_health_check` 和 `e2e_verify` 从 4 处重复定义提取到 `lib/http-check.sh`，将两个蓝绿部署脚本通过 `SERVICE_PORT`/`HEALTH_PATH`/`SERVICE_IMAGE` 等环境变量统一为一个入口。

推荐路径是先建立共享库（log.sh 增强、http-check.sh 新建、image-cleanup.sh 新建），再重构消费者脚本（蓝绿部署合并、pipeline-stages 精简、rollback-findclass 精简），最后清理一次性脚本和可选拆分。Phase 1 聚焦 5 个基本要求特性，预计净减 670 行代码。

关键风险集中在三方面：(1) log.sh 合并争议——Architecture 研究者建议合并、Pitfalls 研究者明确反对，Pitfalls 的论证更具体且涉及核心价值"数据库永不丢失"，建议采纳 Pitfalls 立场，不合并 log.sh；(2) 蓝绿部署脚本合并时 `http_health_check` 的执行上下文差异（容器内部 vs nginx 容器）必须参数化保留，不能抹平；(3) `pipeline-stages.sh` 的 `pipeline_*` 函数签名变更必须同步修改 Jenkinsfile，否则部署 Pipeline 运行时崩溃。

## Key Findings

### Recommended Stack

全部基于成熟的开发工具，无运行时依赖。安装后可用于整个项目的持续质量保证。

**核心工具：**
- **ShellCheck v0.11.0** -- Shell 脚本静态分析 -- 300+ 条规则检测常见错误，SC2329（未调用函数检测）对识别死代码极其有用
- **shfmt v3.13.1** -- Shell 脚本格式化 -- 基于 mvdan/sh parser 的唯一成熟格式化工具，`-s` 简化模式可自动简化冗余语法
- **Bats v1.13.0** -- Shell 脚本测试框架 -- 事实标准，`@test` + `run`/`assert` 模式，项目已有 12 个手写测试脚本可渐进迁移

**辅助工具：** `diff` + `source` 验证（合并后功能等价性）、`.shellcheckrc`（项目级配置）、`.editorconfig`（shfmt 读取缩进配置）

### Expected Features

**Must have（table stakes）：**
- T-01: 统一日志库 -- 合并 scripts/lib/log.sh 和 scripts/backup/lib/log.sh（**有争议，见下方冲突说明**）
- T-02: 提取 http_health_check + e2e_verify 到 scripts/lib/http-check.sh -- 消除 4 处约 360 行最危险的重复代码
- T-03: 合并蓝绿部署脚本 -- 参数化统一 blue-green-deploy.sh 和 keycloak-blue-green-deploy.sh
- T-04: 删除 scripts/verify/ 下 5 个一次性脚本 -- 硬编码旧架构，已不能运行
- T-05: 提取 detect_platform 到 scripts/lib/platform.sh -- 消除 8 处约 48 行重复

**Should have（competitive）：**
- D-01: pipeline-stages.sh 拆分 -- 将应用 Pipeline 和基础设施 Pipeline 分为两个文件
- D-05: backup/lib/health.sh 重命名为 precheck.sh -- 消除与 scripts/lib/health.sh 的命名混淆
- D-06: nginx/noda-ops 回滚代码去重 -- 提取 rollback_compose_service() 共享函数

**Defer（v2+）：**
- D-02: setup-jenkins.sh 拆分（当前 1029 行）
- D-03: 合并两个 jenkins-pipeline 脚本
- D-04: 8 个安全脚本收敛为单一入口

### Architecture Approach

保持现有 `source` + 函数库模式，不引入框架。新增 3 个共享库文件，保持 backup/ 子系统独立性。

**Major components:**
1. **scripts/lib/http-check.sh**（新增）-- HTTP 健康检查 + E2E 验证，通过环境变量参数化 SERVICE_PORT/HEALTH_PATH/HEALTH_CHECK_MAX_RETRIES，所有差异点通过函数参数控制
2. **scripts/lib/image-cleanup.sh**（新增）-- 镜像清理（SHA 标签 + dangling），三种策略保留为独立函数
3. **scripts/blue-green-deploy.sh**（重写）-- 通用蓝绿部署入口，通过 SERVICE_IMAGE 是否设置决定构建 vs 拉取模式

**关键架构模式：**
- Source Guard（`BASH_SOURCE[0] == ${0}` 模式）-- 库文件防直接执行
- 环境变量参数化 -- manage-containers.sh 已验证的成熟模式
- 依赖注入 -- http-check.sh 不直接 source manage-containers.sh，通过调用者间接获取 `get_container_name()`

### Critical Pitfalls

1. **log.sh 合并破坏备份系统** -- 两个 log.sh 接口和运行环境不同（宿主机彩色日志 vs 容器 cron 纯文本日志），backup 版有 `set -euo pipefail` 和 `log_progress`/`log_json`/`log_structured` 三个额外函数。合并会导致备份脚本崩溃，威胁核心价值"数据库永不丢失"。建议不合并，保留两个独立 log.sh
2. **http_health_check 执行上下文差异丢失** -- 4 处实现中，3 处在目标容器内部执行 wget，pipeline-stages.sh 在 nginx 容器内执行。合并时必须参数化执行容器，不能依赖默认值
3. **pipeline_* 函数签名变更导致 Jenkins 运行时崩溃** -- Jenkinsfile 通过字符串拼接调用 pipeline 函数，无编译时检查。重命名或修改参数签名只在运行时暴露错误
4. **readonly 变量冲突** -- backup/lib/constants.sh 的 14 个 readonly 变量在 source 时重复定义会导致 bash 崩溃。跨目录 source 时必须保留条件加载 guard
5. **macOS/Linux 双平台代码被误删** -- `date -v`/`date -d`、`stat -f`/`stat -c` 兼容代码在精简时可能被误认为"多余"而删除

### Researcher Conflict: log.sh Merge

**Architecture 研究者（主张合并）：** backup/lib/log.sh 是 scripts/lib/log.sh 的超集（多 3 个函数），应合并到 scripts/lib/log.sh，删除 backup/lib/log.sh，backup 脚本改 source 路径。

**Pitfalls 研究者（主张不合并）：** 两个 log.sh 服务于完全不同的运行环境——scripts/lib/log.sh 在宿主机终端（带 ANSI 颜色），backup/lib/log.sh 在 noda-ops 容器内 cron 环境（纯文本，颜色码会污染日志文件）。backup 版有 `set -euo pipefail`（库文件中不应有）。合并后备份脚本可能崩溃，威胁核心价值。

**推荐结论：采纳 Pitfalls 立场，不合并 log.sh。** 理由：(1) Pitfalls 论证更具体，逐条列出接口差异和后果；(2) 备份系统是核心价值"数据库永不丢失"的保障，风险不可接受；(3) 不合并的代价极低——仅保留两个独立文件，每个都有清晰的注释说明其用途和运行环境。如果未来需要统一，应以 backup/lib/log.sh 为基础创建"无颜色超集"，但需确保 `set -euo pipefail` 仅在入口脚本中设置。

## Implications for Roadmap

基于研究，建议 4 个 Phase 的结构。

### Phase 1: 共享库建设（基础设施层）
**Rationale:** 所有后续重构依赖共享库。先建立 http-check.sh、image-cleanup.sh、platform.sh，再让消费者脚本 source 它们。依赖关系决定了必须先有库再有消费者。
**Delivers:** 3 个新共享库文件 + ShellCheck/shfmt 工具配置 + 验证 detect_platform 提取安全
**Addresses:** T-02（http_health_check/e2e_verify 提取）、T-05（detect_platform 提取）
**Avoids:** Pitfall 7（http_health_check 行为差异丢失）-- 参数化所有差异点，不依赖默认值
**净变化:** ~+95 行（新文件）/-456 行（删除重复），约 -361 行

### Phase 2: 蓝绿部署统一
**Rationale:** 依赖 Phase 1 的 http-check.sh 和 image-cleanup.sh。这是最有价值的重构——两个 297 行脚本 95% 逻辑相同，合并为一个约 120 行的参数化脚本。合并后 Jenkinsfile 需同步修改调用方式。
**Delivers:** 统一的 blue-green-deploy.sh 入口 + 删除 keycloak-blue-green-deploy.sh + rollback-findclass.sh 精简
**Addresses:** T-03（蓝绿部署合并）
**Avoids:** Pitfall 3（硬编码 URL 丢失）-- 全部通过环境变量参数化；Pitfall 2（readonly 冲突）-- 不涉及 constants.sh
**净变化:** ~+120 行/-794 行（两个旧脚本 + rollback 内联副本删除），约 -674 行

### Phase 3: 清理与精简
**Rationale:** Phase 1-2 建立新模式后，清理遗留物。删除不可用的一次性验证脚本、重命名 backup/lib/health.sh 消除混淆。风险极低，可快速完成。
**Delivers:** verify/ 目录清理 + backup/lib/health.sh 重命名 + pipeline-stages.sh 精简（删除内联副本）
**Addresses:** T-04（删除验证脚本）、D-01（pipeline-stages 拆分）、D-05（health.sh 重命名）、D-06（回滚代码去重）
**Avoids:** Pitfall 4（丧失验证能力）-- 先标记废弃确认无引用再删；Pitfall 5（函数签名变更）-- 拆分不改名
**净变化:** ~+20 行/-150 行

### Phase 4: 质量保证与格式化（可选）
**Rationale:** 重构完成后统一格式化全量脚本，建立 ShellCheck CI 阶段。这是收尾工作，确保所有脚本风格统一，为后续开发建立质量基线。
**Delivers:** 全量 shfmt 格式化 + ShellCheck 零 error + 可选 Jenkins ShellCheck 阶段
**Uses:** ShellCheck、shfmt、.shellcheckrc、.editorconfig
**净变化:** 0 行（纯格式化，无功能变更）

### Phase Ordering Rationale

1. **Phase 1 先行：** http-check.sh 是蓝绿部署合并和 pipeline-stages 精简的前置依赖。没有共享库，后续重构无法开始
2. **Phase 2 紧随：** 蓝绿部署合并是本次重构的核心价值（-674 行），但依赖 http-check.sh 和 image-cleanup.sh 就绪
3. **Phase 3 可部分并行：** verify 脚本删除与 Phase 2 无依赖关系，但 pipeline-stages 精简依赖 Phase 1 的共享库
4. **Phase 4 最后：** 格式化必须在所有功能变更完成后统一执行，避免 merge conflict

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2:** 蓝绿部署合并涉及核心部署逻辑，需要逐行对比两个脚本的所有差异点（264 行差异），确保参数化不遗漏。建议在测试环境先对 findclass-ssr 和 keycloak 各做一次完整蓝绿部署验证
- **Phase 3:** pipeline-stages.sh 拆分前需要完整梳理所有 `pipeline_*` 函数在 Jenkinsfile 中的调用点，确保拆分后引用不中断

Phases with standard patterns (skip research-phase):
- **Phase 1:** 提取函数到独立文件 + source 引用是 shell 脚本标准重构模式，ShellCheck 可验证
- **Phase 4:** shfmt 格式化 + ShellCheck 检查是标准工具使用，文档充分

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | ShellCheck/shfmt/Bats 均为 shell 脚本领域唯一成熟工具，无可替代品。版本号通过 GitHub API 验证 |
| Features | HIGH | 基于完整代码阅读（65 个脚本），重复代码通过 grep 确认，非推测。特性依赖关系明确 |
| Architecture | HIGH | 基于完整代码库审计，source 链路通过 grep 验证。但 log.sh 合并方案与 Pitfalls 有冲突，采纳 Pitfalls 立场 |
| Pitfalls | HIGH | 基于逐文件比对重复代码，Shell 脚本行为确定性高。Pitfall-to-Phase 映射完整 |

**Overall confidence:** HIGH

### Gaps to Address

- **log.sh 合并争议已裁决：** 采纳 Pitfalls 立场不合并。如果 Features 研究者（T-01）的原始需求仍需满足，可考虑仅将 backup 版的 `log_progress`/`log_json`/`log_structured` 三个函数添加到 scripts/lib/log.sh（作为可选增强），但 backup/lib/log.sh 保持独立存在
- **蓝绿部署合并的实际验证：** Phase 2 完成后必须在测试环境对 findclass-ssr 和 keycloak 各做一次完整蓝绿部署，确认参数化无遗漏。生产环境首次使用时应有人工确认环节
- **pipeline-stages.sh 拆分边界：** 需要完整列出所有 `pipeline_*` 和 `pipeline_infra_*` 函数，确认是否有交叉依赖。当前研究基于文件名前缀判断，可能有隐式依赖
- **backup/lib/ source 路径改动：** 如果最终决定让 backup 脚本 source scripts/lib/log.sh（而非保留独立的 backup/lib/log.sh），需要逐个验证 7 个 backup 库文件的 source 链不会引入 readonly 冲突

## Sources

### Primary (HIGH confidence)
- 项目代码库完整审计：scripts/ 目录下 65 个 .sh 文件逐行分析
- 重复代码量化：`grep -rn "http_health_check\|e2e_verify\|detect_platform\|cleanup_old"` 确认所有重复位置
- Source 链分析：`grep -rn "source.*\.sh"` 验证所有依赖关系
- [ShellCheck GitHub Releases](https://github.com/koalaman/shellcheck/releases) -- v0.11.0 版本确认
- [shfmt GitHub Releases](https://github.com/mvdan/sh/releases) -- v3.13.1 版本确认
- [Bats-core GitHub Releases](https://github.com/bats-core/bats-core/releases) -- v1.13.0 版本确认
- [ShellCheck Wiki](https://github.com/koalaman/shellcheck/wiki/Directive) -- .shellcheckrc 配置语法

### Secondary (MEDIUM confidence)
- 行数变化预估基于代码阅读的合理估计，实际可能 +-15%
- 安全脚本收敛（D-04）的复杂度评估为 HIGH，需要逐个审计 8 个脚本的权限逻辑

---
*Research completed: 2026-04-18*
*Ready for roadmap: yes*
