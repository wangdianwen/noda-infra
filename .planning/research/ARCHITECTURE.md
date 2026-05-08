# Architecture Research: Pre-Prod 环境集成

**Domain:** Pre-prod 环境架构设计 -- 在现有单 prod 环境基础上增加 pre-prod 验证环境
**Researched:** 2026-05-08
**Confidence:** HIGH

## 系统总览

```
                              Cloudflare CDN
                                   |
                        Cloudflare Tunnel (noda-ops)
                                   |
                            noda-infra-nginx:80
                          /                    \
            prod 域名路由                    pre-prod 域名路由
         class.noda.co.nz               pre.class.noda.co.nz
         auth.noda.co.nz                pre.auth.noda.co.nz
         noda.co.nz                     pre.noda.co.nz
         admin.noda.co.nz               pre.admin.noda.co.nz
                |                              |
    upstream-findclass.conf        upstream-findclass-preprod.conf
    $findclass_upstream            $findclass_preprod_upstream
    $www_upstream                  $www_preprod_upstream
    $auth_app_upstream             $auth_app_preprod_upstream
    $admin_upstream                $admin_preprod_upstream
    $admin_api_upstream            $admin_api_preprod_upstream
                |                              |
    noda-apps-blue:3000            noda-apps-preprod-blue:3000
    noda-apps-green:3000           noda-apps-preprod-green:3000
               \                     /
                \                   /
            noda-network (共享外部网络)
                    |           |
         noda-infra-postgres-prod:5432
           ├── noda_prod      (prod 数据库)
           └── noda_preprod   (pre-prod 数据库)

         keycloak-blue:8080 / keycloak-green:8080
           ├── noda realm        (prod 认证)
           └── noda-preprod realm (pre-prod 认证)
```

### 组件职责

| 组件 | 职责 | 变更类型 |
|------|------|----------|
| noda-infra-postgres-prod | 共享 PostgreSQL 实例，新增 noda_preprod 数据库 | **修改** (init-databases.sh) |
| keycloak-blue/green | 共享 Keycloak 实例，新增 noda-preprod realm | **修改** (init-realm.sh + 手动配置) |
| noda-infra-nginx | 共享 Nginx，新增 pre-prod server blocks + upstream | **修改** (default.conf + 新 snippet) |
| noda-apps-preprod-blue/green | **新增** pre-prod 应用容器，独立蓝绿部署 | **新增** |
| Cloudflare Tunnel | 添加 pre-prod 域名路由 | **修改** (noda-ops config) |
| manage-containers.sh | 参数化支持 preprod 环境 | **修改** |
| Jenkinsfile.noda-apps | 参数化支持 preprod + promote 流程 | **修改** |

## 1. 容器命名与标签规范

### 命名约定

当前 prod 容器命名模式: `{SERVICE_NAME}-{blue|green}` (如 `noda-apps-blue`)

pre-prod 容器命名: `{SERVICE_NAME}-preprod-{blue|green}` (如 `noda-apps-preprod-blue`)

**理由：**
- 容器名在 Docker 网络中作为 DNS 名称，`noda-apps-preprod-blue` 可被 Nginx 直接 resolver 解析
- 前缀 `noda-apps` 保持一致，`docker ps` 输出自然分组
- `preprod` 作为中间段，避免与蓝绿后缀混淆
- 与现有 `keycloak-blue/green` 模式对齐，不需要 `keycloak-preprod`（Keycloak 共享单实例）

### 标签体系

```
# 现有标签（prod 容器）
noda.service-group=apps
noda.environment=prod
noda.blue-green=blue|green

# 新增标签（pre-prod 容器）
noda.service-group=apps
noda.environment=preprod
noda.blue-green=blue|green
```

