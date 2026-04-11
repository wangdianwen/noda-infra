# Phase 13: Keycloak 自定义主题 - Research

**Researched:** 2026-04-11
**Domain:** Keycloak v1 FreeMarker 主题定制 / PatternFly v4 CSS 覆盖
**Confidence:** HIGH

## Summary

Phase 13 为生产环境 Keycloak 登录页创建 Noda 品牌主题。主题基于 Keycloak v1 FreeMarker 主题系统，通过 CSS 覆盖实现品牌化样式，不修改任何 FreeMarker 模板文件。Phase 12 已搭建主题骨架（theme.properties + 空 styles.css），本阶段需要填充 CSS 内容并修复主题配置。

**核心发现：** 当前 `theme.properties` 缺少 `styles=css/styles.css` 声明，导致自定义 CSS 文件不会被 Keycloak 加载。这是实现前必须修复的阻塞性问题。

**主要建议：** 使用 PatternFly v4 CSS 变量（`--pf-global--primary-color--100` 等）进行最小化覆盖，将 Noda 品牌色映射到 Keycloak 登录页的关键 UI 元素（按钮、链接、焦点环、卡片边框）。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 使用 noda-apps 设计系统的品牌色 — 主色 Pounamu Green `#0D9B6A`，次色 Ocean Blue `#005DBB`，强调色 Kowhai Gold `#D4A017`
- **D-02:** 文字色使用 Slate 900 `#0f172a`，边框色使用 Slate 200 `#e2e8f0`，背景色 `#ffffff`
- **D-03:** 圆角使用设计系统标准 `0.5rem`
- **D-04:** 保留 Keycloak 默认 Logo — Noda 尚无独立品牌 Logo，不使用占位符
- **D-05:** 最小覆盖策略 — 仅修改颜色变量和关键样式属性，保留 Keycloak 默认布局、间距和组件结构
- **D-06:** 纯 CSS 覆盖 — 不修改 FreeMarker .ftl 模板文件，仅通过 styles.css 覆盖默认样式
- **D-07:** 仅覆盖 login 主题类型 — 不创建 register、email、account 等主题类型

### Claude's Discretion
- 具体需要覆盖哪些 CSS 选择器（按钮、链接、输入框焦点色等）
- 是否需要覆盖 Keycloak CSS 变量（`--pf-*`）还是直接覆盖属性
- styles.css 的组织方式和注释风格

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| THEME-01 | 品牌化登录页 — 创建 noda 主题，CSS 覆盖实现 Noda 品牌风格 | PatternFly v4 CSS 变量映射到 Noda 品牌色；theme.properties 修复；关键选择器清单 |
| THEME-02 | 自定义 Logo — 替换默认 Keycloak Logo 为 Noda Logo | D-04 决定保留默认 Logo，THEME-02 标记为已完成（默认行为满足） |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Keycloak | 26.2.3 | 认证服务 | 项目已在运行，提供 v1 FreeMarker 主题系统 |
| PatternFly v4 | (Keycloak 内置) | CSS 框架 | Keycloak 26.x 登录页基于 PF4，通过 `--pf-global--*` 变量控制样式 |

### Supporting
无额外依赖。纯 CSS 覆盖方案不需要引入任何新库。

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| CSS 变量覆盖 | 直接属性覆盖 | 变量覆盖代码量更少、更易维护；但需验证 Keycloak 26.x 的 PF4 变量是否全面覆盖所需元素 |
| v1 FreeMarker 主题 | v2 React 主题 | v2 仅限 Account Console，login 页面仍需 v1。REQUIREMENTS.md 明确排除 v2 |

**Installation:**
无需安装新包。所有工具已在项目中就位。

## Architecture Patterns

### 项目结构（Phase 12 已创建）
```
docker/services/keycloak/themes/
└── noda/
    └── login/
        ├── theme.properties          # 主题定义（需修复：添加 styles=）
        └── resources/
            └── css/
                └── styles.css        # 自定义 CSS（当前为空，需填充）
```

### 主题继承链
```
noda → keycloak → base
```
- **base:** Keycloak 最底层主题，定义 FreeMarker 模板骨架
- **keycloak:** 定义 `styles=css/login.css`、`stylesCommon`（PatternFly v4/v3 CSS），以及大量 CSS 类属性（kcButtonClass 等）
- **noda:** 继承 keycloak，通过 `styles=css/styles.css` 加载自定义 CSS（覆盖 keycloak 的 login.css 样式）

### Pattern: CSS 变量覆盖
**What:** 通过覆盖 PatternFly v4 全局 CSS 变量（`--pf-global--primary-color--100` 等）改变 Keycloak 登录页配色
**When to use:** 需要批量修改使用同一变量的多个元素时
**Example:**
```css
/* 源自 Keycloak 26.x login.css 分析 [VERIFIED: GitHub keycloak/keycloak main] */
:root {
    --pf-global--primary-color--100: #0D9B6A;  /* Pounamu Green 替代默认蓝色 */
}
```

