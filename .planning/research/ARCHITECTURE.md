# Architecture Patterns: Keycloak 自定义主题 + 双环境

**Domain:** Keycloak 认证服务定制与开发环境隔离
**Researched:** 2026-04-11
**Overall confidence:** HIGH（基于项目代码库直接分析 + Keycloak 官方文档）

---

## 一、架构总览

### 当前架构（v1.1）

```
浏览器 → Cloudflare CDN → Cloudflare Tunnel (noda-ops) → Docker 内部网络
  class.noda.co.nz → nginx → findclass-ssr:3001
  auth.noda.co.nz  → nginx → keycloak:8080
                                │
                                ▼
                          postgres:5432/keycloak
```

### v1.2 目标架构

```
生产环境:
  auth.noda.co.nz → Cloudflare Tunnel → nginx → keycloak:8080
                                                  │
                                                  ├─ postgres:5432/keycloak (prod 数据库)
                                                  └─ /opt/keycloak/themes/noda/login/ (自定义主题)

开发环境:
  localhost:8180 → keycloak-dev:8080
                      │
                      ├─ postgres-dev:5432/keycloak_dev (dev 数据库)
                      └─ /opt/keycloak/themes/noda/login/ (共享自定义主题，热更新)
```

### 变更范围

| 变更类型 | 组件 | 说明 |
|---------|------|------|
| 新增 | `docker/services/keycloak/themes/noda/login/` | 自定义登录主题文件 |
| 新增 | `keycloak-dev` 服务定义（dev overlay） | 开发环境独立 Keycloak 实例 |
| 修改 | `docker/docker-compose.dev.yml` | 添加 keycloak-dev 服务 |
| 不变 | `docker/docker-compose.yml` | 主题卷挂载已预留 |
| 不变 | `docker/docker-compose.prod.yml` | 主题卷挂载已预留 |
| 不变 | `config/nginx/conf.d/default.conf` | 路由规则无需变更 |
| 不变 | `docker/services/postgres/init-dev/` | keycloak_dev 数据库已创建 |

---

## 二、组件清单

### 新增组件

| 组件 | 类型 | 位置 | 职责 |
|------|------|------|------|
| `theme.properties` | 配置文件 | `docker/services/keycloak/themes/noda/login/theme.properties` | 声明主题名称、父主题、样式资源 |
| `login.ftl` | FreeMarker 模板 | `docker/services/keycloak/themes/noda/login/login.ftl` | 可选：自定义登录页 HTML 结构 |
| `noda.css` | 样式表 | `docker/services/keycloak/themes/noda/login/resources/css/noda.css` | 品牌化样式覆盖 |
| `messages_zh.properties` | 消息包 | `docker/services/keycloak/themes/noda/login/messages/messages_zh.properties` | 中文界面文本定制 |
| `messages_en.properties` | 消息包 | `docker/services/keycloak/themes/noda/login/messages/messages_en.properties` | 英文界面文本定制 |
| `keycloak-dev` 服务 | Docker Compose | `docker/docker-compose.dev.yml` | 开发环境独立 Keycloak 实例 |

### 需要修改的组件

| 组件 | 修改内容 | 影响范围 | 修改量 |
|------|---------|---------|--------|
| `docker-compose.dev.yml` | 添加 keycloak-dev 服务 + 修改现有 keycloak 服务指向 postgres-dev | 开发环境 | 中 |

### 不需要修改的组件

| 组件 | 原因 |
|------|------|
| `docker-compose.yml`（基础） | 主题卷挂载 `./services/keycloak/themes:/opt/keycloak/themes/noda:ro` 已存在 |
| `docker-compose.prod.yml`（生产） | 主题卷挂载已存在，生产 Keycloak 无需修改 |
| Nginx 配置 | 主题是 Keycloak 内部渲染，不影响代理路由 |
| findclass-ssr | 应用不直接与主题交互，仅通过 OAuth 协议通信 |
| noda-ops | 备份系统不涉及主题文件 |
| postgres init 脚本 | `keycloak_dev` 数据库已在 `01-create-databases.sql` 中创建 |

---

## 三、自定义主题架构

### 3.1 主题目录结构