**manage-containers.sh 修改点：**
- `run_container()` 中的 `noda.environment` 标签当前硬编码为 `prod`（第 242 行）
- 需要改为 `NODA_ENVIRONMENT` 环境变量控制，默认 `prod`，pre-prod 设为 `preprod`
- `com.docker.compose.project` 标签也需参数化：prod 用 `noda-apps`，pre-prod 用 `noda-apps-preprod`

### 查询过滤示例

```bash
# 查看所有 prod 容器
docker ps --filter label=noda.environment=prod

# 查看所有 pre-prod 容器
docker ps --filter label=noda.environment=preprod

# 查看 pre-prod 活跃容器
docker ps --filter label=noda.environment=preprod --filter label=noda.blue-green=blue
```

## 2. 状态文件管理

### 当前状态文件

```
/opt/noda/active-env              → noda-apps prod 蓝绿状态 (blue/green)
/opt/noda/active-env-keycloak     → keycloak 蓝绿状态 (blue/green)
```

### 新增状态文件

```
/opt/noda/active-env-preprod      → noda-apps pre-prod 蓝绿状态 (blue/green)
```

**关键设计决策：** pre-prod 有独立的状态文件，prod 和 pre-prod 的蓝绿切换互不影响。prod 在 blue 时，pre-prod 可以在 green，反之亦然。

**manage-containers.sh 参数映射：**

| 环境 | SERVICE_NAME | ACTIVE_ENV_FILE | UPSTREAM_CONF |
|------|-------------|-----------------|---------------|
| prod | noda-apps | /opt/noda/active-env | config/nginx/snippets/upstream-findclass.conf |
| pre-prod | noda-apps-preprod | /opt/noda/active-env-preprod | config/nginx/snippets/upstream-findclass-preprod.conf |
| keycloak | keycloak | /opt/noda/active-env-keycloak | config/nginx/snippets/upstream-keycloak.conf |

**注意：** SERVICE_NAME 从 `noda-apps` 变为 `noda-apps-preprod` 会影响：
1. `get_container_name()` 输出: `noda-apps-preprod-blue` -- 正确
2. `get_env_template()` 输出: `env-noda-apps-preprod.env` -- 正确（需要创建此文件）
3. `update_upstream()` 中的硬编码 upstream 内容 -- 需要修改（见第 3 节）

## 3. Nginx Upstream 配置

### 当前模式分析

现有 Nginx 使用 `set $variable` + `resolver 127.0.0.11` 实现动态 DNS 解析。upstream 变量定义在独立 snippet 文件中，由 `update_upstream()` 在蓝绿切换时写入。

当前 `upstream-findclass.conf` 内容：
```nginx
set $findclass_upstream noda-apps-blue:3000;
set $www_upstream noda-apps-blue:3002;
set $auth_app_upstream noda-apps-blue:3004;
set $admin_upstream noda-apps-blue:3006;
set $admin_api_upstream noda-apps-blue:3011;
```

### 推荐方案：独立 snippet 文件 + 独立 server blocks

**新增文件：** `config/nginx/snippets/upstream-findclass-preprod.conf`
```nginx
set $findclass_preprod_upstream noda-apps-preprod-blue:3000;
set $www_preprod_upstream noda-apps-preprod-blue:3002;
set $auth_app_preprod_upstream noda-apps-preprod-blue:3004;
set $admin_preprod_upstream noda-apps-preprod-blue:3006;
set $admin_api_preprod_upstream noda-apps-preprod-blue:3011;
```

**变量命名规则：** 在现有变量名后插入 `_preprod`，如 `$findclass_upstream` 变为 `$findclass_preprod_upstream`。这避免了变量名冲突（Nginx 不允许在同一 http 块中重复定义 `set` 变量）。

**为什么不用同一组变量 + 条件判断：**
- Nginx 的 `set` 变量是全局的，同一变量不能在不同 server block 中赋予不同值
- 条件判断（`if`）在 Nginx 中是反模式（"if is evil"）
- 独立变量名是最简单、最可靠的方案

