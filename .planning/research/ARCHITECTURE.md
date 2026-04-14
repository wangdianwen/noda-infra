# Architecture Research: v1.4 CI/CD 零停机部署

**Domain:** Jenkins + Docker 蓝绿部署（单服务器 Docker Compose 基础设施）
**Researched:** 2026-04-14
**Confidence:** HIGH（基于项目代码库直接分析 + Jenkins 官方文档 + nginx reload 机制验证）

---

## 一、系统总览

### 1.1 当前架构（v1.3）

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops) → nginx:80
                                │
                                ├─ class.noda.co.nz  → nginx → findclass-ssr:3001
                                │
                                └─ auth.noda.co.nz   → nginx → keycloak:8080

Docker Compose 项目：
  noda-infra  — postgres, keycloak, nginx, noda-ops, postgres-dev
  noda-apps   — findclass-ssr, skykiwi-crawler, noda-site
  共享网络：noda-network (external)
```

### 1.2 目标架构（v1.4）

```
开发者 push → Jenkins Pipeline（宿主机）
                   │
                   ├─ Stage 1: Lint + 单元测试
                   ├─ Stage 2: docker compose build
                   ├─ Stage 3: docker run 新容器（蓝或绿）
                   ├─ Stage 4: 健康检查
                   ├─ Stage 5: nginx upstream 切换 + reload
                   ├─ Stage 6: 旧容器下线
                   └─ 失败 → 自动回滚（不切换流量）

浏览器 → Cloudflare CDN → Cloudflare Tunnel → nginx:80
                                              │
                    nginx include 文件决定流量方向
                      ┌──────────┴──────────┐
                 findclass-blue:3001    findclass-green:3002
                  （活跃 或 空闲）       （空闲 或 活跃）
```

---

## 二、组件边界

| 组件 | 职责 | 实现方式 | 运行位置 |
|------|------|---------|---------|
| Jenkins | CI/CD 编排、Pipeline 管理 | 宿主机原生安装（systemd） | 宿主机 |
| Jenkins Pipeline | 构建、测试、部署流程 | Jenkinsfile (Declarative) | Jenkins agent |
| 蓝绿状态文件 | 记录当前活跃颜色 | `/var/lib/noda-deploy/current_color` | 宿主机文件 |
| Nginx upstream 文件 | 流量路由目标 | `config/nginx/snippets/upstream-findclass.conf` | nginx 容器挂载卷 |
| 蓝容器 | findclass-ssr 生产实例 | `docker run`（非 compose） | Docker 引擎 |
| 绿容器 | findclass-ssr 生产实例 | `docker run`（非 compose） | Docker 引擎 |
| 构建服务 | 镜像构建 | `docker compose build`（仅构建用） | Docker 引擎 |
| 基础设施服务 | postgres, keycloak, nginx, noda-ops | `docker compose up`（不变） | Docker 引擎 |

### 关键设计决策

| 决策 | 理由 |
|------|------|
| 蓝绿容器用 `docker run` 而非 compose | compose 会管理生命周期，蓝绿需要独立启停控制；compose 仅用于构建 |
| Nginx 通过 `include` 文件切换 | 原子操作：写文件 + reload，比 sed 替换大文件更安全 |
| 状态文件用纯文本 | 单服务器无需分布式状态，文本文件最简单可靠 |
| Jenkins 宿主机原生安装 | 直接操作 Docker socket，无容器嵌套复杂性 |
| Pipeline 手动触发 | 单人项目，避免每次 push 自动部署的噪音 |

---

## 三、蓝绿部署架构详解

### 3.1 容器命名与端口

```
findclass-ssr-blue   → 容器内 3001，Docker 网络 noda-network
findclass-ssr-green  → 容器内 3001，Docker 网络 noda-network
（两者内部端口相同，通过容器名区分，nginx upstream 指向容器名）
```

**为什么不需要映射不同宿主机端口：** 所有流量通过 nginx 转发，nginx 和蓝绿容器在同一 Docker 网络（noda-network），通过容器名直接通信。不需要暴露宿主机端口。

### 3.2 Nginx 切换机制

**核心文件结构：**

```
config/nginx/
├── nginx.conf                       # 主配置，include snippets/*.conf
├── conf.d/
│   └── default.conf                 # server blocks（不包含 upstream 定义）
└── snippets/
    ├── proxy-common.conf            # 通用代理头
    ├── proxy-websocket.conf         # WebSocket 支持
    └── upstream-findclass.conf      # 蓝绿切换入口（Pipeline 写入）