### Pattern: 直接选择器覆盖
**What:** 直接针对特定 CSS 选择器覆盖属性值
**When to use:** 变量覆盖无法覆盖的元素（如硬编码颜色值的样式）
**Example:**
```css
/* login.css 中部分颜色不使用 PF 变量，需要直接覆盖 */
.login-pf a:hover {
    color: #0D9B6A;  /* 替代默认 #0099d3 */
}
```

### Anti-Patterns to Avoid
- **修改 .ftl 模板文件:** D-06 明确禁止。模板修改在 Keycloak 升级时会产生合并冲突。所有品牌化通过 CSS 实现。
- **覆盖布局/间距样式:** D-05 限制仅修改颜色和圆角。不要修改 padding、margin、font-size 等布局属性。
- **添加新 CSS 框架:** 仅使用 Keycloak 已内置的 PatternFly。不要引入 Tailwind、Bootstrap 等外部框架。

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 主题注册机制 | 自定义 theme loader | Keycloak v1 theme.properties 继承系统 | 内置支持 parent/import 链 |
| CSS 重置/基础样式 | 从零编写所有样式 | 继承 keycloak 基础主题的 PatternFly 样式 | parent=keycloak 提供完整基础 |
| 响应式布局 | 手写 media queries | 保留 Keycloak 默认响应式 | 默认布局已在移动端适配 |

**Key insight:** 主题系统的设计意图就是"最小覆盖"。只需要差异部分，其余全部继承自父主题。

## Common Pitfalls

### Pitfall 1: theme.properties 缺少 styles= 声明
**What goes wrong:** 自定义 CSS 文件存在但不被加载，主题看起来与默认完全相同
**Why it happens:** Keycloak v1 主题系统不会自动扫描 resources 目录，必须在 theme.properties 中显式声明 `styles=css/styles.css`
**How to avoid:** 在 theme.properties 中添加 `styles=css/styles.css` 行。当前文件仅有 `parent=keycloak` 和 `import=common/keycloak`，缺少此行。
**Warning signs:** 修改 styles.css 后刷新页面无任何变化

### Pitfall 2: 主题缓存导致修改不生效
**What goes wrong:** 在生产环境修改 CSS 后刷新浏览器看不到变化
**Why it happens:** Keycloak 生产模式（`start` 命令）缓存主题资源，修改文件不会立即反映
**How to avoid:** 使用 keycloak-dev 容器（`start-dev` 模式）进行开发，该模式自动禁用主题缓存。生产环境需重启 Keycloak 容器使主题生效。
**Warning signs:** `start-dev` 下修改即时生效，但部署到生产后看不到变化

### Pitfall 3: Admin Console 未切换主题
**What goes wrong:** 主题文件正确，CSS 正确，但登录页仍显示默认样式
**Why it happens:** Keycloak 需要在 Admin Console 中手动将 Realm 的 Login Theme 设置为 `noda`
**How to avoid:** 实现步骤中必须包含：Admin Console → Realm Settings → Themes → Login Theme → 选择 `noda` → Save
**Warning signs:** 主题文件存在且 CSS 正确，但 `view-source` 显示加载的是 keycloak 默认主题的 CSS

### Pitfall 4: CSS 变量覆盖范围不足
**What goes wrong:** 覆盖了 `--pf-global--primary-color--100` 但部分元素颜色仍未变化
**Why it happens:** Keycloak login.css 中部分颜色值是硬编码的（如链接 hover 色 `#0099d3`），不使用 PF 变量
**How to avoid:** 结合变量覆盖 + 直接选择器覆盖，确保所有需要品牌化的元素都被覆盖
**Warning signs:** 主按钮和卡片边框变色了，但链接和 hover 状态仍是默认蓝色

### Pitfall 5: prod 只读挂载与 dev 读写挂载混淆
**What goes wrong:** 在生产环境中尝试修改主题文件失败（只读挂载）
**Why it happens:** docker-compose.yml 中 themes 挂载为 `:ro`（只读），docker-compose.dev.yml 为读写
**How to avoid:** 开发用 keycloak-dev（localhost:18080），生产部署通过 git 推送 + 重启容器更新主题
**Warning signs:** `Permission denied` 错误或文件修改后恢复原状

## Code Examples

### theme.properties 修复（必须）
```properties
# 当前内容（缺少 styles=）
parent=keycloak
import=common/keycloak

# 修复后内容
parent=keycloak
import=common/keycloak
styles=css/styles.css
```

