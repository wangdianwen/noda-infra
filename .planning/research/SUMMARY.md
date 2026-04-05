# PostgreSQL 云备份系统调研摘要

**项目:** Noda Infrastructure -- PostgreSQL 17.9 in Docker
**领域:** 数据库备份系统（Docker 容器 + 云存储）
**调研完成:** 2026-04-06
**置信度:** HIGH

---

## 执行摘要

Noda 项目需要一个可靠的 PostgreSQL 云备份系统，保护两个关键数据库（keycloak_db、findclass_db）免受数据丢失。专家对小型生产环境（<1GB 数据库）的最佳实践是：使用 PostgreSQL 内置的 `pg_dump -Fc` 进行逻辑备份，通过 rclone 上传到 Backblaze B2 云存储，由 Jenkins 定时调度。这个方案简单、可靠、成本极低（当前规模完全免费），避免了 pgBackRest/WAL-G 等企业级工具的复杂度。

关键风险集中在三个领域：**多数据库备份完整性**（必须同时备份所有数据库 + 全局对象）、**凭证安全**（严禁硬编码，使用受限 B2 Application Key）、**恢复流程验证**（备份从未测试恢复等于没有备份）。通过应用层清理逻辑（而非 B2 生命周期规则）、多层验证链（本地→传输→远程→每周恢复测试）和严格权限管理，这些风险可以有效缓解。项目已有 Jenkins 基础设施和 SOPS 加密体系，备份系统可以无缝融入现有架构。

推荐的实施路径是渐进式构建：先实现可靠的本地备份脚本（Phase 1），再集成云存储（Phase 2），然后 Jenkins 自动化（Phase 3），最后完善恢复和监控（Phase 4-5）。这种顺序确保每个阶段都有可验证的交付物，避免一次性构建复杂系统带来的风险。当前数据库规模（<1GB）下，pg_dump -Fc 完全足够；未来增长到 >10GB 时，可以平滑升级到 pgBackRest 或 WAL-G，无需重写架构。

---

## 核心发现

### 推荐技术栈

**一键方案：Backblaze B2 + pg_dump -Fc + rclone + Jenkins**

基于 STACK.md 的成本分析和技术评估，Backblaze B2 是最佳选择：
- **成本优势：** 当前规模（2.8GB 存储）完全在免费额度内，月费 $0.00
- **S3 兼容：** rclone 原生支持，将来迁移到 R2/S3 只需改配置
- **API 定价：** Class A（写）请求免费，Class B/C（读/列）每天 2,500 次免费
- **出口免费：** 每月 3x 存储量（8.4GB）免费出口，恢复测试无额外费用

**核心技术组件：**
- **pg_dump -Fc（PostgreSQL 17.9 内置）：** 自带 zlib 压缩（60-80% 压缩比）、支持 `pg_restore --list` 验证、支持并行恢复。无需额外工具，Docker 原生兼容
- **rclone（v1.68+）：** 支持 70+ 云存储后端、内置校验和验证、指数退避重试、成熟稳定。比 AWS CLI 更灵活（B2 原生 API + S3 API 都支持）
- **Jenkins cron（已有基础设施）：** 避免了 Docker 容器内 cron 的时区、日志、重启问题。提供可视化日志、失败通知、手动触发
- **SSE-B2 + 受限 Application Key：** B2 默认服务端加密。安全性关键是严格 Key 权限管理（专用 Standard Key，仅限备份 bucket + 最低权限）

**不需要的工具（避免过度工程）：**
- **pgBackRest/WAL-G：** 适合 >100GB 数据库或需要 PITR 的场景。当前 6-12 小时备份频率的小型数据库，pg_dump 足够
- **客户端加密（rclone crypt）：** SSE-B2 + Key 权限管理已足够。客户端加密增加复杂度但收益有限
- **PITR（时间点恢复）：** 需要 WAL 归档 + base backup 配合，复杂度高。当前项目不需要秒级 RPO