**为什么不用独立的 upstream 块（`upstream {}`）：**
- 现有架构已经使用 `set` 变量 + resolver 方案
- upstream 块不支持 `set` 变量动态修改，蓝绿切换需要 reload
- 保持一致性，避免在同一 Nginx 实例中混用两种模式

### manage-containers.sh 修改：update_upstream()

当前 `update_upstream()` 函数（第 268-303 行）对 `noda-apps` 和 `keycloak` 有硬编码的 upstream 内容生成逻辑。需要扩展支持 `noda-apps-preprod`。

**推荐方案：** 通过环境变量 `UPSTREAM_VARIABLES` 控制生成的 upstream 内容，而非在 bash 函数中硬编码服务名判断。

```bash
# 环境变量定义（wrapper 中设置）
UPSTREAM_VARIABLES="${UPSTREAM_VARIABLES:-findclass:3000 www:3002 auth_app:3004 admin:3006 admin_api:3011}"

# update_upstream() 中动态生成
# 格式：变量名:端口，空格分隔
for pair in $UPSTREAM_VARIABLES; do
    var_name="${pair%%:*}"
    port="${pair##*:}"
    echo "set \$${var_name}_upstream ${container_name}:${port};"
done
```

这样 keycloak 仍然可以设置 `UPSTREAM_VARIABLES="keycloak:8080"`（但变量名不同，keycloak 用 `$keycloak_upstream`），需要进一步处理。

**更实用的方案：** 保持当前 if/else 结构，增加 `noda-apps-preprod` 分支。pre-prod 的 upstream 变量名加 `_preprod` 后缀。

```bash
# 在 update_upstream() 中增加
if [ "$SERVICE_NAME" = "noda-apps-preprod" ]; then
    upstream_content="# noda-apps pre-prod upstream 变量
set \$findclass_preprod_upstream ${container_name}:3000;
set \$www_preprod_upstream ${container_name}:3002;
set \$auth_app_preprod_upstream ${container_name}:3004;
set \$admin_preprod_upstream ${container_name}:3006;
set \$admin_api_preprod_upstream ${container_name}:3011;"
fi
```

### 新增 Nginx Server Blocks

在 `config/nginx/conf.d/` 下新增独立配置文件，或在 `default.conf` 中追加。推荐在 `default.conf` 中追加，因为：

1. 共享的 `proxy-common.conf`、`proxy-websocket.conf` snippets 已经 include
2. 共享 `forwarded_proto`/`forwarded_port` map 块
3. 共享自定义错误页
4. 一个文件更容易维护路由逻辑的对应关系

**新增 server blocks（追加到 default.conf）：**

```nginx
# ============================================
# Pre-prod Auth 服务域名
# ============================================
server {
    listen 80;
    server_name pre.auth.noda.co.nz;

    include /etc/nginx/snippets/upstream-findclass-preprod.conf;
    include /etc/nginx/snippets/upstream-keycloak.conf;  # 共享 Keycloak

    client_max_body_size 100M;

    # 安全头
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "ALLOW-FROM https://pre.class.noda.co.nz" always;
    add_header Content-Security-Policy "frame-ancestors 'self' https://pre.class.noda.co.nz;" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Auth App 用户页面 → pre-prod 容器
    location = / {
        proxy_pass http://$auth_app_preprod_upstream;
        include /etc/nginx/snippets/proxy-websocket.conf;
    }
    # ... 其他 auth 路由，与 prod 结构相同但使用 _preprod upstream 变量

    # Keycloak 默认兜底（共享 Keycloak，但 realm 路径不同）
    location / {
        proxy_pass http://$keycloak_upstream;
        include /etc/nginx/snippets/proxy-websocket.conf;
    }
}

# ============================================
# Pre-prod FindClass 应用
# ============================================
server {
    listen 80;
    server_name pre.class.noda.co.nz;

    include /etc/nginx/snippets/upstream-findclass-preprod.conf;

    client_max_body_size 100M;

    # ... 与 prod class.noda.co.nz 相同的路由结构
    # 但使用 $findclass_preprod_upstream 等变量

    location / {
        proxy_pass http://$findclass_preprod_upstream;
        include /etc/nginx/snippets/proxy-common.conf;
        proxy_buffering off;
        proxy_set_header Connection "";
    }
}

# ============================================
# Pre-prod 官网
# ============================================
server {
    listen 80;
    server_name pre.noda.co.nz;

    include /etc/nginx/snippets/upstream-findclass-preprod.conf;

    # ... 与 prod noda.co.nz 相同结构
    location / {
        proxy_pass http://$www_preprod_upstream;
        include /etc/nginx/snippets/proxy-common.conf;
    }
}

# ============================================
# Pre-prod Admin（仅内网）
# ============================================
server {
    listen 80;
    server_name pre.admin.noda.co.nz;

    include /etc/nginx/snippets/upstream-findclass-preprod.conf;

    # ... 与 prod admin.noda.co.nz 相同结构
    location /api/admin/ {
        proxy_pass http://$admin_api_preprod_upstream;
        include /etc/nginx/snippets/proxy-common.conf;
    }
    location / {
        proxy_pass http://$admin_preprod_upstream;
        include /etc/nginx/snippets/proxy-common.conf;
    }
}
```

