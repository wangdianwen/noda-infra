# Phase 13: Keycloak 自定义主题 - Context

**Gathered:** 2026-04-11
**Status:** Ready for planning

<domain>
## Phase Boundary

为生产环境 Keycloak 登录页创建 Noda 品牌主题，CSS 覆盖实现自定义样式。两个需求交付：

1. **THEME-01:** 品牌化登录页 — CSS 覆盖实现 Noda 品牌风格（颜色、按钮风格）
2. **THEME-02:** 自定义 Logo — 替换默认 Keycloak Logo

不涉及：FreeMarker 模板修改、register/email/account 主题、中文消息包（Future 需求 THEME-03/04/05）。

</domain>

<decisions>
## Implementation Decisions

### 品牌设计元素
- **D-01:** 使用 noda-apps 设计系统的品牌色 — 主色 Pounamu Green `#0D9B6A`，次色 Ocean Blue `#005DBB`，强调色 Kowhai Gold `#D4A017`
- **D-02:** 文字色使用 Slate 900 `#0f172a`，边框色使用 Slate 200 `#e2e8f0`，背景色 `#ffffff`
- **D-03:** 圆角使用设计系统标准 `0.5rem`
- **D-04:** 保留 Keycloak 默认 Logo — Noda 尚无独立品牌 Logo，不使用占位符

### CSS 覆盖深度
- **D-05:** 最小覆盖策略 — 仅修改颜色变量和关键样式属性，保留 Keycloak 默认布局、间距和组件结构

### 模板定制策略
- **D-06:** 纯 CSS 覆盖 — 不修改 FreeMarker .ftl 模板文件，仅通过 styles.css 覆盖默认样式。优势：Keycloak 版本升级时零模板冲突风险

### 主题覆盖范围
- **D-07:** 仅覆盖 login 主题类型 — 不创建 register、email、account 等主题类型

### Claude's Discretion
- 具体需要覆盖哪些 CSS 选择器（按钮、链接、输入框焦点色等）
- 是否需要覆盖 Keycloak CSS 变量（`--pf-*`）还是直接覆盖属性
- styles.css 的组织方式和注释风格

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 设计系统
- `~/Project/noda-apps/packages/design-tokens/tokens/primitive/colors.json` — Noda 品牌色原始定义（Pounamu Green、Ocean Blue、Kowhai Gold）
- `~/Project/noda-apps/packages/design-tokens/tokens/semantic/light.json` — 语义色映射（primary=绿、accent=金、border=slate-200）
- `~/Project/noda-apps/packages/design-tokens/tokens/primitive/radii.json` — 圆角标准（lg=0.5rem）

### 现有主题文件
- `docker/services/keycloak/themes/noda/login/theme.properties` — 主题定义（parent=keycloak, import=common/keycloak）
- `docker/services/keycloak/themes/noda/login/resources/css/styles.css` — 空 CSS 文件（待填充）

### Docker Compose 配置
- `docker/docker-compose.yml` — 生产 Keycloak 服务定义（themes 只读挂载 `./services/keycloak/themes:/opt/keycloak/themes/noda:ro`）
- `docker/docker-compose.dev.yml` — 开发环境 keycloak-dev 定义（themes 读写挂载 `./services/keycloak/themes:/opt/keycloak/themes`）

### 前置 Phase 上下文
- `.planning/phases/12-keycloak/12-CONTEXT.md` — 双环境决策，包含主题挂载和热重载机制

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **主题骨架:** Phase 12 已创建 `themes/noda/login/` 目录结构（theme.properties + 空 styles.css）
- **keycloak-dev 热重载:** 开发环境使用 start-dev 模式 + 读写挂载，修改 CSS 后刷新浏览器即可看到变化
- **设计系统色值:** noda-apps 中有完整的 design tokens，可直接引用色值

### Established Patterns
- **Keycloak v1 FreeMarker 主题:** 继承 `keycloak` 基础主题，通过 CSS 覆盖自定义样式
- **Docker Compose overlay:** prod 只读挂载 vs dev 读写挂载
- **VirtioFS 兼容:** Docker Desktop 下挂载 themes 父目录（非子目录）

### Integration Points
- 生产环境：`auth.noda.co.nz` → Cloudflare Tunnel → keycloak:8080 → 加载 noda 主题
- 开发环境：`localhost:18080` → keycloak-dev:8080 → 加载 noda 主题（热重载）
- 主题需要在 Keycloak Admin Console 中设置为 noda realm 的默认主题

</code_context>

<specifics>
## Specific Ideas

- Keycloak 26.x 登录页使用的 CSS 变量主要是 `--pf-*` 系列（PatternFly），通过覆盖这些变量可以最小化 CSS 代码量
- 主要需要修改的颜色：主按钮背景、链接色、输入框焦点环色、页面标题色
- 主题激活方式：Admin Console → Realm Settings → Themes → Login Theme 选择 `noda`

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---
*Phase: 13-keycloak*
*Context gathered: 2026-04-11*