### 必备功能

**Table Stakes（必备特性）—— 缺少任何一个，系统不可用于生产环境：**

- **TS-1 多数据库完整备份：** 必须逐一备份 keycloak_db、findclass_db（不能遗漏任何一个）
- **TS-2 全局对象备份：** pg_dumpall --globals-only 单独备份角色和表空间定义（pg_dump 不包含这些）
- **TS-3 备份文件命名规范：** `{db}_{YYYYMMDD}_{HHMM}.dump`，支持清理和恢复识别
- **TS-4 自定义压缩格式：** pg_dump -Fc 自带 zlib 压缩，不要再用 gzip 二次压缩
- **TS-5 云存储自动上传：** rclone 上传到 B2，上传后删除本地临时文件
- **TS-6 上传失败重试：** rclone 内置重试（--retries 3 --retries-sleep 10s）
- **TS-7 上传后校验和验证：** rclone --checksum 自动验证
- **TS-8 应用层保留清理：** rclone delete --min-age 7d（不依赖 B2 生命周期规则）
- **TS-9 一键恢复脚本：** rclone 下载 -> createdb -T template0 -> pg_restore -> ANALYZE
- **TS-10 结构化日志：** 时间、库名、大小、耗时、状态，输出到 stdout（Jenkins 采集）和日志文件
- **TS-11 凭证环境变量管理：** 所有凭证通过环境变量传入，绝不硬编码
- **TS-12 最低权限 API Key：** 受限 B2 Standard Application Key（仅限备份 bucket + 必要权限）
- **TS-13 备份前健康检查：** pg_isready 验证 PostgreSQL 可连接，避免在数据库不可用时执行备份

**差异化特性（提升可靠性，但非用户默认期望）：**

- **IM-1 备份完整性验证：** pg_restore --list 验证备份文件可读性，验证失败则不上传
- **IM-2 备份失败告警：** Webhook 通知（项目已有 Cloudflare Tunnel，可对接企业微信/Slack）
- **IM-3 列出可用备份：** restore.sh --list 使用 rclone ls 列出所有可用备份
- **IM-4 恢复指定数据库：** restore.sh --database findclass_db --timestamp 20260405_120000
- **IM-5 恢复到测试库：** restore.sh --target-db findclass_db_test（安全验证，不影响生产）
- **IM-6 每周自动恢复测试：** Jenkins 定时任务验证恢复流程，最终可靠性保障
- **IM-7 备份耗时追踪：** 与历史平均值对比，偏差 >50% 时输出 WARNING
- **IM-8 磁盘空间检查：** 备份前检查 Docker volume 可用空间 >= 预估备份大小 x 2
- **IM-9 未完成上传清理：** B2 bucket 生命周期规则设置 daysFromStartingToCancelingUnfinishedLargeFiles: 1
- **IM-10 统一退出码：** 0=成功、1=连接失败、2=备份失败、3=上传失败、4=清理失败、5=验证失败

**明确不做的特性（Anti-Features，避免过度工程）：**

- **AF-1 增量备份：** pg_dump 完整备份对当前规模足够快。增量备份需要管理 WAL 归档链，恢复复杂度高
- **AF-2 实时复制/流备份：** 需要主从架构，至少双倍基础设施成本。6-12 小时 RPO 对当前项目足够
- **AF-3 PITR 时间点恢复：** 需要基础备份 + 完整 WAL 归档链，复杂度极高。使用 pg_dump 多频率备份实现粗粒度时间点恢复
- **AF-4 跨区域备份复制：** 增加存储成本和管理复杂度。B2 已有数据中心冗余，单区域足够
- **AF-5 手动备份触发 Web UI：** Jenkins 已提供手动触发能力，Web UI 额外开发和维护成本不值得
- **AF-6 自定义客户端加密方案：** 自定义加密容易出错，rclone crypt 是成熟方案。当前 SSE-B2 已足够
- **AF-7 备份压缩格式选择：** -Fc 已内置 zlib 压缩，提供多种格式选择增加测试矩阵但无实际收益
- **AF-8 数据库自动发现：** 会备份 template0/template1 等系统数据库。显式列出需要备份的数据库更安全
- **AF-9 备份文件保留策略可配置：** 7 天保留策略已明确，过早提供配置选项增加测试负担
- **AF-10 Web 管理面板：** 需要额外开发和维护 Web 前端+后端+认证。Jenkins 已提供日志查看和历史记录

