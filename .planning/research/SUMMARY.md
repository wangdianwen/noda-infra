# Project Research Summary

**Project:** Noda Infrastructure -- 密钥管理集中化 (v1.8)
**Domain:** Docker Compose 单服务器基础设施 + Jenkins CI/CD 密钥管理
**Researched:** 2026-04-19
**Confidence:** HIGH

## Executive Summary

Noda 是一个单服务器 Docker Compose 基础设施项目，管理约 20 个密钥（数据库密码、API 密钥、B2 备份凭据等），月部署频率约 60 次。密钥当前分散在 4 个明文 `.env` 文件中，无统一管理、无审计、无轮换。研究的目标是为 v1.8 里程碑引入集中式密钥管理。

研究出现了一个关键分歧：Stack 研究推荐 Infisical Cloud（免费 SaaS + CLI），而 Features、Architecture 和 Pitfalls 研究一致推荐增强现有的 SOPS + age 方案。经过权衡分析（详见下方），**推荐增强 SOPS + age 方案**。核心理由：项目已有 SOPS + age 基础设施（decrypt-secrets.sh 已存在），零额外资源消耗，无新服务引入（零单点故障），与单服务器架构完美匹配。Infisical Cloud 作为未来升级路径保留。

关键风险集中在三个领域：（1）密钥迁移遗漏导致服务启动失败 -- 需要完整的密钥清单和逐文件验证；（2）备份系统与密钥管理的循环依赖 -- 备份系统必须保持独立；（3）docker/.env 曾被提交到 Git 历史（commit c15faba）-- 需要清理历史并轮换相关密钥。推荐的渐进式迁移策略（先创建加密文件，再修改消费方，最后删除明文）可以最大限度降低风险。

## 技术方案分歧分析

### 方案 A：Infisical Cloud（Stack 研究推荐）

**核心思路：** 使用 Infisical Cloud 免费版作为密钥存储，通过 CLI（infisical export）在 Jenkins Pipeline 中拉取密钥。

| 优势 | 劣势 |
|------|------|
| Web UI 管理，可视编辑密钥 | 引入 SaaS 外部依赖，密钥离开服务器 |
| 原生 Jenkins 集成（Universal Auth） | 需要 jenkins 用户安装 46MB CLI |
| 审计日志、版本历史（Pro 功能） | 免费版无 Point-in-Time Recovery |
| 密钥引用（secret referencing） | infisical export 写入 .env 到磁盘 |
| 未来可扩展到自动轮换 | 网络依赖 -- Infisical 宕机 = 无法部署 |
| 25.9k stars，MIT 许可证 | 与现有 SOPS + age 基础设施重复 |

**适用场景：** 如果团队需要非技术成员通过 Web UI 管理密钥，或未来需要多环境、多项目的密钥管理。

### 方案 B：SOPS + age 增强（Features/Architecture/Pitfalls 一致推荐）

**核心思路：** 扩展现有 SOPS + age 加密体系，将所有密钥整合到 `config/secrets/*.sops.yaml`，通过统一接口 `scripts/lib/secrets.sh` 消费。

| 优势 | 劣势 |
|------|------|
| 零额外资源消耗（无新容器/服务） | 无 Web UI，纯 CLI 操作 |
| 项目已有 decrypt-secrets.sh 和 .sops.yaml | 无自动轮换 |
| Git 原生版本控制和审计（git log） | 无内置审计日志（依赖 git log） |
| 无运行时依赖，不存在单点故障 | 密钥编辑需要 sops edit 命令 |
| 与单服务器架构完美匹配 | 密钥引用需手动拼接 |
| 渐进式迁移，风险可控 | 未来扩展需要迁移到 Vault/Infisical |

**适用场景：** 当前单服务器、单用户、低频部署的精确匹配。

### 推荐：方案 B（SOPS + age 增强）

**理由：**

