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

### 1. 添加 Cloudflare Tunnel Token

```bash
# 编辑未加密的密钥文件
cd ~/project/noda-infra
nano config/secrets.sops.yaml
```

在文件中添加您的 token：
```yaml
cloudflare_tunnel_token: "your_actual_token_here"
```

### 2. 加密并保存

```bash
# 加密文件
sops --age age1869smm93r878hzgarhv5uggkg58mttaz54l05wwc0s3zmp264e7qw7rc3w \
    --encrypt --encrypted-regex '^(data|string)$' \
    config/secrets.sops.yaml

# 提交到 Git
git add config/secrets.sops.yaml
git commit -m "feat: add encrypted secrets"
git push
```

### 3. 部署时解密

```bash
# 解密到环境变量
eval $(sops --decrypt --extract '["cloudflare_tunnel_token"]' \
    --output-format dotenv config/secrets.sops.yaml)

# 部署
./deploy.sh
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
ls -la config/keys/git-age-key.txt

# 重新生成密钥（如果丢失）
age-keygen -o config/keys/git-age-key.txt
```

### 查看加密内容
```bash
# 解密并查看（不修改文件）
sops --decrypt config/secrets.sops.yaml
```
