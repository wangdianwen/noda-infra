# Pitfalls Research

**Domain:** Keycloak 双环境部署 + 自定义主题（Docker Compose 基础设施）
**Researched:** 2026-04-11
**Confidence:** HIGH（官方文档验证）/ MEDIUM（社区实践）

---

## Critical Pitfalls

### Pitfall 1: Keycloak 主题缓存 -- 修改了文件但页面不变

**What goes wrong:**
开发自定义主题时，修改了 FreeMarker 模板（`.ftl`）或 CSS 文件，刷新浏览器后页面完全没有变化。反复确认文件内容已更新，怀疑修改错了文件或路径不对。实际上 Keycloak 26.x（Quarkus）默认启用主题缓存，静态资源缓存时间为 30 天（`spi-theme-static-max-age=2592000`），模板和主题本身也被缓存在内存中。

**Why it happens:**
Keycloak 出于性能考虑，会将主题资源（模板、CSS、JS、图片）缓存到内存和磁盘（`data/tmp/kc-gzip-cache` 目录）。即使底层文件已修改，缓存中的旧版本仍然被使用。更隐蔽的是，浏览器本身也会缓存这些静态资源。双重缓存（Keycloak + 浏览器）导致开发者误以为修改没有生效。

**How to avoid:**
- **开发环境**：在 Keycloak 启动命令中添加缓存禁用参数：
  ```
  --spi-theme-static-max-age=-1
  --spi-theme-cache-themes=false
  --spi-theme-cache-templates=false
  ```
- **生产环境**：保持默认缓存启用，修改主题后需要重启 Keycloak 容器
- **浏览器**：开发时使用 Ctrl+Shift+R 强制刷新，或在 DevTools 中禁用缓存
- **验证方法**：在模板中添加时间戳注释 `<!-- rendered at ${.now?string.iso} -->`，确认加载的是最新版本

**Warning signs:**
- 修改 `.ftl` 文件后页面不变
- 修改 CSS 后样式不变
- 删除整个主题目录后登录页仍然正常显示（说明用的是缓存）

**Phase to address:**
Phase 2（自定义主题开发）-- 开发环境启动参数必须在主题开发开始前配置好

---

### Pitfall 2: Dev/Prod Keycloak 共享数据库 -- 数据互相污染

**What goes wrong:**
当前 `docker-compose.yml` 中 Keycloak 的数据库配置为 `KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak`。`docker-compose.dev.yml` 覆盖了 `KC_HOSTNAME` 和 `KC_PROXY`，但**没有覆盖 `KC_DB_URL`**。这意味着开发环境和生产环境共用同一个 PostgreSQL `keycloak` 数据库。

如果同时运行 `docker compose -f base -f dev up` 和 `docker compose -f base -f prod up`（或 docker-compose.app.yml），两个 Keycloak 实例会连接同一个数据库，导致：
- Realm 配置互相覆盖
- 用户数据不一致
- 会话冲突
- Schema 迁移竞争（Keycloak 启动时可能执行数据库迁移）

**Why it happens:**
Docker Compose overlay 模式中，`dev.yml` 只覆盖了与生产不同的环境变量，但数据库连接字符串没有被认为是"需要覆盖"的项。开发者通常认为 dev overlay 已经处理了所有差异，不会逐一检查每个环境变量。

**How to avoid:**
- 为 dev Keycloak 创建独立的数据库（如 `keycloak_dev`）
- 在 `docker-compose.dev.yml` 中覆盖 `KC_DB_URL`：
  ```yaml
  keycloak:
    environment:
      KC_DB_URL: jdbc:postgresql://postgres-dev:5432/keycloak_dev
  ```
- 或者使用独立的 PostgreSQL 容器（复用现有的 `postgres-dev` 实例）
- 在 PostgreSQL init 脚本中为 dev 环境创建 `keycloak_dev` 数据库
- 确保 dev 和 prod 的 Keycloak 数据完全隔离

**Warning signs:**
- dev 环境修改了 realm 配置后，prod 环境也被改变
- 同时启动两个环境时 Keycloak 启动失败（数据库锁冲突）
- dev 环境中看到了生产用户数据

**Phase to address:**
Phase 1（双环境搭建）-- 必须在启动第二个 Keycloak 实例前解决

