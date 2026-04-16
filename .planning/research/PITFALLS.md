# Domain Pitfalls: Noda v1.5 开发环境本地化 + 基础设施 CI/CD

**Domain:** Docker Compose 基础设施项目 — 添加本地开发环境、Jenkins H2 迁移、Keycloak 蓝绿部署、统一基础设施 Pipeline
**Researched:** 2026-04-17
**Confidence:** MEDIUM（项目代码库深度分析 + 训练知识；WebSearch API 不可用，部分结论未经在线验证）

---

## Critical Pitfalls

### Pitfall 1: Jenkins H2 迁移到 PostgreSQL — 静默数据丢失

**What goes wrong:**
Jenkins 从嵌入式 H2 数据库迁移到 PostgreSQL 时，构建历史、Pipeline 定义、凭据、插件配置可能部分丢失。最危险的是"静默丢失"——迁移显示成功，但某些插件的自定义表或大字段（如构建日志 XML）未被完整迁移，直到数天后用户发现数据缺失。

**Why it happens:**
- H2 和 PostgreSQL 的类型系统不同：H2 的 `CLOB` 映射到 PostgreSQL 的 `TEXT` 时可能截断；`BOOLEAN` 表示方式不同（H2 用整数，PG 用布尔）
- Jenkins 插件可以创建自定义数据库表，官方迁移脚本不覆盖第三方插件表
- H2 对外键约束更宽松，违反约束的行在导入 PG 时被静默丢弃
- 如果迁移期间 Jenkins 未完全停止，H2 文件可能处于不一致状态

**How to avoid:**
1. **迁移前**：完整备份 `JENKINS_HOME`（含 `db.bak` 目录中的 H2 文件）
2. **迁移前**：记录关键表的行数（`build`、`job`、`credential` 等），迁移后逐表对比
3. **迁移时**：必须先停止 Jenkins（`systemctl stop jenkins`），确认进程完全退出
4. **迁移后**：启动 Jenkins 前验证 JDBC 连接、字符编码（必须是 `UTF8`）、时区设置
5. **回滚计划**：保留 H2 文件至少一周，确保可以回退

**Warning signs:**
- Jenkins 启动日志中出现 `DataConversionException` 或 `SchemaException`
- 构建历史数量少于迁移前
- Pipeline 定义丢失或变回默认值
- 凭据列表为空

**Phase to address:**
Phase 1（宿主机 PostgreSQL 安装 + Jenkins 迁移）。这是整个里程碑的基础——如果迁移失败，后续所有依赖 Jenkins 数据库的功能都会受影响。

---

### Pitfall 2: Homebrew PostgreSQL 版本与 Docker PostgreSQL 版本不匹配

**What goes wrong:**
宿主机通过 Homebrew 安装的 PostgreSQL 版本（如 17.x）与 Docker 中运行的 PostgreSQL 版本（当前 `postgres:17.9`）看起来主版本号相同，但 `pg_dump`/`pg_restore` 工具的次版本差异可能导致备份不兼容。更关键的是：Jenkins 使用 JDBC 驱动连接 PostgreSQL，如果 Homebrew 升级了 PostgreSQL 但 Jenkins 的 PostgreSQL JDBC 驱动版本不匹配，连接可能静默失败或数据损坏。

**Why it happens:**
- Homebrew 的 PostgreSQL 版本跟随 Homebrew formula，可能比 Docker 固定版本（`postgres:17.9`）更新
- `pg_dump 17.9` 产出的备份无法被 `pg_restore 16.x` 恢复（跨大版本不兼容）
- Jenkins 的 PostgreSQL 插件自带的 JDBC 驱动版本（如 `42.x.x`）必须与 PostgreSQL 服务端版本兼容
- 项目当前 Docker 中使用 `postgres:17.9`，但 Jenkins 的 JDBC 驱动可能只测试过 16.x

**How to avoid:**
1. **锁定 Homebrew PostgreSQL 版本**：使用 `brew install postgresql@17` 而非 `brew install postgresql`，确保与 Docker 版本匹配
2. **验证 JDBC 驱动兼容性**：迁移前测试 Jenkins 的 PostgreSQL 插件与本地 PG 的连接
3. **统一工具链**：确保 `pg_dump`/`psql` 的客户端版本与服务器端版本一致（`psql --version` vs `SELECT version()`）
4. **文档化版本矩阵**：在 STACK.md 中明确 Homebrew PG 版本、Docker PG 版本、JDBC 驱动版本的对应关系

