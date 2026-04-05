# Phase 1: 本地备份核心 - Context

**Gathered:** 2026-04-06
**Status:** Ready for planning

## Phase Boundary

建立可靠的多数据库本地备份流程，运维人员可以手动执行备份脚本，备份所有数据库到本地文件系统，并立即验证备份完整性。

## Implementation Decisions

### 数据库备份策略
- **D-01:** 自动发现并备份所有用户数据库（通过查询 pg_database 系统表排除系统数据库）
- **D-02:** 必须单独备份全局对象（角色、表空间定义），使用 `pg_dumpall -g` 命令
- **D-03:** 严格使用 `pg_dump -Fc` 格式（PostgreSQL 自定义压缩格式，自带 zlib 压缩）
- **D-04:** 串行备份每个数据库（不并行），使用默认压缩级别

### 健康检查与验证
- **D-05:** 备份前仅使用 `pg_isready` 检查 PostgreSQL 连接状态
- **D-06:** 每次备份后立即验证（`pg_restore --list` + SHA-256 校验和）
- **D-07:** 遇到错误立即失败，不继续备份其他数据库
- **D-08:** 严格遵循 MONITOR-05 错误退出码：0=成功、1=连接失败、2=备份失败、3=上传失败、4=清理失败、5=验证失败

### 存储与文件管理
- **D-09:** 备份文件存储在 Docker volume 映射的宿主机目录
- **D-10:** 备份目录结构按日期分层（如 2026/04/06/）
- **D-11:** 备份文件命名严格遵循需求格式：`{db_name}_{YYYYMMDD_HHmmss}.dump`
- **D-12:** 全局对象备份文件使用固定命名：`globals_{timestamp}.sql`
- **D-13:** 备份文件权限设置为严格的 600（仅所有者可读写）
- **D-14:** 同时检查 Docker volume 和宿主机的磁盘空间
- **D-15:** 磁盘空间检查阈值：数据库大小 × 2
- **D-16:** 备份失败时清理所有已创建的备份文件
- **D-17:** 实现本地清理策略，按天数保留旧备份（通过环境变量配置天数）

### 脚本功能与接口
- **D-18:** 脚本名称：`backup-postgres.sh`
- **D-19:** 使用 Bash 编写，主脚本 + 库文件结构
- **D-20:** 默认无参数直接备份所有数据库
- **D-21:** 提供 `--list-databases` 参数列出所有可备份的数据库
- **D-22:** 提供 `--dry-run` 模式模拟备份执行
- **D-23:** 提供锁定机制防止并发执行（使用 PID 文件）
- **D-24:** 自动清理过期的锁定文件
- **D-25:** 显示详细进度信息（当前数据库、完成百分比、预计剩余时间）
- **D-26:** 简洁日志输出到标准输出（关键信息）

### 配置与元数据
- **D-27:** 使用 `.env.backup` 模板文件管理配置
- **D-28:** 配置优先级：命令行参数 > .env 文件 > 默认值
- **D-29:** 生成 JSON 格式元数据文件记录每次备份
- **D-30:** 记录备份历史（JSON 格式）到备份目录

### 技术实现
- **D-31:** 使用 `docker exec` 方式在容器内执行备份命令
- **D-32:** 全局对象备份使用 `pg_dumpall -g` 命令
- **D-33:** 通过 Unix socket 连接到 PostgreSQL（容器内本地连接）
- **D-34:** 使用 `.pgpass` 文件管理数据库密码（避免硬编码）

### 性能与优化
- **D-35:** 设置固定超时时间（如 1 小时）
- **D-36:** 使用默认压缩级别（平衡速度和大小）

### 代码结构
- **D-37:** 库文件按功能划分（db.sh、log.sh、util.sh 等）
- **D-38:** 脚本中包含详细注释和文档头

### 安全性
- **D-39:** 创建审计日志记录所有备份操作
- **D-40:** 使用 Git 标签管理版本

### 扩展性
- **D-41:** 设计插件架构，便于后续添加云存储功能（Phase 2）
- **D-42:** 预留通知接口，便于集成监控告警（Phase 5）

### 测试
- **D-43:** 提供 `--test` 模式，创建测试数据库并验证完整备份和恢复流程
- **D-44:** 支持 macOS 和 Linux 操作系统

### 文档
- **D-45:** 在备份目录创建详细的恢复文档（RESTORE.md）
- **D-46:** 提供详细的错误消息和解决建议

### 日志格式
- **D-47:** 使用 JSON 格式日志便于解析

### Claude's Discretion
以下方面由 Claude 在规划和实现时决定：
- 备份超时的具体时间值（建议 1 小时）
- 本地清理策略的默认保留天数（建议 7 天）
- 进度显示的具体格式和更新频率
- 元数据文件的具体字段和结构
- 审计日志的具体内容和格式
- 库文件的具体函数划分和命名
- 测试模式的具体实现细节

## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 需求规范
- `.planning/REQUIREMENTS.md` — 完整的需求列表，包括 BACKUP-01 到 BACKUP-05、VERIFY-01、MONITOR-04
- `.planning/REQUIREMENTS.md` §Backup — 备份执行需求（BACKUP-01 到 BACKUP-05）
- `.planning/REQUIREMENTS.md` §Verify — 验证测试需求（VERIFY-01）
- `.planning/REQUIREMENTS.md` §Monitor — 监控告警需求（MONITOR-04、MONITOR-05）

### 项目文档
- `.planning/PROJECT.md` — 项目概述、核心价值、约束条件
- `.planning/PROJECT.md` §Current Infrastructure — 当前基础设施状态
- `.planning/PROJECT.md` §Constraints — 成本、频率、保留期、安全性等约束

### 路线图
- `.planning/ROADMAP.md` §Phase 1 — 阶段 1 目标、需求和成功标准
- `.planning/ROADMAP.md` §Progress — 执行顺序和进度跟踪

### 现有代码参考
- `services/postgres/init/01-create-databases.sql` — 数据库初始化脚本，了解数据库架构
- `scripts/verify/quick-verify.sh` — 现有验证脚本，了解脚本模式和 Docker 命令使用方式
- `docker/docker-compose.app.yml` — Docker Compose 配置，了解服务架构

## Existing Code Insights

### Reusable Assets
- **scripts/verify/quick-verify.sh**: 可以参考其 Docker 命令执行模式和输出格式
- **docker/.env**: 现有环境变量配置文件（虽然存在安全问题，但可以作为模式参考）

### Established Patterns
- **Docker 命令模式**: 现有脚本使用 `docker exec` 在容器内执行命令
- **环境变量管理**: 使用 `.env` 文件管理配置
- **数据库连接**: PostgreSQL 运行在 Docker 容器中，容器名为 `noda-postgres`
- **数据库架构**: 独立数据库架构（keycloak_db、findclass_db 等）
- **输出格式**: 现有脚本使用清晰的符号和格式（✅、❌、⚠️）

### Integration Points
- **Docker 容器**: noda-postgres（PostgreSQL 17.9）
- **数据库列表**: keycloak_db、findclass_db（以及未来规划的数据库）
- **备份目录**: /var/lib/postgresql/backup（容器内）
- **环境配置**: .env.production（需要处理安全问题）

### 创造性选项
- **自动发现数据库**: 可以通过查询 `pg_database` 系统表自动发现所有用户数据库
- **插件架构**: 可以设计函数化的备份流程，便于后续扩展云存储功能
- **元数据驱动**: 可以使用 JSON 元数据文件驱动清理、验证和恢复功能

## Specific Ideas

### 备份脚本行为
- "我希望备份脚本像 quick-verify.sh 一样有清晰的输出和错误处理"
- "备份文件应该按日期分层存储，便于查找和管理"
- "失败时应该清理所有文件，避免留下不完整的备份"

### 技术实现参考
- "使用 docker exec 方式执行备份，与现有脚本保持一致"
- "使用 .pgpass 文件管理密码，避免在环境变量中硬编码敏感信息"
- "插件架构设计应该让 Phase 2 的云存储集成尽可能无缝"

### 错误处理
- "错误消息应该详细且包含解决建议，帮助运维人员快速定位问题"
- "备份失败时应该立即停止，不要继续备份其他数据库"

### 安全性
- "使用 .pgpass 文件而不是环境变量，避免 .env.production 被 Git 追踪的安全问题"
- "审计日志应该记录所有备份操作，便于事后追踪"

## Deferred Ideas

以下想法在讨论中被提及，但超出了 Phase 1 的范围：

### 云存储相关（Phase 2）
- 云存储上传接口设计
- B2 Application Key 权限配置
- 上传重试和校验机制
- 云端清理策略

### 恢复功能（Phase 3）
- 一键恢复脚本
- 列出可用备份
- 恢复到不同数据库

### 自动化验证测试（Phase 4）
- 每周自动恢复测试
- 临时数据库管理
- 测试失败告警

### 监控与告警（Phase 5）
- Webhook 告警集成
- 耗时追踪和警告
- 结构化日志增强

### 性能优化（v2）
- 并行备份多个数据库
- 增量备份（pg_basebackup + WAL）
- 压缩级别可配置

### 高级功能（v2）
- PITR 时间点恢复
- 跨区域备份复制
- Web 管理面板

---

*Phase: 01-local-backup-core*
*Context gathered: 2026-04-06*
