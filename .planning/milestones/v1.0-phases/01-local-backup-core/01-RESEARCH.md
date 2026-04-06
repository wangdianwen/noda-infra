# 阶段 1：本地备份核心 - 研究

**研究时间：** 2026-04-06
**技术域：** PostgreSQL 备份与验证、Bash 脚本、Docker 容器化
**置信度：** HIGH

## 摘要

本研究文档为"本地备份核心"阶段提供技术实施指导。通过分析 PostgreSQL 17.9 的备份工具、现有项目脚本模式和行业最佳实践，确定了使用 `pg_dump -Fc` 自定义格式、`pg_restore --list` 验证、`pg_isready` 健康检查的核心技术栈。

**主要建议：** 使用 Bash 脚本库结构（主脚本 + 功能模块），通过 `docker exec` 在容器内执行备份命令，采用时间戳分层目录结构存储，实现自动化的多数据库备份流程。

## 用户约束（来自 CONTEXT.md）

### 锁定决策
以下决策已在讨论阶段确定，研究必须基于这些决策进行：

- **D-01:** 自动发现并备份所有用户数据库（通过查询 pg_database 系统表排除系统数据库）
- **D-02:** 必须单独备份全局对象（角色、表空间定义），使用 `pg_dumpall -g` 命令
- **D-03:** 严格使用 `pg_dump -Fc` 格式（PostgreSQL 自定义压缩格式，自带 zlib 压缩）
- **D-04:** 串行备份每个数据库（不并行），使用默认压缩级别
- **D-05:** 备份前仅使用 `pg_isready` 检查 PostgreSQL 连接状态
- **D-06:** 每次备份后立即验证（`pg_restore --list` + SHA-256 校验和）
- **D-07:** 遇到错误立即失败，不继续备份其他数据库
- **D-08:** 严格遵循 MONITOR-05 错误退出码：0=成功、1=连接失败、2=备份失败、3=上传失败、4=清理失败、5=验证失败
- **D-09:** 备份文件存储在 Docker volume 映射的宿主机目录
- **D-10:** 备份目录结构按日期分层（如 2026/04/06/）
- **D-11:** 备份文件命名严格遵循需求格式：`{db_name}_{YYYYMMDD_HHmmss}.dump`
- **D-12:** 全局对象备份文件使用固定命名：`globals_{timestamp}.sql`
- **D-13:** 备份文件权限设置为严格的 600（仅所有者可读写）
- **D-14:** 同时检查 Docker volume 和宿主机的磁盘空间
- **D-15:** 磁盘空间检查阈值：数据库大小 × 2
- **D-16:** 备份失败时清理所有已创建的备份文件
- **D-17:** 实现本地清理策略，按天数保留旧备份（通过环境变量配置天数）
- **D-18:** 脚本名称：`backup-postgres.sh`
- **D-19:** 使用 Bash 编写，主脚本 + 库文件结构
- **D-20:** 默认无参数直接备份所有数据库
- **D-21:** 提供 `--list-databases` 参数列出所有可备份的数据库
- **D-22:** 提供 `--dry-run` 模式模拟备份执行
- **D-23:** 提供锁定机制防止并发执行（使用 PID 文件）
- **D-24:** 自动清理过期的锁定文件
- **D-25:** 显示详细进度信息（当前数据库、完成百分比、预计剩余时间）
- **D-26:** 简洁日志输出到标准输出（关键信息）
- **D-27:** 使用 `.env.backup` 模板文件管理配置
- **D-28:** 配置优先级：命令行参数 > .env 文件 > 默认值
- **D-29:** 生成 JSON 格式元数据文件记录每次备份
- **D-30:** 记录备份历史（JSON 格式）到备份目录
- **D-31:** 使用 `docker exec` 方式在容器内执行备份命令
- **D-32:** 全局对象备份使用 `pg_dumpall -g` 命令
- **D-33:** 通过 Unix socket 连接到 PostgreSQL（容器内本地连接）
- **D-34:** 使用 `.pgpass` 文件管理数据库密码（避免硬编码）
- **D-35:** 设置固定超时时间（如 1 小时）
- **D-36:** 使用默认压缩级别（平衡速度和大小）
- **D-37:** 库文件按功能划分（db.sh、log.sh、util.sh 等）
- **D-38:** 脚本中包含详细注释和文档头
- **D-39:** 创建审计日志记录所有备份操作
- **D-40:** 使用 Git 标签管理版本
- **D-41:** 设计插件架构，便于后续添加云存储功能（Phase 2）
- **D-42:** 预留通知接口，便于集成监控告警（Phase 5）
- **D-43:** 提供 `--test` 模式，创建测试数据库并验证完整备份和恢复流程
- **D-44:** 支持 macOS 和 Linux 操作系统
- **D-45:** 在备份目录创建详细的恢复文档（RESTORE.md）
- **D-46:** 提供详细的错误消息和解决建议
- **D-47:** 使用 JSON 格式日志便于解析

