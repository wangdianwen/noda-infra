# Findclass SSR 部署改造实现计划

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 findclass 从前后端分离部署改造为 SSR 单容器部署

**Architecture:** 单个 Express 容器同时提供 API、SSR 渲染和静态文件服务

**Tech Stack:** Node.js 20 Alpine, Express, Docker multi-stage build

---

## 文件结构

| 文件 | 操作 | 职责 |
|------|------|------|
| `deploy/Dockerfile.findclass-ssr` | 新建 | SSR 容器多阶段构建 |
| `docker/docker-compose.yml` | 修改 | 替换 findclass + api 为 findclass-ssr |
| `docker/docker-compose.dev.yml` | 修改 | 添加 dev 端口映射 3001:3001 |
| `docker/docker-compose.prod.yml` | 修改 | 更新 prod 环境配置 |
| `config/nginx/conf.d/default.conf` | 修改 | 简化代理到 SSR 容器 |

---

## Chunk 1: Dockerfile 创建

### Task 1: 创建 SSR Dockerfile

**Files:**
- Create: `deploy/Dockerfile.findclass-ssr`

- [ ] **Step 1: 创建 Dockerfile.findclass-ssr**

```dockerfile
# ============================================
# Findclass SSR 容器 - 多阶段构建
# ============================================
# 镜像名: findclass-ssr:latest
# 功能: 单容器提供 API + SSR 渲染 + 静态文件服务
# ============================================

# ----------------------------------------
# Stage 1: 依赖安装
# ----------------------------------------
FROM node:20-alpine AS deps

WORKDIR /app

# 复制 package 文件
COPY package.json package-lock.json ./
COPY packages/shared/package.json ./packages/shared/
COPY packages/database/package.json ./packages/database/
COPY apps/findclass/web/package.json ./apps/findclass/web/
COPY apps/findclass/api/package.json ./apps/findclass/api/

# 安装依赖
RUN npm ci --include=dev

# ----------------------------------------
# Stage 2: 构建
# ----------------------------------------
FROM node:20-alpine AS builder

WORKDIR /app

# 复制依赖
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/packages/shared/node_modules ./packages/shared/node_modules
COPY --from=deps /app/packages/database/node_modules ./packages/database/node_modules
COPY --from=deps /app/apps/findclass/web/node_modules ./apps/findclass/web/node_modules
COPY --from=deps /app/apps/findclass/api/node_modules ./apps/findclass/api/node_modules

# 复制源代码
COPY package.json package-lock.json ./
COPY packages ./packages
COPY apps/findclass ./apps/findclass

# 生成 Prisma Client
WORKDIR /app/packages/database
RUN npx prisma generate

# 构建 web (client + server)
WORKDIR /app/apps/findclass/web
RUN npm run build

# 构建 api (tsc)
WORKDIR /app/apps/findclass/api
RUN npm run build

# ----------------------------------------
# Stage 3: 运行镜像
# ----------------------------------------
FROM node:20-alpine AS runner

WORKDIR /app

# 设置生产环境
ENV NODE_ENV=production
ENV PORT=3001

# 创建非 root 用户
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nodejs

# 复制必要文件
COPY --from=builder /app/package.json ./
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/packages/shared/dist ./packages/shared/dist
COPY --from=builder /app/packages/shared/package.json ./packages/shared/
COPY --from=builder /app/packages/database/dist ./packages/database/dist
COPY --from=builder /app/packages/database/package.json ./packages/database/
COPY --from=builder /app/apps/findclass/web/dist ./apps/findclass/web/dist
COPY --from=builder /app/apps/findclass/api/dist ./apps/findclass/api/dist
COPY --from=builder /app/apps/findclass/api/package.json ./apps/findclass/api/

# 复制 Prisma 生成的文件
COPY --from=builder /app/packages/database/node_modules/.prisma ./packages/database/node_modules/.prisma
COPY --from=builder /app/packages/database/node_modules/@prisma ./packages/database/node_modules/@prisma
COPY --from=builder /app/packages/database/prisma ./packages/database/prisma

# 设置权限
RUN chown -R nodejs:nodejs /app

USER nodejs

EXPOSE 3001

# 启动 API 服务器（已集成 SSR 中间件）
CMD ["node", "apps/findclass/api/dist/api/src/api.js"]
```

- [ ] **Step 2: 验证 Dockerfile 语法**

Run: `docker build --no-cache -f deploy/Dockerfile.findclass-ssr -t findclass-ssr:test ../../noda-apps 2>&1 | head -50`

Expected: 开始构建过程，无语法错误

- [ ] **Step 3: 提交 Dockerfile**

```bash
git add deploy/Dockerfile.findclass-ssr
git commit -m "feat: add Dockerfile for SSR container"
```

---

## Chunk 2: Docker Compose 配置修改

### Task 2: 修改 docker-compose.yml

**Files:**
- Modify: `docker/docker-compose.yml:64-113`

- [ ] **Step 1: 删除旧的 findclass 和 api 服务定义**

将 `docker/docker-compose.yml` 中第 64-113 行的 `findclass` 和 `api` 服务替换为新的 `findclass-ssr` 服务：

```yaml
  # ----------------------------------------
  # Findclass SSR 服务（API + SSR 渲染 + 静态文件）
  # ----------------------------------------
  findclass-ssr:
    build:
      context: ../../noda-apps
      dockerfile: ../noda-infra/deploy/Dockerfile.findclass-ssr
    image: findclass-ssr:latest
    container_name: findclass-ssr
    restart: unless-stopped
    environment:
      NODE_ENV: production
      DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/findclass_db
      DIRECT_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/findclass_db
      KEYCLOAK_URL: http://keycloak:8080
      KEYCLOAK_REALM: noda
      KEYCLOAK_CLIENT_ID: noda-frontend
    networks:
      noda-network:
        aliases:
          - findclass-ssr
    depends_on:
      postgres:
        condition: service_healthy
      keycloak:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "wget --quiet --tries=1 --spider http://localhost:3001/api/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
```

