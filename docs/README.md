# Noda Infra 文档

欢迎来到 Noda Infra 项目文档！

## 📋 快速导航

### 🚀 部署相关

- **[基础设施部署指南](/docs/DEPLOYMENT_GUIDE.md)** ⭐
  - 一键部署 PostgreSQL、Keycloak、Nginx
  - 详细的部署流程和验证步骤
  - 完整的故障排查指南
  - **适用场景**：首次部署、重新部署、故障恢复

- **[架构设计](/docs/architecture.md)**
  - 整体架构图
  - 安全原则和设计
  - 服务分组和网络拓扑
  - **适用场景**：了解系统架构、安全设计

### 🔧 配置相关

- **[Keycloak 脚本说明](/docs/KEYCLOAK_SCRIPTS.md)**
  - 部署脚本清单
  - 脚本依赖关系
  - 最佳实践
  - **适用场景**：了解 Keycloak 部署脚本

- **[密钥管理指南](/docs/secrets-management.md)**
  - SOPS + age 加密
  - 密钥配置和使用
  - 安全注意事项
  - **适用场景**：管理敏感信息、添加新密钥

## 🎯 按场景查找文档

### 我想部署系统

1. **首次部署** → [基础设施部署指南](/docs/DEPLOYMENT_GUIDE.md)
2. **了解架构** → [架构设计](/docs/architecture.md)
3. **配置密钥** → [密钥管理指南](/docs/secrets-management.md)

### 我想排查问题

1. **部署失败** → [基础设施部署指南 - 故障排查](/docs/DEPLOYMENT_GUIDE.md#故障排查)
2. **Keycloak 问题** → [基础设施部署指南 - Google OAuth](/docs/DEPLOYMENT_GUIDE.md#问题-3-google-oauth-登录失败)
3. **密钥解密失败** → [密钥管理指南 - 故障排除](/docs/secrets-management.md#故障排除)

### 我想了解系统

1. **整体架构** → [架构设计](/docs/architecture.md)
2. **部署脚本** → [Keycloak 脚本说明](/docs/KEYCLOAK_SCRIPTS.md)
3. **安全设计** → [架构设计 - 安全原则](/docs/architecture.md#安全原则)

## 📊 文档结构

```
docs/
├── README.md                      # 本文档（导航索引）
├── DEPLOYMENT_GUIDE.md            # 主部署指南 ⭐
├── architecture.md                # 架构设计
├── KEYCLOAK_SCRIPTS.md            # Keycloak 脚本说明
└── secrets-management.md          # 密钥管理指南
```

## 🚀 快速开始

### 一键部署

```bash
# 从项目根目录执行
bash scripts/deploy/deploy-infrastructure-prod.sh
```

这个命令会自动完成：
- ✅ 验证环境配置
- ✅ 初始化所有数据库
- ✅ 启动基础设施服务（PostgreSQL, Keycloak, Nginx）
- ✅ 配置 Keycloak（realm, client, Google OAuth）

### 验证部署

```bash
# 检查容器状态
docker ps --filter "name=noda-infra"

# 检查 Keycloak 日志
docker logs noda-infra-keycloak-1 --tail 20

# 测试 realm 端点
curl -s https://auth.noda.co.nz/realms/noda | jq -r '.realm'
```

## 🔗 外部资源

- [Docker Compose 文档](https://docs.docker.com/compose/)
- [Keycloak 官方文档](https://www.keycloak.org/documentation)
- [SOPS 加密工具](https://github.com/getsops/sops)
- [age 加密工具](https://github.com/FiloSottile/age)

## 💡 贡献指南

文档更新规则：
1. **保持精简**：只保留必要信息
2. **合并重复**：同类文档整合为一个
3. **删除过时**：更新后立即删除旧版本
4. **中文优先**：所有文档使用中文

## 📞 获取帮助

如果文档没有解决你的问题：

1. **查看日志**：
   ```bash
   docker logs noda-infra-keycloak-1
   docker logs noda-infra-postgres-1
   ```

2. **重新部署**：
   ```bash
   bash scripts/deploy/deploy-infrastructure-prod.sh
   ```

3. **检查配置**：
   ```bash
   # 验证密钥文件
   ls -la config/secrets.sops.yaml
   ls -la config/keys/git-age-key.txt

   # 测试解密
   export SOPS_AGE_KEY_FILE=/Users/dianwenwang/Project/noda-infra/config/keys/git-age-key.txt
   sops --decrypt config/secrets.sops.yaml
   ```

---

**最后更新**: 2026-04-06
**维护者**: Noda Infra Team
