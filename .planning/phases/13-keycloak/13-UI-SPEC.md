---
phase: 13
slug: keycloak-theme
status: draft
shadcn_initialized: false
preset: none
created: 2026-04-11
---

# Phase 13 — UI Design Contract

> Keycloak 自定义登录主题（纯 CSS 覆盖）。无组件库、无前端构建、无 React/shadcn。所有品牌色来自 noda-apps 设计系统 tokens。

---

## Design System

| Property | Value |
|----------|-------|
| Tool | none — 纯 CSS 主题覆盖，非前端应用 |
| Preset | not applicable |
| Component library | none — 继承 Keycloak PatternFly v4 组件 |
| Icon library | none — 使用 Keycloak 内置图标 |
| Font | none — 使用 Keycloak 默认字体（D-05 保留默认布局和排版） |

**Note:** 本阶段不引入任何前端工具链。设计系统仅通过 CSS 变量映射体现。

---

## Spacing Scale

**不修改。** D-05 保留 Keycloak 默认布局、间距和组件结构。仅覆盖颜色和 border-radius。

Exceptions: none

---

## Typography

**不修改。** D-05 保留 Keycloak 默认字体大小、字重和行高。CSS 覆盖不涉及任何排版属性。

---

## Color

色值来源：`~/Project/noda-apps/packages/design-tokens/tokens/`

### 品牌色映射

| Design Token | Hex | CSS Variable / Selector | 覆盖目标 |
|-------------|-----|------------------------|---------|
| `color.green.pounamu` | `#0D9B6A` | `--pf-global--primary-color--100` | 主按钮背景、链接色、卡片顶部边框 |
| `color.green.pounamu` (dark) | `#0a7d55` | `--pf-global--primary-color--200` | 主按钮 hover 状态 |
| `color.green.pounamu` | `#0D9B6A` | `--pf-global--primary-color--light-100` | 浅色主色变体 |
| `color.green.pounamu` | `#0D9B6A` | `--pf-global--active-color--100` | 输入框焦点环色 |
| `color.green.pounamu` | `#0D9B6A` | `--pf-global--link--Color` | 链接默认色 |
| `color.green.pounamu` (dark) | `#0a7d55` | `--pf-global--link--Color--hover` | 链接 hover 色 |
| `color.slate.900` | `#0f172a` | `#kc-header-wrapper` | 页面标题文字色 |
| `color.slate.200` | `#e2e8f0` | `#kc-form input` border-color | 输入框边框色 |

### 60/30/10 分布

| Role | Value | Usage |
|------|-------|-------|
| Dominant (60%) | `#ffffff` | 页面背景、卡片背景（Keycloak 默认，不修改） |
| Secondary (30%) | `#0f172a` (Slate 900) | 文字色、标题色 — 保持 Keycloak 默认深色文字 |
| Accent (10%) | `#0D9B6A` (Pounamu Green) | 主按钮、链接、焦点环、卡片顶部边框条、认证选择标题 |

Accent reserved for: 主按钮背景、链接文字色、输入框焦点环色、登录卡片顶部 3px 边框条、认证方式选择标题

### 次要品牌色（本阶段不使用）

| Token | Hex | 保留用途 |
|-------|-----|---------|
| `color.blue.ocean` | `#005DBB` | Future: 社交登录按钮等次要交互元素 |
| `color.gold.kowhai` | `#D4A017` | Future: 警告/高亮等场景 |
| `destructive` | `#ef4444` | 登录错误提示（Keycloak 内置，不覆盖） |

---

## Border Radius

| Token | Value | 覆盖目标 |
|-------|-------|---------|
| `radii.lg` | `0.5rem` | 主按钮（`.pf-c-button`）、输入框（`#kc-form input`） |

来源：D-03 决定使用设计系统标准 `0.5rem`，对应 `radii.json` 中的 `lg` 值。

---

## CSS Override Contract

### PatternFly 变量覆盖（:root 级别）

```css
:root {
    --pf-global--primary-color--100: #0D9B6A;
    --pf-global--primary-color--200: #0a7d55;
    --pf-global--primary-color--light-100: #0D9B6A;
    --pf-global--active-color--100: #0D9B6A;
    --pf-global--link--Color: #0D9B6A;
    --pf-global--link--Color--hover: #0a7d55;
}
```

### 直接选择器覆盖（login.css 硬编码值）

