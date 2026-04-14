# Project Research Summary

**Project:** Noda v1.4 CI/CD 零停机部署
**Domain:** Jenkins CI/CD + Docker Compose 蓝绿部署（单服务器基础设施）
**Researched:** 2026-04-14
**Confidence:** HIGH

## Executive Summary

本项目为现有的 Docker Compose 单服务器基础设施（PostgreSQL、Keycloak、Nginx、findclass-ssr）添加 Jenkins CI/CD 流水线和蓝绿部署能力。核心目标是消除当前 `docker compose up --force-recreate` 带来的 30-60 秒停机窗口，实现零停机部署。研究结论明确：Jenkins 宿主机原生安装（非容器化）+ Nginx upstream include 文件切换 + Docker `docker run` 独立管理蓝绿容器，是单服务器场景下最简洁可靠的方案。

推荐的技术路径分五步递进：Jenkins 安装 -> Nginx 配置重构 -> 蓝绿核心脚本 -> Pipeline 集成 -> 清理与文档。每个步骤独立可验证，前一步失败不阻塞回退。关键约束是所有蓝绿操作仅限于无状态应用容器（findclass-ssr），基础设施服务（PostgreSQL、Keycloak、Nginx）保持现有 compose 部署方式不变。

主要风险集中在三个领域：(1) 蓝绿切换时 Nginx 配置语法错误导致全站不可用，需通过 `nginx -t` 前置验证 + 原子写文件防止；(2) Docker 镜像累积导致磁盘耗尽，Pipeline 必须内置清理步骤；(3) 数据库迁移破坏蓝绿共存，需采用 Expand-Contract 模式确保向后兼容。三层回滚机制（健康检查失败不切换 -> E2E 验证失败自动切回 -> 手动紧急回滚脚本）覆盖所有故障场景。

## Key Findings

### Recommended Stack

Jenkins LTS 2.541.x 宿主机原生安装，通过 systemd 管理，直接访问 Docker socket。配合 Nginx upstream include 文件切换实现蓝绿流量路由。核心部署逻辑放在 bash 脚本中，Jenkinsfile 仅编排调用，保证可手动执行。所有结论基于项目代码库深度分析和 Jenkins/Nginx 官方文档，置信度高。

**Core technologies:**
- **Jenkins LTS 2.541.3:** CI/CD 控制器，Declarative Pipeline 语法，宿主机原生安装避免 Docker-in-Docker 安全风险
- **OpenJDK 21 (Temurin):** Jenkins 运行时，LTS 2.541.x 支持 Java 17/21/25，Java 21 是当前最优选择
- **Nginx upstream include 切换:** 蓝绿流量路由，通过重写 include 文件 + `nginx -s reload` 实现毫秒级零停机切换
- **Docker `docker run` 独立管理:** 蓝绿容器脱离 compose 生命周期管理，实现独立启停控制；compose 仅用于 `docker compose build`
- **Bash 部署脚本:** 核心部署逻辑（`blue-green-deploy.sh`），Jenkinsfile 仅编排调用，可脱离 Jenkins 独立执行

### Expected Features

研究将特性分为三层：Table Stakes（部署流程不可靠不安全则缺少的必备项）、Differentiators（显著提升部署安全性的增强项）、Anti-Features（单服务器场景下的过度设计，明确不做）。

**Must have (table stakes):**
- **Pipeline 阶段化 (T1):** Build -> Test -> Deploy -> Verify 四阶段骨架，Jenkins Declarative Pipeline 原生支持
- **镜像 Git SHA 标签 (T2):** 版本可追溯，蓝绿区分新旧镜像的基础，替换当前 `findclass-ssr:latest`
- **构建失败阻止部署 (T3):** Jenkins 天然支持，`sh` 步骤失败即中止 Pipeline
- **HTTP E2E 健康检查 (T4):** 切换前验证新容器 + 切换后验证完整链路，不仅仅是 Docker HEALTHCHECK
- **自动回滚 (T5):** 蓝绿模式下等于"不切换流量"，旧容器持续运行；三层回滚覆盖所有场景
- **Jenkins 宿主机安装/卸载脚本 (T7):** 干净的安装和完全卸载能力，是所有 Pipeline 特性的基础

**Should have (competitive):**
- **蓝绿部署零停机切换 (D1):** v1.4 核心价值，消除 30-60 秒停机窗口，复杂度最高
- **Lint + 单元测试门禁 (D2):** 需要 noda-apps 仓库配合，v1.4.x 追加
- **Cloudflare CDN 缓存清除 (D6):** 部署后用户看到新版本，需要 CF API Token 配置

**Defer (v2+):**
- **部署通知 (D5):** 单人维护场景价值低
- **多环境 Pipeline (dev/staging/prod):** 当前 dev 环境按需手动启动
- **基础设施服务蓝绿:** PostgreSQL/Keycloak 有状态，复杂度远高于无状态应用

### Architecture Approach

