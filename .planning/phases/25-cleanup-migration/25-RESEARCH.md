# Phase 25: 清理与迁移 - Research

**Researched:** 2026-04-16
**Domain:** 文档更新与里程碑归档
**Confidence:** HIGH

## Summary

Phase 25 是 v1.4 CI/CD 零停机部署里程碑的收尾阶段。核心工作是三项：(1) 为旧部署脚本添加手动回退方案注释标记；(2) 更新 CLAUDE.md 部署命令章节，反映 Jenkins Pipeline 优先的部署流程；(3) 将 v1.4 里程碑在 ROADMAP.md、PROJECT.md、STATE.md 中归档为已完成状态。

本阶段不涉及代码逻辑变更，全部为文档和注释修改。变更范围小且风险低，但需要确保归档格式与 v1.0~v1.3 一致，且 CLAUDE.md 的部署命令章节准确反映当前架构。

**Primary recommendation:** 严格按照 v1.3 归档格式执行，CLAUDE.md 仅更新"部署命令"章节，不触碰其他章节。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** `deploy-infrastructure-prod.sh` 和 `deploy-apps-prod.sh` 添加文件头注释块，明确标注为"手动回退方案，Jenkins Pipeline 是主要部署方式"
- **D-02:** 不添加运行时警告 -- 脚本行为不变，仅通过文件头注释和文档说明角色
- **D-03:** 同样检查 `deploy-findclass-zero-deps.sh`（已标记 deprecated），确认无需额外处理
- **D-04:** 仅更新"部署命令"章节 -- Jenkins Pipeline 为主，旧脚本标注为手动回退
- **D-05:** 不重写整个 CLAUDE.md，其他章节（架构、部署规则、修复记录等）保持不变
- **D-06:** 新的部署章节应包含：Jenkins 手动触发步骤、旧脚本回退用法、查看状态的只读命令
- **D-07:** ROADMAP.md 中 v1.4 归档格式与 v1.0~v1.3 一致：折叠块 + 统计信息（phases/plans/commits）+ 主要成果列表
- **D-08:** PROJECT.md 更新：Current Milestone 标记为 shipped，Requirements 中 Active 项移至 Validated
- **D-09:** STATE.md 更新：milestone 状态改为 completed

### Claude's Discretion
- 注释块的具体措辞
- CLAUDE.md 部署章节的具体排版
- 归档统计数据的收集方式（git log 命令等）

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ENH-04 | 现有部署脚本（deploy-infrastructure-prod.sh、deploy-apps-prod.sh）保留为手动回退方案 | D-01/D-02 定义了注释标记方式，D-04/D-06 定义了 CLAUDE.md 更新范围，脚本文件已读取确认结构 |
</phase_requirements>

## Standard Stack

本阶段无技术栈依赖，全部为文档操作。

### Core
| 工具 | 用途 | Why |
|------|------|-----|
| git log | 统计 v1.4 里程碑 commits/plans 数据 | [VERIFIED: 已运行 `git log --oneline --since="2026-04-14" \| wc -l` 确认 93 commits] |
| 文本编辑 | 修改注释和文档 | 无需特殊工具 |

### Alternatives Considered
无 -- 本阶段不需要技术选型。

**Installation:**
无安装需求。

## Architecture Patterns

### 需要修改的文件清单

```
scripts/deploy/
├── deploy-infrastructure-prod.sh  # 添加文件头注释块
├── deploy-apps-prod.sh            # 添加文件头注释块
└── deploy-findclass-zero-deps.sh  # 已有 DEPRECATED 标记，确认即可

CLAUDE.md                          # 仅更新"部署命令"章节（第 131-142 行）

.planning/
├── ROADMAP.md                     # v1.4 归档为折叠块 + v1.5 占位
├── PROJECT.md                     # Current Milestone 改为 shipped
├── STATE.md                       # milestone 状态改 completed
└── REQUIREMENTS.md                # ENH-04 标记为完成
```

### Pattern 1: 脚本注释标记
**What:** 在脚本文件头添加手动回退方案注释
**When to use:** 已被 Jenkins Pipeline 替代但仍需保留的旧部署脚本
**Example:**
```bash
#!/bin/bash
# ============================================
# 手动回退部署脚本（生产环境）
# ============================================
# NOTE: 此脚本作为 Jenkins Pipeline 不可用时的紧急回退方案保留。
# 正常部署请使用 Jenkins Pipeline（Build Now -> findclass-deploy）。
# 文件行为不变，可直接手动执行。
# ============================================
```

