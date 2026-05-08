# Phase 54 模式文档：Nginx + Cloudflare 配置模式

**创建日期：** 2026-05-08
**用途：** 记录现有的 Nginx 和 Cloudflare 配置模式，供 Phase 54 规划参考

---

## Nginx 配置模式

### 1. Upstream 变量模式

**位置：** `config/nginx/snippets/upstream-*.conf`

**结构：**
```nginx
# Upstream 变量 — 在 server 块中 include
# 使用 resolver 127.0.0.11 动态解析 DNS，容器重建后自动刷新 IP
# 由 update_upstream() 在蓝绿切换时更新
set $findclass_upstream noda-apps-green:3000;
set $www_upstream noda-apps-green:3002;
set $auth_app_upstream noda-apps-green:3004;
set $admin_upstream noda-apps-green:3006;
set $admin_api_upstream noda-apps-green:3011;
```

**关键特征：**
- 使用 `set` 指令定义变量（非 `upstream` 块）
- 变量名格式：`$<service>_upstream`
- 初始值指向绿色容器（`-green` 后缀）
- 在 server 块中通过 `include` 引入
- 由蓝绿切换脚本动态更新

**Pre-prod 适配：**
- 变量名必须包含 `_preprod_` 前缀（例如 `$findclass_preprod_upstream`）
- 初始值指向 `noda-apps-preprod-green:port`（容器名在 Phase 55 创建）

### 2. Server Block 模式

**位置：** `config/nginx/conf.d/default.conf`

**结构：**
```nginx
server {
    listen 80;
    server_name class.noda.co.nz;

    # 引入 upstream 变量
    include /etc/nginx/snippets/upstream-findclass.conf;

    # 安全头
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    # 代理规则
    location / {
        proxy_pass http://$findclass_upstream;
        include /etc/nginx/snippets/proxy-common.conf;
    }

    # 错误页
    error_page 502 503 /50x.html;
    location = /50x.html {
        root /etc/nginx/errors;
        internal;
    }
}
```

**关键特征：**
- 监听端口 80（Cloudflare TLS 终止，内部 HTTP）
- 每个域名一个 `server {}` 块
- 使用 `include` 引入 upstream 变量（避免硬编码）
- 使用 `include` 引入 proxy 头配置（复用）
- 错误页使用 `/etc/nginx/errors` 目录

**Pre-prod 适配：**
- `server_name` 改为 pre-prod 域名（例如 `pre.class.noda.co.nz`）
- `include` 改为 pre-prod upstream 文件（`upstream-findclass-preprod.conf`）
- location 规则保持一致（复用 prod 模式）

### 3. Location 匹配优先级模式

**场景：** `auth.noda.co.nz` 同时路由到 Auth App 和 Keycloak

**结构：**
```nginx
# Auth App 用户页面（精确匹配和前缀匹配）
location = / { proxy_pass http://$auth_app_upstream; }
location /login { proxy_pass http://$auth_app_upstream; }
location /api/ { proxy_pass http://$auth_app_upstream; }

# Keycloak API/协议端点（兜底）
location / {
    proxy_pass http://$keycloak_upstream;
}
```

**关键特征：**
- 精确匹配（`location = /`）优先级最高
- 前缀匹配（`location /api/`）优先级次之
- 兜底匹配（`location /`）优先级最低
- Auth App 的规则必须在 Keycloak 之前

**Pre-prod 适配：**
- `pre.auth.noda.co.nz` 使用相同的 location 结构
- Auth App upstream 改为 `$auth_app_preprod_upstream`
- Keycloak upstream 保持 `$keycloak_upstream`（共享实例）

### 4. 代理头配置模式

**位置：** `config/nginx/snippets/proxy-common.conf`

**结构：**
```nginx
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $forwarded_proto;
proxy_set_header X-Forwarded-Port $forwarded_port;
proxy_set_header X-Forwarded-Host $host;
proxy_http_version 1.1;
```

**关键特征：**
- 使用 `$forwarded_proto` 和 `$forwarded_port`（从 `default.conf` 的 map 指令获取）
- 支持WebSocket（`proxy_http_version 1.1`）
- 所有 server 块共享此配置

**Pre-prod 适配：**
- 无需修改（直接复用）

### 5. Forwarded Protocol 映射模式

**位置：** `config/nginx/conf.d/default.conf`（顶部）

**结构：**
```nginx
map $host $forwarded_proto {
    default $scheme;
    class.noda.co.nz "https";
    auth.noda.co.nz "https";
}

map $host $forwarded_port {
    default $server_port;
    class.noda.co.nz "443";
    auth.noda.co.nz "443";
}
```

**关键特征：**
- 为每个域名显式声明 `https` 和 `443`（Cloudflare TLS 终止）
- 避免应用层检测到 `http://` 和 `80` 端口

**Pre-prod 适配：**
- 为 4 个 pre-prod 域名添加 map 条目
- 例如：`pre.class.noda.co.nz "https";` 和 `pre.class.noda.co.nz "443";`

---

## Cloudflare Tunnel 配置模式

### 1. Ingress 规则模式

**位置：** `config/cloudflare/config.yml`

