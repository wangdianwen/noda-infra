# Phase 29: 统一基础设施 Jenkins Pipeline - Context

**Gathered:** 2026-04-17
**Status:** Ready for planning (auto mode)

<domain>
## Phase Boundary

创建统一 Jenkins Pipeline (Jenkinsfile.infra)，通过参数化选择目标基础设施服务（keycloak/nginx/noda-ops/postgres），自动执行备份、部署、健康检查和回滚。复用现有 pipeline-stages.sh 函数库和各服务部署脚本，不重写已有的 Keycloak 蓝绿逻辑。

范围包括：
- 创建 Jenkinsfile.infra 统一基础设施 Pipeline（Jenkins choice 参数选择服务）
- pipeline-stages.sh 新增基础设施服务专用部署/健康检查/回滚函数
- 集成 pg_dump 自动备份（postgres 和 keycloak 部署前）
- 服务专属健康检查和回滚策略
- 高风险操作（postgres restart）人工确认门禁
- deploy-infrastructure-prod.sh 同步更新（移除已被 Pipeline 覆盖的服务）

范围不包括：
- findclass-ssr Pipeline 变更（已有独立 Jenkinsfile）
- noda-site Pipeline 变更（已有独立 Jenkinsfile.noda-site）
- Keycloak 蓝绿部署逻辑重写（复用 keycloak-blue-green-deploy.sh）
- Postgres 蓝绿部署（保持 compose 停启模式）
- Jenkins 安装/配置变更
- Keycloak 配置变更（realm/client/IdP 不动）

</domain>

<decisions>
## Implementation Decisions

### Pipeline 结构
- **D-01:** 创建单一 Jenkinsfile.infra，使用 Jenkins `parameters { choice }` 选择目标服务
  - 服务列表：keycloak, nginx, noda-ops, postgres
  - 统一 Pipeline 阶段：Pre-flight → Backup → Deploy → Health Check → Verify → Cleanup
  - Backup 阶段仅对 keycloak/postgres 执行（nginx/noda-ops 无持久化数据）
  - Deploy/Health Check/Verify 阶段根据 SERVICE 参数调用不同函数
  - 保留 Jenkinsfile.keycloak 文件（不删除，作为独立 Keycloak Pipeline 参考），新建统一 Pipeline

### Keycloak 集成
- **D-02:** Jenkinsfile.infra 的 Keycloak 部署复用现有脚本
  - pipeline_deploy_keycloak() 封装调用 keycloak-blue-green-deploy.sh
  - 不重新实现蓝绿逻辑，避免代码重复
  - 健康检查和回滚由 keycloak-blue-green-deploy.sh 内部处理
  - env-keycloak.env 和 manage-containers.sh 无需修改

### Nginx 部署策略
- **D-03:** Nginx 使用 docker compose recreate 模式
  - 步骤：保存当前镜像标签 → docker compose up -d --force-recreate nginx → 等待 running → nginx -t 验证
  - 秒级中断（容器重启约 2-5 秒），非零停机（nginx 无法蓝绿代理自身）
  - 回滚：使用保存的镜像标签重新 docker compose up
  - 健康检查：docker exec nginx nginx -t + curl -sf http://localhost/

### noda-ops 部署策略
- **D-04:** noda-ops 使用 docker compose recreate 模式
  - 步骤：保存当前镜像标签 → docker compose up -d --force-recreate noda-ops → docker ps 验证
  - 回滚：使用保存的镜像标签重新创建
  - 健康检查：docker ps --filter name=noda-ops --filter status=running（容器 running 即可，无 HTTP 端点）

### Postgres 部署策略
- **D-05:** Postgres 使用 compose restart + 备份恢复模式
  - 步骤：pg_dump 全量备份 → 人工确认 → docker compose restart postgres → pg_isready 验证
  - pg_dump 使用容器内命令：docker exec postgres pg_dump
  - 备份失败则中止整个 Pipeline（不执行 restart）
  - 回滚：从备份文件 pg_restore（或重新创建旧版本容器）
  - 注意：当前 Jenkins 不依赖 postgres（使用 XML/H2 存储），restart 不会断连 Jenkins