**Warning signs:**
- `pg_dump` 报 `aborting because of server version mismatch`
- Jenkins 日志出现 `org.postgresql.util.PSQLException: Protocol error`
- `psql` 客户端连接时出现 `major version differs` 警告

**Phase to address:**
Phase 1（宿主机 PostgreSQL 安装）。安装时必须锁定版本，不然后续所有数据库操作都可能出问题。

---

### Pitfall 3: 移除 postgres-dev / keycloak-dev 容器破坏现有开发工作流

**What goes wrong:**
项目当前 `docker-compose.dev.yml` 定义了 `postgres-dev`（端口 5433）和 `keycloak-dev`（端口 18080）作为开发环境容器。移除这些容器后，开发者的本地应用配置（如 `.env` 中的数据库连接字符串）会立即失效。如果有开发数据沉淀在 `postgres_dev_data` Docker volume 中，移除容器后这些数据可能无法恢复。

**Why it happens:**
- `docker-compose.dev.yml` 的 `postgres-dev` 容器有独立的 Docker volume `postgres_dev_data`，包含开发用的种子数据和测试数据
- `keycloak-dev` 的 `start-dev` 模式提供了与生产环境隔离的 Keycloak 测试实例（不需要 HTTPS、不设 hostname 限制）
- 开发者本地的环境变量、IDE 数据库连接配置可能硬编码了 `localhost:5433`
- 移除容器后，需要重新配置所有本地开发工具指向宿主机 PostgreSQL

**How to avoid:**
1. **数据迁移脚本**：在移除容器前，编写脚本将 `postgres_dev_data` volume 中的数据导出并导入到宿主机 PostgreSQL 的开发数据库中
2. **端口映射过渡**：宿主机 PostgreSQL 的开发数据库监听 `localhost:5433`（与旧容器端口一致），减少开发者配置变更
3. **文档化迁移步骤**：明确列出需要修改的本地配置文件（`.env`、IDE 配置等）
4. **保留 keycloak-dev 的替代方案**：由于本地不安装 Keycloak（PROJECT.md Out of Scope），需要明确开发者如何测试认证流程（如使用生产 Keycloak 的测试 realm）
5. **分阶段移除**：先让宿主机 PostgreSQL 可用，验证开发流程正常后再移除 Docker 容器

**Warning signs:**
- 开发者报告本地应用无法连接数据库
- `docker compose -f docker-compose.dev.yml up` 报服务未定义
- CI/CD Pipeline 中引用 `postgres-dev` 的步骤失败

**Phase to address:**
Phase 2（移除 dev 容器）。必须在宿主机 PostgreSQL 完全就绪后才能执行，不能并行。

---

### Pitfall 4: Keycloak 蓝绿部署的数据库 Schema 冲突

**What goes wrong:**
Keycloak 在启动时通过 Liquibase 自动执行数据库 schema 迁移。蓝绿部署时，如果新旧版本共享同一个 PostgreSQL 数据库（当前架构中 `KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak`），新版本启动时会尝试升级 schema。如果升级引入了破坏性变更（如删除列、修改约束），旧版本 Keycloak 会立即崩溃。

更具体的场景：Keycloak 26.2.3 的蓝绿部署中，新旧容器版本相同，所以 schema 冲突风险较低。但当 Keycloak 升级版本时（如 26.2.3 -> 27.x），这个问题是致命的。

**Why it happens:**
- Keycloak 使用 Liquibase 管理数据库 schema，`start` 命令自动运行迁移
- 同一个 `keycloak` 数据库被新旧两个容器共享（当前 `docker-compose.yml` 配置）
- 即使版本相同，两个实例同时写入同一数据库可能导致 Liquibase 锁冲突
- Keycloak 的 Infinispan 缓存默认使用嵌入式模式（本地内存），两个实例的缓存不同步

