# Phase 1: 本地备份核心 - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-06
**Phase:** 01-本地备份核心
**Mode:** discuss
**Areas discussed:** 64 gray areas

---

## 数据库备份策略

### 数据库范围
| Option | Description | Selected |
|--------|-------------|----------|
| 仅备份 keycloak_db 和 findclass_db | 只备份明确要求的 keycloak_db 和 findclass_db，符合最小化原则 | |
| 自动发现并备份所有用户数据库 | 备份所有非系统数据库，灵活但可能备份不需要的数据库 | ✓ |
| 使用环境变量配置数据库列表 | 在脚本中配置数据库列表，平衡灵活性和明确性 | |

**User's choice:** 自动发现并备份所有用户数据库
**Notes:** REQUIREMENTS.md 提到 keycloak_db 和 findclass_db，但 01-create-databases.sql 显示还有未来规划的数据库（noda_app_db、site_a_db）。自动发现可以避免频繁更新脚本。

### 全局对象备份
| Option | Description | Selected |
|--------|-------------|----------|
| 必须单独备份全局对象 | 按需求要求单独备份全局对象（角色、表空间），确保完整恢复 | ✓ |
| 不备份全局对象 | 只备份各数据库，全局对象在恢复时手动重建（更简单） | |
| 让 Claude 决定 | 让 Claude 决定 | |

**User's choice:** 必须单独备份全局对象
**Notes:** 使用 pg_dumpall -g 命令备份全局对象。

### 备份格式
| Option | Description | Selected |
|--------|-------------|----------|
| 严格使用 pg_dump -Fc 格式 | 需求明确要求的格式，自带 zlib 压缩，是 PostgreSQL 自定义格式 | ✓ |
| 提供格式选项但默认 -Fc | 提供多种格式选项（plain SQL、tar、directory），但默认使用 -Fc | |
| 让 Claude 决定 | 让 Claude 决定，根据实际需求选择最合适的格式 | |

**User's choice:** 严格使用 pg_dump -Fc 格式
**Notes:** PostgreSQL 自定义压缩格式，自带 zlib 压缩。

### 数据库发现方式
| Option | Description | Selected |
|--------|-------------|----------|
| 查询系统表自动发现 | 查询 pg_database 排除系统数据库（postgres、template0、template1） | ✓ |
| 从配置文件读取 | 从配置文件读取数据库列表 | |
| 混合方式 | 结合两者：配置文件指定 + 自动发现验证 | |

**User's choice:** 查询系统表自动发现
**Notes:** 通过查询 pg_database 系统表排除系统数据库。

### 并行备份
| Option | Description | Selected |
|--------|-------------|----------|
| 串行备份 | 串行备份每个数据库，简单可靠 | ✓ |
| 并行备份 | 并行备份多个数据库以提升速度 | |
| 可配置的并行备份 | 提供 --parallel 参数让用户选择 | |

**User's choice:** 串行备份
**Notes:** 不并行备份多个数据库。

### 压缩级别
| Option | Description | Selected |
|--------|-------------|----------|
| 默认压缩级别 | 使用 pg_dump -Fc 的默认压缩级别（平衡速度和大小） | ✓ |
| 最高压缩级别 | 使用最高压缩级别（-Z 9）以最小化文件大小 | |
| 可配置的压缩级别 | 提供 --compress 参数让用户选择 | |

**User's choice:** 默认压缩级别
**Notes:** 使用 pg_dump -Fc 的默认压缩级别。

---

## 健康检查与验证

### PostgreSQL 健康检查
| Option | Description | Selected |
|--------|-------------|----------|
| 仅使用 pg_isready | 使用 pg_isready 检查 PostgreSQL 是否接受连接，简单快速 | ✓ |
| pg_isready + 查询测试 | 执行简单的 SELECT 查询验证数据库响应，更可靠 | |
| 全面健康检查 | 检查数据库连接、查询响应和基本统计信息，最全面 | |

**User's choice:** 仅使用 pg_isready
**Notes:** REQUIREMENTS.md 要求使用 pg_isready。

### 错误处理策略
| Option | Description | Selected |
|--------|-------------|----------|
| 遇到错误立即失败 | 遇到任何错误立即停止，符合 MONITOR-05 标准退出码要求 | ✓ |
| 继续备份其他数据库 | 继续备份其他数据库，最后报告所有失败（更复杂） | |
| 提供选项让用户决定 | 提供 --continue-on-error 标志让用户选择行为 | |