```

**`upstream-findclass.conf` 文件内容（动态生成）：**

```nginx
# 由 Jenkins Pipeline 自动管理 - 不要手动编辑
# 当前活跃: blue
# 最后更新: 2026-04-14T12:00:00Z
upstream findclass_backend {
    server findclass-ssr-blue:3001 max_fails=3 fail_timeout=30s;
}
```

**切换到绿色时重写为：**

```nginx
# 由 Jenkins Pipeline 自动管理 - 不要手动编辑
# 当前活跃: green
# 最后更新: 2026-04-14T12:05:00Z
upstream findclass_backend {
    server findclass-ssr-green:3001 max_fails=3 fail_timeout=30s;
}
```

**切换步骤（原子操作）：**

```bash
# 1. 写入新 upstream 配置
cat > config/nginx/snippets/upstream-findclass.conf <<EOF
upstream findclass_backend {
    server findclass-ssr-green:3001 max_fails=3 fail_timeout=30s;
}
EOF

# 2. 验证配置语法
docker exec noda-infra-nginx nginx -t

# 3. 优雅重载（零停机：现有连接完成后再应用新配置）
docker exec noda-infra-nginx nginx -s reload
```

**为什么 `nginx -s reload` 是零停机：** Nginx reload 启动新的 worker 进程加载新配置，旧 worker 进程继续处理现有请求直到完成。在极短时间内（通常 < 100ms）新旧 worker 共存，不存在连接中断。

### 3.3 蓝绿状态管理

**状态文件：** `/var/lib/noda-deploy/current_color`

```
blue
```

**状态读取（bash）：**

```bash
CURRENT_COLOR=$(cat /var/lib/noda-deploy/current_color 2>/dev/null || echo "blue")
TARGET_COLOR=$([ "$CURRENT_COLOR" = "blue" ] && echo "green" || echo "blue")
```

**状态写入（仅健康检查通过后）：**

```bash
echo "$TARGET_COLOR" > /var/lib/noda-deploy/current_color
```

### 3.4 完整部署流程

```
Jenkins Pipeline 触发
    │
    ▼
┌─────────────────────────┐
│ Stage 1: 代码拉取        │  git pull / git clone
└────────┬────────────────┘
         │
    ▼
┌─────────────────────────┐
│ Stage 2: Lint + 测试     │  pnpm lint, pnpm test
│  失败 → Pipeline 中止    │  编译失败不 down 站
└────────┬────────────────┘
         │
    ▼
┌─────────────────────────┐
│ Stage 3: 构建镜像        │  docker compose -f docker-compose.app.yml build
│  标签: findclass-ssr:    │  使用 BUILD_NUMBER 作为标签
│    ${BUILD_NUMBER}       │
└────────┬────────────────┘
         │
    ▼
┌─────────────────────────┐
│ Stage 4: 部署新容器      │  读取状态文件 → 确定目标颜色
│  docker stop 旧容器      │  docker run 新容器（--name findclass-ssr-${COLOR}）
│  docker rm 旧容器        │  加入 noda-network
│  docker run 新容器       │  使用镜像 ${BUILD_NUMBER}
└────────┬────────────────┘
         │
    ▼
┌─────────────────────────┐
│ Stage 5: 健康检查        │  轮询容器健康状态（最多 90s）
│  失败 → 不切换流量       │  wget http://容器:3001/api/health
│  清理新容器              │  失败时 docker stop/rm 新容器
└────────┬────────────────┘
         │
    ▼
┌─────────────────────────┐
│ Stage 6: 切换流量        │  写入 upstream-findclass.conf
│  nginx -t && reload      │  更新状态文件
│  等待 10s                │
└────────┬────────────────┘
         │
    ▼
┌─────────────────────────┐
│ Stage 7: E2E 验证        │  curl https://class.noda.co.nz/api/health
│  失败 → 自动回滚         │  切回旧 upstream + reload + 清理新容器
└────────┬────────────────┘
         │
    ▼
