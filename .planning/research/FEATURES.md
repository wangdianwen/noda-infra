# iStoreOS Docker 迁移功能研究

**领域:** ARM64 低内存服务器 Docker 迁移
**研究日期:** 2026-05-17
**综合置信度:** HIGH

## 执行摘要

iStoreOS Docker 迁移的核心挑战是在 3.77GB RAM 的 ARM64 设备上运行原本运行在 8GB+ Mac 上的完整服务栈。研究确认的关键策略是 **"分层迁移、资源共享、内存优化"** —— 基础设施层（PostgreSQL、Keycloak、Nginx、Cloudflare Tunnel）整体迁移，应用层（findclass-ssr prod+pre-prod）采用蓝绿部署，通过内存限制和共享架构将总内存控制在 2.5GB 以内。

迁移采用 **Jenkins SSH 远程部署模式**，Mac 作为控制节点，r4s 作为执行节点，保持现有部署逻辑不变。备份策略完全迁移到 r4s，利用 Docker volume 特性实现数据库持久化。

研究识别出 **5 个关键迁移陷阱**，其中 2 个具有 HIGH 级别影响：Jenkins SSH 连接稳定性（网络中断导致部署失败）和 PostgreSQL 数据一致性（pg_dump 在容器内执行的时机）。这些必须在迁移方案中建立防护机制。

## 关键发现

### 推荐技术方案

迁移保持现有技术栈，针对 ARM64 低内存环境进行优化配置。不引入新组件，通过配置调整实现适应。

**核心技术决策：**

- **SSH 远程执行架构：** Jenkins 在 Mac，通过 SSH 连接 r4s 执行 `docker compose` 命令，保持现有脚本逻辑
- **Docker Compose Overlay 模式：** 使用 `docker-compose.r4s.yml` 覆盖内存限制和端口映射，继承所有基础配置
- **内存预算分配：** PostgreSQL 768M + Keycloak 640M + Nginx 64M + noda-ops 256M + findclass-ssr 1G = 总计 2.7GB（预留 1GB 缓冲）
- **ARM64 镜像兼容：** Mac M4 和 r4s 都是 ARM64，无需重新构建镜像，直接复用
- **独立 Docker Root：** `/mnt/mmc1-4/docker`（54.8GB 可用），避免与 iStoreOS 系统冲突
- **Swap 文件机制：** 2GB Swap 作为 OOM 缓冲，防止内存不足导致服务崩溃

### 功能优先级

**必须实现（Table Stakes，P1）：**

- **基础设施整体迁移** -- PostgreSQL + Keycloak + Nginx + Cloudflare Tunnel 全部迁移到 r4s
- **应用蓝绿部署迁移** -- findclass-ssr prod 和 pre-prod 蓝绿容器组迁移到 r4s
- **Jenkins SSH 远程部署** - Pipeline 改造为通过 SSH 在 r4s 执行 docker compose 命令
- **备份策略完全迁移** -- pg_dump + B2 上传完全在 r4s 执行，Mac 仅触发
- **内存优化配置** -- 所有服务设置 memory limits + compact logging + tmpfs 优化
- **健康检查机制** - 复用现有 health check，增加 r4s 特定的网络连通性检查
- **回滚机制** - 保持现有 rollback 逻辑，增加 SSH 连接失败回滚

**建议实现（Differentiators，P2）：**

- **监控集成** - 在 r4s 上部署 Prometheus agent，收集容器资源使用数据
- **自动化健康检查** - 定期验证 r4s 服务连通性，预检内存使用
- **镜像缓存策略** - r4s 本地缓存常用镜像，减少网络传输
- **备份验证** - 自动下载并验证备份文件完整性

**推迟到 v2+（P3）：**

- **自动扩容** - 根据内存使用自动调整容器资源（需要深入研究）
- **多节点备份** - 将备份文件同步到多个存储位置（增加复杂度）
- **性能基准测试** - 建立性能基准，量化迁移前后对比

### 架构方案

迁移采用"控制与执行分离"架构：Mac 作为控制中心（Jenkins + 代码库），r4s 作为执行节点（Docker 运行）。

