# Feature Research

**Domain:** Keycloak 双环境部署 + 自定义主题（Docker Compose 基础设施）
**Researched:** 2026-04-11
**Confidence:** HIGH（基于 Keycloak 26.x 官方文档、项目代码库分析、已验证的 PostgreSQL prod/dev overlay 模式）

---

## 范围说明

本文档只覆盖 v1.2 里程碑的两个新功能：
1. **Keycloak 双环境** -- 本地独立 Keycloak 实例 + 配置结构统一（复用 PostgreSQL prod/dev overlay 模式）
2. **Keycloak 自定义主题** -- 实现品牌化登录页

不包括已完成的功能（备份系统、SSR 服务、Google OAuth 登录等）。

---

## Feature Landscape

### Table Stakes（必备特性）

缺少这些特性，双环境部署不可用或主题无法生效。用户不会因为有这些而赞赏，但缺少则功能不完整。

| # | Feature | Why Expected | Complexity | Deps | Notes |
|---|---------|--------------|------------|------|-------|
| TS-1 | Keycloak Dev 独立容器（keycloak-dev） | 项目已有 PostgreSQL prod/dev 双实例模式（postgres + postgres-dev）。Keycloak 理应遵循相同模式，dev 环境需要独立的 Keycloak 实例用于本地开发测试，避免影响生产 | MEDIUM | 无 | 复用 docker-compose.dev.yml overlay 模式。当前 dev overlay 修改了同一个 keycloak 服务的环境变量，但没有创建独立容器。需要添加 `keycloak-dev` 服务，使用 `start-dev` 命令 |
| TS-2 | Dev Keycloak 独立数据库（keycloak_dev） | 两个 Keycloak 实例共用同一个 PostgreSQL `keycloak` 数据库会导致 realm 配置互相覆盖、用户数据不一致、Schema 迁移竞争（PITFALLS #2） | LOW | TS-1 | 在 `KC_DB_URL` 中指向 `postgres-dev:5432/keycloak_dev`。在 PostgreSQL init-dev 脚本中创建 `keycloak_dev` 数据库 |
| TS-3 | Dev 环境端口偏移 | Dev 和 Prod Keycloak 暴露相同端口（8080/8443/9000），同时运行时端口冲突，第二个实例无法启动（PITFALLS #3） | LOW | TS-1 | Dev 使用 18080/18443/19000 端口映射。与 PostgreSQL 的 prod:5432/dev:5433 偏移模式一致 |
| TS-4 | Dev 环境 Hostname v2 SPI 配置 | Keycloak 26.x 使用 Hostname v2 SPI。Dev 环境必须清空 `KC_HOSTNAME`、禁用 strict 模式、关闭 proxy，否则 localhost 访问被拒绝或 cookie domain 错误（PITFALLS #6） | LOW | TS-1 | `KC_HOSTNAME: ""`, `KC_HOSTNAME_STRICT: "false"`, `KC_HOSTNAME_STRICT_HTTPS: "false"`, `KC_PROXY: none`。当前 dev overlay 已有这些配置但作用于同一个 keycloak 服务 |
| TS-5 | 主题目录结构（theme.properties + 资源文件） | Keycloak 要求特定目录结构才能识别主题。缺少 `theme.properties` 或路径不正确，主题不会出现在 Admin Console 的选择列表中（PITFALLS #5, #7） | LOW | 无 | 目录结构：`services/keycloak/themes/noda/login/theme.properties` + `resources/css/` + `resources/img/`。Volume 挂载点已配置但宿主机目录不存在 |
| TS-6 | 主题继承配置（parent=keycloak） | 不设置 parent 或设置错误（如 `keycloak.v2`），登录页要么白屏无样式（parent=base），要么 `.ftl` 模板不生效（parent=keycloak.v2 使用 React 而非 FreeMarker）（PITFALLS #5） | LOW | TS-5 | 推荐使用 `parent=keycloak`（v1 FreeMarker 主题），通过 CSS 覆盖实现品牌化。不使用 `keycloak.v2`（React 主题，自定义方式完全不同） |
| TS-7 | Realm 配置中启用自定义主题 | 主题文件部署后不会自动生效，必须在 Realm 配置中指定 `loginTheme: "noda"`（PITFALLS #4）。当前 `noda-realm.json` 和 `init-realm.sh` 都没有设置主题 | LOW | TS-5, TS-6 | 在 `noda-realm.json` 中添加 `"loginTheme": "noda"` 字段，或在 `init-realm.sh` 中通过 kcadm.sh 设置 |
| TS-8 | 品牌化 CSS 样式覆盖 | 登录页使用默认 Keycloak 样式，用户看到的仍然是 "Keycloak" 而非 "Noda"，降低品牌信任度。这是自定义主题的核心价值 | LOW | TS-5, TS-6 | 覆盖 `css/styles.css` 中的颜色、字体、Logo。使用 FreeMarker 模板变量引用资源文件。保持 HTML 结构不变，只修改 CSS |
| TS-9 | Noda Logo 和品牌标识 | 没有 Logo 的登录页看起来像第三方服务，用户信任度低（PITFALLS UX #2） | LOW | TS-5, TS-8 | 替换登录页 Logo 图片。Logo 文件放在 `resources/img/` 目录，通过 CSS 引用。同时修改 favicon 和页面标题 |
| TS-10 | Dev 环境主题缓存禁用 | Keycloak 默认缓存主题 30 天。开发自定义主题时，修改 CSS/模板后页面不变，开发者误以为修改没有生效（PITFALLS #1） | LOW | TS-1, TS-5 | 在 dev Keycloak 启动命令中添加 `--spi-theme-static-max-age=-1 --spi-theme-cache-themes=false --spi-theme-cache-templates=false`。生产环境保持默认缓存 |

