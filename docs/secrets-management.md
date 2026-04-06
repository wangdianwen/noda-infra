# 密钥管理指南

## 🔐 加密密钥存储

本项目使用 **SOPS + age** 加密敏感信息，允许安全地将密钥存储在 Git 中。

---

## 📋 密钥配置文件

### config/secrets.sops.yaml
- **未加密版本**（本地）：包含明文密钥，**不提交到 Git**
- **加密版本**（Git）：SOPS 加密后提交到 Git

---

## 🚀 使用方法

### 1. 添加密钥到配置文件

```bash
# 编辑加密的配置文件
cd /Users/dianwenwang/Project/noda-infra
sops config/secrets.sops.yaml
```

在文件中添加或修改密钥：
```yaml
cloudflare_tunnel_token: "your_actual_token_here"
google_oauth_client_id: "your_client_id"
google_oauth_client_secret: "your_client_secret"
```

### 2. 保存加密文件

```bash
# SOPS 会自动加密保存，直接提交即可
git add config/secrets.sops.yaml
git commit -m "feat: update encrypted secrets"
git push
```

### 3. 部署时自动解密

部署脚本会自动解密，无需手动操作：

```bash
# 一键部署（自动解密）
bash scripts/deploy/deploy-infrastructure-prod.sh
```

如果需要手动解密查看：

```bash
# 设置密钥文件路径
export SOPS_AGE_KEY_FILE=/Users/dianwenwang/Project/noda-infra/config/keys/git-age-key.txt

# 解密并查看
sops --decrypt config/secrets.sops.yaml
```

---

## 🔑 获取 Cloudflare Tunnel Token

1. 访问 [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. 进入 **Zero Trust** → **Networks** → **Tunnels**
3. 选择您的隧道
4. 点击 **Token** → **Create Token**
5. 复制生成的 token

---

## ⚠️ 安全注意事项

- ✅ **加密后的文件** 可以提交到 Git
- ❌ **未加密的文件** 永远不要提交
- 🔒 私钥文件 (`config/keys/git-age-key.txt`) 不要提交
- 📝 将私钥备份到安全的地方

---

## 🛠️ 故障排除

### 解密失败

```bash
# 检查私钥是否存在
ls -la /Users/dianwenwang/Project/noda-infra/config/keys/git-age-key.txt

# 设置环境变量
export SOPS_AGE_KEY_FILE=/Users/dianwenwang/Project/noda-infra/config/keys/git-age-key.txt

# 测试解密
sops --decrypt config/secrets.sops.yaml
```

### 查看加密内容

```bash
# 设置密钥文件路径
export SOPS_AGE_KEY_FILE=/Users/dianwenwang/Project/noda-infra/config/keys/git-age-key.txt

# 解密并查看（不修改文件）
sops --decrypt config/secrets.sops.yaml
```