### Claude 自由裁量
以下方面由规划时决定：

- 备份超时的具体时间值（建议 1 小时）
- 本地清理策略的默认保留天数（建议 7 天）
- 进度显示的具体格式和更新频率
- 元数据文件的具体字段和结构
- 审计日志的具体内容和格式
- 库文件的具体函数划分和命名
- 测试模式的具体实现细节

### 延迟想法（超出范围）
以下想法已明确超出阶段 1 范围：

- 云存储上传接口设计（Phase 2）
- B2 Application Key 权限配置（Phase 2）
- 上传重试和校验机制（Phase 2）
- 云端清理策略（Phase 2）
- 一键恢复脚本（Phase 3）
- 列出可用备份（Phase 3）
- 恢复到不同数据库（Phase 3）
- 每周自动恢复测试（Phase 4）
- 临时数据库管理（Phase 4）
- 测试失败告警（Phase 4）
- Webhook 告警集成（Phase 5）
- 耗时追踪和警告（Phase 5）
- 结构化日志增强（Phase 5）
- 并行备份多个数据库（v2）
- 增量备份（pg_basebackup + WAL）（v2）
- 压缩级别可配置（v2）
- PITR 时间点恢复（v2）
- 跨区域备份复制（v2）
- Web 管理面板（v2）

## 阶段需求

| 需求 ID | 描述 | 研究支持 |
|---------|------|----------|
| BACKUP-01 | 系统可以备份多个数据库（keycloak_db、findclass_db）及其全局对象 | pg_dumpall -g 支持全局对象备份，pg_database 系统表查询支持自动发现 |
| BACKUP-02 | 备份文件使用时间戳和数据库名命名 | Bash date 命令支持格式化输出 |
| BACKUP-03 | 备份使用 pg_dump -Fc 自定义压缩格式 | PostgreSQL 17.9 内置支持，自带 zlib 压缩 |
| BACKUP-04 | 备份前执行 PostgreSQL 健康检查 | pg_isready 工具提供连接状态检查 |
| BACKUP-05 | 备份前检查磁盘空间是否充足 | df 命令 + pg_database_size 函数支持 |
| VERIFY-01 | 备份后立即验证完整性 | pg_restore --list + sha256sum 支持验证 |
| MONITOR-04 | 备份前检查 Docker volume 可用磁盘空间 | docker exec + df 命令支持 |

## 标准技术栈

### 核心
| 工具/库 | 版本 | 用途 | 为什么标准 |
|---------|------|------|-----------|
| PostgreSQL | 17.9 | 数据库引擎 | [VERIFIED: docker exec] 容器内运行版本，Debian 17.9-1.pgdg13+1 |
| pg_dump | 17.9 | 数据库备份工具 | [VERIFIED: docker exec] PostgreSQL 官方备份工具，支持自定义格式 |
| pg_restore | 17.9 | 备份恢复/验证工具 | [VERIFIED: docker exec] PostgreSQL 官方恢复工具，支持 --list 验证 |
| pg_isready | 17.9 | 连接状态检查工具 | [VERIFIED: docker exec] PostgreSQL 官方健康检查工具 |
| Bash | 4.0+ | 脚本语言 | [VERIFIED: macOS/Linux] 项目现有脚本使用 Bash |
| Docker | - | 容器运行时 | [VERIFIED: docker ps] 项目使用 Docker 容器化部署 |

### 支持
| 工具/库 | 版本 | 用途 | 何时使用 |
|---------|------|------|----------|
| jq | 1.6+ | JSON 处理 | 解析和生成 JSON 元数据文件 |
| sha256sum | - | 文件校验和 | 验证备份文件完整性 |
| GNU Coreutils | - | 基础工具（date、df 等） | 时间戳格式化、磁盘空间检查 |