**How to avoid:**
1. **同版本蓝绿可行**：当前场景（26.2.3 -> 26.2.3）不涉及 schema 变更，蓝绿共存安全
2. **Liquibase 锁处理**：确保旧容器完全停止后再启动新容器（当前 findclass-ssr 的蓝绿模式已经是"停旧启新"，但 Keycloak 可能需要"先启新再停旧"以实现零停机）
3. **升级版本的策略**：当 Keycloak 需要升级时，必须先手动运行 schema 迁移（`kc.sh update`），确认迁移成功后再做蓝绿部署
4. **数据库连接池监控**：蓝绿切换期间，两个实例同时连接数据库可能导致连接数翻倍，需确认 PostgreSQL `max_connections` 足够

**Warning signs:**
- Keycloak 启动日志出现 `Liquibase lock wait timeout`
- Keycloak 日志出现 `ERROR: column xxx does not exist`（schema 不兼容）
- PostgreSQL 连接数接近 `max_connections` 限制
- 用户登录后 session 在切换后丢失

**Phase to address:**
Phase 4（Keycloak 蓝绿部署）。必须在统一基础设施 Pipeline 完成后再实现，因为 Keycloak 蓝绿需要 Pipeline 框架支持。

---

### Pitfall 5: Keycloak 蓝绿部署的会话丢失

**What goes wrong:**
Keycloak 将用户会话存储在嵌入式 Infinispan 缓存中（本地内存，非持久化）。蓝绿切换时，用户的登录会话存储在旧容器内存中，新容器无法访问。切换后所有已登录用户被强制登出，需要重新登录。如果正在 OAuth 流程中的用户（如 Google 登录回调）被切换到新容器，认证流程会中断。

**Why it happens:**
- 当前 Keycloak 配置使用默认的嵌入式 Infinispan（`start` 模式，非 HA）
- 会话数据只存在于单个 JVM 的堆内存中
- nginx 切换 upstream 后，所有请求（包括活跃的 OAuth 回调）立即路由到新容器
- Keycloak 的 `AUTH_SESSION_ID` cookie 指向旧容器的会话，新容器不认识

**How to avoid:**
1. **维护窗口切换**：在低流量时段（凌晨）执行 Keycloak 蓝绿切换，减少活跃会话数量
2. **切换前通知**：Pipeline 中添加人工确认门禁，运维人员确认当前无活跃用户
3. **观察期**：新容器启动后不立即切换，先让新容器预热（连接数据库、加载缓存），再执行 nginx 切换
4. **长期方案（超出 v1.5 范围）**：配置 Keycloak 使用外部 Infinispan 或数据库持久化会话，实现真正的 HA
5. **认证流程保护**：切换前检查 Keycloak 的活跃会话数（通过 Management API），超过阈值则拒绝切换

**Warning signs:**
- 切换后 auth.noda.co.nz 返回 `session_not_found` 错误
- 用户报告被登出
- OAuth 回调返回 `invalid_code` 或 `cookie_not_found`

**Phase to address:**
Phase 4（Keycloak 蓝绿部署）。会话处理策略必须在 Pipeline 设计阶段确定。

---

### Pitfall 6: 基础设施 Pipeline 重启 Pipeline 自身依赖的服务（循环依赖）

**What goes wrong:**
统一基础设施 Pipeline 管理所有服务（postgres、keycloak、noda-ops、nginx）的部署。当 Pipeline 需要重启 PostgreSQL 时，Jenkins 自身也在使用 PostgreSQL（迁移后）。如果 PostgreSQL 重启导致连接中断，Jenkins Pipeline 会失去数据库连接，Pipeline 状态无法更新，最终导致 Pipeline 卡死或失败。更严重的场景：Pipeline 重启 nginx 后，如果 nginx 不恢复，外部访问（包括运维人员通过 Cloudflare 访问 Jenkins）可能中断。

**Why it happens:**
- Jenkins H2 -> PG 迁移后，Jenkins 与 PostgreSQL 建立了硬依赖
- 统一基础设施 Pipeline 的参数化设计允许选择任意服务部署
- PostgreSQL 容器重启时，Jenkins 的数据库连接会断开，Pipeline 执行器可能卡住
- Nginx 是所有外部流量的入口，重启 nginx 会短暂中断所有服务（包括 Cloudflare Tunnel 的健康检查）

**How to avoid:**
1. **PostgreSQL 部署策略**：禁止 Pipeline 重启 Docker 中的 PostgreSQL（因为 Jenkins 依赖它）。PostgreSQL 的维护（版本升级、配置变更）只能手动执行。
2. **Pipeline 服务分类**：
   - **安全重启**：keycloak、noda-ops（Jenkins 不依赖）
   - **条件重启**：nginx（需确认 Jenkins 不在执行 Pipeline）
   - **禁止 Pipeline 重启**：postgres（Jenkins 数据库，手动维护）