┌─────────────────────────┐
│ Stage 8: 清理旧容器      │  docker stop/rm 旧颜色容器
│  保留镜像用于回滚        │  只删除容器，不删除镜像
└─────────────────────────┘
```

---

## 四、回滚机制

### 4.1 三层回滚保护

| 层级 | 触发条件 | 回滚动作 | 数据影响 |
|------|---------|---------|---------|
| Level 1: 健康检查失败 | 新容器 90s 内未 healthy | 不切换流量，清理新容器 | 零影响 |
| Level 2: E2E 验证失败 | 上线后外部 HTTP 检查失败 | 切回旧 upstream + reload | 零影响 |
| Level 3: 手动紧急回滚 | 人为发现问题 | 执行回滚脚本 | 零影响 |

### 4.2 自动回滚流程（Level 2）

```
E2E 验证失败
    │
    ├─ 1. 切回旧 upstream 文件
    │     echo "server findclass-ssr-${CURRENT_COLOR}:3001" > upstream-findclass.conf
    │
    ├─ 2. nginx -t && nginx -s reload
    │
    ├─ 3. 验证回滚成功
    │     curl https://class.noda.co.nz/api/health
    │
    ├─ 4. 清理失败的新容器
    │     docker stop findclass-ssr-${TARGET_COLOR}
    │     docker rm findclass-ssr-${TARGET_COLOR}
    │
    └─ 5. Pipeline 标记 FAILURE
```

### 4.3 手动回滚脚本

```bash
#!/bin/bash
# scripts/deploy/rollback-findclass.sh
# 用途：紧急手动回滚到上一个版本

set -euo pipefail

CURRENT=$(cat /var/lib/noda-deploy/current_color)
PREVIOUS=$([ "$CURRENT" = "blue" ] && echo "green" || echo "blue")

# 检查回滚目标容器是否存在且运行
if ! docker ps --format '{{.Names}}' | grep -q "findclass-ssr-${PREVIOUS}"; then
    echo "错误：回滚目标容器 findclass-ssr-${PREVIOUS} 不存在或未运行"
    exit 1
fi

echo "回滚：${CURRENT} → ${PREVIOUS}"

# 切换 upstream
cat > config/nginx/snippets/upstream-findclass.conf <<EOF
upstream findclass_backend {
    server findclass-ssr-${PREVIOUS}:3001 max_fails=3 fail_timeout=30s;
}
EOF

docker exec noda-infra-nginx nginx -t
docker exec noda-infra-nginx nginx -s reload

# 更新状态
echo "${PREVIOUS}" > /var/lib/noda-deploy/current_color

echo "回滚完成"
```

---

## 五、Jenkins 架构

### 5.1 安装模式

**宿主机原生安装（systemd），不使用 Docker 容器运行 Jenkins。**

理由：
1. Jenkins 需要直接操作 Docker socket（`/var/run/docker.sock`），宿主机安装避免卷挂载复杂性
2. Pipeline 中执行 `docker run`、`docker exec` 等命令直接可用
3. 不引入 Docker-in-Docker 的安全风险
4. 单服务器场景，无多节点调度需求

### 5.2 Jenkins 目录结构

```
/var/lib/noda-deploy/
├── current_color                      # 蓝绿状态文件
└── deploy-history.log                 # 部署历史日志

/opt/jenkins/                          # JENKINS_HOME
├── jobs/
│   └── noda-findclass-deploy/
│       └── config.xml
└── workspace/
    └── noda-findclass-deploy/         # 工作目录（git clone）

~/noda-infra/                          # 项目代码（Jenkins workspace）
├── Jenkinsfile
├── config/nginx/snippets/
│   └── upstream-findclass.conf        # nginx 切换文件
├── docker/
│   └── docker-compose.app.yml         # 仅用于构建
├── deploy/
│   └── Dockerfile.findclass-ssr       # 构建定义
└── scripts/
    └── deploy/
        ├── blue-green-deploy.sh       # 蓝绿部署核心脚本
        └── rollback-findclass.sh      # 手动回滚脚本
```

### 5.3 Jenkins 与 Docker 交互

```
Jenkins (宿主机 systemd)
    │
    ├─ docker compose build           # 构建镜像
    ├─ docker run findclass-ssr-blue  # 启动蓝容器
    ├─ docker run findclass-ssr-green # 启动绿容器
    ├─ docker exec nginx nginx -s reload  # 切换流量
    ├─ docker stop/rm                 # 清理容器
    │
    └─ 读写文件
        ├─ /var/lib/noda-deploy/current_color
        └─ config/nginx/snippets/upstream-findclass.conf
           ↓（volume mount）
           nginx 容器读取