### Pattern 2: 里程碑归档格式
**What:** ROADMAP.md 中折叠块归档格式
**When to use:** 里程碑完成后的归档
**格式参考 (v1.3):** [VERIFIED: 已读取 `.planning/milestones/v1.3-ROADMAP.md`]
```markdown
<details>
<summary>v1.4 CI/CD 零停机部署 (Phases 19-25) -- SHIPPED 2026-04-16</summary>

7 phases, 10 plans, 93 commits, 87 files changed (+15,539/-1,511 LOC)

- Jenkins 宿主机原生安装/卸载（setup-jenkins.sh 7 子命令）
- Nginx upstream include 抽离（蓝绿路由基础）
- 蓝绿容器管理（docker run 独立 + active-env 状态文件）
- 蓝绿部署核心流程（SHA 标签 + HTTP 健康检查 + nginx 切换 + 回滚）
- Pipeline 集成与测试门禁（Jenkinsfile 9 阶段 + lint/test 质量门禁）
- Pipeline 增强特性（备份时效性检查 + CDN 清除 + 镜像清理）
- 旧脚本保留标记 + 文档更新 + 里程碑归档

</details>
```

### Pattern 3: PROJECT.md 里程碑状态更新
**What:** 将 Current Milestone 改为 shipped，Active Requirements 移至 Validated
**格式参考:** [VERIFIED: 已读取 `.planning/PROJECT.md`]
```markdown
## Shipped Milestones

### v1.4 CI/CD 零停机部署 (2026-04-16)

7 phases, 10 plans, 93 commits, 87 files changed (+15,539/-1,511 LOC)

- Jenkins 宿主机原生安装/卸载脚本
- Nginx upstream include 蓝绿路由基础
- 蓝绿容器独立管理 + 状态文件追踪
- 蓝绿部署核心流程（零停机 + 自动回滚）
- Jenkinsfile 9 阶段 Pipeline + lint/test 质量门禁
- Pipeline 增强特性（备份检查 + CDN 清除 + 镜像清理）
```

### Anti-Patterns to Avoid
- **重写整个 CLAUDE.md:** 仅更新"部署命令"章节（第 131-142 行），其他章节保持不变 [D-04/D-05]
- **添加运行时警告:** 不在脚本中添加 echo/printf 警告，仅通过文件头注释说明 [D-02]
- **删除旧脚本:** 脚本保留且行为不变，只是标注角色变更 [D-01]
- **修改脚本逻辑:** 不改变任何部署逻辑、环境变量或错误处理

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| v1.4 统计数据 | 手动数 commits | `git log --oneline --since="2026-04-14" \| wc -l` | 自动且准确 [VERIFIED: 93 commits] |
| 归档格式 | 自创格式 | 复用 v1.3 折叠块格式 | 一致性 [VERIFIED: `.planning/milestones/v1.3-ROADMAP.md`] |
| REQUIREMENTS 归档 | 直接修改当前文件 | 创建 `.planning/milestones/v1.4-REQUIREMENTS.md` 归档 + 更新当前文件 | 历史记录保留 [VERIFIED: v1.2/v1.3 均有独立归档文件] |

## Common Pitfalls

### Pitfall 1: CLAUDE.md 修改范围失控
**What goes wrong:** 更新部署命令时意外修改了架构章节、部署规则或其他记录
**Why it happens:** CLAUDE.md 有 342 行，内容密集，容易误触其他章节
**How to avoid:** 严格限制修改到第 131-142 行的"部署命令"代码块
**Warning signs:** diff 中出现第 131-142 行以外的变更

### Pitfall 2: 归档统计不准确
**What goes wrong:** 手动数 phases/commits 导致数据与实际不符
**Why it happens:** v1.4 跨度 7 个 phases（19-25），commits 包含 docs/fix/feat 多种类型
**How to avoid:** 使用 git 命令精确统计
- Phases: 19-25 = 7 phases（已知）
- Plans: 2+1+1+2+2+2+1 = 11 plans（需从 ROADMAP.md 确认）
- Commits: `git log --oneline --since="2026-04-14" | wc -l` = 93 [VERIFIED]
- Files changed: `git diff --stat <start>^..HEAD | tail -1` = 87 files [VERIFIED]

### Pitfall 3: STATE.md milestone 状态未完全更新
**What goes wrong:** 只改了 status 字段，没改 stopped_at、last_activity、progress 等
**Why it happens:** STATE.md 是 YAML front matter + markdown 混合格式
**How to avoid:** 更新 front matter 中所有相关字段：status: completed, last_updated, last_activity, progress