---

### Pitfall 3: 端口冲突 -- Dev 和 Prod Keycloak 无法同时运行

**What goes wrong:**
`docker-compose.prod.yml` 和 `docker-compose.dev.yml` 都暴露了相同的端口：
- 8080:8080（HTTP）
- 8443:8443（HTTPS）
- 9000:9000（管理端口）

如果需要同时运行 dev 和 prod 环境（例如调试生产问题同时开发新功能），第二个启动的 Keycloak 实例会因端口占用而失败。Docker Compose 不会给出友好的错误信息，只显示 "port is already allocated"。

**Why it happens:**
端口映射在 Docker 层面是全局资源，不属于 Compose 项目隔离范围。即使使用不同的 Compose 文件（dev vs prod），同一主机上的端口只能绑定一次。`docker-compose.dev.yml` 复制了 `docker-compose.prod.yml` 的端口配置，没有做偏移。

**How to avoid:**
- dev 环境使用不同的端口映射：
  ```yaml
  keycloak:
    ports:
      - "18080:8080"   # 开发环境 HTTP
      - "18443:8443"   # 开发环境 HTTPS
      - "19000:9000"   # 开发环境管理端口
  ```
- 确保所有 dev 环境端口与 prod 端口有明确的偏移规则
- 在 Nginx 配置中为 dev 环境的 Keycloak 添加路由（如果需要通过域名访问）
- 文档中明确记录端口分配规则

**Warning signs:**
- 启动第二个 Compose 项目时报 "port is already allocated"
- Keycloak 容器状态为 Restarting
- 无法同时运行 dev 和 prod 环境

**Phase to address:**
Phase 1（双环境搭建）-- 端口规划必须在配置文件编写时完成

---

### Pitfall 4: 主题已部署但未生效 -- Admin Console 中未选择

**What goes wrong:**
按照 Keycloak 文档创建了主题目录结构、编写了 `theme.properties`、将文件放在正确路径（`themes/noda/login/`），重启了容器，但登录页面仍然显示默认的 Keycloak 主题。没有任何错误日志，主题文件看似正确。

**Why it happens:**
Keycloak 的主题不会自动应用。创建主题文件只是第一步，还需要在 Admin Console 中手动选择：
1. 进入 Admin Console -> Realm Settings -> Themes 标签页
2. 将 "Login Theme" 从 "keycloak" 改为 "noda"
3. 保存

如果使用 `init-realm.sh` 或 realm JSON 导入来初始化，需要在 JSON 配置中添加 `loginTheme: "noda"` 字段。当前 `noda-realm.json` 中没有 `loginTheme` 字段，`init-realm.sh` 也没有设置主题。

**How to avoid:**
- 在 `noda-realm.json` 中添加主题配置：
  ```json
  {
    "realm": "noda",
    "loginTheme": "noda",
    "accountTheme": "noda",
    "emailTheme": "noda",
    ...
  }
  ```
- 或在 `init-realm.sh` 中通过 kcadm.sh 设置：
  ```bash
  /opt/keycloak/bin/kcadm.sh update realms/noda -s loginTheme=noda
  ```
- 在部署验证步骤中明确检查主题是否生效（访问登录页，检查页面源码中的自定义标识）

**Warning signs:**
- 主题文件存在于正确路径，但登录页不变
- Admin Console 中 Login Theme 仍为 "keycloak"
- `noda-realm.json` 中没有 `loginTheme` 字段

**Phase to address:**
Phase 2（自定义主题开发）-- 主题选择逻辑必须与主题文件一起交付

---

### Pitfall 5: theme.properties 继承配置错误 -- 主题加载失败或样式缺失

**What goes wrong:**
自定义主题的 `theme.properties` 配置不正确，导致以下问题之一：
- `parent=keycloak.v2` 但想修改的模板在 `keycloak`（v1）中
- `parent=base` 但缺少基础样式，登录页裸露无样式
- `import=common/keycloak` 写错路径，导致公共资源无法加载
- Keycloak 26.x 的 login 主题默认 parent 是 `keycloak.v2`（React-based），不是旧的 `keycloak`