### 架构方法

**推荐架构：宿主机编排，容器内执行，云存储持久化**

基于 ARCHITECTURE.md 的分析，备份系统不添加新的 Docker 容器，而是利用现有 Jenkins 基础设施：

```
Jenkins cron 触发（每6小时）
    │
    ▼
backup-to-cloud.sh（备份编排脚本）
    │
    ├─ 1. 前置检查（PostgreSQL 健康 + rclone 配置 + 磁盘空间）
    ├─ 2. 数据库转储（docker exec postgres pg_dump -Fc）
    ├─ 3. 本地验证（pg_restore --list）
    ├─ 4. 云上传（rclone copy --checksum）
    ├─ 5. 清理旧备份（rclone delete --min-age 7d）
    └─ 6. 清理临时文件（rm /tmp/backup-*）
```

**主要组件：**
1. **backup-to-cloud.sh** - 备份编排脚本，调用 pg_dump -> 上传 -> 清理 -> 输出状态
2. **restore-from-cloud.sh** - 一键恢复脚本，从 B2 下载 -> pg_restore 到目标数据库
3. **verify-backup.sh** - 每周自动恢复测试，下载最新备份 -> 恢复到临时数据库 -> 验证完整性
4. **notify-status.sh** - 发送备份状态通知（成功/失败），支持 webhook
5. **Jenkinsfile.backup** - Jenkins Pipeline 定义，定时触发备份 + 失败通知

**存储架构：**
```
noda-db-backup/                     # B2 Bucket
├── noda_prod/                      # 生产数据库备份
│   ├── noda_prod_20260406_0001.dump
│   ├── noda_prod_20260406_1200.dump
│   └── ...
├── keycloak/                       # Keycloak 数据库备份
│   ├── keycloak_20260406_0001.dump
│   └── ...
└── globals/                        # 全局角色和表空间定义
    ├── globals_20260406_0001.sql
    └── ...
```

**关键架构模式：**
- **Pattern 1: 宿主机编排，容器内执行** - 备份编排在 Jenkins（宿主机层面）执行，pg_dump 在 PostgreSQL 容器内通过 `docker exec` 调用。避免了 sidecar 容器的复杂度
- **Pattern 2: 分层凭据管理** - 敏感凭据通过 SOPS 加密存储，运行时注入。非敏感配置通过环境变量管理
- **Pattern 3: 纵向验证链** - 本地验证（pg_restore --list）-> 传输验证（rclone --checksum）-> 远程验证（rclone check）-> 恢复验证（每周测试）

### 关键陷阱

**Critical Pitfalls（必须避免的前 5 个陷阱）：**

1. **Pitfall 1: pg_dump 一致性误解** - 认为备份了所有数据库就安全了
   - **问题：** pg_dump 每次只能备份一个数据库，且不备份角色和表空间。只备份 findclass_db 而忘记 keycloak_db，灾难恢复时 Keycloak 配置丢失，所有用户认证失效
   - **避免：** 使用 pg_dumpall --globals-only 单独备份角色和表空间定义。对每个数据库单独运行 pg_dump。在备份脚本中明确列出所有数据库名（keycloak_db、findclass_db）