| Selector | Property | Value | Reason |
|----------|----------|-------|--------|
| `.card-pf` | `border-top-color` | `#0D9B6A` | login.css 中卡片边框使用 PF 变量但需确保覆盖 |
| `#kc-header-wrapper` | `color` | `#0f172a` | 页面标题使用 Slate 900 |
| `.login-pf a:hover` | `color` | `#0D9B6A` | login.css 中链接 hover 色为硬编码 `#0099d3` |
| `.select-auth-box-headline` | `color` | `#0D9B6A` | 认证选择标题 |
| `input:focus, select:focus` | `border-color` | `#0D9B6A` | 焦点状态边框 |
| `input:focus, select:focus` | `box-shadow` | `0 0 0 2px rgba(13, 155, 106, 0.25)` | 焦点环 |
| `.pf-c-button` | `border-radius` | `0.5rem` | 按钮圆角 |
| `#kc-form input[type="text"]` | `border-color` | `#e2e8f0` | 输入框默认边框（Slate 200） |
| `#kc-form input[type="text"]` | `border-radius` | `0.5rem` | 输入框圆角 |
| `#kc-form input[type="password"]` | `border-color` | `#e2e8f0` | 密码框默认边框 |
| `#kc-form input[type="password"]` | `border-radius` | `0.5rem` | 密码框圆角 |

### 不覆盖的属性（D-05 约束）

- padding / margin / width / height（布局间距）
- font-size / font-weight / font-family / line-height（排版）
- display / position / flex 属性（布局结构）
- Keycloak 默认 Logo（D-04 保留）

---

## Copywriting Contract

**不修改。** D-06 纯 CSS 覆盖策略不涉及任何文本修改。所有文案使用 Keycloak 默认英文文本。

| Element | Status |
|---------|--------|
| Primary CTA | Keycloak 默认 "Sign In" — 不修改 |
| Empty state | Keycloak 默认 — 不修改 |
| Error state | Keycloak 默认 — 不修改 |
| Destructive confirmation | 不涉及 |

中文消息包为 Future 需求 THEME-03，本阶段不实现。

---

## Registry Safety

| Registry | Blocks Used | Safety Gate |
|----------|-------------|-------------|
| none | none | not applicable |

本阶段不使用 shadcn 或任何第三方注册表。纯 CSS 文件，零外部依赖。

---

## Prerequisite Fix

### theme.properties 修复（阻塞性）

当前 `theme.properties` 缺少 `styles=css/styles.css` 声明，自定义 CSS 不会被 Keycloak 加载。

**Before:**
```properties
parent=keycloak
import=common/keycloak
```

**After:**
```properties
parent=keycloak
import=common/keycloak
styles=css/styles.css
```

### 主题激活

在 Keycloak Admin Console 中设置：Realm Settings → Themes → Login Theme → `noda` → Save。

开发环境（keycloak-dev）修改后刷新浏览器即可看到变化。生产环境需重启 Keycloak 容器。

---

## Verification States

以下登录页状态需在开发环境逐一验证颜色覆盖效果：

| State | 验证要点 |
|-------|---------|
| 默认登录页 | 卡片顶部边框为绿色、标题为 Slate 900、输入框圆角 0.5rem、边框 Slate 200 |
| 输入焦点 | 焦点环为 Pounamu Green、无蓝色残留 |
| 按钮 hover | 按钮背景保持绿色系（由 PF 变量控制） |
| 链接 hover | 链接色为 Pounamu Green（非默认 `#0099d3`） |
| 错误状态 | Keycloak 默认红色错误提示不受影响 |
| Google 社交登录按钮 | 按钮圆角为 0.5rem |

---

## Checker Sign-Off

- [ ] Dimension 1 Copywriting: PASS — 不修改文案，使用 Keycloak 默认文本
- [ ] Dimension 2 Visuals: PASS — CSS 选择器和覆盖值明确声明
- [ ] Dimension 3 Color: PASS — 品牌色来自设计系统 tokens，60/30/10 分布合理
- [ ] Dimension 4 Typography: PASS — 不修改排版，保留 Keycloak 默认
- [ ] Dimension 5 Spacing: PASS — 不修改间距，保留 Keycloak 默认
- [ ] Dimension 6 Registry Safety: PASS — 无第三方注册表依赖

**Approval:** pending