1. **规模匹配** -- 20 个密钥、60 次部署/月，SOPS 完全胜任
2. **已有基础** -- decrypt-secrets.sh 和 .sops.yaml 已存在，增量成本低
3. **零风险** -- 不引入新服务，不存在"密钥服务宕机 = 无法部署"的单点故障
4. **备份独立性** -- SOPS 加密文件在 Git 中，不依赖任何运行时服务
5. **资源约束** -- 单服务器已运行 PostgreSQL + Keycloak（蓝绿） + findclass-ssr（蓝绿）+ Nginx + Jenkins，没有余量运行额外服务

**保留升级路径：** 如果未来密钥超过 50 个、需要自动轮换、或团队扩大需要 Web UI，可以迁移到 Infisical Cloud。`scripts/lib/secrets.sh` 的接口设计使得后端切换透明。

## Key Findings

### Recommended Stack

推荐基于现有 SOPS + age 基础设施的增强方案，不引入新的密钥管理服务。

**Core technologies:**
- **SOPS (Mozilla Secrets Operations):** 密钥加密/解密工具 -- 已在项目中使用，扩展到覆盖所有密钥
- **age (现代加密工具):** 非对称加密后端 -- 已配置密钥，需要加强离线备份
- **Git (版本控制):** 加密密钥文件存储 -- 天然的版本管理、审计日志、多副本
- **Jenkins Credentials Store:** age 私钥和 Jenkins 专用凭据存储 -- 与 Pipeline withCredentials 原生集成

**如果选择 Infisical Cloud 的替代技术栈:**
- **Infisical Cloud (Free):** 密钥存储和 Web UI 管理 -- 零运维负担
- **Infisical CLI (0.43.x):** Pipeline 中拉取密钥 -- infisical export 输出 .env 格式
- **Machine Identity (Universal Auth):** CI/CD 无交互认证 -- Client ID/Secret 存储在 Jenkins Credentials

### Expected Features

**Must have (table stakes -- P0):**
- T-01: Jenkins Pipeline 构建前密钥拉取 -- 替换 source docker/.env
- T-02: Docker Compose 密钥注入 -- compose up 时环境变量完整
- T-03: envsubst 模板机制保留 -- 蓝绿部署核心不破坏
- T-04: 迁移后删除明文 .env 文件 -- 集中化的意义所在
- T-05: 密钥数据备份到 B2 -- "数据库永不丢失"的延伸
- T-06: 传输加密 -- SOPS 文件级加密天然满足
- T-07: 静态加密 -- SOPS + age 天然满足

**Should have (competitive -- P1):**
- D-02: 审计日志 -- 简单的 access.log 或依赖 git log
- D-03: 环境隔离 (prod/dev) -- 按目录或按文件分组
- D-04: 密钥版本管理 -- SOPS + git 天然支持

**Defer (v2+):**
- D-01: PostgreSQL 密码自动轮换 -- 需要额外工具
- D-05: Jenkins Credentials Provider 集成 -- 需要 Vault
- D-06: 密钥模板引用 -- 需要 Vault/Infisical

### Architecture Approach

推荐架构将密钥按消费方分组存储在 `config/secrets/` 目录下的 SOPS 加密文件中（infra/apps/backup/jenkins 四组），通过新增的 `scripts/lib/secrets.sh` 统一接口消费。Docker Compose 的 `${VAR}` 替换机制和 envsubst 模板机制保持不变，仅替换密钥来源。age 私钥作为根信任点需要多位置备份。

**Major components:**
1. `config/secrets/*.sops.yaml` -- 加密密钥存储（按消费方分组，Git 提交）
2. `scripts/lib/secrets.sh` -- 统一密钥获取接口（替代 decrypt-secrets.sh）
3. `pipeline-stages.sh`（修改）-- 密钥加载从 source .env 改为 fetch_secrets
4. `config/keys/git-age-key.txt`（gitignored）-- age 私钥，需要离线备份

### Critical Pitfalls

1. **备份系统循环依赖（P5，代价：HIGH）** -- 备份系统的 B2 凭据和 PostgreSQL 密码绝不迁移到密钥服务。备份系统是"最后防线"，必须独立于任何新引入的组件。`scripts/backup/.env.backup` 保持不变，或单独加密存储但不依赖任何运行时服务。