3. **nginx 滚动更新**：使用 `nginx -s reload` 而非重启容器（当前架构已支持）
4. **Pipeline 自保护**：在 Pipeline Pre-flight 阶段检查是否有其他 Pipeline 正在运行（`disableConcurrentBuilds` 已配置，但基础设施 Pipeline 和应用 Pipeline 是不同作业）
5. **Jenkins 本地 PG 连接韧性**：配置 Jenkins 数据库连接池的重试策略，允许短暂断连

**Warning signs:**
- Pipeline 执行中途状态变为 `not_built` 或 `aborted`
- Jenkins 日志出现 `org.postgresql.util.PSQLException: Connection refused`
- PostgreSQL 重启后 Jenkins Web UI 无响应

**Phase to address:**
Phase 3（统一基础设施 Pipeline）。Pipeline 设计时必须明确哪些服务可以被 Pipeline 安全管理。

---

### Pitfall 7: 本地开发一键安装脚本的幂等性问题

**What goes wrong:**
一键安装脚本（`setup-local-dev.sh`）需要安装 Homebrew PostgreSQL、配置数据库、创建开发用户和数据库、设置开机自启。如果脚本被多次运行（开发者迭代调试安装过程），非幂等操作会导致问题：数据库已存在时报错、用户已创建时报错、端口被占用时启动失败。更严重的是，Apple Silicon（M1/M2/M3/M4）和 Intel Mac 的 Homebrew 路径不同（`/opt/homebrew` vs `/usr/local`），脚本在一种架构上测试通过后可能在另一种架构上完全失败。

**Why it happens:**
- `createdb` 在数据库已存在时返回错误（非零退出码），导致 `set -e` 脚本中断
- `brew services start postgresql@17` 在服务已运行时的行为与首次启动不同
- Apple Silicon 的 Homebrew 安装路径不同，`PATH` 设置也不同
- PostgreSQL 的 `pg_hba.conf` 和 `postgresql.conf` 配置文件路径在 Homebrew 和 Docker 之间完全不同
- 开发者可能已有旧版 PostgreSQL（如 14.x）在运行，新安装的 17.x 会导致端口冲突

**How to avoid:**
1. **幂等检查函数**：每个操作前先检查是否已完成
   ```bash
   # 幂等创建数据库
   createdb noda_dev 2>/dev/null || echo "数据库已存在，跳过"
   ```
2. **架构检测**：
   ```bash
   ARCH=$(uname -m)
   if [ "$ARCH" = "arm64" ]; then
       HOMEBREW_PREFIX="/opt/homebrew"
   else
       HOMEBREW_PREFIX="/usr/local"
   fi
   eval "$($HOMEBREW_PREFIX/bin/brew shellenv)"
   ```
3. **端口冲突检测**：安装前检查 5432/5433 端口是否被占用
4. **版本检测**：检查已安装的 PostgreSQL 版本，如果已有 17.x 则跳过安装
5. **配置文件模板**：使用模板生成 `pg_hba.conf` 和 `postgresql.conf`，每次运行覆盖（而非追加）
6. **回滚机制**：提供 `setup-local-dev.sh uninstall` 命令清理所有安装产物

**Warning signs:**
- 脚本第二次运行报 `database "noda_dev" already exists` 然后退出
- Intel Mac 上报 `brew: command not found`（PATH 未正确设置）
- `pg_isready` 返回成功但 `psql` 连接被拒（`pg_hba.conf` 配置错误）
- Homebrew PostgreSQL 启动后无法创建 socket 文件（`/tmp` 目录权限问题）

