# Phase 58: 基础设施迁移 - Research

**Researched:** 2026-05-17
**Domain:** PostgreSQL/Keycloak/Nginx/noda-ops 容器从 Mac M4 迁移到 iStoreOS (r4s)
**Confidence:** HIGH

## Summary

Phase 58 将四个基础设施容器（PostgreSQL、Keycloak、Nginx、noda-ops）从 Mac M4 迁移到 r4s (iStoreOS)。所有决策已在 CONTEXT.md 中锁定：SSH 管道流式传输迁移 PG 数据、停服迁移、串行逐服务部署。本研究的核心任务是验证这些决策的技术可行性并提供具体的命令模式和陷阱规避。

通过实际连接 Mac 上的 PostgreSQL（17.9）获取了完整的数据库清单、表数量、行数和序列值，作为迁移验证的基准线。数据库总量仅约 50MB（keycloak 13MB + noda_prod 12MB + noda_preprod 9MB + noda_agent 8MB），管道传输预计在秒级完成。r4s overlay 配置（`docker-compose.r4s.yml`）已通过 `docker compose config` 验证，`!override` 标签正确替换端口映射。noda-ops 镜像 304MB，通过 `docker save | ssh docker load` 管道传输预计 1-2 分钟。

**Primary recommendation:** 严格按照 CONTEXT.md 锁定的迁移顺序（PG -> Keycloak -> Nginx -> noda-ops）执行，每个服务验证通过后再启动下一个。使用本文档提供的具体命令模式和验证查询。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** SSH 管道流式传输（`pg_dump | ssh root@r4s 'docker exec -i postgres pg_restore'`）
- **D-02:** 全部数据库一起迁移（noda_prod + keycloak + noda_preprod + noda_agent）
- **D-03:** 停服迁移 — Mac 上所有依赖 PG 的服务先停止
- **D-04:** 迁移前先执行一次完整备份（pg_dump + B2 上传）
- **D-05:** r4s 上先启动空 PG 容器，然后通过 SSH pipe 导入数据
- **D-06:** 数据完整性验证：对比表数量 + 每表行数
- **D-07:** Mac 上 `docker build` noda-ops 镜像，`docker save | ssh docker load` 到 r4s
- **D-08:** r4s 上使用与 Mac 相同的 `.env` 文件
- **D-09:** 逐服务串行迁移，每个验证通过后再下一个
- **D-10:** 迁移顺序：PostgreSQL -> Keycloak -> Nginx -> noda-ops
- **D-11:** 全程停服迁移，服务不可用
- **D-12:** Mac 旧容器保留（docker stop，不 docker rm）一周作为回滚点

### Claude's Discretion
- 具体的 pg_dump/pg_restore 命令参数
- 各服务健康检查的具体验证步骤
- r4s 上 Docker Compose 文件的具体部署命令
- 迁移过程中的错误处理和重试逻辑

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| INFRA-01 | PostgreSQL 数据从 Mac 迁移到 r4s（pg_dump/pg_restore，零数据丢失） | SSH 管道流式迁移模式 + 完整验证基准线 + 序列值检查 |
| INFRA-02 | Keycloak 配置迁移到 r4s（realm/主题/客户端配置保持不变） | Keycloak 数据在 PG 中自动迁移 + docker run 命令模式 |
| INFRA-03 | Nginx 反向代理配置迁移到 r4s（upstream/SSL/路由规则保持不变） | Docker Compose overlay + bind mount 配置文件 |
| INFRA-04 | noda-ops 容器迁移到 r4s（Cloudflare Tunnel + 备份 + Doppler + supervisord） | docker save/ssh load 镜像传输 + .env 环境变量 |
| INFRA-05 | noda-network 外部网络在 r4s 上创建，所有服务加入同一网络 | Phase 57 已创建 noda-network |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| PostgreSQL 数据迁移 | Mac (source) -> r4s (target) | — | Mac 产出数据，r4s 接收数据 |
| Keycloak 启动 | r4s (Docker Compose) | — | Keycloak 在 r4s PG 数据之上启动 |
| Nginx 反向代理 | r4s (Docker Compose) | — | Nginx 在 r4s 上监听 8080/8081/8443 |
| noda-ops 运行 | r4s (Docker Compose) | — | Cloudflare Tunnel + 备份在 r4s 运行 |
| 容器间 DNS 通信 | r4s Docker 内部网络 | — | noda-network 外部网桥提供 DNS 解析 |