**User's choice:** 遇到错误立即失败
**Notes:** 符合 MONITOR-05 标准退出码要求。

### 备份验证方式
| Option | Description | Selected |
|--------|-------------|----------|
| 仅使用 pg_restore --list | 按需求使用 pg_restore --list 验证备份文件可读性 | |
| pg_restore --list + 文件完整性检查 | 除了 --list，还验证文件大小和校验和 | ✓ |
| 完整恢复测试验证 | 恢复到临时数据库并验证数据完整性（最全面但最慢） | |

**User's choice:** pg_restore --list + 文件完整性检查
**Notes:** 使用 pg_restore --list + SHA-256 校验和。

### 备份验证时机
| Option | Description | Selected |
|--------|-------------|----------|
| 每次备份后验证 | 每次备份后立即验证（pg_restore --list） | ✓ |
| 可配置的验证 | 提供 --verify 参数，让用户选择是否验证 | |
| 仅 dry-run 验证 | 仅在 --dry-run 模式下验证 | |

**User's choice:** 每次备份后验证
**Notes:** 每次备份后立即验证。

### 错误退出码
| Option | Description | Selected |
|--------|-------------|----------|
| 严格遵循 MONITOR-05 | 严格遵循 MONITOR-05：0=成功、1=连接失败、2=备份失败、3=上传失败、4=清理失败、5=验证失败 | ✓ |
| 简化退出码 | 使用更简单的退出码：0=成功、1=失败 | |
| 扩展错误码 | 在 MONITOR-05 基础上添加更多细分的错误码 | |

**User's choice:** 严格遵循 MONITOR-05
**Notes:** 严格遵循 MONITOR-05 错误退出码。

---

## 存储与文件管理

### 存储位置
| Option | Description | Selected |
|--------|-------------|----------|
| 容器内固定路径 | 直接存储在 PostgreSQL 容器的 /var/lib/postgresql/backup | |
| Docker volume 映射到宿主机 | 存储在宿主机目录，通过 Docker volume 映射 | ✓ |
| 环境变量配置路径 | 通过环境变量配置备份路径，灵活但需要额外配置 | |

**User's choice:** Docker volume 映射到宿主机
**Notes:** 备份文件存储在 Docker volume 映射的宿主机目录。

### 备份目录结构
| Option | Description | Selected |
|--------|-------------|----------|
| 扁平结构 | 所有备份文件放在同一目录下 | |
| 按日期分层 | 按日期创建子目录（如 2026/04/06/） | ✓ |
| 按数据库分层 | 按数据库创建子目录 | |

**User's choice:** 按日期分层
**Notes:** 备份目录结构按日期分层。

### 备份文件命名
| Option | Description | Selected |
|--------|-------------|----------|
| 严格按照需求格式 | keycloak_db_20260406_143000.dump（符合需求示例） | ✓ |
| 添加序列号防止冲突 | 在时间戳后添加序列号：keycloak_db_20260406_143000_001.dump | |
| 使用 ISO 8601 格式 | 使用 ISO 8601 格式：keycloak_db_2026-04-06T14:30:00.dump | |

**User's choice:** 严格按照需求格式
**Notes:** 备份文件命名严格遵循需求格式：{db_name}_{YYYYMMDD_HHmmss}.dump。

### 全局对象命名
| Option | Description | Selected |
|--------|-------------|----------|
| 固定文件名 | 使用固定的文件名：globals_{timestamp}.sql | ✓ |
| 与数据库相同格式 | 使用与数据库相同的命名格式 | |
| 包含日期的文件名 | 包含日期的文件名：globals_YYYYMMDD.sql | |

**User's choice:** 固定文件名
**Notes:** 全局对象备份文件使用固定命名：globals_{timestamp}.sql。

### 文件权限
| Option | Description | Selected |
|--------|-------------|----------|
| 严格的 600 权限 | 设置 600 权限，仅所有者可读写（最安全） | ✓ |
| 640 权限（组可读） | 设置 640 权限，所有者读写，组用户只读 | |
| 环境变量配置权限 | 使用环境变量配置权限，灵活但需要额外配置 | |

**User's choice:** 严格的 600 权限
**Notes:** 备份文件权限设置为严格的 600。

