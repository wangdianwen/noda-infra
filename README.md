# noda-infra

> OneTeam 基础设施仓库 - 独立的基础设施配置和部署脚本

**版本**: 1.0.0
**最后更新**: 2026-04-05
**架构**: Docker Compose + Jenkins CI/CD

---

## 📋 仓库概述

noda-infra 包含 OneTeam 项目的所有基础设施配置，包括：

- **PostgreSQL 17.9** - 数据库服务
- **Keycloak 26.2.3** - 认证服务
- **Nginx 1.25** - 反向代理
- **Jenkins 2.x** - CI/CD 流水线
- **Cloudflare Tunnel** - 内网穿透

与应用仓库（oneteam）完全分离，实现独立部署。

---

## 📁 目录结构

```
noda-infra/
├── services/           # 服务定义
│   ├── postgres/       # PostgreSQL 配置和初始化脚本
│   ├── keycloak/       # Keycloak 配置和主题
│   ├── nginx/          # Nginx 配置
│   ├── jenkins/        # Jenkins 配置
│   └── findclass/      # Findclass 应用配置（虚拟主机等）
├── scripts/            # 运维脚本
│   ├── deploy/         # 部署脚本
│   ├── backup/         # 备份脚本
│   ├── verify/         # 验证脚本
│   └── utils/          # 工具脚本
├── config/             # 配置文件
│   ├── nginx/          # Nginx 配置
│   ├── cloudflare/     # Cloudflare Tunnel 配置
│   └── environments/   # 环境配置
├── docker/             # Docker 配置
│   ├── docker-compose.yml
│   ├── docker-compose.prod.yml
│   └── docker-compose.dev.yml
├── docs/               # 文档
├── Jenkinsfile-infra   # 基础设施 CI/CD 流水线
└── README.md           # 仓库文档
```

---

## 🚀 快速开始

### 前置要求

- Docker 29.1.3+
- Docker Compose v2.40.3+
- SOPS 3.12.2 + age 1.3.1（密钥加密）

### 本地部署

```bash
# 克隆仓库
git clone <noda-infra-url> ~/project/noda-infra
cd ~/project/noda-infra

# 启动基础设施服务
docker-compose -f docker/docker-compose.yml up -d

# 验证服务状态
docker-compose ps
```

---

## 📚 部署指南

### 生产环境部署

详见 `docs/deployment-guide.md`（待创建）

### 开发环境部署

详见 `docs/development-guide.md`（待创建）

---

## 🔧 维护指南

### 备份和恢复

- PostgreSQL 备份：`scripts/backup/backup-postgres.sh`
- 配置备份：`scripts/backup/backup-config.sh`

### 验证和监控

- 基础设施验证：`scripts/verify/verify-infrastructure.sh`
- 服务健康检查：`scripts/verify/verify-services.sh`

---

## 🔐 安全指南

- 所有敏感信息使用 SOPS + age 加密
- 密钥文件不提交到 Git
- Jenkins 流水线安全注入密钥
- 容器以非 root 用户运行

---

## 📞 联系方式

- **维护者**: Claude Code
- **问题反馈**: GitHub Issues
- **文档**: [docs/](./docs/)

---

**相关仓库**:
- [oneteam](https://github.com/xxx/oneteam) - 应用代码仓库

---

*版本: 1.0.0*
*最后更新: 2026-04-05*
# Test
