# Stack Research

**Domain:** Keycloak 自定义主题开发 + 双环境部署（dev/prod）
**Researched:** 2026-04-11
**Confidence:** HIGH

## 推荐技术栈

### 核心技术（主题开发）

| 技术 | 版本 | 用途 | 推荐理由 |
|------|------|------|----------|
| Keycloak | 26.2.3 | 认证服务 | 项目已部署，主题系统基于 FreeMarker 模板引擎，无需额外运行时依赖 |
| FreeMarker 模板 | 随 Keycloak 自带 | 登录页 HTML 模板 | Keycloak 内置引擎，`.ftl` 文件直接放置在 theme 目录即可生效 |
| CSS3 | - | 主题样式覆盖 | 通过 `theme.properties` 的 `styles` 属性加载自定义 CSS，覆盖 PatternFly 默认样式 |
| Keycloak `start-dev` 模式 | 26.2.3 | 开发环境热重载 | 禁用主题缓存，修改 CSS/模板无需重启容器 |

### 核心技术（双环境）

| 技术 | 版本 | 用途 | 推荐理由 |
|------|------|------|----------|
| Docker Compose overlay | 已有模式 | dev/prod 配置分离 | 项目已使用 base + dev/prod overlay 模式（PostgreSQL 双实例已验证），Keycloak 复用同一模式 |
| PostgreSQL 17.9 | 已部署 | dev Keycloak 数据库 | 复用 `postgres-dev` 实例，创建独立的 `keycloak_dev` 数据库 |
| Volume mount (开发) | Docker 原生 | 主题文件热重载 | 开发时将 `themes/noda` 目录挂载到容器，修改即时生效 |
| COPY + `kc.sh build` (生产) | Docker 原生 | 主题打包进镜像 | 生产环境将主题烘焙进镜像，版本化、可追溯 |

### 辅助文件/工具

| 文件/工具 | 用途 | 使用场景 |
|-----------|------|----------|
| `theme.properties` | 主题元数据配置 | 每个 theme type 必须包含，定义 parent/import/styles |
| `messages/messages_en.properties` | 国际化文本覆盖 | 修改按钮文案、提示文字 |
| `messages/messages_zh_cn.properties` | 中文翻译 | 新西兰教育场景可能有中文用户 |
| `resources/css/styles.css` | 自定义样式 | 品牌化登录页视觉 |
| `resources/img/` | Logo 和背景图 | Noda 品牌资源 |
| `footer.ftl` | 自定义页脚 | 版权信息、链接 |

## 安装

```bash
# 无需安装额外 npm/pip 包
# Keycloak 主题开发纯靠文件系统操作

# 开发环境启动（主题热重载）
docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d keycloak-dev

# 生产环境：主题通过 volume 挂载（当前方案）
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d keycloak
```

## 主题目录结构

```
services/keycloak/themes/noda/
  login/
    theme.properties          # parent=keycloak, import=common/keycloak, styles=...
    resources/
      css/
        noda-login.css        # 自定义样式（覆盖 PatternFly 变量）
      img/
        logo.svg              # Noda Logo
        bg.png                # 登录页背景（可选）
    messages/
      messages_en.properties  # 英文文本覆盖
      messages_zh_cn.properties  # 中文翻译（可选）
    footer.ftl                # 自定义页脚模板（可选）
  email/                      # 邮件主题（v1.2 范围外，但可预留）
    theme.properties
    messages/
      messages_en.properties
```

## 双环境配置方案

### 开发环境（keycloak-dev 独立容器）

复用 PostgreSQL dev 实例，创建独立 keycloak-dev 容器：

**docker-compose.dev.yml 新增内容：**
```yaml
keycloak-dev:
  image: quay.io/keycloak/keycloak:26.2.3
  container_name: noda-infra-keycloak-dev
  command: start-dev
  environment:
    KC_DB: postgres
    KC_DB_URL: jdbc:postgresql://postgres-dev:5432/keycloak_dev
    KC_DB_USERNAME: ${POSTGRES_USER}
    KC_DB_PASSWORD: ${POSTGRES_PASSWORD}
    KC_HOSTNAME: ""
    KC_HEALTH_ENABLED: "true"
    KEYCLOAK_ADMIN: ${KEYCLOAK_ADMIN_USER}
    KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
    # 开发环境专用：禁用主题缓存
    KC_SPI_THEME_STATIC_MAX_AGE: "-1"
    KC_SPI_THEME_CACHE_THEMES: "false"
    KC_SPI_THEME_CACHE_TEMPLATES: "false"
  ports:
    - "8180:8080"   # 避免与生产 Keycloak 8080 端口冲突
    - "9100:9000"   # 管理端口
  volumes:
    - ../services/keycloak/themes:/opt/keycloak/themes:ro
  networks:
    - noda-network
  depends_on:
    postgres-dev:
      condition: service_healthy
```

### 生产环境（现有 keycloak 服务增强）

**docker-compose.yml 修改：**
- 修改 volume 挂载路径：`../services/keycloak/themes:/opt/keycloak/themes:ro`
  - 当前挂载到 `/opt/keycloak/themes/noda:ro`，应改为挂载整个 themes 目录