```
docker/services/keycloak/
└── themes/
    └── noda/                          # 主题名称（Keycloak 管理界面选择 "noda"）
        └── login/                     # 主题类型：login
            ├── theme.properties       # 主题元数据（父主题、资源引用）
            ├── login.ftl              # 可选：覆盖登录页模板
            ├── resources/
            │   ├── css/
            │   │   └── noda.css       # 品牌化样式
            │   └── img/
            │       └── logo.svg       # Noda 品牌 Logo（可选）
            └── messages/
                ├── messages_en.properties  # 英文文本覆盖
                └── messages_zh.properties  # 中文文本覆盖
```

**目录路径必须精确匹配**：Keycloak 从 `/opt/keycloak/themes/<主题名>/<类型>/` 加载主题。当前 docker-compose.yml 中的卷挂载是：

```yaml
volumes:
  - ./services/keycloak/themes:/opt/keycloak/themes/noda:ro
```

这意味着宿主机 `./services/keycloak/themes/` 下的内容映射到容器内 `/opt/keycloak/themes/noda/`。所以宿主机目录结构应该是：

```
docker/services/keycloak/themes/login/...
```

容器内看到的是 `/opt/keycloak/themes/noda/login/...`。

### 3.2 theme.properties 配置

```properties
# 主题元数据
parent=keycloak
import=common/keycloak

# 样式资源
styles=css/noda.css

# 可选：JavaScript
# scripts=js/noda.js

# 可选：额外 HTML 属性
# htmlClasses=noda-login
```

**关键决策：使用 `parent=keycloak` 继承基础主题。**

原因：
- 不继承基础主题意味着需要重写所有 FreeMarker 模板（login.ftl、login-otp.ftl、login-password.ftl 等 20+ 个模板）
- 继承后只需覆盖需要定制的文件，其余自动回退到父主题
- Keycloak 升级时，自定义文件少意味着兼容性风险低
- 未来 Keycloak 新增登录流程模板（如 WebAuthn），自定义主题自动继承

### 3.3 样式覆盖策略

**推荐：仅覆盖 CSS，不覆盖 FreeMarker 模板。**

仅在以下情况覆盖 `login.ftl`：
- 需要修改 HTML 结构（如添加额外 DOM 元素）
- 需要插入自定义 JavaScript
- 需要修改表单字段顺序或布局

纯 CSS 可以实现的品牌化：
- Logo 替换（背景图片覆盖 `.kc-logo-text`）
- 颜色方案（CSS 变量覆盖）
- 字体（Google Fonts 引入）
- 布局微调（间距、圆角、阴影）
- 按钮样式
- 背景图片

**示例 noda.css 最小集：**

```css
/* Noda 品牌化样式 - 覆盖 Keycloak 默认主题 */
:root {
  --pf-global--primary-color--100: #2563eb;  /* Noda 品牌蓝 */
  --pf-global--primary-color--200: #1d4ed8;
  --pf-global--BackgroundColor--100: #f8fafc;
}

/* 登录页容器 */
.login-pf body {
  background: linear-gradient(135deg, #1e3a5f 0%, #2563eb 100%);
}

/* Logo 区域 */
.kc-logo-text {
  background-image: url('../img/logo.svg');
  background-repeat: no-repeat;
  background-size: contain;
  width: 120px;
  height: 40px;
}

/* 登录卡片 */
.card-pf {
  border-radius: 12px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.12);
}

/* 登录按钮 */
.pf-c-button.pf-m-primary {
  background-color: #2563eb;
  border-radius: 8px;
}
```

### 3.4 消息包定制

**仅覆盖需要修改的文本，未覆盖的自动使用 Keycloak 默认翻译。**

`messages_en.properties`:
```properties
# 覆盖登录页标题
loginTitle=Noda
loginTitleHtml=Noda

# 覆盖欢迎文本
loginWelcome=Sign in to your account

# 覆盖 Google 登录按钮文本（如果使用 identity provider）
identity-provider-link-label=Sign in with Google
```

`messages_zh.properties`:
```properties
loginTitle=Noda
loginTitleHtml=Noda
loginWelcome=\u767b\u5f55\u60a8\u7684\u8d26\u6237
identity-provider-link-label=\u4f7f\u7528 Google \u767b\u5f55
```