**forwarded_proto map 扩展：**

在 default.conf 顶部的 map 块中追加 pre-prod 域名：

```nginx
map $host $forwarded_proto {
    default $scheme;
    # prod
    class.noda.co.nz "https";
    auth.noda.co.nz "https";
    noda.co.nz "https";
    www.noda.co.nz "https";
    # pre-prod
    pre.class.noda.co.nz "https";
    pre.auth.noda.co.nz "https";
    pre.noda.co.nz "https";
    pre.admin.noda.co.nz "https";
}
map $host $forwarded_port {
    default $server_port;
    # prod
    class.noda.co.nz "443";
    auth.noda.co.nz "443";
    noda.co.nz "443";
    www.noda.co.nz "443";
    # pre-prod
    pre.class.noda.co.nz "443";
    pre.auth.noda.co.nz "443";
    pre.noda.co.nz "443";
    pre.admin.noda.co.nz "443";
}
```

## 4. Keycloak 多 Realm 配置

### 架构决策

Keycloak 共享单实例，通过不同 realm 隔离 prod 和 pre-prod 用户：

| Realm | 用途 | Client ID | Redirect URIs |
|-------|------|-----------|---------------|
| noda | 生产环境 | noda-frontend | class.noda.co.nz, auth.noda.co.nz |
| noda-preprod | 预发布环境 | noda-frontend-preprod | pre.class.noda.co.nz, pre.auth.noda.co.nz |

### 实施方式

**方式 A（推荐）：** 扩展 `init-realm.sh` 脚本

在现有 `init-realm.sh` 中增加 `noda-preprod` realm 创建逻辑，复用 Google OAuth 配置。脚本是幂等的（先检查 realm 是否存在），可以安全重新运行。

新增内容：
```bash
# 创建 noda-preprod realm
if /opt/keycloak/bin/kcadm.sh get realms/noda-preprod > /dev/null 2>&1; then
    echo "Realm 'noda-preprod' 已存在，跳过"
else
    /opt/keycloak/bin/kcadm.sh create realms \
        -s realm=noda-preprod \
        -s enabled=true \
        -s sslRequired=none \
        -s registrationAllowed=true \
        -s loginWithEmailAllowed=true \
        -s duplicateEmailsAllowed=false \
        -s resetPasswordAllowed=true \
        -s bruteForceProtected=true
fi

# 创建 noda-frontend-preprod client
if /opt/keycloak/bin/kcadm.sh get realms/noda-preprod/clients | \
    jq -e '.[] | select(.clientId=="noda-frontend-preprod")' > /dev/null 2>&1; then
    echo "Client 'noda-frontend-preprod' 已存在"
else
    /opt/keycloak/bin/kcadm.sh create clients \
        -r noda-preprod \
        -s clientId=noda-frontend-preprod \
        -s enabled=true \
        -s publicClient=true \
        -s 'redirectUris=["https://pre.class.noda.co.nz/*","https://pre.auth.noda.co.nz/*"]' \
        -s 'webOrigins=["+"])'
fi

# 配置 Google IdP（复用 prod 的 OAuth 凭据）
# 与 prod realm 相同的 Google Identity Provider 配置
```

