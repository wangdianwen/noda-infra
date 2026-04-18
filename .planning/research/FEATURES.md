# 特性模式分析：Shell 脚本重构精简

**领域：** noda-infra Shell 脚本代码库精简
**研究日期：** 2026-04-18
**总体置信度：** HIGH（基于完整代码阅读，非推测）

---

## 基本要求（Table Stakes）

不做就等于没完成重构的特性。每项都对应明确的问题点。

| # | 特性 | 问题现状 | 复杂度 | 预估行数变化 | 优先级 |
|---|------|----------|--------|-------------|--------|
| T-01 | **统一日志库** -- 合并 `scripts/lib/log.sh`(34行) 和 `scripts/backup/lib/log.sh`(88行) 为一个 | 两份重复文件，备份版多 `log_progress`/`log_json`/`log_structured` 三个函数，但四个基础函数完全重复 | Low | -54行（删 backup/log.sh） | P0 |
| T-02 | **提取 http_health_check + e2e_verify 到独立库** | 同一函数在 4 个文件中分别定义：`blue-green-deploy.sh`、`keycloak-blue-green-deploy.sh`、`pipeline-stages.sh`、`rollback-findclass.sh`。每次修改需同步 4 处 | Low | -200行（4份合并为1份） | P0 |
| T-03 | **合并蓝绿部署脚本** -- 将 `blue-green-deploy.sh`(297行) 和 `keycloak-blue-green-deploy.sh`(297行) 参数化合并 | 两个脚本 95% 逻辑相同：前置检查、停旧启新、健康检查、切换流量、E2E 验证、回滚、清理。差异仅在镜像获取方式（构建 vs pull）、健康检查端口/路径、清理策略 | Medium | -250行（合并为一个脚本） | P0 |
| T-04 | **删除一次性验证脚本** -- 清理 `scripts/verify/` 目录下的 5 个脚本 | `quick-verify.sh`、`verify-services.sh`、`verify-findclass.sh`、`verify-infrastructure.sh`、`verify-apps.sh` 全部硬编码旧架构（`noda-postgres`、`localhost:8080`、旧 compose 路径），已不能在生产环境运行 | Low | -130行（删 5 文件） | P0 |
| T-05 | **提取 detect_platform 到共享库** | `detect_platform()` 在 8 个脚本中重复定义，逻辑完全相同 | Low | -40行（8份合并为1份 source） | P1 |
| T-06 | **提取 find_cli_jar + jenkins_home 到共享库** | `setup-jenkins.sh` 独占这些工具函数，但 `setup-jenkins-pipeline.sh` 重新实现了 `wait_for_jenkins()` | Low | -30行 | P1 |

### 特性依赖关系

```
T-02（提取 http_health_check/e2e_verify）
  └-- T-03（合并蓝绿部署）依赖 T-02 先完成
       └-- T-03 完成后 rollback-findclass.sh 也应改为 source 共享库

T-01（统一日志库）独立，无依赖
T-04（删除验证脚本）独立，无依赖
T-05（提取 detect_platform）独立，无依赖
T-06（提取 Jenkins 工具函数）独立，无依赖
```

---

## 差异化特性（Differentiators）

做了会让代码库显著更易维护的特性。不是必须，但价值明确。

| # | 特性 | 价值主张 | 复杂度 | 预估收益 | 优先级 |
|---|------|----------|--------|---------|--------|
| D-01 | **pipeline-stages.sh 拆分** -- 将 1108 行拆为应用 Pipeline + 基础设施 Pipeline 两个文件 | 当前文件包含 `pipeline_*`（findclass 用）和 `pipeline_infra_*`（基础设施用）两套完全独立的函数集。合在一起增加了认知负担和 grep 噪声 | Medium | 可维护性显著提升 | P1 |
| D-02 | **setup-jenkins.sh 拆分** -- 将 1029 行拆为核心命令（install/uninstall/upgrade）和辅助命令（reset-password/matrix-auth） | matrix-auth 相关代码（apply + verify）占约 250 行，与核心安装/卸载/重启逻辑正交 | Medium | 每个文件 <600 行 | P2 |
| D-03 | **合并 setup-jenkins-pipeline.sh + prepare-jenkins-pipeline.sh** | 两个脚本功能高度重叠（都做 Jenkins 安装后配置），且 `setup-jenkins-pipeline.sh` 有自己的 `wait_for_jenkins()` 和颜色定义，应该复用 `setup-jenkins.sh` 的函数 | Medium | -200行，消除职责混淆 | P2 |
| D-04 | **安全脚本收敛为单一入口** -- 将 `apply-file-permissions.sh`、`undo-permissions.sh`、`setup-docker-permissions.sh`、`break-glass.sh`、`install-sudoers-whitelist.sh`、`verify-sudoers-whitelist.sh`、`install-auditd-rules.sh`、`install-sudo-log.sh` 合并为一个 `noda-security.sh`（子命令分发模式） | 8 个安全脚本各自独立但有大量重复：`detect_platform()`、颜色定义、`source log.sh`、前置检查模式。统一入口后可共享基础设施 | High | -300行，运维体验大幅提升 | P3 |
| D-05 | **backup/lib/ 命名澄清** -- 将 `scripts/backup/lib/health.sh` 重命名为 `scripts/backup/lib/precheck.sh` 或类似 | 当前 `health.sh` 名字与 `scripts/lib/health.sh` 混淆，实际功能是备份前前置检查（PG 连接 + 磁盘空间），不是容器健康检查 | Low | 消除命名混淆 | P1 |
| D-06 | **nginx/noda-ops 回滚代码去重** -- `pipeline-stages.sh` 中 `pipeline_infra_rollback` 的 nginx 和 noda-ops 分支逻辑完全相同（创建临时 compose overlay + force-recreate） | 可提取为 `rollback_compose_service()` 共享函数 | Low | -20行 | P2 |

