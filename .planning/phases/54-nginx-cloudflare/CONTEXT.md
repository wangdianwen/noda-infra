# Phase 54 上下文：Nginx 路由 + Cloudflare DNS

**创建日期：** 2026-05-08
**Phase：** 54-nginx-cloudflare
**目标：** Pre-prod 域名可从外部访问，Nginx 正确路由到 pre-prod upstream（无后端时返回 502 即为正确）

---

## 背景

Phase 53 已完成基础设施隔离：
- ✅ `noda_preprod` 数据库创建（独立用户 `preprod_app`）
- ✅ Keycloak `noda-preprod` realm 创建（包含 Google OAuth）
- ✅ Doppler `pre` config 创建（隔离密钥）

Phase 54 的任务是配置网络层路由，使 pre-prod 域名可从外部访问。

## 当前架构

### Nginx 配置结构

```
config/nginx/
├── nginx.conf                    # 主配置
├── conf.d/default.conf           # Server blocks（4 个域名）
└── snippets/
    ├── upstream-findclass.conf   # Prod upstream 变量
    ├── upstream-keycloak.conf    # Keycloak upstream
    ├── proxy-common.conf         # 通用代理头
    └── proxy-websocket.conf      # WebSocket 支持
```

### Prod Upstream 模式

`upstream-findclass.conf` 定义了 5 个变量：
- `$findclass_upstream` → `noda-apps-green:3000`
- `$www_upstream` → `noda-apps-green:3002`
- `$auth_app_upstream` → `noda-apps-green:3004`
- `$admin_upstream` → `noda-apps-green:3006`
- `$admin_api_upstream` → `noda-apps-green:3011`

### Cloudflare Tunnel 配置

当前 `config.yml` 定义了 4 个 prod 域名：
- `noda.co.nz` → `noda-nginx:80`
- `auth.noda.co.nz` → `noda-nginx:80`
- `localhost.noda.co.nz` → `noda-nginx:80`
- `health.noda.co.nz` → `noda-nginx:80`

## 需要创建的 Pre-Prod 资源

### 1. Nginx Pre-Prod Upstream（INFRA-04）

**文件：** `config/nginx/snippets/upstream-findclass-preprod.conf`

**变量命名规范：**
- 必须使用 `_preprod_` 前缀（避免与 prod 变量冲突）
- 例如：`$findclass_preprod_upstream`（而非 `$findclass_upstream`）

**初始值：**
```nginx
set $findclass_preprod_upstream noda-apps-preprod-green:3000;
set $www_preprod_upstream noda-apps-preprod-green:3002;
set $auth_app_preprod_upstream noda-apps-preprod-green:3004;
set $admin_preprod_upstream noda-apps-preprod-green:3006;
set $admin_api_preprod_upstream noda-apps-preprod-green:3011;
```

**注意：** 容器名 `noda-apps-preprod-*` 将在 Phase 55 创建，当前阶段只需定义变量。

### 2. Nginx Pre-Prod Server Blocks（INFRA-05）

**需要 4 个 server blocks：**

| 域名 | 用途 | Upstream 变量 | 预期行为（无后端时） |
|------|------|---------------|-------------------|
| `pre.class.noda.co.nz` | FindClass SSR | `$findclass_preprod_upstream` | 502 Bad Gateway |
| `pre.auth.noda.co.nz` | Auth App + Keycloak | `$auth_app_preprod_upstream` + `$keycloak_upstream` | Keycloak 登录页（共享实例） |
| `pre.noda.co.nz` | Noda 官网 | `$www_preprod_upstream` | 502 Bad Gateway |
| `pre.admin.noda.co.nz` | Admin Dashboard | `$admin_preprod_upstream` | 502 Bad Gateway |

**配置模式：**
- 复用 `default.conf` 的 location 结构（保持一致性）
- 替换 `server_name` 为 pre-prod 域名
- 替换 upstream 变量为 pre-prod 版本
- Keycloak 共享 prod 实例（`pre.auth.noda.co.nz` 的 `/` 路由仍使用 `$keycloak_upstream`）

### 3. Cloudflare DNS + Tunnel 路由（INFRA-06）

**需要在 Cloudflare Dashboard 添加 4 个 CNAME 记录：**

| 子域名 | 类型 | 目标 | Proxy 状态 |
|--------|------|------|-----------|
| `pre.class` | CNAME | `noda-ops.noda.co.nz` | Proxied（橙色云） |
| `pre.auth` | CNAME | `noda-ops.noda.co.nz` | Proxied（橙色云） |
| `pre` | CNAME | `noda-ops.noda.co.nz` | Proxied（橙色云） |
| `pre.admin` | CNAME | `noda-ops.noda.co.nz` | Proxified（橙色云） |

