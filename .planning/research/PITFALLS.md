# Pre-Prod 环境陷阱研究

**Domain:** Docker Compose + Jenkins 单服务器部署，添加 pre-prod 环境
**Researched:** 2026-05-08
**Confidence:** HIGH（基于对现有代码库的完整分析）

## Critical Pitfalls

### Pitfall 1: Docker 网络别名冲突 — pre-prod 容器与 prod 容器互相覆盖

**What goes wrong:**
docker-compose.app.yml 中 noda-apps 服务使用网络别名 `noda-apps`。如果 pre-prod 容器在同一 `noda-network` 中启动，且也使用别名 `noda-apps`，Docker DNS 会随机解析到 prod 或 pre-prod 容器。Nginx upstream 配置中的 `noda-apps-blue:3000` 能正常工作（因为用的是容器名），但任何通过别名 `noda-apps` 的通信（如 Keycloak 内部回调、容器间服务发现）会不可预测地路由到错误环境。

**Why it happens:**
Docker 网络别名是 per-network 的，同一别名被多个容器注册时，Docker 内置 DNS 返回所有 IP 的轮询结果。开发者习惯从 docker-compose.app.yml 复制配置，容易忘记修改别名。

**How to avoid:**
1. pre-prod 容器使用完全不同的网络别名：`noda-apps-preprod`
2. pre-prod 容器的 env 文件中 `KEYCLOAK_INTERNAL_URL` 必须指向 `http://noda-infra-nginx`（与 prod 相同，因为 Nginx 共享），不要用别名
3. manage-containers.sh 中 `run_container()` 的 `--network-alias` 参数需要根据 SERVICE_NAME 区分 prod 和 preprod
4. 在代码审查中检查：任何 `docker run --network-alias` 必须包含环境标识

**Warning signs:**
- Nginx 日志显示同一域名请求被代理到不同容器
- Pre-prod 测试操作意外影响了 prod 数据库
- `docker exec` 进某个容器 `nslookup noda-apps` 返回多个 IP

**Phase to address:** Phase 1（基础设施准备）— 在创建 pre-prod 容器定义时立即处理

---

### Pitfall 2: Doppler 密钥配置只有 prd — pre-prod 加载了 prod 密钥

**What goes wrong:**
当前 `secrets.sh` 中硬编码 `doppler secrets download --project noda --config prd`。pre-prod Pipeline 如果复用同一脚本，会拉取 prod 密钥。后果：
- pre-prod 的 `DATABASE_URL` 指向 `noda_prod` 而非 `noda_preprod`
- pre-prod 的 `KEYCLOAK_ADMIN_PASSWORD` 与 prod 相同，pre-prod 测试操作可修改 prod Keycloak 配置
- `RESEND_API_KEY` 在 pre-prod 测试中发出真实邮件

**Why it happens:**
Doppler 的 config（环境）概念与项目的环境概念容易混淆。当前只有 `prd` config，没有 `pre` config。开发者可能认为"同一个 Doppler project 下共享密钥没问题"，但 `DATABASE_URL` 等变量必须按环境区分。

**How to avoid:**
两种方案，推荐方案 A：

**方案 A（推荐）：Doppler 新建 `pre` config**
1. 在 Doppler project `noda` 下新建 config `pre`
2. 从 `prd` 继承共享密钥（B2、Cloudflare 等），覆盖环境特定变量（DATABASE_URL、KEYCLOAK_*）
3. 修改 `secrets.sh` 的 `load_secrets()` 接受 `DOPPLER_CONFIG` 参数，默认 `prd`
4. pre-prod Pipeline 设置 `DOPPLER_CONFIG=pre`，Jenkins 用 `doppler-service-token-preprod` 凭据

**方案 B（简单但不推荐）：env 文件覆盖**
1. 保留 Doppler `prd` config 不变
2. pre-prod 的 env 模板文件硬编码 `DATABASE_URL` 指向 `noda_preprod`
3. Doppler 密钥加载后再用 env 文件覆盖关键变量
4. 缺点：密钥分散管理，容易遗漏

**Warning signs:**
- pre-prod 日志中出现 `noda_prod` 而非 `noda_preprod` 的数据库连接
- pre-prod 部署后 prod 数据出现测试数据
- Doppler 中只有 `prd` config，无 `pre` config