### 磁盘空间检查
| Option | Description | Selected |
|--------|-------------|----------|
| 检查 Docker volume 可用空间 | 检查 Docker volume 的可用空间，考虑 PostgreSQL 容器的文件系统 | |
| 检查宿主机磁盘空间 | 检查宿主机备份目标路径的磁盘空间 | |
| 两者都检查 | 同时检查 Docker volume 和宿主机，确保两边都有足够空间 | ✓ |

**User's choice:** 两者都检查
**Notes:** 同时检查 Docker volume 和宿主机的磁盘空间。

### 磁盘空间阈值
| Option | Description | Selected |
|--------|-------------|----------|
| 数据库大小 × 2 | 要求可用空间至少是数据库大小的 2 倍 | ✓ |
| 数据库大小 × 3 | 要求可用空间至少是数据库大小的 3 倍（更安全） | |
| 固定最小值 | 使用固定的最小值（如 10GB） | |
| 环境变量配置 | 通过环境变量配置阈值 | |

**User's choice:** 数据库大小 × 2
**Notes:** 磁盘空间检查阈值：数据库大小 × 2。

### 数据库大小估算
| Option | Description | Selected |
|--------|-------------|----------|
| 查询数据库大小 | 使用 pg_database_size() 查询每个数据库的大小 | ✓ |
| 使用固定值 | 使用固定的估算值（如 1GB） | |
| 不估算 | 不进行估算，直接检查磁盘空间 | |

**User's choice:** 查询数据库大小
**Notes:** 使用 pg_database_size() 查询每个数据库的大小。

### 清理策略
| Option | Description | Selected |
|--------|-------------|----------|
| 失败时清理所有备份文件 | 部分失败时删除所有已创建的备份文件 | ✓ |
| 只清理失败的文件 | 保留成功的备份，只清理失败的文件 | |
| 保留所有文件 | 保留所有文件，让用户决定 | |

**User's choice:** 失败时清理所有备份文件
**Notes:** 备份失败时清理所有已创建的备份文件。

### 本地清理策略
| Option | Description | Selected |
|--------|-------------|----------|
| 按天数保留 | 保留最近 N 天的备份（通过环境变量配置） | ✓ |
| 按文件数保留 | 保留最近 N 个备份文件 | |
| 两者都支持 | 两者都支持，通过参数选择 | |

**User's choice:** 按天数保留
**Notes:** 实现本地清理策略，按天数保留旧备份。

---

## 脚本功能与接口

### 脚本语言
| Option | Description | Selected |
|--------|-------------|----------|
| 使用 Bash | 纯 Bash 脚本，简单直接，与现有 quick-verify.sh 风格一致 | ✓ |
| 使用 Python | Python 脚本，更强大的错误处理和库支持 | |
| Bash + Python 混合 | 混合使用，Bash 包装器调用 Python 脚本 | |

**User's choice:** 使用 Bash
**Notes:** 使用 Bash 编写。

### 代码结构
| Option | Description | Selected |
|--------|-------------|----------|
| 单文件脚本 | 单文件脚本，所有功能在一个文件中 | |
| 模块化脚本 | 模块化设计，主脚本 + 库函数 | |
| 主脚本 + 库文件 | 主脚本 + 配置文件 + 工具函数 | ✓ |

**User's choice:** 主脚本 + 库文件
**Notes:** 主脚本 + 库文件结构。

### 库文件组织
| Option | Description | Selected |
|--------|-------------|----------|
| 按功能划分 | 按功能划分库文件（db.sh、log.sh、util.sh） | ✓ |
| 按层次划分 | 按层次划分库文件（core.sh、postgres.sh、backup.sh） | |
| 单一库文件 | 单一库文件包含所有函数 | |

**User's choice:** 按功能划分
**Notes:** 库文件按功能划分。

### 脚本名称
| Option | Description | Selected |
|--------|-------------|----------|
| backup-postgres.sh | backup-postgres.sh（与现有架构一致） | ✓ |
| backup.sh | backup.sh（简洁） | |
| pg-backup.sh | pg-backup.sh（描述性） | |

**User's choice:** backup-postgres.sh
**Notes:** 脚本名称：backup-postgres.sh。

### 命令行接口
| Option | Description | Selected |
|--------|-------------|----------|
| 无参数，直接备份所有数据库 | 简单直接，./backup.sh 即可执行所有备份 | ✓ |
| 支持命令行参数 | 支持 --db、--output、--dry-run 等参数，更灵活 | |
| 交互式菜单 | 提供交互式菜单让用户选择要备份的数据库 | |