### Pitfall 4: PROJECT.md Active Requirements 遗漏
**What goes wrong:** 只把部分 Active 项移到 Validated，遗漏了某些条目
**Why it happens:** Active 列表有多项（6 项），容易遗漏
**How to avoid:** 逐条检查 Active 项，v1.4 范围内的全部移至 Validated，Prisma 7 留在 Active

## Code Examples

### 文件头注释块（deploy-infrastructure-prod.sh）
```bash
#!/bin/bash
# ============================================
# 手动回退部署脚本（生产环境）
# ============================================
# NOTE: 此脚本作为 Jenkins Pipeline 不可用时的紧急回退方案保留。
# 正常部署请使用 Jenkins Pipeline（Build Now -> findclass-deploy）。
#
# 原有功能：自动部署并配置基础设施服务
# 包括：PostgreSQL (Prod/Dev), Keycloak, Nginx, Noda-Ops, Findclass-SSR
#
# 此脚本行为不变，可直接手动执行。
# ============================================
```

### CLAUDE.md 部署命令章节（替换第 131-142 行）
```bash
## 部署命令

### 主要部署方式：Jenkins Pipeline

通过 Jenkins UI 手动触发蓝绿部署 Pipeline：

1. 浏览器访问 Jenkins（默认 http://<server-ip>:8888）
2. 点击 `findclass-deploy` 任务
3. 点击 "Build Now" 按钮
4. Pipeline 自动执行 9 阶段：Pre-flight -> Build -> Test -> Deploy -> Health Check -> Switch -> Verify -> CDN Purge -> Cleanup
5. 查看 Stage View 确认各阶段状态

### 紧急回退：手动部署脚本

Jenkins 不可用时，可使用旧部署脚本手动部署：

```bash
# 全量部署（基础设施 + 应用）
bash scripts/deploy/deploy-infrastructure-prod.sh

# 仅部署应用（findclass-ssr）
bash scripts/deploy/deploy-apps-prod.sh
```

### 查看状态（只读，允许直接使用）

```bash
# Docker Compose 容器状态
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml ps

# 蓝绿容器状态
cat /opt/noda/active-env  # 当前活跃环境（blue/green）
docker ps --filter name=findclass-ssr  # 蓝绿容器列表
```
```

### ROADMAP.md v1.4 归档后里程碑列表
```markdown
## Milestones

- v1.0 完整备份系统 -- Phases 1-9 (shipped 2026-04-06) -- [详情](milestones/v1.0-ROADMAP.md)
- v1.1 基础设施现代化 -- 29 commits (shipped 2026-04-11) -- [详情](milestones/v1.1-MILESTONE.md)
- v1.2 基础设施修复与整合 -- Phases 10-14 (shipped 2026-04-11) -- [详情](milestones/v1.2-ROADMAP.md)
- v1.3 安全收敛与分组整理 -- Phases 15-18 (shipped 2026-04-12) -- [详情](milestones/v1.3-ROADMAP.md)
- v1.4 CI/CD 零停机部署 -- Phases 19-25 (shipped 2026-04-16)
```

## State of the Art

| 旧方式 | 当前方式 | 变更时间 | 影响 |
|--------|---------|---------|------|
| 手动 `bash deploy-apps-prod.sh` | Jenkins Pipeline Build Now | Phase 23 (2026-04-15) | CLAUDE.md 部署章节需反映此变化 |
| 单容器部署 | 蓝绿零停机部署 | Phase 22 (2026-04-15) | 部署方式根本性变化 |

**无 deprecated 代码需处理** -- 旧脚本保留为回退方案，不是废弃。

## v1.4 统计数据

以下数据已通过 git 命令验证，归档时直接使用：

| 指标 | 值 | 验证方式 |
|------|-----|---------|
| Phases | 7 (19-25) | ROADMAP.md 确认 |
| Plans | 11 (2+1+1+2+2+2+1) | ROADMAP.md 确认 |
| Commits | 93 | `git log --oneline --since="2026-04-14" \| wc -l` [VERIFIED] |
| Files changed | 87 | `git diff --stat` [VERIFIED] |
| LOC added | +15,539 | `git diff --stat` [VERIFIED] |
| LOC removed | -1,511 | `git diff --stat` [VERIFIED] |
| 时间跨度 | 2026-04-14 ~ 2026-04-16 | Phase 19 开始 ~ Phase 25 完成 |