### 3.5 主题激活流程

主题文件就位后，需要在 Keycloak Admin Console 中激活：

```
1. 访问 https://auth.noda.co.nz/admin/ （生产）或 http://localhost:8180/admin/ （开发）
2. 登录管理员账号（KEYCLOAK_ADMIN_USER / KEYCLOAK_ADMIN_PASSWORD）
3. 选择 noda realm
4. Realm Settings → Themes 标签
5. Login Theme 下拉菜单选择 "noda"
6. 保存
```

**注意：** 主题选择是 realm 级别的设置，存储在 Keycloak 数据库中。这意味着：
- 生产环境选择一次即可，后续主题文件更新自动生效
- 开发环境需要单独选择（不同的数据库）
- 主题选择不会因为容器重启而丢失

### 3.6 与现有 Docker Compose 的集成

当前 `docker-compose.yml` 中已预留主题卷挂载：

```yaml
# docker-compose.yml 第 155 行
keycloak:
  volumes:
    - ./services/keycloak/themes:/opt/keycloak/themes/noda:ro
```

`docker-compose.prod.yml` 也重复了这个挂载（第 68 行）。两者指向同一个宿主机目录，因此：

1. 创建 `docker/services/keycloak/themes/login/` 目录和主题文件
2. Docker Compose 无需修改（卷挂载已就绪）
3. 重启 Keycloak 容器或等待主题缓存过期后生效

**卷挂载使用 `:ro`（只读），主题文件通过宿主机编辑，容器内只读加载。** 这是正确的模式 -- 主题文件由 Git 管理，不应该在容器内修改。

---

## 四、双环境架构

### 4.1 设计原则

复用 PostgreSQL 双环境的成功模式：
- prod 实例：内部网络，不暴露端口，使用生产数据
- dev 实例：暴露端口，使用开发数据，独立容器名

Keycloak 双环境遵循相同的 overlay 模式：

```
docker-compose.yml          → 基础 Keycloak 配置（prod）
docker-compose.dev.yml      → 开发覆盖：添加 keycloak-dev 服务 + 修改现有 keycloak 指向 dev
docker-compose.prod.yml     → 生产覆盖：SMTP、资源限制、健康检查
```

### 4.2 开发环境 Keycloak 服务定义

需要在 `docker-compose.dev.yml` 中添加以下配置：

**方案：添加独立的 `keycloak-dev` 服务。**

为什么不直接覆盖现有 `keycloak` 服务：
- 覆盖 `keycloak` 服务会让开发环境连到同一个 postgres 数据库，没有真正隔离
- 独立服务可以同时运行 prod 和 dev，方便对比测试
- 与 postgres-dev 的模式一致（独立服务，不覆盖）

```yaml
# docker-compose.dev.yml 中新增
keycloak-dev:
  image: quay.io/keycloak/keycloak:26.2.3
  container_name: noda-infra-keycloak-dev
  restart: unless-stopped
  command: start-dev
  ports:
    - "8180:8080"   # 开发环境 HTTP 端口（避免与 prod 8080 冲突）
    - "9100:9000"   # 开发环境管理端口
  environment:
    # 数据库配置：连接 postgres-dev 的 keycloak_dev 数据库
    KC_DB: postgres
    KC_DB_URL: jdbc:postgresql://postgres-dev:5432/keycloak_dev
    KC_DB_USERNAME: ${POSTGRES_USER}
    KC_DB_PASSWORD: ${POSTGRES_PASSWORD}
    # 开发模式：禁用主机名和代理
    KC_HOSTNAME: ""
    KC_HOSTNAME_STRICT: "false"
    KC_HOSTNAME_STRICT_HTTPS: "false"
    KC_PROXY: none
    KC_HTTP_ENABLED: "true"
    KC_HEALTH_ENABLED: "true"
    # 管理员账号
    KEYCLOAK_ADMIN: ${KEYCLOAK_ADMIN_USER}
    KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
    # 开发模式：禁用主题缓存，方便实时预览主题修改
    KC_THEME_CACHE_THEMES: "false"
    KC_THEME_STATIC_MAX_AGE: "-1"
  volumes:
    - ./services/keycloak/themes:/opt/keycloak/themes/noda:ro
  networks:
    - noda-network
  depends_on:
    postgres-dev:
      condition: service_healthy
  healthcheck:
    test: ["CMD-SHELL", "echo > /dev/tcp/localhost/9000 2>/dev/null || exit 1"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 60s
```

