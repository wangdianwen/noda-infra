# Project Research Summary

**Project:** Noda v1.5 开发环境本地化 + 基础设施 CI/CD
**Domain:** 单服务器 Docker Compose 基础设施运维 -- Jenkins CI/CD 蓝绿部署扩展
**Researched:** 2026-04-17
**Confidence:** MEDIUM-HIGH

## Executive Summary

Noda v1.5 是一个基础设施运维里程碑，目标是将开发环境数据库从 Docker 容器迁移到宿主机 PostgreSQL，并为基础设施服务（Keycloak、PostgreSQL、nginx、noda-ops）建立统一的 Jenkins CI/CD Pipeline。项目的核心模式已由 v1.4 验证：蓝绿部署通过 Nginx upstream include 切换实现零停机，`manage-containers.sh` + `pipeline-stages.sh` 通过环境变量参数化支持任意服务的蓝绿管理。v1.5 的主要工作是将这套模式从应用层扩展到基础设施层。

**重要发现：Jenkins 不使用 H2 数据库存储核心数据。** STACK.md 研究确认 Jenkins 2.x 的所有核心数据（jobs、builds、config、credentials）使用 XML + XStream 序列化存储在 `$JENKINS_HOME` 文件系统中。H2 只是嵌入式数据库驱动插件（安装率 0.043%），Jenkins 核心不依赖它。因此 PROJECT.md 中的 "Jenkins H2 -> PG 迁移" 需要重新定义：不是数据库迁移，而是安装 PostgreSQL 插件实现 fingerprint/build records 的外部存储 + 将 `$JENKINS_HOME` 纳入 B2 备份体系。这个认知修正直接影响 Phase 2 的范围和复杂度。

主要风险集中在三个方面：（1）Keycloak 蓝绿部署的数据库 schema 冲突（同版本安全，跨版本致命）；（2）基础设施 Pipeline 的循环依赖问题（Pipeline 重启 PostgreSQL 会导致 Jenkins 自身断连）；（3）移除 dev 容器可能破坏现有开发工作流。三个风险都有明确的缓解方案，但需要在 Roadmap 阶段安排中体现。

## Key Findings

### Recommended Stack

宿主机安装 Homebrew PostgreSQL 17（与 Docker 生产 postgres:17.9 版本一致），用于 Jenkins 持久化和本地开发数据库。基础设施 Pipeline 复用 v1.4 已验证的参数化 Jenkinsfile 模式，通过 `choice` 参数选择服务。Keycloak 蓝绿部署复用 `manage-containers.sh` 框架，共享同一 PostgreSQL 数据库。

**Core technologies:**
- **PostgreSQL 17 (Homebrew):** 宿主机开发数据库 + Jenkins 数据存储 -- 与 Docker 生产版本完全一致，pg_dump 无兼容问题
- **Jenkinsfile.infra:** 基础设施统一 Pipeline -- 参数化选择服务，复用 pipeline-stages.sh 函数库
- **Keycloak 蓝绿部署:** 复用 manage-containers.sh + upstream-keycloak.conf 动态切换 -- 与 findclass-ssr/noda-site 模式一致
- **setup-dev.sh:** 一键开发环境安装 -- Homebrew + 数据库初始化 + 环境变量配置

**Critical version requirements:**
- 必须使用 `brew install postgresql@17`（非 `brew install postgresql`，后者安装 18.x）
- Jenkins 2.541.3 要求 Java 17/21/25；2.555.1+ 仅支持 Java 21/25

### Expected Features

**Must have (table stakes):**
- **宿主机 PostgreSQL 安装与配置 (T1)** -- 开发环境用 Docker 跑数据库是反模式，版本必须与生产对齐
- **Jenkins 数据存储优化 (T2, 重新定义)** -- 安装 PostgreSQL 插件 + $JENKINS_HOME 备份策略，不是传统意义的数据库迁移
- **移除 postgres-dev / keycloak-dev 容器 (T3)** -- 本地 PG 替代后完全多余
- **统一基础设施 Pipeline (T4)** -- 当前基础设施完全手动部署，是运维自动化的核心缺失
- **Keycloak 蓝绿部署 (T5)** -- 生产环境 Keycloak 重启导致认证中断，蓝绿是零停机标准做法
- **部署前备份 + 健康检查 + 回滚 (T6)** -- 基础设施 Pipeline 的安全网
- **人工确认门禁 (T7)** -- 基础设施变更不可逆，必须有人确认