**结构：**
```yaml
ingress:
  # 主域名
  - hostname: noda.co.nz
    service: http://noda-nginx:80

  # 认证服务
  - hostname: auth.noda.co.nz
    service: http://noda-nginx:80

  # 健康检查
  - hostname: health.noda.co.nz
    service: http://noda-nginx:80

  # 默认规则（必须是最后一条）
  - service: http_status:404
```

**关键特征：**
- 每个域名一个 ingress 条目
- 所有域名指向同一个服务：`http://noda-nginx:80`（由 Nginx 路由到不同容器）
- 默认规则返回 404（防止未配置域名被访问）

**Pre-prod 适配：**
- 添加 4 条 pre-prod 域名规则
- 所有规则指向 `http://noda-nginx:80`
- 保持默认规则在最后

### 2. Tunnel 服务重启模式

**命令：**
```bash
# 重启 noda-ops 容器（加载最新 config.yml）
docker restart noda-infra-noda-ops-1

# 验证 Tunnel 连接状态
docker logs noda-infra-noda-ops-1 --tail 50 | grep "registered.*tunnel"
```

**关键特征：**
- 修改 `config.yml` 后必须重启容器（热重载不生效）
- 使用 Docker restart（非 down/up）
- 检查日志确认 Tunnel 注册成功

---

## 蓝绿切换脚本模式（Phase 55 参考）

### 1. Upstream 更新模式

**位置：** `scripts/lib/manage-containers.sh` 中的 `update_upstream()` 函数

**逻辑：**
```bash
update_upstream() {
    local UPSTREAM_CONF="/etc/nginx/snippets/upstream-findclass.conf"
    local COLOR="${1}"  # blue or green

    # 替换 upstream 变量值
    sed -i "s/noda-apps-blue:/noda-apps-${COLOR}:/g" "$UPSTREAM_CONF"
    sed -i "s/noda-apps-green:/noda-apps-${COLOR}:/g" "$UPSTREAM_CONF"

    # 重载 Nginx
    docker exec noda-infra-nginx nginx -s reload
}
```

**关键特征：**
- 使用 `sed` 替换容器名后缀（`-blue` ↔ `-green`）
- 修改后立即重载 Nginx（`nginx -s reload`）
- upstream 文件路径可配置（Phase 55 将添加 `UPSTREAM_CONF` 环境变量）

**Pre-prod 适配（Phase 55）：**
- 修改 `UPSTREAM_CONF` 为 `/etc/nginx/snippets/upstream-findclass-preprod.conf`
- 容器名前缀改为 `noda-apps-preprod-`

---

## 文件命名约定

| 组件 | Prod 文件名 | Pre-prod 文件名 |
|------|-------------|----------------|
| Upstream 配置 | `upstream-findclass.conf` | `upstream-findclass-preprod.conf` |
| 容器名 | `noda-apps-{blue|green}` | `noda-apps-preprod-{blue|green}` |
| 状态文件 | `/opt/noda/active-env` | `/opt/noda/active-env-preprod` |
| 环境变量文件 | `env-noda-apps.env` | `env-noda-apps-preprod.env` |
| Doppler config | `prd` | `pre` |

---

## 配置验证模式

### Nginx 配置验证

```bash
# 语法检查
docker exec noda-infra-nginx nginx -t

# 重载 Nginx
docker exec noda-infra-nginx nginx -s reload

# 查看 upstream 变量值
docker exec noda-infra-nginx cat /etc/nginx/snippets/upstream-findclass.conf
```

### Cloudflare Tunnel 配置验证

```bash
# 验证 YAML 语法（需要在容器内执行）
docker exec noda-infra-noda-ops-1 cloudflared --config /etc/cloudflared/config.yml config validate

# 查看 Tunnel 连接状态
docker exec noda-infra-noda-ops-1 cloudflared --config /etc/cloudflared/config.yml tunnel info

# 查看 Tunnel 路由表
docker exec noda-infra-noda-ops-1 cloudflared --config /etc/cloudflared/config.yml tunnel route
```

---

## 常见错误与调试

### 错误 1：Nginx 502 Bad Gateway

**原因：** upstream 容器未运行或容器名错误

**调试：**
```bash
# 检查 upstream 容器状态
docker ps | grep noda-apps

# 检查 upstream 变量值
docker exec noda-infra-nginx cat /etc/nginx/snippets/upstream-findclass-preprod.conf

# 手动测试容器可达性
docker exec noda-infra-nginx curl -I http://noda-apps-preprod-green:3000
```

### 错误 2：Cloudflare Tunnel 522 错误

**原因：** Tunnel 无法连接到 `noda-nginx:80`

**调试：**
```bash
# 检查 noda-nginx 容器状态
docker ps | grep nginx

# 检查 noda-ops 容器日志
docker logs noda-infra-noda-ops-1 --tail 100

# 从 noda-ops 容器测试 nginx 可达性
docker exec noda-infra-noda-ops-1 curl -I http://noda-nginx:80
```

### 错误 3：域名返回 404

**原因：** Cloudflare Tunnel 配置缺少该域名的 ingress 规则

**调试：**
```bash
# 检查 config.yml 是否包含该域名
docker exec noda-infra-noda-ops-1 cat /etc/cloudflared/config.yml | grep pre.class.noda.co.nz

# 检查 Tunnel 路由表
docker exec noda-infra-noda-ops-1 cloudflared --config /etc/cloudflared/config.yml tunnel route
```