蓝绿部署采用"构建与运行分离"模式：`docker compose build` 仅用于构建镜像，`docker run` 独立管理蓝绿容器生命周期。Nginx 通过 `include` 文件引用 upstream 定义，Pipeline 通过原子写文件 + `nginx -s reload` 实现流量切换。状态文件 `/var/lib/noda-deploy/current_color` 追踪活跃颜色。基础设施服务（PostgreSQL、Keycloak、Nginx、noda-ops）保持现有 compose 部署不变。

**Major components:**
1. **Jenkins (宿主机 systemd):** CI/CD 编排，Pipeline 管理，直接操作 Docker socket
2. **蓝绿部署脚本 (`blue-green-deploy.sh`):** 核心部署逻辑，包括容器启停、健康检查、nginx 切换、状态管理
3. **Nginx upstream include 文件 (`upstream-findclass.conf`):** 流量路由入口，Pipeline 动态生成和切换
4. **蓝绿状态文件 (`/var/lib/noda-deploy/current_color`):** 纯文本记录活跃颜色，Pipeline 各阶段读写
5. **Jenkinsfile:** Pipeline 骨架，仅编排 stage 调用，不包含复杂逻辑

### Critical Pitfalls

1. **Docker Socket 挂载导致容器逃逸:** Jenkins 必须宿主机原生安装，绝不使用 Docker 容器运行 + socket 挂载模式。这是安全底线，Phase 1 就要正确决策。
2. **蓝绿切换 Nginx 配置语法错误:** 切换前必须执行 `docker exec nginx nginx -t` 验证配置，失败则不执行 reload。使用原子写（写临时文件 + mv）防止配置文件损坏。
3. **健康检查假阳性:** Docker HEALTHCHECK 通过不等于应用就绪。必须做 HTTP E2E 检查（curl 返回 200 + 响应时间合理），不仅仅是 TCP connect。
4. **Pipeline 部分失败状态不一致:** 维护状态文件追踪活跃颜色，每个阶段操作必须幂等，`post { failure }` 中根据状态文件判断回滚策略。旧容器在 E2E 验证通过后才删除。
5. **磁盘空间耗尽:** Pipeline 末尾必须有清理步骤（`docker image prune` + `docker builder prune`），定期 cron 清理，磁盘监控超过 85% 告警。

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: Jenkins 安装与基础配置
**Rationale:** Jenkins 是所有 Pipeline 特性的基础，必须最先安装验证。独立于应用逻辑，风险最低。
**Delivers:** 可运行的 Jenkins 实例，可访问 Docker，Pipeline Job 骨架
**Addresses:** T7 (Jenkins 安装脚本), T1 (Pipeline 阶段化骨架)
**Avoids:** Pitfall 1 (Docker Socket 安全) -- 宿主机原生安装
**Research flag:** 标准模式，Jenkins 官方安装文档覆盖完整，无需额外研究

### Phase 2: Nginx 配置重构
**Rationale:** 蓝绿部署依赖 Nginx upstream 动态切换，需要先将 upstream 定义从 `default.conf` 抽离到独立 include 文件。这是蓝绿的流量路由基础设施。
**Delivers:** `upstream-findclass.conf` include 文件，nginx reload 验证通过，现有流量不受影响
**Addresses:** 蓝绿部署的 Nginx 基础改造
**Avoids:** Pitfall 2 (蓝绿容器端口冲突) -- upstream 指向可动态切换的容器名
**Research flag:** 标准模式，Nginx include + reload 是成熟方案

### Phase 3: 蓝绿部署核心脚本
**Rationale:** 核心部署逻辑（容器启停、健康检查、nginx 切换、状态管理）先在 bash 脚本中实现并手动验证，再集成到 Jenkins。降低调试复杂度。
**Delivers:** `blue-green-deploy.sh` + `rollback-findclass.sh`，手动测试蓝绿切换和回滚正常工作
**Addresses:** T2 (Git SHA 标签), T4 (HTTP 健康检查), T5 (自动回滚), D1 (蓝绿部署核心)
**Uses:** Docker `docker run` 独立管理容器，Nginx upstream include 切换，状态文件
**Avoids:** Pitfall 3 (数据库迁移兼容), Pitfall 4 (健康检查假阳性), Pitfall 5 (Pipeline 部分失败)
**Research flag:** 需要研究 -- 健康检查策略（重试次数、超时、E2E 验证 URL）需要在实际环境中调优

### Phase 4: Jenkins Pipeline 集成
**Rationale:** 核心部署逻辑验证通过后，包装进 Jenkinsfile 实现自动化。包括完整的 stage 编排、E2E 健康检查、自动回滚。
**Delivers:** 可运行的 Jenkins Pipeline，手动触发 -> 零停机部署 -> 自动回滚
**Addresses:** T1 (Pipeline 阶段化), T3 (构建失败阻止部署), T6 (部署前备份)
**Uses:** Jenkins Declarative Pipeline, `post { failure }` 回滚
**Avoids:** Pitfall 5 (Pipeline 部分失败) -- 状态文件 + 幂等操作 + failure 回滚
**Research flag:** 标准模式，Jenkins Declarative Pipeline 文档覆盖完整

