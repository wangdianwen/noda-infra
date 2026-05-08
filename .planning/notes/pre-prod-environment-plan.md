---
name: Pre-Prod 环境部署方案
description: 在现有 prod 环境基础上增加 pre-prod 验证环境的完整改动计划
date: 2026-05-08
context: gsd-explore 调查产出
---

# Pre-Prod 环境部署方案

## 架构决策

| 决策项 | 选择 | 理由 |
|--------|------|------|
| 验证范围 | 全链路验证 | 前端 + API + DB 迁移 + Keycloak 认证 |
| 数据库策略 | 同实例不同库 | 资源友好，一个 PostgreSQL 实例管理 `noda_prod` + `noda_preprod` |
| 访问方式 | 独立子域名 | 团队可实际操作验证完整登录流程 |
| Git 策略 | Trunk + Tag 推进 | main 分支 → pre-prod，手动 Promote → prod |
| Keycloak | 同实例新 Realm | 共享 Keycloak 服务，新增 `noda-preprod` realm |
| 基础设施 | noda-infra 共享 | PostgreSQL/Nginx/Keycloak/Cloudflare 跑一份，同时服务 prod 和 pre-prod |
| 应用层 | noda-apps 双实例 | prod 和 pre-prod 各自蓝绿部署 |

## 架构图

```
┌─────────────────────────────────────────────────────┐
│  noda-infra (共享，单实例)                              │
│  ├── PostgreSQL: noda_prod + noda_preprod + keycloak_db │
│  ├── Keycloak: noda realm + noda-preprod realm       │
│  ├── Nginx: 路由 prod + pre-prod 域名                 │
│  └── Cloudflare Tunnel + noda-ops                    │
├─────────────────────────────────────────────────────┤
│  noda-apps (双实例，各自蓝绿)                           │
│  ├── prod:    noda-apps-blue/green → class.noda.co.nz │
│  ├── pre-prod: noda-apps-preprod-blue/green → pre.class.noda.co.nz │
│  └── 每套实例包含: findclass(3000) + www(3002) + auth(3004) + admin(3006) + admin-api(3011) │
└─────────────────────────────────────────────────────┘
```

## 域名规划

| 环境 | 域名 | 用途 |
|------|------|------|
| Prod | class.noda.co.nz | FindClass 应用 |
| Prod | auth.noda.co.nz | Keycloak + Auth App |
| Prod | noda.co.nz / www.noda.co.nz | 官网 |
| Prod | admin.noda.co.nz | Admin Dashboard |
| Pre-prod | pre.class.noda.co.nz | FindClass 预发布 |
| Pre-prod | pre.auth.noda.co.nz | Auth App 预发布（指向 noda-preprod realm） |
| Pre-prod | pre.noda.co.nz | 官网预发布 |
| Pre-prod | pre.admin.noda.co.nz | Admin 预发布（仅内网） |

## 改动清单

### 1. PostgreSQL（noda-infra）
- 创建 `noda_preprod` 数据库
- 创建对应的数据库用户（或复用现有用户）
- 修改 `scripts/init-databases.sh` 添加 preprod 数据库初始化

### 2. Keycloak（noda-infra）
- 在现有 Keycloak 实例中创建 `noda-preprod` realm
- 配置 Google OAuth redirect URI 包含 `pre.class.noda.co.nz` 和 `pre.auth.noda.co.nz`
- 创建 `noda-frontend-preprod` client，redirect URI 指向 pre-prod 域名
- 可选：导入 prod realm 配置作为基础

### 3. Nginx（noda-infra）
- 新增 `config/nginx/snippets/upstream-findclass-preprod.conf` — pre-prod upstream 变量
- 在 `config/nginx/conf.d/default.conf` 或新文件中添加 pre-prod server blocks：
  - `pre.class.noda.co.nz` → `$findclass_preprod_upstream`
  - `pre.auth.noda.co.nz` → auth app preprod + keycloak
  - `pre.noda.co.nz` → www preprod upstream
  - `pre.admin.noda.co.nz` → admin preprod upstream
- 所有 pre-prod server block 添加 `resolver 127.0.0.11 valid=30s;`

### 4. Cloudflare Tunnel（noda-infra/noda-ops）
- 在 Cloudflare Tunnel 配置中添加 pre-prod 域名路由：
  - `pre.class.noda.co.nz` → nginx:80
  - `pre.auth.noda.co.nz` → nginx:80
  - `pre.noda.co.nz` → nginx:80
- 在 Cloudflare DNS 中添加对应的 CNAME 记录