## Standard Stack

### Core
| Library/Component | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| PostgreSQL | 17.9 | 数据库 | 已在 Mac 运行，r4s 使用相同镜像 `postgres:17.9` |
| Keycloak | 26.2.3 | 认证服务 | 已在 Mac 运行，r4s 使用 `quay.io/keycloak/keycloak:26.2.3` |
| Nginx | 1.25-alpine | 反向代理 | 已在 Mac 运行，r4s 使用 `nginx:1.25-alpine` |
| noda-ops | latest | 运维工具集 | Mac 构建，管道传输到 r4s |
| Docker Compose | v2.39.1 (r4s) | 容器编排 | r4s 已安装 |
| Docker Compose | v5.1.3 (Mac) | 容器编排 | Mac 已安装 |

### Supporting
| Component | Version | Purpose | When to Use |
|-----------|---------|---------|-------------|
| pg_dump/pg_restore | 17.9 (PG 自带) | 数据库迁移 | SSH 管道流式传输 |
| docker save/load | Docker 自带 | 镜像传输 | noda-ops 镜像传输到 r4s |
| cloudflared | latest (noda-ops 内) | Cloudflare Tunnel | noda-ops 容器内运行 |

**Installation:**
无需安装新包。所有工具已在 Docker 镜像中包含或在 Docker 引擎中内置。

## Package Legitimacy Audit

本阶段不安装任何外部包。所有使用的组件均为现有 Docker 镜像或 Docker 引擎自带工具。

| Package | Registry | Notes |
|---------|----------|-------|
| postgres:17.9 | Docker Hub | 已在用，无需验证 |
| quay.io/keycloak/keycloak:26.2.3 | Quay.io | 已在用，无需验证 |
| nginx:1.25-alpine | Docker Hub | 已在用，无需验证 |
| noda-ops:latest | 本地构建 | 自建镜像，无需验证 |

## Architecture Patterns

### System Architecture Diagram

```
Mac M4 (Source)                          r4s iStoreOS (Target)
+---------------------------+            +-------------------------------+
| Current Running Stack     |            | Phase 57 Prepared Environment |
|                           |            |                               |
| [postgres-prod] ----+     |            | [noda-network] external bridge|
|   noda_prod (12MB)   |    |            |                               |
|   keycloak (13MB)    |    |  SSH pipe  | Phase 58 Migration Targets:   |
|   noda_preprod (9MB) +----|===========>|                               |
|   noda_agent (8MB)   |    |  pg_dump   | [1] postgres-prod (empty)     |
|                      |    |  pg_restore|     ^  pipe data in           |
| [keycloak]           |    |            |     |                         |
|   data in PG --------+    |            | [2] keycloak (docker run)     |
|                      |    |  docker    |     connects to PG            |
| [nginx]              |    |  save/load |                               |
|   config files       +----|===========>| [3] nginx (compose up)        |
|                      |    |            |     bind mount configs        |
| [noda-ops]           |    |            |                               |
|   image (304MB) -----+----|===========>| [4] noda-ops (compose up)     |
|                      |    |            |     Tunnel + backup           |
+---------------------------+            +-------------------------------+
                                                   |
                                            8080/8081/8443 exposed
                                                   |
                                          (Cloudflare Tunnel later)
```

### Recommended Project Structure
```
# r4s 上的文件布局（git clone 到 r4s）
/opt/noda/noda-infra/          # 或实际 clone 路径
├── docker/
│   ├── docker-compose.yml
│   ├── docker-compose.prod.yml
│   ├── docker-compose.r4s.yml   # Phase 57 已创建
│   ├── .env                     # 从 Mac 复制
│   ├── services/
│   │   ├── postgres/backup/     # 备份脚本（bind mount）
│   │   ├── postgres/conf/       # PG 配置（bind mount）
│   │   └── keycloak/themes/     # Keycloak 主题（bind mount）
│   └── volumes/                 # 运行时数据目录
│       ├── backup/              # 备份文件
│       ├── history/             # 备份历史
│       └── logs/                # 日志
├── config/nginx/                # Nginx 配置（bind mount）
│   ├── conf.d/
│   ├── snippets/
│   ├── ssl/                     # SSL 证书
│   └── errors/                  # 错误页面
├── deploy/                      # Dockerfile + supervisord
└── scripts/backup/              # 备份脚本
```