### 自动备份集成
- **D-06:** 部署 postgres/keycloak 前自动执行 pg_dump
  - 新增函数 pipeline_backup_database(service_name)
  - 备份命令：docker exec noda-infra-postgres-prod pg_dump -U postgres {db_name}
  - 备份路径：BACKUP_HOST_DIR/infra-pipeline/{service}/{timestamp}.sql.gz
  - Keycloak 备份 keycloak 数据库，postgres 备份所有数据库（pg_dumpall）
  - 备份验证：检查文件大小 > 1KB
  - nginx/noda-ops 不需要备份（无持久化数据）

### 健康检查
- **D-07:** 每个服务使用专属健康检查函数
  - pipeline_health_postgres()：docker exec postgres pg_isready -h localhost -p 5432
  - pipeline_health_keycloak()：由 keycloak-blue-green-deploy.sh 内部处理（/health/ready）
  - pipeline_health_nginx()：docker exec nginx nginx -t && curl -sf http://localhost/
  - pipeline_health_noda_ops()：docker ps --filter name=noda-ops --filter status=running

### 回滚机制
- **D-08:** 服务专属回滚策略
  - keycloak：切回旧 upstream（keycloak-blue-green-deploy.sh 已有回滚逻辑）
  - postgres：pg_restore 从备份文件恢复
  - nginx：docker compose up 使用保存的旧镜像标签
  - noda-ops：docker compose up 使用保存的旧镜像标签

### 人工确认门禁
- **D-09:** 高风险操作前 Jenkins `input` 步骤
  - Postgres restart 前强制人工确认（显示备份文件路径和大小）
  - 确认超时：30 分钟后自动中止 Pipeline
  - 其他服务（keycloak/nginx/noda-ops）不需要人工确认（蓝绿或快速 recreate）
  - 确认消息包含：服务名、备份状态、预计影响范围

### deploy-infrastructure-prod.sh 同步
- **D-10:** 更新 deploy-infrastructure-prod.sh，移除已被 Pipeline 覆盖的服务
  - 移除 nginx 和 noda-ops 的部署逻辑（改由 Pipeline 管理）
  - 保留 postgres 部署逻辑（作为无 Jenkins 时的手动回退）
  - Keycloak 已在 Phase 28 移除（不需要再改）
  - 脚本保留作为灾难恢复手动入口

### Claude's Discretion
- Jenkinsfile.infra 具体阶段名称和参数定义细节
- 备份文件命名规则（timestamp 格式）
- 回滚超时时间和健康检查重试参数
- 备份文件清理策略
- compose 文件路径（base + prod overlay）

### Folded Todos
无待办事项可合并。

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 需求文档
- `.planning/ROADMAP.md` §Phase 29 — 成功标准和验收条件（PIPELINE-01 至 PIPELINE-07）
- `.planning/REQUIREMENTS.md` §基础设施 Pipeline — PIPELINE-01 至 PIPELINE-07

### 前序 Phase 决策
- `.planning/phases/22-blue-green-deploy/22-CONTEXT.md` — 蓝绿部署核心流程决策
- `.planning/phases/23-pipeline/23-CONTEXT.md` — Jenkinsfile 九阶段 Pipeline 决策
- `.planning/phases/24-pipeline-enhancements/24-CONTEXT.md` — Pipeline 增强特性（备份检查、CDN 清除）
- `.planning/phases/28-keycloak/28-CONTEXT.md` — Keycloak 蓝绿部署决策（复用框架、env 模板、健康检查）

### 现有代码参考
- `jenkins/Jenkinsfile` — findclass-ssr 蓝绿 Pipeline（9 阶段结构参考）
- `jenkins/Jenkinsfile.keycloak` — Keycloak 蓝绿 Pipeline（7 阶段，官方镜像模式参考）
- `jenkins/Jenkinsfile.noda-site` — noda-site 蓝绿 Pipeline（无 Test 阶段模式参考）
- `scripts/pipeline-stages.sh` — Pipeline 阶段函数库（核心复用对象）
- `scripts/keycloak-blue-green-deploy.sh` — Keycloak 蓝绿部署脚本（Keycloak 部署复用）
- `scripts/manage-containers.sh` — 蓝绿容器管理脚本（参数化模式参考）
- `scripts/deploy/deploy-infrastructure-prod.sh` — 基础设施部署脚本（当前手动部署参考）
- `scripts/lib/backup.sh` — 备份函数库（备份逻辑参考）
- `docker/docker-compose.yml` — 基础服务定义（postgres, nginx, noda-ops）
- `docker/docker-compose.prod.yml` — 生产 overlay（安全配置参考）