2. **Pitfall 2: 恢复失败** - 备份成功但恢复时才暴露问题
   - **问题：** pg_dump 生成的纯文本格式恢复时遇到编码错误、扩展版本不兼容、或恢复脚本从未被测试过。PostgreSQL 官方警告："you will only have a partially restored database"
   - **避免：** 使用 pg_dump -Fc（自定义格式）而非纯文本格式。恢复脚本中使用 `psql --set ON_ERROR_STOP=on`。恢复前必须 `createdb -T template0 dbname`。自动化恢复测试：每周在一个干净的测试环境中运行完整恢复流程

3. **Pitfall 3: 云存储生命周期规则误配** - 7 天保留策略的 B2 特殊陷阱
   - **问题：** B2 生命周期规则基于文件版本（version），不是基于独立文件。每个备份文件名不同（含时间戳），所以 daysFromHidingToDeleting 规则不会生效
   - **避免：** 不要依赖 B2 生命周期规则来管理备份保留。在备份脚本中实现应用层清理逻辑：rclone delete --min-age 7d。在清理逻辑中保留安全缓冲：删除超过 8 天的文件（而非恰好 7 天）

4. **Pitfall 4: 凭证硬编码和泄露** - 最常见的安全事故
   - **问题：** 云存储 Access Key 被硬编码在备份脚本中、写入 .env 文件但没有 .gitignore。一旦代码仓库泄露，攻击者可以访问所有备份数据。当前项目中 `.env.production` 已被 Git 追踪，需要立即处理
   - **避免：** 创建专用的 Backblaze B2 Standard Application Key，权限限制为：仅限特定 bucket、仅限 writeFiles + deleteFiles + listFiles 权限、设置 fileNamePrefix 限制。绝不使用 Master Application Key。凭证通过环境变量传入脚本

5. **Pitfall 5: Docker 容器环境下的调度失效** - cron 消失
   - **问题：** 在 Docker 容器内运行 cron 定时任务，但容器重启后 cron 服务没有自动启动。或者 cron 任务使用了容器内的时区（UTC），与新西兰时区（NZST/NZDT）不一致
   - **避免：** 推荐使用 Jenkins cron 调度（项目已有 Jenkins 基础设施）。如果必须使用 Docker 容器内 cron：设置 TZ=Pacific/Auckland 环境变量、确保入口脚本同时启动 cron、将 cron 输出重定向到 stdout

**Moderate/Minor Pitfalls（需要注意的其他陷阱）：**
- **Pitfall 6: 网络传输失败** - 上传中断和静默数据损坏。使用 rclone 内置重试和校验和验证
- **Pitfall 7: 备份文件未压缩** - 存储成本和传输时间倍增。使用 pg_dump -Fc 自带压缩
- **Pitfall 8: 监控盲区** - 备份成功但数据损坏。备份后立即验证 pg_restore --list，每周自动恢复测试
- **Pitfall 9: WAL 归档与 pg_dump 的混淆** - 当前 WAL 归档只存本地，未配合云上传。明确选择 pg_dump 逻辑备份策略，评估是否关闭 archive_mode
- **Pitfall 10: 加密误解** - 云存储"加密"不等于端到端安全。使用 SSE-B2 + 严格 Key 权限管理，需要更高安全性时用 rclone crypt

---

## 路线图启示

基于综合研究，建议分 5 个阶段渐进式构建备份系统。每个阶段都有明确的交付物和验证标准，避免一次性构建复杂系统带来的风险。

### Phase 1: 本地备份增强（v1 核心）

**理由：** 必须先建立可靠的本地备份流程，再添加云存储。这是所有后续功能的基础。

**交付物：**
- backup-to-cloud.sh 骨架（本地备份部分）
- 使用 `docker exec pg_dump -Fc` 替代当前的纯文本格式
- 本地验证（pg_restore --list）
- 结构化日志输出

**覆盖需求：** TS-1, TS-2, TS-3, TS-4, TS-10, TS-13, IM-1, IM-8, IM-10

**避免陷阱：** Pitfall 1（多数据库备份遗漏）、Pitfall 2（恢复失败）、Pitfall 7（未压缩备份）

