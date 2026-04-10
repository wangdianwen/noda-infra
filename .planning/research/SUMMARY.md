# Project Research Summary

**Project:** Noda Infrastructure v1.2 -- Keycloak 双环境部署 + 自定义主题
**Domain:** Docker Compose 基础设施 / Keycloak 认证服务定制
**Researched:** 2026-04-11
**Confidence:** HIGH

## Executive Summary

本项目是为 Noda 教育平台基础设施（v1.2 里程碑）添加 Keycloak 开发/生产双环境隔离和品牌化登录主题。技术方案基于项目已验证的 Docker Compose overlay 模式（PostgreSQL 双实例已稳定运行），复用 `postgres-dev` 实例为开发 Keycloak 提供独立的 `keycloak_dev` 数据库，实现完全隔离的双环境架构。

推荐的技术路线是 Keycloak v1 FreeMarker 主题（`parent=keycloak`），通过 CSS 覆盖 + 消息包定制实现品牌化登录页。这条路线自由度高、社区文档丰富、与 Keycloak 26.2.3 完全兼容，避免了 v2 React 主题的定制限制。整个项目预估 7-12 小时工作量（约 1-2 个工作日），核心风险集中在双环境数据隔离和 Hostname v2 SPI 配置上，但均有项目内已验证的修复经验可供参考。

## Key Findings

### Recommended Stack

主题开发无需安装任何额外 npm/pip 包，完全基于 Keycloak 内置的 FreeMarker 模板引擎和原生 CSS 覆盖机制。双环境方案复用已有的 Docker Compose overlay 模式和 PostgreSQL dev 实例。

**Core technologies:**
- **Keycloak 26.2.3:** 认证服务 -- 项目已部署，主题系统基于 FreeMarker，无额外依赖
- **FreeMarker 模板:** 登录页 HTML 渲染 -- Keycloak 内置引擎，`.ftl` 文件放入 theme 目录即生效
- **CSS3 + PatternFly 5 变量覆盖:** 品牌化样式 -- 通过 `theme.properties` 的 `styles` 属性加载，覆盖 PF5 默认样式
- **Docker Compose overlay:** dev/prod 配置分离 -- 项目已验证的 base + overlay 模式
- **Volume bind mount:** 主题文件注入 -- 宿主机 Git 管理的文件通过 `:ro` 挂载到容器

### Expected Features

**Must have (table stakes):**
- **keycloak-dev 独立容器 (TS-1):** 开发环境独立 Keycloak 实例，使用 `start-dev` 命令
- **独立数据库 keycloak_dev (TS-2):** 连接 `postgres-dev:5432/keycloak_dev`，避免数据污染
- **端口偏移 (TS-3):** dev 使用 18080/9100 端口，与 prod 的 8080/9000 不冲突
- **Hostname v2 SPI 配置 (TS-4):** dev 清空 `KC_HOSTNAME`、禁用 strict/proxy
- **主题目录结构 (TS-5):** `services/keycloak/themes/noda/login/` 完整目录和 `theme.properties`
- **主题继承 parent=keycloak (TS-6):** v1 FreeMarker 方式，CSS 覆盖实现品牌化
- **Realm 启用主题 (TS-7):** `noda-realm.json` 添加 `loginTheme: "noda"` 字段
- **品牌化 CSS (TS-8) + Logo (TS-9):** 颜色、字体、Logo 替换
- **Dev 主题缓存禁用 (TS-10):** 开发环境添加 `--spi-theme-cache-*` 禁用参数

**Should have (differentiators):**
- **本地化消息 (DF-1):** `messages_zh_CN.properties` 中文翻译
- **移动端适配 (DF-2):** 响应式媒体查询
- **Dev realm 初始化 (DF-4):** 简化 dev 环境配置流程

**Defer (v1.3+):**
- **自定义 HTML 模板 (DF-3):** 仅在 CSS 不够用时使用
- **邮件模板 (DF-5) / Account Console 主题 (DF-6):** 高级定制

### Architecture Approach