### 项目文档
- `.planning/PROJECT.md` — v1.5 目标、架构、Out of Scope
- `.planning/STATE.md` — 当前进度和 Blockers/Concerns

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/pipeline-stages.sh` — 核心函数库，已有 pipeline_preflight/build/deploy/health_check/switch/verify/cleanup 函数
- `scripts/keycloak-blue-green-deploy.sh` — 完整 Keycloak 蓝绿部署流程，可直接调用
- `scripts/manage-containers.sh` — 参数化容器管理，已支持 SERVICE_NAME 环境变量
- `scripts/lib/backup.sh` — 备份函数库，已有 backup_database/verify_backup 函数
- `scripts/deploy/deploy-infrastructure-prod.sh` — 已有 postgres/nginx/noda-ops compose 部署流程

### Established Patterns
- Jenkins Declarative Pipeline（environment 块 + stages 块 + post 块）
- pipeline-stages.sh 函数通过 `source` 加载，sh 步骤调用
- Jenkins `parameters { choice }` 用于服务选择（可参考 multi-service pattern）
- 人工确认通过 Jenkins `input` 步骤实现
- 备份路径：BACKUP_HOST_DIR（/opt/noda/backups）
- compose 文件：docker/docker-compose.yml + docker/docker-compose.prod.yml 双文件 overlay

### Integration Points
- Pipeline 以 jenkins 用户执行 docker 命令（docker 组权限）
- postgres 容器名：noda-infra-postgres-prod（compose 管理）
- nginx 容器名：noda-infra-nginx（compose 管理）
- noda-ops 容器名：noda-ops（compose 管理）
- pg_dump 执行方式：docker exec postgres pg_dump（容器内执行）

### 风险评估
- **中风险：** Postgres restart 影响依赖服务 — keycloak 和 findclass-ssr 会短暂断连数据库，重启后自动恢复
- **低风险：** nginx recreate 秒级中断 — 外部请求短暂失败，Cloudflare 会重试
- **低风险：** noda-ops recreate — 仅影响备份调度和 Cloudflare Tunnel，无外部请求
- **已解决：** Jenkins 不依赖 postgres（XML 存储），restart 不会断连 Pipeline
- **需验证：** docker compose restart postgres 是否比 stop+start 更平滑（连接池保持）

</code_context>

<specifics>
## Specific Ideas

- Jenkinsfile.infra 使用 `when` 指令条件化各阶段（根据 SERVICE 参数）
- 备份函数复用 scripts/lib/backup.sh 中已有的 backup_database 逻辑
- deploy-infrastructure-prod.sh 精简后仅处理 postgres（其他服务由 Pipeline 管理）
- Pipeline 失败时保存失败日志到 deploy-failure-{service}-{timestamp}.log
- compose recreate 使用 --no-deps 避免影响依赖服务
- pg_dump 备份使用 --clean --if-exists 选项，便于 pg_restore 回滚

</specifics>

<deferred>
## Deferred Ideas

- **Postgres 蓝绿部署** — 需要双 PG 实例 + 数据复制，超出当前范围
- **Keycloak 版本升级** — schema 迁移不兼容，不能蓝绿
- **自动触发 Pipeline** — 保持手动触发，与安全要求一致
- **Pipeline 并发控制** — infra-deploy 与 findclass-deploy 互斥（共用 docker/compose）
- **邮件通知** — 部署结果通知（后续迭代）
- **部署历史记录** — 部署审计日志（后续迭代）

---
*Phase: 29-jenkins-pipeline*
*Context gathered: 2026-04-17 (auto mode)*
