---
phase: 29-jenkins-pipeline
verified: 2026-04-17T22:15:00Z
status: gaps_found
score: 9/13 must-haves verified
overrides_applied: 0
gaps:
  - truth: "pipeline-stages.sh 包含回滚函数，每个服务使用独立回滚策略"
    status: partial
    reason: "Keycloak 回滚函数计算了 inactive_env 但实际调用 update_upstream '$active_env'（当前活跃环境），导致回滚操作是 no-op，未切回旧容器。变量 inactive_env 被计算但从未使用。"
    artifacts:
      - path: "scripts/pipeline-stages.sh"
        issue: "第 906-910 行计算 inactive_env，第 911 行却使用 active_env 调用 update_upstream"
    missing:
      - "第 911 行 update_upstream 调用应使用 inactive_env 而非 active_env"
      - "第 914 行 set_active_env 应使用 inactive_env"
      - "第 915 行日志消息应反映正确的回滚目标环境"
  - truth: "Jenkins 中存在 infra-deploy Pipeline 任务，可通过下拉菜单选择 keycloak/nginx/noda-ops/postgres 服务"
    status: partial
    reason: "Jenkinsfile.infra 文件已创建且结构完整，但需要在 Jenkins 服务器上注册为 Pipeline 任务才能验证存在性。这需要人工在 Jenkins UI 中创建任务。"
    artifacts:
      - path: "jenkins/Jenkinsfile.infra"
        issue: "文件存在（132 行），但 Jenkins 任务注册需要人工操作"
    missing:
      - "Jenkins 服务器上注册 infra-deploy Pipeline 任务"
  - truth: "健康检查失败时自动回滚到部署前状态（Keycloak 切回旧容器、nginx/noda-ops 恢复旧镜像）"
    status: partial
    reason: "回滚函数对 nginx/noda-ops/postgres 策略正确（compose overlay + pg_restore），但 Keycloak 回滚因 active_env/inactive_env 变量混用导致回滚实际无效"
    artifacts:
      - path: "scripts/pipeline-stages.sh"
        issue: "pipeline_infra_rollback keycloak 分支使用错误的环境变量"
    missing:
      - "修复 keycloak 回滚中的环境变量引用"
  - truth: "pipeline-stages.sh 包含 4 个服务的健康检查函数，覆盖 pg_isready / HTTP / nginx -t / docker ps"
    status: partial
    reason: "keycloak 健康检查使用 wait_container_healthy 而非 HTTP /health/ready 直接检查。虽然蓝绿脚本内部已做 HTTP 健康检查（http_health_check），pipeline 层的二次验证仅检查容器状态（Docker health），未显式调用 HTTP 端点。这是设计选择（二次验证定位为容器级检查），与 ROADMAP SC 描述 'keycloak: HTTP /health/ready' 存在偏差。"
    artifacts:
      - path: "scripts/pipeline-stages.sh"
        issue: "pipeline_infra_health_check keycloak 分支使用 wait_container_healthy 而非 HTTP 检查"
    missing:
      - "无（设计选择，非功能缺失。实际 HTTP 检查由 keycloak-blue-green-deploy.sh 内部完成）"
human_verification:
  - test: "在 Jenkins UI 中创建 infra-deploy Pipeline 任务，关联 jenkins/Jenkinsfile.infra"
    expected: "任务创建成功，Build with Parameters 显示 SERVICE 下拉菜单包含 keycloak/nginx/noda-ops/postgres"
    why_human: "需要运行中的 Jenkins 服务器和 UI 操作，无法通过代码验证"
  - test: "触发 keycloak 部署并观察 Pipeline 执行"
    expected: "7 阶段顺序执行：Pre-flight -> Backup -> Deploy -> Health Check -> Verify -> Cleanup，Human Approval 阶段跳过"
    why_human: "需要运行中的 Jenkins 服务器 + Docker 环境"
  - test: "触发 postgres 部署并观察 Human Approval 门禁"
    expected: "Backup 阶段执行 pg_dumpall，然后 Pipeline 暂停等待人工确认，30 分钟超时"
    why_human: "需要运行中的 Jenkins 服务器 + Docker 环境"
  - test: "部署失败时观察自动回滚行为"
    expected: "post failure 触发 pipeline_infra_failure_cleanup，日志归档到 deploy-failure-*.log"
    why_human: "需要运行中的 Jenkins 服务器 + 触发失败场景"