**User's choice:** 无参数，直接备份所有数据库
**Notes:** 默认无参数直接备份所有数据库。

### 列出数据库功能
| Option | Description | Selected |
|--------|-------------|----------|
| 提供 --list-databases 功能 | 提供 --list-databases 参数列出所有可备份的数据库 | ✓ |
| 不提供，使用标准工具 | 脚本只负责备份，列出数据库使用其他工具 | |
| 自动显示备份列表 | 在备份开始前自动显示将要备份的数据库列表 | |

**User's choice:** 提供 --list-databases 功能
**Notes:** 提供 --list-databases 参数。

### Dry Run 模式
| Option | Description | Selected |
|--------|-------------|----------|
| 提供 --dry-run 模式 | 提供 --dry-run 参数，模拟执行但不实际备份 | ✓ |
| 不提供 | 不提供，保持脚本简单 | |
| 让 Claude 决定 | 让 Claude 决定 | |

**User's choice:** 提供 --dry-run 模式
**Notes:** 提供 --dry-run 参数。

### 测试模式
| Option | Description | Selected |
|--------|-------------|----------|
| 提供测试模式 | 提供 --test 参数，使用小型测试数据库验证脚本功能 | ✓ |
| 不提供 | 不提供测试模式，依赖真实环境测试 | |
| 独立测试脚本 | 创建独立的测试脚本 | |

**User's choice:** 提供测试模式
**Notes:** 提供 --test 模式，创建测试数据库并验证完整备份和恢复流程。

### 并发控制
| Option | Description | Selected |
|--------|-------------|----------|
| 提供锁定机制 | 使用 PID 文件锁定，防止并发执行 | ✓ |
| 不提供 | 不提供，依赖用户避免并发执行 | |
| 检测并警告 | 检测到正在运行的备份时退出并提示 | |

**User's choice:** 提供锁定机制
**Notes:** 提供锁定机制防止并发执行。

### 锁定机制实现
| Option | Description | Selected |
|--------|-------------|----------|
| 使用 PID 文件 | 在 /tmp 创建 PID 文件，启动时检查并创建，结束时删除 | ✓ |
| 使用 flock | 使用 flock 系统调用进行文件锁定 | |
| 检查进程 | 检查是否有正在运行的 pg_dump 进程 | |

**User's choice:** 使用 PID 文件
**Notes:** 使用 PID 文件。

### 锁定超时处理
| Option | Description | Selected |
|--------|-------------|----------|
| 自动清理过期锁定 | 如果锁定文件超过 N 小时，自动删除并继续 | ✓ |
| 提示用户清理 | 提示用户手动清理锁定文件 | |
| 提供 --force 参数 | 提供 --force 参数强制覆盖锁定 | |

**User's choice:** 自动清理过期锁定
**Notes:** 自动清理过期的锁定文件。

### 进度显示
| Option | Description | Selected |
|--------|-------------|----------|
| 显示详细进度 | 显示备份进度（当前数据库、完成百分比、预计剩余时间） | ✓ |
| 简洁输出 | 只显示开始和完成信息，保持简洁 | |
| 可配置的进度显示 | 提供 --progress 参数控制是否显示进度 | |

**User's choice:** 显示详细进度
**Notes:** 显示详细进度信息。

### 日志输出
| Option | Description | Selected |
|--------|-------------|----------|
| 简洁日志（关键信息） | 输出关键信息（开始/成功/失败），保持简洁 | ✓ |
| 详细日志（所有步骤） | 输出详细步骤、文件大小、耗时等，便于调试 | |
| 提供 --verbose 标志 | 使用 --verbose 标志控制日志级别 | |

**User's choice:** 简洁日志（关键信息）
**Notes:** 简洁日志输出到标准输出。

### 日志格式
| Option | Description | Selected |
|--------|-------------|----------|
| JSON 格式日志 | 使用结构化日志格式（JSON）便于解析 | ✓ |
| 文本格式日志 | 使用人类可读的文本格式 | |
| 可配置的日志格式 | 提供 --log-format 参数选择格式 | |

**User's choice:** JSON 格式日志
**Notes:** 使用 JSON 格式日志便于解析。

### 日志位置
| Option | Description | Selected |
|--------|-------------|----------|
| 标准输出 | 输出到 stdout，让 Jenkins 或用户重定向 | ✓ |
| 日志文件 | 自动写入日志文件到备份目录 | |
| 两者都输出 | 两者都输出：stdout + 日志文件 | |

