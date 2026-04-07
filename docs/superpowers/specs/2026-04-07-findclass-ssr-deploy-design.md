# Findclass SSR 部署改造设计

## 概述

将 findclass 项目从前后端分离部署（web + api 两个容器）改造为 SSR 单容器部署。

## 背景

- **当前架构**：`findclass-web`（Nginx 静态前端）+ `findclass-api`（Express API）
- **目标架构**：单个 `findclass-ssr` 容器，集成 API + SSR 渲染 + 静态文件服务

## 设计决策

| 决策点 | 选择 | 理由 |
|--------|------|------|
| dev 网络隔离 | 内网 only | 最安全 |
| dev 部署方式 | 同服务器不同端口 | 资源复用，方便对比测试 |
| Dockerfile 位置 | noda-infra/deploy/ | 部署配置集中管理 |
| 容器架构 | 单容器 SSR | 架构简单，资源占用少 |

## 架构

```
┌─────────────────────────────────────┐
│         findclass-ssr 容器          │
│  ┌─────────────────────────────┐    │
│  │  Express Server (Port 3001) │    │
│  │  ├── /api/*  → API 路由      │    │
│  │  ├── /*      → SSR 渲染      │    │
│  │  └── /static → 静态文件      │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

## 组件变更

### 1. Dockerfile

**新建**：`noda-infra/deploy/Dockerfile.findclass-ssr`

多阶段构建：
1. Stage 1：安装依赖（基于 node:20-alpine）
2. Stage 2：构建 web（`npm run build` → dist/client + dist/server）
3. Stage 3：运行镜像，启动 api 服务

**启动命令**：`node dist/api/src/api.js`

### 2. Docker Compose

**修改** `docker/docker-compose.yml`：
- 删除 `findclass`（旧 web 容器）服务定义
- 修改 `api` 服务为 `findclass-ssr`，使用新 Dockerfile

**修改** `docker/docker-compose.dev.yml`：
- 添加 `findclass-ssr` 端口映射 `3001:3001`（内网访问）

**修改** `docker/docker-compose.prod.yml`：
- 配置 `findclass-ssr` 生产环境变量和资源限制
- 无端口映射（通过 nginx 代理）

### 3. Nginx

**修改** `config/nginx/conf.d/default.conf`：

```nginx
# 主应用域名 - 代理到 SSR 容器
server {
    listen 80;
    server_name localhost class.noda.co.nz;

    # 所有请求代理到 SSR 容器
    location / {
        proxy_pass http://findclass-ssr:3001;
        include /etc/nginx/snippets/proxy-common.conf;
    }

    # 健康检查
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
```

**删除**：
- 旧的 `/api/` 代理配置（SSR 容器内部处理）
- 旧的 `/auth/callback` 配置

## 部署流程

### 阶段 1：Dev 环境部署

1. 创建 Dockerfile.findclass-ssr
2. 修改 docker-compose 配置
3. 修改 nginx 配置
4. 构建 SSR 镜像
5. 启动 dev 容器（端口 3001）
6. 验证功能：
   - API 端点正常
   - SSR 渲染正常
   - 静态资源加载正常

### 阶段 2：Prod 环境部署

1. 确认 dev 验证通过
2. 部署 prod 容器
3. 通过 class.noda.co.nz 验证
4. 清理旧容器镜像

## 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `deploy/Dockerfile.findclass-ssr` | 新建 | SSR 容器构建文件 |
| `docker/docker-compose.yml` | 修改 | 替换 api 服务定义 |
| `docker/docker-compose.dev.yml` | 修改 | 添加 dev 端口映射 |
| `docker/docker-compose.prod.yml` | 修改 | 更新 prod 配置 |
| `config/nginx/conf.d/default.conf` | 修改 | 简化代理配置 |

## 回滚方案

如果部署失败，可通过以下步骤回滚：
1. 恢复旧的 docker-compose 配置
2. 重新构建旧镜像（web + api）
3. 重启容器