- 保持现有 `start` 命令（生产模式，主题缓存开启）
- 已有配置无需大幅修改

**关键环境变量差异：**

| 配置项 | 开发环境 | 生产环境 |
|--------|----------|----------|
| `command` | `start-dev` | `start` |
| `KC_HOSTNAME` | `""` (空) | `"https://auth.noda.co.nz"` |
| `KC_PROXY` | 不设置 | `"edge"` |
| 主题缓存 | 全部禁用 | 默认启用 |
| 端口 | 8180:8080 | 8080:8080 |
| 数据库 | `postgres-dev:5432/keycloak_dev` | `postgres:5432/keycloak` |

## Alternatives Considered

| 推荐 | 替代方案 | 不选理由 |
|------|----------|----------|
| 纯 CSS 覆盖（extend keycloak theme） | 从 base theme 白手起家 | base theme 只有消息包，需要自己实现所有 HTML，维护成本极高 |
| Volume mount（开发） | JAR 打包（开发） | 开发阶段每次改 CSS 都要 rebuild JAR + 重启容器，效率太低 |
| 独立 keycloak-dev 容器 | 共享 keycloak 容器（overlay 覆盖配置） | 共享容器意味着开发操作（调试、重置）会影响生产数据；独立容器实现真正的环境隔离 |
| `start-dev` 命令（开发） | `start` 命令（开发） | `start-dev` 自动禁用 HTTPS 要求、主机名检查，开发体验更好；`start` 模式在本地需要额外证书配置 |
| 复用 postgres-dev 实例 | 独立 postgres 容器给 keycloak-dev | 项目已有 `postgres-dev` 实例，只需创建新数据库 `keycloak_dev`，通过 init-dev SQL 脚本自动创建 |

## What NOT to Use

| 避免 | 原因 | 用什么替代 |
|------|------|------------|
| 直接修改 Keycloak 内置主题 | 升级 Keycloak 版本时会被覆盖，维护噩梦 | 创建自定义主题 extend `keycloak` 主题 |
| React-based theme（`@keycloak/keycloak-account-ui`） | 仅适用于 Account Console 和 Admin Console 自定义，不适用于 Login 页面 | FreeMarker 模板 + CSS 覆盖 |
| keycloak-theme-tailwind 等第三方工具 | 引入不必要的构建步骤和依赖，Keycloak 原生主题系统已足够 | 原生 CSS + PatternFly 变量覆盖 |
| Keycloak Export/Import 做环境同步 | 开发环境应有独立的 realm 配置，不需要与生产同步 | 开发环境用 `init-realm.sh` 初始化 |
| `KC_HOSTNAME_PORT` | Keycloak 26 v2 SPI 已废弃此选项 | `KC_HOSTNAME` 使用完整 URL（含 scheme） |

## Stack Patterns by Variant

**如果只需要品牌化登录页（不改变布局结构）：**
- 使用 `parent=keycloak` + 自定义 CSS
- 仅修改 `theme.properties` 和 `resources/css/` 下的文件
- 零 FreeMarker 模板修改，升级最安全

**如果需要修改登录页布局或添加字段：**
- 复制 `login.ftl` 等模板到自定义主题目录
- 修改模板，添加自定义 HTML 结构
- 注意：升级 Keycloak 时需要检查模板是否有变化

**如果需要开发/生产共用同一个 Keycloak 容器：**
- 不推荐。独立容器更安全、调试更方便
- 但如果资源受限，可通过 `KC_SPI_THEME_*` 环境变量在 overlay 中区分缓存策略

## Version Compatibility

| 组件 | 版本 | 兼容性说明 |
|------|------|------------|
| Keycloak 26.2.3 + FreeMarker | 随 Keycloak 自带 | 无版本冲突 |
| Keycloak 26.2.3 + PostgreSQL 17.9 | 已验证 | 生产环境已运行正常 |
| Keycloak 26.2.3 + `start-dev` | 官方支持 | Quarkus 分发版原生支持 |
| 主题 volume mount | Docker 原生 | `:ro` 挂载确保容器不会修改宿主机文件 |

## Sources

- Keycloak 26.2.3 Server Developer Guide -- Themes 章节（官方文档，HIGH confidence）
  - 主题类型、创建流程、theme.properties 配置、CSS/JS/图片添加方式、部署方法
  - URL: https://www.keycloak.org/docs/26.2.3/server_development/#_themes
- Keycloak 26.2.3 v2 Hostname SPI（项目 CLAUDE.md 记录的修复经验，HIGH confidence）
  - `KC_HOSTNAME` 使用完整 URL，`KC_HOSTNAME_PORT` 已废弃
- Docker Compose overlay 模式（项目已验证模式，HIGH confidence）
  - PostgreSQL dev/prod 双实例已稳定运行
- 现有项目配置文件（docker-compose.yml / docker-compose.dev.yml / docker-compose.prod.yml）

---
*Stack research for: Keycloak 自定义主题 + 双环境部署*
*Researched: 2026-04-11*
