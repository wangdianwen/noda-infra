# Phase 58: 基础设施迁移 - Context

**Gathered:** 2026-05-17
**Status:** Ready for planning

## Phase Boundary

将 PostgreSQL、Keycloak、Nginx、noda-ops 四个基础设施容器从 Mac 迁移到 r4s (iStoreOS)，数据完整迁移，服务在 r4s 上正常运行。迁移范围仅限基础设施容器，应用容器（findclass-ssr、noda-admin、noda-auth）在 Phase 59 迁移。

## Implementation Decisions

### PostgreSQL 迁移

- **D-01:** 使用 SSH 管道流式传输（`pg_dump | ssh root@r4s 'docker exec -i postgres pg_restore'`）。不产生中间文件，节省磁盘空间。
- **D-02:** 全部数据库一起迁移（noda_prod + keycloak + noda_preprod 等所有数据库）。Keycloak 数据在 PG 中，无需单独 export/import。
- **D-03:** 停服迁移 — Mac 上所有依赖 PG 的服务先停止，确保数据一致性，零数据丢失。
- **D-04:** 迁移前先执行一次完整备份（pg_dump + B2 上传），作为回滚安全网。
- **D-05:** r4s 上先启动空 PostgreSQL 容器（初始化默认数据库），然后通过 SSH pipe 导入数据。
- **D-06:** 数据完整性验证：对比 Mac 和 r4s 上各数据库的表数量 + 每表行数。

### noda-ops 镜像处理

- **D-07:** Mac 上 `docker build` 构建 noda-ops 镜像，然后 `docker save | ssh root@r4s 'docker load'` 管道传输到 r4s。与 PG 迁移统一使用管道模式。
- **D-08:** r4s 上使用与 Mac 相同的 `.env` 文件配置环境变量（CLOUDFLARE_TUNNEL_TOKEN、B2 密钥、DOPPLER_TOKEN 等）。

### 迁移执行节奏

- **D-09:** 逐服务串行迁移，每个服务在 r4s 上启动并验证通过后再迁移下一个。
- **D-10:** 迁移顺序：PostgreSQL → Keycloak → Nginx → noda-ops。遵循依赖关系（KC 依赖 PG，Nginx 路由到所有服务，noda-ops 依赖 PG）。

### 数据安全策略

- **D-11:** 全程停服迁移。Mac 上所有基础设施服务停止 → r4s 数据迁移 → r4s 服务启动 → 逐服务验证。迁移窗口期间服务不可用。
- **D-12:** r4s 全部验证通过后，Mac 旧容器保留（docker stop，不 docker rm），保留一周后清理。保留期间可作为回滚点。

### Claude's Discretion

- 具体的 pg_dump/pg_restore 命令参数
- 各服务健康检查的具体验证步骤
- r4s 上 Docker Compose 文件的具体部署命令
- 迁移过程中的错误处理和重试逻辑

## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Docker Compose 配置

- `docker/docker-compose.yml` — 基础服务定义（postgres、nginx、noda-ops、keycloak）
- `docker/docker-compose.prod.yml` — 生产环境覆盖（安全加固、资源限制、Keycloak 环境变量）
- `docker/docker-compose.r4s.yml` — r4s overlay（内存限制、高端口映射 8080:80/8081:81/8443:443、紧凑日志）

### Nginx 配置

- `config/nginx/conf.d/default.conf` — 反向代理路由（prod + pre-prod 域名）
- `config/nginx/snippets/upstream-*.conf` — upstream 定义

### noda-ops

- `deploy/Dockerfile.noda-ops` — noda-ops 镜像构建文件

### 环境变量

- `docker/.env` — Mac 环境变量模板（r4s 需要相同的配置）

### 备份系统

- `scripts/backup/` — 现有备份脚本（迁移前执行一次作为安全网）

## Existing Code Insights

### Reusable Assets

- `docker-compose.r4s.yml` — Phase 57 已创建，包含所有容器的 r4s 内存限制和端口映射。直接使用。
- `docker/.env` — Mac 环境变量文件可直接复制到 r4s 使用（PG 密钥、B2 密钥等不变）。
- `docker/services/postgres/backup/` — 备份脚本和配置，r4s 上复用。

### Established Patterns

- Docker Compose overlay 模式：`-f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.r4s.yml`
- Keycloak 通过 Jenkins Pipeline 管理（docker stop/rm/run），不在 compose 中启动（profiles: disabled）
- noda-network 外部网络 — Phase 57 已在 r4s 上创建

### Integration Points

- PostgreSQL 容器需要先启动，其他服务依赖数据库连接
- Keycloak 容器需要 PostgreSQL 健康检查通过后再启动
- Nginx 需要所有上游服务就绪后才能正确路由
- noda-ops 需要 PostgreSQL 连接（备份功能）+ Cloudflare Tunnel Token

## Specific Ideas

- 迁移过程使用一致的 SSH 管道模式（PG 数据和 noda-ops 镜像都用管道），减少中间文件
- 逐服务验证而非全部一起验证，方便定位问题

## Deferred Ideas

None — discussion stayed within phase scope

---

*Phase: 58-基础设施迁移*
*Context gathered: 2026-05-17*