---

# Phase 29: 统一基础设施 Jenkins Pipeline 验证报告

**Phase Goal:** 管理员可在 Jenkins 中选择目标基础设施服务（keycloak/nginx/noda-ops/postgres），Pipeline 自动执行备份、部署、健康检查和回滚
**Verified:** 2026-04-17T22:15:00Z
**Status:** gaps_found
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

**Roadmap Success Criteria (6 truths):**

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC-1 | Jenkins 中存在 infra-deploy Pipeline 任务，可通过下拉菜单选择服务 | PARTIAL | Jenkinsfile.infra 存在（132 行），包含 `choice(name:'SERVICE', choices:['keycloak','nginx','noda-ops','postgres'])`。但 Jenkins 任务注册需要人工操作 |
| SC-2 | Pipeline 部署 keycloak 前自动执行 pg_dump 全量备份，备份失败则中止部署 | VERIFIED | `pipeline_backup_database()` (line 696): keycloak 走 `pg_dump -U postgres --clean --if-exists keycloak` 分支 (line 714)，文件大小 <1KB 时 `return 1` 中止 (line 724-726)。Backup 阶段 `when` 条件 `params.SERVICE == 'keycloak'` (line 48) |
| SC-3 | 每个服务使用匹配的部署策略 | VERIFIED | `pipeline_deploy_keycloak()` 调用 keycloak-blue-green-deploy.sh (line 787)；`pipeline_deploy_nginx()` 使用 `up -d --force-recreate` (line 807)；`pipeline_deploy_noda_ops()` 使用 `up -d --build --force-recreate` (line 829)；`pipeline_deploy_postgres()` 使用 `restart postgres` (line 844) |
| SC-4 | 部署后自动执行服务专属健康检查 | VERIFIED | `pipeline_infra_health_check()` (line 855): postgres=`pg_isready` (line 877), nginx=`nginx -t` (line 868), noda-ops=`wait_container_healthy` (line 873), keycloak=二次 `wait_container_healthy` (line 864) |
| SC-5 | 健康检查失败时自动回滚到部署前状态 | PARTIAL | nginx/noda-ops 回滚使用 INFRA_ROLLBACK_IMAGE compose overlay (lines 917-955) -- 正确。postgres 回滚使用 INFRA_BACKUP_FILE pg_restore (lines 957-970) -- 正确。keycloak 回滚使用 `update_upstream "$active_env"` (line 911) -- 变量错误，实际为 no-op |
| SC-6 | 重启 PostgreSQL 等高风险操作前 Pipeline 暂停等待人工确认（30 分钟超时） | VERIFIED | Human Approval 阶段 `when { expression { params.SERVICE == 'postgres' } }` (line 63)，`timeout(time: 30, unit: 'MINUTES')` (line 66)，`input message: '确认重启 PostgreSQL?'` (line 67) |

**Plan-specific truths (7 additional):**

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| P1-1 | pipeline-stages.sh 包含 pipeline_backup_database，keycloak=pg_dump, postgres=pg_dumpall | VERIFIED | Lines 714 (pg_dump keycloak) + 717 (pg_dumpall postgres)，文件大小验证 line 723-727 |
| P1-2 | pipeline-stages.sh 包含 4 个服务部署函数 | VERIFIED | `pipeline_deploy_keycloak()` (line 769), `pipeline_deploy_nginx()` (line 796), `pipeline_deploy_noda_ops()` (line 818), `pipeline_deploy_postgres()` (line 840) |
| P1-3 | 每个服务使用独立部署策略 | VERIFIED | keycloak=蓝绿 (line 787 bash keycloak-blue-green-deploy.sh), nginx=recreate (line 807 --force-recreate), noda-ops=recreate+build (line 829 --build --force-recreate), postgres=restart (line 844 restart) |
| P1-4 | 4 个服务健康检查覆盖 pg_isready/HTTP/nginx -t/docker ps | PARTIAL | keycloak 使用 wait_container_healthy 而非 HTTP 检查。实际 HTTP 检查由蓝绿脚本内部完成，pipeline 层做容器状态二次验证。nginx=nginx -t, postgres=pg_isready, noda-ops=容器 running -- 均正确 |
| P1-5 | pipeline-stages.sh 包含回滚函数，每个服务使用独立回滚策略 | PARTIAL | keycloak 回滚变量引用错误 (见 SC-5)。nginx/noda-ops 使用 compose overlay 回滚 (正确)。postgres 使用 pg_restore (正确) |
| P2-1 | Jenkinsfile.infra 包含 7 阶段 + parameters choice + when 条件化 + input 门禁 | VERIFIED | 7 stages: Pre-flight (line 35), Backup (line 45), Human Approval (line 61), Deploy (line 76), Health Check (line 86), Verify (line 96), Cleanup (line 106)。`parameters { choice ... }` (lines 26-32)。Backup `when` (lines 46-51)。input + timeout (lines 66-74) |
| P3-1 | deploy-infrastructure-prod.sh 精简为仅 postgres，不包含 nginx/noda-ops 部署逻辑 | VERIFIED | `START_SERVICES="postgres"` (line 45)。`EXPECTED_CONTAINERS` 仅含 `noda-infra-postgres-prod` (line 39)。头部注释引用 Jenkinsfile.infra (line 7)。container_to_service 仅映射 postgres (line 88)。步骤精简为 5 步 |