**Phase to address:** Phase 1（基础设施准备）— 必须在首次 pre-prod 部署前完成 Doppler 配置

---

### Pitfall 3: Jenkins Pipeline 并发部署导致蓝绿状态文件损坏

**What goes wrong:**
当前 Jenkinsfile.noda-apps 使用 `disableConcurrentBuilds()` 防止同一 Pipeline 并发。但 pre-prod Pipeline 和 prod Pipeline 是不同的 Jenkins Job，它们共享：
- 同一个 Nginx 容器（reload 操作）
- 同一个 Docker daemon（构建资源竞争）
- 同一个 manage-containers.sh 脚本（全局变量和临时文件）

如果两个 Pipeline 同时执行：
1. prod Pipeline 执行 `update_upstream` 写入 upstream-findclass.conf
2. pre-prod Pipeline 紧接着也执行 `update_upstream` 写入 upstream-findclass-preprod.conf
3. 两者都调用 `nginx -s reload`，第二次 reload 可能在第一次的流量切换尚未完全生效时触发
4. 更危险的是：如果 pre-prod 和 prod 的 manage-containers.sh 使用相同的 `NGINX_CONTAINER` 变量，`docker exec nginx -t` 可能检测到不完整配置

**Why it happens:**
`disableConcurrentBuilds()` 只保护同一 Job 内的并发，不保护跨 Job 并发。开发者在紧急 hotfix 场景下可能同时触发 prod 和 pre-prod 部署。

**How to avoid:**
1. **Jenkins 资源锁：** 使用 `lock('nginx-reload')` 包裹 Switch 阶段，确保同一时间只有一个 Pipeline 在执行 nginx reload
   ```groovy
   stage('Switch') {
       steps {
           lock(resource: 'nginx-reload', inversePrecedence: true) {
               sh '...'
           }
       }
   }
   ```
2. **或者：** 使用 `lock('docker-deploy')` 锁住整个 Deploy → Switch → Verify 链路，更保守但更安全
3. **在 pipeline_switch() 中添加文件锁：** 用 `flock` 确保同一时间只有一个进程操作 nginx
4. **pre-prod Pipeline 不需要 CDN Purge 阶段**（pre-prod 域名通常不需要 CDN 缓存清除），减少与 prod Pipeline 的冲突窗口

**Warning signs:**
- Jenkins 构建日志中出现 `nginx: [emerg]` 错误
- 部署后 `active-env` 文件内容与预期不符
- 两个 Pipeline 的 Verify 阶段都报告失败

**Phase to address:** Phase 3（Jenkins Pipeline）— 在创建 pre-prod Pipeline 时立即加入锁机制

---

### Pitfall 4: Keycloak noda-preprod Realm 的 Google OAuth redirect URI 遗漏

**What goes wrong:**
Keycloak 的 Google Identity Provider 配置中，`Valid Redirect URIs` 必须包含所有可能的回调地址。遗漏任何一个都会导致：
1. 用户在 pre-prod 点击 Google 登录 -> Google 回调到 `pre.auth.noda.co.nz`
2. Keycloak 报错 `Invalid parameter: redirect_uri`
3. 用户看到白屏或错误页面

根据 CLAUDE.md 的历史记录，这个项目已经多次因为 redirect URI 问题导致登录失败（Phase 16 的 3 层 OAuth 问题）。Pre-prod 增加了 4 个新域名，每个都需要正确的 redirect URI。

**Why it happens:**
Google Cloud Console 的 OAuth 配置需要手动添加 authorized redirect URIs，容易遗漏。Keycloak realm 的 client 配置中也需要添加 Valid Redirect URIs。两层配置都需要同步更新。

**How to avoid:**
创建检查清单，在 pre-prod 首次部署前逐项验证：

1. **Google Cloud Console:**
   - `https://pre.auth.noda.co.nz/*`
   - `https://pre.class.noda.co.nz/*`

2. **Keycloak noda-preprod realm 的 noda-frontend-preprod client:**
   - `Valid Redirect URIs`: `https://pre.class.noda.co.nz/*`, `https://pre.auth.noda.co.nz/*`
   - `Web Origins`: `https://pre.class.noda.co.nz`, `https://pre.auth.noda.co.nz`