**验证标准：**
- 所有数据库（keycloak_db、findclass_db）都被备份
- pg_restore --list 成功列出所有备份文件内容
- 备份文件大小比纯文本格式小 60-80%
- 日志包含时间戳、数据库名、文件大小、耗时、状态

### Phase 2: 云存储集成（v1 核心）

**理由：** 本地备份可靠后，添加云存储上传。rclone 简化了重试和校验逻辑，比 AWS CLI 更适合。

**交付物：**
- 安装和配置 rclone
- 创建 B2 Bucket 和受限 Application Key
- 实现上传和校验和验证
- 实现旧备份清理（rclone delete --min-age 7d）
- 将 B2 凭据加入 SOPS 加密管理

**覆盖需求：** TS-5, TS-6, TS-7, TS-8, TS-11, TS-12, IM-9

**使用技术栈：** Backblaze B2（STACK.md 推荐）、rclone（STACK.md 推荐）

**避免陷阱：** Pitfall 3（B2 生命周期规则误配）、Pitfall 4（凭证硬编码）、Pitfall 6（网络传输失败）

**验证标准：**
- 备份文件成功上传到 B2（可通过 rclone ls 确认）
- rclone check 验证上传后校验和匹配
- 超过 7 天的旧备份被自动删除
- B2 Application Key 权限受限（仅限备份 bucket + 必要权限）

### Phase 3: Jenkins 自动化（v1 核心）

**理由：** 云存储集成完成后，添加 Jenkins 自动化调度。Jenkins 已有基础设施，避免了 Docker 容器内 cron 的各种问题。

**交付物：**
- Jenkinsfile.backup（Pipeline 定义）
- 定时触发器配置（H */6 * * *）
- Jenkins Credentials 配置（B2 Key）
- 失败通知（webhook 或邮件）

**覆盖需求：** TS-9（恢复脚本基础）、IM-2（失败告警）

**使用技术栈：** Jenkins（已有基础设施）

**避免陷阱：** Pitfall 5（Docker 调度失效）

**验证标准：**
- Jenkins cron 按预期触发备份任务（每 6 小时）
- 备份失败时 webhook/邮件通知触发
- Jenkins Dashboard 显示构建历史和日志

### Phase 4: 恢复和验证（v1.x 监控和自动化测试）

**理由：** 核心备份功能完成后，添加恢复流程和自动化测试。这是最终可靠性保障。

**交付物：**
- restore-from-cloud.sh（一键恢复脚本）
- verify-backup.sh（每周自动恢复测试）
- 恢复操作文档
- 首次完整恢复测试执行

**覆盖需求：** TS-9（完整恢复）、IM-3（列出备份）、IM-4（恢复指定库）、IM-5（恢复到测试库）、IM-6（自动恢复测试）

**避免陷阱：** Pitfall 2（恢复失败）、Pitfall 8（监控盲区）

**验证标准：**
- restore-from-cloud.sh 成功恢复指定数据库
- verify-backup.sh 每周自动运行，失败时告警
- 恢复测试在临时数据库中完成，不影响生产
- 恢复文档包含完整步骤和故障排查指南

### Phase 5: 监控完善（v1.x 监控和自动化测试）

**理由：** 系统稳定运行后，添加监控增强和异常检测。这是运维效率的提升。

**交付物：**
- 优化通知内容（包含备份大小、时长、数据库列表）
- 添加备份状态可视化（可选）
- 添加异常检测（文件大小突变告警）
- 备份耗时追踪（IM-7）

**覆盖需求：** IM-2（完整告警）、IM-7（耗时追踪）、NH-4（上传进度日志）

**避免陷阱：** Pitfall 8（监控盲区）

**验证标准：**
- 备份失败时 webhook 通知包含详细错误信息
- 备份文件大小突变（>50% 偏差）时触发 WARNING
- Jenkins Dashboard 显示备份时长趋势