**Score:** 9/13 truths fully verified (6 PARTIAL + 2 needing human Jenkins registration)

### Required Artifacts

| Artifact | Expected | Status | Details |
| -------- | -------- | ------ | ------- |
| `scripts/pipeline-stages.sh` | 基础设施 Pipeline 函数库 (12 个函数) | VERIFIED | 1097 行，包含 12 个 pipeline_infra_* 函数 (7) + pipeline_backup_database + 4 个 pipeline_deploy_* 函数。bash -n 语法通过 |
| `jenkins/Jenkinsfile.infra` | 统一基础设施部署 Pipeline | VERIFIED | 132 行，Declarative Pipeline，7 阶段，choice 参数 4 服务，when 条件化，input 门禁，post failure |
| `scripts/deploy/deploy-infrastructure-prod.sh` | 精简后的手动部署回退脚本 | VERIFIED | 324 行，仅部署 postgres，头部注释引用 Jenkinsfile.infra，nginx/noda-ops 从 EXPECTED_CONTAINERS/START_SERVICES 移除。bash -n 语法通过 |

### Key Link Verification

| From | To | Via | Status | Details |
| ---- | -- | --- | ------ | ------- |
| jenkins/Jenkinsfile.infra | scripts/pipeline-stages.sh | `source scripts/pipeline-stages.sh` | WIRED | 7 处 source 调用 (lines 39,55,80,90,100,110,122)，每个 sh 步骤加载后调用 pipeline_infra_* 函数 |
| pipeline-stages.sh | keycloak-blue-green-deploy.sh | `bash "$PROJECT_ROOT/scripts/keycloak-blue-green-deploy.sh"` | WIRED | line 787，pipeline_deploy_keycloak 设置环境变量后调用 |
| pipeline-stages.sh | scripts/lib/health.sh | `source` (间接通过 manage-containers.sh) | WIRED | manage-containers.sh line 16 source health.sh。wait_container_healthy 在 pipeline_infra_health_check 中调用 (lines 864,869,873,878) |
| pipeline-stages.sh | scripts/manage-containers.sh | `source "$PROJECT_ROOT/scripts/manage-containers.sh"` | WIRED | line 16，update_upstream/reload_nginx/set_active_env 等函数在回滚/部署中使用 |
| deploy-infrastructure-prod.sh | jenkins/Jenkinsfile.infra | 注释引用 | WIRED | lines 7,40,78,315,316,317 引用 Jenkinsfile.infra |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
| -------- | ------------- | ------ | ------------------ | ------ |
| pipeline_backup_database | INFRA_BACKUP_FILE | pg_dump/pg_dumpall via docker exec | Yes -- 真实数据库查询 | FLOWING |
| pipeline_deploy_nginx | INFRA_ROLLBACK_IMAGE | `docker inspect --format='{{.Image}}'` | Yes -- 读取运行容器实际镜像 | FLOWING |
| pipeline_deploy_noda_ops | INFRA_ROLLBACK_IMAGE | `docker inspect --format='{{.Image}}'` | Yes -- 读取运行容器实际镜像 | FLOWING |
| pipeline_infra_rollback (postgres) | INFRA_BACKUP_FILE | pipeline_backup_database 导出 | Yes -- 通过 gunzip|psql 管道恢复 | FLOWING |
| pipeline_infra_rollback (nginx/noda-ops) | INFRA_ROLLBACK_IMAGE | pipeline_deploy_* 导出 | Yes -- 生成 compose overlay 使用 digest | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
| -------- | ------- | ------ | ------ |
| pipeline-stages.sh 语法检查 | `bash -n scripts/pipeline-stages.sh` | 退出码 0 | PASS |
| deploy-infrastructure-prod.sh 语法检查 | `bash -n scripts/deploy/deploy-infrastructure-prod.sh` | 退出码 0 | PASS |
| pipeline_infra_* 函数存在 (source guard) | `grep -c "^pipeline_infra_" scripts/pipeline-stages.sh` | 7 个函数定义 | PASS |
| Jenkinsfile.infra choice 参数包含 4 服务 | `grep "choices:" jenkins/Jenkinsfile.infra` | `choices: ['keycloak', 'nginx', 'noda-ops', 'postgres']` | PASS |
| deploy-infrastructure-prod.sh 不含 noda-ops 服务 | `grep "START_SERVICES=" scripts/deploy/deploy-infrastructure-prod.sh` | `START_SERVICES="postgres"` | PASS |
| Backup 阶段条件化 | `grep -c "when" jenkins/Jenkinsfile.infra` | 3 处 when 块 (Backup + Human Approval x2) | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
| ----------- | ---------- | ----------- | ------ | -------- |
| PIPELINE-01 | Plan 02 | Jenkinsfile.infra choice 参数选择目标服务 | SATISFIED | jenkins/Jenkinsfile.infra lines 26-32: `choice(name:'SERVICE', choices:['keycloak','nginx','noda-ops','postgres'])` |
| PIPELINE-02 | Plan 01 | pipeline-stages.sh 新增基础设施服务专用部署函数 | SATISFIED | 4 个函数: pipeline_deploy_keycloak/ nginx/noda_ops/postgres (lines 769-847) |
| PIPELINE-03 | Plan 01 | 每个服务使用独立部署策略 | SATISFIED | keycloak=蓝绿 (bash script), nginx=recreate, noda-ops=recreate+build, postgres=restart |
| PIPELINE-04 | Plan 01 | 部署前自动执行 pg_dump，备份失败中止 | SATISFIED | pipeline_backup_database (line 696): pg_dump + pg_dumpall + 文件大小验证 + return 1 |
| PIPELINE-05 | Plan 01 | 部署后自动执行健康检查 | SATISFIED | pipeline_infra_health_check (line 855): 4 种服务专属检查策略 |
| PIPELINE-06 | Plan 01 | 健康检查失败时自动回滚 | PARTIAL | pipeline_infra_rollback 存在。nginx/noda-ops/postgres 回滚正确。keycloak 回滚变量引用错误导致 no-op |
| PIPELINE-07 | Plan 02 | 关键操作前 Jenkins input 步骤 | SATISFIED | Human Approval stage (line 61): `when { params.SERVICE == 'postgres' }` + `timeout(time: 30, unit: 'MINUTES')` + `input message` |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
| ---- | ---- | ------- | -------- | ------ |
| scripts/pipeline-stages.sh | 906-911 | Keycloak rollback 使用 active_env 而非 inactive_env | BLOCKER | keycloak 回滚实际为 no-op，部署失败时无法切回旧容器 |