**核心组件关系：**

1. **Jenkins (Mac)** -- Pipeline 控制中心，通过 SSH 连接 r4s 执行部署命令
2. **Docker Compose (r4s)** -- 执行层，使用 `-f base -f prod -f r4s` 组合配置
3. **PostgreSQL (r4s)** -- 数据持久化，使用独立 Docker volume + 768M 内存限制
4. **Keycloak (r4s)** -- 认证服务，同实例共享数据库，640M 内存限制
5. **Nginx (r4s)** -- 反向代理，高端口映射（8080/8443）避免与 iStoreOS 冲突
6. **Cloudflare Tunnel (r4s)** -- 外部访问，保持现有 token 配置
7. **应用容器 (r4s)** -- findclass-ssr 蓝绿组，1G 内存限制，read_only 模式

**关键数据流：**
```
浏览器 -> Cloudflare -> r4s:8080 -> Nginx -> findclass-ssr-{color}:3000
  -> DATABASE_URL -> r4s postgres:5432 (noda_prod 数据库)
  -> KEYCLOAK_REALM -> r4s keycloak:8080 (noda realm)
```

**迁移步骤流程：**
```
1. 准备 r4s 环境（SSH + Docker + 网络）
2. 迁移基础设施（docker-compose up postgres/keycloak/nginx/noda-ops）
3. 验证基础设施连通性
4. 迁移应用（蓝绿部署，先 prod 后 pre-prod）
5. 配置 Cloudflare 域名路由
6. 切换生产流量
```

### 关键陷阱

1. **SSH 连接不稳定性** -- r4s 通过 SSH 连接执行部署，网络抖动可能导致命令执行失败。防护方案：SSH 连接重试机制（3次重试）+ 命令执行状态验证 + 超时控制（每命令 5 分钟）

2. **PostgreSQL 数据迁移时机** -- pg_dump 在容器内执行时，如果容器重启或内存不足可能导致数据不一致。防护方案：迁移前强制检查点 + 使用 `--format=directory` 增量备份 + 多次备份验证

3. **内存不足 OOM** -- r4s 仅 3.77GB RAM，多个服务同时启动可能触发 OOM。防护方案：渐进式启动（先基础设施后应用）+ 内存监控 + Swap 预热 + docker stats 实时监控

4. **ARM64 架构兼容性** -- 虽然都是 ARM64，但内核版本差异可能导致性能问题。防护方案：性能基准测试 + 监控 CPU 使用率 + 调整 CPU 亲和性

5. **端口冲突** -- iStoreOS 自带管理界面使用 80/443，Nginx 需要映射到高端口。防护方案：使用 8080/8443 端口 + 确保防火墙规则正确 + Cloudflare Tunnel 配置更新

## 对路线图的影响

基于研究发现的依赖关系和风险分布，建议以下阶段结构：

### Phase 1: r4s 环境准备

**理由：** 所有后续阶段都依赖 SSH 连接、Docker 运行环境和基础网络配置就位。这是最基础的阶段，可以独立验证连接和基本功能。

**交付物：** SSH 免密登录可用 + Docker Compose 可以在 r4s 正常执行 + 基础网络连通性验证通过

**覆盖功能：** SSH 远程执行架构、Docker Root 配置、Swap 文件机制

**需要规避的陷阱：** SSH 连接不稳定性（Pitfall 1）、ARM64 架构兼容性（Pitfall 4）

**涉及文件：**
- 修改：`scripts/r4s/setup-ssh.sh`（添加连接重试机制）
- 新增：`scripts/r4s/verify-connection.sh`（SSH 连接测试）
- 修改：`scripts/r4s/setup-swap.sh`（增加 Swap 预热）

### Phase 2: 基础设施迁移

**理由：** PostgreSQL、Keycloak、Nginx、Cloudflare Tunnel 是所有应用的基础，必须先确保基础设施稳定运行。这个阶段风险较低，因为组件都已成熟运行。

**交付物：** 所有基础设施服务在 r4s 正常运行 + 数据一致性验证通过 + 外部访问可达