更具体的陷阱：如果使用 `parent=keycloak.v2`，自定义 `.ftl` 模板不会生效，因为 v2 login 主题使用 React 组件渲染，不使用 FreeMarker。只有使用 `parent=keycloak`（v1 主题）才能通过 `.ftl` 模板自定义登录页。

**Why it happens:**
Keycloak 26.x 引入了基于 React 的新 login 主题（`keycloak.v2`），与传统的 FreeMarker 模板主题（`keycloak`）是两套不同的系统。开发者搜索到的教程大多是旧版 FreeMarker 方式，但新版本默认使用 React 方式。两套系统的模板文件结构、自定义方式完全不同。

FreeMarker（v1）方式：修改 `.ftl` 模板文件
React（v2）方式：通过 `messages/` 目录和 CSS 变量自定义，不能直接修改模板

**How to avoid:**
- **如果要完全自定义 HTML 结构**：使用 `parent=keycloak`（v1），编写 `.ftl` 模板
- **如果只改颜色/Logo/文案**：使用 `parent=keycloak.v2`（v2），通过 CSS 变量和 `messages/*.properties` 自定义
- 在 `theme.properties` 中明确指定 `parent`：
  ```properties
  # v1 方式（完全控制 HTML）
  parent=keycloak
  import=common/keycloak

  # v2 方式（仅样式定制）
  parent=keycloak.v2
  ```
- 不要混用 v1 的 `.ftl` 模板和 v2 的 React 组件

**Warning signs:**
- 设置了 `parent=keycloak.v2` 但修改 `.ftl` 文件无效
- 登录页样式缺失（白屏或无样式文本）
- Keycloak 日志中出现 theme not found 错误
- 修改了 `login/theme.properties` 但没有任何变化

**Phase to address:**
Phase 2（自定义主题开发）-- 在编写任何主题代码前，必须确定使用 v1 还是 v2 方式

---

### Pitfall 6: Hostname v2 SPI 配置错误导致 Cookie/Session 失效

**What goes wrong:**
Keycloak 26.x 使用 Hostname v2 SPI，配置规则比 v1 严格很多。以下错误配置会导致登录后 cookie 无法设置、session 失效、重定向循环：

- `KC_HOSTNAME` 包含端口号（如 `https://auth.noda.co.nz:8080`）-- v2 会从 scheme 自动推导端口，显式写端口会导致 cookie domain 不匹配
- `KC_HOSTNAME_STRICT=true` 但通过 IP 或 localhost 访问 -- 请求的 hostname 与配置不匹配，请求被拒绝
- 同时设置 `KC_HOSTNAME` 和已废弃的 `KC_HOSTNAME_PORT` -- 冲突导致不可预测行为
- Dev 环境忘记设置 `KC_HOSTNAME_STRICT=false` -- localhost 访问被拒绝

**Why it happens:**
v1 Hostname SPI 中 `KC_HOSTNAME_PORT` 和 `KC_HOSTNAME_STRICT_HTTPS` 是常用选项。升级到 v2 后，这些选项被废弃但仍然存在于很多教程和配置示例中。v2 的 `KC_HOSTNAME` 接受完整 URL（包含 scheme），端口自动从 scheme 推导（https=443, http=80），不需要也不应该单独设置端口。

当前项目已经在 v1.1 中修复过这个问题（Google 登录 8080 端口问题的第 4 层），但添加 dev 环境时容易重新引入错误配置。

**How to avoid:**
- **生产环境**：
  ```yaml
  KC_HOSTNAME: "https://auth.noda.co.nz"  # 完整 URL，不含端口
  KC_HOSTNAME_STRICT: "false"              # 允许内部网络访问
  KC_PROXY: "edge"                         # Cloudflare Tunnel TLS 终止
  KC_PROXY_HEADERS: "xforwarded"           # 读取 X-Forwarded 头
  ```
- **开发环境**：
  ```yaml
  KC_HOSTNAME: ""                          # 空 = 允许任何 hostname
  KC_HOSTNAME_STRICT: "false"
  KC_HOSTNAME_STRICT_HTTPS: "false"
  KC_PROXY: none                           # 不使用代理
  ```
- **绝对不要使用**：`KC_HOSTNAME_PORT`、`KC_HOSTNAME_STRICT_HTTPS`（v1 废弃选项）
- **验证方法**：登录后检查浏览器 DevTools -> Application -> Cookies，确认 cookie domain 正确