2. **密钥迁移遗漏（P2，代价：MEDIUM）** -- 4 个 .env 文件中的密钥有重复和交叉。迁移前必须执行完整审计（`grep -rh '^\w+=' docker/.env .env.production scripts/backup/.env.backup`），建立清单，迁移后用 `docker compose config` 验证所有变量。

3. **VITE_* 构建时密钥注入（P3，代价：LOW 但影响面大）** -- VITE_KEYCLOAK_URL/REALM/CLIENT_ID 是公开信息，不应纳入密钥管理。保持 pipeline-stages.sh 中的 `--build-arg` 硬编码值不变，避免构建时密钥注入失败导致前端白屏。

4. **docker/.env 曾提交到 Git 历史（安全风险）** -- commit c15faba 中包含明文密钥。迁移完成后需要用 `git filter-branch` 或 BFG Repo Cleaner 清除历史，并轮换所有曾暴露的密钥。

5. **age 私钥丢失 = 永久丢失所有密钥（P9，代价：CRITICAL）** -- age 私钥至少需要 3 处备份：服务器本地 + 密码管理器 + B2 加密备份。没有 age 私钥，SOPS 加密文件无法解密。

## Implications for Roadmap

Based on research, suggested phase structure:

### Phase 1: 密钥基础设施搭建
**Rationale:** 所有后续工作依赖加密密钥文件和统一获取接口。这一阶段没有破坏性变更，不修改任何现有脚本。
**Delivers:** config/secrets/ 目录结构 + 4 个 SOPS 加密文件 + scripts/lib/secrets.sh + age 私钥备份到 B2
**Addresses:** T-05, T-06, T-07, Pitfall 9（加密密钥备份）, Pitfall 5（备份独立性设计）
**Avoids:** Pitfall 6（资源耗尽 -- 无新容器）
**Research needed:** 无 -- SOPS + age 文档完善，项目已有使用经验

### Phase 2: Jenkins Pipeline 集成
**Rationale:** Jenkins 是密钥的最大消费方（pipeline-stages.sh），也是部署流程的核心。集成 Jenkins 是验证 SOPS 方案端到端可行性的关键。
**Delivers:** pipeline-stages.sh 密钥加载重构 + Jenkins Credentials 配置 age 私钥 + 端到端 Pipeline 测试
**Addresses:** T-01, T-03（envsubst 保留验证）, Pitfall 2（密钥遗漏验证）, Pitfall 3（VITE_* 确认不纳入）, Pitfall 7（日志泄露审查）
**Uses:** SOPS CLI, Jenkins withCredentials, scripts/lib/secrets.sh
**Research needed:** 可能需要 -- Jenkins `credentials()` 函数在 Declarative Pipeline 中的 Secret file 类型用法

### Phase 3: 手动部署脚本迁移
**Rationale:** deploy-infrastructure-prod.sh 和 deploy-apps-prod.sh 是 Jenkins 不可用时的回退方案，必须与 Pipeline 使用相同的密钥获取方式。
**Delivers:** deploy-*.sh 脚本密钥加载重构 + noda-ops 环境变量注入方式优化
**Addresses:** T-02（Docker Compose 密钥注入）, Pitfall 10（.env 删除时机）, Pitfall 12（noda-ops 容器内密钥访问）
**Uses:** scripts/lib/secrets.sh
**Research needed:** 无 -- 与 Phase 2 相同模式

### Phase 4: Git 历史清理 + 明文文件删除
**Rationale:** 必须在 Phase 2 和 Phase 3 全部验证稳定后执行。删除是不可逆操作，需要充分的验证期。
**Delivers:** docker/.env 密钥清除 + .env.production 删除 + scripts/backup/.env.backup 优化 + git filter-branch 清理历史
**Addresses:** T-04（删除明文 .env）, Pitfall 10（.env 删除过早）, 安全风险（git 历史中的明文密钥）
**Avoids:** Pitfall 2（迁移遗漏 -- 通过 docker compose config 对比验证）
**Research needed:** 可能需要 -- BFG Repo Cleaner 或 git filter-repo 的具体用法

### Phase Ordering Rationale

