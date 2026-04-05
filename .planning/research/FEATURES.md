# Feature Research

**Domain:** PostgreSQL 云备份系统（Docker 容器 + Backblaze B2 云存储）
**Researched:** 2026-04-06
**Confidence:** HIGH（基于 PostgreSQL 官方文档、B2 官方文档、项目代码库实际配置分析、STACK.md 技术选型）

---

## Feature Landscape

### Table Stakes（必备特性）

缺少这些特性，系统不可用于生产环境。用户不会因为你有这些而赞赏，但没有的话系统就是残缺的。

| # | Feature | Why Expected | Complexity | Deps | Notes |
|---|---------|--------------|------------|------|-------|
| TS-1 | 多数据库完整备份（pg_dump -Fc） | PostgreSQL 有两个活跃数据库（keycloak_db、findclass_db），缺一个就意味着灾难恢复时数据不完整。keycloak_db 丢失导致全部认证失效 | LOW | 无 | 用 -Fc 自定义格式，自带 zlib 压缩且支持并行恢复。必须对每个数据库单独运行 pg_dump。数据库列表从配置文件读取，当前为 keycloak_db、findclass_db |
| TS-2 | 全局对象备份（pg_dumpall --globals-only） | pg_dump 不备份角色和表空间定义。恢复时缺少角色（keycloak_user、findclass_user）导致权限错误，所有应用无法连接数据库 | LOW | TS-1 | 单独运行，输出角色+表空间定义。与数据库备份分开存储 |
| TS-3 | 备份文件命名规范（时间戳+数据库名） | 28 个备份文件（7天 x 每天4次）没有规范命名就无法识别和排序，清理逻辑也无法判断文件年龄 | LOW | TS-1 | 格式：`{db_name}_{YYYYMMDD_HHmmss}.dump`。使用 Pacific/Auckland 时区（与 postgresql.conf 中 timezone='Pacific/Auckland' 一致） |
| TS-4 | 自定义压缩格式（pg_dump -Fc） | 未压缩的纯 SQL 文件是数据库实际大小的 3-5 倍，增加存储成本和上传时间。-Fc 自带压缩无需额外处理 | LOW | TS-1 | -Fc 格式自带 zlib 压缩，不要再用 gzip 二次压缩。同时支持并行恢复（pg_restore -j） |
| TS-5 | 云存储自动上传（rclone） | 备份只存本地等于没有备份——服务器磁盘损坏则备份同时丢失 | MEDIUM | TS-1, TS-3 | 使用 rclone（STACK.md 推荐）上传到 Backblaze B2。rclone 自带校验和验证和重试机制，比 AWS CLI 更适合。上传后立即删除本地临时文件 |
| TS-6 | 上传失败重试（指数退避） | 网络不稳定时上传中断很常见。没有重试机制会导致备份看似成功实则未上传，灾难时才发现没有云端备份 | LOW | TS-5 | rclone 内置重试机制（--retries 3 --retries-sleep 10s）。脚本层面也需检查 rclone 退出码 |
| TS-7 | 上传后校验和验证 | 网络传输可能静默损坏文件。不验证的话，恢复时才发现备份已损坏为时已晚 | LOW | TS-5 | rclone copy 自带校验和对比（--checksum）。备份前计算 SHA256 作为元数据记录，上传后 rclone 自动验证 |
| TS-8 | 应用层保留清理（7天策略） | B2 生命周期规则对时间戳命名的独立文件无效（PITFALLS #3）。没有清理则存储成本无限增长 | MEDIUM | TS-3, TS-5 | 使用 rclone delete --min-age 7d 清理旧备份。保留 8 天安全缓冲。同时清理本地残留文件 |
| TS-9 | 一键恢复脚本 | 备份的最终目的是恢复。没有恢复脚本的备份系统在灾难时刻需要手动操作，出错概率极高 | MEDIUM | TS-1, TS-5 | rclone 从 B2 下载 -> createdb -T template0 -> pg_restore -> ANALYZE。必须包含完整错误处理和回滚逻辑 |
| TS-10 | 结构化日志 | 没有日志就无法知道备份是否正常运行。结构化日志是所有后续监控和告警的基础 | LOW | 无 | 包含：时间戳、数据库名、文件大小、耗时、状态（成功/失败）、错误详情。输出到 stdout（Jenkins 采集）和日志文件 |
| TS-11 | 凭证通过环境变量管理 | 硬编码密钥 = 代码仓库泄露 = 所有备份数据暴露（PITFALLS #4）。当前 01-create-databases.sql 已有明文密码问题，备份系统不能重蹈覆辙 | LOW | 无 | 所有凭证（B2 Key、DB 密码）通过环境变量传入。使用 Jenkins Credentials 管理 rclone 配置。绝不硬编码 |
| TS-12 | 最低权限 API Key | Master Key 泄露影响整个 B2 账户。专用受限 Key 泄露只影响备份 bucket | LOW | TS-11 | 创建 B2 Standard Application Key：仅限备份 bucket + readFiles + writeFiles + deleteFiles + listFiles + fileNamePrefix 限制 |
| TS-13 | 备份前健康检查 | PostgreSQL 容器可能已停止或网络不通。盲目执行 pg_dump 会产生空文件或错误文件，误报为"备份成功" | LOW | 无 | docker compose 中已配置 pg_isready 健康检查（interval: 10s）。备份脚本复用此检查，失败则立即退出并告警 |