**方式 B（快速启动）：** Keycloak Admin Console 手动创建

从 Admin Console 导入 noda realm 配置，修改 realm 名称和 redirect URIs。适合首次部署，后续自动化用方式 A。

**推荐：先用方式 B 首次创建验证，然后用方式 A 脚本化保证可重复性。**

### Keycloak 不变的部分

- Keycloak 容器本身不需要变更（单实例、蓝绿部署方式不变）
- `KC_HOSTNAME` 保持 `https://auth.noda.co.nz` -- Keycloak 的 Admin Console 和 token 端点仍然通过 prod 域名访问
- pre-prod 应用的 `KEYCLOAK_URL` 指向 `https://pre.auth.noda.co.nz`，但 Nginx 将其代理到同一个 Keycloak 实例
- Keycloak 的 realm 路由是内部逻辑（`/realms/noda-preprod/...`），由应用端 `KEYCLOAK_REALM` 环境变量控制

### 注意事项

- `KEYCLOAK_CLIENT_ID` 在 pre-prod 中必须不同（`noda-frontend-preprod`），因为同一 realm 内 clientId 必须唯一，不同 realm 间可以相同，但为了管理清晰使用不同名称
- Google OAuth redirect URIs 需要在 Google Cloud Console 中添加 pre-prod 域名
- pre-prod realm 的用户数据独立，不影响 prod 用户

## 5. 环境变量模板策略

### 新增文件

**`docker/env-noda-apps-preprod.env`**

```bash
# ============================================
# noda-apps pre-prod 环境变量文件
# ============================================
# 与 env-noda-apps.env 结构相同，修改以下变量：
# - DATABASE_URL → 指向 noda_preprod 数据库
# - KEYCLOAK_URL → 指向 pre.auth.noda.co.nz
# - KEYCLOAK_REALM → noda-preprod
# - KEYCLOAK_CLIENT_ID → noda-frontend-preprod

NODE_ENV=production
NEXT_PUBLIC_LOCAL_API_URL=http://localhost:3001
DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@noda-infra-postgres-prod:5432/noda_preprod
DIRECT_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@noda-infra-postgres-prod:5432/noda_preprod
KEYCLOAK_URL=https://pre.auth.noda.co.nz
KEYCLOAK_INTERNAL_URL=http://noda-infra-nginx
KEYCLOAK_REALM=noda-preprod
KEYCLOAK_CLIENT_ID=noda-frontend-preprod
RESEND_API_KEY=${RESEND_API_KEY}
ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}
ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}

# Email Service
KEYCLOAK_ADMIN_URL=http://noda-infra-nginx
KEYCLOAK_ADMIN_USER=${KEYCLOAK_ADMIN_USER}
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}
TOKEN_SECRET=${TOKEN_SECRET}
EMAIL_SERVICE_API_KEY=${EMAIL_SERVICE_API_KEY}
AUTH_APP_URL=http://localhost:3004
RESEND_FROM_EMAIL=Noda <noreply@email.noda.co.nz>
```

### 构建时 vs 运行时变量

**关键区别：** `NEXT_PUBLIC_*` 变量在 Docker build 时写入 JS 文件。pre-prod 需要不同的 Keycloak 配置，这意味着：