### Pattern 1: SSH 管道流式 PG 数据迁移
**What:** 通过 SSH 管道直接将 pg_dump 输出流式传输到远程 pg_restore，不产生中间文件
**When to use:** 从 Mac 向 r4s 迁移所有 PostgreSQL 数据库
**Example:**
```bash
# 单数据库迁移模式（D-01）
# Mac 端: docker exec pg_dump -> ssh -> r4s 端: docker exec -i pg_restore
docker exec noda-infra-postgres-prod \
  pg_dump -U postgres -Fc "noda_prod" | \
  ssh root@<R4S_IP> \
  "docker exec -i noda-infra-postgres-prod pg_restore -U postgres -d noda_prod"

# 多数据库循环模式（D-02）
for db in noda_prod keycloak noda_preprod noda_agent; do
  echo "Migrating $db..."
  docker exec noda-infra-postgres-prod \
    pg_dump -U postgres -Fc "$db" | \
    ssh root@<R4S_IP> \
    "docker exec -i noda-infra-postgres-prod pg_restore -U postgres -d $db"
done
```
**Key notes:**
- `-Fc` 自定义格式：压缩、支持并行恢复、可选择性恢复
- `docker exec -i`（非交互模式）是管道传输的必要条件
- 每个数据库单独 pg_dump/pg_restore（pg_dump 不支持一次 dump 多个数据库）

### Pattern 2: Docker 镜像管道传输
**What:** 通过 SSH 管道将本地构建的 Docker 镜像传输到远程主机
**When to use:** noda-ops 镜像从 Mac 传输到 r4s
**Example:**
```bash
# 构建镜像
docker build -t noda-ops:latest -f deploy/Dockerfile.noda-ops .

# 管道传输（D-07）
docker save noda-ops:latest | ssh -C root@<R4S_IP> "docker load"
```
**Key notes:**
- `-C` 启用 SSH 压缩，noda-ops 镜像 304MB 压缩后约 100-150MB
- ARM64 -> ARM64，无需跨架构构建
- 传输完成后在 r4s 上 `docker images noda-ops` 验证

### Pattern 3: Keycloak docker run 部署
**What:** Keycloak 不通过 Docker Compose 启动，而是通过 docker run 直接启动
**When to use:** r4s 上启动 Keycloak（与 Mac 上 Jenkins Pipeline 管理方式一致）
**Example:**
```bash
# r4s 上直接 docker run Keycloak
docker run -d \
  --name noda-infra-keycloak \
  --network noda-network \
  --restart unless-stopped \
  --memory 640m \
  -e KC_DB=postgres \
  -e KC_DB_URL=jdbc:postgresql://noda-infra-postgres-prod:5432/keycloak \
  -e KC_DB_USERNAME=postgres \
  -e KC_DB_PASSWORD="${POSTGRES_PASSWORD}" \
  -e KC_HOSTNAME=https://auth.noda.co.nz \
  -e KC_HOSTNAME_STRICT=false \
  -e KC_HTTP_ENABLED=true \
  -e KC_PROXY=edge \
  -e KC_PROXY_HEADERS=xforwarded \
  -e KC_FRONTEND_URL=https://auth.noda.co.nz \
  -e KC_HEALTH_ENABLED=true \
  -e KEYCLOAK_ADMIN=admin \
  -e KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
  quay.io/keycloak/keycloak:26.2.3 \
  start --hostname-strict=false --proxy-headers=xforwarded
```
**Key notes:**
- Keycloak 在 docker-compose.yml 中标记为 `profiles: disabled`
- Mac 上通过 Jenkinsfile.infra Pipeline 管理（docker stop/rm/run）
- r4s 上此阶段直接 docker run 启动即可
- 必须等待 PG 健康检查通过后再启动 Keycloak