```

Jenkins 用户需要加入 `docker` 组以获得 Docker socket 访问权限。

### 5.4 Pipeline 结构

```groovy
pipeline {
    agent any

    environment {
        PROJECT_ROOT = '/home/${USER}/noda-infra'
        STATE_FILE = '/var/lib/noda-deploy/current_color'
        COMPOSE_FILE = 'docker/docker-compose.app.yml'
        NETWORK = 'noda-network'
        HEALTH_TIMEOUT = '90'
    }

    stages {
        stage('Checkout') { /* git pull */ }
        stage('Lint & Test') { /* pnpm lint + pnpm test */ }
        stage('Build Image') { /* docker compose build */ }
        stage('Blue-Green Deploy') {
            steps {
                sh "bash scripts/deploy/blue-green-deploy.sh"
            }
        }
    }

    post {
        failure {
            echo '部署失败，流量未切换，当前版本仍在运行'
        }
        success {
            echo "部署成功，当前活跃: ${CURRENT_COLOR}"
        }
    }
}
```

**核心部署逻辑放在 `blue-green-deploy.sh` 中，而非 Jenkinsfile。** 理由：
1. 可在 Jenkins 外手动执行（调试、紧急修复）
2. bash 脚本比 Groovy 更容易调试和迭代
3. 符合现有项目的脚本驱动部署模式

---

## 六、数据流

### 6.1 部署请求流

```
开发者手动触发 Jenkins Job
    │
    ▼
Jenkins 读取 STATE_FILE → 确定当前颜色（如 blue）
    │
    ▼
目标颜色 = green
    │
    ▼
docker compose build → 镜像 findclass-ssr:${BUILD_NUMBER}
    │
    ▼
docker stop findclass-ssr-green（如果存在旧绿色容器）
docker rm findclass-ssr-green
    │
    ▼
docker run --name findclass-ssr-green \
    --network noda-network \
    -e NODE_ENV=production \
    -e DATABASE_URL=... \
    --label noda.color=green \
    --label noda.build=${BUILD_NUMBER} \
    findclass-ssr:${BUILD_NUMBER}
    │
    ▼
轮询健康检查（最多 90s）
    │
    ├─ 失败 → docker stop/rm findclass-ssr-green → Pipeline FAIL
    │
    ▼  成功
写入 upstream-findclass.conf（指向 green）
    │
    ▼
docker exec noda-infra-nginx nginx -t
docker exec noda-infra-nginx nginx -s reload
    │
    ▼
echo "green" > STATE_FILE
    │
    ▼
等待 10s + E2E 验证
    │
    ├─ 失败 → 回滚到 blue upstream + reload → Pipeline FAIL
    │
    ▼  成功
docker stop findclass-ssr-blue
docker rm findclass-ssr-blue
（保留 findclass-ssr-blue 镜像用于紧急回滚）
    │
    ▼
Pipeline SUCCESS
```

### 6.2 请求路由流（正常流量）

```
浏览器 → class.noda.co.nz
    │
    ▼
Cloudflare CDN（TLS 终止）
    │
    ▼
Cloudflare Tunnel (noda-ops 容器内 cloudflared)
    │
    ▼
nginx:80（noda-infra-nginx 容器）
    │
    ├─ server_name class.noda.co.nz 匹配
    │
    ▼
upstream findclass_backend（从 upstream-findclass.conf 读取）
    │
    ├─ 当前指向 findclass-ssr-blue:3001 或 findclass-ssr-green:3001
    │
    ▼
活跃颜色容器处理请求
    │
    ├─ SSR 渲染 + API 响应 + 静态文件
    │  容器内连接 PostgreSQL: noda-infra-postgres-prod:5432
    │  容器内连接 Keycloak: noda-infra-keycloak-prod:8080
    │
    ▼
