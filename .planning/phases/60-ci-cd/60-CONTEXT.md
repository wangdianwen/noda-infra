# Phase 60: CI/CD 改造 - Context

**Gathered:** 2026-05-18
**Status:** Ready for planning

<domain>
## Phase Boundary

将 Jenkins Pipeline 从本地 Docker 命令改为 SSH 远程部署到 r4s。Mac 上 Jenkins 执行构建和镜像打包，通过 SSH 管道传输镜像到 r4s，再通过 SSH 执行远程 docker compose 命令完成部署。保留 Mac 本地部署回退能力。

**范围：**
- pipeline-stages.sh 内部实现改造（添加 remote wrapper 层）
- r4s 上 noda-infra 仓库 git pull 配置
- Jenkins Credentials 添加 SSH 密钥
- Jenkins 环境变量添加 DEPLOY_TARGET 和 R4S_HOST
- r4s flock 文件锁防止并发部署冲突
- 部署前镜像 tag 备份作为回滚点

**不在范围：**
- Jenkinsfile 结构变更（stage 结构保持不变）
- r4s 上安装 Jenkins
- noda-apps 源代码在 r4s 上构建
- 备份 cronjob 迁移（Phase 61）
- Cloudflare Tunnel 切换（Phase 61）

</domain>

<decisions>
## Implementation Decisions

### 改造策略

- **D-01:** 创建 `scripts/lib/remote-ops.sh` 封装层，pipeline-stages.sh 函数内部改为显式分步执行（本地 build → SSH 传输 → SSH 远程部署）。通过 `DEPLOY_TARGET` 环境变量切换本地/远程模式，保留 Mac 本地部署回退能力。
- **D-02:** Jenkinsfile 结构不变，只改 pipeline-stages.sh 内部实现。每个 pipeline_xxx() 函数内部显式区分本地和远程步骤。
- **D-03:** remote-ops.sh 的封装粒度由 Claude 决定（推荐按操作类型封装：build_local、transfer_image、remote_exec）。
- **D-04:** `DEPLOY_TARGET`（local/r4s）和 `R4S_HOST` 配置在 Jenkins 环境变量中。切换回退只需改 `DEPLOY_TARGET=local`。
- **D-05:** SSH 密钥存 Jenkins Credentials，Pipeline 中用 `withCredentials` 加载，`ssh -i` 指定密钥文件。
- **D-06:** 错误处理采用快速失败策略（`set -e`），SSH 连接失败或远程命令失败立即停止 Pipeline。
- **D-07:** findclass-ssr 在 Mac 本地 `docker build`，然后 `docker save | ssh root@r4s 'docker load'` 管道传输。基础设施服务（Keycloak 等）直接在 r4s 上 pull 官方镜像。

### Compose 文件同步

- **D-08:** r4s 上通过 `git pull` 同步 noda-infra 仓库（Deploy Key 只读访问 GitHub）。
- **D-09:** r4s 上仓库路径 `/opt/noda/noda-infra/`，compose 文件在 `docker/` 子目录。
- **D-10:** r4s 固定 git pull main 分支，简单可靠。

### 远程命令封装

- **D-11:** 显式分步执行风格 — 每个函数内部明确标注本地步骤和远程步骤，不做透明代理。代码清晰易调试。
- **D-12:** `docker exec` 操作（如 nginx reload、pg_dump）用嵌套 SSH exec：`ssh root@r4s 'docker exec container cmd'`。
- **D-13:** pre-prod 环境变量在 Mac 上 `envsubst` 替换后，通过管道传输到 r4s：`envsubst < template | ssh root@r4s 'cat > /tmp/env && docker run --env-file /tmp/env ...'`。

### 健康检查与 Nginx reload

- **D-14:** 容器健康检查通过 SSH 远程 `docker inspect`，与当前 `wait_container_healthy()` 逻辑相同，加 SSH 前缀。
- **D-15:** E2E 验证（Verify 阶段）保持从 Mac `curl https://class.noda.co.nz/api/health`，走完整 Cloudflare 全链路。
- **D-16:** Nginx reload 通过 SSH exec：`ssh root@r4s 'docker exec noda-infra-nginx nginx -s reload'`。
- **D-17:** 保持 DNS resolver（`resolver 127.0.0.11`）机制，容器重建后 nginx reload 自动刷新 IP。
- **D-18:** pre-prod 健康检查组合验证：SSH docker inspect + Mac curl pre-prod 域名。

### Pipeline 并发控制

- **D-19:** r4s 上使用 flock 文件锁（`/tmp/noda-deploy.lock`）防止 apps-deploy 和 infra-deploy 同时操作。
- **D-20:** Pre-flight 阶段通过 SSH 获取 flock 锁，Pipeline 结束（含 failure）释放锁。获取锁失败则 Pipeline 失败并提示重试。