- Phase 1 必须最先，因为所有后续阶段依赖密钥文件和 secrets.sh 接口
- Phase 2 在 Phase 3 之前，因为 Jenkins Pipeline 是主部署路径，验证后手动脚本才能跟着改
- Phase 4 必须最后，因为删除明文文件不可逆，需要 Phase 2 + 3 充分验证
- Pitfall 5（备份循环依赖）在 Phase 1 解决，因为备份系统的独立设计必须在架构层面确定
- VITE_* 的特殊处理在 Phase 2 明确 -- 确认这些公开信息不纳入密钥管理

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2:** Jenkins `credentials()` 函数与 Secret file 类型的具体配置方式；Jenkins Pipeline 中 `sops --decrypt` 的错误处理和回退逻辑
- **Phase 4:** BFG Repo Cleaner 或 git filter-repo 的具体操作步骤；git 历史清理后的远程仓库同步

Phases with standard patterns (skip research-phase):
- **Phase 1:** SOPS + age 已在项目中使用，扩展到更多文件是标准操作
- **Phase 3:** 与 Phase 2 相同的密钥获取模式，仅替换消费方

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack (SOPS + age) | HIGH | 项目已有 decrypt-secrets.sh，Context7 官方文档验证，代码审计确认可行性 |
| Stack (Infisical Cloud) | HIGH | Infisical 定价页、GitHub 仓库、Docker Hub 镜像分析均有验证 |
| Features | HIGH | 基于完整代码审计（4 个 .env 文件 + pipeline-stages.sh + Jenkinsfile），密钥清单准确 |
| Architecture | HIGH | 基于完整代码库审计 + Context7 多源文档验证，迁移映射表精确到具体变量名和行号 |
| Pitfalls | MEDIUM-HIGH | 10 个 Critical Pitfall 基于代码审计推导，部分生态数据（Vault 内存占用）来自训练知识未实测验证 |

**Overall confidence:** HIGH

### Gaps to Address

- **Infisical Cloud 降级风险：** 如果未来选择 Infisical Cloud，需要验证其免费版 API 速率限制是否满足 60 次/月部署频率。建议在 Phase 1 设计 secrets.sh 接口时预留后端切换能力
- **Vault 内存占用估算：** 200-400MB 为社区经验值，未在项目服务器上实测。如果未来考虑 Vault，需要先在服务器上 `docker stats` 确认可用内存
- **Git 历史清理范围：** commit c15faba 中的 .env 文件包含哪些具体密钥值需要人工确认，自动化清理前必须手动审查
- **age 私钥管理流程：** 需要在 Phase 1 执行前确定离线备份的具体位置（密码管理器选择、加密 USB 等）

## Sources

### Primary (HIGH confidence)
- Context7: HashiCorp Vault 文档 -- KV v2 操作、Docker 部署、Raft 存储、审计日志
- Context7: Jenkins 官方文档 -- withCredentials、Declarative Pipeline environment 块
- Context7: Infisical CLI 文档 -- export/run 命令、machine identity 认证
- Context7: Infisical 平台文档 -- 自托管部署、定价层级
- Context7: SOPS 官方文档 -- 加密文件格式、age 后端
- 项目代码审计 -- docker/.env, .env.production, scripts/backup/.env.backup, pipeline-stages.sh, manage-containers.sh, Jenkinsfile.*, decrypt-secrets.sh

### Secondary (MEDIUM confidence)
- Infisical GitHub 仓库 -- 25.9k stars，MIT 许可证，自托管 docker-compose.prod.yml
- Infisical Docker Hub -- 镜像大小验证（infisical/infisical: 694MB, infisical/cli: 46MB）
- HashiCorp Vault Docker Hub -- vault:2.0.0 镜像
- Vault 生产加固指南 -- 资源推荐和部署要求

### Tertiary (LOW confidence)
- Vault 内存占用估算 -- 200-400MB 来自社区经验，未在项目环境中实测
- Jenkins withCredentials masking 行为 -- 基于训练知识，具体边界条件需要实测验证

---
*Research completed: 2026-04-19*
*Ready for roadmap: yes*