**Phase to address:**
Phase 5（本地开发一键安装脚本）。但幂等性原则应在脚本设计的第一行代码就贯彻。

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Jenkins H2 不迁移，继续使用嵌入式数据库 | 零风险，无迁移工作 | H2 不支持并发写入、无备份机制、数据损坏时无法恢复 | 绝不可接受（PROJECT.md 明确要求迁移） |
| Keycloak 蓝绿跳过会话持久化 | 不引入外部缓存组件 | 每次部署强制所有用户重新登录 | 可接受（当前用户量小，可在维护窗口切换） |
| 一键安装脚本不用 brew bundle | 少维护一个 Brewfile | 脚本维护成本随包数量增长 | 仅在包少于 5 个时 |
| Keycloak 部署时不做版本兼容性检查 | Pipeline 更简单 | Keycloak 升级时蓝绿部署会导致旧实例崩溃 | 仅在同版本重新部署时（当前场景） |
| PostgreSQL 部署通过 Pipeline 自动化 | 减少 DBA 手动操作 | Pipeline 重启 PG 会导致 Jenkins 自身断连 | 绝不可接受——PG 维护必须手动 |
| 跳过 dev 容器数据迁移 | 节省迁移脚本开发时间 | 开发者丢失测试数据 | 绝不可接受（开发体验） |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Jenkins -> 本地 PostgreSQL | JDBC URL 使用 `localhost` 而非 `127.0.0.1`，导致 IPv6 解析问题 | 使用 `jdbc:postgresql://127.0.0.1:5432/jenkins` 明确 IPv4 |
| Jenkins -> PostgreSQL 连接池 | 使用默认连接池大小（100），与 PostgreSQL 的 `max_connections` 冲突 | 配置 Jenkins 连接池大小（如 `maxActive=20`），确保不超过 PG 限制 |
| Homebrew PG -> Docker PG | 用 Homebrew 的 `pg_dump` 备份 Docker 中的数据库，版本不匹配导致备份无法恢复 | 使用 Docker 内的 `pg_dump`：`docker exec postgres-prod pg_dump ...` |
| 本地 PG -> Keycloak 蓝绿 | Keycloak 新旧容器同时连接 PG，连接数翻倍 | 确认 PG `max_connections` 至少为（Keycloak 默认池 * 2 + Jenkins + 余量） |
| 本地 PG -> noda-ops 备份 | 备份脚本硬编码了 Docker 内部主机名 `noda-infra-postgres-prod` | 备份脚本继续使用 Docker 网络内部主机名，本地 PG 仅用于 Jenkins |
| 一键脚本 -> macOS 系统版本 | 脚本使用 `launchctl` API 在不同 macOS 版本上行为不同 | 使用 `brew services` 管理自动启动，不直接操作 `launchctl` |
| 一键脚本 -> Docker Desktop | 脚本假设 Docker Desktop 已安装并运行 | 安装前检查 `docker info` 是否可用，提供安装 Docker Desktop 的指引 |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Jenkins + PG 在同一台服务器 | PostgreSQL 写入延迟增加，Jenkins 构建变慢 | 配置 PG 的 `shared_buffers` 和 `work_mem` 适配服务器内存 | Jenkins 同时执行多个构建时 |
| Keycloak 蓝绿双容器同时运行 | 内存使用翻倍（每个 512MB-1GB），触发 OOM | 确保 Keycloak 蓝绿不是同时运行模式——先启新再停旧，而非同时运行 | 服务器可用内存 < 2GB 时 |
| 本地 PG 的 `fsync` 开启 | 开发环境每次事务提交都刷盘，INSERT 批量操作很慢 | 开发环境的 PG 可关闭 `fsync`（`postgresql.conf: fsync=off`），但生产绝不可关闭 | 批量种子数据导入时 |
| Jenkins Pipeline `dir()` 嵌套 | `dir('noda-apps') { sh '...' }` 在大 workspace 中遍历慢 | 使用绝对路径代替 `dir()` | workspace 超过 1GB 时 |
| Homebrew PG 的 `shared_buffers` 默认值太低 | 默认 128MB，Jenkins 查询构建历史时全表扫描 | 根据服务器内存调整（推荐 25% 总内存） | 构建历史超过 1000 条时 |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| 本地 PG 监听 `0.0.0.0` | 局域网内任何设备可访问数据库 | 配置 `listen_addresses = 'localhost'`，`pg_hba.conf` 只允许本地连接 |
| Jenkins PG 用户使用 `postgres` 超级用户 | Jenkins Pipeline 错误可能 DROP 生产数据库 | 为 Jenkins 创建专用用户（`jenkins_db`），只授权访问 `jenkins` 数据库 |
| 开发环境 `.env` 提交到 Git | 数据库密码泄露 | `.gitignore` 中排除 `.env`，提供 `.env.example` 模板 |
| 一键脚本使用 `curl | bash` 模式 | 供应链攻击风险 | 脚本存储在项目仓库中，通过 `git clone` + `bash` 执行 |
| 移除 dev 容器后忘记清理 Docker volumes | `postgres_dev_data` 卷中可能包含敏感测试数据 | 脚本化 volume 清理，并在移除文档中明确列出 |
| Keycloak 蓝绿切换时旧容器未完全停止 | 旧容器可能仍接受请求，导致数据不一致 | 切换后等待 `stop_grace_period` + 验证旧容器已退出 |