**覆盖功能：** 基础设施整体迁移、备份策略迁移、内存优化配置

**需要规避的陷阱：** PostgreSQL 数据迁移时机（Pitfall 2）、内存不足 OOM（Pitfall 3）

**涉及文件：**
- 修改：`docker/docker-compose.r4s.yml`（基础设施内存限制）
- 新增：`scripts/infra-migrate.sh`（基础设施迁移脚本）
- 修改：`deploy/Dockerfile.noda-ops`（ARM64 优化）

### Phase 3: 应用迁移

**理由：** 应用迁移依赖基础设施就位，且需要保持零停机。蓝绿部署机制已经成熟，主要需要适配 SSH 执行环境。

**交付物：** findclass-ssr prod 和 pre-prod 在 r4s 成功运行 + 蓝绿切换功能正常 + 健康检查通过

**覆盖功能：** 应用蓝绿部署迁移、健康检查机制、回滚机制

**涉及文件：**
- 修改：`jenkins/Jenkinsfile.apps`（添加 SSH 执行步骤）
- 新增：`scripts/app-migrate.sh`（应用迁移脚本）
- 修改：`scripts/manage-containers.sh`（SSH 远程执行支持）

### Phase 4: 验证与优化

**理由：** 核心功能迁移完成后进行全面验证和性能优化。监控和自动化检查功能在此阶段加入。

**交付物：** 完整端到端验证通过 + 性能基线建立 + 监控系统就位

**覆盖功能：** 监控集成、自动化健康检查、镜像缓存策略

**涉及文件：**
- 新增：`scripts/monitoring/r4s-resource-check.sh`
- 新增：`scripts/validate-migration.sh`
- 修改：`CLAUDE.md`（更新部署流程文档）

### 阶段排序理由

- **Phase 1 先行**是因为 SSH 连接是所有远程操作的基础，没有连接后续都无法进行
- **Phase 2 在 Phase 3 之前**是因为应用依赖数据库和认证服务等基础设施
- **Phase 4 放在最后**是因为验证和优化不阻塞核心迁移，可以在功能稳定后补充
- **渐进式迁移**降低风险，每个阶段都可以独立验证和回滚

### 研究标记

需要更深入研究的阶段：
- **Phase 2：** PostgreSQL 数据迁移的具体方法需要确定是使用 pg_dump 还是 volume 直接复制
- **Phase 3：** 蓝绿部署在 SSH 远程执行时的网络延迟影响需要评估

模式成熟、可跳过研究阶段的：
- **Phase 1 SSH 配置：** 沿用现有 SSH 最佳实践，文档充分
- **Phase 4 监控：** 使用标准 Prometheus + Grafana 组合，方案成熟

## 置信度评估

| 领域 | 置信度 | 说明 |
|------|--------|------|
| 技术栈 | HIGH | 不引入新组件，基于现有 Docker Compose + Jenkins 架构，仅做环境适配 |
| 功能范围 | HIGH | 迁移边界清晰，Table Stakes 和 Anti-Features 定义明确，复用现有功能 |
| 架构方案 | HIGH | 控制与执行分离架构有充分参考，SSH 远程执行是成熟模式 |
| 陷阱识别 | HIGH | 5 个陷阱基于 ARM64 低内存设备特性和远程部署常见问题分析 |

**综合置信度：HIGH**

### 需要解决的缺口

- **PostgreSQL 迁移方法：** 需要在 Phase 2 确定使用 pg_dump 还是 volume 直接复制，建议先测试性能差异
- **SSH 连接重试策略：** 需要确定具体的重试次数和间隔，建议 Phase 1 进行压力测试
- **内存监控阈值：** 需要确定触发警告和告警的具体内存使用百分比，建议参考 80% 警告、90% 告警
- **蓝绿部署网络延迟：** SSH 执行可能增加部署时间，需要评估是否影响用户体验

## Feature Dependencies