### Differentiators（差异化特性）

这些特性不是用户默认期望的，但能显著提升备份系统的可靠性和运维效率。

| # | Feature | Value Proposition | Complexity | Deps | Notes |
|---|---------|-------------------|------------|------|-------|
| IM-1 | 备份完整性验证（pg_restore --list） | pg_dump 可能返回 0 但实际备份不完整或损坏（PITFALLS #8）。只有用 pg_restore --list 验证过才算真正成功 | LOW | TS-1 | 备份后立即运行 `pg_restore --list backup.dump`。失败则标记整个备份为失败，不上传 |
| IM-2 | 备份失败告警（Webhook） | 备份静默失败是最危险的——一切看起来正常，直到需要恢复时才发现没有备份 | MEDIUM | TS-10, TS-11 | 失败时发送 Webhook 通知。项目已有 Cloudflare Tunnel 基础设施，可配合企业微信/Slack/Discord webhook。Jenkins post failure 块可直接触发 |
| IM-3 | 列出可用备份 | 恢复时需要知道有哪些备份可用。手动登录 B2 控制台查看效率低且容易出错 | LOW | TS-3, TS-5 | `restore.sh --list` 使用 rclone ls 列出所有可用备份，按时间排序。显示：文件名、大小、日期、数据库 |
| IM-4 | 恢复指定数据库 | 恢复整个集群是不必要的风险。通常只需要恢复某个出问题的数据库 | LOW | TS-9, IM-3 | `restore.sh --database findclass_db --timestamp 20260405_120000`。不影响其他运行中的数据库 |
| IM-5 | 恢复到不同数据库名（安全测试） | 直接恢复到生产数据库进行测试是灾难性行为。需要安全地验证备份是否可用 | MEDIUM | TS-9, IM-4 | `restore.sh --database findclass_db --target-db findclass_db_test`。恢复到临时数据库用于验证，不影响生产 |
| IM-6 | 每周自动恢复测试 | 备份从未被恢复过 = 备份可能不可用。每周自动测试是验证备份有效性的唯一可靠方法（PITFALLS #2） | HIGH | TS-9, IM-5, IM-1 | Jenkins 定时任务：rclone 下载最新备份 -> pg_restore 到临时数据库 -> 验证表/数据完整性 -> 清理临时数据库。失败时告警 |
| IM-7 | 备份持续时间追踪 | 如果备份从 5 分钟增长到 60 分钟，说明数据库在快速增长或出了问题。需要基线对比 | LOW | TS-10 | 记录每次备份的开始/结束时间。与最近 7 天平均值对比，偏差 >50% 时输出 WARNING |
| IM-8 | 磁盘空间检查 | 磁盘空间不足时 pg_dump 可能写入不完整文件但不报错（PITFALLS #8）。备份前检查磁盘空间是必要的预防措施 | LOW | 无 | 备份前检查 Docker volume 可用空间 >= 预估备份大小 x 2。空间不足时跳过并告警 |
| IM-9 | 未完成上传清理 | B2 的 unfinished large files 默认不清理，持续计费（PITFALLS #6）。需要在应用层处理 | LOW | TS-5, TS-8 | 设置 B2 bucket 生命周期规则：`daysFromStartingToCancelingUnfinishedLargeFiles: 1`。rclone 也会自动清理中断的上传 |
| IM-10 | 结构化错误处理和退出码 | 脚本没有统一退出码，监控系统无法判断备份是否成功。Jenkins 需要标准退出码来标记构建状态 | LOW | 无 | 定义标准退出码：0=成功、1=连接失败、2=备份失败、3=上传失败、4=清理失败、5=验证失败 |