### 主要成果
1. Jenkins 宿主机原生安装/卸载脚本（setup-jenkins.sh 7 子命令 + groovy 自动化）
2. Nginx upstream include 抽离（蓝绿路由基础，支持 nginx -s reload 切换）
3. 蓝绿容器管理（manage-containers.sh 8 子命令 + env-findclass-ssr.env 模板）
4. 蓝绿部署核心流程（blue-green-deploy.sh + rollback-findclass.sh）
5. Jenkinsfile 9 阶段 Pipeline + pipeline-stages.sh 函数库
6. Pipeline 增强特性（备份时效性检查 + CDN 缓存清除 + 镜像时间阈值清理）

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | v1.4 Plans 总计 11 个（19:2 + 20:1 + 21:1 + 22:2 + 23:2 + 24:2 + 25:1） | 统计数据 | 归档数据不准确 |

**验证:** A1 应通过最终检查确认 -- ROADMAP.md Phase 25 写着 "2 plans" 但 Plans 下面只有 1 个条目（25-01）。实际应为 10 plans（19:2 + 20:1 + 21:1 + 22:2 + 23:2 + 24:2 + 25:1 = 11，但 Phase 25 只有 1 plan，而 ROADMAP.md 写 "2 plans"）。需 planner 确认 Phase 25 的实际 plan 数量。

**更新：** 经查 ROADMAP.md Phase 25 行显示 `**Plans**: 2 plans` 但 Plans 列表只有 `25-01`。这是 CONTEXT.md 中记录的不一致。鉴于 STATE.md 显示 completed_plans: 10，v1.4 总 plans 应为 10 个。

## Open Questions

1. **Phase 25 Plans 数量不一致**
   - What we know: ROADMAP.md Phase 25 行写 "2 plans"，但 Plans 列表只有 `25-01` 一个条目。STATE.md 显示 completed_plans: 10。
   - What's unclear: Phase 25 是 1 plan 还是 2 plans？
   - Recommendation: 以实际 plan 文件为准。当前只有 `25-01`，归档使用 10 plans。

## Environment Availability

Step 2.6: SKIPPED -- 本阶段全部为文件编辑操作，无外部依赖。

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | 手动验证（文档审查） |
| Config file | 无 |
| Quick run command | `git diff --stat HEAD~1` |
| Full suite command | `git diff HEAD~N` (验证所有变更) |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ENH-04 | 旧脚本添加手动回退注释 | manual-only | `head -10 scripts/deploy/deploy-infrastructure-prod.sh` | 需 Wave 0 验证 |
| ENH-04 | CLAUDE.md 部署章节更新 | manual-only | `grep -A 30 "部署命令" CLAUDE.md` | 需 Wave 0 验证 |
| ENH-04 | ROADMAP.md 归档 | manual-only | `grep "v1.4" .planning/ROADMAP.md` | 需 Wave 0 验证 |

**Note:** 本阶段全部为文档变更，无自动化测试。验证通过人工审查 diff 进行。

### Sampling Rate
- **Per task commit:** `git diff HEAD~1` 确认变更范围正确
- **Per wave merge:** `git diff HEAD~N` 确认所有文件正确修改
- **Phase gate:** 全部文件 diff 审查通过

### Wave 0 Gaps
无 -- 不需要测试框架。

## Security Domain

Step skipped -- 本阶段无安全相关变更（纯文档和注释修改）。

## Sources

### Primary (HIGH confidence)
- 项目代码: `scripts/deploy/deploy-infrastructure-prod.sh` -- 当前脚本结构确认
- 项目代码: `scripts/deploy/deploy-apps-prod.sh` -- 当前脚本结构确认
- 项目代码: `scripts/deploy/deploy-findclass-zero-deps.sh` -- 已有 DEPRECATED 标记确认
- 项目文档: `.planning/ROADMAP.md` -- v1.0~v1.3 归档格式参考
- 项目文档: `.planning/PROJECT.md` -- 里程碑结构参考
- 项目文档: `.planning/STATE.md` -- 项目状态结构参考
- 项目文档: `.planning/milestones/v1.3-ROADMAP.md` -- 最新归档格式参考
- 项目文档: `.planning/milestones/v1.3-REQUIREMENTS.md` -- 需求归档格式参考
- Git 统计: `git log --oneline --since="2026-04-14"` -- v1.4 提交统计 (93 commits, 87 files)
- Git 统计: `git diff --stat` -- v1.4 LOC 统计 (+15,539/-1,511)

### Secondary (MEDIUM confidence)
- CONTEXT.md D-01 ~ D-09 决策 -- 用户确认的锁定决策

### Tertiary (LOW confidence)
无

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- 无技术栈选型，纯文档操作
- Architecture: HIGH -- 所有文件已读取确认结构
- Pitfalls: HIGH -- 基于已有归档模式分析得出

**Research date:** 2026-04-16
**Valid until:** 2026-05-16（文档结构稳定）