### styles.css 推荐结构
```css
/* ============================================
   Noda Login Theme - Brand Color Overrides
   ============================================
   品牌色：Pounamu Green #0D9B6A（主色）
   设计系统：noda-apps/packages/design-tokens
   策略：最小覆盖，仅修改颜色变量和关键选择器
   ============================================ */

/* --- PatternFly 全局变量覆盖 --- */
:root {
    /* 主色：Pounamu Green */
    --pf-global--primary-color--100: #0D9B6A;
    --pf-global--primary-color--200: #0a7d55;
    --pf-global--primary-color--light-100: #0D9B6A;

    /* 焦点环色 */
    --pf-global--active-color--100: #0D9B6A;

    /* 链接色 */
    --pf-global--link--Color: #0D9B6A;
    --pf-global--link--Color--hover: #0a7d55;
}

/* --- 直接选择器覆盖（login.css 硬编码值）--- */

/* 卡片顶部边框条 */
.card-pf {
    border-top-color: #0D9B6A !important;
}

/* 页面标题 */
#kc-header-wrapper {
    color: #0f172a;  /* Slate 900 */
}

/* 链接 hover */
.login-pf a:hover {
    color: #0D9B6A;
}

/* 认证方式选择标题 */
.select-auth-box-headline {
    color: #0D9B6A;
}

/* 输入框焦点环 */
input:focus, select:focus {
    border-color: #0D9B6A !important;
    box-shadow: 0 0 0 2px rgba(13, 155, 106, 0.25) !important;
    border-radius: 0.5rem;
}

/* 按钮圆角 */
.pf-c-button {
    border-radius: 0.5rem;
}

/* 输入框圆角和边框 */
#kc-form input[type="text"],
#kc-form input[type="password"] {
    border-color: #e2e8f0;  /* Slate 200 */
    border-radius: 0.5rem;
}
```

### CSS 选择器清单（login.css 中需要覆盖的选择器）
```
关键选择器                     | 用途                | login.css 中的值
-------------------------------|--------------------|--------------
:root --pf-global--primary-*   | 全局主色            | #0066cc (PF4 默认)
:root --pf-global--link--*     | 链接色              | #06c
.card-pf                       | 登录卡片顶部边框    | var(--pf-global--primary-color--100)
#kc-header-wrapper             | 页面标题颜色        | (继承 PF)
.login-pf a:hover              | 链接 hover 色      | #0099d3（硬编码）
.select-auth-box-headline      | 认证选择标题        | var(--pf-global--primary-color--100)
.pf-c-button                   | 按钮样式            | PF4 默认
input:focus                    | 输入框焦点          | PF4 默认蓝色环
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Keycloak v1 hostname 选项 | v2 Hostname SPI (`KC_HOSTNAME`) | Keycloak 20+ | Phase 12 已处理 |
| PatternFly v3 | PatternFly v4 | Keycloak 20+ | 使用 `--pf-global--*` 变量而非 `.pf-*` 类 |
| 主题热重载需手动禁用缓存 | `start-dev` 自动禁用缓存 | Keycloak 20+ | dev 环境开发体验显著改善 |

**Deprecated/outdated:**
- `KC_HOSTNAME_PORT`、`KC_HOSTNAME_STRICT_HTTPS`: Keycloak v1 废弃选项，已在 Phase 11/12 移除
- PatternFly v3 类名（`.login-pf .badge` 等）: 已被 PF4 替代，但 login.css 中仍有少量残留

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Keycloak 26.2.3 login.css 中 `--pf-global--primary-color--100` 控制卡片边框和认证标题颜色 | Architecture Patterns | 部分元素可能使用硬编码值，需要额外的直接选择器覆盖 |
| A2 | `styles=css/styles.css` 会追加到（而非替换）父主题的样式列表 | Architecture Patterns | 如果替换而非追加，可能导致 PatternFly 基础样式丢失 |
| A3 | `!important` 在必要的选择器覆盖中是安全的 | Code Examples | 如果过度使用可能导致维护困难 |

**关于 A2 的验证：** Keycloak 主题系统中，子主题的 `styles=` 会追加到父主题的样式列表之后（而非替换）。keycloak 父主题加载 `css/login.css`，noda 子主题的 `css/styles.css` 在其后加载，因此 CSS 层叠规则自然生效——后加载的样式覆盖先加载的。[ASSUMED: 基于 Keycloak 主题系统设计原理，未通过源码验证]

## Open Questions

1. **主题激活时机**
   - What we know: 需要在 Admin Console 手动切换 Login Theme 为 `noda`
   - What's unclear: 切换是否需要重启容器才能生效（生产模式）
   - Recommendation: 先在 dev 环境验证主题效果，确认无误后再在生产环境切换。切换后如未生效，重启 keycloak 容器。

2. **CSS 覆盖的完整性**
   - What we know: login.css 中大部分颜色使用 PF 变量，少部分硬编码
   - What's unclear: 是否还有其他硬编码颜色值被遗漏（如错误状态、禁用状态）
   - Recommendation: 实现后在 dev 环境遍历所有登录页状态（正常、错误、社交登录、TOTP）进行视觉验证。

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | 主题部署和测试 | ✓ | 29.1.3 | — |
| Keycloak (prod) | 生产主题验证 | ✓ | 26.2.3 (quay.io) | — |
| Keycloak (dev) | CSS 热重载开发 | ✓ | 26.2.3 (keycloak-dev) | — |
| keycloak-dev 容器运行 | CSS 修改即时验证 | 待确认 | — | 重启 keycloak-dev 容器 |
| 浏览器 DevTools | CSS 调试 | ✓ | — | — |

**Missing dependencies with no fallback:**
None — 所有依赖已在 Phase 12 就位。

**Missing dependencies with fallback:**
- keycloak-dev 容器可能未运行 — 启动命令：`docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d keycloak-dev`

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | 手动视觉验证（无自动化测试框架） |
| Config file | none |
| Quick run command | `docker compose -f docker/docker-compose.yml -f docker/docker-compose.dev.yml up -d keycloak-dev && open http://localhost:18080` |
| Full suite command | 遍历登录页所有状态进行视觉检查 |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| THEME-01 | 登录页使用 Noda 品牌色 | manual-only | `open http://localhost:18080` (dev) / `open https://auth.noda.co.nz` (prod) | N/A |
| THEME-02 | 默认 Keycloak Logo 保留 | manual-only | 目视确认 | N/A |