### 4.3 环境对比

| 维度 | 生产 Keycloak | 开发 Keycloak |
|------|-------------|-------------|
| 容器名 | keycloak（或 noda-infra-keycloak-1） | noda-infra-keycloak-dev |
| 端口 | 8080（内部）→ Cloudflare Tunnel | 8180（本地暴露） |
| 数据库 | postgres:5432/keycloak | postgres-dev:5432/keycloak_dev |
| 命令 | `start` | `start-dev` |
| 主机名 | `https://auth.noda.co.nz` | 空（localhost） |
| 代理模式 | `edge`（Cloudflare TLS） | `none`（本地直连） |
| SMTP | 已配置 | 不配置（开发不需要发邮件） |
| 主题缓存 | 默认（缓存开启） | 禁用（方便调试） |
| 资源限制 | CPU 1核 / 内存 1G | 无限制（开发用） |
| 外部访问 | Cloudflare Tunnel → auth.noda.co.nz | 仅 localhost:8180 |

### 4.4 开发环境启动命令

```bash
# 启动开发环境（包含 dev PostgreSQL + dev Keycloak）
docker compose \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.dev.yml \
  up -d postgres-dev keycloak-dev

# 查看日志
docker compose logs -f keycloak-dev

# 停止开发环境
docker compose \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.dev.yml \
  stop keycloak-dev postgres-dev
```

### 4.5 findclass-ssr 开发环境 Keycloak 指向

开发环境中 findclass-ssr 应该指向 dev Keycloak：

```yaml
# docker-compose.dev.yml 中修改 findclass-ssr
findclass-ssr:
  environment:
    KEYCLOAK_URL: http://localhost:8180
    KEYCLOAK_INTERNAL_URL: http://keycloak-dev:8080
    KEYCLOAK_REALM: noda
    KEYCLOAK_CLIENT_ID: noda-frontend
    DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres-dev:5432/noda_dev
    DIRECT_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres-dev:5432/noda_dev
```

**注意：** 开发环境的 findclass-ssr 需要：
1. 前端 URL 使用 `http://localhost:8180`（浏览器直接访问 dev Keycloak）
2. 内部 URL 使用 `http://keycloak-dev:8080`（容器间通信）
3. 数据库切换到 `postgres-dev` 的 `noda_dev`

---

## 五、数据流

### 5.1 主题渲染流程

```
用户访问 auth.noda.co.nz/login
       │
       ▼
Cloudflare Tunnel → Nginx → Keycloak:8080
       │
       ▼
Keycloak 检查 realm 设置 → Login Theme = "noda"
       │
       ▼
加载 /opt/keycloak/themes/noda/login/theme.properties
       │
       ├─ parent=keycloak → 继承基础模板和样式
       ├─ styles=css/noda.css → 加载自定义 CSS
       │
       ▼
渲染 login.ftl（如果存在用 noda 版本，否则用 keycloak 基础版本）
       │
       ▼
返回完整 HTML（基础结构 + noda.css 覆盖样式）
```

### 5.2 主题开发迭代流程（开发环境）

```
1. 编辑 docker/services/keycloak/themes/noda/login/resources/css/noda.css
2. 保存文件（宿主机）
3. 刷新浏览器 → Keycloak 重新读取卷挂载文件
   （开发环境禁用了主题缓存，立即生效）
4. 满意后 git commit 推送到生产
5. 生产环境需要重启 Keycloak 容器或等待缓存过期
   docker compose restart keycloak
```

### 5.3 双环境 OAuth 流程对比

**生产：**
```
浏览器 → class.noda.co.nz → findclass-ssr → 重定向到 auth.noda.co.nz
  → Cloudflare Tunnel → Keycloak (prod) → Google OAuth → 回调
  → findclass-ssr → 获取 token → 完成
```

**开发：**
```
浏览器 → localhost:3002 → findclass-ssr → 重定向到 localhost:8180
  → Keycloak (dev) → Google OAuth（或本地用户名密码）→ 回调
  → findclass-ssr → 获取 token → 完成
```