### Differentiators（差异化特性）

这些特性不是用户默认期望的，但能显著提升开发效率和主题质量。

| # | Feature | Value Proposition | Complexity | Deps | Notes |
|---|---------|-------------------|------------|------|-------|
| DF-1 | 本地化消息文件（中文） | 默认错误提示和界面文案都是英文，中文用户不理解错误含义。提供 `messages_zh_CN.properties` 覆盖所有面向用户的文案，提升用户体验 | LOW | TS-5 | 在 `login/messages/messages_zh_CN.properties` 中翻译：登录、注册、忘记密码、错误提示等所有文案 |
| DF-2 | 移动端响应式适配 | 默认 Keycloak 主题在手机上基本可用，但自定义 CSS 可能破坏布局。需要确保主题在主流移动设备上正确显示 | LOW | TS-8 | 使用媒体查询 `@media (max-width: 480px)` 调整布局。测试 iOS Safari 和 Android Chrome |
| DF-3 | 自定义登录页 HTML 结构（.ftl 模板） | CSS-only 方案无法修改 HTML 结构。如果需要添加自定义元素（如额外链接、说明文字、背景图片容器），需要覆盖 FreeMarker 模板 | MEDIUM | TS-6 | 覆盖 `login.ftl` 模板。注意：模板随 Keycloak 版本变化，升级时需要重新适配。只在 CSS 不够用时才使用 |
| DF-4 | Dev 环境独立 realm 初始化 | Dev 环境的 realm 配置（如回调 URL）与生产不同。独立的初始化脚本避免每次手动配置 dev 环境 | MEDIUM | TS-1, TS-2 | 创建 `init-realm-dev.sh` 或在现有脚本中添加环境检测。Dev realm 使用 localhost 回调 URL |
| DF-5 | 自定义邮件模板 | 密码重置、邮件验证等场景使用默认英文模板。品牌化体验要求自定义邮件内容 | MEDIUM | TS-5, TS-6 | 在 `email/` 主题类型中创建自定义 FreeMarker 邮件模板。需要配置 SMTP（生产已配置） |
| DF-6 | Account Console 主题 | 登录后的用户账户管理页面也使用自定义主题，保持品牌一致性 | LOW | TS-5, TS-6 | 在 `account/theme.properties` 中设置 parent=keycloak.v2（Account Console 使用 React）。主要通过 CSS 变量自定义 |
| DF-7 | 主题开发验证脚本 | 自动检查主题目录结构、theme.properties 配置、资源文件完整性。减少手动排查主题不生效的时间 | LOW | TS-5 | Shell 脚本：检查目录结构、验证 theme.properties 的 parent 和 import 字段、确认 CSS/图片文件存在 |

