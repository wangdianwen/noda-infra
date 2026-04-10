<!-- generated-by: gsd-doc-writer -->

# 快速上手

本文档帮助新成员从零开始搭建 Noda 基础设施本地开发环境，完成首次部署并验证所有服务正常运行。

---

## 前置要求

在开始之前，请确认本地已安装以下工具：

| 工具 | 最低版本 | 说明 |
|------|----------|------|
| Docker | 20.10+ | 容器运行时，所有服务基于 Docker 部署 |
| Docker Compose | v2.0+ | 服务编排工具（随 Docker Desktop 安装） |
| Git | 任意 | 版本控制 |
| SOPS | 3.12+ | 密钥加密/解密工具（生产环境部署需要） |
| age | 1.3+ | SOPS 的加密后端（生产环境部署需要） |

**开发环境只需 Docker 和 Docker Compose**，SOPS 和 age 仅在生产部署解密密钥时需要。

---

## 安装步骤

### 1. 克隆仓库

```bash
git clone https://github.com/wangdianwen/noda-infra.git
cd noda-infra
```

### 2. 配置环境变量

```bash
# 复制环境变量模板
cp config/environments/.env.example docker/.env
```

编辑 `docker/.env`，填入实际的密码和 Token。必填项包括：

- `POSTGRES_USER` / `POSTGRES_PASSWORD` -- 数据库凭据
- `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` -- Keycloak 管理员凭据
- `CLOUDFLARE_TUNNEL_TOKEN` -- Cloudflare Tunnel Token（开发环境可留空）

可选但生产环境需要的变量：

- `SMTP_HOST` / `SMTP_PORT` / `SMTP_USER` / `SMTP_PASSWORD` / `SMTP_FROM` -- Keycloak 邮件服务配置
- `RESEND_API_KEY` -- findclass-ssr 邮件服务
- `B2_ACCOUNT_ID` / `B2_APPLICATION_KEY` -- Backblaze B2 备份存储

完整的变量说明见 [CONFIGURATION.md](CONFIGURATION.md)。

### 3. 创建外部网络

所有服务运行在同一个外部 Docker 网络 `noda-network` 中，首次部署需要创建：

```bash
docker network create noda-network
```

> 提示：如果网络已存在，此命令会报错但不影响后续操作。

---

## 首次运行

### 启动基础设施服务

**开发环境**（推荐本地使用）：

```bash
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d
```

**生产环境**：

```bash
# 一键部署（推荐）
bash scripts/deploy/deploy-infrastructure-prod.sh

# 或手动启动
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml up -d
```

> 注意：生产部署脚本实际使用三个 compose 文件（base + prod + dev），同时启动基础设施和开发数据库。

启动的服务包括：PostgreSQL（生产 + 开发）、Keycloak、Nginx、noda-ops、findclass-ssr。

### 单独启动应用服务（findclass-ssr）

如果需要单独构建和启动 findclass-ssr，可以使用独立的 app compose 文件：

```bash
# 构建镜像
docker compose -f docker/docker-compose.app.yml build findclass-ssr

# 启动服务
docker compose -f docker/docker-compose.app.yml up -d findclass-ssr
```

> 注意：`VITE_*` 构建参数在 `docker build` 时写入前端 JS 文件，修改后必须重新构建镜像。

### 验证服务状态

```bash
# 查看所有容器状态
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml ps

# 或使用验证脚本
bash scripts/verify/verify-infrastructure.sh
```

**预期输出** -- 所有服务状态为 `Up`：

```
noda-infra-postgres-prod   Up X minutes   5432/tcp
noda-infra-postgres-dev    Up X minutes   5432->5433/tcp
noda-infra-keycloak-1      Up X minutes   8080/tcp, 9000/tcp
noda-infra-nginx           Up X minutes   80->8081/tcp (dev) / 80/tcp (prod)
noda-ops                   Up X minutes
findclass-ssr              Up X minutes   3001->3002/tcp (dev) / 3001/tcp (prod)
```

