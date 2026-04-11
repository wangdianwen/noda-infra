# Phase 13: Keycloak 自定义主题 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-11
**Phase:** 13-keycloak
**Areas discussed:** 品牌设计元素, CSS 覆盖深度, 模板定制策略, 主题覆盖范围

---

## 品牌设计元素

### Logo

| Option | Description | Selected |
|--------|-------------|----------|
| 已有 SVG Logo | 有现成的 Noda Logo SVG | |
| 有位图格式 Logo | 有 PNG/JPG，需转换 | |
| 没有 Logo（用占位符） | 尚无 Logo，需用占位符 | ✓ |

**User's choice:** 没有 Logo
**Notes:** 随后选择保留 Keycloak 默认 Logo（不做文字占位符）

### Logo 占位策略

| Option | Description | Selected |
|--------|-------------|----------|
| 文字 Logo 占位（推荐） | 用 "Noda" 文字占位，后续替换文件 | |
| 图标占位符 | 用简单几何图形占位 | |
| 保留默认 Logo | 保留 Keycloak Logo，只改颜色和字体 | ✓ |

**User's choice:** 保留默认 Logo

### 品牌色

| Option | Description | Selected |
|--------|-------------|----------|
| 已有色值 | 确定的品牌色可提供 | ✓ |
| 你决定（现代简洁风格） | 无明确色值，由 Claude 决定 | |

**User's choice:** 已有色值
**Notes:** 色值来自 noda-apps 设计系统 (packages/design-tokens)。Pounamu Green #0D9B6A, Ocean Blue #005DBB, Kowhai Gold #D4A017

---

## CSS 覆盖深度

| Option | Description | Selected |
|--------|-------------|----------|
| 最小覆盖（仅颜色）（推荐） | 只改颜色变量和 Logo，保留默认布局 | ✓ |
| 中等覆盖（颜色 + 组件） | 改颜色 + 按钮风格 + 背景色 | |
| 深度重写（完全自定义） | 完全重写布局、背景、动画 | |

**User's choice:** 最小覆盖（仅颜色）
**Notes:** 使用设计系统 Pounamu Green #0D9B6A 作为主色

---

## 模板定制策略

| Option | Description | Selected |
|--------|-------------|----------|
| 纯 CSS 覆盖（推荐） | 只写 CSS，不碰 FreeMarker 模板 | ✓ |
| 覆盖 FreeMarker 模板 | 复制 login.ftl 修改 HTML 结构 | |

**User's choice:** 纯 CSS 覆盖
**Notes:** 保留默认 Logo + 只改颜色 → 纯 CSS 完全足够

---

## 主题覆盖范围

| Option | Description | Selected |
|--------|-------------|----------|
| 仅 login（推荐） | 只覆盖登录页，匹配 THEME-01/02 需求 | ✓ |
| 全部页面 | login + register + email 等 | |

**User's choice:** 仅 login
**Notes:** THEME-03/04/05（中文消息包、Email 主题、Account 主题）列为 Future 需求

---

## Claude's Discretion

- 具体覆盖哪些 CSS 选择器
- 使用 CSS 变量覆盖还是直接属性覆盖
- styles.css 组织方式

## Deferred Ideas

None