**Warning signs:**
- 登录后立即被重定向回登录页（cookie 未设置）
- 浏览器地址栏显示 `auth.noda.co.nz:8080`（端口泄露）
- Keycloak 日志显示 hostname mismatch 错误
- Cookie domain 包含端口号

**Phase to address:**
Phase 1（双环境搭建）-- Hostname 配置必须在第一个 Keycloak 实例启动前正确设置

---

### Pitfall 7: Docker Volume 只读挂载导致主题无法热更新

**What goes wrong:**
`docker-compose.yml` 中 Keycloak 的主题挂载使用了 `:ro`（只读）标志：
```yaml
volumes:
  - ./services/keycloak/themes:/opt/keycloak/themes/noda:ro
```

这意味着容器内无法写入主题目录。虽然这本身不是问题（主题文件由宿主机管理），但会导致以下混淆：

1. 开发者尝试在容器内调试主题（如 `docker exec` 进入容器修改文件），修改被拒绝
2. 宿主机修改文件后，由于 Keycloak 缓存（见 Pitfall 1），需要重启容器才能生效
3. 路径映射 `themes/noda` 是容器内的主题名称，但宿主机路径 `services/keycloak/themes` 可能与开发者预期的目录结构不一致

更关键的问题是：**宿主机的 `services/keycloak/themes/` 目录目前不存在**。Keycloak 启动时不会报错（目录不存在时 Docker 静默跳过挂载），但主题自然也不会加载。

**Why it happens:**
Docker 的 bind mount 对不存在的源目录处理方式是：如果是文件则报错，如果是目录则自动创建一个空目录。但这个空目录会被标记为 owned by root，可能导致权限问题。同时，`:ro` 标志防止了容器内任何写入操作。

**How to avoid:**
- **开发环境**：移除 `:ro` 标志，允许容器写入（方便调试）：
  ```yaml
  volumes:
    - ./services/keycloak/themes:/opt/keycloak/themes/noda
  ```
- **生产环境**：保持 `:ro`（安全最佳实践）
- 在项目初始化脚本中创建主题目录：
  ```bash
  mkdir -p services/keycloak/themes/noda/login
  mkdir -p services/keycloak/themes/noda/login/resources/css
  mkdir -p services/keycloak/themes/noda/login/resources/img
  ```
- 修改主题后重启容器（生产）或禁用缓存（开发，见 Pitfall 1）

**Warning signs:**
- `docker exec` 修改文件失败（read-only file system）
- Keycloak Admin Console 主题列表中没有 "noda" 选项
- `ls services/keycloak/themes/` 显示目录不存在或为空

**Phase to address:**
Phase 2（自定义主题开发）-- 目录创建和挂载配置必须在主题开发开始前完成

---

### Pitfall 8: CSP 策略阻止自定义 JavaScript

**What goes wrong:**
在自定义登录主题中添加了 JavaScript（如自定义验证逻辑、第三方分析脚本），但脚本不执行。浏览器控制台显示 Content Security Policy (CSP) 违规错误：
```
Refused to execute inline script because it violates the following Content Security Policy directive: "script-src ..."
```

Keycloak 默认的 CSP 策略非常严格，不允许内联脚本、eval、以及非白名单域名的脚本加载。

**Why it happens:**
Keycloak 的安全策略默认禁止内联脚本（防止 XSS）。自定义主题中的 `<script>` 标签如果不是通过外部文件引入，或者没有在 CSP 中添加对应域名，会被浏览器阻止。

**How to avoid:**
- 将所有 JavaScript 放在外部 `.js` 文件中（`resources/js/` 目录），不要使用内联脚本
- 在 `theme.properties` 中添加 CSP 白名单（如果需要加载外部脚本）：
  ```properties
  scripts=script.js
  ```
- 避免在主题中使用 `eval()`、`new Function()` 等不安全操作
- 如果确实需要修改 CSP 策略，通过 Keycloak SPI 或 realm 属性设置（不推荐）
- 尽量用纯 CSS 实现视觉效果，减少 JavaScript 依赖

**Warning signs:**
- 浏览器控制台出现 CSP 违规错误
- 自定义 JavaScript 功能不工作
- 第三方脚本加载失败

