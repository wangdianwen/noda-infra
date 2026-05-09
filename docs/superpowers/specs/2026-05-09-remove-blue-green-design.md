# 移除蓝绿部署设计

## 背景

当前项目实现了完整的蓝绿部署（blue-green deployment），包含容器管理、nginx upstream 动态切换、Pipeline 阶段编排等。但引入 pre-prod 环境后，蓝绿的零停机价值已被 pre-prod 验证 + 直接替换替代，且蓝绿带来了容器命名不一致、状态文件混乱等问题。

## 决策

移除所有服务的蓝绿部署，统一为 **Pre-prod 验证 + 直接替换** 策略。

## 部署流程变化

**旧（12 阶段）：**
Pre-flight → Build → Test → Deploy Pre-prod → Health Check Pre-prod → Human Approval → Deploy Prod → Health Check Prod → **Switch** → Verify → CDN Purge → Cleanup

**新（10 阶段）：**
Pre-flight → Build → Test → Deploy Pre-prod → Health Check Pre-prod → Human Approval → **Deploy Prod**（停旧启新 + 健康检查） → Verify → CDN Purge → Cleanup

## 容器命名简化

| 服务 | 旧（蓝绿） | 新（单容器） |
|------|-----------|-------------|
| noda-apps | `noda-apps-prod-blue` / `noda-apps-prod-green` | `noda-apps-prod` |
| keycloak | `keycloak-blue` / `keycloak-green` | `keycloak` |

## 回滚机制

每次部署前，将当前镜像 tag 为 `noda-apps:rollback`（或对应服务名）。失败时启动 rollback 镜像即可恢复。

## 删除的文件（6 个）

| 文件 | 原因 |
|------|------|
| `scripts/blue-green-deploy.sh` | 整个文件都是蓝绿逻辑 |
| `scripts/keycloak-blue-green-deploy.sh` | Keycloak 蓝绿 wrapper |
| `scripts/rollback-deploy.sh` | 蓝绿专用回滚 |
| `scripts/manage-containers.sh` | 蓝绿容器管理函数库 |
| `scripts/update-upstream.sh` | upstream 动态切换工具 |
| `/opt/noda/active-env*` | 4 个蓝绿状态文件（active-env, active-env-keycloak, active-env-auth, active-env-noda-site） |

## 修改的文件

### 1. scripts/pipeline-stages.sh

**移除的函数：**
- `pipeline_deploy()` — 蓝绿部署到目标环境
- `pipeline_health_check()` — 蓝绿健康检查
- `pipeline_switch()` — nginx 流量切换
- `pipeline_verify()` — 蓝绿 E2E 验证
- `pipeline_cleanup()` — 清理非活跃蓝绿容器
- `pipeline_failure_cleanup()` — 蓝绿失败清理
- `pipeline_deploy_keycloak()` — Keycloak 蓝绿部署
- `pipeline_deploy_nginx()` 中保存回滚镜像 digest 逻辑简化
- `pipeline_deploy_noda_ops()` 中保存回滚镜像 digest 逻辑简化
- `pipeline_infra_rollback()` — 蓝绿回滚
- 所有 `update_upstream()` / `set_active_env()` / `get_active_env()` 调用

**新增的函数：**
- `pipeline_deploy_prod()` — 停旧容器 → tag rollback 镜像 → 启新容器 → 健康检查
- `pipeline_deploy_keycloak_prod()` — Keycloak 直接替换（docker stop/rm/run）

**保留的函数：**
- `pipeline_preflight()` — 前置检查（移除蓝绿相关检查）
- `pipeline_build()` — 镜像构建
- `pipeline_test()` — 依赖安装
- `pipeline_purge_cdn()` — CDN 缓存清除
- `pipeline_cleanup_preprod()` — pre-prod 容器清理
- `pipeline_deploy_preprod()` — pre-prod 部署（已是单容器模式，不变）
- `pipeline_health_check_preprod()` — pre-prod 健康检查（不变）
- `check_backup_freshness()` — 备份检查（不变）
- 基础设施 Pipeline 函数（`pipeline_infra_*`）简化但保留

**移除的常量：**
- `ACTIVE_ENV_FILE` — 蓝绿状态文件
- `UPSTREAM_CONF` — upstream 动态切换配置路径

### 2. jenkins/Jenkinsfile.apps

**移除：**
- `ACTIVE_ENV` / `TARGET_ENV` 环境变量
- `stage('Health Check Prod')` — 合并到 Deploy Prod
- `stage('Switch')` — 不再需要流量切换
- `pipeline_failure_cleanup` 中的蓝绿清理

**修改：**
- `stage('Deploy Prod')` — 调用 `pipeline_deploy_prod`（停旧启新+健康检查）

**保留不变：**
- Pre-flight, Build, Test, Deploy Pre-prod, Health Check Pre-prod, Human Approval, CDN Purge, Cleanup

### 3. config/nginx/snippets/upstream-findclass.conf

旧（动态切换）：
```nginx
set $findclass_upstream noda-apps-green:3000;
set $www_upstream noda-apps-green:3002;
...
```

新（固定）：
```nginx
set $findclass_upstream noda-apps-prod:3000;
set $www_upstream noda-apps-prod:3002;
set $auth_app_upstream noda-apps-prod:3004;
set $admin_upstream noda-apps-prod:3006;
set $admin_api_upstream noda-apps-prod:3011;
```

### 4. config/nginx/snippets/upstream-keycloak.conf

旧：`set $keycloak_upstream keycloak-green:8080;`
新：`set $keycloak_upstream keycloak:8080;`

### 5. jenkins/Jenkinsfile.infra

简化 Keycloak 部署：从 `pipeline_deploy_keycloak()`（蓝绿）改为直接 `docker stop/rm/run`。

## 不变的文件

- `docker/docker-compose.apps-prod.yml` — 本来就是单服务定义
- `docker/docker-compose.yml` — 基础设施 compose
- `docker/docker-compose.prod.yml` — 生产 overlay
- `scripts/lib/log.sh` — 日志库
- `scripts/lib/health.sh` — 健康检查工具（保留通用函数）
- `scripts/lib/secrets.sh` — 密钥加载
- `scripts/lib/cleanup.sh` — 清理工具
- `scripts/lib/image-cleanup.sh` — 镜像清理
- `scripts/lib/deploy-check.sh` — 部署检查