1. **Dockerfile 构建参数需要不同：**
   - prod: `NEXT_PUBLIC_KEYCLOAK_URL=https://auth.noda.co.nz`
   - pre-prod: `NEXT_PUBLIC_KEYCLOAK_URL=https://pre.auth.noda.co.nz`

2. **两种解决方案：**
   - **方案 A（推荐）：** 使用同一个 Docker 镜像，但 `NEXT_PUBLIC_KEYCLOAK_URL` 保持为 prod 值。pre-prod 应用在运行时通过 `KEYCLOAK_URL` 环境变量覆盖服务端行为。前端 Keycloak 初始化使用 prod URL（浏览器通过 Nginx 代理访问 `/realms/noda-preprod/`）。
   - **方案 B：** 构建两个不同镜像。增加存储和构建时间，不推荐。

**方案 A 的可行性：** 浏览器访问 `https://pre.auth.noda.co.nz/realms/noda-preprod/...` 时，DNS 指向同一服务器，Nginx 将 `pre.auth.noda.co.nz` 代理到同一个 Keycloak 容器。前端 JS 中硬编码的 Keycloak URL 实际上可以是 `auth.noda.co.nz`（prod 域名），因为 Keycloak 根据 URL 中的 realm 名称路由。但 `KEYCLOAK_REALM` 环境变量决定了 token 请求的目标 realm。

**结论：** pre-prod 可以使用与 prod 完全相同的 Docker 镜像（`noda-apps:latest`），仅通过运行时环境变量（`env-noda-apps-preprod.env`）区分数据库和 Keycloak realm。Promote 流程直接复用同一镜像 tag。

## 6. Docker 网络考量

### 推荐：共享同一网络

prod 和 pre-prod 容器运行在同一个 `noda-network` 外部网络上。

**理由：**
- 共享基础设施（PostgreSQL、Keycloak、Nginx）需要被所有应用容器访问
- pre-prod 容器需要 DNS 解析 `noda-infra-postgres-prod`、`noda-infra-nginx`、`keycloak-*`
- 容器隔离通过标签（`noda.environment`）实现，不需要网络隔离
- 项目已经在 Out of Scope 中排除了网络隔离（"标签分组已满足管理需求"）

**不需要额外网络：**
- 不需要 `noda-network-preprod` -- 增加管理复杂度无安全收益
- 不需要跨网络通信配置
- 单服务器部署，网络隔离对安全无实质帮助

### DNS 命名空间

所有容器在 `noda-network` 中的 DNS 名称：

| 容器名 | 环境归属 | DNS 可达 |
|--------|---------|---------|
| noda-apps-blue | prod | noda-network 内所有容器 |
| noda-apps-green | prod | noda-network 内所有容器 |
| noda-apps-preprod-blue | pre-prod | noda-network 内所有容器 |
| noda-apps-preprod-green | pre-prod | noda-network 内所有容器 |
| noda-infra-postgres-prod | 共享 | noda-network 内所有容器 |
| noda-infra-nginx | 共享 | noda-network 内所有容器 |
| keycloak-blue/green | 共享 | noda-network 内所有容器 |

## 集成点分析：新增 vs 修改

### 需要新增的文件

| 文件 | 用途 | Phase |
|------|------|-------|
| `config/nginx/snippets/upstream-findclass-preprod.conf` | pre-prod upstream 变量 | Phase 2 |
| `docker/env-noda-apps-preprod.env` | pre-prod 运行时环境变量 | Phase 3 |
| `scripts/wrapper-blue-green-deploy-preprod.sh` | pre-prod 蓝绿部署 wrapper（类似 keycloak-blue-green-deploy.sh） | Phase 3 |
| `jenkins/Jenkinsfile.noda-apps-preprod` | pre-prod 部署 Pipeline | Phase 3 |

### 需要修改的文件