无 TODO/FIXME/placeholder/空实现/stub 发现。

### Inversion Analysis

3 specific ways this implementation could be wrong despite appearing to work:

1. **Keycloak rollback no-op** (confirmed): `pipeline_infra_rollback` 计算了 `inactive_env` (lines 906-910) 但 `update_upstream` 调用使用 `active_env` (line 911)，导致 keycloak 回滚操作不产生实际效果。变量 `inactive_env` 被赋值但从未引用。

2. **Keycloak health check 二次验证与 Docker health check 耦合**: `wait_container_healthy` 依赖 Docker 内置 health check (`Health.Status`)，而非显式 HTTP 请求。如果 Keycloak 容器的 Docker health check 未配置或配置错误，二次验证可能给出假阳性结果。这由 keycloak-blue-green-deploy.sh 内部的 http_health_check 作为主要检查覆盖。

3. **deploy-infrastructure-prod.sh 保留 noda-ops 容器引用**: 备份函数 `check_recent_backup` (line 141) 和 `run_pre_deploy_backup` (line 189) 仍通过 `docker exec noda-ops` 执行。这是 intentional -- postgres 备份仍通过 noda-ops 容器执行，保留正确。

### Confirmation Bias Counter

1. **部分满足的需求**: PIPELINE-06 的 keycloak 回滚分支存在 bug，变量引用错误。整体回滚机制对 3/4 服务正确，但 keycloak 是最关键的蓝绿部署服务。

