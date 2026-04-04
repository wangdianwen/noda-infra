# Google OAuth 集成指南

## 概述

本指南说明如何在 Keycloak 中配置 Google Identity Provider,实现 Google 账号登录功能。提供手动配置和自动化脚本两种方式。

## 前置条件

- Keycloak 容器已启动并运行(Plan 52-01)
- noda Realm 已创建
- 拥有 Google Cloud Console 项目访问权限

## 步骤 1: 配置 Google Cloud Console

### 1.1 获取 OAuth 2.0 凭证

1. 访问 [Google Cloud Console](https://console.cloud.google.com/)
2. 选择现有项目或创建新项目
3. 导航到: APIs & Services → Credentials
4. 如果已有 OAuth 2.0 Client ID,复制 Client ID 和 Client Secret
5. 如果没有,创建新的 OAuth 2.0 Client ID:
   - Click "Create Credentials" → "OAuth client ID"
   - Application type: Web application
   - Name: Noda Keycloak
   - Authorized redirect URIs: 添加以下 URI
     ```
     https://noda.co.nz/realms/noda/broker/google/endpoint
     ```
   - Click "Create"

### 1.2 更新回调 URL

**重要**: 必须添加 Keycloak 的回调 URL,否则 OAuth 登录会失败。

在现有 OAuth 2.0 Client ID 中添加新的回调 URL:
```
https://noda.co.nz/realms/noda/broker/google/endpoint
```

### 1.3 设置环境变量

将获取的 Client ID 和 Client Secret 设置到环境变量:
```bash
export GOOGLE_OAUTH_CLIENT_ID="your_google_client_id_here"
export GOOGLE_OAUTH_CLIENT_SECRET="your_google_client_secret_here"
```

## 步骤 2: 配置 Keycloak Google Identity Provider

### 方式 1: 自动化脚本(推荐)

1. 确保环境变量已设置:
   ```bash
   echo $GOOGLE_OAUTH_CLIENT_ID
   echo $GOOGLE_OAUTH_CLIENT_SECRET
   ```

2. 运行配置脚本:
   ```bash
   bash infra/keycloak/scripts/configure-google-idp.sh
   ```

3. 验证配置成功:
   ```bash
   bash scripts/test-google-oauth.sh
   ```

### 方式 2: 手动配置

1. 访问 Keycloak Admin Console:
   ```
   https://noda.co.nz/auth/admin
   ```

2. 登录(使用管理员账号)

3. 选择 noda Realm

4. 导航到: Identity providers → Add provider → Google

5. 填写配置:
   - Alias: google
   - Display name: Google
   - Client ID: `${GOOGLE_OAUTH_CLIENT_ID}`
   - Client secret: `${GOOGLE_OAUTH_CLIENT_SECRET}`
   - Hosted domain: (留空)

6. 点击 "Add"

7. 验证配置:
   - 在 Identity providers 列表中应看到 Google
   - 状态应为 "Enabled"

## 步骤 3: 配置 Keycloak Client

前端应用需要配置 Valid Redirect URIs,否则 OAuth 回调会失败。

1. 在 Keycloak Admin Console 中,导航到: Clients → noda-frontend

2. 点击 "Settings" 标签

3. 配置 Valid Redirect URIs:
   ```
   https://noda.co.nz/*
   ```

4. 配置 Web Origins:
   ```
   https://noda.co.nz
   ```

5. 点击 "Save"

## 步骤 4: 测试 Google OAuth 登录

1. 运行测试脚本:
   ```bash
   bash scripts/test-google-oauth.sh
   ```

2. 点击输出的 URL 或复制到浏览器

3. 验证登录流程:
   - ✓ 看到 Google 登录页面
   - ✓ 可以选择 Google 账号
   - ✓ 授权页面显示正确的应用名称和权限
   - ✓ 授权后成功重定向
   - ✓ Keycloak 中创建了新用户(首次登录)

4. 检查 Keycloak 中的用户:
   - 导航到: Users
   - 搜索刚才登录的 Google 账号邮箱
   - 验证用户信息(Identity Provider Links 显示 google)

## 故障排查

### 错误: redirect_uri_mismatch

**原因**: Google Cloud Console 中未添加 Keycloak 的回调 URL

**解决**: 在 Google Cloud Console → APIs & Services → Credentials → OAuth 2.0 Client ID → Authorized redirect URIs 中添加:
```
https://noda.co.nz/realms/noda/broker/google/endpoint
```

### 错误: Invalid client

**原因**: Google OAuth Client ID 或 Client Secret 不正确

**解决**:
1. 检查环境变量 `GOOGLE_OAUTH_CLIENT_ID` 和 `GOOGLE_OAUTH_CLIENT_SECRET` 是否正确
2. 在 Keycloak Admin Console 中重新配置 Identity Provider

### 错误: Invalid redirect URI

**原因**: Keycloak Client 的 Valid Redirect URIs 配置不正确

**解决**: 在 Keycloak Admin Console → Clients → noda-frontend → Settings → Valid Redirect URIs 中添加:
```
https://noda.co.nz/*
```

### 登录后重定向失败

**原因**: Keycloak Client 的 Web Origins 配置不正确

**解决**: 在 Keycloak Admin Console → Clients → noda-frontend → Settings → Web Origins 中添加:
```
https://noda.co.nz
```

## 安全注意事项

- ✓ Client Secret 应存储在环境变量中,不要硬编码到代码库
- ✓ 使用 HTTPS(通过 Cloudflare Tunnel SSL termination)
- ✓ 限制 Google OAuth 应用的作用域(仅请求必要的权限)
- ✓ 定期审查已授权的第三方应用

## 下一步

完成配置后,继续执行 Plan 52-03-A: 前端认证逻辑迁移 - 客户端初始化

## 参考资料

- [Keycloak Google Identity Provider 文档](https://www.keycloak.org/docs/26.0/server_admin/index.html#_google_identity_provider)
- [Google OAuth 2.0 文档](https://developers.google.com/identity/protocols/oauth2)
