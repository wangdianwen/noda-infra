# Keycloak Realm 配置

## 手动配置步骤

### 1. 启动 Keycloak 容器

```bash
docker-compose -f docker-compose.yml -f docker-compose.prod.yml up keycloak -d
```

### 2. 访问 Admin Console

- **内网访问**（开发环境）: http://localhost:8080
- **外网访问**（生产环境）: https://class.noda.co.nz/auth/admin

### 3. 登录 Admin Console

使用环境变量中配置的管理员账号：
- 用户名: `${KEYCLOAK_ADMIN_USER}`（默认：admin）
- 密码: `${KEYCLOAK_ADMIN_PASSWORD}`

### 4. 创建 noda Realm

1. 点击左上角 "Master" 下拉菜单
2. 选择 "Create realm"
3. Name: `noda`
4. 点击 "Create"

### 5. 配置 Realm 设置

#### Realm settings → Login
- User registration: **ON**
- Forgot password: **ON**
- Remember me: **ON**
- Verify email: **OFF**（可选，根据需求）

#### Realm settings → Sessions
- SSO Session Idle: `604800` seconds（7 天）
- SSO Session Max: `3600` seconds（1 小时）

#### Realm settings → Security defences
- Password policy: `minimumLength(6)`

### 6. 配置用户属性（可选）

如果需要扩展用户属性（与现有 profiles 表对应）：
1. Realm settings → User profile
2. 添加属性：
   - `name`（全名）
   - `role`（用户角色：parent/teacher）

### 7. 导出 Realm 配置

```bash
# 导出 realm 配置到容器临时目录
docker exec -it noda-keycloak \
  /opt/keycloak/bin/kc.sh export \
  --realm noda \
  --users realm_file \
  --dir /tmp

# 复制到本地
docker cp noda-keycloak:/tmp/noda-realm.json \
  infra/keycloak/realm/noda-realm.json
```

## Google Identity Provider 配置

### 1. 在 Google Cloud Console 配置 OAuth 回调 URL

访问：Google Cloud Console → APIs & Services → Credentials → OAuth 2.0 Client ID → Authorized redirect URIs

添加新的回调 URL：
```
https://class.noda.co.nz/realms/noda/broker/google/endpoint
```

### 2. 在 Keycloak 中添加 Google Identity Provider

1. Identity providers → Add provider → Google
2. 配置：
   - Client ID: `${GOOGLE_OAUTH_CLIENT_ID}`
   - Client Secret: `${GOOGLE_OAUTH_CLIENT_SECRET}`
   - Redirect URI: （自动生成，无需修改）
3. 点击 "Add"

### 3. 测试 Google 登录

1. 访问 Keycloak 登录页面
2. 点击 "Google" 按钮
3. 完成 OAuth 流程
4. 验证用户成功创建

## Client 配置

### 创建前端应用 Client

1. Clients → Create client
2. 配置：
   - Client type: **OpenID Connect**
   - Client ID: `noda-frontend`
   - Client authentication: **OFF**（公共客户端）
3. 点击 "Next"

4. 配置登录设置：
   - Valid redirect URIs:
     - `https://class.noda.co.nz/*`
     - `http://localhost:5173/*`（开发环境）
   - Web origins:
     - `https://class.noda.co.nz`
     - `http://localhost:5173`（开发环境）
5. 点击 "Save"

### 查看客户端配置

1. 进入 Client: `noda-frontend`
2. 查看 "Credentials" tab
3. 记录以下信息（用于前端配置）：
   - Client ID: `noda-frontend`
   - Client authenticator: （不需要客户端 Secret）

## SMTP 配置验证

### 测试邮件发送

1. Realm settings → Email
2. 配置 SMTP（如果未在环境变量中配置）：
   - From: `${SMTP_FROM}`
   - From display name: `Noda`
   - Host: `${SMTP_HOST}`
   - Port: `${SMTP_PORT}`（587 for STARTTLS）
   - Auth: **ON**
   - Username: `${SMTP_USER}`
   - Password: `${SMTP_PASSWORD}`
3. 点击 "Test connection"
4. 输入测试邮箱地址
5. 预期输出: "Email sent successfully"

## 故障排查

### 容器无法启动

```bash
# 查看容器日志
docker-compose logs keycloak

# 检查数据库连接
docker-compose exec keycloak \
  curl -f http://localhost:8080/health/ready
```

### 数据库连接失败

```bash
# 验证 keycloak schema 存在
docker exec -it noda-postgres \
  psql -U noda_prod_user -d noda_prod -c "\dn keycloak"

# 检查 Keycloak 表是否创建
docker exec -it noda-postgres \
  psql -U noda_prod_user -d noda_prod -c "\dt keycloak.*" | head -20
```

### SMTP 发送失败

1. 检查 SMTP 环境变量配置
2. 验证 Gmail/SendGrid 凭证
3. 查看容器日志中的错误信息

## 未来自动化建议

当前使用手动配置 Realm，未来可通过以下方式自动化：

### 方法 1: Keycloak Admin CLI

```bash
# 使用 kcadm.sh 自动创建 Realm
docker exec -it noda-keycloak \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password ${KEYCLOAK_ADMIN_PASSWORD}

# 导入 Realm 配置
docker exec -it noda-keycloak \
  /opt/keycloak/bin/kcadm.sh create realms \
  -f - < infra/keycloak/realm/noda-realm.json
```

### 方法 2: Keycloak Operator（Kubernetes）

在 Kubernetes 环境中，可使用 Keycloak Operator 自动管理 Realm 配置。

### 方法 3: Docker Entrypoint 脚本

创建自定义 entrypoint 脚本，在容器启动时自动导入 Realm 配置。