项目采用 Docker Compose overlay 隔离模式，生产环境通过 Cloudflare Tunnel 暴露 `auth.noda.co.nz`，开发环境通过 `localhost:8180` 直连。两个环境的 Keycloak 实例完全独立（独立容器、独立数据库、独立端口），但共享同一套主题源码（通过 volume bind mount 从宿主机注入）。主题架构使用 `parent=keycloak` 继承基础 FreeMarker 主题，仅覆盖 CSS 和消息文件，保持最小变更集。

**Major components:**
1. **keycloak-dev 服务:** 开发环境独立容器，`start-dev` 模式，禁用主题缓存，暴露 18080 端口
2. **主题文件目录:** `services/keycloak/themes/noda/login/` -- theme.properties + CSS + 消息包 + 图片
3. **noda-realm.json 更新:** 添加 `loginTheme: "noda"` 字段激活主题

### Critical Pitfalls

1. **Dev/Prod 共享数据库导致数据污染 (Pitfall 2):** dev Keycloak 必须连接独立的 `keycloak_dev` 数据库，否则 realm 配置互相覆盖、schema 迁移竞争
2. **Hostname v2 SPI 配置错误导致 cookie/session 失效 (Pitfall 6):** dev 环境必须清空 `KC_HOSTNAME`、设置 `KC_HOSTNAME_STRICT: false`、`KC_PROXY: none`；绝对不能使用 v1 废弃选项 `KC_HOSTNAME_PORT`
3. **主题缓存导致修改不生效 (Pitfall 1):** 开发环境必须添加缓存禁用参数；生产环境修改主题后需重启容器
4. **主题已部署但未在 Admin Console 启用 (Pitfall 4):** 必须在 `noda-realm.json` 中添加 `loginTheme: "noda"`，或在 Admin Console 手动选择
5. **v1/v2 主题选择错误 (Pitfall 5):** 必须使用 `parent=keycloak`（v1 FreeMarker），不要使用 `parent=keycloak.v2`（React），否则 `.ftl` 模板和 CSS 覆盖不生效

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: Keycloak 双环境搭建
**Rationale:** 双环境是基础设施层面的事，与主题无关但必须先就绪，才能在 dev 环境中高效开发主题。数据库隔离和端口规划是硬依赖。
**Delivers:** 可独立启动的 keycloak-dev 容器，完全隔离的开发/生产环境
**Addresses:** TS-1, TS-2, TS-3, TS-4
**Avoids:** Pitfall 2（数据污染）、Pitfall 3（端口冲突）、Pitfall 6（Hostname 配置错误）
**Key actions:**
- 在 `docker-compose.dev.yml` 中添加 `keycloak-dev` 服务定义
- 确认 `postgres-dev` 中 `keycloak_dev` 数据库已创建（init-dev SQL 已包含）
- 配置端口偏移 18080/9100
- 配置 Hostname v2 SPI（清空 KC_HOSTNAME、禁用 strict/proxy）

### Phase 2: 自定义主题开发
**Rationale:** 主题开发依赖 dev 环境的热重载能力（Phase 1 提供的缓存禁用），但主题文件的创建本身不依赖 dev 环境。可以先在生产环境验证主题基本可用，再在 dev 环境迭代优化。
**Delivers:** 品牌化登录页，Noda Logo + 自定义颜色/字体
**Uses:** Keycloak FreeMarker 主题系统、CSS 覆盖、PatternFly 5 变量
**Implements:** TS-5, TS-6, TS-8, TS-9, TS-7, TS-10
**Avoids:** Pitfall 1（缓存问题）、Pitfall 4（未启用主题）、Pitfall 5（继承错误）、Pitfall 7（目录不存在）
**Key actions:**
- 创建 `services/keycloak/themes/noda/login/` 目录结构
- 编写 `theme.properties`（parent=keycloak, import=common/keycloak）
- 编写 `noda.css`（颜色变量覆盖、Logo、按钮样式）
- 添加 Noda Logo SVG 到 `resources/img/`
- 修改 `noda-realm.json` 添加 `loginTheme: "noda"`