**Should have (competitive):**
- **一键安装脚本 (D1)** -- 5 分钟搭建完整开发环境
- **服务特定 Pipeline 阶段分发 (D2)** -- 不同服务不同部署策略
- **开发数据库种子数据自动化 (D3)** -- 本地 PG 初始化时自动创建测试数据
- **Jenkins PG 备份纳入 B2 (D4)** -- 避免成为备份盲区

**Defer (v2+):**
- Keycloak session 持久化 -- 用户量小，过度工程化
- PostgreSQL 蓝绿部署 -- 数据库状态在卷上，无意义
- Jenkins Configuration as Code (JCasC) -- 单服务器场景手动配置足够

### Architecture Approach

v1.5 引入三层架构：宿主机层（PostgreSQL + Jenkins）处理持久化和 CI/CD；Docker 层（postgres-prod、keycloak、nginx、noda-ops）处理生产服务；蓝绿管理层（manage-containers.sh + upstream include）处理零停机部署。新增的 `Jenkinsfile.infra` 通过参数化复用现有 `pipeline-stages.sh`，与 `Jenkinsfile`/`Jenkinsfile.noda-site` 保持一致的模式。Keycloak 蓝绿部署遵循与 findclass-ssr 完全相同的路径：env 模板 + docker run 容器 + upstream 切换 + 状态文件。

**Major components:**
1. **宿主机 PostgreSQL (Homebrew, port 5432)** -- jenkins_db + noda_dev，与 Docker 层隔离
2. **Jenkinsfile.infra** -- 参数化 Pipeline，支持 postgres/keycloak/nginx/noda-ops 四种服务
3. **Keycloak 蓝绿容器 (keycloak-blue/keycloak-green)** -- docker run 管理，共享 Docker postgres-prod 中的 keycloak_db
4. **setup-dev.sh** -- 一键安装开发环境，幂等设计

### Critical Pitfalls

1. **Jenkins 数据迁移理解偏差** -- STACK.md 确认 Jenkins 核心数据存储在文件系统（XML + XStream），不使用 H2 数据库。所谓 "H2 -> PG 迁移" 实际上是安装 PostgreSQL 插件用于 fingerprint 外置存储 + 文件系统备份策略优化。需要修正 FEATURES.md 和 ARCHITECTURE.md 中基于 "H2 迁移" 假设的复杂度评估。
2. **基础设施 Pipeline 循环依赖** -- Jenkins 迁移到 PG 后，Pipeline 重启 PostgreSQL 会导致 Jenkins 自身断连。解决方案：禁止 Pipeline 管理 PostgreSQL（手动维护），Pipeline 服务白名单中排除 postgres。
3. **Keycloak 蓝绿部署的 Schema 冲突** -- 同版本（26.2.3）蓝绿安全（schema 不变），但跨版本升级时新容器会执行 Liquibase 迁移导致旧容器崩溃。蓝绿部署仅适用于配置变更，版本升级必须用滚动替换。
4. **Keycloak 会话丢失** -- Infinispan 会话在 JVM 内存中，蓝绿切换后所有活跃用户被强制登出。接受此风险（用户量小），在维护窗口切换。
5. **移除 dev 容器破坏开发工作流** -- postgres-dev 的 Docker volume 中可能有开发数据，移除前需要迁移脚本。keycloak-dev 移除后开发者需要用生产 Keycloak 测试。

## Implications for Roadmap

基于研究，建议以下阶段结构。每个阶段的排序基于依赖关系和风险递增原则。

### Phase 1: 宿主机 PostgreSQL 安装与配置
**Rationale:** 所有后续功能的基础依赖。T2（Jenkins PG 配置）、T3（移除 dev 容器）都要求宿主机 PG 先就绪。纯新增操作，不影响现有服务。
**Delivers:** 运行中的 Homebrew PostgreSQL 17，包含 jenkins_db 和 noda_dev 数据库
**Addresses:** T1（宿主机 PG 安装）
**Avoids:** Pitfall 2（版本不匹配）-- 锁定 postgresql@17

