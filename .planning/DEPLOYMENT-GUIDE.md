# Milestone v1.11 部署指南

**最后更新**: 2026-05-08
**Milestone**: v1.11 Pre-Prod 验证环境 + 安全上线流程

## 概述

本文档描述了完成 Milestone v1.11 后需要执行的手动步骤，以将 pre-prod 环境投入生产使用。

## 前置条件

- ✅ 数据库已创建（noda_preprod）
- ⚠️ Keycloak noda-preprod realm 待创建
- ✅ Nginx 配置已更新
- ✅ Jenkins Pipeline 已创建
- ⚠️ Jenkins Jobs 待初始化

## 步骤 1: 初始化 Pre-Prod 状态目录

需要管理员权限创建系统级状态目录：

```bash
# 创建 pre-prod 状态目录
sudo mkdir -p /opt/noda/preprod /opt/noda/upstream

# 复制 pre-prod upstream 配置
sudo cp config/nginx/snippets/upstream-findclass-preprod.conf /opt/noda/upstream/_preprod_upstream-findclass.conf

# 设置默认环境为 blue
echo "blue" | sudo tee /opt/noda/preprod/active-env

# 设置权限（可选，根据你的环境调整）
sudo chown -R $USER:$USER /opt/noda/preprod
sudo chown -R $USER:$USER /opt/noda/upstream
```

## 步骤 2: 配置 Keycloak Pre-Prod Realm

**需要**: Doppler CLI Token (`dp.ct.*`)

```bash
# 1. 导入 Doppler CLI Token
export DOPPLER_TOKEN="dp.ct.xxx"

# 2. 加载 Google OAuth 凭据
eval "$(doppler secrets download --no-file --format=env --project noda --config prd)"
export KEYCLOAK_ADMIN_USER KEYCLOAK_ADMIN_PASSWORD GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET

# 3. 执行 Keycloak 初始化脚本
bash scripts/keycloak-setup.sh

# 4. 验证创建结果
KEYCLOAK_CONTAINER=$(docker ps --format "{{.Names}}" | grep "keycloak" | head -1)
docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get realms/noda-preprod
docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get identity-provider/instances/google -r noda-preprod
docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get clients -r noda-preprod --fields clientId,redirectUris
```

**预期结果**:
- Realm `noda-preprod` 存在且 `enabled=true`
- Identity Provider `google` 存在且 `enabled=true`
- Client `noda-frontend-preprod` 存在，redirect URIs 包含 `pre.class.noda.co.nz` 和 `pre.auth.noda.co.nz`

## 步骤 3: 配置 Doppler Pre-Prod Config

**需要**: Doppler CLI Token (`dp.ct.*`)

```bash
# 1. 导入 Doppler CLI Token
export DOPPLER_TOKEN="dp.ct.xxx"

# 2. 执行 Doppler 初始化脚本
bash scripts/doppler-setup.sh

# 3. 保存输出的 Service Token（格式：dp.st.pre.xxx）
# 这个 token 需要配置到 Jenkins 凭据中
```

**预期结果**:
- Doppler `pre` config 已创建
- pre config 包含正确的数据库和 Keycloak realm 配置
- Service Token `dp.st.pre.xxx` 已生成

## 步骤 4: 验证环境隔离

```bash
# 使用 pre config Service Token 验证三层隔离
export DOPPLER_TOKEN="dp.st.pre.xxx"
bash scripts/verify-preprod-isolation.sh
```

**预期结果**: 所有检查通过，exit 0

## 步骤 5: 初始化 Jenkins Jobs

```bash
# 方法 1: 使用 Jenkins CLI（如果 Jenkins 已运行）
java -jar jenkins-cli.jar -s http://localhost:8888 -websocket groovy scripts/jenkins/init-jobs.groovy

# 方法 2: 使用 Jenkins Job DSL 插件
# 1. 在 Jenkins 中创建 "seed-job" 自由风格任务
# 2. 添加 "Process Job DSLs" 构建步骤
# 3. 指定 "Look on Filesystem" → scripts/jenkins/init-jobs.groovy
# 4. 运行 seed-job
```

## 步骤 6: 配置 Jenkins 凭据

在 Jenkins UI 中添加以下凭据：

### Pre-Prod 凭据

| 凭据 ID | 类型 | Secret |
|---------|------|--------|
| `doppler-service-token-preprod` | Secret text | Doppler Service Token (`dp.st.pre.xxx`) |
| `cf-api-token-preprod` | Secret text | Cloudflare API Token（可选） |
| `cf-zone-id-preprod` | Secret text | Cloudflare Zone ID（可选） |

### Prod 凭据（如果尚未配置）

| 凭据 ID | 类型 | Secret |
|---------|------|--------|
| `doppler-service-token` | Secret text | Doppler Service Token (`dp.st.prd.xxx`) |
| `cf-api-token` | Secret text | Cloudflare API Token |
| `cf-zone-id` | Secret text | Cloudflare Zone ID |

### 通用凭据

| 凭据 ID | 类型 | Secret |
|---------|------|--------|
| `noda-apps-git-credentials` | Username with password | Git 仓库访问凭据 |

## 步骤 7: 测试 Pre-Prod Pipeline

### 7.1 触发 Pre-Prod 部署

```bash
# 方法 1: Jenkins UI
# 1. 打开 Jenkins → noda-apps-preprod-deploy
# 2. 点击 "Build Now"

# 方法 2: Jenkins CLI（如果已配置）
java -jar jenkins-cli.jar -s http://localhost:8888 build noda-apps-preprod-deploy

# 方法 3: Jenkins API
curl -X POST "http://localhost:8888/job/noda-apps-preprod-deploy/build" \
  --user "admin:$(cat ~/.jenkins_admin_password)"
```