响应原路返回 → 浏览器
```

### 6.3 关键数据存储

| 数据 | 存储位置 | 格式 | 访问者 |
|------|---------|------|--------|
| 蓝绿状态 | `/var/lib/noda-deploy/current_color` | 纯文本 `blue` 或 `green` | Jenkins, 手动脚本 |
| Upstream 配置 | `config/nginx/snippets/upstream-findclass.conf` | nginx 配置 | nginx 容器 |
| 部署历史 | `/var/lib/noda-deploy/deploy-history.log` | 时间戳 + 颜色 + build号 + 结果 | Jenkins |
| 容器镜像 | Docker 本地存储 | `findclass-ssr:${BUILD_NUMBER}` | Docker 引擎 |

---

## 七、现有部署脚本迁移路径

### 7.1 迁移映射

| 现有脚本功能 | v1.4 对应 | 迁移方式 |
|-------------|----------|---------|
| `deploy-apps-prod.sh` Step 1: 验证基础设施 | Jenkins Stage: Pre-check | 保留为独立脚本，Pipeline 调用 |
| `deploy-apps-prod.sh` Step 2: 保存镜像标签 | 不需要 | 蓝绿模式下旧容器保留到验证通过 |
| `deploy-apps-prod.sh` Step 3: 构建镜像 | Jenkins Stage: Build Image | `docker compose build` 不变 |
| `deploy-apps-prod.sh` Step 4: 部署新版本 | Jenkins Stage: Blue-Green Deploy | 从 compose up 改为 docker run |
| `deploy-apps-prod.sh` Step 5: 健康检查 | Jenkins Stage: Health Check | 复用 `scripts/lib/health.sh` |
| `deploy-apps-prod.sh` 回滚机制 | 蓝绿回滚 | 从 compose override 改为 upstream 切回 |
| `deploy-infrastructure-prod.sh` | 不变 | 基础设施仍用 compose 部署 |
| `scripts/lib/health.sh` | 复用 | 蓝绿部署脚本直接 source |
| `scripts/lib/log.sh` | 复用 | 所有脚本复用 |
| `scripts/verify/verify-infrastructure.sh` | 复用 | Pipeline 预检调用 |

### 7.2 关键变更：docker compose up → docker run

**现有模式（v1.3）：**
```bash
docker compose -f docker/docker-compose.app.yml up -d --force-recreate findclass-ssr
```
- compose 管理容器生命周期
- 直接替换旧容器（有短暂停机）
- 回滚通过 compose override 镜像 digest

**新模式（v1.4）：**
```bash
docker run -d \
    --name findclass-ssr-${TARGET_COLOR} \
    --network noda-network \
    --restart unless-stopped \
    --label noda.color=${TARGET_COLOR} \
    --label noda.build=${BUILD_NUMBER} \
    -e NODE_ENV=production \
    -e "DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@noda-infra-postgres-prod:5432/noda_prod" \
    -e "KEYCLOAK_URL=https://auth.noda.co.nz" \
    -e "KEYCLOAK_INTERNAL_URL=http://noda-infra-keycloak-prod:8080" \
    -e "KEYCLOAK_REALM=noda" \
    -e "KEYCLOAK_CLIENT_ID=noda-frontend" \
    findclass-ssr:${BUILD_NUMBER}