### 阶段顺序理由

- **依赖关系：** Phase 1（本地备份）是所有后续功能的基础。Phase 2（云存储）依赖可靠的本地备份。Phase 3（Jenkins 自动化）依赖云存储集成完成。Phase 4（恢复和验证）是系统集成的最终验证。Phase 5（监控完善）在系统稳定后添加
- **风险控制：** 每个阶段都有可验证的交付物，避免一次性构建复杂系统。如果某个阶段出现问题，可以回滚到上一个稳定状态
- **价值交付：** Phase 1-3 完成 MVP（核心备份+上传+恢复），满足 BACKUP-01 到 BACKUP-05。Phase 4-5 添加监控告警和自动化测试，满足 BACKUP-06、BACKUP-07、BACKUP-08

### 研究标记

**需要深度调研的阶段（运行 `/gsd-research-phase`）：**
- **无** - 所有阶段都有明确的技术路径和最佳实践。PostgreSQL 官方文档、Backblaze B2 文档、rclone 文档提供了详细的实现指南。当前项目的 Jenkins 基础设施和 SOPS 加密体系已验证可行

**标准模式的阶段（跳过 research-phase）：**
- **Phase 1（本地备份增强）：** pg_dump 是 PostgreSQL 17.9 内置工具，官方文档详细。docker exec 调用方式是标准 Docker 模式
- **Phase 2（云存储集成）：** rclone + Backblaze B2 是成熟方案，STACK.md 已完成成本分析和技术选型。SOPS 加密体系项目已有
- **Phase 3（Jenkins 自动化）：** Jenkins Pipeline 是标准 CI/CD 模式，项目已有 Jenkins 基础设施
- **Phase 4（恢复和验证）：** pg_restore 是 PostgreSQL 内置工具，恢复流程有官方文档支持。每周自动恢复测试是业界最佳实践
- **Phase 5（监控完善）：** Jenkins Dashboard + Webhook 通知是标准监控模式，无需特殊研究

---

## 置信度评估

| 领域 | 置信度 | 说明 |
|------|--------|------|
| 技术栈 | HIGH | 定价来自 2026-04-05 官方页面直接抓取（Backblaze B2、Cloudflare R2、AWS S3）。工具推荐基于 PITFALLS.md 研究和生态系统经验。rclone 是云备份上传的事实标准 |
| 功能 | HIGH | 基于 PostgreSQL 官方文档、B2 官方文档、项目代码库实际配置分析（docker-compose.yml、postgresql.conf、01-create-databases.sql）。FEATURES.md 已完成依赖关系分析和优先级排序 |
| 架构 | HIGH | 基于项目代码库直接分析（docker-compose.yml、deploy.sh、config/secrets.sops.yaml）。STACK.md 技术决策已验证可行。架构模式基于 Docker + PostgreSQL + 云存储的最佳实践 |
| 陷阱 | HIGH | 所有陷阱都有明确的触发条件、后果、预防措施和验证标准。PostgreSQL 官方文档、Backblaze B2 官方文档、项目代码库实际配置提供了支持 |

**总体置信度：** HIGH

### 需要处理的缺口

**技术债务（需要立即处理）：**
- **当前 .env.production 已被 Git 追踪** - 包含数据库密码等敏感信息。需要立即从 Git 历史中移除（git filter-branch 或 BFG Repo-Cleaner），并确保 .gitignore 包含 .env*
- **01-create-databases.sql 中硬编码密码** - keycloak_password_change_me、findclass_password_change_me 以明文存储在 Git 中。应该使用环境变量传入密码