**Phase to address:**
Phase 2（自定义主题开发）-- 如果主题需要 JavaScript，必须使用外部文件方式

---

### Pitfall 9: Google OAuth 回调 URL 在 Dev 环境不匹配

**What goes wrong:**
在开发环境中启动 Keycloak 后，Google OAuth 登录失败，显示 "redirect_uri_mismatch" 错误。这是因为 Google OAuth 的 Authorized Redirect URIs 配置了 `https://auth.noda.co.nz/realms/noda/protocol/openid-connect/auth`，但开发环境使用 `http://localhost:8080`，域名和协议都不匹配。

**Why it happens:**
Google OAuth 的回调 URL 必须精确匹配（包括协议、域名、端口、路径）。开发环境使用 localhost + HTTP，与生产环境的自定义域名 + HTTPS 完全不同。当前 `init-realm.sh` 中 Google OAuth 配置使用环境变量，但没有区分 dev/prod 环境。

**How to avoid:**
- 在 Google Cloud Console 中为 OAuth Client 添加多个 Authorized Redirect URIs：
  - 生产：`https://auth.noda.co.nz/realms/nada/protocol/openid-connect/auth`
  - 开发：`http://localhost:8080/realms/noda/protocol/openid-connect/auth`
  - 以及对应的 JavaScript origins
- 在 `docker-compose.dev.yml` 中覆盖 Google OAuth 环境变量（如果使用不同的 Client）
- 或者开发环境跳过 Google OAuth，使用用户名/密码登录

**Warning signs:**
- 开发环境 Google 登录报 redirect_uri_mismatch
- Google OAuth 登录页显示的回调 URL 与实际不符
- 生产环境正常但开发环境 Google 登录失败