| 文件 | 修改内容 | 复杂度 | Phase |
|------|---------|--------|-------|
| `scripts/init-databases.sh` | REQUIRED_DBS 增加 `noda_preprod` | 低 | Phase 1 |
| `services/keycloak/init-realm.sh` | 增加 `noda-preprod` realm + client 创建 | 中 | Phase 1 |
| `config/nginx/conf.d/default.conf` | 新增 4 个 pre-prod server blocks + 扩展 map | 中 | Phase 2 |
| `scripts/manage-containers.sh` | 参数化 `noda.environment` 标签 + 支持 `noda-apps-preprod` upstream | 中 | Phase 3 |
| `jenkins/Jenkinsfile.noda-apps` | 增加 Promote to Prod 参数化流程 | 中 | Phase 3 |

### 不需要修改的文件

| 文件 | 原因 |
|------|------|
| `docker/docker-compose.yml` | 基础设施 compose 不变 |
| `docker/docker-compose.app.yml` | 应用容器通过 docker run 管理，不通过 compose |
| `docker/env-keycloak.env` | Keycloak 共享，不需要 pre-prod 版本 |
| `config/nginx/snippets/upstream-keycloak.conf` | Keycloak 共享，upstream 不变 |
| `config/nginx/snippets/proxy-*.conf` | 通用代理头，pre-prod 复用 |
| `scripts/pipeline-stages.sh` | 通过 SERVICE_NAME/ACTIVE_ENV_FILE 等环境变量参数化，新 Pipeline 设置不同的变量值即可 |

## 数据流

### Pre-prod 请求完整链路

```
1. 浏览器访问 https://pre.class.noda.co.nz
2. Cloudflare DNS → CNAME → noda-ops Cloudflare Tunnel
3. noda-ops → nginx:80 (Host: pre.class.noda.co.nz)
4. Nginx server_name 匹配 → include upstream-findclass-preprod.conf
5. proxy_pass http://$findclass_preprod_upstream
6. resolver 127.0.0.11 → noda-apps-preprod-blue:3000 (或 green)
7. noda-apps 容器处理请求
8. DATABASE_URL → noda-infra-postgres-prod:5432/noda_preprod
9. KEYCLOAK_REALM=noda-preprod → Keycloak 认证

Auth 登录流程:
1. 浏览器 → pre.class.noda.co.nz → 点击登录
2. 前端 → pre.auth.noda.co.nz/realms/noda-preprod/protocol/openid-connect/auth
3. Nginx pre.auth.noda.co.nz → Keycloak (共享) → noda-preprod realm
4. Google OAuth → Google → callback → Keycloak → token
5. 前端用 token 访问 pre.class.noda.co.nz API
```

### Promote to Prod 流程

```
1. 开发者合并代码到 main
2. Jenkins Pipeline: noda-apps-preprod → Build → Deploy → Health Check → Switch
3. 团队在 pre.class.noda.co.nz 验证
4. 验证通过 → 触发 Promote Pipeline
5. Promote: 读取 pre-prod 当前镜像 digest
6. 用相同镜像部署到 prod 蓝绿环境
7. Health Check → Switch → Verify → CDN Purge
8. Prod 上线完成
```

## 构建顺序建议（Phase 依赖）

