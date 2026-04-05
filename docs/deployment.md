# OneTeam 基础设施自动部署

## 部署方案：Shell 脚本 + Git Hook

最简单、最可靠的部署方案。

---

## 📝 使用方法

### 方式 1：手动部署（推荐）

```bash
# 部署核心服务（PostgreSQL + Keycloak）
~/project/noda-infra/deploy-simple.sh
```

### 方式 2：自动部署（Git Hook）

每次 `git pull` 后自动触发部署：

```bash
cd ~/project/noda-infra
git pull  # 自动执行 deploy.sh
```

---

## 🎯 当前已部署服务

- ✅ PostgreSQL 17.9（端口 5432）
- ✅ Keycloak 26.2.3（端口 8080, 9000）

---

## 🔧 常用命令

### 查看服务状态
```bash
cd ~/project/noda-infra/docker
docker compose -p noda-prod -f docker-compose.yml ps
```

### 查看日志
```bash
# 所有服务
docker compose -p noda-prod -f docker-compose.yml logs -f

# 特定服务
docker compose -p noda-prod -f docker-compose.yml logs -f postgres
docker compose -p noda-prod -f docker-compose.yml logs -f keycloak
```

### 重启服务
```bash
cd ~/project/noda-infra/docker
docker compose -p noda-prod -f docker-compose.yml restart
```

### 停止服务
```bash
cd ~/project/noda-infra/docker
docker compose -p noda-prod -f docker-compose.yml down
```

### 删除所有数据（危险）
```bash
cd ~/project/noda-infra/docker
docker compose -p noda-prod -f docker-compose.yml down -v
```

---

## 🌐 访问服务

### Keycloak 管理后台
- URL: http://localhost:8080
- 管理员账号: `admin`
- 管理员密码: `admin_password_change_me`

**⚠️ 生产环境请立即修改密码！**

### PostgreSQL 连接
- 主机: `localhost`
- 端口: `5432`
- 用户: `postgres`
- 密码: `postgres_password_change_me`
- 数据库: `oneteam_prod`

---

## 📂 文件说明

- `deploy-simple.sh` - 简化版部署脚本（推荐）
- `deploy.sh` - 完整部署脚本（需要先构建镜像）
- `.git/hooks/post-merge` - Git Hook 自动触发部署

---

## 🚀 部署流程

1. 拉取最新代码
2. 设置环境变量
3. 启动/重启服务
4. 显示服务状态

---

## 🔄 下一步

### 添加 API 服务
1. 确保 `~/project/oneteam` 存在
2. 修改 `docker-compose.yml` 添加 API 服务配置
3. 运行 `~/project/noda-infra/deploy-simple.sh`

### 添加前端服务
1. 构建 Docker 镜像
2. 修改 `docker-compose.yml` 添加前端服务配置
3. 运行 `~/project/noda-infra/deploy-simple.sh`

---

## 💡 提示

- 脚本会自动创建 Docker 网络（noda-network）
- 数据会持久化在 Docker volume（noda-prod_postgres_data）
- 修改 `.env` 文件可以更改环境变量
- Git Hook 可以删除（`rm .git/hooks/post-merge`）来禁用自动部署