---

## "Looks Done But Isn't" Checklist

- [ ] **Jenkins PG 迁移:** Jenkins 启动正常但构建历史不完整 -- 验证构建数量：对比迁移前后 `SELECT COUNT(*) FROM builds;`
- [ ] **Jenkins PG 迁移:** Pipeline 作业存在但凭据丢失 -- 验证 `withCredentials` 步骤能正确解析所有凭据
- [ ] **本地 PG 安装:** PostgreSQL 运行但 Jenkins 无法连接 -- 验证 `pg_hba.conf` 允许本地 TCP 连接（不只是 Unix socket）
- [ ] **本地 PG 安装:** PostgreSQL 运行但开机不自启 -- 重启电脑后验证 `brew services list` 显示 `postgresql@17 started`
- [ ] **dev 容器移除:** `docker compose -f dev.yml config` 无报错但网络引用断裂 -- 验证所有服务的 `depends_on` 仍然有效
- [ ] **Keycloak 蓝绿:** nginx 切换成功但旧容器未清理 -- 验证 `docker ps` 中只有一个 Keycloak 容器
- [ ] **Keycloak 蓝绿:** 切换后用户可登录但会话不持久 -- 验证 Keycloak 的 `AUTH_SESSION_ID` cookie 在切换后仍有效
- [ ] **基础设施 Pipeline:** Pipeline 可触发但回滚逻辑未测试 -- 手动触发一次故意失败的部署，验证回滚步骤执行正确
- [ ] **一键安装:** 脚本成功但 PostgreSQL 配置未优化 -- 验证 `shared_buffers`、`work_mem` 已根据服务器内存调整
- [ ] **一键安装:** 脚本在 Apple Silicon 上通过但 Intel 上失败（或反过来）-- 两种架构都验证

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Jenkins H2 -> PG 迁移数据丢失 | HIGH（可能无法完整恢复） | 1. 停止 Jenkins 2. 恢复 `JENKINS_HOME` 备份 3. 切回 H2 配置 4. 启动 Jenkins 验证 5. 重新规划迁移 |
| Homebrew PG 版本不匹配 | LOW（安装正确版本） | 1. `brew uninstall postgresql` 2. `brew install postgresql@17` 3. 验证版本匹配 |
| dev 容器移除后开发数据丢失 | MEDIUM（需重新种子） | 1. 从 `postgres_dev_data` volume 导出：`docker run --rm -v postgres_dev_data:/data busybox tar czf - -C /data .` 2. 导入到本地 PG 3. 如果 volume 已删除，使用种子脚本重新初始化 |
| Keycloak 蓝绿导致用户登出 | LOW（用户重新登录） | 1. 无需恢复操作 2. 告知用户重新登录 3. 长期方案：配置会话持久化 |
| Pipeline 重启 PostgreSQL 导致 Jenkins 卡死 | HIGH（需手动介入） | 1. 等待 PostgreSQL 容器恢复运行 2. 重启 Jenkins 服务：`systemctl restart jenkins` 3. 检查 Pipeline 状态 4. 如果 Pipeline 卡死，使用 Jenkins Script Console 中止 |
| 一键脚本在错误架构上运行 | MEDIUM（需清理残留） | 1. `brew uninstall postgresql` 2. 清理数据目录：`rm -rf /opt/homebrew/var/postgresql@17` 3. 用正确架构的脚本重新安装 |
| Keycloak Liquibase 锁冲突 | LOW（清除锁记录） | 1. 连接 keycloak 数据库 2. `DELETE FROM databasechangeloglock WHERE locked = true;` 3. 重启 Keycloak 容器 |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Jenkins H2 -> PG 数据丢失 | Phase 1: 宿主机 PG + 迁移 | 迁移前后构建历史条数一致、凭据可读取 |
| Homebrew PG 版本不匹配 | Phase 1: 宿主机 PG 安装 | `psql --version` 与 Docker PG 版本主版本号一致 |
| dev 容器移除破坏工作流 | Phase 2: 移除 dev 容器 | 移除后本地应用可连接宿主机 PG |
| Keycloak DB Schema 冲突 | Phase 4: Keycloak 蓝绿 | 新旧容器可交替连接同一数据库无报错 |
| Keycloak 会话丢失 | Phase 4: Keycloak 蓝绿 | 切换后活跃用户的会话仍有效（或接受在维护窗口切换） |
| Pipeline 循环依赖 | Phase 3: 基础设施 Pipeline | Pipeline 服务白名单不包含 postgres |
| 一键脚本非幂等 | Phase 5: 一键安装脚本 | 脚本连续运行 3 次不报错 |
| PG 连接池耗尽 | Phase 4: Keycloak 蓝绿 | 蓝绿切换期间 `pg_stat_activity` 连接数在安全范围内 |
| Jenkins PG 连接配置错误 | Phase 1: 迁移 | Jenkins 启动日志无 `PSQLException` |
| dev 数据未迁移 | Phase 2: 移除 dev 容器 | 本地 PG 的 `noda_dev` 数据库有完整的种子数据 |