3. **Docker 构建参数（Dockerfile）：**
   - `NEXT_PUBLIC_KEYCLOAK_URL=https://pre.auth.noda.co.nz`（不能是 auth.noda.co.nz）
   - `NEXT_PUBLIC_KEYCLOAK_REALM=noda-preprod`
   - `NEXT_PUBLIC_KEYCLOAK_CLIENT_ID=noda-frontend-preprod`
   - 这些是构建时参数，改了必须重新 build，运行时环境变量无法覆盖（CLAUDE.md 已记录此教训）

4. **创建自动化验证脚本：** 部署后 curl 检查 `https://pre.auth.noda.co.nz/realms/noda-preprod/.well-known/openid-configuration` 确认 realm 可达

**Warning signs:**
- 登录时浏览器 URL 出现 `localhost:8080` 或 `auth.noda.co.nz`（而非 `pre.auth.noda.co.nz`）
- Keycloak 日志: `error=invalid_redirect_uri`
- Google OAuth 回调后白屏

**Phase to address:** Phase 1（Keycloak realm 配置）— 在部署任何 pre-prod 应用前必须完成

---

### Pitfall 5: 单服务器内存不足 — 4 个 noda-apps 容器同时运行 OOM

**What goes wrong:**
pre-prod-environment-plan.md 评估增量约 1GB（pre-prod 的两个蓝绿容器）。但实际情况更复杂：
- 当前 prod 已有 `noda-apps-blue` + `noda-apps-green`（限制各 1G）
- 加上 pre-prod 的 `noda-apps-preprod-blue` + `noda-apps-preprod-green`（各 1G）
- 再加上 PostgreSQL（限制 2G）、Keycloak（限制 1G）、Nginx、noda-ops、Jenkins（JVM 默认堆内存）
- 蓝绿部署切换期间，新旧容器短暂同时运行（约 30-60 秒 health check）
- 如果 prod 和 pre-prod 同时处于蓝绿切换的 overlap 窗口，同时运行 6 个 noda-apps 容器

在 plan 中标注"~1GB 增量"只考虑了 pre-prod 平时运行状态（1 个活跃容器），没考虑：
- 蓝绿切换的 overlap 窗口
- Jenkins 构建时的内存消耗（pnpm install + next build）
- PostgreSQL 在备份/恢复时的内存峰值

**Why it happens:**
资源评估通常只看稳态，忽略了部署过程中的瞬时资源峰值。加上 Docker 的 memory limit 是硬限制，超了直接 OOM kill。

**How to avoid:**
1. **降低 pre-prod 容器 memory limit**：prod 是 1G，pre-prod 可以降到 512M（不需要处理真实流量，只做功能验证）
2. **pre-prod 蓝绿容器不要同时运行**：pre-prod 可以用"停旧启新"策略而非蓝绿，接受短暂不可用（pre-prod 不需要零停机）
3. **添加部署前内存检查到 Pipeline Pre-flight 阶段**：
   ```bash
   available_mem=$(free -m | awk '/Mem:/{print $4}')
   if [ "$available_mem" -lt 1536 ]; then
       log_error "可用内存不足 1.5GB，中止部署"
       exit 1
   fi
   ```
4. **Jenkins 构建 Node.js 限制内存**：`NODE_OPTIONS=--max-old-space-size=1024`
5. **Pre-prod 不使用蓝绿部署，只用单容器**：启动新容器 -> 验证 -> 停旧容器 -> nginx reload。省掉一个容器的内存开销。

**Warning signs:**
- `dmesg` 中出现 `Out of memory: Killed process`
- Docker `docker inspect` 显示容器 `OOMKilled=true`
- 服务器响应变慢，SSH 登录延迟

**Phase to address:** Phase 1（基础设施准备）— 必须在首次 pre-prod 容器启动前确认资源上限

---

### Pitfall 6: 镜像清理脚本误删 pre-prod 镜像