### Anti-Features（明确不做的特性）

这些特性看起来有用，但实际上会增加复杂度、成本或风险，或者与项目需求不匹配。

| # | Feature | Why Requested | Why Problematic | Alternative |
|---|---------|---------------|-----------------|-------------|
| AF-1 | 增量备份（pg_basebackup + WAL） | 看似节省存储和时间 | PostgreSQL 完整备份对当前数据库规模已足够快。增量备份需要管理 WAL 归档链，恢复流程复杂度高，容错率低。对于小型数据库，增量备份节省的空间不值得增加的复杂度 | 保持 pg_dump -Fc 完整备份，简单可靠 |
| AF-2 | 实时复制/流备份 | 最高级别的数据保护 | 需要主从架构，至少双倍基础设施成本。当前项目是小型生产环境，6-12 小时 RPO 完全满足需求。实时复制是大型企业或金融场景的需求 | pg_dump 定时备份 + 6-12 小时 RPO |
| AF-3 | PITR 时间点恢复 | 理论上能恢复到任意时间点 | 需要基础备份 + 完整 WAL 归档链，复杂度极高。恢复步骤多，出错概率大。当前已有 WAL 归档配置但只存本地 Docker volume，未配合云上传，形成了技术债务（PITFALLS #9） | 使用 pg_dump 多频率备份实现粗粒度时间点恢复（每 6 小时一个恢复点） |
| AF-4 | 跨区域备份复制 | 地理灾难恢复 | 增加存储成本（至少翻倍）和管理复杂度。B2 本身已有数据中心冗余。对于新西兰小型生产环境，单区域存储足够 | B2 单区域存储 + 本地短期备份 |
| AF-5 | 手动备份触发 Web UI | 方便运维手动触发 | 增加一个 Web UI 的开发和维护成本。Jenkins 已提供手动触发能力（Build Now 按钮）和参数化构建。Web UI 还需要额外的认证和授权 | 通过 Jenkins 手动触发备份任务，或命令行 `./backup.sh --now` |
| AF-6 | 自定义客户端加密方案 | 更高的安全性幻觉 | 自定义加密容易出错（密钥管理、加密库选择、IV 处理），反而降低安全性。如果需要客户端加密，rclone crypt 是成熟方案而非自行实现 | B2 SSE-B2（默认存储加密）+ 严格 API Key 权限管理。需要更高安全性时用 rclone crypt |
| AF-7 | 备份压缩格式选择（gzip/zstd/lz4） | 灵活性 | pg_dump -Fc 已内置 zlib 压缩，效果足够好。提供多种压缩格式选择增加测试矩阵（每种格式都需要测试备份+恢复流程），没有实际收益 | 统一使用 -Fc 格式，不提供压缩选项 |
| AF-8 | 数据库自动发现 | 动态发现所有数据库并备份 | 自动发现会备份 template0/template1 等系统数据库，浪费空间。如果新创建了数据库但忘记配置备份参数（用户名等），可能备份不完整 | 在配置文件中明确列出需要备份的数据库列表（当前：keycloak_db、findclass_db），新增数据库时手动添加 |
| AF-9 | 备份文件保留策略可配置（保留天数/数量） | 灵活性 | 增加配置复杂度和测试负担。7天保留策略是项目约束中已明确的。过早提供配置选项意味着需要测试多种组合 | 硬编码 7 天保留策略。如需调整，直接修改配置文件中的 RETENTION_DAYS 常量 |
| AF-10 | Web 管理面板 | 可视化管理备份 | 需要额外开发和维护 Web 前端+后端+认证。对于 2 个数据库的备份系统来说完全过度。Jenkins 已提供日志查看和历史记录 | Jenkins 控制台 + 命令行脚本 + 结构化日志文件 |