### Phase 2: Jenkins 数据存储优化（重新定义）
**Rationale:** 紧跟 Phase 1，因为 Jenkins 是宿主机 PG 的主要消费者。但基于 STACK.md 的发现，这不是传统的数据库迁移，而是安装 PostgreSQL 插件 + 备份策略优化，复杂度低于原计划。
**Delivers:** Jenkins 使用本地 PG 存储部分数据 + $JENKINS_HOME 纳入 B2 备份
**Addresses:** T2（重新定义为 Jenkins PG 插件配置 + 备份策略）
**Avoids:** Pitfall 1（数据丢失）-- 完整备份 $JENKINS_HOME，保留回滚方案

### Phase 3: 移除 postgres-dev / keycloak-dev 容器
**Rationale:** 依赖 Phase 1 宿主机 PG 替代开发数据库。必须在本地开发流程验证通过后再移除。
**Delivers:** 简化的 docker-compose.dev.yml（仅保留 nginx 开发配置）
**Addresses:** T3（移除 dev 容器）+ D3（种子数据迁移到本地 PG）
**Avoids:** Pitfall 3（破坏开发工作流）-- 先验证本地 PG 可替代，再移除容器

### Phase 4: Keycloak 蓝绿部署基础设施
**Rationale:** 与 PG 迁移无关，可独立进行。但需要在 Pipeline 框架之前完成，因为 Pipeline 要集成 Keycloak 蓝绿逻辑。这是 v1.5 最复杂的单个功能。
**Delivers:** keycloak-blue/green 容器 + upstream-keycloak.conf 动态切换 + env-keycloak.env 模板
**Addresses:** T5（Keycloak 蓝绿部署）
**Avoids:** Pitfall 4（Schema 冲突）-- 同版本蓝绿安全；Pitfall 5（会话丢失）-- 维护窗口切换

### Phase 5: 统一基础设施 Pipeline
**Rationale:** 依赖 Phase 4（Keycloak 蓝绿基础设施已就绪）。所有部署策略（蓝绿/滚动替换）在 Pipeline 中统一编排。
**Delivers:** Jenkinsfile.infra + pipeline-stages.sh 扩展 + Jenkins Job 配置
**Addresses:** T4（统一 Pipeline）+ T6（备份检查/健康检查/回滚）+ T7（人工确认门禁）+ D2（服务分发）
**Avoids:** Pitfall 6（循环依赖）-- Pipeline 服务白名单排除 postgres

### Phase 6: 一键开发环境脚本
**Rationale:** 独立于核心功能，但整合了前面所有变更（宿主机 PG、移除 dev 容器）。放在最后可以确保脚本反映最终状态。
**Delivers:** setup-dev.sh（install/init-db/status/reset 子命令）
**Addresses:** D1（一键安装）
**Avoids:** Pitfall 7（非幂等）-- 架构检测 + 幂等检查函数

### Phase Ordering Rationale

1. **Phase 1 是所有 PG 相关功能的前置条件** -- T2、T3 都依赖宿主机 PG
2. **Phase 2 紧跟 Phase 1** -- Jenkins 是宿主机 PG 的第一个消费者，迁移后才能验证 PG 稳定性
3. **Phase 3 在 Phase 1 之后** -- 需要宿主机 PG 替代 postgres-dev 的开发数据库功能
4. **Phase 4 可与 Phase 2/3 并行** -- Keycloak 蓝绿与 PG 迁移无关
5. **Phase 5 在 Phase 4 之后** -- Pipeline 需要所有部署策略已验证
6. **Phase 6 最后** -- 开发环境脚本整合所有变更

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2:** Jenkins PostgreSQL 插件的具体配置方式需要验证。STACK.md 确认 Jenkins 不使用 H2 存储核心数据，但 "安装 PG 插件改善存储" 的具体操作步骤需要参考 Jenkins 官方文档确认。研究显示两种可能路径：简单路径（仅安装插件 + JDBC 配置）和复杂路径（JCasC + 远程存储插件）。需要在 Plan 阶段确认。
- **Phase 4:** Keycloak 蓝绿容器启动参数（15+ 环境变量）和 Infinispan 缓存行为需要实际测试验证。研究推荐 "同版本 start 模式 + 短暂共存" 方案，但缓存集群的具体行为（如连接数翻倍、schema migration 锁）需要在测试环境中观察。
- **Phase 5:** Pipeline 参数化分发（不同服务不同策略）的 Jenkinsfile 结构需要设计。虽然 v1.4 已有参数化模式（findclass-ssr/noda-site），但基础设施服务有本质区别（有状态/无状态、蓝绿/滚动），需要在 Plan 阶段确定分发策略。

