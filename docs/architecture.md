# Noda 基础设施部署架构

## 🏗️ 架构总览

```
外网 (Internet)
    |
    v
[Cloudflare Tunnel]
    |
    v
[noda-infra-nginx:80] ← 唯一对外访问点
    |
    +--> [findclass-web:80] (内部网络)
    |
    +--> [findclass-api:3001] (内部网络)
    |
    +--> [noda-infra-keycloak-1:8080] (内部网络)
    |
    +--> [noda-infra-postgres-1:5432] (内部网络)
```

## 🔒 安全原则

**单一入口点**: 只有 `noda-infra-nginx` 容器对外暴露端口 80
- ✅ 所有应用服务都在内部网络
- ✅ 通过反向代理访问
- ✅ Cloudflare Tunnel 只连接到 noda-infra-nginx

## 📦 服务分组

### 1. noda-infra (基础设施)
- **noda-infra-postgres-1**: PostgreSQL 数据库
- **noda-infra-keycloak-1**: Keycloak 认证服务
- **noda-infra-nginx-1**: Nginx 反向代理（**唯一对外服务**）
- **noda-infra-cloudflared-1**: Cloudflare Tunnel

### 2. noda-app (应用服务)
- **findclass-web**: Findclass 前端（Nginx 静态文件）
- **findclass-api**: Express API 服务器

### 3. noda-dev (开发环境)
- **noda-dev-postgres**: 开发数据库

## 🌐 访问路径

### 外网访问（通过 Cloudflare Tunnel）
```
https://class.noda.co.nz/
    |
    v
Cloudflare Tunnel
    |
    v
noda-infra-nginx:80
    |
    +-- / --> findclass-web:80 (前端)
    |
    +-- /api/* --> findclass-api:3001 (API)
    |
    +-- /auth/* --> noda-infra-keycloak-1:8080 (认证)
```

### 本地访问
```
http://localhost/ --> 前端应用
http://localhost/api/health --> API 健康检查
http://localhost:8080/ --> Keycloak 管理后台
```

## 🔧 端口映射

| 容器 | 内部端口 | 外部端口 | 说明 |
|------|----------|----------|------|
| noda-infra-nginx-1 | 80 | **80** | ✅ 唯一对外端口 |
| noda-infra-keycloak-1 | 8080, 9000 | 8080, 9000 | 本地管理端口 |
| noda-infra-postgres-1 | 5432 | - | 🔒 内部网络 |
| findclass-web | 80 | - | 🔒 内部网络 |
| findclass-api | 3001 | - | 🔒 内部网络 |
| noda-dev-postgres | 5432 | 5433 | 开发端口 |

## 📝 Nginx 配置

### default.conf (主入口)
```nginx
# 根路径 -> 前端应用
location / {
    proxy_pass http://findclass-web/;
}

# API -> 后端服务
location /api/ {
    proxy_pass http://findclass-api:3001/api/;
}

# 认证 -> Keycloak
location /auth/ {
    proxy_pass http://keycloak:8080/;
}
```

### class.noda.co.nz.conf (生产域名)
```nginx
server {
    server_name class.noda.co.nz;
    
    # API 反向代理
    location /api/ {
        proxy_pass http://findclass-api:3001/api/;
    }
    
    # SPA 回退
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

## 🚀 部署命令

### 启动所有服务
```bash
cd ~/project/noda-infra/docker

# 基础设施
docker compose -p noda-infra -f docker-compose.simple.yml up -d

# 应用服务
docker compose -p noda-app -f docker-compose.app.yml up -d

# 开发环境（可选）
docker compose -p noda-dev -f docker-compose.dev-standalone.yml up -d
```

### 查看服务状态
```bash
docker ps --filter "name=noda" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### 重启 Nginx（配置更新后）
```bash
docker restart noda-infra-nginx-1
```

## 🔍 验证检查

### 1. 检查端口映射
```bash
docker ps --format "table {{.Names}}\t{{.Ports}}"
```
**预期结果**: 只有 noda-infra-nginx-1 有 `0.0.0.0:80->80/tcp`

### 2. 测试外网访问
```bash
# 前端
curl -s http://localhost/ | grep "<title>"

# API
curl http://localhost/api/health

# 认证
curl http://localhost:8080/realms/master
```

### 3. 验证服务间通信
```bash
# 从前端容器访问 API
docker exec findclass-web wget -q -O - http://findclass-api:3001/api/health
```

## ⚠️ 重要提醒

1. **不要**为 findclass-web 或 findclass-api 添加端口映射
2. **不要**直接暴露数据库端口到外网
3. **所有**外网访问都必须通过 noda-infra-nginx
4. **Cloudflare Tunnel** 只连接到 noda-infra-nginx:80

## 📊 服务依赖关系

```
noda-infra-nginx (入口)
    |
    +--> findclass-web
    |       |
    |       +--> findclass-api
    |               |
    |               +--> noda-infra-postgres-1
    |               |
    |               +--> noda-infra-keycloak-1
    |
    +--> noda-infra-keycloak-1
    |
    +--> noda-infra-postgres-1
```

**启动顺序**:
1. noda-infra (PostgreSQL, Keycloak, Nginx, Cloudflare)
2. noda-app (API, Web)

---

**部署日期**: 2026-04-05
**配置文件**: docker-compose.simple.yml, docker-compose.app.yml