### Anti-Features（明确不做的特性）

这些特性看起来有用，但实际上会增加复杂度或风险，与当前项目需求不匹配。

| # | Feature | Why Requested | Why Problematic | Alternative |
|---|---------|---------------|-----------------|-------------|
| AF-1 | 使用 keycloak.v2 React 主题 | Keycloak 26.x 默认使用 v2 主题，看似应该跟随 | v2 主题使用 React 组件渲染，自定义方式完全不同（通过 CSS 变量和 messages，不能直接修改模板）。社区文档和教程绝大多数是 v1 FreeMarker 方式。v1 仍然被 Keycloak 26.x 完全支持。切换 v2 需要全新的学习曲线 | 使用 `parent=keycloak`（v1 FreeMarker），通过 CSS 覆盖实现品牌化，自由度高且文档丰富 |
| AF-2 | 完整的 FreeMarker 模板覆盖 | 完全控制登录页 HTML 结构 | 模板文件随 Keycloak 版本变化而变化。升级 Keycloak 时（如 26.2 -> 27.x），覆盖的模板可能与新版本不兼容，导致登录页崩溃。维护成本高 | 只覆盖 CSS + 消息文件，保持模板继承。只在确实需要修改 HTML 结构时才覆盖特定模板 |
| AF-3 | Realm Export/Import 自动化 | 开发环境的 realm 配置自动同步 | Keycloak 的 realm export 功能不稳定（部分配置无法导出、环境变量引用丢失、敏感信息泄露风险）。当前项目规模小，init-realm.sh + 手动配置足够 | 使用 `init-realm.sh` 初始化 + kcadm.sh 精确控制。Dev 环境配置简单，手动配置成本低于自动化工程 |
| AF-4 | 主题打包为 JAR 部署 | 更"专业"的部署方式，主题独立版本管理 | JAR 部署需要额外构建步骤（Maven/Gradle）、增加 CI/CD 复杂度、调试困难。当前单节点部署，Docker volume 挂载完全满足需求 | 保持 Docker volume bind mount 方式。宿主机文件直接映射到容器，修改即时可见（dev 环境禁用缓存后） |
| AF-5 | Dev/Prod Keycloak 同时运行 | 开发时需要同时访问两个环境 | 增加资源消耗（每个 Keycloak ~512MB 内存）。实际开发场景中很少需要同时运行。可以按需启动其中一个环境 | 通过不同的 Compose 文件分别启动。需要同时运行时，端口偏移已确保不冲突（TS-3） |
| AF-6 | 自定义 JavaScript 交互 | 登录页添加动态效果或自定义验证 | Keycloak CSP 策略阻止内联脚本（PITFALLS #8）。外部 JS 文件方式增加复杂度且维护成本高。登录页是极简页面，不需要复杂交互 | 纯 CSS 实现所有视觉效果（动画、渐变、过渡）。登录验证由 Keycloak 内置处理 |
| AF-7 | 暗色模式支持 | 现代应用标配 | 增加一倍 CSS 维护工作量。登录页停留时间极短（几秒到几十秒），暗色模式 ROI 极低。Keycloak 默认主题也没有暗色模式 | 使用中性色调设计，在明暗环境下都可读。未来有需求时再添加 `prefers-color-scheme` 支持 |
| AF-8 | 多主题切换机制 | 不同场景使用不同主题 | 单一品牌不需要多个主题。多主题意味着多倍维护成本和测试矩阵 | 单一 "noda" 主题，通过 CSS 变量集中管理颜色/字体，修改一处全局生效 |

## Feature Dependencies