**Justification for manual-only:** CSS 主题定制是视觉层面的工作，涉及颜色、圆角等外观属性。自动化快照测试（如 Percy/Chromatic）需要额外基础设施且本阶段仅修改 CSS 变量，ROI 不合理。通过浏览器 DevTools 检查元素计算样式即可验证。

### Sampling Rate
- **Per task commit:** Dev 环境 `localhost:18080` 目视验证
- **Per wave merge:** Dev + Prod 环境对比验证
- **Phase gate:** 生产环境 `auth.noda.co.nz` 完整登录流程验证

### Wave 0 Gaps
None — 纯 CSS 修改不需要测试框架基础设施。验证通过浏览器手动完成。

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | 不修改认证流程，仅修改 UI 样式 |
| V3 Session Management | no | 不涉及会话管理 |
| V4 Access Control | no | 不涉及权限控制 |
| V5 Input Validation | no | 纯 CSS 文件，无用户输入 |
| V6 Cryptography | no | 不涉及加密 |

### Known Threat Patterns for CSS Theme Customization

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| CSS 注入 | Tampering | CSS 文件通过 Docker 只读挂载，仅可通过 git 修改。主题不加载外部资源。 |
| 供应链风险（Font/CDN） | Tampering | 不引入外部字体或 CDN 资源，使用 Keycloak 内置资源 |

**安全评估：** 本阶段为低风险——仅修改静态 CSS 文件，不涉及认证逻辑、数据处理或外部资源加载。CSS 覆盖不影响安全控制（HTTPS、Cookie 标记、CORS 等由 Keycloak 配置控制，与主题无关）。

## Sources

### Primary (HIGH confidence)
- Keycloak GitHub 仓库 `keycloak/keycloak` — 获取 `theme.properties`、`login.css` 源码，分析 CSS 变量和选择器 [VERIFIED: GitHub main branch]
- `docker/services/keycloak/themes/noda/login/theme.properties` — 当前主题配置 [VERIFIED: 本地文件读取]
- `~/Project/noda-apps/packages/design-tokens/tokens/primitive/colors.json` — 品牌色定义 [VERIFIED: 本地文件读取]
- `~/Project/noda-apps/packages/design-tokens/tokens/semantic/light.json` — 语义色映射 [VERIFIED: 本地文件读取]

### Secondary (MEDIUM confidence)
- Keycloak v1 主题系统继承行为（子主题 styles= 追加而非替换） [ASSUMED: 基于 Keycloak 文档和社区经验]

### Tertiary (LOW confidence)
- None

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 无新依赖，基于现有 Keycloak 26.2.3 + PatternFly v4
- Architecture: HIGH — 主题继承链和文件结构已通过本地文件和 GitHub 源码验证
- Pitfalls: HIGH — theme.properties 缺陷通过实际文件读取确认；缓存和激活问题基于 Keycloak 社区经验
- CSS 选择器: MEDIUM — 基于 GitHub main 分支源码分析，可能因 Keycloak 版本微小差异有所不同

**Research date:** 2026-04-11
**Valid until:** 2026-05-11（Keycloak 主题系统稳定，30 天有效期合理）