## Feature Dependencies

```
[TS-13 健康检查] ──requires──> [TS-1 多数据库备份] ──requires──> [TS-5 云存储上传(rclone)]
       |                            |                                  |
       |                            ├──includes──> [TS-2 全局对象备份]   ├──includes──> [TS-6 上传重试(rclone内置)]
       |                            |                                  ├──includes──> [TS-7 校验和验证(rclone内置)]
       |                            ├──includes──> [TS-3 命名规范]       └──requires──> [TS-8 保留清理(rclone delete)]
       |                            └──includes──> [TS-4 -Fc 格式]                |
       |                                                                  ├──includes──> [IM-9 未完成上传清理]
       |                                                                  └──requires──> [TS-9 恢复脚本]
       |                                                                       |
       |                                                                       ├──enhances──> [IM-3 列出备份(rclone ls)]
       |                                                                       ├──enhances──> [IM-4 恢复指定库]
       |                                                                       └──enhances──> [IM-5 恢复到测试库]
       |                                                                            |
       |                                                                            └──requires──> [IM-6 自动恢复测试]
       |
       ├──standalone──> [TS-10 日志] ──enhances──> [IM-2 失败告警]
       |                         └──enhances──> [IM-7 耗时追踪]
       |                         └──enhances──> [NH-1 存储用量]
       |
       ├──standalone──> [TS-11 凭证管理] ──includes──> [TS-12 最低权限 Key]
       |
       └──standalone──> [IM-8 磁盘空间检查]

[IM-1 备份验证] ──enhances──> [TS-1]（验证备份文件完整性）
[IM-10 退出码] ──enhances──> 所有脚本（统一错误处理）

[AF-3 PITR] ──conflicts──> [TS-4 -Fc 格式]（PITR 需要物理备份，-Fc 是逻辑备份）
[AF-8 自动发现] ──conflicts──> [TS-1]（显式数据库列表更安全）
```

### Dependency Notes

- **TS-1 是核心节点：** 多数据库备份是所有其他特性的基础。没有备份就没有上传、没有恢复、没有测试
- **TS-9 恢复脚本是第二核心：** 恢复测试（IM-6）依赖恢复脚本。恢复脚本依赖上传功能（需要从云端下载）
- **TS-10 日志是横切关注点：** 几乎所有特性都依赖日志，但日志本身独立于备份流程
- **IM-6 是最复杂特性：** 恢复测试依赖完整的备份+上传+恢复链路，是系统集成的最终验证
- **TS-13 健康检查是第一道防线：** 必须最先执行，避免在数据库不可用时浪费时间和空间
- **rclone 简化了 TS-6 和 TS-7：** 相比之前方案用 AWS CLI 需手动实现重试和校验，rclone 内置这些功能，显著降低实现复杂度
- **TS-1 requires TS-13:** 健康检查必须先于备份执行，否则可能在数据库不可用时产生无效备份文件
- **IM-5 enhances IM-4:** 恢复到测试库是恢复指定库功能的扩展，共享大部分逻辑
- **AF-3 conflicts TS-4:** PITR 需要物理备份（pg_basebackup），而 -Fc 是逻辑备份格式，两者不兼容

## MVP Definition

### Launch With (v1 -- 核心备份+上传+恢复)

最小可用产品。能自动备份、上传、清理、恢复。覆盖 PROJECT.md 中的 BACKUP-01 到 BACKUP-05。