**User's choice:** 标准输出
**Notes:** 简洁日志输出到标准输出。

### 备份超时
| Option | Description | Selected |
|--------|-------------|----------|
| 设置超时 | 设置备份超时时间，超时后终止 | ✓ |
| 不设置超时 | 不设置超时，让备份自然完成 | |
| 可配置超时 | 提供 --timeout 参数让用户配置 | |

**User's choice:** 设置超时
**Notes:** 设置固定超时时间。

### 超时时间设置
| Option | Description | Selected |
|--------|-------------|----------|
| 固定超时 | 固定超时时间（如 1 小时） | ✓ |
| 动态超时 | 根据数据库大小动态计算超时时间 | |
| 环境变量配置 | 通过环境变量配置超时时间 | |

**User's choice:** 固定超时
**Notes:** 设置固定超时时间。

---

## 配置与元数据

### 配置管理
| Option | Description | Selected |
|--------|-------------|----------|
| 使用 .env 文件 | 使用 .env 文件配置（与现有架构一致） | ✓ |
| 使用独立配置文件 | 使用独立的配置文件 backup.conf | |
| 仅使用环境变量 | 所有配置通过环境变量传递 | |

**User's choice:** 使用 .env 文件
**Notes:** 使用 .env.backup 模板文件管理配置。

### 配置文件
| Option | Description | Selected |
|--------|-------------|----------|
| .env.backup 模板 | 创建 .env.backup 模板文件 | ✓ |
| .env.production | 在 .env.production 中添加备份配置 | |
| backup.conf | 使用 backup.conf 配置文件 | |

**User's choice:** .env.backup 模板
**Notes:** 创建 .env.backup 模板文件。

### 配置来源
| Option | Description | Selected |
|--------|-------------|----------|
| 使用现有 .env.production | 从 .env.production 读取数据库凭证和配置 | |
| 创建独立的 .env.backup | 创建独立的 .env.backup 文件 | |
| 仅使用命令行参数 | 通过命令行参数传递所有配置 | |

**User's choice:** 使用现有 .env.production
**Notes:** 使用现有 .env.production 文件（需要处理安全问题）。

### 配置优先级
| Option | Description | Selected |
|--------|-------------|----------|
| 命令行参数优先 | 命令行参数 > .env 文件 > 默认值 | ✓ |
| 配置文件优先 | .env 文件 > 命令行参数 > 默认值 | |
| 仅配置文件 | 仅使用 .env 文件 | |

**User's choice:** 命令行参数优先
**Notes:** 配置优先级：命令行参数 > .env 文件 > 默认值。

### 元数据记录
| Option | Description | Selected |
|--------|-------------|----------|
| 生成元数据文件 | 创建 JSON 文件记录备份元数据（时间、大小、校验和等） | ✓ |
| 不生成元数据 | 不单独生成元数据，依赖文件名和日志 | |
| 文件名包含元数据 | 在备份文件名中包含更多信息（大小、校验和） | |

**User's choice:** 生成元数据文件
**Notes:** 生成 JSON 格式元数据文件记录每次备份。

### 元数据格式
| Option | Description | Selected |
|--------|-------------|----------|
| JSON 格式 | 使用 JSON 格式，易于解析和处理 | ✓ |
| 键值对格式 | 使用简单的键值对格式 | |
| YAML 格式 | 使用 YAML 格式 | |

**User's choice:** JSON 格式
**Notes:** 使用 JSON 格式。

### 备份统计
| Option | Description | Selected |
|--------|-------------|----------|
| 记录备份历史 | 记录备份历史（时间、大小、耗时、状态） | ✓ |
| 仅当前统计 | 仅记录当前备份的统计信息 | |
| 不记录统计 | 不记录统计信息 | |

**User's choice:** 记录备份历史
**Notes:** 记录备份历史（JSON 格式）。

### 历史记录格式
| Option | Description | Selected |
|--------|-------------|----------|
| JSON 格式 | 使用 JSON 格式记录备份历史 | ✓ |
| CSV 格式 | 使用 CSV 格式记录备份历史 | |
| 文本日志 | 使用文本日志格式记录备份历史 | |

**User's choice:** JSON 格式
**Notes:** 使用 JSON 格式。