### Phase 3: 集成验证 + 增强
**Rationale:** 双环境和主题都完成后，需要端到端验证完整登录流程。增强功能（本地化、移动端适配）可在基本功能稳定后添加。
**Delivers:** 完整可用的双环境 + 品牌化登录系统
**Addresses:** DF-1, DF-2, DF-4
**Avoids:** Pitfall 9（Google OAuth dev 回调不匹配）
**Key actions:**
- 验证 prod 登录流程（auth.noda.co.nz -> Google OAuth -> 回调）
- 验证 dev 登录流程（localhost:8180 -> 密码/Google -> 回调）
- 添加 `messages_zh_CN.properties` 中文消息
- 添加移动端响应式媒体查询
- 可选：创建 `init-realm-dev.sh` 简化 dev 环境初始化

### Phase Ordering Rationale

- **Phase 1 先于 Phase 2:** dev 环境的主题缓存禁用是高效开发主题的前提条件；数据库隔离是不可妥协的安全需求
- **Phase 2 可部分与 Phase 1 并行:** 主题文件创建（TS-5, TS-6）不依赖 dev 环境，可以直接在现有 prod Keycloak 上验证；但主题迭代优化需要 dev 环境的热重载
- **Phase 3 最后:** 端到端验证需要两个环境都就绪
- **DF-4（dev realm 初始化）归入 Phase 3:** 不是 v1.2 的核心需求，但能显著提升后续开发效率

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 1:** Google OAuth dev 环境配置（Pitfall 9）-- 需确认 Google Console 配置步骤和 localhost 回调 URL 格式
- **Phase 2:** PatternFly 5 CSS 类名对照 -- 需要查阅 PF5 文档确认具体的选择器，确保 CSS 覆盖准确命中目标元素

Phases with standard patterns (skip research-phase):
- **Phase 1 Docker Compose 配置:** 已有 PostgreSQL overlay 模式作为参考，配置结构完全一致
- **Phase 2 主题目录结构:** Keycloak 官方文档有完整的目录结构说明
- **Phase 3 集成验证:** 标准的 OAuth 流程验证

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | 无额外技术依赖；Keycloak 主题系统是内置功能；overlay 模式已在项目中验证 |
| Features | HIGH | 10 个 table stakes 特性均为 LOW-MEDIUM 复杂度；依赖关系清晰；已有详细实现方案 |
| Architecture | HIGH | 直接基于项目代码库分析；卷挂载已预留；数据库已创建；无需新增外部依赖 |
| Pitfalls | HIGH | 9 个 pitfalls 均有具体预防方案和验证方法；Hostname v2 问题已在 v1.1 修复过 |

**Overall confidence:** HIGH

### Gaps to Address

- **品牌设计资源:** Noda Logo SVG 和品牌色值尚未确定 -- 主题开发时需要设计输入
- **Google OAuth dev 回调:** 需要在 Google Cloud Console 添加 localhost 回调 URL -- 可能需要账号权限
- **PatternFly 5 选择器:** CSS 覆盖需要针对 PF5 的 `pf-v5-*` 类名前缀 -- 开发时需查阅 PF5 文档确认选择器
- **Dev 环境验证:** `keycloak_dev` 数据库虽已在 init SQL 中创建，但尚未实际验证 Keycloak 能否成功连接和初始化 schema

## Sources

### Primary (HIGH confidence)
- Keycloak 26.2.3 Server Developer Guide -- Themes 章节 -- 主题类型、创建流程、theme.properties 配置、缓存控制
- Keycloak 26.2.3 Server Administration Guide -- Hostname v2 SPI -- v2 配置规则、废弃选项
- Noda 项目代码库（docker-compose.yml / docker-compose.dev.yml / docker-compose.prod.yml / init-dev SQL）-- 现有架构和配置分析
- Noda 项目 CLAUDE.md -- Google 登录 8080 端口 5 层修复记录 -- Hostname v2 配置已验证经验

### Secondary (MEDIUM confidence)
- Keycloak 26.2.3 Server Administration Guide -- Reverse Proxy -- proxy 模式选择
- PatternFly 5 CSS 类名文档 -- 登录页组件选择器

### Tertiary (LOW confidence)
- 社区 Keycloak 主题开发教程 -- v1 vs v2 选择建议（已通过官方文档交叉验证）

---
*Research completed: 2026-04-11*
*Ready for roadmap: yes*