- [ ] **Step 2: 提交 docker-compose.yml 修改**

```bash
git add docker/docker-compose.yml
git commit -m "refactor: replace web+api with single SSR service"
```

### Task 3: 修改 docker-compose.dev.yml

**Files:**
- Modify: `docker/docker-compose.dev.yml`

- [ ] **Step 1: 添加 findclass-ssr dev 配置**

在文件末尾 networks 定义之前添加：

```yaml
  # ----------------------------------------
  # Findclass SSR（开发环境配置）
  # ----------------------------------------
  findclass-ssr:
    ports:
      - "3001:3001"  # 内网访问端口
    environment:
      NODE_ENV: production
      DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/findclass_db
      DIRECT_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/findclass_db
```

- [ ] **Step 2: 提交 docker-compose.dev.yml 修改**

```bash
git add docker/docker-compose.dev.yml
git commit -m "feat: add dev port mapping for SSR container"
```

### Task 4: 修改 docker-compose.prod.yml

**Files:**
- Modify: `docker/docker-compose.prod.yml:122-153`

- [ ] **Step 1: 替换 findclass 和 api 为 findclass-ssr**

将第 122-153 行替换为：

```yaml
  # ----------------------------------------
  # Findclass SSR（生产环境）
  # ----------------------------------------
  findclass-ssr:
    environment:
      DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/findclass_db
      DIRECT_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/findclass_db
      KEYCLOAK_URL: http://keycloak:8080
      KEYCLOAK_REALM: noda
      KEYCLOAK_CLIENT_ID: noda-frontend
      RESEND_API_KEY: ${RESEND_API_KEY}
    deploy:
      resources:
        limits:
          cpus: '1'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 128M
```

- [ ] **Step 2: 提交 docker-compose.prod.yml 修改**

```bash
git add docker/docker-compose.prod.yml
git commit -m "refactor: update prod config for SSR container"
```

---

## Chunk 3: Nginx 配置修改

### Task 5: 简化 nginx 代理配置

**Files:**
- Modify: `config/nginx/conf.d/default.conf`

- [ ] **Step 1: 更新主应用 server 块**

将第 34-103 行的 server 块替换为：

```nginx
# ============================================
# 主应用域名
# ============================================
server {
    listen 80;
    server_name localhost class.noda.co.nz;

    # 客户端最大请求体大小
    client_max_body_size 100M;

    # 安全头
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Gzip 压缩
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript
               application/x-javascript application/xml+rss
               application/json application/javascript
               image/svg+xml;

    # 所有请求代理到 SSR 容器
    location / {
        proxy_pass http://findclass-ssr:3001;
        include /etc/nginx/snippets/proxy-common.conf;
    }

    # Keycloak 认证服务（开发环境）
    location /auth/ {
        proxy_pass http://keycloak:8080/auth/;

        # Keycloak 需要的代理头部
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header X-Forwarded-Host $host;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass $http_upgrade;
    }

    # 健康检查
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
```

- [ ] **Step 2: 提交 nginx 配置修改**

```bash
git add config/nginx/conf.d/default.conf
git commit -m "refactor: simplify nginx config for SSR container"
```

---

## Chunk 4: 构建和部署验证

### Task 6: 构建 SSR 镜像

**Files:**
- None (构建操作)

- [ ] **Step 1: 构建 dev 环境镜像**

Run: `cd docker && docker compose -f docker-compose.yml -f docker-compose.dev.yml build findclass-ssr`

Expected: 构建成功，无错误

- [ ] **Step 2: 验证镜像创建成功**

Run: `docker images | grep findclass-ssr`

Expected: 显示 `findclass-ssr:latest` 镜像

### Task 7: 启动 dev 容器

**Files:**
- None (部署操作)

- [ ] **Step 1: 停止旧容器**

Run: `cd docker && docker compose -f docker-compose.yml -f docker-compose.dev.yml down`

- [ ] **Step 2: 启动新容器**

Run: `cd docker && docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d findclass-ssr`

- [ ] **Step 3: 检查容器状态**

Run: `docker ps | grep findclass-ssr`

Expected: 容器状态为 `healthy`

### Task 8: 验证功能

**Files:**
- None (验证操作)

- [ ] **Step 1: 验证 API 健康检查**

Run: `curl -s http://localhost:3001/api/health`

Expected: 返回 `{"status":"ok",...}`

- [ ] **Step 2: 验证 SSR 渲染**

Run: `curl -s http://localhost:3001/ | head -20`

Expected: 返回完整 HTML，包含 SSR 渲染内容

- [ ] **Step 3: 验证静态资源**

Run: `curl -s -I http://localhost:3001/favicon.svg`

Expected: 返回 200 状态码

### Task 9: 最终提交

- [ ] **Step 1: 查看所有变更**

Run: `git status`

- [ ] **Step 2: 确认并推送**

```bash
git push origin main
```

---

## 部署流程总结

### Dev 环境
```bash
cd docker
docker compose -f docker-compose.yml -f docker-compose.dev.yml build findclass-ssr
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d findclass-ssr
# 访问 http://<服务器内网IP>:3001 验证
```

### Prod 环境（dev 验证通过后）
```bash
cd docker
docker compose -f docker-compose.yml -f docker-compose.prod.yml build findclass-ssr
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d findclass-ssr
# 通过 class.noda.co.nz 验证
```