### 替代方案考虑
| 代替 | 可用 | 权衡 |
|------|------|------|
| pg_dump -Fc | pg_dump -Fp（纯文本） | 自定义格式支持压缩和并行恢复，纯文本格式可读但更大且恢复慢 |
| pg_restore --list | 实际恢复测试 | --list 快速验证但不保证数据完整性，实际测试更彻底但耗时 |
| Bash 脚本 | Python 脚本 | Bash 更轻量且与现有脚本一致，Python 提供更好的错误处理和库支持 |

**安装：**
```bash
# macOS
brew install jq coreutils

# Ubuntu/Debian
sudo apt-get install jq coreutils

# 验证安装
jq --version
sha256sum --version
```

**版本验证：** 所有核心工具已在 Docker 容器内验证可用（PostgreSQL 17.9 完整工具链）。

## 架构模式

### 推荐的项目结构
```
scripts/backup/
├── backup-postgres.sh          # 主脚本
├── lib/
│   ├── db.sh                   # 数据库操作函数
│   ├── log.sh                  # 日志函数
│   ├── util.sh                 # 工具函数
│   └── config.sh               # 配置管理
├── templates/
│   ├── .env.backup             # 环境变量模板
│   └── RESTORE.md              # 恢复文档模板
└── tests/
    ├── test_backup.sh          # 备份功能测试
    └── test_restore.sh         # 恢复功能测试
```

### 模式 1：库文件架构
**什么：** 将功能分解为可重用的库文件，主脚本负责编排和命令行参数处理。

**何时使用：** 复杂脚本需要模块化、测试和维护时。

**示例：**
```bash
# 主脚本结构
#!/bin/bash
set -euo pipefail

# 加载库文件
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/db.sh"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/util.sh"

# 主流程
main() {
  parse_arguments "$@"
  load_config
  acquire_lock
  check_prerequisites
  backup_all_databases
  verify_backups
  cleanup_old_backups
  release_lock
}

main "$@"
```

### 模式 2：Docker 容器内执行
**什么：** 通过 `docker exec` 在 PostgreSQL 容器内执行备份命令，文件通过 volume 映射到宿主机。

**何时使用：** 数据库运行在 Docker 容器中时。

**示例：**
```bash
# 来源：项目现有脚本模式（quick-verify.sh）
docker exec noda-infra-postgres-1 pg_dump -U postgres -Fc -f /var/lib/postgresql/backup/backup.dump keycloak_db

# 文件通过 volume 映射到宿主机
# 宿主机路径：/var/lib/docker/volumes/noda-infra_postgres_data/_data/backup/
```

### 模式 3：自动发现用户数据库
**什么：** 查询 `pg_database` 系统表，排除模板数据库（datistemplate = true）和系统数据库。

**何时使用：** 需要备份所有用户数据库时。

**示例：**
```bash
# 来源：PostgreSQL 系统表查询
docker exec noda-infra-postgres-1 psql -U postgres -d postgres -t -c \
  "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"
```

### 模式 4：错误处理和退出码
**什么：** 使用 `set -euo pipefail` 和明确的退出码确保错误被正确处理。

**何时使用：** 所有 Bash 脚本，特别是需要可靠错误报告的脚本。

**示例：**
```bash
# 来源：项目现有脚本模式（verify-findclass-jenkins.sh）
set -euo pipefail

# 定义退出码常量
EXIT_SUCCESS=0
EXIT_CONNECTION_FAILED=1
EXIT_BACKUP_FAILED=2
EXIT_UPLOAD_FAILED=3
EXIT_CLEANUP_FAILED=4
EXIT_VERIFICATION_FAILED=5

# 错误处理函数
error_exit() {
  log_error "$1"
  exit "${2:-1}"
}
```

### 反模式避免
- **硬编码密码：** 避免在脚本中硬编码数据库密码，使用 .pgpass 文件或环境变量
- **忽略错误：** 避免使用 `|| true` 忽略错误，应该明确处理每个可能的失败
- **全局变量污染：** 避免在库文件中使用全局变量，使用函数封装和局部变量
- **不验证备份：** 避免创建备份后不验证，应该至少使用 pg_restore --list 验证

## 不要重复造轮子

