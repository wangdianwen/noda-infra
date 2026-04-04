# Google Identity Provider 配置

## Callback URL 说明

### Keycloak 作为统一认证中心

当使用 Google OAuth 登录时，回调流程如下：

```
用户点击 Google 登录
    ↓
应用重定向到 Keycloak
    ↓
Keycloak 重定向到 Google OAuth
    ↓
用户授权成功
    ↓
Google 回调到 Keycloak
    ↓
Keycloak 创建/更新用户
    ↓
Keycloak 回调到应用
```

### 正确的 Callback URL 配置

**在 Google Cloud Console 中添加**：

```
https://noda.co.nz/realms/noda/broker/google/endpoint
```

### 为什么是 Keycloak 的 URL？

1. **Keycloak 作为中间人**：
   - 应用不需要直接配置 Google OAuth
   - Keycloak 统一管理所有社交登录
   - 便于未来添加 Facebook/Apple 登录

2. **安全性**：
   - Client Secret 只存储在 Keycloak
   - 应用端不暴露任何 OAuth 凭证
   - 统一的 token 管理

3. **多应用支持**：
   - 多个应用共享同一个 Google Identity Provider
   - 用户在所有应用中使用同一个 Google 账号
   - 统一的用户身份管理

### Keycloak Realm 配置

在 Keycloak Admin Console 中：

1. 创建 Realm: `noda`
2. 添加 Identity Provider: Google
3. 配置 Client ID 和 Secret
4. 设置 Redirect URI: `https://noda.co.nz/realms/noda/broker/google/endpoint`

### 应用端配置

应用只需要配置 Keycloak 的回调 URL：

```typescript
// 应用端只需配置 Keycloak 回调
keycloak.login({
  idpHint: 'google',
  redirectUri: window.location.origin + '/auth/callback'
})
```

应用不需要直接配置 Google OAuth！
