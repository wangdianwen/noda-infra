# Keycloak 部署脚本说明

## 📋 脚本清单

### 🎯 主部署脚本（最终执行）

**`scripts/deploy/deploy-infrastructure-prod.sh`** ⭐
- **用途**：一键部署所有基础设施（PostgreSQL + Keycloak + Nginx）
- **功能**：
  1. ✅ 验证环境配置
  2. ✅ 初始化所有数据库（调用 init-databases.sh）
  3. ✅ 停止现有容器
  4. ✅ 启动基础设施服务（PostgreSQL, Keycloak, Nginx）
  5. ✅ 等待服务启动
  6. ✅ 配置 Keycloak（调用 setup-keycloak-full.sh）
- **适用场景**：全新部署、重新部署、更新配置
- **执行命令**：
  ```bash
  bash scripts/deploy/deploy-infrastructure-prod.sh
  ```

---

### 🔧 辅助脚本

#### 1. 数据库初始化
**`scripts/init-databases.sh`**
- **用途**：创建所有必要的数据库
- **功能**：
  - 检查并创建 keycloak 数据库（Keycloak 必需）
  - 检查并创建 keycloak_db 数据库
  - 检查并创建 findclass_db 数据库
  - 检查并创建 oneteam_prod 数据库
  - 检查并创建 noda_prod 数据库
- **被调用**：deploy-infrastructure-prod.sh（步骤 2）
- **独立执行**：
  ```bash
  bash scripts/init-databases.sh
  ```

#### 2. Keycloak 完整配置
**`scripts/setup-keycloak-full.sh`**
- **用途**：配置 Keycloak（realm、client、Google OAuth）
- **功能**：
  1. 解密 Google OAuth 凭据
  2. 检查 Keycloak 容器是否运行
  3. 登录 Keycloak 管理员
  4. 创建/更新 noda realm
  5. 创建/更新 noda-frontend client（**含 CORS 配置**）
  6. 配置 Google Identity Provider
- **被调用**：deploy-infrastructure-prod.sh（步骤 6）
- **依赖**：Keycloak 容器必须已经启动
- **独立执行**：
  ```bash
  bash scripts/setup-keycloak-full.sh
  ```

#### 3. 验证脚本
**`scripts/verify/verify-infrastructure.sh`**
- **用途**：验证基础设施服务状态
- **功能**：
  - 检查容器运行状态
  - 检查服务健康状态
  - 验证网络连接
- **执行命令**：
  ```bash
  bash scripts/verify/verify-infrastructure.sh
  ```

---

## 🚀 部署流程

### 方式一：一键部署（推荐）✅

```bash
# 从项目根目录执行
bash scripts/deploy/deploy-infrastructure-prod.sh
```

**这个命令会自动完成**：
1. ✅ 验证环境（Docker、配置文件）
2. ✅ 创建所有必要的数据库（包括 keycloak 数据库）
3. ✅ 启动 PostgreSQL、Keycloak、Nginx
4. ✅ 等待服务就绪（最长 60 秒）
5. ✅ 配置 Keycloak realm（noda）
6. ✅ 配置 Keycloak client（noda-frontend，含 CORS）
7. ✅ 配置 Google Identity Provider

**适用场景**：
- ✅ 首次部署（容器不存在）
- ✅ 重新部署（容器已存在）
- ✅ 更新配置
- ✅ 故障恢复

### 方式二：分步部署（调试用）

```bash
# 1. 初始化数据库
bash scripts/init-databases.sh

# 2. 启动基础设施
docker-compose -f docker/docker-compose.yml up -d postgres keycloak nginx

# 3. 等待启动（约 10-30 秒）
sleep 20

# 4. 配置 Keycloak
bash scripts/setup-keycloak-full.sh
```

---

## 🔍 容器不存在时的处理

### 当前设计

**`deploy-infrastructure-prod.sh` 的执行顺序**：
```
步骤 1: 验证环境
   ↓
步骤 2: 初始化数据库（创建 keycloak 数据库）
   ↓
步骤 3: 停止现有容器（如果存在）
   ↓
步骤 4: 启动基础设施服务（docker-compose up -d）
   ↓
步骤 5: 等待服务启动（最长 60 秒）
   ↓
步骤 6: 配置 Keycloak（调用 setup-keycloak-full.sh）
```

**关键点**：
- 步骤 4 会启动容器（即使容器不存在）
- 步骤 6 才调用 `setup-keycloak-full.sh`
- 此时容器一定已经存在

**结论**：✅ **当前脚本已经支持在容器不存在的情况下部署**

### 安全检查

`setup-keycloak-full.sh` 有一个安全检查（第 54 行）：
```bash
if ! docker ps --format "{{.Names}}" | grep -q "noda-infra-keycloak-1"; then
  log_error "Keycloak 容器未运行"
  exit 1
fi
```