### 历史记录位置
| Option | Description | Selected |
|--------|-------------|----------|
| 备份目录 | backup-history.json 文件放在备份目录 | ✓ |
| 单独历史目录 | 使用单独的历史目录 | |
| 按日期分层 | 按日期分层的历史文件 | |

**User's choice:** 备份目录
**Notes:** 备份历史记录文件放在备份目录。

---

## 技术实现

### Docker 执行方式
| Option | Description | Selected |
|--------|-------------|----------|
| docker exec 方式 | 使用 docker exec 在容器内执行 pg_dump | ✓ |
| docker run 方式 | 使用 docker run 执行一次性容器执行备份 | |
| 宿主机直接执行 | 在宿主机直接执行 pg_dump（通过网络连接） | |

**User's choice:** docker exec 方式
**Notes:** 使用 docker exec 方式在容器内执行备份命令。

### 全局对象备份方式
| Option | Description | Selected |
|--------|-------------|----------|
| 使用 pg_dumpall -g | 使用 pg_dumpall -g 备份全局对象到 globals.sql | ✓ |
| 手动导出定义 | 手动导出角色和表空间定义 | |
| 让 Claude 决定 | 让 Claude 决定最合适的方式 | |

**User's choice:** 使用 pg_dumpall -g
**Notes:** 使用 pg_dumpall -g 命令。

### 数据库连接方式
| Option | Description | Selected |
|--------|-------------|----------|
| Unix socket | 使用 Unix socket 连接（容器内本地连接） | ✓ |
| TCP/IP | 使用 TCP/IP 连接（localhost:5432） | |
| 自动选择 | 根据环境自动选择 | |

**User's choice:** Unix socket
**Notes:** 通过 Unix socket 连接到 PostgreSQL。

---

## 安全性

### 敏感信息处理
| Option | Description | Selected |
|--------|-------------|----------|
| 环境变量，不记录到日志 | 从 .env.production 读取密码，不在日志中显示 | |
| 使用 .pgpass 文件 | 使用 PostgreSQL 的 .pgpass 文件 | ✓ |
| 交互式输入 | 每次执行时交互式输入密码 | |

**User's choice:** 使用 .pgpass 文件
**Notes:** 使用 .pgpass 文件管理数据库密码。

### 审计日志
| Option | Description | Selected |
|--------|-------------|----------|
| 创建审计日志 | 记录所有备份操作到审计日志文件 | ✓ |
| 不创建审计日志 | 仅记录到标准输出，不单独保存 | |
| 可配置的审计日志 | 提供 --audit 参数控制是否记录审计日志 | |

**User's choice:** 创建审计日志
**Notes:** 创建审计日志记录所有备份操作。

---

## 扩展性

### 预留云存储接口
| Option | Description | Selected |
|--------|-------------|----------|
| 预留云存储接口 | 在脚本中预留扩展点，便于后续添加云存储功能 | |
| 不预留接口 | 不预留，Phase 2 时直接修改脚本 | |
| 插件架构 | 设计插件架构，支持动态加载功能 | ✓ |

**User's choice:** 插件架构
**Notes:** 设计插件架构，便于后续添加云存储功能。

### 预留通知接口
| Option | Description | Selected |
|--------|-------------|----------|
| 预留通知接口 | 预留通知接口，便于 Phase 5 集成 | ✓ |
| 不预留接口 | Phase 1 不实现通知，仅记录到日志 | |
| 本地通知 | 实现简单的本地通知（如桌面通知） | |

**User's choice:** 预留通知接口
**Notes:** 预留通知接口，便于集成监控告警。

---

## 测试与文档

### 测试模式实现
| Option | Description | Selected |
|--------|-------------|----------|
| 完整测试流程 | 创建测试数据库并验证完整备份和恢复流程 | ✓ |
| 基础测试 | 仅验证备份文件创建和基本检查 | |
| 单元测试 | 提供单元测试框架 | |

**User's choice:** 完整测试流程
**Notes:** 创建测试数据库并验证完整备份和恢复流程。

### 版本控制
| Option | Description | Selected |
|--------|-------------|----------|
| 添加版本信息 | 在脚本中添加版本号和更新日志 | |
| 使用 Git 标签 | 使用 Git 标签管理版本 | ✓ |
| 不进行版本控制 | 不进行版本控制 | |

**User's choice:** 使用 Git 标签
**Notes:** 使用 Git 标签管理版本。