- [ ] **TS-13 健康检查** -- 避免在数据库不可用时执行备份，复用 docker compose 已有的 pg_isready
- [ ] **TS-1 多数据库备份** -- 核心功能，逐一备份 keycloak_db 和 findclass_db
- [ ] **TS-2 全局对象备份** -- 与数据库备份一起，备份角色（keycloak_user、findclass_user）和表空间
- [ ] **TS-3 命名规范** -- 时间戳+数据库名（Pacific/Auckland 时区），支持后续清理和恢复
- [ ] **TS-4 -Fc 格式** -- 自带压缩+并行恢复支持
- [ ] **TS-10 结构化日志** -- 时间、库名、大小、耗时、状态，输出到 stdout 和日志文件
- [ ] **TS-11 凭证管理** -- 环境变量传入，不硬编码，Jenkins Credentials 管理 rclone 配置
- [ ] **TS-12 最低权限 Key** -- 受限 B2 Standard Application Key
- [ ] **IM-1 备份验证** -- pg_restore --list 验证备份完整性，验证失败则不上传
- [ ] **IM-8 磁盘空间检查** -- 备份前检查 Docker volume 可用空间
- [ ] **IM-10 统一退出码** -- 支持监控系统（Jenkins）判断状态
- [ ] **TS-5 云存储上传（rclone）** -- 上传到 B2，上传后删除本地临时文件
- [ ] **TS-6 上传重试** -- rclone 内置重试 + 脚本层面检查退出码
- [ ] **TS-7 校验和验证** -- rclone --checksum 自动验证
- [ ] **TS-8 保留清理** -- rclone delete --min-age 7d 删除旧备份
- [ ] **IM-9 未完成上传清理** -- B2 bucket 生命周期规则 + rclone 自动处理
- [ ] **TS-9 一键恢复脚本** -- rclone 下载 -> createdb -T template0 -> pg_restore -> ANALYZE
- [ ] **IM-3 列出可用备份** -- rclone ls 列出所有可用备份
- [ ] **IM-4 恢复指定数据库** -- 恢复单个数据库，不影响其他运行中的库
- [ ] **Jenkins Pipeline** -- 定时调度（H */6 * * *）+ 手动触发 + 失败通知

### Add After Validation (v1.x -- 监控和自动化测试)

核心备份验证可用后，添加监控和自动化测试。覆盖 BACKUP-06、BACKUP-07、BACKUP-08。

- [ ] **IM-2 备份失败告警（Webhook）** -- Jenkins post failure 块触发 Webhook 通知
- [ ] **IM-5 恢复到测试库** -- 安全验证备份可用性，恢复到 findclass_db_test 等临时库
- [ ] **IM-6 每周自动恢复测试** -- Jenkins 定时任务验证恢复流程，最终可靠性保障
- [ ] **IM-7 备份耗时追踪** -- 监控备份性能趋势，早期发现数据库增长问题
- [ ] **NH-4 上传进度日志** -- rclone --progress 配合 Jenkins 日志输出

### Future Consideration (v2+ -- 优化和增强)

系统稳定运行后再考虑。