Phases with standard patterns (skip research-phase):
- **Phase 1:** Homebrew PostgreSQL 安装是标准化流程，文档充分
- **Phase 3:** Docker Compose 文件编辑和数据迁移，模式清晰
- **Phase 6:** 一键安装脚本，参考现有 setup-jenkins.sh 模式

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Homebrew PG 安装、Jenkins 文件系统存储、Keycloak 版本兼容性均有官方文档验证 |
| Features | MEDIUM | T2（Jenkins H2 -> PG）的定义需要重新评估。FEATURES.md 基于错误的 "H2 数据库迁移" 假设，需要根据 STACK.md 的发现修正范围和复杂度 |
| Architecture | HIGH | 基于项目代码库完整分析，蓝绿框架已在 v1.4 验证，扩展模式清晰 |
| Pitfalls | MEDIUM | Pitfall 1（Jenkins H2 迁移数据丢失）基于错误的假设需要降级或重写；Pitfall 6（循环依赖）是真实且严重的问题；其他 Pitfall 基于项目代码库分析，可靠性高 |

**Overall confidence:** MEDIUM-HIGH

### Gaps to Address

- **Jenkins PG 集成范围待确认:** STACK.md 确认 Jenkins 核心数据不使用 H2，但 PROJECT.md 的 "Jenkins H2 -> PG 迁移" 需求仍列在 Active 中。需要在 Roadmap 规划前与用户确认：是简化为 "安装 PG 插件 + 备份策略优化"（推荐），还是坚持某种形式的数据库集成。这直接影响 Phase 2 的范围。
- **Jenkins PostgreSQL 插件的实际价值:** 安装率仅 1.76%，Jenkins 社区对此插件的讨论较少。需要确认安装此插件后具体改善什么（fingerprint 存储？build records？），还是仅仅将 $JENKINS_HOME 备份到 B2 就足够。
- **Keycloak 蓝绿的 findclass-ssr 联动:** findclass-ssr 的 `KEYCLOAK_INTERNAL_URL` 当前硬编码为 `http://noda-infra-keycloak-prod:8080`。Keycloak 蓝绿后容器名变为 `keycloak-{color}`，需要同步更新 findclass-ssr 的环境变量。ARCHITECTURE.md 提到了这个问题但未给出最终方案。
- **本地开发数据库选择:** ARCHITECTURE.md 推荐本地开发应用连接 Docker postgres-prod（方案 A），但这要求 Docker 容器必须运行。是否需要为开发环境提供纯宿主机方案（方案 B）需要确认。

## Sources

### Primary (HIGH confidence)
- 项目代码库: `docker/docker-compose.yml`, `docker/docker-compose.dev.yml`, `config/nginx/snippets/upstream-keycloak.conf`, `scripts/manage-containers.sh`, `scripts/pipeline-stages.sh`, `jenkins/Jenkinsfile`, `jenkins/Jenkinsfile.noda-site` -- 架构和集成点分析
- [Jenkins Persistence Documentation](https://www.jenkins.io/doc/developer/persistence/) -- 确认 Jenkins 使用文件系统存储（XML + XStream），不使用 H2
- [Jenkins H2 Database Plugin](https://plugins.jenkins.io/database-h2/) -- 安装率 0.043%，仅作为 database 插件的 H2 驱动
- [Homebrew postgresql@17 Formula](https://formulae.brew.sh/formula/postgresql@17) -- 版本 17.9，支持 Apple Silicon
- [Keycloak Configuration](https://www.keycloak.org/server/configuration) -- 生产模式配置、Infinispan 缓存行为
- [Keycloak Database Configuration](https://www.keycloak.org/server/db) -- PostgreSQL 14-18 支持

### Secondary (MEDIUM confidence)
- Jenkins PostgreSQL 插件配置方式 -- 训练数据，未经在线文档验证
- Keycloak Infinispan 多实例行为 -- Keycloak 文档描述，实际行为需测试验证
- Jenkins H2 到 PG 迁移的具体步骤 -- 社区实践，Jenkins 官方无正式迁移指南

### Tertiary (LOW confidence)
- Jenkins database-postgresql 插件的具体功能和限制 -- 安装率 1.76%，文档稀少
- Apple Silicon 与 Intel Mac 在 PostgreSQL Homebrew 安装上的差异 -- 推断自 Homebrew 通用行为

---
*Research completed: 2026-04-17*
*Ready for roadmap: yes*