### 初始化数据库

首次部署时需要确保 PostgreSQL 中创建了所有必要数据库：

```bash
bash scripts/init-databases.sh
```

该脚本会创建以下数据库（如果不存在）：

| 数据库 | 用途 |
|--------|------|
| `noda_prod` | findclass 应用主数据库 |
| `keycloak` | Keycloak 认证数据库 |

### 检查服务端点

```bash
# Keycloak Realm 端点（生产环境）
curl -s https://auth.noda.co.nz/realms/noda | jq -r '.realm'
# 预期输出: noda

# 应用健康检查（容器内）
docker exec findclass-ssr wget -qO- http://localhost:3001/api/health
```

---

## 常见问题

### 问题 1: Docker 网络 "noda-network" 不存在

**症状**：容器启动失败，日志显示 `network noda-network declared as external, but could not be found`

**解决方案**：

```bash
docker network create noda-network
```

然后重新启动服务。

### 问题 2: Keycloak 数据库连接失败

**症状**：Keycloak 日志显示 `FATAL: database "keycloak" does not exist` 或 `FATAL: password authentication failed`

**解决方案**：

1. 确认 `docker/.env` 中 `POSTGRES_USER`、`POSTGRES_PASSWORD` 配置正确
2. 手动初始化数据库：

   ```bash
   bash scripts/init-databases.sh
   ```

3. 重启 Keycloak：

   ```bash
   docker restart noda-infra-keycloak-1
   ```

### 问题 3: 端口被占用

**症状**：容器启动失败，日志显示 `port is already allocated`

**解决方案**：

开发环境使用非默认端口避免冲突：

| 服务 | 开发端口 | 生产端口 |
|------|----------|----------|
| PostgreSQL (dev) | 5433 | -- |
| PostgreSQL (prod) | 不暴露 | 不暴露 |
| Nginx | 8081 | 80 |
| findclass-ssr | 3002 | 3001（内部） |
| Keycloak | 8080 | 8080 |

检查占用端口的进程：

```bash
lsof -i :8080
```

### 问题 4: SOPS 解密失败

**症状**：`Error: cannot decrypt` 或部署脚本在解密步骤失败

**解决方案**：

1. 确认 age 密钥文件存在：

   ```bash
   ls config/keys/git-age-key.txt
   ```

2. 设置环境变量：

   ```bash
   export SOPS_AGE_KEY_FILE=config/keys/git-age-key.txt
   ```

3. 测试解密：

   ```bash
   sops --decrypt config/secrets.sops.yaml
   ```

### 问题 5: 前端配置修改后未生效

**症状**：修改了 `VITE_KEYCLOAK_URL` 等环境变量但前端行为不变

**原因**：`VITE_*` 变量在 `docker build` 阶段写入 JS 文件，运行时环境变量仅影响 SSR 服务端

**解决方案**：必须重新构建镜像：

```bash
docker compose -f docker/docker-compose.app.yml build findclass-ssr --no-cache
docker compose -f docker/docker-compose.app.yml up -d findclass-ssr
```

### 问题 6: findclass-ssr 构建失败（lru-cache ESM 兼容）

**症状**：构建或运行时报错 `Named export 'LRUCache' not found`

**原因**：`lru-cache` 包的 ESM/CJS 兼容性问题

**解决方案**：Dockerfile 中已包含 sed 修复步骤，确保使用最新的 Dockerfile 重新构建：

```bash
docker compose -f docker/docker-compose.app.yml build findclass-ssr --no-cache
```

---

## 下一步

环境搭建完成后，可以继续阅读以下文档：

- [架构文档](architecture.md) -- 了解系统架构、组件关系和数据流
- [配置指南](CONFIGURATION.md) -- 完整的环境变量和配置文件说明
- [部署指南](DEPLOYMENT_GUIDE.md) -- 生产环境完整部署流程和故障排查
- [密钥管理](secrets-management.md) -- SOPS + age 密钥加密方案