```
[TS-1 keycloak-dev 容器]
  ├──requires──> [TS-2 独立数据库 keycloak_dev]
  ├──requires──> [TS-3 端口偏移]
  ├──requires──> [TS-4 Hostname v2 配置]
  └──enhances──> [TS-10 主题缓存禁用]（dev 环境启动参数）
       │
       └──enhances──> [DF-4 Dev realm 初始化]

[TS-5 主题目录结构]
  ├──requires──> [TS-6 继承配置 parent=keycloak]
  └──requires──> [TS-8 CSS 样式覆盖]
       ├──includes──> [TS-9 Logo 和品牌标识]
       ├──enhances──> [DF-1 本地化消息]
       ├──enhances──> [DF-2 移动端适配]
       ├──enhances──> [DF-7 验证脚本]
       └──requires──> [TS-7 Realm 启用主题]

[TS-6 继承配置]
  ├──alternative──> [AF-1 keycloak.v2]（不使用 v2）
  └──conflicts──> [AF-2 完整模板覆盖]（应最小化模板覆盖）

[TS-7 Realm 启用主题]
  └──requires──> [TS-5, TS-6]（主题文件必须先存在且可被识别）

[DF-3 自定义 HTML]
  └──requires──> [TS-6]（必须用 v1 FreeMarker 方式）
  └──conflicts──> [AF-2]（应谨慎使用）

[DF-5 邮件模板]
  └──requires──> [TS-5, TS-6]（需要 email 主题类型）

[DF-6 Account 主题]
  └──requires──> [TS-5]（需要 account 主题类型）
  └──note: Account 使用 keycloak.v2（React），与 Login 的 v1 不同

[AF-3 Realm 自动化] ──conflicts──> [DF-4]（替代方案：手动 init-realm.sh）
[AF-4 JAR 部署] ──conflicts──> [TS-5]（替代方案：volume bind mount）
[AF-6 自定义 JS] ──conflicts──> [TS-8]（CSS-only 方案更简单）
```

### Dependency Notes

- **TS-1 是双环境的核心节点：** 没有独立的 keycloak-dev 容器，其他所有双环境特性都无法实现。它复用了 PostgreSQL prod/dev 的 overlay 模式
- **TS-5 是主题的核心节点：** 没有正确的目录结构和文件，主题不会被 Keycloak 识别。所有其他主题特性都依赖于此
- **TS-7 是"最后一公里"：** 即使主题文件完美，不在 Realm 中启用也不会生效。这是最容易遗漏的步骤（PITFALLS #4）
- **TS-10 依赖 TS-1：** 主题缓存禁用参数只在 dev 环境有意义，因此依赖 keycloak-dev 容器的存在
- **双环境和主题是两个独立模块：** 它们之间没有硬依赖。可以先搭建双环境（Phase 1），再开发主题（Phase 2），也可以并行。但主题在双环境中的测试依赖两者都完成
- **DF-1 和 DF-2 是低投入高回报：** 在 CSS/消息文件层面添加，不需要额外的架构变更

## MVP Definition

### Launch With（v1.2 -- 双环境 + 品牌化主题）

最小可用产品。Dev 环境可以独立启动并运行，生产登录页显示 Noda 品牌化主题。

**Phase 1: Keycloak 双环境搭建**

- [ ] **TS-1 keycloak-dev 独立容器** -- 在 docker-compose.dev.yml 中添加 keycloak-dev 服务，使用 `start-dev` 命令
- [ ] **TS-2 独立数据库** -- 在 init-dev 脚本中创建 `keycloak_dev` 数据库，keycloak-dev 连接 postgres-dev
- [ ] **TS-3 端口偏移** -- keycloak-dev 使用 18080/18443/19000 端口映射
- [ ] **TS-4 Hostname v2 配置** -- dev 环境清空 KC_HOSTNAME、禁用 strict、关闭 proxy

**Phase 2: 自定义主题开发**

- [ ] **TS-5 主题目录结构** -- 创建 `services/keycloak/themes/noda/login/` 目录和 `theme.properties`
- [ ] **TS-6 继承配置** -- `parent=keycloak`, `import=common/keycloak`
- [ ] **TS-8 品牌化 CSS** -- 覆盖颜色、字体、布局，保持 HTML 结构不变
- [ ] **TS-9 Logo 和品牌标识** -- 替换 Logo、favicon、页面标题
- [ ] **TS-7 Realm 启用主题** -- 在 noda-realm.json 中添加 `loginTheme: "noda"`
- [ ] **TS-10 Dev 主题缓存禁用** -- keycloak-dev 添加缓存禁用启动参数

