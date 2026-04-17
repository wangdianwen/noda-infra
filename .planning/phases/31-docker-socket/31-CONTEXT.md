# Phase 31: Docker Socket 权限收敛 + 文件权限锁定 - Context

**Gathered:** 2026-04-18
**Status:** Ready for planning

<domain>
## Phase Boundary

将 Docker socket 属组从 `docker` 改为 `jenkins`（或等效方案），使仅 jenkins 用户可通过 socket 执行 docker 命令。同时将部署脚本权限锁定为 `750 root:jenkins`，并通过 systemd override 确保重启后权限持久化。所有 4 个 Jenkins Pipeline 和备份系统必须继续正常工作。

</domain>

<decisions>
## Implementation Decisions

### 备份脚本兼容性
- **D-01:** 恢复/备份验证脚本由 jenkins 用户运行。管理员执行恢复时通过 `sudo -u jenkins bash scripts/backup/restore-postgres.sh` 或 Phase 32 的 Break-Glass 机制
- noda-ops 容器不挂载 Docker socket，备份通过内部网络 pg_dump，不受 socket 权限变更影响
- 宿主机备份脚本（restore.sh, verify.sh, health.sh）大量使用 `docker exec`，需确保 jenkins 用户可执行

### git pull 权限恢复
- **D-02:** 使用 Git post-merge hook 自动恢复部署脚本的 `750 root:jenkins` 权限
- hook 文件由安装脚本创建，不在版本控制中（安全性考虑）
- hook 需要在 `.git/hooks/post-merge` 中调用 `chown root:jenkins` + `chmod 750`

### 脚本锁定范围
- **D-03:** 最小范围锁定，仅需求明确列出的脚本：
  - `scripts/deploy/deploy-apps-prod.sh`
  - `scripts/deploy/deploy-infrastructure-prod.sh`
  - `scripts/pipeline-stages.sh`
  - `scripts/manage-containers.sh`
- 其他脚本（blue-green-deploy.sh, rollback-findclass.sh, keycloak-blue-green-deploy.sh 等）通过上述脚本间接调用
- 锁定权限：`750 root:jenkins`

### 执行安全网
- **D-04:** Phase 31 提供最小 undo 脚本（undo-permissions.sh）
- 执行权限修改前先备份当前状态（socket 属组、文件权限列表）
- 回滚时恢复备份的状态
- Phase 34 将提供完整的 `setup-docker-permissions.sh rollback`

### Claude's Discretion
- Socket 属组具体名称（jenkins 组 vs 新建 docker-jenkins 组）— 研究阶段决定
- systemd override 具体配置参数
- post-merge hook 的具体实现方式
- undo 脚本的备份格式和存储位置

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 项目级规划
- `.planning/ROADMAP.md` — Phase 31 目标、依赖关系、成功标准
- `.planning/REQUIREMENTS.md` — PERM-01 至 PERM-05, JENKINS-01, JENKINS-02 详细需求
- `.planning/PROJECT.md` — 已锁定决策（Socket 属组方案 A、Pipeline 零代码修改）

### 现有实现
- `scripts/setup-jenkins.sh` — 第 8 步当前 `usermod -aG docker jenkins`，需改为 socket 属组方式
- `scripts/pipeline-stages.sh` — Jenkins Pipeline 函数库，source manage-containers.sh
- `scripts/manage-containers.sh` — 蓝绿容器管理，使用 docker run/exec/stop/rm
- `scripts/deploy/deploy-apps-prod.sh` — 应用部署手动回退脚本
- `scripts/deploy/deploy-infrastructure-prod.sh` — 基础设施部署手动回退脚本
- `docker/docker-compose.yml` — noda-ops 不挂载 Docker socket（已验证）
- `jenkins/Jenkinsfile` — findclass-ssr 蓝绿部署 Pipeline
- `jenkins/Jenkinsfile.infra` — 基础设施参数化 Pipeline
- `jenkins/Jenkinsfile.keycloak` — Keycloak 蓝绿部署 Pipeline
- `jenkins/Jenkinsfile.noda-site` — noda-site 蓝绿部署 Pipeline

### 备份系统（需验证兼容性）
- `scripts/backup/lib/restore.sh` — 宿主机 docker exec 恢复操作
- `scripts/backup/lib/verify.sh` — 宿主机 docker exec 验证操作
- `scripts/backup/lib/health.sh` — 宿主机 docker exec 健康检查
- `scripts/backup/verify-restore.sh` — 宿主机 docker exec 验证恢复

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/setup-jenkins.sh` — 已有 systemd override 模式（端口配置），可复用相同模式为 Docker 服务创建 override
- `scripts/lib/health.sh` — 健康检查函数，Pipeline 依赖

### Established Patterns
- systemd override 目录：`/etc/systemd/system/jenkins.service.d/override.conf` — 同样模式可用于 `/etc/systemd/system/docker.service.d/override.conf`
- Jenkins 用户配置：setup-jenkins.sh 中的 `usermod -aG` 模式
- 蓝绿部署：通过 `pipeline-stages.sh` → `manage-containers.sh` 调用链执行

### Integration Points
- Docker socket: `/var/run/docker.sock` — 当前属组 `docker`，需改为 jenkins 可访问的组
- Jenkins Pipeline 通过 `sh` 步骤执行 bash 命令 → 最终调用 docker CLI → 通过 socket 与 Docker daemon 通信
- 部署脚本通过 `source` 引用 `pipeline-stages.sh` 和 `manage-containers.sh`

</code_context>

<specifics>
## Specific Ideas

- setup-jenkins.sh 第 8 步需要从 `usermod -aG docker jenkins` 改为 socket 属组方式
- 需要在生产服务器执行前收集状态快照（STATE.md 提到："Phase 31 执行前需在生产服务器运行状态快照命令"）
- 最小 undo 脚本应在任何权限修改前运行，备份：socket 属组、脚本权限列表

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 31-docker-socket*
*Context gathered: 2026-04-18*