---

## Phase-Specific Warnings

| Phase | Likely Pitfall | Mitigation |
|-------|---------------|------------|
| Phase 1: 宿主机 PG 安装 | macOS 权限问题导致 PG 无法启动 | 使用 `brew services` 管理，不手动创建数据目录 |
| Phase 1: Jenkins 迁移 | JDBC 驱动版本与 PG 服务端不兼容 | 先测试 JDBC 连接，再执行迁移 |
| Phase 2: 移除 dev 容器 | docker-compose.dev.yml 中其他服务（如 nginx dev 端口 8081）也受影响 | 逐个服务验证，不要批量移除 |
| Phase 3: 统一 Pipeline | Pipeline 参数化导致误操作（如错误地重启了 postgres） | 服务白名单 + 危险操作二次确认 |
| Phase 4: Keycloak 蓝绿 | 复用 findclass-ssr 的蓝绿脚本但不调整 Keycloak 特定参数 | Keycloak 的 `SERVICE_PORT`、`HEALTH_PATH`、`UPSTREAM_NAME` 必须独立配置 |
| Phase 5: 一键安装 | Apple Silicon 的 Rosetta 依赖未安装 | 脚本中检测并安装 Rosetta 2 |
| 全局: 回归测试 | 任何阶段修改 docker-compose.yml 导致生产配置被意外修改 | 修改后运行 `docker compose -f base -f prod config` 验证生产配置完整性 |

---

## Sources

- 项目代码库：`docker/docker-compose.yml`（PostgreSQL/Keycloak 服务定义、环境变量）
- 项目代码库：`docker/docker-compose.dev.yml`（postgres-dev/keycloak-dev 配置、端口映射）
- 项目代码库：`docker/docker-compose.prod.yml`（生产环境安全加固配置）
- 项目代码库：`scripts/setup-jenkins.sh`（Jenkins 安装脚本、端口配置、systemd override）
- 项目代码库：`scripts/manage-containers.sh`（蓝绿容器管理、upstream 切换逻辑）
- 项目代码库：`scripts/pipeline-stages.sh`（Pipeline 阶段函数、健康检查、构建流程）
- 项目代码库：`jenkins/Jenkinsfile`（现有 Pipeline 定义、阶段结构）
- 项目代码库：`config/nginx/snippets/upstream-keycloak.conf`（Keycloak upstream 当前配置）
- 项目代码库：`scripts/init-databases.sh`（数据库初始化脚本）
- `.planning/PROJECT.md`（v1.5 目标、技术栈、架构图）
- Jenkins 官方文档：PostgreSQL 数据库配置、H2 迁移指南
- Keycloak 官方文档：数据库配置、Liquibase 迁移、HA 模式
- Homebrew 文档：PostgreSQL formula、`brew services` 命令、Apple Silicon 路径

---
*Pitfalls research for: Noda v1.5 开发环境本地化 + 基础设施 CI/CD*
*Researched: 2026-04-17*