---

## 六、架构模式

### Pattern 1: Docker Compose Overlay 隔离

**What:** 使用同一个基础配置 + 环境特定 overlay 实现多环境隔离。

**When:** 需要 dev/staging/prod 环境共享核心配置但有环境差异时。

**Example:**

```
docker-compose.yml          → 所有环境共享的服务定义
docker-compose.prod.yml     → 生产覆盖（SMTP、资源限制、安全配置）
docker-compose.dev.yml      → 开发覆盖（新服务、端口映射、调试配置）
```

**在本项目中的应用：**
- PostgreSQL：prod（内部）+ dev（暴露 5433 端口）
- Keycloak：prod（Cloudflare Tunnel）+ dev（localhost:8180）
- 两者使用独立的数据库和容器名，完全隔离

### Pattern 2: 主题继承（Theme Inheritance）

**What:** 自定义主题通过 `parent=keycloak` 继承基础主题，只覆盖需要定制的部分。

**When:** 品牌化定制不需要修改 HTML 结构，只需 CSS 样式覆盖。

**好处：**
- 最少代码量实现品牌化
- Keycloak 版本升级时兼容性好
- 自动获得新登录流程页面
- 调试简单（对比基础主题和自定义差异）

### Pattern 3: 卷挂载共享主题

**What:** 主题文件通过 Docker 卷挂载从宿主机注入容器，prod 和 dev 共享同一套主题源码。

**When:** 主题需要在多个环境中使用，且需要通过 Git 管理版本。

```
宿主机 Git 仓库
  docker/services/keycloak/themes/login/
       │
       ├─→ keycloak (prod) :ro 卷挂载
       └─→ keycloak-dev (dev) :ro 卷挂载
```

两个环境读取同一套文件。开发环境禁用缓存方便实时预览，生产环境使用缓存保证性能。

---

## 七、反模式（需要避免）

### Anti-Pattern 1: 覆盖现有 keycloak 服务实现开发环境

**What:** 在 docker-compose.dev.yml 中直接覆盖 `keycloak` 服务的 environment 和 command。

**Why bad:**
- 无法同时运行 prod 和 dev 实例（端口冲突）
- 开发环境会连接 prod 的 PostgreSQL 数据库
- 切换环境需要重启整个服务栈
- 不符合 PostgreSQL 双环境的设计模式（独立服务）

**Instead:** 添加独立的 `keycloak-dev` 服务，与 `postgres-dev` 模式一致。

### Anti-Pattern 2: 完全重写 FreeMarker 模板

**What:** 不设置 `parent=keycloak`，从零编写所有 login 类型模板。

**Why bad:**
- Keycloak 26.x 的 login 主题有 20+ 个模板（login.ftl、login-otp.ftl、login-password.ftl、login-reset-password.ftl、register.ftl 等）
- 每次升级 Keycloak 都需要对比和合并模板变更
- 容易遗漏安全相关的隐藏字段（如 CSRF token）
- 维护成本远大于收益

**Instead:** 使用 `parent=keycloak` 继承 + CSS 覆盖。仅在有明确需求时覆盖特定模板文件。

### Anti-Pattern 3: 使用 Keycloak 自定义 SPI 或 Provider

**What:** 编写 Java 代码实现自定义 Authenticator、Required Action 等 SPI。

**Why bad:**
- 需要编译 JAR 并部署到 Keycloak 容器
- 增加构建复杂度和维护成本
- 需要理解 Keycloak SPI 接口和生命周期
- 与 Keycloak 版本强耦合

**Instead:** 对于品牌化登录页需求，纯主题（CSS + 可选 FreeMarker）足够。仅在需要自定义认证流程时才考虑 SPI。

### Anti-Pattern 4: 在容器内修改主题文件

**What:** `docker exec` 进入容器修改 `/opt/keycloak/themes/` 下的文件。

**Why bad:**
- 容器重建后修改丢失
- 无法通过 Git 追踪变更
- 当前卷挂载使用 `:ro` 模式，不允许容器内写入

**Instead:** 在宿主机编辑 `docker/services/keycloak/themes/` 下的文件，通过卷挂载自动同步到容器。