```
[r4s 环境准备]
    ├──requires──> [SSH 免密登录配置]
    ├──requires──> [Docker Root 独立配置]
    └──requires──> [Swap 文件机制]

[基础设施迁移]
    ├──requires──> [r4s 环境准备]
    ├──requires──> [PostgreSQL 数据迁移]
    ├──requires──> [Keycloak 配置同步]
    └──requires──> [Nginx + Cloudflare Tunnel 迁移]

[应用迁移]
    ├──requires──> [基础设施迁移]
    ├──requires──> [Jenkins SSH 远程部署改造]
    ├──requires──> [蓝绿部署脚本适配]
    └──requires──> [健康检查机制验证]

[验证与优化]
    ├──requires──> [应用迁移]
    ├──requires──> [性能基准测试]
    └──enhances──> [监控系统部署]
```

### Dependency Notes

- **基础设施迁移 requires r4s 环境准备：** Docker 和 SSH 必须先就位，否则无法执行部署命令
- **应用迁移 requires 基础设施迁移：** 应用容器依赖数据库、认证等基础设施服务
- **Jenkins SSH 远程部署改造 requires r4s 环境准备：** 需要先验证 SSH 连接可用
- **验证与优化 enhances 所有功能：** 监控系统不是前置条件，但能提升整体可靠性

## Table Stakes vs Differentiators

### Table Stakes（必须实现的基础功能）

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **SSH 远程执行架构** | 没有远程执行能力，迁移无法实现 | MEDIUM | Jenkins 通过 SSH 在 r4s 执行 docker compose，保持现有脚本逻辑 |
| **基础设施整体迁移** | 数据库和认证服务必须迁移，否则应用无法运行 | HIGH | PostgreSQL + Keycloak + Nginx + Cloudflare Tunnel 全部迁移 |
| **应用蓝绿部署迁移** | 生产环境需要零停机部署 | MEDIUM | findclass-ssr prod 和 pre-prod 迁移到 r4s，复用现有蓝绿机制 |
| **备份策略完全迁移** | 数据库永不丢失是核心价值 | LOW | pg_dump + B2 上传完全在 r4s 执行，Mac 仅触发 |
| **内存优化配置** | r4s 仅 3.77GB RAM，必须优化 | LOW | 所有服务设置 memory limits + compact logging + tmpfs |
| **健康检查机制** | 验证服务正常运行 | LOW | 复用现有 health check，增加 r4s 网络连通性检查 |
| **回滚机制** | 出错时能快速恢复 | LOW | 保持现有 rollback 逻辑，增加 SSH 失败回滚 |

### Differentiators（提升价值的增强功能）

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **监控集成** | 实时掌握 r4s 资源使用情况 | MEDIUM | Prometheus agent 收集容器 metrics，Grafana 可视化 |
| **自动化健康检查** | 预防性发现潜在问题 | LOW | 定期验证服务连通性，内存使用预警 |
| **镜像缓存策略** | 减少镜像传输时间 | LOW | r4s 本地缓存常用镜像，加速部署 |
| **备份验证** | 确保备份文件可用 | LOW | 自动下载并验证备份文件完整性 |

### Anti-Features（应该避免的功能）

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| **完全独立的基础设施** | "迁移应该完全隔离" | r4s 资源有限，独立部署会导致内存不足且复杂度倍增。共享架构更实际 | 共享基础设施，通过容器隔离实现多环境 |
| **自动触发迁移** | "一键完成所有迁移" | 多阶段迁移需要验证每个步骤，自动执行会增加风险 | 分阶段手动执行，每步验证后继续 |
| **实时数据同步** | "prod 数据实时同步到 r4s" | 增加网络负担和复杂性，且可能影响生产性能 | 定期手动备份 + 按需恢复 |
| **Kubernetes 迁移** | "更现代的容器编排" | r4s 资源有限，K8s 开销大且不必要。Docker Compose 已足够 | 继续使用 Docker Compose，仅优化配置 |
| **多节点集群** | "高可用性要求" | 单服务器架构，增加节点超出当前需求 | 单节点 + 备份策略实现数据安全 |

## MVP Definition

### Launch With (v1)