### 文档注释
| Option | Description | Selected |
|--------|-------------|----------|
| 详细注释 | 详细的注释和文档头，说明功能、用法、依赖 | ✓ |
| 简洁注释 | 简洁的注释，仅说明关键步骤 | |
| 独立文档 | 创建独立的 README.md | |

**User's choice:** 详细注释
**Notes:** 脚本中包含详细注释和文档头。

### 恢复文档
| Option | Description | Selected |
|--------|-------------|----------|
| 创建恢复文档 | 在备份目录创建 README.md 说明如何恢复 | ✓ |
| 脚本注释说明 | 在脚本头部添加恢复说明注释 | |
| 推迟到 Phase 3 | Phase 3 再提供恢复文档 | |

**User's choice:** 创建恢复文档
**Notes:** 在备份目录创建详细的恢复文档（RESTORE.md）。

### 恢复文档详细程度
| Option | Description | Selected |
|--------|-------------|----------|
| 详细恢复文档 | 详细的恢复步骤、命令示例和故障排除 | ✓ |
| 简洁恢复文档 | 简洁的恢复命令参考 | |
| 交互式恢复脚本 | 交互式恢复脚本（Phase 3） | |

**User's choice:** 详细恢复文档
**Notes:** 详细的恢复步骤、命令示例和故障排除。

### 恢复文档位置
| Option | Description | Selected |
|--------|-------------|----------|
| 备份目录 | RESTORE.md 文件放在备份目录 | ✓ |
| 备份目录 README | README.md 文件放在备份目录 | |
| 项目根目录 | RESTORE.md 文件放在项目根目录 | |

**User's choice:** 备份目录
**Notes:** 恢复文档放在备份目录。

### 错误消息设计
| Option | Description | Selected |
|--------|-------------|----------|
| 详细错误消息 | 提供清晰的错误消息和解决建议 | ✓ |
| 简洁错误消息 | 简洁的错误码和简短描述 | |
| 错误代码 + 文档 | 提供错误代码和详细文档链接 | |

**User's choice:** 详细错误消息
**Notes:** 提供详细的错误消息和解决建议。

---

## 其他

### 操作系统支持
| Option | Description | Selected |
|--------|-------------|----------|
| macOS + Linux | 支持 macOS 和 Linux | ✓ |
| 仅 Linux | 仅支持 Linux（生产环境） | |
| POSIX 兼容 | 支持所有 POSIX 兼容系统 | |

**User's choice:** macOS + Linux
**Notes:** 支持 macOS 和 Linux 操作系统。

---

## Claude's Discretion

以下区域用户明确表示"让 Claude 决定"或选择"推荐选项"：

### 备份格式
- 备份文件格式的具体选择（已决定：严格使用 pg_dump -Fc）

### 全局对象备份
- 全局对象备份的具体实现方式（已决定：使用 pg_dumpall -g）

### Dry Run 模式
- 是否提供 --dry-run 模式（已决定：提供）

### 清理策略
- 备份失败时的清理策略（已决定：失败时清理所有备份文件）

### 超时设置
- 超时时间的具体值（Claude 建议：1 小时）
- 清理策略的默认保留天数（Claude 建议：7 天）
- 进度显示的具体格式和更新频率（Claude 自行决定）
- 元数据文件的具体字段和结构（Claude 自行决定）
- 审计日志的具体内容和格式（Claude 自行决定）
- 库文件的具体函数划分和命名（Claude 自行决定）
- 测试模式的具体实现细节（Claude 自行决定）

---

## Deferred Ideas

以下想法在讨论中被提及，但明确属于其他阶段：

### Phase 2: 云存储集成
- 云存储上传接口设计
- B2 Application Key 权限配置
- 上传重试和校验机制
- 云端清理策略

### Phase 3: 恢复脚本
- 一键恢复脚本
- 列出可用备份
- 恢复到不同数据库

### Phase 4: 自动化验证测试
- 每周自动恢复测试
- 临时数据库管理
- 测试失败告警

### Phase 5: 监控与告警
- Webhook 告警集成
- 耗时追踪和警告
- 结构化日志增强

### v2: 性能优化
- 并行备份多个数据库
- 增量备份（pg_basebackup + WAL）
- 压缩级别可配置

### v2: 高级功能
- PITR 时间点恢复
- 跨区域备份复制
- Web 管理面板

---

*Discussion log generated: 2026-04-06*
*Total gray areas discussed: 64*
*Total decisions made: 64*
