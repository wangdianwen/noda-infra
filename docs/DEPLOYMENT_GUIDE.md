# 基础设施部署指南

## 📋 目录

- [快速部署](#快速部署)
- [核心脚本](#核心脚本)
- [部署流程](#部署流程)
- [故障排查](#故障排查)

## 🚀 快速部署

### 一键部署（推荐）

```bash
# 从项目根目录执行
bash scripts/deploy/deploy-infrastructure-prod.sh
```

这个脚本会自动完成：
1. ✅ 验证环境配置
2. ✅ 初始化所有数据库
3. ✅ 启动基础设施服务（PostgreSQL, Keycloak, Nginx）
4. ✅ 等待服务就绪
5. ✅ 配置 Keycloak（realm, client, Google OAuth）

## 📁 核心脚本

### 1. 部署脚本

| 脚本 | 功能 | 调用 |
|------|------|------|
| `scripts/deploy/deploy-infrastructure-prod.sh` | 完整部署流程 | 直接调用 |

### 2. 辅助脚本（被 deploy 调用）

| 脚本 | 功能 | 说明 |
|------|------|------|
| `scripts/init-databases.sh` | 初始化数据库 | 创建 keycloak, keycloak_db, findclass_db 等数据库 |
| `scripts/setup-keycloak-full.sh` | 配置 Keycloak | 创建 realm, client, Google Identity Provider |

## 🔄 部署流程

### 步骤 1: 验证环境

```bash
# 检查必需文件
config/secrets.sops.yaml  # 加密的凭据（Google OAuth, 数据库密码等）

# 检查必需工具
docker --version
docker-compose --version
```

### 步骤 2: 初始化数据库

自动执行 `scripts/init-databases.sh`，创建以下数据库：

- `keycloak` - Keycloak 认证服务（主数据库）
- `keycloak_db` - Keycloak 认证服务（旧版）
- `findclass_db` - Findclass 应用数据库
- `noda_prod` - Noda 生产数据库
- `oneteam_prod` - OneTeam 生产数据库

### 步骤 3: 启动基础设施

```bash
docker-compose -f docker/docker-compose.yml up -d postgres keycloak nginx
```

启动的服务：
- **PostgreSQL**: 数据库服务
- **Keycloak**: 认证服务
- **Nginx**: 反向代理

### 步骤 4: 等待服务就绪

- **PostgreSQL**: 等待 `pg_isready` 响应（最多 30 秒）
- **Keycloak**: 等待 "Keycloak started" 日志（最多 60 秒）

### 步骤 5: 配置 Keycloak

自动执行 `scripts/setup-keycloak-full.sh`：

1. **解密凭据**: 从 `config/secrets.sops.yaml` 提取 Google OAuth 凭据
2. **创建 realm**: 创建 `noda` realm
3. **创建 client**: 创建 `noda-frontend` client
4. **配置 Google OAuth**: 配置 Google Identity Provider

## 🔐 密钥管理

### 加密文件位置

```
config/secrets.sops.yaml  # 加密的凭据文件
config/keys/git-age-key.txt  # AGE 解密密钥
```

### 加密内容

- `google_oauth_client_id` - Google OAuth 客户端 ID
- `google_oauth_client_secret` - Google OAuth 客户端密钥
- `keycloak_admin_password` - Keycloak 管理员密码
- `postgres_password` - PostgreSQL 密码
- `cloudflare_tunnel_token` - Cloudflare Tunnel 令牌

### 解密方式

```bash
# 设置密钥文件路径
export SOPS_AGE_KEY_FILE=/path/to/config/keys/git-age-key.txt

# 解密查看
sops --decrypt config/secrets.sops.yaml
```

## 📊 部署验证

### 1. 检查容器状态

```bash
docker ps --filter "name=noda-infra"
```

**预期输出**：
```
noda-infra-postgres-1   Up X minutes   5432/tcp
noda-infra-keycloak-1   Up X minutes   8080/tcp, 9000/tcp
noda-infra-nginx-1       Up X minutes   80/tcp
```

### 2. 检查 Keycloak 日志

```bash
docker logs noda-infra-keycloak-1 --tail 20
```

**预期输出**：
```
INFO  [io.quarkus] (main) Keycloak 26.2.3 on JVM started
```

### 3. 检查数据库

```bash
docker exec noda-infra-postgres-1 psql -U postgres -d postgres -c \
  "SELECT datname FROM pg_database WHERE datname LIKE '%keycloak%' OR datname LIKE '%prod%';"
```

**预期输出**：
```
keycloak
noda_prod
oneteam_prod
```

### 4. 检查 Realm 端点

```bash
curl -s https://auth.noda.co.nz/realms/noda | jq -r '.realm'
```

**预期输出**：
```
noda
```

### 5. 检查 Google Identity Provider

```bash
# 需要 Keycloak 管理员密码
docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password <密码>

docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh get realms/noda/identity-provider/instances/google
```

**预期输出**：包含 `"providerId": "google"` 和 `"enabled": true`

## 🔧 故障排查

### 问题 1: 部署失败 - 数据库不存在

**症状**：Keycloak 日志显示 `FATAL: database "keycloak" does not exist`

**解决方案**：
```bash
# 手动初始化数据库
bash scripts/init-databases.sh

# 重启 Keycloak
docker restart noda-infra-keycloak-1
```

### 问题 2: 部署失败 - Page not found

**症状**：访问 `https://auth.noda.co.nz/realms/noda` 显示 404

**解决方案**：
```bash
# 手动配置 Keycloak
bash scripts/setup-keycloak-full.sh
```

### 问题 3: Google OAuth 登录失败

#### 症状 A: redirect_uri_mismatch（错误 400）

**错误信息**：
```
错误 400：redirect_uri_mismatch
无法登录，因为此应用发送的请求无效。
```

**原因**：Google Console 中配置的 redirect URI 与 Keycloak 发送的不匹配

**解决方案**：

1. **检查 Keycloak 配置**：
   ```bash
   KEYCLOAK_ADMIN_PASSWORD=$(docker exec noda-infra-keycloak-1 printenv | grep KEYCLOAK_ADMIN_PASSWORD | cut -d= -f2)

   docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh config credentials \
     --server http://localhost:8080 --realm master --user admin --password "$KEYCLOAK_ADMIN_PASSWORD"

   docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh get realms/noda/identity-provider/instances/google | jq -r '.config.redirectUri'
   ```

   **预期输出**：`https://auth.noda.co.nz/realms/noda/broker/google/endpoint`

2. **在 Google Cloud Console 中配置**：

   访问：https://console.cloud.google.com/

   - 进入 **APIs & Services** > **Credentials**
   - 找到 OAuth 2.0 Client ID
   - 在 **Authorized redirect URIs** 中添加：
     ```
     https://auth.noda.co.nz/realms/noda/broker/google/endpoint
     ```
   - 保存更改（可能需要 1-5 分钟生效）

3. **重新配置 Keycloak**：
   ```bash
   bash scripts/setup-keycloak-full.sh
   ```

#### 症状 B: CORS 错误

**错误信息**：
```
Access to fetch at 'https://auth.noda.co.nz/realms/noda/protocol/openid-connect/token'
from origin 'https://class.noda.co.nz' has been blocked by CORS policy
```

**原因**：Keycloak client 的 Web Origins 配置不正确

**解决方案**：

1. **检查当前配置**：
   ```bash
   KEYCLOAK_ADMIN_PASSWORD=$(docker exec noda-infra-keycloak-1 printenv | grep KEYCLOAK_ADMIN_PASSWORD | cut -d= -f2)

   docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh config credentials \
     --server http://localhost:8080 --realm master --user admin --password "$KEYCLOAK_ADMIN_PASSWORD"

   docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh get realms/noda/clients | \
     jq -r '.[] | select(.clientId=="noda-frontend") | .webOrigins'
   ```

2. **重新配置 Keycloak**（会自动修复 CORS）：
   ```bash
   bash scripts/setup-keycloak-full.sh
   ```

3. **重启 Keycloak**（使配置生效）：
   ```bash
   docker restart noda-infra-keycloak-1
   sleep 15
   ```

#### 症状 C: 登录出错了（通用错误）

**排查步骤**：

1. **检查 Keycloak 日志**：
   ```bash
   docker logs noda-infra-keycloak-1 --tail 50 | grep -i "error\|warn"
   ```

2. **检查 Google IdP 配置**：
   ```bash
   KEYCLOAK_ADMIN_PASSWORD=$(docker exec noda-infra-keycloak-1 printenv | grep KEYCLOAK_ADMIN_PASSWORD | cut -d= -f2)

   docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh config credentials \
     --server http://localhost:8080 --realm master --user admin --password "$KEYCLOAK_ADMIN_PASSWORD"

   docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh get realms/noda/identity-provider/instances/google | jq '.'
   ```

3. **验证 realm 端点**：
   ```bash
   curl -I https://auth.noda.co.nz/realms/noda
   ```

   **预期**：HTTP 200

4. **重新配置**：
   ```bash
   bash scripts/setup-keycloak-full.sh
   ```

### 问题 4: SOPS 解密失败

**症状**：`Error: cannot decrypt` 或 `Error: data could not be decrypted`

**原因**：AGE 密钥文件未找到或不匹配

**解决方案**：
```bash
# 确认密钥文件存在
ls -la config/keys/git-age-key.txt

# 设置环境变量
export SOPS_AGE_KEY_FILE=/Users/dianwenwang/Project/noda-infra/config/keys/git-age-key.txt

# 测试解密
sops --decrypt config/secrets.sops.yaml
```

### 问题 5: 容器启动超时

**症状**：部署脚本等待容器启动超时

**解决方案**：
```bash
# 手动检查容器状态
docker ps -a

# 查看容器日志
docker logs noda-infra-postgres-1
docker logs noda-infra-keycloak-1

# 手动重启
docker-compose -f docker/docker-compose.yml restart postgres keycloak
```

## 📝 维护命令

### 查看服务状态

```bash
# 所有容器状态
docker-compose -f docker/docker-compose.yml ps

# 实时日志
docker-compose -f docker/docker-compose.yml logs -f
```

### 重启服务

```bash
# 重启所有基础设施
docker-compose -f docker/docker-compose.yml restart

# 重启单个服务
docker restart noda-infra-keycloak-1
```

### 更新配置

```bash
# 1. 更新代码或配置文件
vim docker/docker-compose.yml
vim config/secrets.sops.yaml

# 2. 重新部署
bash scripts/deploy/deploy-infrastructure-prod.sh
```

## 🎯 部署检查清单

部署前：
- [ ] Docker 已安装
- [ ] Docker Compose 已安装
- [ ] `config/secrets.sops.yaml` 文件存在
- [ ] `config/keys/git-age-key.txt` 密钥文件存在
- [ ] 可以成功解密 `secrets.sops.yaml`

部署后：
- [ ] PostgreSQL 容器运行正常
- [ ] Keycloak 容器运行正常
- [ ] Nginx 容器运行正常
- [ ] 所有数据库已创建
- [ ] `noda` realm 已创建
- [ ] `noda-frontend` client 已创建
- [ ] Google Identity Provider 已配置
- [ ] 可以访问 `https://auth.noda.co.nz/realms/noda`
- [ ] 可以访问 `https://auth.noda.co.nz/admin`

## 📞 紧急恢复

如果部署完全失败，可以手动恢复：

```bash
# 1. 停止所有容器
docker-compose -f docker/docker-compose.yml down

# 2. 清理容器（保留数据卷）
docker-compose -f docker/docker-compose.yml rm -f

# 3. 重新部署
bash scripts/deploy/deploy-infrastructure-prod.sh
```

## 🔗 相关文档

- [Keycloak 脚本说明](/docs/KEYCLOAK_SCRIPTS.md)
- [密钥管理](/docs/secrets-management.md)
- [数据量校验](/scripts/backup/DATA_VOLUME_CHECK.md)