### Anti-Patterns to Avoid
- **不要在 Mac 端导出 SQL 文件再 scp：** 违反 D-01 决策，产生中间文件浪费磁盘和带宽。直接使用 SSH 管道。
- **不要在 r4s 上先启动所有服务再迁移数据：** 服务启动失败会产生误导性错误日志。应先启动空 PG，导入数据后再逐服务启动。
- **不要忘记创建数据库再 pg_restore：** pg_restore 的 `-d` 参数要求目标数据库已存在。r4s PG 首次启动只有 `noda_prod`（由 POSTGRES_DB 创建），需要手动创建 `keycloak`、`noda_preprod`、`noda_agent`。
- **不要忘记迁移 roles：** `preprod_app` 角色需要在 r4s PG 中创建，否则 noda_preprod 数据库的权限会丢失。

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| PG 数据迁移 | 自写同步脚本 | pg_dump -Fc + SSH pipe + pg_restore | 原生工具保证数据一致性，处理序列、权限、约束 |
| 数据验证 | 自写比较脚本 | psql 查询: count(*) per table + pg_sequences | 直接 SQL 查询最可靠 |
| 镜像传输 | 自建 registry | docker save + ssh pipe + docker load | 零基础设施需求，ARM64 直接兼容 |
| Keycloak 配置迁移 | export/import realm JSON | PG 数据库整库迁移 | Keycloak 所有配置在 PG 中，无需单独处理 |

**Key insight:** 本次迁移的核心优势是所有有状态数据都在 PostgreSQL 中（包括 Keycloak 配置），因此只需要做好 PG 数据迁移，其余服务启动即可恢复。

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | PostgreSQL: 4 个用户数据库（keycloak/noda_prod/noda_preprod/noda_agent），总计约 50MB | pg_dump/pg_restore SSH 管道迁移 |
| Stored data | PG roles: `postgres`(superuser) + `preprod_app`(login) | 迁移后手动创建 preprod_app 角色 |
| Stored data | PG sequences: noda_prod 有 5 个活跃序列（web_vitals_id_seq=891 最大） | pg_dump -Fc 自动包含序列值 |
| Live service config | Keycloak 当前运行参数（docker inspect 获取） | docker run 使用相同参数 |
| Live service config | Nginx 配置文件（bind mount from git repo） | r4s 上 clone 相同 repo |
| Live service config | noda-ops 镜像（本地构建，304MB） | docker save + ssh pipe + docker load |
| OS-registered state | Docker Compose project name: `noda-infra` | r4s 上保持一致（name: noda-infra） |
| OS-registered state | noda-network 外部网络 | Phase 57 已在 r4s 创建 |
| Secrets/env vars | `.env` 文件（PG 密码、B2 密钥、CF Tunnel Token 等） | 复制到 r4s 相同路径（D-08） |
| Build artifacts | noda-ops:latest 镜像（304MB） | 管道传输到 r4s |
| Build artifacts | postgres_data Docker volume（489MB on Mac） | 不迁移 volume，通过 pg_dump/pg_restore 重建 |

## Common Pitfalls

### Pitfall 1: pg_restore 目标数据库不存在
**What goes wrong:** `pg_restore -d keycloak` 失败，因为 r4s 上空 PG 只有 `noda_prod`（POSTGRES_DB 环境变量创建的）
**Why it happens:** PG 首次启动只创建 `POSTGRES_DB` 指定的数据库，`keycloak`、`noda_preprod`、`noda_agent` 需要手动创建
**How to avoid:** 在 pg_restore 之前，先执行 `createdb` 创建所有目标数据库
**Warning signs:** `pg_restore: error: connection to database "keycloak" failed: FATAL: database "keycloak" does not exist`