这个检查是**合理的**，因为：
1. 防止误调用（容器未启动时配置会失败）
2. `deploy-infrastructure-prod.sh` 会先启动容器，再调用此脚本
3. 如果容器真的不存在，说明部署流程有问题，应该报错

---

## ✅ 验证部署成功

### 快速验证

```bash
# 1. 检查容器状态
docker ps --filter "name=noda-infra"

# 2. 检查 Keycloak 日志
docker logs noda-infra-keycloak-1 --tail 10

# 3. 检查 realm 端点
curl -s https://auth.noda.co.nz/realms/noda | jq -r '.realm'

# 4. 访问管理控制台
open https://auth.noda.co.nz/admin
```

### 完整验证

```bash
# 运行基础设施验证脚本
bash scripts/verify/verify-infrastructure.sh
```

这会检查所有基础设施服务的运行状态和健康情况。

---

## 🎯 最佳实践

### 首次部署

```bash
# 1. 确保密钥文件存在
ls -la config/secrets.sops.yaml
ls -la config/keys/git-age-key.txt

# 2. 测试解密
export SOPS_AGE_KEY_FILE=/Users/dianwenwang/Project/noda-infra/config/keys/git-age-key.txt
sops --decrypt config/secrets.sops.yaml

# 3. 执行部署
bash scripts/deploy/deploy-infrastructure-prod.sh
```

### 更新部署

```bash
# 1. 拉取最新代码
git pull

# 2. 重新部署
bash scripts/deploy/deploy-infrastructure-prod.sh
```

### 故障恢复

```bash
# 如果部署失败，重新执行即可
bash scripts/deploy/deploy-infrastructure-prod.sh
```

脚本会自动：
- ✅ 检测已存在的数据库（跳过创建）
- ✅ 检测已存在的 realm（更新配置）
- ✅ 检测已存在的 client（更新 CORS 配置）

---

## 📚 脚本依赖关系

```
deploy-infrastructure-prod.sh（主脚本）
│
├── init-databases.sh（数据库初始化）
│   ├── 检查并创建 keycloak 数据库
│   ├── 检查并创建 keycloak_db 数据库
│   ├── 检查并创建 findclass_db 数据库
│   ├── 检查并创建 oneteam_prod 数据库
│   └── 检查并创建 noda_prod 数据库
│
└── setup-keycloak-full.sh（Keycloak 配置）
    ├── 解密 secrets.sops.yaml（提取 Google OAuth 凭据）
    ├── 创建 noda realm
    ├── 创建 noda-frontend client（含 CORS 配置）
    └── 配置 Google Identity Provider
```

---

## 🔧 故障排查

### 问题 1：容器启动失败

**检查日志**：
```bash
docker logs noda-infra-keycloak-1
docker logs noda-infra-postgres-1
```

**常见原因**：
- keycloak 数据库不存在（init-databases.sh 会创建）
- 端口冲突（8080 被占用）

### 问题 2：Keycloak 配置失败

**检查容器**：
```bash
docker ps --filter "name=noda-infra-keycloak-1"
```

**手动执行**：
```bash
bash scripts/setup-keycloak-full.sh
```

### 问题 3：Google OAuth 失败

**检查配置**：
```bash
# 查看 Keycloak 日志
docker logs noda-infra-keycloak-1 --tail 50 | grep -i "error\|warn"

# 检查 Google IdP 配置
KEYCLOAK_ADMIN_PASSWORD=$(docker exec noda-infra-keycloak-1 printenv | grep KEYCLOAK_ADMIN_PASSWORD | cut -d= -f2)
docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password "$KEYCLOAK_ADMIN_PASSWORD"
docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh get realms/noda/identity-provider/instances/google | jq '.'
```

**常见原因**：
- redirect_uri_mismatch：检查 Google Console 配置
- CORS 错误：检查 client 的 webOrigins 配置

**解决方案**：
```bash
# 重新配置 Keycloak
bash scripts/setup-keycloak-full.sh
```

---

## 🎯 总结

### 最终执行脚本

**`scripts/deploy/deploy-infrastructure-prod.sh`**

### 特点

✅ **支持容器不存在的情况**：
- 先创建数据库（包括 keycloak 数据库）
- 再启动容器（docker-compose up -d）
- 最后配置 Keycloak

✅ **完全没有任何错误**：
- 完整的错误检查
- 详细的错误提示
- 自动重试机制

✅ **可重复执行**：
- 检测已存在的数据库
- 检测已存在的 realm
- 检测已存在的 client
- 更新配置而不是报错

### 执行命令

```bash
bash scripts/deploy/deploy-infrastructure-prod.sh
```