### Add After Validation（v1.2.x -- 主题增强）

双环境稳定运行、主题基本可用后，添加增强功能。

- [ ] **DF-1 本地化消息** -- `messages_zh_CN.properties` 覆盖所有中文文案
- [ ] **DF-2 移动端适配** -- 媒体查询确保手机端布局正确
- [ ] **DF-4 Dev realm 初始化** -- 简化 dev 环境的 realm 和 client 配置流程
- [ ] **DF-7 主题验证脚本** -- 自动检查主题目录和配置完整性

### Future Consideration（v1.3+ -- 高级定制）

系统稳定运行后再考虑。

- [ ] **DF-3 自定义 HTML 模板** -- 只在 CSS 不够用时使用
- [ ] **DF-5 邮件模板** -- 密码重置等邮件的品牌化
- [ ] **DF-6 Account Console 主题** -- 用户账户管理页面主题

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority | Phase |
|---------|------------|---------------------|----------|-------|
| TS-1 keycloak-dev 容器 | HIGH | MEDIUM | P1 | Phase 1 |
| TS-2 独立数据库 | HIGH | LOW | P1 | Phase 1 |
| TS-3 端口偏移 | HIGH | LOW | P1 | Phase 1 |
| TS-4 Hostname v2 配置 | HIGH | LOW | P1 | Phase 1 |
| TS-5 主题目录结构 | HIGH | LOW | P1 | Phase 2 |
| TS-6 继承配置 | HIGH | LOW | P1 | Phase 2 |
| TS-7 Realm 启用主题 | HIGH | LOW | P1 | Phase 2 |
| TS-8 品牌化 CSS | HIGH | LOW | P1 | Phase 2 |
| TS-9 Logo 和品牌标识 | HIGH | LOW | P1 | Phase 2 |
| TS-10 Dev 缓存禁用 | MEDIUM | LOW | P1 | Phase 2 |
| DF-1 本地化消息 | MEDIUM | LOW | P2 | v1.2.x |
| DF-2 移动端适配 | MEDIUM | LOW | P2 | v1.2.x |
| DF-4 Dev realm 初始化 | MEDIUM | MEDIUM | P2 | v1.2.x |
| DF-7 验证脚本 | LOW | LOW | P2 | v1.2.x |
| DF-3 自定义 HTML | MEDIUM | MEDIUM | P3 | v1.3+ |
| DF-5 邮件模板 | LOW | MEDIUM | P3 | v1.3+ |
| DF-6 Account 主题 | LOW | LOW | P3 | v1.3+ |

**Priority key:**
- P1: v1.2 发布 -- 双环境 + 基本品牌化主题
- P2: v1.2.x 发布 -- 主题增强和开发效率提升
- P3: v1.3+ 发布 -- 高级定制

## MVP Work Estimation

| Module | Features | Est. Hours | Notes |
|--------|----------|-----------|-------|
| Keycloak 双环境配置 | TS-1, TS-2, TS-3, TS-4 | 3-4h | 复用 PostgreSQL overlay 模式，添加 keycloak-dev 服务和数据库 |
| 主题目录和配置 | TS-5, TS-6, TS-10 | 1-2h | 创建目录结构、theme.properties、dev 缓存参数 |
| 品牌化 CSS + Logo | TS-8, TS-9 | 2-4h | 设计品牌色调、覆盖 CSS、替换 Logo 和 favicon |
| Realm 主题启用 | TS-7 | 0.5h | 修改 noda-realm.json 或 init-realm.sh |
| 集成测试 | 全部 P1 | 1-2h | 验证双环境独立运行、主题生效、登录流程完整 |
| **v1.2 总计** | | **7-12h** | 约 1-2 个工作日 |