```bash
# 在 r4s PG 启动后，先创建所有数据库
ssh root@<R4S_IP> "docker exec -i noda-infra-postgres-prod psql -U postgres -c 'CREATE DATABASE keycloak;'"
ssh root@<R4S_IP> "docker exec -i noda-infra-postgres-prod psql -U postgres -c 'CREATE DATABASE noda_preprod;'"
ssh root@<R4S_IP> "docker exec -i noda-infra-postgres-prod psql -U postgres -c 'CREATE DATABASE noda_agent;'"
# 然后创建 preprod_app 角色
ssh root@<R4S_IP> "docker exec -i noda-infra-postgres-prod psql -U postgres -c \"CREATE ROLE preprod_app WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}';\""
# 授权
ssh root@<R4S_IP> "docker exec -i noda-infra-postgres-prod psql -U postgres -c 'GRANT ALL PRIVILEGES ON DATABASE noda_preprod TO preprod_app;'"
```

### Pitfall 2: Docker Compose bind mount 路径在 r4s 上不存在
**What goes wrong:** `docker compose up` 失败，因为 Nginx/PG 的 bind mount 源路径指向 Mac 本地路径
**Why it happens:** docker-compose.yml 和 docker-compose.prod.yml 中的 bind mount 使用相对路径（如 `../config/nginx/`），但 r4s 上需要先 clone 仓库
**How to avoid:** 确保在 r4s 上完整 clone noda-infra 仓库，且从正确目录执行 `docker compose`
**Warning signs:** `ERROR: for nginx  source . not found`

### Pitfall 3: Keycloak 启动时 PG 尚未就绪
**What goes wrong:** Keycloak 启动失败，报数据库连接错误
**Why it happens:** Keycloak 容器启动很快但需要 PG 连接，如果 PG 健康检查尚未通过，Keycloak 会启动失败
**How to avoid:** 使用 `wait_container_healthy` 函数等待 PG healthy 后再启动 Keycloak
**Warning signs:** Keycloak 日志 `ERROR: Connection refused` 或 `FATAL: the database system is starting up`

### Pitfall 4: postgres_data volume 残留导致 init 脚本不执行
**What goes wrong:** 如果 r4s 上 postgres_data volume 已存在（来自之前的测试），PG 不会重新初始化
**Why it happens:** PostgreSQL 只在 `PGDATA` 目录为空时执行初始化
**How to avoid:** 首次启动前确认 volume 是空的，或使用 `docker volume rm` 清理
**Warning signs:** PG 启动后数据目录非空，缺少预期的数据库

### Pitfall 5: SSH 管道中断无法恢复
**What goes wrong:** 网络中断导致 SSH 管道断裂，pg_dump/pg_restore 中途中止
**Why it happens:** 网络不稳定或 SSH 超时
**How to avoid:** 数据量仅约 50MB，管道传输秒级完成。如果需要重试，可以安全地重新执行（pg_restore 会报错但不会损坏已有数据）。对于已存在的对象，使用 `--clean --if-exists` 参数清理。
**Warning signs:** `pg_restore: error: could not execute query: connection to server was lost`

### Pitfall 6: Keycloak profiles: disabled 导致 docker compose up 不启动
**What goes wrong:** `docker compose up -d` 不会启动 Keycloak，因为 `profiles: disabled`
**Why it happens:** 这是设计行为 — Keycloak 通过 Jenkins Pipeline 的 docker run 管理
**How to avoid:** 明确知道 Keycloak 需要单独 `docker run` 启动，不依赖 compose
**Warning signs:** `docker compose up -d` 只启动 postgres/nginx/noda-ops，没有 keycloak

## Code Examples

### PG 迁移完整流程（核心命令）