**What goes wrong:**
image-cleanup.sh 的 `cleanup_by_date_threshold()` 通过容器名前缀匹配来识别"在用镜像"：
```bash
container_names=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^${image_name}" || true)
```
如果 pre-prod 和 prod 都使用镜像 `noda-apps:latest`（同一个镜像名，不同标签），清理逻辑可能：
1. prod Pipeline 的 cleanup 阶段只检查 `noda-apps-*` 前缀的容器
2. 发现 `noda-apps-preprod-blue` 正在使用某镜像，正确跳过
3. 但 `noda-apps-preprod-blue` 停止后（pre-prod 不活跃容器），其镜像被 prod Pipeline 的 cleanup 误删
4. 下次 pre-prod 部署找不到镜像，需要重新构建

**Why it happens:**
镜像名 `noda-apps` 同时用于 prod 和 pre-prod。清理脚本的 "in-use" 检测基于容器名前缀匹配，逻辑复杂且脆弱。

**How to avoid:**
1. **pre-prod 使用不同的镜像名**：`noda-apps-preprod:latest` 而非 `noda-apps:latest`。清理脚本按镜像名隔离，互不影响
2. **pipeline_build() 中根据 SERVICE_NAME 区分**：`-t noda-apps-preprod:${git_sha}`
3. **Promote to Prod 时重新 tag 镜像**：`docker tag noda-apps-preprod:xxx noda-apps:xxx`

**Warning signs:**
- Pre-prod 部署日志: `Unable to find image 'noda-apps-preprod:xxx' locally`
- `docker images` 中 pre-prod 的镜像标签消失
- Promote to Prod 失败：找不到源镜像

**Phase to address:** Phase 3（Jenkins Pipeline）— 在定义 pre-prod 构建和 Promote 流程时同步处理

---

### Pitfall 7: Nginx upstream include 文件写入竞争 — prod 和 pre-prod 切换互相覆盖

**What goes wrong:**
prod 和 pre-prod 使用不同的 upstream 配置文件：
- `upstream-findclass.conf`（prod）
- `upstream-findclass-preprod.conf`（pre-prod）

`update_upstream()` 函数在写入时使用了临时文件 + mv 的原子操作，这本身没问题。但 `reload_nginx()` 会重载所有 Nginx 配置。如果 pre-prod 的 upstream 文件在 prod 切换的瞬间处于中间状态（比如新容器还没启动完成），`nginx -t` 可能检测到无效的 upstream 目标。

更具体地，manage-containers.sh 中 `update_upstream()` 只写 prod 的 upstream 文件。如果 pre-prod 复用这个函数，需要确保它写的是 `upstream-findclass-preprod.conf`。如果 `UPSTREAM_CONF` 变量传错，pre-prod 切换可能写入 prod 的 upstream 文件。

**Why it happens:**
`update_upstream()` 使用 `$UPSTREAM_CONF` 环境变量决定写入哪个文件。这个变量默认指向 prod 配置。如果 pre-prod Pipeline 忘记设置 `UPSTREAM_CONF`，会直接修改 prod 的 upstream。

**How to avoid:**
1. **update_upstream() 添加防护检查**：在写入前验证文件路径包含预期环境标识
   ```bash
   if [ "$SERVICE_NAME" = "noda-apps-preprod" ]; then
       echo "$upstream_content" | grep -q "preprod" || { log_error "pre-prod upstream 不应包含 prod 容器名"; exit 1; }
   fi
   ```
2. **pre-prod Jenkinsfile 必须设置 UPSTREAM_CONF**：`UPSTREAM_CONF = "${PROJECT_ROOT}/config/nginx/snippets/upstream-findclass-preprod.conf"`
3. **添加 nginx 配置完整性测试**：Switch 阶段在 reload 前用 `nginx -t` 验证（已实现），但还应验证 upstream 目标容器确实在运行
4. **文件权限分离**：prod 和 pre-prod 的 upstream 配置文件可以设置不同的文件权限（虽然在同一台机器上意义有限）

**Warning signs:**
- prod 域名突然指向 pre-prod 容器
- `nginx -t` 报错后 Pipeline 回滚，但 upstream 文件已被修改
- `cat upstream-findclass.conf` 显示 `noda-apps-preprod-*` 容器名

**Phase to address:** Phase 2（Nginx 路由）— 在创建 pre-prod upstream 配置时建立防护

---

### Pitfall 8: Hotfix 跳过 Pre-prod 后镜像不同步