```
- docker run 独立管理（蓝绿各一个容器）
- 旧容器在流量切换后继续运行（直到验证通过）
- 回滚通过 nginx upstream 切回（秒级，无需重建容器）

### 7.3 环境变量来源

`docker-compose.app.yml` 中定义了 findclass-ssr 的完整环境变量。迁移到 `docker run` 时需要从 `config/secrets.sops.yaml` 解密读取。

**方案：** 在 `blue-green-deploy.sh` 中 source 一个环境变量文件：

```bash
# scripts/deploy/blue-green-env.sh
# 由 sops 解密 config/secrets.sops.yaml 生成
export POSTGRES_USER="..."
export POSTGRES_PASSWORD="..."
export DATABASE_URL="postgresql://..."
export KEYCLOAK_URL="https://auth.noda.co.nz"
# ... 其他变量
```

或者直接在 Pipeline 中通过 `sops -d` 读取并 export：

```bash
eval "$(sops -d config/secrets.sops.yaml | yq 'to_entries | .[] | "export " + .key + "=\"" + .value + "\""')"
```

---

## 八、Nginx 配置变更

### 8.1 `default.conf` 变更

**当前（v1.3）：**
```nginx
upstream findclass_backend {
    server findclass-ssr:3001 max_fails=3 fail_timeout=30s;
}
```

**目标（v1.4）：**
```nginx
# upstream 定义移到 snippets/upstream-findclass.conf
# default.conf 只保留 server blocks
server {
    listen 80;
    server_name localhost class.noda.co.nz;
    # ... 其他配置不变

    location / {
        proxy_pass http://findclass_backend;  # 引用不变
        # ... 其他配置不变
    }
}
```

**变更内容：** 将 `upstream findclass_backend` 块从 `default.conf` 移到 `snippets/upstream-findclass.conf`。`nginx.conf` 已有 `include /etc/nginx/snippets/*.conf;`（第 27 行），自动加载。

**零风险迁移：** 仅改变 upstream 定义的位置，不改变 server block 中的 proxy_pass 目标。nginx reload 后立即生效。

### 8.2 初次迁移步骤

```bash
# 1. 创建 upstream 文件（初始指向当前容器名）
cat > config/nginx/snippets/upstream-findclass.conf <<'EOF'
upstream findclass_backend {
    server findclass-ssr:3001 max_fails=3 fail_timeout=30s;
}
EOF

# 2. 从 default.conf 移除 upstream 块
# 编辑 config/nginx/conf.d/default.conf，删除第 8-10 行

# 3. 验证配置
docker exec noda-infra-nginx nginx -t

# 4. 重载
docker exec noda-infra-nginx nginx -s reload
```

---

## 九、推荐项目结构

```
noda-infra/
├── .planning/                            # 规划文档
├── config/
│   ├── nginx/
│   │   ├── conf.d/
│   │   │   └── default.conf              # server blocks（移除 upstream 定义）
│   │   ├── snippets/
│   │   │   ├── proxy-common.conf
│   │   │   ├── proxy-websocket.conf
│   │   │   └── upstream-findclass.conf   # 新增：蓝绿切换入口
│   │   └── nginx.conf
│   └── secrets.sops.yaml
├── deploy/
│   └── Dockerfile.findclass-ssr
├── docker/
│   ├── docker-compose.yml                # 基础设施（不变）
│   ├── docker-compose.prod.yml           # 生产覆盖（不变）
│   ├── docker-compose.dev.yml            # 开发覆盖（不变）
│   └── docker-compose.app.yml            # 应用构建定义（仅用于 build）
├── scripts/
│   ├── deploy/
│   │   ├── blue-green-deploy.sh          # 新增：蓝绿部署核心脚本
│   │   ├── rollback-findclass.sh         # 新增：手动回滚脚本
│   │   ├── deploy-infrastructure-prod.sh # 不变
│   │   └── deploy-apps-prod.sh           # 保留（可手动执行，不经过 Jenkins）
│   ├── install/
│   │   └── install-jenkins.sh            # 新增：Jenkins 安装脚本
│   ├── lib/
│   │   ├── health.sh                     # 复用
│   │   └── log.sh                        # 复用
│   └── verify/
│       └── verify-infrastructure.sh      # 复用
├── Jenkinsfile                           # 新增：Pipeline 定义
└── var/
    └── lib/
        └── noda-deploy/
            ├── current_color             # 蓝绿状态文件（运行时生成）
            └── deploy-history.log        # 部署历史（运行时生成）
```

---

## 十、架构模式

### Pattern 1: Include 文件切换模式

**内容：** 通过重写 nginx include 文件 + reload 实现流量切换
**使用条件：** 单服务器、nginx 反向代理、需要零停机切换
**权衡：** 极简但依赖文件系统一致性；nginx reload 有极短暂的配置不一致窗口（< 100ms）

**实施：**
```bash
# 写入新 upstream（原子写：写临时文件 + mv）
cat > /tmp/upstream-findclass.conf.tmp <<EOF
upstream findclass_backend {
    server findclass-ssr-${TARGET}:3001 max_fails=3 fail_timeout=30s;
}
EOF
mv /tmp/upstream-findclass.conf.tmp config/nginx/snippets/upstream-findclass.conf

# 验证 + reload
docker exec noda-infra-nginx nginx -t && docker exec noda-infra-nginx nginx -s reload
```

### Pattern 2: 构建与运行分离模式

**内容：** `docker compose build` 仅用于构建镜像，`docker run` 管理蓝绿容器生命周期
**使用条件：** 需要独立控制多个同服务容器的启停
**权衡：** 丢失 compose 的声明式管理，换来蓝绿独立控制能力

**实施：**
```bash
# 构建（compose 负责）
docker compose -f docker/docker-compose.app.yml build findclass-ssr

# 运行（docker run 负责）
docker run -d --name findclass-ssr-green --network noda-network findclass-ssr:latest
```

### Pattern 3: 部署脚本与 Pipeline 分离模式

**内容：** 核心部署逻辑放在 bash 脚本中，Jenkinsfile 仅编排调用
**使用条件：** 需要同时支持 Jenkins 自动化和手动执行
**权衡：** 维护两套入口（Jenkinsfile + bash），但获得灵活性和可调试性

**实施：**
```groovy
// Jenkinsfile
stage('Blue-Green Deploy') {
    sh "bash scripts/deploy/blue-green-deploy.sh"
}
```

### Pattern 4: 镜像保留回滚模式

**内容：** 旧版本镜像不删除，用于紧急回滚
**使用条件：** 磁盘空间充足、需要快速回滚能力
**权衡：** 占用更多磁盘，但回滚不依赖重新构建

**实施：**
```bash
# 部署成功后只删除旧容器，保留旧镜像
docker stop findclass-ssr-${CURRENT_COLOR}
docker rm findclass-ssr-${CURRENT_COLOR}
# 不执行 docker rmi

# 紧急回滚时可以直接用旧镜像
docker run -d --name findclass-ssr-${CURRENT_COLOR} \
    --network noda-network \
    findclass-ssr:${PREVIOUS_BUILD}
```

---

## 十一、反模式

### Anti-Pattern 1: 在 Jenkinsfile 中写复杂部署逻辑

**错误做法：** 在 Jenkinsfile（Groovy）中实现 docker run、健康检查、nginx 切换等所有逻辑。

**原因：** Groovy 比 bash 更难调试；无法脱离 Jenkins 独立执行；Pipeline 日志中 bash 输出被包裹在 sh step 中，不如直接运行 bash 脚本清晰。

**正确做法：** 部署逻辑放在 `scripts/deploy/blue-green-deploy.sh`，Jenkinsfile 只编排 stage 调用。

### Anti-Pattern 2: 蓝绿容器使用 docker compose 管理

**错误做法：** 在 compose 文件中定义 blue 和 green 两个服务，用 `docker compose up -d` 管理生命周期。

**原因：** compose 的设计假设同一服务只有一个实例。两个同名服务需要两个 compose 文件或复杂的 profile 机制。`docker compose up` 会尝试同时管理两个实例的健康检查和重启策略，干扰蓝绿的独立控制。

**正确做法：** compose 仅用于构建（`docker compose build`），运行时用 `docker run` 独立管理蓝绿容器。

### Anti-Pattern 3: 修改 default.conf 做 upstream 切换

**错误做法：** 用 sed 替换 `default.conf` 中的 upstream server 地址。

**原因：** `default.conf` 是 169 行的大文件，sed 替换容易误匹配。且 default.conf 包含多个 server block，修改大文件增加出错风险。

**正确做法：** upstream 定义放在独立 include 文件（`upstream-findclass.conf`），Pipeline 只重写这个小文件。

### Anti-Pattern 4: 健康检查通过后立即删除旧容器

**错误做法：** 新容器健康检查通过就立即 `docker stop/rm` 旧容器。

**原因：** 切换流量后可能存在短暂问题（如 DNS 缓存、连接池初始化）。如果 E2E 验证在切换后失败，旧容器已删除则无法回滚。

**正确做法：** 切换流量 → E2E 验证通过 → 才删除旧容器。保留旧容器直到新版本确认稳定。

### Anti-Pattern 5: Jenkins 运行在 Docker 容器中

**错误做法：** 将 Jenkins 作为 Docker 容器运行，挂载 Docker socket。

**原因：** Docker socket 挂载等于给 Jenkins 容器完整的宿主机 root 权限。且 Pipeline 中的 `docker run` 命令创建的容器会在 Jenkins 容器的网络命名空间外运行，网络配置复杂。

**正确做法：** Jenkins 原生安装在宿主机，直接访问 Docker socket。

### Anti-Pattern 6: 使用 latest 标签追踪生产镜像

**错误做法：** 蓝绿容器始终使用 `findclass-ssr:latest` 标签。

**原因：** 无法区分当前运行的是哪个构建版本。回滚时不知道要用哪个旧镜像。

**正确做法：** 每次构建使用 `${BUILD_NUMBER}` 作为标签。部署后记录当前活跃颜色 + 构建号到 `deploy-history.log`。

---

## 十二、可扩展性考虑

| 关注点 | 当前（单服务器 ~7 容器） | 中等（多应用 + 多服务器） | 大型（微服务） |
|-------|----------------------|----------------------|-------------|
| 部署方式 | Jenkins + bash 脚本 | Jenkins Shared Libraries | Kubernetes + ArgoCD |
| 流量切换 | nginx include 文件 | nginx + Consul Template | Ingress + Service Mesh |
| 状态管理 | 宿主机文件 | Consul/etcd 键值存储 | CRD (Custom Resource) |
| 回滚 | 手动脚本 | 自动 + 审批门 | GitOps 自动回滚 |
| 容器编排 | docker run | Docker Swarm | Kubernetes |

**当前阶段结论：** 单服务器 + 2 个应用容器（findclass-ssr, noda-site），bash 脚本 + nginx include 切换完全够用。noda-site 如果未来也需要蓝绿部署，可以复用同样的模式，添加 `upstream-nodasite.conf`。

---

## 十三、构建顺序建议

```
Phase 1: Jenkins 安装与基础配置
  │  宿主机安装 Jenkins (systemd)
  │  配置 Docker socket 访问权限
  │  安装必要插件（Pipeline, Git）
  │  创建第一个 Pipeline Job（空操作）
  │  验证：Jenkins 可访问 Docker
  │
Phase 2: Nginx 配置重构
  │  upstream 从 default.conf 移到 snippets/upstream-findclass.conf
  │  验证 nginx -t + reload 正常
  │  验证现有流量不受影响
  │
Phase 3: 蓝绿部署核心脚本
  │  创建 blue-green-deploy.sh
  │  创建 /var/lib/noda-deploy/ 目录和状态文件
  │  手动测试蓝绿切换（不经过 Jenkins）
  │  验证：手动切换 + 回滚正常工作
  │
Phase 4: Jenkins Pipeline 集成
  │  编写 Jenkinsfile
  │  集成 lint + 测试 stage
  │  集成蓝绿部署 stage
  │  添加 E2E 健康检查 + 自动回滚
  │  验证：完整 Pipeline 端到端运行
  │
Phase 5: 部署脚本迁移 + 文档
     迁移现有 deploy-apps-prod.sh 的环境变量到新脚本
     保留旧脚本作为备选（手动部署入口）
     更新 CLAUDE.md 部署文档
```

**Phase 1 先行的理由：** Jenkins 安装是基础设施变更，独立于应用逻辑，风险最低。
**Phase 3 在 Phase 4 之前的理由：** 核心部署逻辑先手动验证，再集成到 Jenkins，降低调试复杂度。

---

## 十四、与其他服务的关系

### 14.1 基础设施服务（不在蓝绿范围内）

| 服务 | 部署方式 | 蓝绿部署？ | 原因 |
|------|---------|-----------|------|
| PostgreSQL | `deploy-infrastructure-prod.sh` | 否 | 有状态，蓝绿会导致数据不一致 |
| Keycloak | `deploy-infrastructure-prod.sh` | 否 | 有状态（session、token），更新频率极低 |
| Nginx | `deploy-infrastructure-prod.sh` | 否 | 流量路由器，蓝绿部署本身依赖它 |
| noda-ops | `deploy-infrastructure-prod.sh` | 否 | 备份 + Tunnel，更新频率极低 |

### 14.2 蓝绿范围内的服务

| 服务 | 蓝绿方式 | 说明 |
|------|---------|------|
| findclass-ssr | docker run + nginx upstream | 无状态，主要部署目标 |
| noda-site | 暂不纳入蓝绿 | 更新频率低，compose 直接部署即可 |

---

## 数据源

| 来源 | 置信度 | 用途 |
|------|--------|------|
| `docker/docker-compose.yml` | HIGH（直接读取） | 基础设施服务定义、网络配置 |
| `docker/docker-compose.app.yml` | HIGH（直接读取） | findclass-ssr 环境变量、健康检查、资源限制 |
| `config/nginx/conf.d/default.conf` | HIGH（直接读取） | upstream 定义位置、server block 结构 |
| `config/nginx/nginx.conf` | HIGH（直接读取） | include 机制验证（第 27 行 `include snippets/*.conf`） |
| `scripts/deploy/deploy-apps-prod.sh` | HIGH（直接读取） | 现有部署流程、回滚机制、环境变量 |
| `scripts/deploy/deploy-infrastructure-prod.sh` | HIGH（直接读取） | 基础设施部署流程 |
| `scripts/lib/health.sh` | HIGH（直接读取） | 健康检查轮询实现 |
| `deploy/Dockerfile.findclass-ssr` | HIGH（直接读取） | 构建流程、镜像结构 |
| `.planning/PROJECT.md` | HIGH（直接读取） | v1.4 里程碑目标 |
| Jenkins 官方文档 | HIGH（官方来源） | 安装方式、Pipeline 语法 |
| nginx reload 机制 | HIGH（官方文档） | 零停机 reload 原理 |

---

*Architecture research for: Noda v1.4 CI/CD 零停机部署*
*Researched: 2026-04-14*