### Anti-Pattern 5: 开发环境复用生产 SMTP 配置

**What:** 在 keycloak-dev 中配置与生产相同的 SMTP 服务器。

**Why bad:**
- 开发环境可能触发真实邮件发送
- 密码重置测试邮件会发给真实用户
- 增加不必要的外部依赖

**Instead:** 开发环境不配置 SMTP。如果需要测试邮件相关功能，使用 MailHog 或 Mailpit 等本地邮件 mock 服务（可后续添加）。

---

## 八、构建顺序建议

基于依赖关系，建议按以下顺序构建：

### Step 1: 创建主题目录和最小文件

**前置条件：** 无
**内容：**
1. 创建 `docker/services/keycloak/themes/noda/login/` 目录结构
2. 编写 `theme.properties`（parent=keycloak）
3. 编写最小化 `noda.css`（颜色和 Logo 覆盖）
4. 编写消息包（loginTitle 等）

**验证：**
```bash
# 重启生产 Keycloak 加载新主题
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml restart keycloak

# 在 Admin Console 中选择 "noda" 主题
# 访问 auth.noda.co.nz 查看效果
```

**为什么先做：** 不需要修改任何 Docker Compose 配置（卷挂载已预留）。风险最低，效果立即可见。

### Step 2: 添加 keycloak-dev 服务

**前置条件：** Step 1 完成（主题文件存在）
**依赖：** postgres-dev 服务和 keycloak_dev 数据库已存在（v1.1 已完成）
**内容：**
1. 在 `docker-compose.dev.yml` 中添加 `keycloak-dev` 服务定义
2. 配置连接 `postgres-dev:5432/keycloak_dev`
3. 暴露 `8180:8080` 端口
4. 禁用主题缓存（开发模式配置）

**验证：**
```bash
# 启动开发环境
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d keycloak-dev

# 访问 http://localhost:8180 确认 Keycloak 启动
# 在 Admin Console 中选择 "noda" 主题
```

**为什么第二步：** 依赖 Step 1 的主题文件。有了开发环境后，可以更方便地迭代主题设计。

### Step 3: 主题迭代和优化

**前置条件：** Step 2 完成（开发环境可用）
**内容：**
1. 使用开发环境实时预览主题修改
2. 调整 CSS 直到满意
3. 可选：添加 Logo SVG 文件
4. 可选：覆盖特定 FreeMarker 模板（如需要）
5. 可选：添加 favicon 和其他资源

**验证：**
- 开发环境实时预览（无缓存）
- 最终在生产环境确认

### Step 4: 更新 findclass-ssr 开发配置

**前置条件：** Step 2 完成
**内容：**
1. 修改 `docker-compose.dev.yml` 中 findclass-ssr 的环境变量
2. KEYCLOAK_URL 指向 `http://localhost:8180`
3. KEYCLOAK_INTERNAL_URL 指向 `http://keycloak-dev:8080`
4. DATABASE_URL 指向 `postgres-dev:5432/noda_dev`

**验证：**
```bash
# 完整开发环境测试
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d

# 访问 localhost:3002 测试完整 OAuth 登录流程
```

---

## 九、Keycloak 版本兼容性注意事项

### Keycloak 26.x 主题系统变化

| 方面 | Keycloak < 23 | Keycloak 23-26 | 本项目影响 |
|------|--------------|----------------|-----------|
| CSS 框架 | PatternFly 3 | PatternFly 4/5 | CSS 类名与 PF4/5 对齐 |
| 模板引擎 | FreeMarker 2.x | FreeMarker 2.x | 无变化 |
| 主题 SPI | ThemeProvider | ThemeProvider | 无变化 |
| 主机名 SPI | v1（KC_HOSTNAME_PORT 等） | v2（KC_HOSTNAME 完整 URL） | 已在 v1.1 修复 |
| 管理端口 | 9990 | 9000 | 已在 compose 中配置 |

**关键点：** Keycloak 26.x 使用 PatternFly 5（`pf-v5-*` 类名前缀）。CSS 覆盖需要针对 PF5 的类名，而不是旧版本的 PF3/4 类名。

### PatternFly 5 关键 CSS 类名