---

## 反特性（Anti-Features）

明确不应该做的事情。做了会适得其反。

| # | 反特性 | 原因 | 替代方案 |
|---|--------|------|----------|
| A-01 | **不要合并 backup/lib/ 和 scripts/lib/ 的 health.sh** | 它们职责完全不同：`scripts/lib/health.sh` 是 Docker 容器健康检查轮询，`scripts/backup/lib/health.sh` 是 PostgreSQL 连接 + 磁盘空间检查。强行合并会产生"什么都做但什么都不精"的上帝文件 | D-05：重命名澄清 |
| A-02 | **不要把 backup 子系统合并到主 scripts/ 目录** | `scripts/backup/` 有完整的独立生态（12 个文件、自己的 lib/、自己的 tests/），职责清晰（备份/恢复/验证），与部署脚本正交。合并会破坏关注点分离 | 保持 backup/ 独立，仅合并共享的 log.sh |
| A-03 | **不要把 Groovy 脚本内联到 shell 脚本** | `setup-jenkins.sh` 中的 `cmd_reset_password` 和 `cmd_verify_matrix_auth` 将 Groovy 代码写在 heredoc 里。这是 Jenkins CLI 的标准模式，提取到独立文件会增加文件数量但不会减少复杂度 | 保持现状 |
| A-04 | **不要为了"统一"而引入 shell 框架**（如 bash-framework、shflags 等） | 项目规模（~50 脚本）不值得引入外部依赖。`source` + 函数库 + 子命令分发模式已经足够，引入框架增加学习成本和依赖风险 | 保持 source 模式，做好函数提取 |
| A-05 | **不要在 T-03 合并时使用复杂的配置文件驱动** | 两个蓝绿脚本的差异点（端口、路径、镜像、清理策略）可以用环境变量完美表达（`manage-containers.sh` 已证明），不需要引入 YAML/JSON 配置 | 环境变量参数化 |
| A-06 | **不要删除 rollback-findclass.sh** | 即使 pipeline 有自动回滚，手动回滚脚本作为紧急恢复手段必须保留。但应改为 source 共享库而非复制代码 | 重构为 source 共享函数 |

---

## 代码重复热力图

通过完整代码阅读确认的重复分布：

| 重复模式 | 出现次数 | 总重复行数（估） | 危险程度 |
|----------|---------|----------------|---------|
| `http_health_check()` | 4 处独立定义 | ~200 行 | 高（逻辑差异：有的用 SERVICE_PORT，有的硬编码 3001） |
| `e2e_verify()` | 4 处独立定义 | ~160 行 | 高（同上） |
| `detect_platform()` | 8 处独立定义 | ~48 行 | 中（逻辑完全相同，但分散） |
| `log_info/log_error/log_success/log_warn` | 2 处独立定义 | ~54 行 | 中（backup 版多了 3 个函数） |
| `wait_for_jenkins()` | 2 处独立定义 | ~30 行 | 低 |
| 颜色常量定义 | 3+ 处 | ~30 行 | 低 |
| nginx/noda-ops 回滚逻辑 | 2 处 | ~40 行 | 低（完全相同的临时 compose overlay 模式） |
| 前置检查（Docker + nginx + network） | 6+ 处 | ~80 行 | 中（每个脚本都重复写同样的 3 个检查） |

**关键发现：** `http_health_check` 和 `e2e_verify` 是最危险的重复，因为它们存在微妙差异（有的用 `SERVICE_PORT` 变量，有的硬编码 `3001`），这种"几乎相同但略有不同"的重复最易引发 bug。

---

## 特性复杂度评估

### T-03：合并蓝绿部署脚本（最复杂的基本要求）

**当前状态对比：**

| 维度 | blue-green-deploy.sh | keycloak-blue-green-deploy.sh |
|------|---------------------|------------------------------|
| 镜像获取 | `docker compose build` + `git rev-parse` SHA 标签 | `docker pull` 官方镜像 |
| 健康检查端口 | 硬编码 `3001` | 使用 `${SERVICE_PORT}`（8080） |
| 健康检查路径 | 硬编码 `/api/health` | 使用 `${HEALTH_PATH}`（`/realms/master`） |
| 清理策略 | 保留最近 N 个 SHA 标签 | 清理 dangling images |
| compose 迁移检测 | 无 | 检测 compose 管理的旧容器并迁移 |
| 额外参数 | 无 | `CONTAINER_MEMORY=1g`、`EXTRA_DOCKER_ARGS`、`CONTAINER_READONLY=false` |