### 7.2 监控部署进度

```bash
# 查看构建日志
java -jar jenkins-cli.jar -s http://localhost:8888 console noda-apps-preprod-deploy <BUILD_NUMBER>

# 或者访问 Jenkins UI
# http://localhost:8888/job/noda-apps-preprod-deploy/<BUILD_NUMBER>/console
```

### 7.3 验证部署结果

```bash
# 检查容器状态
docker ps | grep noda-apps-preprod

# 检查健康状态
curl -f http://localhost:3001/api/health

# 检查外部访问
curl -f https://pre.class.noda.co.nz/api/health
```

**预期结果**:
- `noda-apps-preprod-green` 容器正在运行
- HTTP 200 响应
- `/opt/noda/preprod/active-env` 内容为 `green`

## 步骤 8: 测试 Promote Pipeline

### 8.1 确认 Pre-Prod 验证完成

手动测试 pre-prod 环境的功能：
- 用户登录（Google OAuth）
- 核心功能流程
- 数据库连接

### 8.2 触发 Promote 到 Prod

```bash
# 方法 1: Jenkins UI
# 1. 打开 Jenkins → noda-apps-promote
# 2. 点击 "Build Now"

# 方法 2: Jenkins API
curl -X POST "http://localhost:8888/job/noda-apps-promote/build" \
  --user "admin:$(cat ~/.jenkins_admin_password)"
```

### 8.3 监控 Promote 流程

Promote Pipeline 会：
1. 读取 pre-prod 镜像 digest
2. 部署到 prod 环境（蓝绿部署）
3. 健康检查
4. 流量切换
5. 验证
6. 清除 CDN 缓存

### 8.4 验证 Prod 环境

```bash
# 检查 prod 容器
docker ps | grep noda-apps-.*green

# 检查 prod 应用
curl -f https://class.noda.co.nz/api/health

# 检查活跃环境
cat /opt/noda/active-env  # 应该显示 "green"
```

## 步骤 9: 配置 Cron 定期安全检查（可选）

```bash
# 添加 cron 任务，每天凌晨 2 点运行安全检查
(crontab -l 2>/dev/null; echo "0 2 * * * /path/to/noda-infra/scripts/cron-safety-check.sh") | crontab -
```

## 故障排查

### 问题 1: sudo 权限不足

**症状**: 无法创建 /opt/noda/preprod 目录

**解决方案**:
```bash
# 使用 sudo 或请系统管理员创建目录
sudo mkdir -p /opt/noda/preprod /opt/noda/upstream
sudo chown -R $USER:$(id -gn) /opt/noda/preprod /opt/noda/upstream
```

### 问题 2: Keycloak 容器未运行

**症状**: keycloak-setup.sh 无法连接到 Keycloak

**解决方案**:
```bash
# 检查 Keycloak 容器状态
docker ps | grep keycloak

# 如果未运行，启动容器
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d keycloak-green
```

### 问题 3: DOPPLER_TOKEN 未设置

**症状**: 脚本提示 DOPPLER_TOKEN 未设置

**解决方案**:
```bash
# 1. 访问 Doppler Dashboard
# https://dashboard.doppler.com

# 2. 导航到项目 → Settings → CLI

# 3. 生成或复制 CLI Token（格式：dp.ct.xxx）

# 4. 设置环境变量
export DOPPLER_TOKEN="dp.ct.xxx"
```

### 问题 4: Jenkins Job 未创建

**症状**: noda-apps-preprod-deploy 任务不存在

**解决方案**:
```bash
# 1. 确认 Jenkins 正在运行
docker ps | grep jenkins

# 2. 重新运行初始化脚本
java -jar jenkins-cli.jar -s http://localhost:8888 -websocket groovy scripts/jenkins/init-jobs.groovy

# 3. 或在 Jenkins UI 中手动创建任务
```

### 问题 5: Pipeline 执行失败

**症状**: Pipeline 构建失败

**解决方案**:
```bash
# 查看构建日志
# Jenkins UI → noda-apps-preprod-deploy → Console Output

# 常见问题：
# - Doppler 凭据未配置 → 添加 doppler-service-token-preprod
# - 容器启动失败 → 检查 docker ps 和 docker logs
# - 健康检查失败 → 检查容器端口和网络连接
```

## 验证清单

完成所有步骤后，使用此清单验证部署：

- [ ] `/opt/noda/preprod` 目录存在
- [ ] `/opt/noda/upstream/_preprod_upstream-findclass.conf` 文件存在
- [ ] Keycloak noda-preprod realm 存在
- [ ] Doppler pre config 存在
- [ ] Jenkins Jobs 已创建（noda-apps-preprod-deploy, noda-apps-promote）
- [ ] Jenkins 凭据已配置
- [ ] Pre-prod Pipeline 可以成功执行
- [ ] Pre-prod 容器正常运行
- [ ] Pre-prod 域名可以访问（返回 HTTP 200）
- [ ] Promote Pipeline 可以成功执行
- [ ] Prod 流量切换成功

## 下一步

完成上述步骤后，Milestone v1.11 完全部署并投入使用。你可以：

1. 开始使用 pre-prod 环境进行测试
2. 将新功能先部署到 pre-prod 验证
3. 验证通过后 promote 到 prod
4. 继续开发下一个 Milestone

## 需要帮助？

如果遇到问题，请检查：
- `.planning/v1.11-MILESTONE-AUDIT.md` — 审计报告
- `.planning/ROADMAP.md` — 项目路线图
- 各阶段的 PLAN.md 和 SUMMARY.md 文件

---

**祝部署顺利！** 🚀