### 5. 环境变量（noda-infra）
- 新增 `docker/env-noda-apps-preprod.env`：
  - `DATABASE_URL=postgresql://...@noda-infra-postgres-prod:5432/noda_preprod`
  - `KEYCLOAK_URL=https://pre.auth.noda.co.nz`
  - `KEYCLOAK_REALM=noda-preprod`
  - `KEYCLOAK_CLIENT_ID=noda-frontend-preprod`

### 6. 蓝绿部署脚本（noda-infra）
- `manage-containers.sh` 需支持 pre-prod 的环境变量：
  - 新的 `ACTIVE_ENV_FILE=/opt/noda/active-env-preprod`
  - 新的 `UPSTREAM_CONF=.../upstream-findclass-preprod.conf`
  - 新的 env 模板：`env-noda-apps-preprod.env`
- 容器命名：`noda-apps-preprod-blue` / `noda-apps-preprod-green`
- Docker labels 区分 prod 和 preprod

### 7. Jenkins Pipeline（noda-infra）

#### 新增 Pipeline：`Jenkinsfile.noda-apps-preprod`
- 复用 `Jenkinsfile.noda-apps` 的框架
- 参数化 `SERVICE_NAME`、`ACTIVE_ENV_FILE`、`UPSTREAM_CONF`、`ENV_TEMPLATE`
- 可能合并为一个参数化 Pipeline，通过 `DEPLOY_TARGET` 参数区分

#### 修改 Pipeline：`Jenkinsfile.noda-apps` → 增加 Promote to Prod 阶段
- 新增 "Promote" 参数化构建：
  - 读取当前 pre-prod 镜像 digest
  - 用相同镜像部署到 prod（蓝绿切换）
  - 无需重新构建

#### 流程设计
```
方式 A: 双 Pipeline
  Jenkinsfile.noda-apps-preprod: Build → Test → Deploy Pre-prod → Health → Switch Pre-prod → Verify
  Jenkinsfile.noda-apps-promote: Read Pre-prod Image → Deploy Prod → Health → Switch Prod → Verify → CDN Purge

方式 B: 单 Pipeline 参数化
  DEPLOY_TARGET=preprod: Build → Test → Deploy Pre-prod → Health → Switch → Verify
  DEPLOY_TARGET=promote: Read Pre-prod Image → Deploy Prod → Health → Switch → Verify → CDN Purge
```

### 8. Keycloak 移入 noda-infra（已就位）
- Keycloak 已经在 noda-infra 中管理（Jenkinsfile.keycloak）
- 不需要额外移动，只需确认其作为共享基础设施的角色

## Hotfix 流程

```
1. 从最新 prod tag 创建 hotfix 分支
   git checkout -b hotfix/描述 v1.x.x

2. 修复代码，提交

3. 合并到 main
   git checkout main && git merge hotfix/描述

4. 触发 pre-prod 部署（同镜像）
   Jenkins → noda-apps-preprod → Build Now

5. 快速验证 pre-prod（可缩短等待时间）

6. Promote to Prod
   Jenkins → noda-apps → Promote（使用同一镜像）

7. 打 tag
   git tag -a v1.x.x+1 -m "hotfix: 描述"
```

### 紧急 Hotfix（跳过 Pre-prod）
- 仅限 P0 级别的服务中断（如无法登录、数据丢失风险）
- Jenkins → noda-apps → Build Now（直接部署到 prod）
- 事后补走 pre-prod 验证

## 资源评估

| 组件 | Prod | Pre-prod | 增量 |
|------|------|----------|------|
| noda-apps 容器 | ~512MB x 2 (蓝绿) | ~512MB x 2 (蓝绿) | +1GB |
| PostgreSQL 数据库 | noda_prod | noda_preprod | +磁盘空间 |
| Keycloak | 已有 | 新 realm | 无额外内存 |
| Nginx | 已有 | 新 server blocks | 可忽略 |
| 总增量 | | | ~1GB 内存 + 磁盘 |

## 实施顺序建议

1. **Phase 1: 数据库 + Keycloak Realm**（基础设施准备）
   - 创建 noda_preprod 数据库
   - 创建 noda-preprod Keycloak realm
   - 配置 Google OAuth redirect URIs

2. **Phase 2: Nginx + DNS**（路由打通）
   - 添加 pre-prod upstream 配置
   - 添加 pre-prod server blocks
   - Cloudflare Tunnel 添加域名
   - 验证域名可达性

3. **Phase 3: 部署脚本 + Jenkins**（自动化）
   - 参数化 manage-containers.sh 支持 preprod
   - 创建 pre-prod Jenkinsfile
   - 创建 Promote to Prod 流程
   - 首次部署验证

4. **Phase 4: 文档 + 规范**（规范化）
   - 更新 noda-apps CLAUDE.md
   - 更新 noda-infra CLAUDE.md
   - Git tagging 规范