```
Phase 1: 数据库 + Keycloak Realm（无外部依赖，可独立执行）
  ├── init-databases.sh 修改（5 分钟）
  ├── init-realm.sh 扩展（30 分钟，含 Google OAuth 配置）
  └── 手动验证：noda_preprod 数据库可连接，noda-preprod realm 可登录

Phase 2: Nginx + Cloudflare DNS（依赖 Phase 1 无，但需要 Phase 3 才能端到端验证）
  ├── upstream-findclass-preprod.conf 创建（5 分钟）
  ├── default.conf 修改（30 分钟，4 个 server blocks）
  ├── Cloudflare Tunnel 配置（10 分钟，noda-ops）
  ├── Cloudflare DNS CNAME 记录（5 分钟）
  └── 验证：curl pre.class.noda.co.nz 返回 502（无后端容器，但路由可达）

Phase 3: 部署脚本 + Jenkins Pipeline（依赖 Phase 1 + Phase 2）
  ├── env-noda-apps-preprod.env 创建（10 分钟）
  ├── manage-containers.sh 参数化修改（60 分钟，核心变更）
  ├── wrapper-blue-green-deploy-preprod.sh 创建（15 分钟，复制 keycloak wrapper 模式）
  ├── Jenkinsfile.noda-apps-preprod 创建（30 分钟）
  ├── Jenkinsfile.noda-apps Promote 流程（60 分钟）
  ├── 首次 pre-prod 部署验证
  └── Promote 到 Prod 端到端验证

Phase 4: 文档 + 规范（依赖 Phase 3 验证完成）
  ├── CLAUDE.md 更新
  ├── Git tagging 规范文档
  ├── Hotfix 流程文档
  └── runbook 更新
```

**关键依赖路径：** Phase 3 是关键路径，`manage-containers.sh` 的参数化修改是最复杂的变更，影响蓝绿部署的核心逻辑。建议在修改前增加 Bats 测试（如果已有测试框架）或至少在 staging 环境手动验证。

## 反模式与风险

### 反模式 1：在 manage-containers.sh 中硬编码 pre-prod 逻辑

**问题：** 在 `update_upstream()` 中不断增加 `if [ "$SERVICE_NAME" = "xxx" ]` 分支
**后果：** 脚本膨胀，每次新增服务都需要修改核心函数
**正确做法：** 将 upstream 内容生成参数化，通过环境变量或配置文件传入变量名和端口映射

### 反模式 2：pre-prod 使用不同的 Docker 镜像

**问题：** 为 pre-prod 单独构建 Docker 镜像（不同 build args）
**后果：** Promote 流程无法保证 pre-prod 和 prod 运行完全相同的代码
**正确做法：** pre-prod 和 prod 使用同一镜像，仅运行时环境变量不同

### 反模式 3：pre-prod 和 prod 共享蓝绿状态文件

**问题：** 使用同一个 `/opt/noda/active-env` 文件，通过环境变量切换
**后果：** pre-prod 部署影响 prod 的蓝绿状态记录，回滚时混淆
**正确做法：** 独立的 `active-env-preprod` 文件，两个环境完全解耦

### 反模式 4：Nginx 使用条件路由（if 指令）

**问题：** 在同一个 server block 中用 `if ($host ~ pre\.)` 区分 prod 和 pre-prod
**后果：** Nginx 的 `if` 在 location 中行为不可预测，可能导致请求丢失
**正确做法：** 独立 server blocks，各自 include 对应的 upstream snippet

## 规模考量

| 规模 | Pre-prod 架构调整 |
|------|------------------|
| 当前（单服务器，4 应用） | 共享基础设施 + 独立应用容器，增量 1GB 内存 |
| 10+ 应用 | 考虑 pre-prod 使用 Docker Compose profiles 统一管理 |
| 多服务器 | pre-prod 独立服务器，与 prod 物理隔离 |

**当前瓶颈：** 内存。每套蓝绿环境需要 2 个容器（蓝绿各一），pre-prod 增加 1GB。如果服务器内存紧张，可以只保留一个 pre-prod 容器（不做蓝绿），但失去零停机部署能力。

## Sources

- 项目代码分析：`scripts/manage-containers.sh`, `config/nginx/conf.d/default.conf`, `config/nginx/snippets/upstream-*.conf`, `docker/env-noda-apps.env`, `jenkins/Jenkinsfile.noda-apps`
- 架构历史：CLAUDE.md Phase 16 端口收敛 + OAuth 修复记录
- 项目决策记录：`.planning/PROJECT.md` Key Decisions 表
- 调查笔记：`.planning/notes/pre-prod-environment-plan.md`

---
*Architecture research for: Pre-Prod 环境集成*
*Researched: 2026-05-08*