### 远程部署回滚

- **D-21:** 部署前在 r4s 上 `docker tag current_image:latest current_image:rollback` 保存当前镜像。失败时用 rollback 标签重新启动。不占用额外内存（只是 tag）。

### 日志与可观测性

- **D-22:** SSH 命令的 stdout/stderr 直接显示在 Jenkins console output 中，不需要额外日志拉取。需要调试时通过 `ssh root@r4s 'docker logs container'` 查看。

### Claude's Discretion

- remote-ops.sh 的具体封装粒度和函数设计
- pipeline-stages.sh 中各函数的具体改造细节
- flock 锁的具体超时参数和清理逻辑
- SSH 连接参数（超时、重连等）
- Jenkins Credentials 的具体 ID 命名
- r4s 上 git pull 的错误处理
- 镜像 tag 备份的命名策略

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Jenkins Pipeline 配置

- `jenkins/Jenkinsfile.apps` — 应用部署 Pipeline（10 阶段，Build One 部署到 pre-prod + prod）
- `jenkins/Jenkinsfile.infra` — 基础设施部署 Pipeline（7 阶段，参数化服务选择）
- `scripts/pipeline-stages.sh` — Pipeline 核心函数库（1130 行，所有 docker 命令在此）

### Docker Compose 配置

- `docker/docker-compose.yml` — 基础服务定义
- `docker/docker-compose.prod.yml` — 生产环境 overlay
- `docker/docker-compose.r4s.yml` — r4s overlay（内存限制、高端口映射）
- `docker/docker-compose.apps-prod.yml` — 应用服务定义（noda-apps monorepo）

### 部署脚本

- `scripts/deploy/deploy-apps-prod.sh` — 旧版手动部署脚本（保留作回退）
- `scripts/deploy/deploy-infrastructure-prod.sh` — 旧版手动部署脚本（保留作回退）
- `scripts/lib/health.sh` — 健康检查函数（wait_container_healthy）
- `scripts/lib/log.sh` — 日志函数

### Nginx 配置

- `config/nginx/conf.d/default.conf` — 反向代理路由
- `config/nginx/snippets/upstream-*.conf` — upstream 定义

### 环境变量

- `docker/.env` — 环境变量模板
- `docker/env-noda-apps-preprod.env` — pre-prod 环境变量模板（envsubst 替换）

### 前序阶段参考

- `.planning/phases/58-infra-migration/58-CONTEXT.md` — 基础设施迁移决策
- `.planning/phases/59-app-migration/59-CONTEXT.md` — 应用服务迁移决策

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets

- `scripts/pipeline-stages.sh` — 所有 Pipeline 函数的实现，改造的基础
- `scripts/lib/health.sh` — `wait_container_healthy()` 函数，需改为支持远程执行
- `scripts/lib/log.sh` — 日志函数，本地/远程通用
- `docker/docker-compose.r4s.yml` — r4s overlay 已存在，不需要创建
- Phase 57 已配置 Mac jenkins 用户 → r4s root SSH 免密

### Established Patterns

- SSH 管道传输：`docker save | ssh -C root@r4s 'docker load'`（Phase 58/59 验证通过）
- Docker Compose overlay 模式：`-f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.r4s.yml`
- Pipeline 函数调用模式：`source scripts/pipeline-stages.sh && pipeline_xxx()`
- Nginx DNS resolver 动态 IP 刷新

### Integration Points

- Jenkins Credentials 需要添加 SSH 私钥
- Jenkins 环境变量需要添加 DEPLOY_TARGET 和 R4S_HOST
- r4s 需要配置 GitHub Deploy Key（只读访问 noda-infra）
- r4s 上需要 git clone noda-infra 到 /opt/noda/noda-infra/
- Pre-flight 阶段需要增加 flock 锁获取步骤

</code_context>

<specifics>
## Specific Ideas

- remote-ops.sh 应该提供 `remote_exec()` 函数封装 `ssh -i $SSH_KEY -o StrictHostKeyChecking=no root@$R4S_HOST` 基础命令，所有远程调用通过该函数
- infra Pipeline 中 Keycloak 部署（`docker stop/rm/run`）和 Nginx 部署（`docker compose recreate`）逻辑差异大，需要分别处理远程执行
- docker save/load 的镜像大小约 1-2GB，SSH 管道传输需要压缩（`ssh -C`）
- pre-prod 部署使用 `docker run --env-file` 而非 docker compose，envsubst + 管道传输模式是关键

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope
</deferred>

---

*Phase: 60-CI/CD 改造*
*Context gathered: 2026-05-18*