| 问题 | 不要构建 | 使用替代 | 为什么 |
|------|----------|----------|--------|
| 数据库备份 | 自己编写 SQL 导出脚本 | pg_dump -Fc | 处理依赖关系、序列、权限等复杂情况 |
| 压缩 | 手动调用 gzip/zip | pg_dump -Fc 内置压缩 | 自定义格式已经包含 zlib 压缩 |
| 连接检查 | 编写 ping/端口检查脚本 | pg_isready | 官方工具，准确检查 PostgreSQL 连接状态 |
| 进度显示 | 手动计算百分比 | pv (pipe viewer) 或自定义函数 | pv 专门用于显示数据传输进度 |
| JSON 处理 | 手动解析 JSON | jq | 成熟、安全、高效的 JSON 处理工具 |
| 文件校验和 | 手动实现哈希算法 | sha256sum | 系统自带工具，快速可靠 |

**关键洞察：** PostgreSQL 备份涉及许多边缘情况（大对象、序列、触发器、权限等），使用官方工具避免这些复杂性。

## 运行时状态清单

> 本阶段是全新功能开发，不涉及重命名/重构，因此不需要运行时状态清单。

## 常见陷阱

### 陷阱 1：忽略数据库大小差异
**问题：** 不同数据库大小差异巨大，导致磁盘空间检查不准确。

**原因：** 仅检查总磁盘空间，不考虑单个数据库大小。

**避免：** 在备份前查询每个数据库的大小（`pg_database_size`），累加计算总需求。

**警告信号：** 小数据库备份成功，大数据库备份因磁盘空间不足失败。

### 陷阱 2：全局对象备份遗漏
**问题：** 仅备份各个数据库，忘记备份全局对象（角色、表空间）。

**原因：** pg_dump 默认不包含全局对象，需要单独使用 pg_dumpall -g。

**避免：** 在备份流程中明确包含全局对象备份步骤。

**警告信号：** 恢复时出现 "role not found" 错误。

### 陷阱 3：并发备份冲突
**问题：** 同时运行多个备份实例导致文件冲突和资源竞争。

**原因：** 没有实现锁定机制。

**避免：** 使用 PID 文件锁定，脚本启动时检查锁文件，退出时清理。

**警告信号：** 备份文件损坏或备份日志混乱。

### 陷阱 4：验证不充分
**问题：** 备份文件创建成功但实际无法恢复。

**原因：** 仅检查文件存在，不验证内容完整性。

**避免：** 使用 pg_restore --list 验证文件结构，计算 SHA-256 校验和。

**警告信号：** 恢复测试失败。

### 陷阱 5：权限问题
**问题：** 备份文件权限过于宽松，导致安全风险。

**原因：** 没有设置文件权限或使用 umask。

**避免：** 创建文件后立即设置权限为 600（仅所有者可读写）。

**警告信号：** 备份文件可被其他用户读取。

### 陷阱 6：时间戳不一致
**问题：** 同一次备份的不同文件使用不同的时间戳。

**原因：** 在脚本执行过程中多次调用 date 命令。

**避免：** 在脚本开始时捕获一次时间戳，全程使用该值。

**警告信号：** 文件命名混乱，难以匹配相关文件。

### 陷阱 7：Docker volume 路径混淆
**问题：** 备份文件存储在容器内但无法在宿主机访问。

**原因：** 没有正确配置 volume 映射或使用了容器内路径。

**避免：** 明确区分容器内路径（/var/lib/postgresql/backup）和宿主机路径（volume 挂载点）。

**警告信号：** 容器内看到文件，宿主机找不到。

## 代码示例

### 备份操作
```bash
# 来源：PostgreSQL 17.9 官方文档
docker exec noda-infra-postgres-1 pg_dump -U postgres -Fc -f /var/lib/postgresql/backup/keycloak_db_20260406_143000.dump keycloak_db
```

### 全局对象备份
```bash
# 来源：PostgreSQL 17.9 官方文档
docker exec noda-infra-postgres-1 pg_dumpall -U postgres -g -f /var/lib/postgresql/backup/globals_20260406_143000.sql
```

### 健康检查
```bash
# 来源：PostgreSQL 17.9 官方文档
docker exec noda-infra-postgres-1 pg_isready -U postgres
# 返回码：0=接受连接，1=拒绝连接，2=无响应
```

### 备份验证
```bash
# 来源：PostgreSQL 17.9 官方文档
docker exec noda-infra-postgres-1 pg_restore --list /var/lib/postgresql/backup/backup.dump
# 显示备份内容的 TOC（Table of Contents）
```