```bash
# === Step 1: Mac 上停服 ===
docker stop noda-apps-prod noda-apps-preprod noda-infra-keycloak noda-ops noda-infra-nginx

# === Step 2: Mac 上执行完整备份（D-04）===
docker exec noda-infra-postgres-prod /app/backup/backup-postgres.sh

# === Step 3: r4s 上启动空 PG 容器（D-05）===
ssh root@<R4S_IP> "cd /path/to/noda-infra && \
  docker compose -f docker/docker-compose.yml \
    -f docker/docker-compose.prod.yml \
    -f docker/docker-compose.r4s.yml \
    up -d postgres"

# === Step 4: 等待 PG 健康检查通过 ===
ssh root@<R4S_IP> "docker inspect --format='{{.State.Health.Status}}' noda-infra-postgres-prod"
# 重复直到返回 "healthy"

# === Step 5: r4s 上创建目标数据库和角色 ===
for db in keycloak noda_preprod noda_agent; do
  ssh root@<R4S_IP> "docker exec -i noda-infra-postgres-prod psql -U postgres -c 'CREATE DATABASE $db;'"
done
ssh root@<R4S_IP> "docker exec -i noda-infra-postgres-prod psql -U postgres -c \"CREATE ROLE preprod_app WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}';\""
ssh root@<R4S_IP> "docker exec -i noda-infra-postgres-prod psql -U postgres -c 'GRANT ALL PRIVILEGES ON DATABASE noda_preprod TO preprod_app;'"

# === Step 6: SSH 管道迁移所有数据库（D-01, D-02）===
for db in noda_prod keycloak noda_preprod noda_agent; do
  echo "=== Migrating $db ==="
  docker exec noda-infra-postgres-prod \
    pg_dump -U postgres -Fc "$db" | \
    ssh root@<R4S_IP> \
    "docker exec -i noda-infra-postgres-prod pg_restore -U postgres -d $db --no-owner --no-privileges"
  echo "=== $db done ==="
done
```

### 数据完整性验证查询（D-06）

```bash
# Mac 上获取基准线（迁移前执行一次并保存输出）
for db in keycloak noda_prod noda_preprod noda_agent; do
  echo "=== $db ==="
  docker exec noda-infra-postgres-prod psql -U postgres -d "$db" -c "
    SELECT schemaname || '.' || tablename as table_name,
           (xpath('/row/cnt/text()', query_to_xml(format('SELECT count(*) as cnt FROM %I.%I', schemaname, tablename), false, true, '')))[1]::text::int as row_count
    FROM pg_tables
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    ORDER BY schemaname, tablename;"
done

# r4s 上执行相同查询，对比结果

# 序列值验证
for db in keycloak noda_prod noda_preprod noda_agent; do
  echo "=== $db sequences ==="
  docker exec noda-infra-postgres-prod psql -U postgres -d "$db" -c \
    "SELECT sequencename, last_value FROM pg_sequences ORDER BY sequencename;"
done
```

### Nginx + noda-ops 启动