2. **通过但不完全正确的测试**: `bash -n` 语法检查通过，但运行时逻辑错误（变量引用）无法通过静态分析发现。

3. **无测试覆盖的错误路径**: Jenkinsfile.infra 的 `post { failure { script { ... } } }` 块中 `pipeline_infra_failure_cleanup` 调用 `pipeline_infra_rollback`，但 keycloak 回滚的错误导致失败清理也不完全有效。

### Human Verification Required

### 1. Jenkins 任务注册

**Test:** 在 Jenkins 服务器 UI 中创建 `infra-deploy` Pipeline 任务，SCM 关联 jenkins/Jenkinsfile.infra
**Expected:** 任务创建成功，"Build with Parameters" 显示 SERVICE 下拉菜单包含 keycloak/nginx/noda-ops/postgres
**Why human:** 需要运行中的 Jenkins 服务器和 UI 操作

### 2. Keycloak 部署 Pipeline 端到端测试

**Test:** 在 Jenkins 中选择 keycloak 服务触发 Pipeline
**Expected:** 7 阶段顺序执行，Backup 阶段执行 pg_dump，Deploy 阶段调用蓝绿脚本，最终部署成功
**Why human:** 需要运行中的 Jenkins + Docker 环境和 keycloak 容器

### 3. PostgreSQL 人工确认门禁测试

**Test:** 在 Jenkins 中选择 postgres 服务触发 Pipeline
**Expected:** Backup 阶段执行 pg_dumpall，然后 Pipeline 暂停显示确认对话框，包含 30 分钟超时
**Why human:** 需要运行中的 Jenkins 服务器 + 数据库容器

### 4. 部署失败自动回滚验证

**Test:** 制造部署失败场景（如使用无效镜像），观察 post failure 块执行
**Expected:** pipeline_infra_failure_cleanup 执行，deploy-failure-*.log 归档，自动回滚触发
**Why human:** 需要运行中的环境 + 触发失败场景

### Gaps Summary

发现 1 个阻塞性 bug 和 1 个需要人工完成的配置任务：

**BLOCKER -- Keycloak 回滚变量引用错误：**
`pipeline_infra_rollback()` 函数的 keycloak 分支（scripts/pipeline-stages.sh lines 901-916）计算了 `inactive_env` 变量（应该回滚到的旧环境），但在 `update_upstream`、`set_active_env` 和日志消息中均使用了 `active_env`（当前已切换的新环境）。结果是 keycloak 回滚操作实质上是 no-op -- 它"切换"到了已经是活跃状态的环境。

修复方案：
- Line 911: `update_upstream "$active_env"` -> `update_upstream "$inactive_env"`
- Line 914: `set_active_env "$active_env"` -> `set_active_env "$inactive_env"`
- Line 915: 日志消息更新为反映 `inactive_env`

**INFO -- Keycloak 健康检查策略偏差：**
ROADMAP SC-4 描述 keycloak 健康检查为 "HTTP /health/ready"，但 `pipeline_infra_health_check` 使用 `wait_container_healthy`（Docker 容器状态检查）而非显式 HTTP 请求。这不是功能缺陷 -- 实际 HTTP 检查由 keycloak-blue-green-deploy.sh 内部的 `http_health_check` 函数完成（该函数直接 wget /health/ready 端点），pipeline 层的二次验证定位为容器级检查。但如需严格匹配 ROADMAP 描述，可在 pipeline_infra_health_check 的 keycloak 分支添加显式 HTTP 检查。

**INFO -- Jenkins 任务注册：**
Jenkinsfile.infra 文件已创建且结构完整，但需要在 Jenkins 服务器上手动注册为 Pipeline 任务才能使 ROADMAP SC-1 完全满足。

---

_Verified: 2026-04-17T22:15:00Z_
_Verifier: Claude (gsd-verifier)_
