---
phase: 11-服务整合
verified: 2026-04-11T02:30:00Z
status: gaps_found
score: 5/9 must-haves verified
overrides_applied: 0
gaps:
  - truth: "findclass-ssr 所有相关文件（Dockerfile、配置）位于 noda-apps/ 目录下，docker compose config 输出路径正确且服务正常启动"
    status: partial
    reason: "Dockerfile 仍在 noda-infra/deploy/ 目录下，未迁移到 noda-apps/。但 compose 文件路径引用已统一，docker compose config 能正确解析路径（需要 noda-apps 同级目录存在）。实际做法比原始需求更合理：Dockerfile 归属于基础设施仓库，compose 路径引用已统一。"
    artifacts:
      - path: "deploy/Dockerfile.findclass-ssr"
        issue: "Dockerfile 仍在 noda-infra 仓库，未迁移到 noda-apps/ 目录"
    missing:
      - "REQUIREMENTS.md GROUP-01 描述需更新以反映实际实现（路径统一而非文件迁移）"
      - "ROADMAP.md SC 1 需更新以匹配实际交付物"
  - truth: "docker compose ps --format json 显示所有容器带有 noda-apps 分组标签，可通过 docker compose ps --filter label=project=noda-apps 过滤查看"
    status: partial
    reason: "实现了功能等价的自定义标签 noda.service-group=infra/apps，但标签名称与 ROADMAP SC 中描述的 project=noda-apps 不一致。过滤命令应为 docker ps --filter label=noda.service-group=apps 而非 label=project=noda-apps"
    artifacts:
      - path: "docker/docker-compose.yml"
        issue: "使用 noda.service-group 而非 project=noda-apps"
    missing:
      - "ROADMAP.md SC 2 需更新为实际的过滤命令和标签名称"
---

# Phase 11: 服务整合 Verification Report

**Phase Goal:** findclass-ssr 相关文件归入统一目录结构，Docker 容器分组清晰可辨
**Verified:** 2026-04-11T02:30:00Z
**Status:** gaps_found
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

Truths 来源：ROADMAP.md Success Criteria (2) + PLAN 11-01 must_haves (3 truths) + PLAN 11-02 must_haves (4 truths)，去重后 9 个。

| # | Truth | Source | Status | Evidence |
|---|-------|--------|--------|----------|
| 1 | docker compose config 对所有 compose 文件输出正确的 Dockerfile 路径 | PLAN 01 | VERIFIED | docker-compose.yml 和 docker-compose.app.yml 均包含 `dockerfile: ../noda-infra/deploy/Dockerfile.findclass-ssr`，目标文件存在于 deploy/ 目录 |
| 2 | 所有 compose 文件中 findclass-ssr 的 dockerfile 指向同一份 noda-infra/deploy/Dockerfile.findclass-ssr | PLAN 01 | VERIFIED | grep 确认 docker-compose.yml:104 和 docker-compose.app.yml:20 均为 `../noda-infra/deploy/Dockerfile.findclass-ssr`，完全一致 |
| 3 | 废弃部署脚本中的 Dockerfile 引用被修复或标记废弃 | PLAN 01 | VERIFIED | deploy-findclass-zero-deps.sh 第 2 行包含 DEPRECATED 标记，build_images 函数替换为错误提示+exit 1，grep 确认不含 Dockerfile.findclass 和 Dockerfile.api 引用 |
| 4 | 所有基础设施服务容器带有 noda.service-group=infra 标签 | PLAN 02 | VERIFIED | 13 个 infra 标签分布在 5 个文件中（docker-compose.yml:4, dev.yml:2, simple.yml:5, prod.yml:1, dev-standalone.yml:1） |
| 5 | 所有应用服务容器带有 noda.service-group=apps 标签 | PLAN 02 | VERIFIED | 4 个 apps 标签分布在 4 个文件中（docker-compose.yml:1, app.yml:1, prod.yml:1, dev.yml:1） |
| 6 | 可通过 docker ps --filter label=noda.service-group=apps 过滤查看应用容器 | PLAN 02 | VERIFIED | labels 数组格式正确，Docker Compose 语法验证无错误 |
| 7 | 可通过 docker ps --filter label=noda.service-group=infra 过滤查看基础设施容器 | PLAN 02 | VERIFIED | 同上，所有 infra 标签格式一致 |
| 8 | findclass-ssr 所有相关文件（Dockerfile、配置）位于 noda-apps/ 目录下，docker compose config 输出路径正确且服务正常启动 | ROADMAP SC 1 | PARTIAL | Dockerfile 仍在 noda-infra/deploy/ 而非 noda-apps/ 目录。路径引用已统一，但文件位置与 SC 描述不符 |
| 9 | docker compose ps 显示所有容器带有 noda-apps 分组标签，可通过 label=project=noda-apps 过滤查看 | ROADMAP SC 2 | PARTIAL | 实现了 noda.service-group=infra/apps 标签（功能等价），但标签名称与 SC 中的 project=noda-apps 不一致 |

**Score:** 5/9 truths fully verified, 2 partial (ROADMAP SC wording mismatch), 2 PLAN-only truths verified as part of truths 1-7

### Analysis of ROADMAP SC Mismatches

**ROADMAP SC 1 vs 实际实现：**

GROUP-01 原始需求："findclass-ssr 目录迁移 -- 相关文件迁移到 noda-apps/ 目录下"
实际实现：统一 compose 文件中的 Dockerfile 路径引用，Dockerfile 仍在 noda-infra/deploy/