### 数据库大小查询
```bash
# 来源：PostgreSQL 系统表函数
docker exec noda-infra-postgres-1 psql -U postgres -d postgres -t -c \
  "SELECT pg_database_size('keycloak_db');"
```

### 磁盘空间检查
```bash
# 来源：Linux/Unix df 命令
docker exec noda-infra-postgres-1 df -h /var/lib/postgresql/data
```

### 时间戳格式化
```bash
# 来源：GNU date 命令
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DATE_PART=$(date +"%Y/%m/%d")
```

### SHA-256 校验和
```bash
# 来源：GNU coreutils
sha256sum /path/to/backup.dump
```

## 技术现状

| 旧方法 | 当前方法 | 变更时间 | 影响 |
|--------|----------|----------|------|
| pg_dump -Fp（纯文本） | pg_dump -Fc（自定义格式） | PostgreSQL 7.x+ | 自定义格式支持压缩、并行恢复、选择性恢复 |
| 手动验证 | pg_restore --list | PostgreSQL 8.x+ | 快速验证备份文件结构，无需实际恢复 |
| 硬编码密码 | .pgpass 文件 | 长期最佳实践 | 提高安全性，避免凭证泄露 |

**已弃用/过时：**
- pg_dump -Ft（tar 格式）：仍支持但不推荐，自定义格式更优
- 直接备份到 SQL 文件：不推荐，自定义格式更高效

## 假设日志

| # | 假设 | 章节 | 错误风险 |
|---|------|------|----------|
| A1 | PostgreSQL 17.9 的 pg_dump -Fc 默认压缩级别（6）适合本项目 | 标准技术栈 | LOW - 默认级别平衡速度和大小，D-36 已确认使用默认值 |
| A2 | Bash 脚本在 macOS 和 Linux 上行为一致 | 标准技术栈 | MEDIUM - GNU date 和 BSD date 选项略有不同，D-44 需要兼容性测试 |
| A3 | Docker volume 映射性能足够，不需要优化 | 架构模式 | LOW - 当前备份规模不大，volume 性能不是瓶颈 |
| A4 | PID 文件锁定在容器重启后自动清理 | 常见陷阱 | MEDIUM - 需要实现 D-24 自动清理过期锁定文件 |

**如果此表为空：** 本研究中的所有声明都已验证或引用 —— 不需要用户确认。

## 未解决问题

1. **环境变量安全存储**
   - 已知信息：.env.production 已被 Git 追踪，包含敏感信息（STATE.md 指出）
   - 不明确：应该使用什么方案替代（Git-crypt、SOPS、.env.local + .gitignore？）
   - 建议：在实施前处理这个技术债务，使用 SOPS 或类似工具加密敏感信息

2. **.pgpass 文件管理**
   - 已知信息：D-34 要求使用 .pgpass 文件管理密码
   - 不明确：.pgpass 文件本身如何安全存储和分发
   - 建议：将 .pgpass 文件添加到 .gitignore，通过环境变量生成或使用加密工具

3. **备份目录的 volume 映射**
   - 已知信息：D-09 要求备份文件存储在 Docker volume 映射的宿主机目录
   - 不明确：当前 docker-compose.yml 是否已配置备份目录的 volume 映射
   - 建议：检查并更新 docker-compose.yml，确保 /var/lib/postgresql/backup 映射到宿主机

## 环境可用性

| 依赖 | 需求方 | 可用 | 版本 | 回退方案 |
|------|--------|------|------|----------|
| PostgreSQL | 数据库服务 | ✓ | 17.9 | — |
| pg_dump | 备份工具 | ✓ | 17.9 | — |
| pg_restore | 验证工具 | ✓ | 17.9 | — |
| pg_isready | 健康检查 | ✓ | 17.9 | — |
| psql | 查询工具 | ✓ | 17.9 | — |
| Bash | 脚本语言 | ✓ | (macOS/Linux) | — |
| Docker | 容器运行时 | ✓ | (运行中) | — |
| jq | JSON 处理 | ? | 未检查 | 使用 Python json 模块或手动解析 |
| sha256sum | 校验和 | ✓ | (macOS: shasum) | — |

**缺少依赖且回退方案：**
- 无

**缺少依赖但有回退方案：**
- jq：如果不可用，可以使用 Python 的 json 模块或简单的字符串操作

