# Phase 10: B2 备份修复 - Context

**Gathered:** 2026-04-11
**Status:** Ready for planning

<domain>
## Phase Boundary

修复自 4/8 起中断的 B2 云备份系统，修复磁盘空间检查 bug，修复验证测试下载功能。所有备份功能端到端可用，数据保护承诺得到兑现。

不涉及：新增备份功能、备份策略变更、监控告警系统改进。

</domain>

<decisions>
## Implementation Decisions

### B2 备份中断调查
- **D-01:** 计划内包含调查步骤 — 修复计划的第一步是登录生产环境检查日志和状态，定位根因后再修复
- **D-02:** 调查重点方向：(1) v1.1 迁移后容器重命名/配置丢失 (2) B2 凭证/rclone 配置问题 (3) supervisord cron 配置异常
- **D-03:** 调查结果决定修复方式 — 根因可能是配置更新、环境变量缺失、或 rclone 配置丢失，需要根据实际发现针对性修复

### 磁盘空间检查修复
- **D-04:** 简单修复方案 — 在容器内添加 `df` 检查挂载点空间，替代当前的直接跳过逻辑
- **D-05:** 具体修复位置：`scripts/backup/lib/health.sh` 第 163-166 行的容器内分支，改为执行 df 检查而非直接 return 0

### 验证测试下载修复
- **D-06:** 修复下载路径解析 — 保持 B2 日期子目录存储结构不变，修复下载函数使其能正确处理 `YYYY/MM/DD/` 路径
- **D-07:** 关键修复点：(1) `list_b2_backups` 输出包含子目录路径 (2) `download_backup` 的 `--include` 需匹配正确路径 (3) `download_latest_backup` 解析文件名需去除目录前缀

### 测试与验证策略
- **D-08:** 本地模拟验证 — 用 B2 测试文件 + 模拟环境在本地验证修复逻辑
- **D-09:** 验证优先级：磁盘检查修复 > B2 中断修复 > 验证下载修复（按独立性排列）

### Claude's Discretion
- 具体的 df 检查命令和阈值计算方式
- rclone 参数调优
- 测试脚本的详细构造

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 备份系统核心代码
- `scripts/backup/backup-postgres.sh` — 主备份流程（7 步），调用所有子系统
- `scripts/backup/lib/cloud.sh` — B2 云操作：rclone 配置、上传、校验、清理
- `scripts/backup/lib/health.sh` — 健康检查：PostgreSQL 连接 + 磁盘空间（**BFIX-02 bug 所在**）
- `scripts/backup/lib/restore.sh` — 恢复功能：列出、下载、恢复（**BFIX-03 下载路径问题所在**）
- `scripts/backup/lib/test-verify.sh` — 验证测试库：下载、恢复、验证流程
- `scripts/backup/lib/config.sh` — 配置管理：环境变量加载和验证
- `scripts/backup/lib/constants.sh` — 退出码和常量定义
- `scripts/backup/lib/verify.sh` — 备份验证：pg_restore --list + SHA-256 校验
- `scripts/backup/test-verify-weekly.sh` — 每周自动验证测试脚本

### 运维容器配置
- `deploy/entrypoint-ops.sh` — noda-ops 容器启动脚本，初始化 rclone 配置和 supervisord
- `deploy/Dockerfile.backup` — noda-ops 容器构建文件
- `docker/docker-compose.yml` — 基础 Docker Compose 配置
- `docker/docker-compose.prod.yml` — 生产环境 overlay

### 备份配置
- `scripts/backup/.env.backup` — 备份系统环境变量配置

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `cloud.sh:setup_rclone_config()` — 创建临时 rclone 配置的函数，所有 B2 操作复用
- `cloud.sh:upload_to_b2()` — 上传逻辑已实现重试和校验和验证
- `health.sh:check_postgres_connection()` — 连接检查逻辑正常，容器内/外双路径
- `verify.sh:verify_backup_readable()` — pg_restore --list 验证逻辑正常

### Established Patterns
- 环境检测模式：`if [[ -f /.dockerenv ]]` 区分容器内/宿主机运行
- 配置加载优先级：命令行 > 环境变量 > .env 文件 > 默认值
- 重试模式：指数退避，最多 3 次重试
- rclone 配置：每次操作创建临时配置文件，操作完清理

### Integration Points
- noda-ops 容器内 supervisord 运行 cron 调度备份
- 备份写入 Docker volume `/var/lib/postgresql/backup`（映射到宿主机 `noda-infra_postgres_data`）
- B2 路径结构：`noda-backups/backups/postgres/YYYY/MM/DD/`
- PostgreSQL 连接：容器内通过 Docker 网络连接 `noda-infra-postgres-prod:5432`

### Known Bugs
- **BFIX-02**: `health.sh:163-166` — 容器内磁盘检查直接跳过（`return 0`），从未实际检查空间
- **BFIX-03**: `restore.sh:download_backup()` 和 `test-verify.sh:download_latest_backup()` — B2 日期子目录路径解析可能导致文件找不到
- **BFIX-01**: 根因未知，可能与 v1.1 迁移后容器配置有关

</code_context>

<specifics>
## Specific Ideas

- 磁盘检查修复目标：容器内至少检查备份目录所在挂载点的可用空间，与所需空间（数据库大小 × 2）比较
- 下载修复需确保 `rclone ls` 列出的路径能被 `rclone copy --include` 正确匹配
- 调查步骤应包含：检查容器日志、手动运行 rclone 配置验证、检查 cron 任务状态

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 10-b2*
*Context gathered: 2026-04-11*