最小可行迁移方案 — 能够实现完整服务栈迁移。

- [ ] **r4s 环境准备** -- SSH 连接 + Docker 配置 + Swap 文件。没有这些后续无法进行
- [ ] **基础设施迁移** -- PostgreSQL + Keycloak + Nginx + Cloudflare Tunnel 迁移到 r4s
- [ ] **应用迁移** -- findclass-ssr prod 和 pre-prod 蓝绿部署迁移到 r4s
- [ ] **Jenkins SSH 远程部署** - Pipeline 改造为通过 SSH 在 r4s 执行命令
- [ ] **备份策略迁移** -- pg_dump + B2 上传完全在 r4s 执行

### Add After Validation (v1.x)

核心迁移完成后，增加监控和自动化功能。

- [ ] **监控集成** - Prometheus + Grafana 监控 r4s 资源使用
- [ ] **自动化健康检查** - 定期验证服务连通性和内存状态
- [ ] **镜像缓存策略** - r4s 本地缓存常用镜像
- [ ] **备份验证** - 自动验证备份文件完整性

### Future Consideration (v2+)

需要更多资源投入的功能。

- [ ] **自动扩容** - 根据负载动态调整容器资源
- [ ] **多节点备份** - 备份文件同步到多个位置
- [ ] **性能基准测试** - 量化迁移前后的性能对比

## 部署流程对比

### 当前流程（Mac 部署）

```
Jenkins 触发 → 本地 docker compose 执行 → 部署完成
```

### 目标流程（r4s 部署）

```
Jenkins 触发 (Mac) → SSH 连接 r4s → 远程 docker compose 执行 → 部署完成
```

**关键差异：**
- 执行环境从本地改为远程
- 需要维护 SSH 连接稳定性
- 网络延迟影响部署时间
- 错误处理需要包含 SSH 连接失败场景

## 与现有架构的集成点

| 现有组件 | 迁移集成方式 | 变更范围 |
|---------|-------------|----------|
| `docker-compose.yml` | 使用 `docker-compose.r4s.yml` overlay | 小 - 新增 overlay 文件 |
| `jenkins/Jenkinsfile.apps` | 添加 SSH 执行步骤 + 远程路径 | 中 - 修改 pipeline 步骤 |
| `scripts/manage-containers.sh` | 增加 SSH 远程执行支持 | 中 - 新增 SSH 模式 |
| `deploy/Dockerfile.noda-ops` | ARM64 优化 + 可能的依赖调整 | 小 - 优化构建 |
| `scripts/pipeline-stages.sh` | 备份脚本适配远程执行 | 中 - 修改备份路径 |
| `CLAUDE.md` | 更新部署流程文档 | 小 - 文档更新 |

## Sources

### 主要来源（HIGH 置信度）

- 项目源码分析：`docker/docker-compose.yml`、`docker/docker-compose.r4s.yml`、`docker/docker-compose.apps-prod.yml`、`jenkins/Jenkinsfile.apps`、`scripts/r4s/setup-ssh.sh`、`deploy/Dockerfile.noda-ops`
- 项目架构文档：`CLAUDE.md`（Docker Compose 架构、Jenkins Pipeline 流程）
- ARM64 Docker 优化指南：[Containerization Docker Best Practices 2026](https://github.com/github/awesome-copilot/blob/main/instructions/containerization-docker-best-practices.instructions.md)
- Docker Compose SSH 部署：[Docker Compose Production Deployment Best Practices](https://mykolaaleksandrov.dev/posts/2026/02/docker-production-best-practices/)
- PostgreSQL 迁移实践：[PostgreSQL Database Migration Guide](https://devopsinsight.medium.com/step-by-step-guide-migrate-a-self-hosted-postgresql-database-to-a-managed-service-8184784004f2)

### 次要来源（MEDIUM 置信度）

- Jenkins SSH Pipeline 教程：社区实践案例
- 低内存设备优化：ARM64 性能调优指南
- Cloudflare Tunnel 配置：官方文档参考

---
*研究完成日期: 2026-05-17*
*路线图就绪: 是*