**What goes wrong:**
hotfix 流程设计：直接部署到 prod（跳过 pre-prod），事后补走 pre-prod 验证。可能出现的问题：
1. Hotfix 部署到 prod 后，pre-prod 仍然运行旧版本
2. "事后补走 pre-prod" 从未执行（人的遗忘）
3. 下一次常规部署时，Pipeline 从 main 分支构建新镜像部署到 pre-prod，但 pre-prod 数据库的 schema 已经被 prod 的 hotfix 迁移脚本改变（如果 hotfix 包含 DB migration）
4. 新镜像在 pre-prod 的数据库上运行迁移失败，因为迁移版本号已经被 hotfix 更新过

**Why it happens:**
hotfix 流程打破了对称性——prod 和 pre-prod 的版本不一致。如果 hotfix 包含数据库迁移，pre-prod 数据库（`noda_preprod`）的迁移历史可能与 prod 不同步。

**How to avoid:**
1. **Hotfix 后强制触发 pre-prod 部署**：在 hotfix Jenkinsfile 的 `post.success` 中自动触发 pre-prod Pipeline
   ```groovy
   post {
       success {
           build job: 'noda-apps-preprod', wait: false
       }
   }
   ```
2. **Pre-prod 数据库定期从 prod 同步**（可选，按需）：在 pre-prod 部署前从最新的 prod 备份恢复 `noda_preprod` 数据库
3. **数据库迁移标记**：pre-prod 部署前检查迁移状态，如果 `noda_preprod` 的迁移版本号与代码不匹配，先同步数据库再部署
4. **紧急 hotfix 标准操作流程文档化**：包括"必须补走 pre-prod"这一步骤

**Warning signs:**
- pre-prod 日志中出现数据库 migration 错误
- pre-prod 和 prod 的 `/api/health` 返回不同版本号
- `noda_preprod` 数据库中 `_prisma_migrations` 表与 `noda_prod` 不一致

**Phase to address:** Phase 3（Jenkins Pipeline）— 在创建 hotfix 流程时强制包含 pre-prod 同步步骤

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| pre-prod 复用 prod 的 Doppler config | 减少配置工作，快速启动 | 密钥泄露到错误环境，prod 数据被 pre-prod 操作破坏 | 绝不可接受 |
| pre-prod 不做蓝绿，直接停旧启新 | 省内存和复杂度 | pre-prod 部署时有短暂不可用窗口 | 可接受（pre-prod 不面向真实用户） |
| pre-prod 和 prod 共享同一镜像名 | Promote 流程简单（不需要 retag） | 镜像清理逻辑复杂，容易误删 | 不可接受（应使用不同镜像名） |
| pre-prod 不做健康检查 | 加快部署速度 | 不验证就 Promote 到 prod，风险传导 | 不可接受 |
| pre-prod 容器不加 memory limit | 避免配置工作 | pre-prod 容器异常时吃掉 prod 的内存 | 绝不可接受 |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Keycloak Realm | 在 prod realm 中添加 pre-prod client | 创建独立 `noda-preprod` realm，完全隔离用户和配置 |
| Keycloak Google OAuth | 只在 Google Cloud Console 添加 URI，忘记在 Keycloak client 中添加 | 两处都必须添加，缺一不可 |
| Cloudflare Tunnel | 添加 DNS CNAME 后忘记在 Tunnel 配置中添加路由 | DNS CNAME + Tunnel ingress 规则都需要更新 |
| Cloudflare CDN | pre-prod 域名开启 CDN 缓存，测试时看到旧版本 | pre-prod 域名在 Cloudflare 中关闭缓存（或设置极短 TTL） |
| Docker Network | pre-prod 容器使用与 prod 相同的网络别名 | 使用 `noda-apps-preprod` 等带环境标识的别名 |
| Nginx Upstream | pre-prod server block 忘记 `resolver 127.0.0.11 valid=30s;` | 所有使用变量 upstream 的 server block 都必须添加 resolver |
| Jenkins Credentials | pre-prod Pipeline 使用 prod 的 `doppler-service-token` | 创建独立的 `doppler-service-token-preprod` 凭据 |
| Backup System | noda-ops 备份只备份 `noda_prod`，不包含 `noda_preprod` | 更新备份脚本同时备份 `noda_preprod`（或确认不需要备份 pre-prod） |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| 6 个 noda-apps 容器同时运行 | OOM kill、服务器卡死 | pre-prod 用单容器、降低 memory limit、添加部署前内存检查 | prod + pre-prod 同时蓝绿切换 |
| Jenkins 构建 + pre-prod 部署并行 | 构建超时、pnpm install 失败 | `NODE_OPTIONS=--max-old-space-size=1024`、限制并发构建 | 内存 < 2GB 可用时 |
| pre-prod 数据库迁移阻塞 prod PostgreSQL | prod API 变慢、连接超时 | pre-prod 迁移在低峰期执行、添加 statement_timeout | 大型 ALTER TABLE 操作 |
| Docker 磁盘空间耗尽 | 构建失败、容器无法启动 | 镜像清理策略覆盖 pre-prod、添加部署前磁盘检查 | 镜像 > 20GB（prod + pre-prod 各保留多个版本） |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| pre-prod 容器可以连接 `noda_prod` 数据库 | 测试操作破坏生产数据 | Docker 网络层面：pre-prod 容器不挂载 `noda-network` 的 `postgres` 别名；或者 PostgreSQL 使用 pg_hba.conf 限制只允许特定用户/IP 连接 `noda_prod` |
| pre-prod 域名公网可访问且无认证 | 任何人可以访问未发布的功能 | Cloudflare Access 保护 pre-prod 域名（或使用 HTTP Basic Auth），只允许团队成员访问 |
| pre-prod Keycloak realm 使用相同 admin 密码 | 误操作修改 prod 用户 | noda-preprod realm 使用不同的管理员凭据 |
| Doppler service token 权限过大 | pre-prod token 可以访问 prod 密钥 | pre-prod token 只授权 `config=pre` 的读取权限 |
| pre-prod 日志包含敏感数据 | 测试时使用的真实数据泄露 | pre-prod 使用脱敏数据，不导入真实用户数据 |