### Phase 5: 清理、迁移与文档
**Rationale:** 部署流程稳定后，迁移环境变量管理、添加镜像清理步骤、保留旧脚本作为备选入口、更新文档。
**Delivers:** 完整的 CI/CD 系统，镜像清理机制，文档更新
**Addresses:** 磁盘空间管理，现有脚本迁移映射，CLAUDE.md 部署文档更新
**Avoids:** Pitfall 6 (磁盘空间耗尽) -- Pipeline 末尾清理 + 定期 cron
**Research flag:** 标准模式

### Phase Ordering Rationale

- **依赖关系驱动：** Jenkins (Phase 1) -> Nginx 改造 (Phase 2) -> 蓝绿脚本 (Phase 3) -> Pipeline 集成 (Phase 4)，每一步依赖前一步的产出
- **风险递进：** 先做独立的基础设施变更（Jenkins 安装），再做应用层改造（Nginx/蓝绿），最后做流程集成（Pipeline）
- **可回退性：** Phase 1-2 都不影响现有部署流程，Phase 3 手动验证通过后才进入 Phase 4 自动化，任何阶段失败都可以安全回退
- **蓝绿脚本先于 Pipeline：** 核心 bash 脚本可脱离 Jenkins 独立调试和执行，比在 Jenkinsfile (Groovy) 中调试更高效

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 3:** 健康检查策略需要根据实际 findclass-ssr 冷启动时间调优（重试间隔、超时阈值、E2E 验证 URL）
- **Phase 3:** 环境变量从 `config/secrets.sops.yaml` 到 `docker run` 的传递方案需要设计
- **Phase 4:** Jenkins 与 GitHub SSH 集成（deploy key 配置、workspace 路径映射）需要实际调试

Phases with standard patterns (skip research-phase):
- **Phase 1:** Jenkins 宿主机安装，官方文档完整覆盖
- **Phase 2:** Nginx include + reload，成熟的标准模式
- **Phase 5:** 镜像清理 + 文档更新，无需研究

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Jenkins LTS + Nginx upstream 切换 + Docker run，官方文档 + 社区最佳实践充分验证 |
| Features | HIGH | 特性列表基于项目代码库深度分析，依赖关系和优先级明确 |
| Architecture | HIGH | 组件边界清晰，数据流完整，反模式已识别。基于项目现有代码的直接分析 |
| Pitfalls | MEDIUM | 6 个 Critical Pitfalls 基于代码分析和训练知识，Web 搜索遭遇限流，部分结论未经在线验证（特别是磁盘空间增长估算、健康检查超时阈值） |

**Overall confidence:** HIGH

### Gaps to Address

- **健康检查超时调优：** 研究建议 90s 超时 + 5s 间隔（最多 18 次重试），但实际 findclass-ssr 冷启动时间需要 Phase 3 实测确认
- **环境变量传递方案：** 从 sops 加密文件到 `docker run -e` 的传递链路需要在 Phase 3 设计和验证
- **Jenkins 端口冲突：** Jenkins 默认 8080 端口与 Keycloak 内部端口冲突（虽然 Keycloak 不暴露外部端口），需要在 Phase 1 确认是否需要修改 Jenkins 端口
- **noda-site 蓝绿扩展：** 当前仅 findclass-ssr 纳入蓝绿，noda-site 的蓝绿部署模式需要单独评估

## Sources

### Primary (HIGH confidence)
- 项目代码库：`docker/docker-compose.app.yml`, `docker/docker-compose.yml`, `docker/docker-compose.prod.yml` -- 现有服务定义、网络配置、健康检查
- 项目代码库：`config/nginx/conf.d/default.conf`, `config/nginx/nginx.conf` -- upstream 定义、include 机制验证
- 项目代码库：`scripts/deploy/deploy-apps-prod.sh`, `scripts/deploy/deploy-infrastructure-prod.sh` -- 现有部署流程、回滚逻辑
- 项目代码库：`scripts/lib/health.sh`, `deploy/Dockerfile.findclass-ssr` -- 健康检查实现、构建流程
- Jenkins 官方文档：LTS 安装、Declarative Pipeline、Credentials Store、systemd 管理
- Jenkins Pipeline Plugin (workflow-aggregator) -- 89.7% 安装率，Declarative Pipeline 标配
- Nginx 官方文档：`nginx -s reload` 平滑重载机制，零停机原理

### Secondary (MEDIUM confidence)
- Jenkins Pipeline 最佳实践 -- 使用 `sh` 步骤而非 Groovy 逻辑
- Docker BuildKit 缓存管理 -- `docker builder prune` 清理策略
- 蓝绿部署 Expand-Contract 模式 -- 数据库迁移兼容性最佳实践
- Prisma `migrate deploy` -- 只执行 forward 迁移，与蓝绿回滚策略的关系

### Tertiary (LOW confidence)
- 磁盘空间增长估算 -- 基于构建层大小推断，需实际监控验证
- Cloudflare API 缓存清除 -- 未深入研究 API 细节，Phase 5 前需补充

---
*Research completed: 2026-04-14*
*Ready for roadmap: yes*