- [ ] **NH-1 存储用量追踪** -- 成本监控和趋势分析
- [ ] **NH-6 恢复后数据完整性校验** -- 行数/表数对比，自动化验证
- [ ] **NH-5 客户端加密（rclone crypt）** -- 更高安全要求时的升级路径
- [ ] **NH-10 备份预览** -- pg_restore --list 输出作为元数据一起上传，方便远程诊断

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority | Requirement |
|---------|------------|---------------------|----------|-------------|
| TS-1 多数据库备份 | HIGH | LOW | P1 | BACKUP-01 |
| TS-2 全局对象备份 | HIGH | LOW | P1 | BACKUP-01 |
| TS-3 命名规范 | HIGH | LOW | P1 | -- |
| TS-4 -Fc 格式 | HIGH | LOW | P1 | -- |
| TS-5 云存储上传(rclone) | HIGH | MEDIUM | P1 | BACKUP-02 |
| TS-6 上传重试 | HIGH | LOW | P1 | BACKUP-02 |
| TS-7 校验和验证 | HIGH | LOW | P1 | BACKUP-02 |
| TS-8 保留清理 | HIGH | MEDIUM | P1 | BACKUP-03 |
| TS-9 恢复脚本 | HIGH | MEDIUM | P1 | BACKUP-05 |
| TS-10 结构化日志 | HIGH | LOW | P1 | BACKUP-08 |
| TS-11 凭证管理 | HIGH | LOW | P1 | -- |
| TS-12 最低权限 Key | HIGH | LOW | P1 | BACKUP-04 |
| TS-13 健康检查 | HIGH | LOW | P1 | -- |
| IM-1 备份验证 | HIGH | LOW | P1 | -- |
| IM-3 列出备份 | MEDIUM | LOW | P1 | -- |
| IM-4 恢复指定库 | MEDIUM | LOW | P1 | -- |
| IM-8 磁盘空间检查 | HIGH | LOW | P1 | -- |
| IM-9 未完成上传清理 | MEDIUM | LOW | P1 | -- |
| IM-10 统一退出码 | MEDIUM | LOW | P1 | -- |
| IM-2 失败告警 | HIGH | MEDIUM | P2 | BACKUP-07 |
| IM-5 恢复到测试库 | MEDIUM | MEDIUM | P2 | -- |
| IM-6 自动恢复测试 | HIGH | HIGH | P2 | BACKUP-06 |
| IM-7 耗时追踪 | LOW | LOW | P2 | BACKUP-08 |
| NH-1 存储用量 | LOW | LOW | P3 | BACKUP-08 |
| NH-5 客户端加密 | LOW | MEDIUM | P3 | BACKUP-04 |
| NH-6 数据完整性校验 | MEDIUM | MEDIUM | P3 | -- |

**Priority key:**
- P1: 必须在 v1 发布 -- 核心备份恢复功能
- P2: v1.x 发布 -- 监控告警和自动化测试
- P3: v2+ 发布 -- 优化增强

## Competitor Feature Analysis

| Feature | pg_dump 脚本（本项目） | pgBackRest | Barman | pg_probackup |
|---------|----------------------|------------|--------|-------------|
| 完整备份 | pg_dump -Fc | 增量+完整 | 增量+完整 | 增量+完整 |
| 备份格式 | 自定义二进制(-Fc) | 专用压缩格式 | 专用格式 | 专用格式 |
| 多数据库 | 逐一 pg_dump | 集群级（物理） | 集群级（物理） | 集群级（物理） |
| 云存储 | rclone + B2 | 原生 S3 支持 | S3/SSH | 本地为主 |
| 恢复粒度 | 单数据库/单表 | 集群级 | 集群级 | 集群级 |
| 并行恢复 | pg_restore -j | 原生并行 | 原生并行 | 原生并行 |
| PITR | 不支持 | 支持 | 支持 | 支持 |
| 复杂度 | LOW（shell 脚本） | HIGH（配置多） | HIGH | MEDIUM |
| Docker 兼容 | HIGH（标准工具） | MEDIUM（需要配置） | LOW（不适合） | MEDIUM |
| 维护成本 | LOW | MEDIUM | HIGH | MEDIUM |
| 适合规模 | <10GB | >10GB | >10GB | >10GB |

**本项目选择 pg_dump 脚本的理由：** 数据库规模小（预估 <1GB）、Docker 环境、不需要 PITR、不需要增量备份。pg_dump 是 PostgreSQL 17.9 自带工具，无额外依赖，与 Docker 环境天然兼容。pgBackRest/Barman 是为大规模集群设计的，对当前项目来说是过度工程。

## Feature-to-Pitfall Mapping