## "Looks Done But Isn't" Checklist

- [ ] **DNS 可达:** 添加了 Cloudflare CNAME 和 Tunnel 路由，但没有验证从外部能否访问 `pre.class.noda.co.nz`（Tunnel token 未更新、ingress 规则语法错误等）
- [ ] **Keycloak realm 创建:** 创建了 `noda-preprod` realm，但没有配置 Google Identity Provider（只能用用户名密码登录，无法测试 OAuth 流程）
- [ ] **Nginx server block:** 添加了 `pre.class.noda.co.nz` 的 server block，但忘了 `resolver 127.0.0.11 valid=30s;`（变量 upstream 无法解析）
- [ ] **数据库创建:** 创建了 `noda_preprod` 数据库，但没有运行初始 migration（表结构不存在，应用启动即报错）
- [ ] **Promote 流程:** 创建了 Promote Pipeline，但使用的是"重新构建"而非"使用同一镜像"（构建结果可能不同，验证失去意义）
- [ ] **Hotfix 文档:** 写了 hotfix SOP，但没有自动化步骤确保 pre-prod 同步（依赖人记得手动操作）
- [ ] **备份覆盖:** 备份脚本只备份 `noda_prod`，`noda_preprod` 数据库无人备份（虽然影响小，但不一致）
- [ ] **CDN 缓存:** pre-prod 域名在 Cloudflare 开启了 CDN 缓存，更新后看不到变化（误以为部署失败）
- [ ] **Jenkins disableConcurrentBuilds:** 每个 Pipeline 都设置了 `disableConcurrentBuilds()`，但不同 Pipeline 之间没有互斥锁

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| 网络别名冲突（流量串环境） | LOW | 停止 pre-prod 容器，修改别名，重启容器 |
| Doppler 密钥指向 prod 数据库 | HIGH | 检查 pre-prod 操作是否修改了 prod 数据，必要时从备份恢复 `noda_prod`；修正 Doppler config |
| Pipeline 并发导致 Nginx 配置错乱 | MEDIUM | 手动检查 upstream-*.conf 文件内容，手动 reload nginx |
| Google OAuth redirect URI 遗漏 | LOW | 在 Google Cloud Console 和 Keycloak 中添加遗漏的 URI |
| OOM Kill | MEDIUM | 调整 memory limit，停止不必要的容器，重启被 kill 的容器 |
| 镜像被误删 | LOW | 重新构建镜像（约 5-10 分钟） |
| upstream 文件写入错误环境 | HIGH | 手动修正 upstream 文件，reload nginx，检查 prod 流量是否受影响 |
| Hotfix 后 pre-prod 版本落后 | MEDIUM | 手动触发 pre-prod 部署，检查数据库迁移状态 |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 网络别名冲突 | Phase 1: 基础设施准备 | `docker network inspect noda-network` 确认 prod 和 pre-prod 别名不同 |
| Doppler 密钥环境隔离 | Phase 1: 基础设施准备 | `doppler secrets --config pre` 确认 DATABASE_URL 指向 `noda_preprod` |
| Pipeline 并发锁 | Phase 3: Jenkins Pipeline | 同时触发两个 Pipeline，验证第二个等待第一个完成 |
| Keycloak OAuth redirect URI | Phase 1: Keycloak 配置 | 浏览器测试完整 Google 登录流程 |
| 内存不足 | Phase 1: 基础设施准备 | 启动所有容器后检查 `free -m` 和 `docker stats` |
| 镜像清理冲突 | Phase 3: Jenkins Pipeline | 部署后检查 `docker images` 确认 pre-prod 镜像未被删除 |
| Upstream 写入防护 | Phase 2: Nginx 路由 | 手动修改 UPSTREAM_CONF 变量测试防护逻辑 |
| Hotfix 同步 | Phase 3: Jenkins Pipeline | 模拟 hotfix 流程，验证 pre-prod 是否自动触发部署 |

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| PostgreSQL noda_preprod 创建 | 忘记运行 Prisma migration，数据库空表 | 创建后立即运行 `pnpm prisma migrate deploy` |
| Keycloak realm 导出/导入 | 导出 prod realm 后忘记修改 hostname 和 client ID | 导入后逐项检查 KC_HOSTNAME、redirect URIs、client ID |
| Nginx 新 server block | 忘记 `resolver 127.0.0.11 valid=30s;` 导致变量 upstream 无法解析 | 每个使用 `$variable_upstream` 的 server block 都必须包含 resolver |
| Cloudflare Tunnel 配置修改 | 修改 tunnel config 后忘记重启 noda-ops 容器 | 配置变更后必须 `docker restart noda-ops` |
| Jenkinsfile 创建 | 从 prod Jenkinsfile 复制后忘记修改 ACTIVE_ENV_FILE 和 UPSTREAM_CONF | 使用 diff 对比两个 Jenkinsfile，确认所有环境特定参数 |
| manage-containers.sh 参数化 | SERVICE_NAME 设为 `noda-apps-preprod` 但 get_env_template() 找不到 env 文件 | 创建 `env-noda-apps-preprod.env` 模板文件 |
| Promote to Prod | Promote 使用 `noda-apps-preprod` 镜像但 prod upstream 期望 `noda-apps` 容器名 | Promote 时 `docker tag` 重命名镜像，或 Promote 流程重新 tag |
| 首次端到端验证 | 只验证了 HTTP 200，没有验证 Google 登录完整流程 | 创建端到端验证清单：页面加载 -> Google 登录 -> API 调用 -> 数据写入 |

## Sources

- 项目代码分析: `scripts/manage-containers.sh`, `scripts/pipeline-stages.sh`, `scripts/lib/secrets.sh`, `scripts/lib/image-cleanup.sh`, `scripts/lib/cleanup.sh`
- Jenkins Pipeline 分析: `jenkins/Jenkinsfile.noda-apps`, `jenkins/Jenkinsfile.noda-site`, `jenkins/Jenkinsfile.prod-deploy`
- Docker Compose 分析: `docker/docker-compose.app.yml`, `docker/docker-compose.yml`, `docker/docker-compose.prod.yml`
- Nginx 配置分析: `config/nginx/conf.d/default.conf`, `config/nginx/snippets/upstream-findclass.conf`
- 历史问题记录: CLAUDE.md（Phase 16 OAuth 修复、端口收敛记录）
- Pre-prod 方案分析: `.planning/notes/pre-prod-environment-plan.md`

---
*Pitfalls research for: Pre-Prod 环境添加到现有 Docker Compose + Jenkins 基础设施*
*Researched: 2026-05-08*