**Phase to address:**
Phase 1（双环境搭建）-- Dev 环境的 Google OAuth 配置必须与 prod 分开处理

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Dev/Prod Keycloak 共用数据库 | 少维护一个数据库，配置简单 | 数据互相污染，realm 配置冲突，无法安全测试 | 永远不可接受 |
| 使用默认 keycloak 主题（不自定义） | 零开发成本 | 品牌识别度低，用户信任度差 | 仅在 MVP 阶段 |
| 主题开发不创建 dev 禁用缓存参数 | 配置简单 | 每次修改需重启容器，开发效率极低 | 仅生产环境可以接受 |
| 不为 dev 环境配置独立 Google OAuth | 省一个 OAuth Client 配置 | Dev 环境无法测试 Google 登录 | 可以暂时接受（用密码登录替代） |
| 使用 v1 FreeMarker 主题（而非 v2 React） | 教程多，自由度高 | 未来 Keycloak 版本可能弃用 v1 | 当前推荐（v1 仍然支持） |
| 主题文件不打包为 JAR | 简单直接，目录挂载即可 | 升级 Keycloak 版本时可能丢失自定义配置 | 仅在单节点部署时可以接受 |
| 复制整个 keycloak 主题再修改 | 快速看到效果 | 升级时无法继承上游修复，维护负担大 | 永远不可接受 -- 应使用 parent 继承 |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Keycloak + PostgreSQL | Dev 和 Prod 连接同一个数据库 | 为 dev Keycloak 创建独立的 `keycloak_dev` 数据库 |
| Keycloak + Cloudflare Tunnel | 忘记设置 `KC_PROXY: edge` | 必须设置 `edge` + `KC_PROXY_HEADERS: xforwarded` + `KC_HTTP_ENABLED: true` |
| Keycloak + Nginx | Nginx 代理 `/auth/` 到 Keycloak，覆盖了应用的 `/auth/callback` | 分域名路由：`auth.noda.co.nz` -> keycloak，`class.noda.co.nz` -> app（当前已修复） |
| Keycloak + Google OAuth | Dev 环境用 prod 域名回调 | Google Console 中添加 localhost 回调 URL，或 dev 环境跳过 Google OAuth |
| Keycloak + Docker Network | 使用 `localhost` 连接其他服务 | 使用 Docker 服务名（如 `postgres:5432`）连接同网络内的服务 |
| 主题 + Docker Volume | 主题目录不存在时 Docker 静默创建空目录 | 在启动前 `mkdir -p` 创建完整的目录结构 |
| 主题 + 浏览器缓存 | 修改主题后浏览器显示旧版本 | 开发时 DevTools 禁用缓存；生产环境修改后重启容器 |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Keycloak 主题缓存导致每次修改需重启 | 开发主题时效率极低 | Dev 环境添加 `--spi-theme-cache-themes=false` | 开发阶段 |
| 主题包含大量未优化图片 | 登录页加载慢 | 压缩图片，使用 WebP，控制总大小 < 200KB | 图片 > 500KB |
| 过多自定义 CSS/JS 资源 | 登录页渲染延迟 | 合并压缩资源文件，总 CSS < 50KB | 文件数 > 5 |
| Dev 环境禁用缓存导致 Keycloak CPU 增高 | 容器资源使用率上升 | 仅在开发环境禁用；生产保持默认 | 并发用户 > 100 时 |
| 两个 Keycloak 实例争抢 PostgreSQL 连接 | 数据库连接池耗尽 | 为每个实例配置独立的连接池和数据库 | 同时运行 dev + prod |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Dev Keycloak 暴露相同端口且无认证保护 | 本地开发时攻击者可访问管理控制台 | Dev 环境使用非标准端口；设置 admin 密码；仅绑定 localhost |
| 主题中的 XSS 漏洞 | 用户凭证被盗 | 使用 FreeMarker 的 `?no_esc` 要谨慎；避免内联脚本；遵循 CSP 策略 |
| Dev 环境使用 HTTP 传输敏感数据 | 本地网络嗅探可获取密码和 token | Dev 环境仅用于测试，不使用真实用户数据 |
| 主题中硬编码 Client Secret | Secret 泄露到前端代码 | 主题文件不应包含任何敏感配置；Secret 通过环境变量或 Admin Console 配置 |
| `init-realm.sh` 中 `secret=YOUR_CLIENT_SECRET_HERE` 占位符未替换 | Client Secret 为已知默认值 | 使用环境变量 `${CLIENT_SECRET}` 或通过 Admin Console 手动配置 |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| 主题只改了颜色没改文案 | 用户仍然觉得是 "Keycloak" 而不是 "Noda" | 同时修改 `messages/*.properties` 中的所有面向用户的文案 |
| 登录页没有 Noda 品牌 Logo | 用户不信任登录页面（看起来像第三方） | 添加 Noda Logo 和品牌标识 |
| 忘记处理移动端适配 | 手机上登录页布局错乱 | 使用响应式 CSS，测试主流移动设备 |
| 自定义主题不支持暗色模式 | 强光环境下可读性差 | 跟随系统 `prefers-color-scheme` 或提供手动切换 |
| 错误提示使用 Keycloak 默认英文 | 中文用户不理解错误含义 | 在 `messages_zh_CN.properties` 中提供中文翻译 |

## "Looks Done But Isn't" Checklist