## 验证架构

### 测试框架
| 属性 | 值 |
|------|------|
| 框架 | Bash 脚本测试（Bats 或手动测试） |
| 配置文件 | 无（Bash 脚本不需要） |
| 快速运行命令 | `bash scripts/backup/backup-postgres.sh --dry-run` |
| 完整套件命令 | `bash scripts/backup/tests/test_backup.sh` |

### 阶段需求 → 测试映射
| 需求 ID | 行为 | 测试类型 | 自动化命令 | 文件存在？ |
|---------|--------|---------|------------|-----------|
| BACKUP-01 | 备份多个数据库和全局对象 | 集成测试 | `bash test_backup.sh` | ❌ 需创建 |
| BACKUP-02 | 文件命名格式正确 | 单元测试 | `bash test_backup.sh` | ❌ 需创建 |
| BACKUP-03 | 使用自定义压缩格式 | 集成测试 | `bash test_backup.sh` | ❌ 需创建 |
| BACKUP-04 | 备份前健康检查 | 单元测试 | `bash test_backup.sh` | ❌ 需创建 |
| BACKUP-05 | 磁盘空间检查 | 单元测试 | `bash test_backup.sh` | ❌ 需创建 |
| VERIFY-01 | 备份后验证完整性 | 集成测试 | `bash test_backup.sh` | ❌ 需创建 |
| MONITOR-04 | Docker volume 磁盘空间检查 | 单元测试 | `bash test_backup.sh` | ❌ 需创建 |

### 采样率
- **每次任务提交：** `bash scripts/backup/backup-postgres.sh --dry-run`
- **每次波次合并：** `bash scripts/backup/tests/test_backup.sh`
- **阶段门控：** 完整测试套件通过，所有需求验证完成

### 波次 0 缺失
- [ ] `scripts/backup/tests/test_backup.sh` — 覆盖所有阶段需求
- [ ] `scripts/backup/tests/test_restore.sh` — 恢复功能测试（D-43）
- [ ] 测试数据库创建脚本（用于 D-43 测试模式）

## 安全域

### 适用的 ASVS 类别

| ASVS 类别 | 应用 | 标准控制 |
|-----------|------|----------|
| V2 认证 | 否 | — |
| V3 会话管理 | 否 | — |
| V4 访问控制 | 否 | — |
| V5 输入验证 | 是 | 参数验证、路径验证、数据库名验证 |
| V6 加密 | 是 | .pgpass 文件权限（600）、备份文件权限（600）、SHA-256 校验和 |

### PostgreSQL 备份的已知威胁模式

| 模式 | STRIDE | 标准缓解措施 |
|------|--------|--------------|
| 备份文件泄露 | 信息泄露 | 文件权限 600、加密存储（Phase 2）、安全删除 |
| 硬编码凭证 | 信息泄露 | .pgpass 文件、环境变量、避免硬编码 |
| 路径遍历 | 基本数据伪造 | 验证数据库名、使用绝对路径、避免用户输入直接拼接 |
| 备份篡改 | 基本数据伪造 | SHA-256 校验和、只读存储、签名（Phase 2） |
| 未授权恢复 | 基本数据伪造 | 访问控制、审计日志、恢复授权 |

## 信息来源

### 主要来源（高置信度）
- [PostgreSQL 17.9 官方文档] - pg_dump、pg_restore、pg_isready 工具使用
- [项目现有脚本] - Bash 脚本模式、Docker 命令模式
- [CONTEXT.md] - 用户决策和锁定需求

### 次要来源（中等置信度）
- [项目 README.md] - 架构概览和目录结构
- [backups/sql/README.md] - 现有备份实践

### 三级来源（低置信度）
- [ASSUMED] Bash 脚本最佳实践 - 需要验证 macOS/Linux 兼容性
- [ASSUMED] jq 可用性 - 需要验证是否已安装

## 元数据

**置信度评估：**
- 标准技术栈：HIGH - 所有工具已在容器内验证可用
- 架构模式：HIGH - 基于项目现有脚本模式和 PostgreSQL 最佳实践
- 陷阱：MEDIUM - 基于 PostgreSQL 备份常见问题，但需要实际测试验证

**研究日期：** 2026-04-06
**有效期至：** 2026-05-06（30 天 - PostgreSQL 备份工具稳定）