**需要在 `config/cloudflare/config.yml` 添加 4 条 ingress 规则：**

```yaml
ingress:
  # ... existing prod rules ...

  # Pre-prod 域名
  - hostname: pre.class.noda.co.nz
    service: http://noda-nginx:80
  - hostname: pre.auth.noda.co.nz
    service: http://noda-nginx:80
  - hostname: pre.noda.co.nz
    service: http://noda-nginx:80
  - hostname: pre.admin.noda.co.nz
    service: http://noda-nginx:80

  # 默认规则
  - service: http_status:404
```

**Tunnel 重启：** 修改 `config.yml` 后需重启 `noda-ops` 容器。

## 依赖关系

### 上游依赖（Phase 53）

- ✅ `noda_preprod` 数据库已创建
- ✅ Keycloak `noda-preprod` realm 已创建
- ✅ Doppler `pre` config 已创建

### 下游影响（Phase 55-56）

- Phase 55 将创建 `noda-apps-preprod-{blue|green}` 容器
- Phase 56 将使用 Jenkins Pipeline 自动化部署

## 约束条件

### 变量命名（INFRA-04）

- **必须**使用 `_preprod_` 前缀（避免与 prod 变量冲突）
- 例如：`$findclass_preprod_upstream` 而非 `$findclass_upstream`

### 共享 Keycloak 实例

- Pre-prod 不创建独立的 Keycloak 容器
- `pre.auth.noda.co.nz` 的 `/realms/*` 路由仍使用 `$keycloak_upstream`（共享 prod 实例）
- 但 Keycloak client 必须使用 `noda-frontend-preprod`（realm 选择）

### 安全考虑

- Pre-prod 域名不需要额外的访问控制（与 prod 相同）
- Pre-prod 数据库已在 Phase 53 隔离（`preprod_app` 用户）
- Pre-prod realm 已在 Phase 53 隔离（`noda-preprod`）

## 验证标准

### 成功标准（来自 ROADMAP.md）

1. ✅ `curl https://pre.class.noda.co.nz` 返回 502 Bad Gateway（路由正确但无 pre-prod 后端）
2. ✅ `curl https://pre.auth.noda.co.nz` 返回 Keycloak 登录页（共享实例，realm 正确路由）
3. ✅ `curl https://pre.noda.co.nz` 和 `curl https://pre.admin.noda.co.nz` 可达（返回预期状态码）
4. ✅ Nginx pre-prod upstream 变量名包含 `preprod` 前缀，不与 prod upstream 变量冲突

### 验证方法

```bash
# 1. 验证 Nginx 配置语法
docker exec noda-infra-nginx nginx -t

# 2. 重载 Nginx
docker exec noda-infra-nginx nginx -s reload

# 3. 测试域名可达性
curl -I https://pre.class.noda.co.nz      # 502 Bad Gateway
curl -I https://pre.auth.noda.co.nz       # 200 OK（Keycloak 页面）
curl -I https://pre.noda.co.nz            # 502 Bad Gateway
curl -I https://pre.admin.noda.co.nz      # 502 Bad Gateway

# 4. 验证 upstream 变量名包含 preprod 前缀
docker exec noda-infra-nginx grep -r "preprod" /etc/nginx/snippets/
```

## 风险与注意事项

### 风险 1：变量名冲突

**问题：** 如果 pre-prod upstream 变量名与 prod 相同（例如都用 `$findclass_upstream`），蓝绿切换脚本会修改错误的文件。

**缓解：** 强制使用 `_preprod_` 前缀（例如 `$findclass_preprod_upstream`）。

### 风险 2：Keycloak 路由混淆

**问题：** `pre.auth.noda.co.nz` 同时需要路由到 Auth App（`/`、`/login` 等）和 Keycloak（`/realms/*`），location 匹配顺序可能出错。

**缓解：** 确保 Auth App 的 location 规则（精确匹配和前缀匹配）在 Keycloak 的 `location /` 之前。

### 风险 3：Cloudflare Tunnel 配置错误

**问题：** `config.yml` 语法错误会导致 `noda-ops` 容器无法启动。

**缓解：** 修改前备份原文件，使用 `cloudflared --config config.yml config validate` 验证语法。

## 参考文档

- Prod Nginx 配置：`config/nginx/conf.d/default.conf`
- Prod upstream 配置：`config/nginx/snippets/upstream-findclass.conf`
- Cloudflare Tunnel 配置：`config/cloudflare/config.yml`
- Phase 53 总结：`.planning/phases/53-keycloak-doppler/*-SUMMARY.md`