**合并策略：** `keycloak-blue-green-deploy.sh` 已经使用 `manage-containers.sh` 的环境变量参数化机制。`blue-green-deploy.sh` 硬编码了 findclass-ssr 参数。合并后统一使用环境变量，差异点全部通过变量控制。

### D-04：安全脚本收敛（最复杂的差异化特性）

**当前 8 个安全脚本清单：**

| 脚本 | 行数 | 子命令数 | 依赖 |
|------|------|---------|------|
| `apply-file-permissions.sh` | 409 | 4（apply/verify/hook/help） | lib/log.sh |
| `undo-permissions.sh` | ~150 | 1 | lib/log.sh |
| `setup-docker-permissions.sh` | 333 | 4（apply/verify/rollback/help） | lib/log.sh |
| `break-glass.sh` | 324 | 2（break/help） | lib/log.sh |
| `install-sudoers-whitelist.sh` | ~120 | 1 | lib/log.sh |
| `verify-sudoers-whitelist.sh` | ~100 | 1 | lib/log.sh |
| `install-auditd-rules.sh` | 310 | 3（install/verify/help） | lib/log.sh |
| `install-sudo-log.sh` | ~150 | 1 | lib/log.sh |

合并后：`noda-security.sh`，约 6-8 个子命令，共享 `detect_platform`、颜色、前置检查。

---

## MVP 建议

**Phase 1（必须完成，解决 80% 的问题）：**

1. T-01：统一日志库（删 backup/lib/log.sh，备份脚本 source scripts/lib/log.sh）
2. T-02：提取 http_health_check + e2e_verify 到 `scripts/lib/deploy-checks.sh`
3. T-03：合并蓝绿部署脚本（参数化 + source 共享库）
4. T-04：删除 verify/ 目录下的一次性脚本
5. T-05：提取 detect_platform 到 `scripts/lib/platform.sh`

**Phase 2（建议完成，提升可维护性）：**

1. D-01：pipeline-stages.sh 拆分
2. D-05：backup/lib/health.sh 重命名
3. D-06：nginx/noda-ops 回滚代码去重

**Phase 3（可选，锦上添花）：**

1. D-02：setup-jenkins.sh 拆分
2. D-03：合并两个 jenkins-pipeline 脚本
3. D-04：安全脚本收敛

**明确推迟：**
- Docker Compose 文件精简（独立领域，与 Shell 脚本重构正交）
- backup 子系统内部重构（独立且稳定，改动风险大于收益）

---

## 特性行数影响预估

| 特性 | 新增行数 | 删除行数 | 净变化 | 风险 |
|------|---------|---------|--------|------|
| T-01 统一日志库 | 3（backup 脚本加 log_progress 等到 scripts/lib/log.sh） | 88（删 backup/lib/log.sh） | -85 | 极低 |
| T-02 提取部署检查库 | ~80（新文件 deploy-checks.sh） | ~360（4 份重复删除） | -280 | 低（需测试 4 个调用方） |
| T-03 合并蓝绿脚本 | ~120（参数化后的统一脚本） | ~594（删两个旧脚本） | -474 | 中（核心部署逻辑，需 E2E 测试） |
| T-04 删除验证脚本 | 0 | ~130 | -130 | 极低 |
| T-05 提取平台检测 | ~15（platform.sh） | ~96（8 处删除，改为 source） | -81 | 极低 |
| T-06 Jenkins 工具函数 | ~30（jenkins-lib.sh） | ~60（两处合并） | -30 | 低 |
| D-01 Pipeline 拆分 | ~20（文件头/source） | 0 | +20 | 低（纯拆分） |
| D-04 安全脚本收敛 | ~60（统一入口 + 共享函数） | ~300（重复删除） | -240 | 高（8 个脚本改动） |
| **合计（Phase 1+2）** | **~240** | **~910** | **~-670** | -- |

---

## 置信度评估

| 区域 | 置信度 | 原因 |
|------|--------|------|
| 重复代码识别 | HIGH | 通过 grep + 完整代码阅读确认，非推测 |
| 合并可行性（T-03） | HIGH | keycloak 脚本已使用 manage-containers.sh 的环境变量参数化模式，findclass 脚本只需对齐 |
| 删除安全性（T-04） | HIGH | verify 脚本硬编码旧架构路径，确认不可用 |
| 安全脚本收敛（D-04） | MEDIUM | 8 个脚本的权限逻辑需要逐个审计，合并后权限边界需验证 |
| 行数预估 | MEDIUM | 基于代码阅读的合理估计，实际可能 +-15% |

---

## 来源

- 完整代码阅读：scripts/ 目录下所有 .sh 文件
- grep 搜索确认重复函数定义位置
- wc -l 统计各文件行数
- 项目历史：v1.3-v1.6 里程碑记录（CLAUDE.md、PROJECT.md）