PLAN 对 GROUP-01 的重新解释是合理的：
- noda-apps 是应用代码仓库（build context），noda-infra 是基础设施仓库
- Dockerfile.findclass-ssr 定义构建流程，属于基础设施配置，放在 noda-infra 是正确的
- 原始需求措辞"迁移到 noda-apps/"在架构上不合理
- 实际问题（两个 compose 文件指向不同 Dockerfile）已被解决

**ROADMAP SC 2 vs 实际实现：**

SC 提到 `label=project=noda-apps` 过滤，实际使用 `noda.service-group=infra/apps`
- 自定义标签方案更优：可区分 infra 和 apps 两类服务
- 使用 project=noda-apps 无法实现 infra/apps 的分类过滤
- 多个 compose 文件已有不同 project name（noda-infra, noda-apps, noda-dev）

**结论：** 实际实现比 ROADMAP SC 描述更合理，但文档需更新以反映实际交付物。

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| docker/docker-compose.yml | 基础 compose，Dockerfile 路径统一 + 分组标签 | VERIFIED | dockerfile 统一为 ../noda-infra/deploy/Dockerfile.findclass-ssr，5 个服务标签（4 infra + 1 apps） |
| docker/docker-compose.app.yml | 应用 compose，Dockerfile 路径统一 + 分组标签 | VERIFIED | dockerfile 统一，1 个 apps 标签 |
| scripts/deploy/deploy-findclass-zero-deps.sh | 废弃脚本标记 | VERIFIED | 第 2 行 DEPRECATED 标记，build_images 替换为 exit 1 |
| docker/docker-compose.prod.yml | 生产 overlay 分组标签 | VERIFIED | 2 个标签（keycloak infra + findclass-ssr apps） |
| docker/docker-compose.simple.yml | 简化版分组标签 | VERIFIED | 5 个 infra 标签 |
| docker/docker-compose.dev.yml | 开发 overlay 分组标签 | VERIFIED | 3 个标签（2 infra + 1 apps） |
| docker/docker-compose.dev-standalone.yml | 独立开发分组标签 | VERIFIED | 1 个 infra 标签 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| docker-compose.yml | deploy/Dockerfile.findclass-ssr | build.dockerfile 相对路径 | VERIFIED | 行 104: `dockerfile: ../noda-infra/deploy/Dockerfile.findclass-ssr`，目标文件存在 |
| docker-compose.app.yml | deploy/Dockerfile.findclass-ssr | build.dockerfile 相对路径 | VERIFIED | 行 20: `dockerfile: ../noda-infra/deploy/Dockerfile.findclass-ssr`，目标文件存在 |
| docker-compose.yml | 容器运行时标签 | labels 指令 | VERIFIED | 5 个 noda.service-group 标签 |
| docker-compose.app.yml | 容器运行时标签 | labels 指令 | VERIFIED | 1 个 noda.service-group 标签 |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none) | - | - | - | 无 TODO/FIXME/placeholder/空实现发现 |

### Commit Verification

| Commit | Hash | Description | Verified |
|--------|------|-------------|----------|
| PLAN 01 Task 1 | dbcf4e8 | 统一 findclass-ssr Dockerfile 路径引用 | git show 确认，1 file changed |
| PLAN 01 Task 2 | 628e400 | 废弃 deploy-findclass-zero-deps.sh 脚本 | git show 确认，1 file changed, +3/-26 |
| PLAN 02 Task 1 | f43f839 | 为主 compose 文件添加分组标签 | git show 确认，3 files changed, +16 |
| PLAN 02 Task 2 | 9dbf530 | 为辅助 compose 文件添加分组标签 | git show 确认，3 files changed, +18 |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| GROUP-01 | 11-01 | findclass-ssr 目录迁移 -- 相关文件迁移到 noda-apps/ 目录下 | SATISFIED (interpretation) | 实际实现为统一路径引用而非文件迁移。PLAN 重新解释了需求，解决根因（路径不一致）而非执行字面操作（迁移文件） |
| GROUP-02 | 11-02 | Docker 分组标签 -- 容器 labels/project 归入 noda-apps 分组 | SATISFIED | 6 个 compose 文件中 17 个服务标签已配置，使用 noda.service-group=infra/apps 替代 project 归属 |

**Orphaned requirements:** 无 -- GROUP-01 和 GROUP-02 均被 PLAN 覆盖。

### Gaps Summary

Phase 11 的两个核心目标（路径统一 + 分组标签）在技术实现上已完成：
- Dockerfile 路径引用在所有 compose 文件中已统一
- 17 个服务标签（13 infra + 4 apps）正确分布在 6 个 compose 文件中
- 废弃脚本已标记并禁用

**但 ROADMAP.md 和 REQUIREMENTS.md 的文字描述与实际实现存在偏差：**

1. **ROADMAP SC 1** 描述"文件位于 noda-apps/ 目录下"与实际不符。Dockerfile 仍在 noda-infra/deploy/（这是架构上正确的位置），但需求描述需要更新以反映实际设计决策。

2. **ROADMAP SC 2** 描述的 `label=project=noda-apps` 过滤方式与实际实现的 `noda.service-group=infra/apps` 不一致。实际方案功能更完善（支持 infra/apps 分类），但文档需要更新。

这两个 gap 是文档与实现的措辞差异，而非功能缺失。实际实现比原始需求描述更合理。建议通过 override 或更新 ROADMAP.md/REQUIREMENTS.md 来对齐。

---

_Verified: 2026-04-11T02:30:00Z_
_Verifier: Claude (gsd-verifier)_