**实施阶段需要验证的问题：**
- **PostgreSQL 版本匹配** - 确保 Jenkins 容器或宿主机上的 pg_dump 版本与 PostgreSQL 容器（17.9）匹配。版本不匹配可能导致备份失败或恢复错误
- **rclone 配置管理** - rclone 配置文件（config/backup/rclone.conf）不包含凭据（凭据在 Jenkins Credentials 中），只包含 B2 endpoint 和 account ID。需要在实施阶段验证这种分离方式可行
- **WAL 归档策略** - 当前 postgresql.conf 已启用 archive_mode = on，但 WAL 归档文件只存储在本地 Docker volume 中。需要评估是否关闭 archive_mode（如果不使用 PITR），减少不必要的磁盘 I/O 和存储

**未来升级路径（不需要现在处理）：**
- **数据库增长到 >10GB** - 可以升级到 pg_dump -Fd -j 4（并行备份）。恢复测试可以验证当前脚本结构是否支持平滑升级
- **需要更频繁备份 / PITR** - 可以升级到 pgBackRest（物理备份 + 增量 + PITR）。当前架构的脚本结构（编排 -> 转储 -> 上传 -> 验证）可以复用
- **多节点 / 高可用** - 可以升级到 WAL-G + 流复制。每个升级步骤都是独立的，不需要重写之前的架构

---

## 数据源

### 主要来源（HIGH 置信度）

- **Backblaze B2 定价页面**（https://www.backblaze.com/cloud-storage/pricing）- 2026-04-05 官方页面直接抓取。存储费用 $6/TB/月，免费 egress 3x
- **Backblaze B2 API 交易定价**（https://www.backblaze.com/cloud-storage/transaction-pricing）- Class A 免费，Class B/C 每天 2,500 次免费
- **Backblaze B2 生命周期规则文档**（https://www.backblaze.com/docs/cloud-storage-lifecycle-rules）- 规则语义、版本管理、daysFromHidingToDeleting vs daysFromUploadingToHiding
- **Backblaze B2 Application Keys 文档**（https://www.backblaze.com/docs/cloud-storage-application-keys）- Standard vs Master Key、权限限制、最佳实践
- **PostgreSQL 官方文档：SQL Dump**（https://www.postgresql.org/docs/current/backup-dump.html）- pg_dump 备份策略、恢复流程、格式选择
- **PostgreSQL 官方文档：app-pgdump**（https://www.postgresql.org/docs/current/app-pgdump.html）- -Fc 格式说明、并行恢复支持
- **PostgreSQL 官方文档：app-pgrestore**（https://www.postgresql.org/docs/current/app-pgrestore.html）- 恢复选项、错误处理
- **rclone 官方文档**（https://rclone.org/）- B2 后端配置、校验和验证、重试机制
- **项目代码库直接分析** - docker-compose.yml、docker-compose.prod.yml、postgresql.conf、01-create-databases.sql、deploy.sh、config/secrets.sops.yaml

### 次要来源（MEDIUM 置信度）

- **Cloudflare R2 定价页面**（https://www.cloudflare.com/developer-platform/products/r2/）- 2026-04-05 官方页面抓取。R2 存储和操作定价
- **AWS S3 定价页面**（https://aws.amazon.com/s3/pricing/）- 2026-04-05 官方页面抓取。S3 存储和请求定价
- **Hetzner Storage Box 文档**（https://docs.hetzner.com/storage/storage-box/general）- Storage Box 功能和限制。BX11 价格基于已知价格（~EUR 4.15/月）
- **Google Cloud Storage 定价页面**（https://cloud.google.com/storage/pricing）- GCS Nearline 定价。新西兰出口费用基于页面抓取和训练数据补充

### 第三级来源（LOW 置信度，需要验证）

- **Wasabi 定价** - 最低计费 1TB（$6.99/月），不适合小规模场景。定价基于 STACK.md 研究，实施时需要验证
- **IDrive e2、Scaleway** - 替代方案定价基于 STACK.md 研究，如果将来需要切换存储提供商，需要重新验证最新定价

---

**调研完成：** 2026-04-06
**准备就绪用于路线图：** 是
**下一步：** 运行 `/gsd-roadmap` 基于本摘要创建详细的实施路线图
