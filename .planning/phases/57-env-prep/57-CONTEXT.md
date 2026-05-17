# Phase 57: 环境准备 - Context

**Gathered:** 2026-05-17
**Status:** Ready for planning

<domain>
## Phase Boundary

在 r4s (iStoreOS) 上搭建 Docker 运行环境：创建 Docker 独立网桥、配置 Swap 缓冲、设置容器内存限制、建立 SSH 部署通道、验证 Docker 开机自启。为 Phase 58-62 的迁移工作打好基础。

**Requirements:** ENV-01, ENV-02, ENV-03, ENV-04, ENV-05

</domain>

<decisions>
## Implementation Decisions

### 内存预算分配
- **D-01:** PostgreSQL 768M（从 Mac 上的 2G 压缩 — noda 数据库体积小）
- **D-02:** Keycloak 640M（保守缓冲，Java 应用启动峰值约 500M）
- **D-03:** Nginx 64M（反向代理开销低）
- **D-04:** noda-ops 256M（备份脚本 + Cloudflare Tunnel）
- **D-05:** findclass-ssr prod 384M（Node.js SSR 服务）
- **D-06:** findclass-ssr pre-prod 128M
- **D-07:** noda-admin 64M
- **D-08:** noda-auth 64M
- **D-09:** Pre-prod 总内存 256M（用户明确要求压缩 pre-prod 内存）
- **D-10:** 容器总内存 ~2.31 GiB，OS 保留 ~1.46 GiB，加 2GB Swap 安全缓冲
- **D-11:** 优先压缩数据库层（PG + KC），给应用层留更多空间

### Docker Compose 配置组织
- **D-12:** 新增 `docker/docker-compose.r4s.yml` overlay 文件，只覆盖内存限制、卷路径等 r4s 特有差异。复用现有 `docker-compose.yml` + `docker-compose.prod.yml`
- **D-13:** 容器名与 Mac 保持一致（noda-infra-postgres-prod, keycloak 等），Jenkins Pipeline 脚本无需改动容器名引用
- **D-14:** r4s 上仓库 clone 到 `/opt/noda-infra`
- **D-15:** 卷路径通过 `.env` 环境变量管理（如 `DOCKER_DATA_DIR=/mnt/mmc1-4/docker`），未来迁移到机械硬盘时只改 `.env`
- **D-16:** 密钥通过 Doppler CLI 动态注入 — Pipeline SSH 时在 r4s 上执行 `doppler secrets download --no-file --format docker > .env`，用完删除
- **D-17:** r4s 上安装 Doppler CLI（curl -Ls https://cli.doppler.com/install.sh | sh）
- **D-18:** Compose 文件通过 git clone/pull 同步到 r4s（版本可控）
- **D-19:** 服务管理方式与 Mac 保持一致 — postgres/nginx/noda-ops 通过 docker compose 管理，keycloak/findclass-ssr 通过 docker run 管理
- **D-20:** r4s 环境初始化用 shell 脚本（幂等），放在 `scripts/r4s/` 目录下

### Swap 与存储策略
- **D-21:** 2GB Swap 文件放在 SD 卡 `/mnt/mmc1-4/docker/swapfile`（与 Docker 数据同盘，54.8GB 空间充裕）
- **D-22:** `vm.swappiness=10` — 内核尽量用 RAM，只在内存压力大时才 swap
- **D-23:** SD 卡先行，可迁移 — 当 1TB 机械硬盘挂载后，卷路径可通过 `.env` 轻松切换

### SSH 部署通道
- **D-24:** 创建专用 jenkins 用户，加入 docker 组，限制 sudo 仅允许 docker 相关命令
- **D-25:** SSH 密钥类型 ed25519
- **D-26:** SSH 私钥存在 Jenkins credentials 中，Pipeline 通过 withCredentials 注入
- **D-27:** r4s jenkins 用户的 authorized_keys 只添加 Jenkins 公钥（专用，不共享）

### 网络端口与子网
- **D-28:** Nginx 容器映射到 8080:80 和 8443:443（高端口），避免与 iStoreOS 管理界面冲突。Cloudflare Tunnel 配置指向 8080/8443
- **D-29:** noda-network 使用 Docker 默认子网（172.17.x.x），与 iStoreOS LAN（192.168.x.x）不冲突

### 容器日志管理
- **D-30:** r4s 上容器日志配置 `max-size=5m, max-file=2`（比 Mac 的 10m×3 更紧凑），8 个容器总共 ~80MB 日志上限

### iStoreOS Docker 开机行为
- **D-31:** 在 Phase 57 脚本中验证 Docker 开机自启状态，记录 iStoreOS 特有的服务管理方式

### 初始化脚本幂等性
- **D-32:** 所有初始化脚本全幂等 — 每个步骤先检查当前状态再执行（网桥已存在则跳过、Swap 已启用则跳过、用户已存在则跳过）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docker Compose 配置
- `docker/docker-compose.yml` — 基础 compose 配置（服务定义、网络、卷）
- `docker/docker-compose.prod.yml` — 生产环境 overlay（安全加固、内存限制、日志配置）

### 部署脚本与库
- `scripts/deploy/deploy-infrastructure-prod.sh` — 当前 Mac 基础设施部署脚本（参考模式，r4s 不直接用）
- `scripts/lib/log.sh` — 日志函数库
- `scripts/lib/health.sh` — 健康检查函数库
- `scripts/lib/secrets.sh` — 密钥加载函数（Doppler 双模式）

### 规划文档
- `.planning/REQUIREMENTS.md` §ENV-01~ENV-05 — Phase 57 的 5 个需求
- `.planning/ROADMAP.md` §Phase 57 — Phase 目标和成功标准

### 配置文件
- `config/nginx/conf.d/default.conf` — Nginx 路由配置（端口映射影响 Cloudflare Tunnel 连接）

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/lib/log.sh` — 日志函数库，r4s 初始化脚本可直接复用
- `scripts/lib/health.sh` — `wait_container_healthy` 函数，健康检查可复用
- `scripts/lib/secrets.sh` — `load_secrets` 函数，Doppler 密钥加载模式可参考
- `scripts/deploy/deploy-infrastructure-prod.sh` — 部署流程模式（备份检查 → 保存镜像 → 部署 → 健康检查），r4s 脚本可参考

### Established Patterns
- Docker Compose overlay 模式 — `docker-compose.yml` (base) + `docker-compose.prod.yml` (prod) + 新增 `docker-compose.r4s.yml` (r4s)
- 容器双标签体系 — `noda.service-group=infra` + `noda.environment=prod`，r4s 保持一致
- noda-network 外部网桥 — 所有服务加入同一网络，容器间通过服务名访问
- 幂等脚本模式 — 先检查状态再执行（参考 deploy-check.sh 中的检查模式）

### Integration Points
- Docker Compose 命令需在仓库根目录执行（`-f docker/docker-compose.yml` 相对路径）
- Jenkins Pipeline 通过 SSH 在 r4s 上执行命令（Phase 60 会改造 Pipeline）
- Doppler CLI 需要 DOPPLER_TOKEN 环境变量（Phase 57 需要在 r4s 上配置）
- Cloudflare Tunnel 连接配置需要更新端口指向（Phase 61 处理）

</code_context>

<specifics>
## Specific Ideas

- Pre-prod 总内存限制 256M — 用户明确要求，需要在 docker-compose.r4s.yml 中严格执行
- r4s 密钥管理强调安全性 — Doppler 动态注入，不在 r4s 上持久存储密钥文件

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 57-环境准备*
*Context gathered: 2026-05-17*