| Pitfall | Related Features | How Resolved |
|---------|-----------------|-------------|
| #1 多数据库遗漏 | TS-1, TS-2 | 显式列出所有数据库（keycloak_db、findclass_db），逐一备份 + pg_dumpall --globals-only |
| #2 恢复失败 | TS-4, TS-9, IM-1, IM-6 | -Fc 格式 + 完整恢复脚本 + 备份验证 + 自动恢复测试 |
| #3 B2 生命周期规则误配 | TS-8, IM-9 | 应用层清理（rclone delete --min-age 7d，不依赖 B2 规则） + 未完成上传清理 |
| #4 凭证硬编码 | TS-11, TS-12 | 环境变量 + 受限 B2 Standard Key + Jenkins Credentials |
| #5 Docker 调度失效 | TS-10 | Jenkins cron 调度（不在 Docker 容器内运行 cron） + 结构化日志 |
| #6 网络传输失败 | TS-6, TS-7 | rclone 内置重试和校验和验证 |
| #7 未压缩备份 | TS-4 | pg_dump -Fc 自带 zlib 压缩 |
| #8 监控盲区 | IM-1, IM-8, IM-10 | 备份验证（pg_restore --list） + 磁盘检查 + 统一退出码 |
| #9 WAL 归档混淆 | AF-3 | 明确不用 PITR。当前 WAL 归档只存本地（postgresql.conf: archive_command 指向本地目录），备份策略基于 pg_dump 逻辑备份，与 WAL 物理备份独立 |
| #10 加密误解 | TS-12, AF-6 | SSE-B2 + 严格 Key 权限（不自行实现加密）。未来需要时用 rclone crypt |

## MVP Work Estimation

| Module | Features | Est. Hours | Notes |
|--------|----------|-----------|-------|
| 备份脚本 | TS-1, TS-2, TS-3, TS-4, TS-10, TS-13, IM-1, IM-8, IM-10 | 4-6h | 核心逻辑，覆盖 keycloak_db + findclass_db |
| 云存储上传 | TS-5, TS-6, TS-7, TS-8, IM-9 | 3-5h | rclone + B2 S3 API（rclone 简化了重试和校验逻辑） |
| 恢复脚本 | TS-9, IM-3, IM-4 | 3-4h | 完整恢复流程：rclone 下载 -> pg_restore |
| 凭证安全 | TS-11, TS-12 | 1-2h | 创建 B2 Key + rclone 配置 + 环境变量 |
| Jenkins Pipeline | 定时调度 + 手动触发 | 2-3h | Jenkinsfile 配置 + Credentials 绑定 |
| **v1 总计** | | **13-20h** | 约 2-3 个工作日 |

| Module | Features | Est. Hours | Notes |
|--------|----------|-----------|-------|
| 告警通知 | IM-2 | 2-3h | Webhook 集成（Jenkins post block） |
| 恢复测试 | IM-5, IM-6 | 4-6h | 自动化测试流水线 |
| 监控增强 | IM-7 | 1-2h | 耗时追踪 |
| **v1.x 总计** | | **7-11h** | 约 1-2 个工作日 |

## Sources

- PostgreSQL 官方文档：SQL Dump (https://www.postgresql.org/docs/current/backup-dump.html) -- pg_dump 备份策略、恢复流程、格式选择
- PostgreSQL 官方文档：app-pgdump (https://www.postgresql.org/docs/current/app-pgdump.html) -- -Fc 格式说明、并行恢复支持
- PostgreSQL 官方文档：app-pgrestore (https://www.postgresql.org/docs/current/app-pgrestore.html) -- 恢复选项、错误处理
- Backblaze B2 文档：Application Keys (https://www.backblaze.com/docs/cloud-storage-application-keys) -- Key 权限模型、最佳实践
- Backblaze B2 文档：Lifecycle Rules (https://www.backblaze.com/docs/cloud-storage-lifecycle-rules) -- 规则语义、版本管理限制
- Backblaze B2 文档：S3 Compatible API (https://www.backblaze.com/docs/cloud-storage-s3-compatible-api) -- 兼容性、不支持的功能
- rclone 官方文档 (https://rclone.org/docs/) -- B2 后端配置、校验和验证、重试机制
- Noda 项目代码库：docker-compose.yml、docker-compose.prod.yml、postgresql.conf、01-create-databases.sql
- Noda 项目 STACK.md -- 技术选型（rclone 优先于 AWS CLI）
- Noda 项目 PITFALLS.md -- 已知陷阱和解决方案

---
*Feature research for: Noda PostgreSQL 云备份系统*
*Researched: 2026-04-06*