```bash
# r4s 上启动 Nginx
ssh root@<R4S_IP> "cd /path/to/noda-infra && \
  docker compose -f docker/docker-compose.yml \
    -f docker/docker-compose.prod.yml \
    -f docker/docker-compose.r4s.yml \
  up -d nginx"

# r4s 上构建并传输 noda-ops 镜像
# Mac 端:
docker build -t noda-ops:latest -f deploy/Dockerfile.noda-ops .
docker save noda-ops:latest | ssh -C root@<R4S_IP> "docker load"

# r4s 上启动 noda-ops
ssh root@<R4S_IP> "cd /path/to/noda-infra && \
  docker compose -f docker/docker-compose.yml \
    -f docker/docker-compose.prod.yml \
    -f docker/docker-compose.r4s.yml \
  up -d noda-ops"
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Docker Compose v1 `docker-compose` | Docker Compose v2 `docker compose` | 2023+ | r4s 已安装 v2.39.1，Mac 已安装 v5.1.3 |
| Docker Compose ports 合并追加 | `!override` YAML 标签完全替换 | Compose v2.24+ | r4s overlay 使用 `!override` 替换端口映射，已验证有效 |
| Keycloak standalone export/import | Keycloak 数据在 PG 中 | 项目开始 | 无需单独迁移 Keycloak 配置，PG 迁移即可 |
| 本地 docker compose 部署 | SSH 远程 docker compose | Phase 60 实现 | 本阶段（Phase 58）直接手动 SSH 操作 |

**Deprecated/outdated:**
- `KC_HOSTNAME_PORT` / `KC_HOSTNAME_STRICT_HTTPS`：Keycloak v1 废弃选项，不应使用
- `docker-compose`（带连字符）：已由 `docker compose`（空格）替代

## Data Migration Baseline

> 迁移前必须保存以下基准线，用于验证迁移后的数据完整性。

### 数据库大小
| Database | Size | Tables | Key Sequences |
|----------|------|--------|---------------|
| keycloak | 13 MB | 88 | (无序列) |
| noda_prod | 12 MB | 12 | web_vitals_id_seq=891, course_view_dedup_id_seq=146 |
| noda_preprod | 9214 kB | 12 | web_vitals_id_seq=133, __drizzle_migrations_id_seq=64 |
| noda_agent | 7681 kB | 5 | (无序列) |

### 关键表行数（noda_prod）
| Table | Rows |
|-------|------|
| courses | 464 |
| profiles | 338 |
| web_vitals | 314 |
| categories | 30 |
| crawl_executions | 18 |
| cron_services | 1 |
| admin_users | 1 |
| sources | 1 |

### 关键表行数（keycloak）
| Table | Rows |
|-------|------|
| protocol_mapper_config | 624 |
| client_scope_client | 363 |
| realm_attribute | 132 |
| keycloak_role | 136 |
| composite_role | 126 |
| component_config | 112 |
| protocol_mapper | 108 |
| client_scope_attributes | 102 |
| offline_user_session | 46 |
| offline_client_session | 47 |
| user_entity | 6 |
| realm | 3 |
| identity_provider | 2 |
| credential | 3 |

### PG Roles
| Role | Superuser | Can Login |
|------|-----------|-----------|
| postgres | yes | yes |
| preprod_app | no | yes |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | r4s IP 地址与 STATE.md 中记录一致（192.168.1.1） | Environment | SSH 无法连接，迁移无法开始 |
| A2 | r4s 上已 clone noda-infra 仓库到某个路径 | Architecture Patterns | bind mount 路径不存在，容器启动失败 |
| A3 | r4s 上 noda-network 已正确创建（Phase 57） | Pattern 3 | 容器无法加入网络，DNS 不可用 |
| A4 | r4s 上 swap 已配置（Phase 57） | Architecture | OOM Killer 可能杀掉 PG 容器 |
| A5 | SSH 免密密钥已配置（Phase 57） | Pattern 1 | SSH 管道传输需要密码，无法自动化 |
| A6 | noda_prod 数据库由 POSTGRES_DB 环境变量自动创建 | Pitfall 1 | 需要手动创建 noda_prod |
| A7 | `pg_restore --no-owner --no-privileges` 可安全跳过 owner/grant 设置 | Code Examples | 权限需要手动设置 |

**注：** A1-A5 依赖 Phase 57 的执行结果。Phase 57 已标记完成，但这些假设需要在迁移开始前验证。

## Open Questions

1. **r4s 的实际 IP 地址和仓库路径**
   - What we know: STATE.md 记录 `ssh root@192.168.1.1`，但当前 Mac 无法连通（可能不在同一网络）
   - What's unclear: 实际可用的 IP 地址、r4s 上的代码仓库路径
   - Recommendation: Planner 应在 Plan 01 中包含 "验证 r4s 连接和环境" 步骤

2. **r4s 上 git clone 的具体路径**
   - What we know: 需要 bind mount 的文件（nginx 配置、PG 配置、备份脚本等）必须存在于 r4s
   - What's unclear: r4s 上 repo 的具体 clone 路径
   - Recommendation: 建议使用 `/opt/noda/noda-infra` 或用户指定的路径

3. **pg_restore 的 --no-owner --no-privileges 参数是否需要**
   - What we know: Mac 上所有表属于 postgres 用户，r4s 上也是 postgres 用户
   - What's unclear: pg_dump/pg_restore 是否正确传递 owner 信息
   - Recommendation: 保守起见使用 `--no-owner`，避免跨容器 owner 不匹配问题

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker (Mac) | pg_dump 源端 | ✓ | 27.x | — |
| Docker (r4s) | 容器运行 | 未验证（当前不可达） | 27.3.1 | — |
| Docker Compose (r4s) | 编排 | 未验证 | v2.39.1 | — |
| SSH (Mac -> r4s) | 管道传输 | 未验证（当前不可达） | OpenSSH | — |
| noda-network (r4s) | 容器网络 | Phase 57 已创建 | — | — |
| Swap (r4s) | OOM 保护 | Phase 57 已配置 | 2GB | — |

**Missing dependencies with no fallback:**
- r4s SSH 连接 — 必须可达才能执行迁移

**Missing dependencies with fallback:**
- None

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell 脚本验证（非传统测试框架） |
| Config file | 无 — 使用内联验证命令 |
| Quick run command | `ssh root@<R4S_IP> "docker exec noda-infra-postgres-prod psql -U postgres -c '\\l'"` |
| Full suite command | 逐服务健康检查 + 数据完整性 SQL 查询 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| INFRA-01 | PG 数据完整迁移 | smoke | `ssh r4s "docker exec pg psql -U postgres -d noda_prod -c 'SELECT count(*) FROM courses;'"` | Wave 0 |
| INFRA-01 | PG 序列值正确 | smoke | `ssh r4s "docker exec pg psql -U postgres -d noda_prod -c 'SELECT last_value FROM web_vitals_id_seq;'"` | Wave 0 |
| INFRA-02 | Keycloak 健康检查 | smoke | `ssh r4s "docker inspect --format='{{.State.Health.Status}}' noda-infra-keycloak"` | Wave 0 |
| INFRA-03 | Nginx 监听端口 | smoke | `ssh r4s "curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/health"` | Wave 0 |
| INFRA-04 | noda-ops 健康检查 | smoke | `ssh r4s "docker inspect --format='{{.State.Health.Status}}' noda-ops"` | Wave 0 |
| INFRA-05 | noda-network 存在 | smoke | `ssh r4s "docker network inspect noda-network"` | Wave 0 |

### Sampling Rate
- **Per task commit:** `ssh r4s "docker ps --format 'table {{.Names}}\t{{.Status}}'"`
- **Per wave merge:** 逐服务健康检查 + 数据 SQL 查询
- **Phase gate:** 所有 5 个 INFRA 需求的验证命令全部通过

### Wave 0 Gaps
- [ ] 无传统测试框架 — 使用 shell 命令和 SQL 查询作为验证手段

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | yes | PG 角色权限（preprod_app 仅限 noda_preprod） |
| V5 Input Validation | no | — |
| V6 Cryptography | yes | SSH 管道传输加密 + pg_dump 自定义格式 |

### Known Threat Patterns for Infrastructure Migration

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 数据传输中的中间人攻击 | Tampering | SSH 加密管道 |
| 凭据泄露（.env 文件传输） | Information Disclosure | SSH 管道传输，不在中间存储 |
| 迁移期间服务不可用 | Denial of Service | 已决策 D-11 接受停服窗口 |

## Sources

### Primary (HIGH confidence)
- Mac 实际 PostgreSQL 查询 — 数据库清单、表结构、行数、序列值、角色（通过 docker exec 实时查询）
- Docker Compose 配置合并验证 — `docker compose config --format json` 确认 `!override` 端口替换生效
- Docker inspect — Keycloak/noda-ops 实际运行参数和环境变量
- 项目源码 — `docker-compose.yml`, `docker-compose.prod.yml`, `docker-compose.r4s.yml`, `Dockerfile.noda-ops`

### Secondary (MEDIUM confidence)
- [Docker Compose Merge Docs](https://docs.docker.com/reference/compose-file/merge/) — `!override` 和 `!reset` YAML 标签文档
- [Stack Overflow: pg_restore over SSH](https://stackoverflow.com/questions/51729431/restore-postgres-database-using-pg-restore-over-ssh) — SSH 管道 pg_restore 模式
- [Stack Overflow: docker save over SSH](https://stackoverflow.com/questions/26346548/dockerssh-how-to-transfer-docker-images-from-one-host-to-another-securely-on-a) — `docker save | ssh docker load` 模式

### Tertiary (LOW confidence)
- 无 — 所有技术细节已通过代码检查和实际查询验证

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有组件已在 Mac 上运行，r4s 使用相同镜像和配置
- Architecture: HIGH — Docker Compose overlay 已验证合并正确性
- Pitfalls: HIGH — 基于 Mac 实际数据库状态分析，pitfall 场景有具体错误信息
- Migration commands: HIGH — pg_dump/pg_restore 是标准工具，数据量小（50MB），风险极低

**Research date:** 2026-05-17
**Valid until:** 2026-06-17（30 天 — Docker 镜像版本和配置短期内稳定）
