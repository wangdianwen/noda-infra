# Jenkins Doppler 凭据配置指南

## 为什么需要配置 Service Token？

Jenkins Pipeline 运行在**非交互式环境**中，无法使用 `doppler login`。因此需要使用 **Service Token** (`dp.st.xxx`) 来访问 Doppler 密钥。

## 区别对比

| 环境 | 认证方式 | Token 类型 | 示例 |
|------|----------|-----------|------|
| **本地开发** | `doppler login` | CLI Token | `dp.ct.xxx` |
| **Jenkins Pipeline** | 凭据存储 | Service Token | `dp.st.prd.xxx` |

---

## 步骤 1: 生成 Service Token

### 1.1 访问 Doppler Dashboard

```bash
# 在浏览器中打开
https://dashboard.doppler.com
```

### 1.2 导航到项目

1. 选择项目：**noda**
2. 选择配置：**prd**（生产环境）

### 1.3 生成 Service Token

1. 点击左侧菜单 **Settings**（齿轮图标）
2. 选择 **Service Tokens**
3. 点击 **Generate Service Token**
4. 填写配置：
   - **Name**: `Jenkins noda-infra`（或其他描述性名称）
   - **Token Access**: 选择 **Read Only**（推荐）
   - **Expiration**: 选择 `90 days` 或更长
   - **Project Scope**: 选择 `noda` 项目
   - **Config Scope**: 选择 `prd` 配置（如果需要 pre-prod，单独生成另一个）

### 1.4 保存 Token

1. 点击 **Generate Token**
2. **立即复制 Token**（格式：`dp.st.prd.xxx`）
3. **保存到安全位置**（此 Token 只显示一次！）

### 1.5 重复 pre-prod Token（如果需要）

为 pre-prod 环境生成另一个 Service Token：

1. 返回 **Settings** → **Service Tokens**
2. 点击 **Generate Service Token**
3. 配置：
   - **Name**: `Jenkins noda-infra pre-prod`
   - **Config Scope**: 选择 `pre` 配置（注意：不是 `prd`）

4. 复制 Token（格式：`dp.st.pre.xxx`）

---

## 步骤 2: 在 Jenkins 中配置凭据

### 2.1 打开 Jenkins

```bash
# 在浏览器中打开
http://localhost:8888
```

### 2.2 登录 Jenkins

使用您的管理员账户登录。

### 2.3 配置 prod 凭据

1. 点击 **Manage Jenkins**（系统管理）
2. 点击 **Credentials**（凭据）
3. 选择 **Global credentials (unrestricted)**（全局凭据）
4. 点击 **Add Credentials**（添加凭据）
5. 填写表单：
   - **Kind**: **Secret text**
   - **Secret**: 粘贴 prod Service Token (`dp.st.prd.xxx`)
   - **ID**: `doppler-service-token`（必须与此名称一致）
   - **Description**: `Doppler Service Token for noda prd config`
6. 点击 **Create**

### 2.4 配置 pre-prod 凭据（如果使用）

重复上述步骤，创建第二个凭据：

- **ID**: `doppler-service-token-preprod`
- **Secret**: pre-prod Service Token (`dp.st.pre.xxx`)
- **Description**: `Doppler Service Token for noda pre config`

---

## 步骤 3: 验证配置

### 3.1 测试 prod Pipeline

```bash
# 方法 1: Jenkins UI
# 1. 打开 Jenkins → noda-apps-deploy
# 2. 点击 "Build Now"
# 3. 查看控制台输出，确认密钥加载成功

# 方法 2: 命令行
curl -X POST "http://localhost:8888/job/noda-apps-deploy/build" \
  --user "admin:YOUR_JENKINS_PASSWORD"
```

### 3.2 预期成功输出

在 Jenkins 控制台输出中，您应该看到：

```
[Doppler] Loading secrets from config: prd
[Doppler] Secrets loaded successfully
[INFO] DATABASE_URL=postgresql://...
[INFO] KEYCLOAK_REALM=noda
...
```

如果看到错误：

```
ERROR: Doppler 密钥拉取失败（检查 DOPPLER_TOKEN 是否有效）
```

**解决方案**：
1. 检查凭据 ID 是否为 `doppler-service-token`
2. 检查 Token 是否正确复制（没有多余空格）
3. 检查 Token 是否有权限访问项目

---

## 常见问题

### Q1: 我需要配置两个 Token 吗？

**A**: 取决于您的使用场景：

- **仅使用 prod Pipeline**: 只需配置 `doppler-service-token`（prd）
- **使用 pre-prod Pipeline**: 需要配置两个：
  - `doppler-service-token`（prd，用于 prod Pipeline）
  - `doppler-service-token-preprod`（pre，用于 pre-prod Pipeline）

### Q2: Token 过期了怎么办？

**A**: Service Token 过期后：
1. 重新生成新的 Service Token（步骤 1）
2. 在 Jenkins 中更新凭据：
   - Manage Jenkins → Credentials → doppler-service-token → Update
   - 粘贴新 Token 并保存

### Q3: 我能看到 Token 的值吗？

**A**: Service Token 只在生成时显示一次。如果丢失：
1. 删除旧凭据
2. 重新生成新 Token
3. 重新配置 Jenkins 凭据

### Q4: 本地开发需要配置这些 Token 吗？

**A**: **不需要**！本地开发直接使用 `doppler login` 即可，Service Token 仅用于 Jenkins 等 CI/CD 环境。

---

## 安全建议

1. **权限最小化**: Service Token 使用 **Read Only** 权限
2. **定期轮换**: 每 90 天重新生成 Token
3. **环境隔离**: prod 和 pre-prod 使用不同的 Token
4. **监控使用**: 在 Doppler Dashboard 中监控 Token 使用情况
5. **立即撤销**: 如果 Token 泄露，立即在 Doppler Dashboard 中撤销

---

## 相关文件

- **Jenkins Pipeline**: `jenkins/Jenkinsfile.noda-apps` (prod)
- **Jenkins Pipeline**: `jenkins/Jenkinsfile.noda-apps-preprod` (pre-prod)
- **密钥加载脚本**: `scripts/lib/secrets.sh`

---

**配置完成后，Jenkins Pipeline 就能自动加载 Doppler 密钥了！** 🎉
