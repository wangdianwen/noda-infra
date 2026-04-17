# Phase 32: sudoers 白名单 + Break-Glass 紧急机制 - Context

**Gathered:** 2026-04-18
**Status:** Ready for planning

<domain>
## Phase Boundary

权限锁定后（Phase 31 Docker socket 属组收敛已完成），管理员仍可通过受控 sudoers 白名单进行只读 docker 调试，通过 Break-Glass 脚本在 Jenkins 不可用时执行紧急部署。所有操作留有审计痕迹。

**In scope:**
- sudoers 白名单规则：允许只读 docker 命令（ps、logs、inspect、stats、top）
- sudoers 黑名单规则：拒绝写入 docker 命令（run、rm、compose up/down、exec）
- Break-Glass 紧急部署脚本：Jenkins 不可用时验证身份后执行部署
- Jenkins 可用性检查机制
- Break-Glass 操作审计日志记录

**Out of scope:**
- auditd 内核审计系统（Phase 33）
- Jenkins Audit Trail 插件（Phase 33）
- sudo 操作日志配置（Phase 33）
- setup-docker-permissions.sh 统一脚本（Phase 34）
- Jenkins 权限矩阵（Phase 34）

</domain>

<decisions>
## Implementation Decisions

### Break-Glass 验证方式
- **D-01:** 复用 sudo 密码验证（PAM 认证），不创建独立密码文件
- 管理员执行 `break-glass.sh` 时需输入自己的 sudo 密码
- sudoers 已记录操作日志（配合 Phase 33 审计系统）
- 零额外配置，复用现有系统认证机制

### Jenkins 可用性判断
- **D-02:** 通过 HTTP 健康检查判断 Jenkins 是否可用
- curl Jenkins API 端点（如 `/login` 或 `/api/json`），超时（如 10s）或非 200 响应即视为不可用
- 能检测进程存在但服务异常的情况（OOM、线程死锁等）
- Break-Glass 脚本在 Jenkins 可用（HTTP 200）时拒绝执行

### Break-Glass 操作范围
- **D-03:** Break-Glass 脚本仅允许调用已锁定的部署脚本
- 具体范围：`deploy-apps-prod.sh` 和 `deploy-infrastructure-prod.sh`
- 不允许执行任意 docker 命令或打开交互式 shell
- 部署脚本内部包含回滚逻辑，紧急回滚也可通过部署脚本实现

### docker exec 归类
- **D-04:** docker exec 归类为写入命令，sudoers 白名单中严格禁止
- 管理员需要 docker exec 调试时：
  - 只读调试：使用 sudoers 白名单的 `docker logs`、`docker inspect`、`docker stats`
  - 需要进入容器：使用 `sudo -u jenkins` 切换到 jenkins 用户执行
  - 紧急部署：使用 Break-Glass 机制

### sudoers 白名单规则
- **D-05:** 白名单覆盖 BREAK-01 要求的只读命令：docker ps、docker logs、docker inspect、docker stats、docker top
- 黑名单覆盖 BREAK-02 要求的写入命令：docker run、docker rm、docker compose up/down、docker exec
- 管理员通过 `sudo docker <只读命令>` 执行调试

### Claude's Discretion
- sudoers 规则具体实现方式（Cmnd_Alias vs 封装脚本）
- Break-Glass 脚本的具体名称和存放位置
- HTTP 健康检查的具体端点和超时时间
- 审计日志的存储路径和格式（Phase 33 统一之前）
- Break-Glass 脚本的参数设计

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 项目级规划
- `.planning/ROADMAP.md` — Phase 32 目标、依赖关系、成功标准
- `.planning/REQUIREMENTS.md` — BREAK-01 至 BREAK-04 详细需求
- `.planning/PROJECT.md` — 已锁定决策（Break-Glass 必须在权限收敛前就绪）
- `.planning/phases/31-docker-socket/31-CONTEXT.md` — Phase 31 上下文（权限收敛决策）

### 现有实现
- `scripts/setup-jenkins.sh` — Jenkins 用户配置脚本（第 8 步 socket 属组方式）
- `scripts/undo-permissions.sh` — Phase 31 权限回滚脚本
- `scripts/apply-file-permissions.sh` — Phase 31 文件权限应用脚本
- `scripts/deploy/deploy-apps-prod.sh` — 应用部署脚本（Break-Glass 调用目标）
- `scripts/deploy/deploy-infrastructure-prod.sh` — 基础设施部署脚本（Break-Glass 调用目标）
- `scripts/pipeline-stages.sh` — Jenkins Pipeline 函数库
- `scripts/manage-containers.sh` — 蓝绿容器管理（docker run/exec/stop/rm）

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/setup-jenkins.sh` — 已有用户配置和 systemd override 模式，可复用相同模式安装 sudoers 规则
- `scripts/undo-permissions.sh` — backup_current_state/undo_permissions 模式可复用为 Break-Glass 的状态管理
- `scripts/lib/health.sh` — wait_container_healthy 函数模式可参考实现 Jenkins HTTP 检查

### Established Patterns
- sudoers 文件放置在 `/etc/sudoers.d/` 目录（标准 Linux 模式）
- 脚本以 root:jenkins 750 权限锁定（Phase 31 已建立的模式）
- systemd override 目录模式（Phase 31 已使用）

### Integration Points
- sudoers 白名单影响 admin 用户的 docker 调试能力
- Break-Glass 脚本调用已锁定的部署脚本（需 root 权限执行 `sudo -u jenkins` 切换用户）
- Phase 33 审计系统将消费 Break-Glass 的操作日志
- Phase 34 setup-docker-permissions.sh 将整合 sudoers 规则安装

</code_context>

<specifics>
## Specific Ideas

- sudoers 白名单只允许 `docker ps/logs/inspect/stats/top` 五个只读子命令
- Break-Glass 脚本先检查 Jenkins 可用性（HTTP 检查），再验证管理员 sudo 密码，最后以 jenkins 用户身份调用部署脚本
- docker exec 明确归类为写入命令，不在白名单中

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 32-sudoers-breakglass*
*Context gathered: 2026-04-18*