| Module | Features | Est. Hours | Notes |
|--------|----------|-----------|-------|
| 本地化 + 移动端 | DF-1, DF-2 | 2-3h | 翻译消息 + 媒体查询 |
| Dev realm 初始化 | DF-4 | 2-3h | 简化 dev 环境配置流程 |
| 验证脚本 | DF-7 | 1h | Shell 脚本自动检查 |
| **v1.2.x 总计** | | **5-7h** | 约 1 个工作日 |

## Feature-to-Pitfall Mapping

| Pitfall | Related Features | How Resolved |
|---------|-----------------|-------------|
| #1 主题缓存导致修改不生效 | TS-10 | Dev 环境添加缓存禁用参数，修改后立即可见 |
| #2 Dev/Prod 共享数据库 | TS-2 | 为 keycloak-dev 创建独立的 keycloak_dev 数据库 |
| #3 端口冲突 | TS-3 | Dev 使用 18080/18443/19000 端口映射 |
| #4 主题已部署但未生效 | TS-7 | 在 noda-realm.json 中添加 loginTheme 字段 |
| #5 theme.properties 继承错误 | TS-6 | 使用 `parent=keycloak`（v1 FreeMarker），不使用 v2 |
| #6 Hostname v2 配置错误 | TS-4 | Dev 环境清空 KC_HOSTNAME、关闭 strict 和 proxy |
| #7 Volume 目录不存在 | TS-5 | 在项目初始化中创建完整目录结构 |
| #8 CSP 阻止自定义 JS | AF-6 | 不使用自定义 JavaScript，纯 CSS 实现 |
| #9 Google OAuth dev 回调 | DF-4 | Dev 环境使用独立的 realm 配置和回调 URL |

## Key Design Decision: v1 vs v2 Theme

| 维度 | v1 FreeMarker (parent=keycloak) | v2 React (parent=keycloak.v2) |
|------|------|------|
| HTML 控制度 | 完全控制，可覆盖 .ftl 模板 | 不能修改模板，只能通过 CSS 变量和 messages |
| 自定义方式 | CSS + 消息 + 可选模板覆盖 | CSS 变量 + messages（极有限） |
| 文档和教程 | 丰富（社区积累多年） | 较少（Keycloak 22+ 才引入） |
| 未来兼容性 | Keycloak 26.x 完全支持 | 是未来方向 |
| 升级风险 | 模板文件可能需要更新 | CSS 变量更稳定 |
| 推荐场景 | 需要品牌化定制 | 只需要微调颜色/Logo |

**决策：使用 v1 FreeMarker 主题（`parent=keycloak`）**

理由：
1. 当前目标是品牌化定制（改颜色、Logo、文案），v1 完全满足且自由度更高
2. v1 的社区文档和教程更丰富，遇到问题更容易找到解决方案
3. 项目已验证 FreeMarker 模板的使用（init-realm.sh 中的 kcadm.sh 就在与 Keycloak API 交互）
4. v2 的 React 组件方式限制太多，如果将来需要更深度的定制（如添加自定义区域），仍然需要 v1
5. Keycloak 26.x 仍然完全支持 v1 主题，不存在弃用风险

## Sources

- Keycloak 26.2.3 Server Developer Guide -- Themes（https://www.keycloak.org/docs/26.2/server_development/#themes）-- 主题类型、theme.properties、继承、缓存控制
- Keycloak 26.2.3 Server Administration Guide -- Hostname v2（https://www.keycloak.org/docs/26.2/server_admin/#hostname）-- v2 SPI 配置规则、废弃选项
- Keycloak 26.2.3 Server Administration Guide -- Reverse Proxy（https://www.keycloak.org/docs/26.2/server_admin/#reverse-proxy）-- proxy 模式选择
- Noda 项目 CLAUDE.md -- Google 登录 8080 端口 5 层修复记录（已验证 Hostname v2 配置模式）
- Noda 项目 docker-compose.yml / docker-compose.dev.yml / docker-compose.prod.yml -- 现有 overlay 模式分析
- Noda 项目 services/keycloak/init-realm.sh / noda-realm.json -- 当前 realm 配置分析
- Noda 项目 docker-compose.dev.yml 中 postgres-dev 服务 -- 双实例模式参考

---
*Feature research for: Keycloak 双环境部署 + 自定义主题开发*
*Researched: 2026-04-11*