- [ ] **主题文件部署:** 常缺失 Admin Console 中的主题选择 -- 验证 Realm Settings -> Themes -> Login Theme 设为 "noda"
- [ ] **主题继承:** 常缺失 `parent=keycloak` 导致样式全丢 -- 验证 `theme.properties` 中 parent 配置正确
- [ ] **Dev 环境数据库隔离:** 常缺失 dev Keycloak 的独立数据库 -- 验证 `KC_DB_URL` 在 dev overlay 中被覆盖
- [ ] **Dev 环境端口偏移:** 常缺失 dev 环境的端口映射修改 -- 验证 dev 和 prod 可以同时启动
- [ ] **主题目录结构:** 常缺失完整的目录层级 -- 验证 `themes/noda/login/theme.properties` 和 `themes/noda/login/login.ftl` 存在
- [ ] **Google OAuth Dev 回调:** 常缺失 localhost 回调 URL -- 验证 Google Console 包含开发环境回调地址
- [ ] **Hostname v2 配置:** 常混入 v1 废弃选项 -- 验证没有 `KC_HOSTNAME_PORT` 或 `KC_HOSTNAME_STRICT_HTTPS`
- [ ] **本地化消息:** 常缺失中文消息文件 -- 验证 `messages_zh_CN.properties` 包含所有自定义文案
- [ ] **Favicon 和页面标题:** 常缺失自定义 favicon 和标题 -- 验证登录页标签显示 Noda 而非 Keycloak
- [ ] **主题资源文件:** 常缺失 `resources/` 目录中的 CSS/图片 -- 验证自定义样式和 Logo 文件存在

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| 主题缓存导致修改不生效 | LOW | 重启 Keycloak 容器；或添加缓存禁用参数后重启 |
| Dev/Prod 共享数据库导致数据污染 | HIGH | 从最近的 prod 备份恢复；清理 dev 环境写入的冲突数据；重建 dev 数据库 |
| 端口冲突无法启动 | LOW | 修改 dev 环境的端口映射，重新启动 |
| Hostname v2 配置错误导致登录循环 | MEDIUM | 停止容器；修改环境变量；清除浏览器 Cookie；重启容器 |
| 主题继承配置错误（白屏） | LOW | 修改 `theme.properties` 的 parent；重启容器 |
| CSP 阻止自定义 JS | LOW | 将内联脚本移到外部文件；更新 `theme.properties` 的 scripts 配置 |
| Google OAuth dev 回调不匹配 | LOW | 在 Google Console 添加 localhost 回调 URL（需等待 5 分钟生效） |
| Volume 目录不存在 | LOW | 创建目录结构；重启容器 |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 主题缓存 | Phase 2（主题开发） | Dev 环境启动参数包含缓存禁用参数；修改文件后刷新可见 |
| Dev/Prod 数据库共享 | Phase 1（双环境搭建） | Dev KC_DB_URL 指向 keycloak_dev；prod 指向 keycloak |
| 端口冲突 | Phase 1（双环境搭建） | Dev 和 prod Keycloak 可以同时启动无端口冲突 |
| 主题未在 Admin Console 选择 | Phase 2（主题开发） | noda-realm.json 包含 loginTheme 字段；或 init-realm.sh 设置主题 |
| theme.properties 继承错误 | Phase 2（主题开发） | 登录页正确显示自定义样式和内容 |
| Hostname v2 配置错误 | Phase 1（双环境搭建） | 登录后 Cookie domain 正确；无重定向循环 |
| Volume 只读挂载 | Phase 2（主题开发） | themes/noda/ 目录存在且有完整文件结构 |
| CSP 阻止 JS | Phase 2（主题开发） | 浏览器控制台无 CSP 违规；自定义 JS 正常执行 |
| Google OAuth dev 回调 | Phase 1（双环境搭建） | Dev 环境 Google 登录正常工作或明确跳过 |

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Keycloak Dev 环境配置 | 数据库共享 + 端口冲突 + Hostname 配置 | 先规划端口和数据库，再写配置文件 |
| 自定义主题开发 | 缓存问题 + v1/v2 选择 + 继承配置 | 先确定技术路线（v1 vs v2），再开始编码 |
| 主题部署 | Admin Console 未选择 + 目录不存在 | 部署后验证清单：目录存在 -> Admin 选择 -> 浏览器验证 |
| Dev 环境测试 | Google OAuth 回调不匹配 | 提前在 Google Console 配置 localhost 回调 |

## Sources

- Keycloak 26.2.3 Server Developer Guide -- Themes（https://www.keycloak.org/docs/26.2/server_development/#themes）-- 主题类型、theme.properties、继承、缓存控制
- Keycloak 26.2.3 Server Administration Guide -- Hostname v2（https://www.keycloak.org/docs/26.2/server_admin/#hostname）-- v2 SPI 配置、废弃选项、验证规则
- Keycloak 26.2.3 Server Administration Guide -- Reverse Proxy（https://www.keycloak.org/docs/26.2/server_admin/#reverse-proxy）-- proxy 模式、edge TLS 终止、proxy-headers
- Noda 项目 CLAUDE.md -- Google 登录 8080 端口 5 层修复记录（已验证 Hostname v2 配置）
- Noda 项目 docker-compose.yml / docker-compose.dev.yml / docker-compose.prod.yml -- 当前配置分析
- Noda 项目 services/keycloak/ -- init-realm.sh、noda-realm.json 现状分析

---
*Pitfalls research for: Keycloak 双环境部署 + 自定义主题开发*
*Researched: 2026-04-11*