```css
/* 登录页面容器 */
.pf-v5-c-login

/* 登录卡片 */
.pf-v5-c-login__main
.pf-v5-c-card

/* 标题 */
.pf-v5-c-title

/* 表单 */
.pf-v5-c-form
.pf-v5-c-form__group

/* 按钮 */
.pf-v5-c-button
.pf-v5-c-button.pf-m-primary
.pf-v5-c-button.pf-m-secondary

/* 输入框 */
.pf-v5-c-form-control

/* 社交登录按钮 */
.pf-v5-c-form__helper-text
.kc-social-grp-cookieless  /* Keycloak 特定 */
```

---

## 十、可扩展性考虑

| 关注点 | 当前（单主题） | 中等（多主题 + 多语言） | 高级（完全自定义 UI） |
|-------|--------------|---------------------|---------------------|
| 主题类型 | login | login + email + account | login + email + account + welcome |
| 模板覆盖 | 无（纯 CSS） | login.ftl + register.ftl | 全部模板 |
| 语言 | en + zh | + ja, ko 等 | 自动检测 + 翻译管理 |
| JavaScript | 无 | 自定义验证逻辑 | 完全自定义 SPA |
| Logo/图片 | CSS 背景图 | SVG 资源目录 | 动态主题切换 |
| 维护成本 | 极低（每版本 <30 分钟验证） | 低（半天验证） | 中（每次升级需要测试） |

---

## 十一、与现有系统的集成点

### 1. Docker 网络集成

```
noda-network (外部网络)
    ├── noda-infra-postgres-prod         ← 生产 Keycloak 连接
    ├── noda-infra-postgres-dev          ← 开发 Keycloak 连接（新增）
    ├── keycloak                         ← 生产 Keycloak（已有）
    ├── noda-infra-keycloak-dev          ← 开发 Keycloak（新增）
    ├── noda-infra-nginx                 ← 代理路由（无需变更）
    ├── noda-ops                         ← Cloudflare Tunnel（无需变更）
    └── findclass-ssr                    ← 应用（开发环境指向 dev Keycloak）
```

keycloak-dev 自动加入 noda-network，可以访问 postgres-dev 和被 findclass-ssr 访问。

### 2. 环境变量集成

不需要新增环境变量。现有 `.env` 文件中的 `KEYCLOAK_ADMIN_USER` 和 `KEYCLOAK_ADMIN_PASSWORD` 被 keycloak-dev 复用。

如果未来需要 dev 环境独立的 Keycloak 管理员密码，可以在 `.env` 中添加：
```
KEYCLOAK_DEV_ADMIN_USER=admin
KEYCLOAK_DEV_ADMIN_PASSWORD=dev_password
```

### 3. 备份系统集成

现有的备份系统（noda-ops）会备份 `keycloak` 数据库。需要确保：
- 生产备份只包含 `keycloak` 数据库（不包含 `keycloak_dev`）
- 开发数据库 `keycloak_dev` 不需要备份（可随时从 init 脚本重建）

当前备份配置只备份生产数据库，所以无需修改。

---

## 数据源

| 来源 | 置信度 | 用途 |
|------|--------|------|
| `docker/docker-compose.yml` | HIGH（直接读取） | 基础服务定义和主题卷挂载 |
| `docker/docker-compose.prod.yml` | HIGH（直接读取） | 生产环境 Keycloak 配置 |
| `docker/docker-compose.dev.yml` | HIGH（直接读取） | 开发环境现有配置 |
| `docker/services/postgres/init-dev/01-create-databases.sql` | HIGH（直接读取） | keycloak_dev 数据库已创建确认 |
| `config/nginx/conf.d/default.conf` | HIGH（直接读取） | Nginx 路由无需变更确认 |
| Keycloak Server Developer Guide (26.x) | HIGH（官方文档） | 主题系统架构、FreeMarker 模板、PatternFly 集成 |
| Keycloak Hostname SPI v2 文档 | HIGH（官方文档） | KC_HOSTNAME 配置确认 |
| `.planning/PROJECT.md` | HIGH（直接读取） | v1.2 里程碑目标 |

---

*Architecture research for: Noda v1.2 Keycloak 自定义主题 + 双环境*
*Researched: 2026-04-11*
