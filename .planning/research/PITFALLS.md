# Pitfalls Research

**Domain:** PostgreSQL 云备份系统（Docker 容器环境 + 云存储）
**Researched:** 2026-04-05
**Confidence:** HIGH

---

## Critical Pitfalls

### Pitfall 1: pg_dump 一致性误解 -- 认为备份了所有数据库就安全了

**What goes wrong:**
Noda 基础设施有多个数据库（keycloak_db、findclass_db）。pg_dump 每次只能备份一个数据库。如果只备份了 findclass_db 而忘记了 keycloak_db，灾难恢复时 Keycloak 配置丢失，所有用户认证失效。更严重的是，pg_dump 不备份角色（roles）和表空间（tablespaces）信息，恢复时可能因缺少角色导致权限错误。

**Why it happens:**
pg_dump 是单数据库工具。PostgreSQL 官方文档明确指出："pg_dump dumps only a single database at a time, and it does not dump information about roles or tablespaces (because those are cluster-wide rather than per-database)." 开发者经常以为一个 pg_dump 命令就备份了所有内容。

**How to avoid:**
- 使用 pg_dumpall --globals-only 单独备份角色和表空间定义
- 对每个数据库单独运行 pg_dump（keycloak_db、findclass_db、oneteam_prod）
- 在备份脚本中明确列出所有数据库名，不要使用通配符或硬编码单个库名
- 备份脚本中包含预检查：连接数据库后先列出所有数据库，确认都在备份列表中

**Warning signs:**
- 备份脚本只调用了一次 pg_dump
- 备份输出文件名中没有区分数据库名
- 恢复测试时发现缺少用户/角色

**Phase to address:**
Phase 1（备份脚本开发）-- 必须在第一个版本的备份脚本中就解决

---

### Pitfall 2: 恢复失败 -- 备份成功但恢复时才暴露问题

**What goes wrong:**
备份每天成功运行，日志显示一切正常。但当真正需要恢复时，发现：pg_dump 生成的纯文本格式恢复时遇到编码错误、扩展版本不兼容、或者恢复到不同版本的 PostgreSQL 时语法不兼容。更常见的是，恢复脚本从未被测试过，缺少关键步骤（如先创建数据库、设置 ON_ERROR_STOP）。

PostgreSQL 官方文档警告："you will only have a partially restored database"。默认情况下 psql 遇到错误会继续执行，导致恢复后数据库状态不完整但不报错。

**Why it happens:**
- pg_dump 的纯文本输出在不同 PostgreSQL 版本之间可能不兼容
- 恢复时缺少扩展或依赖
- 没有使用 `ON_ERROR_STOP=on` 或 `--single-transaction` 参数
- 恢复脚本从未被实际执行过
- 恢复脚本中忘记了 `createdb -T template0` 步骤

**How to avoid:**
- 使用 pg_dump -Fc（自定义格式）而非纯文本格式，用 pg_restore 恢复，支持选择性恢复和并行恢复
- 恢复脚本中使用 `psql --set ON_ERROR_STOP=on` 或 `--single-transaction`
- 恢复时必须先 `createdb -T template0 dbname`（用 template0 而非 template1）
- 恢复后运行 ANALYZE 更新统计信息
- 自动化恢复测试：每周在一个干净的测试环境中运行完整的备份恢复流程

**Warning signs:**
- 备份文件是纯 SQL 文本格式（.sql）而非自定义格式（.dump）
- 从未执行过恢复测试
- 恢复脚本只有下载步骤，没有实际的 pg_restore/psql 步骤

**Phase to address:**
Phase 1（备份脚本开发）-- 选择 -Fc 格式；Phase 3（自动化测试）-- 建立恢复测试流水线

---

### Pitfall 3: 云存储生命周期规则误配 -- 7天保留策略的 B2 特殊陷阱

**What goes wrong:**
Backblaze B2 的生命周期规则基于文件版本（version），不是基于独立文件。Noda 项目每 6-12 小时生成一个新备份文件，文件名包含时间戳所以每个文件名不同。这意味着 `daysFromHidingToDeleting` 规则（删除旧版本）不会生效，因为每个备份文件的名称都不同，它们被视为独立文件而非同一文件的旧版本。

如果错误地使用 `daysFromUploadingToHiding` 来隐藏旧备份，会导致所有备份（包括最新的）在 7 天后被隐藏，无法通过正常列表看到。

**Why it happens:**
Backblaze B2 的生命周期规则设计初衷是管理同一文件的版本历史（如备份软件上传同名文件时产生的旧版本），而不是管理不同名称的独立文件。开发者通常将"删除 7 天前的备份"理解为设置一个简单的生命周期规则，但 B2 的规则语义与直觉不同。

**How to avoid:**
- **不要依赖 B2 生命周期规则来管理备份保留**。因为每个备份文件名不同（含时间戳），生命周期规则无法按预期工作
- 在备份脚本中实现应用层清理逻辑：上传新备份后，列出 bucket 中的旧备份文件，删除超过 7 天的
- 如果确实想用生命周期规则，必须使用 `daysFromUploadingToHiding` 配合 `daysFromHidingToDeleting`，但要清楚这会隐藏/删除该前缀下的所有文件（包括最近的），不适合备份场景
- 在清理逻辑中保留安全缓冲：删除超过 8 天的文件（而非恰好 7 天），避免时区或定时任务延迟导致误删

**Warning signs:**
- Bucket 中文件数量持续增长，没有自动清理
- 生命周期规则已设置但旧备份未被删除
- 最新备份被意外隐藏或删除

**Phase to address:**
Phase 2（云存储集成）-- 清理逻辑必须与上传逻辑一起实现

---

### Pitfall 4: 凭证硬编码和泄露 -- 最常见的安全事故

**What goes wrong:**
云存储的 Access Key 和 Secret Key 被硬编码在备份脚本中、写入 .env 文件但没有 .gitignore、或以明文形式出现在 Docker Compose 配置中。一旦代码仓库泄露（包括推送到公开 GitHub），攻击者可以访问所有备份数据，甚至删除所有备份。

当前项目中 `.env.production` 包含了数据库密码等敏感信息，且初始化 SQL 脚本 `01-create-databases.sql` 中硬编码了用户密码（keycloak_password_change_me、findclass_password_change_me）。

**Why it happens:**
- 图方便直接在脚本中写入密钥
- .env 文件没有被 .gitignore 忽略
- Backblaze B2 的 Master Application Key 权限过大，一旦泄露影响整个账户
- 团队成员不了解 Backblaze B2 的 Application Key 权限模型

**How to avoid:**
- 为备份系统创建专用的 Backblaze B2 Standard Application Key，权限限制为：
  - 仅限特定 bucket（不能访问其他 bucket）
  - 仅限 writeFiles + deleteFiles + listFiles 权限（最低权限原则）
  - 设置 fileNamePrefix 限制为备份路径前缀
  - 不设置过期时间（或设置较长的有效期并记录在日历中提醒轮换）
- 绝不使用 Master Application Key
- 凭证通过环境变量传入脚本，不要硬编码
- 确保 .env 文件在 .gitignore 中（当前 .env.production 已被 Git 追踪，需要立即处理）
- 在 CI/CD 中使用 Jenkins Credentials 或密钥管理服务

**Warning signs:**
- 脚本中出现明文 API Key
- .env 文件被提交到 Git
- 使用 Master Application Key
- 单个 Key 能访问所有 bucket

**Phase to address:**
Phase 1（备份脚本开发）-- 凭证管理必须从一开始就正确

---

### Pitfall 5: Docker 容器环境下的调度失效 -- cron 消失

**What goes wrong:**
在 Docker 容器内运行 cron 定时任务，但容器重启后 cron 服务没有自动启动。或者 cron 任务使用了容器内的时区，与预期时区（Pacific/Auckland）不一致。更隐蔽的问题是，cron 任务在容器内运行 pg_dump 时，如果 PostgreSQL 容器已经停止或网络不通，备份会静默失败。

**Why it happens:**
- Docker 容器默认不运行 init 系统，cron 不会自动启动
- 容器时区默认是 UTC，与新西兰时区 NZST（UTC+12/NZDT UTC+13）不一致
- cron 日志默认不输出到 Docker stdout/stderr，导致 `docker logs` 看不到备份日志
- 容器 restart: unless-stopped 策略不会自动启动 cron 服务

**How to avoid:**
- **推荐方案：使用 Jenkins cron 调度**（项目已有 Jenkins 基础设施），避免在 Docker 容器内运行 cron
- 如果使用 Docker 容器内 cron：
  - 使用专门的备份容器（而非进入 PostgreSQL 容器）
  - 设置 `TZ=Pacific/Auckland` 环境变量
  - 确保入口脚本同时启动 cron 和 supervisord
  - 将 cron 输出重定向到 stdout：`* */6 * * * /backup.sh >> /proc/1/fd/1 2>&1`
- 备份脚本添加健康检查：执行前先验证 PostgreSQL 可连接
- 使用 `docker compose exec` 或从备份容器通过 Docker 网络连接 PostgreSQL

**Warning signs:**
- `docker logs` 中看不到任何备份日志
- 备份文件的时间戳与预期不符（差 12-13 小时说明是 UTC vs NZ 时区问题）
- 容器重启后备份停止运行

**Phase to address:**
Phase 1（备份脚本开发）-- 调度方案选择；Phase 2（自动化集成）-- 容器化调度

---

### Pitfall 6: 网络传输失败 -- 上传中断和静默数据损坏

**What goes wrong:**
备份文件上传到 Backblaze B2 时网络中断，导致上传不完整。脚本没有验证上传结果，认为备份成功。更常见的问题是：上传超时后脚本重试，但之前的不完整上传（unfinished large file）残留在 B2 中，占用存储空间并持续计费。

Backblaze B2 对大文件使用分片上传（multipart upload），每个分片最大 5GB。如果网络不稳定，可能部分分片上传成功但整体文件不完整。

**Why it happens:**
- 备份文件较大（数据库增长后），上传时间超过网络超时设置
- 脚本没有实现校验和验证（上传前计算 checksum，上传后对比）
- Backblaze B2 的 unfinished large files 默认不会被自动清理（除非设置了 `daysFromStartingToCancelingUnfinishedLargeFiles` 生命周期规则）
- 脚本使用简单的 `aws s3 cp` 但没有检查返回码

**How to avoid:**
- 上传前计算 SHA256 校验和，上传后用 `head-object` 或 `b2_get_file_info` 对比
- 使用 `aws s3 cp` 时检查退出码（`$?`），失败时重试（指数退避，最多 3 次）
- 设置 B2 bucket 的生命周期规则：`daysFromStartingToCancelingUnfinishedLargeFiles: 1`，自动清理未完成的上传
- 对大文件使用分片上传，设置合理的分片大小（如 100MB）
- 备份脚本必须有明确的成功/失败退出码，便于监控系统判断

**Warning signs:**
- 上传统常超时或失败
- B2 账单中出现未预期的存储费用（unfinished large files 占用空间）
- 备份文件大小不一致或比预期小很多

**Phase to address:**
Phase 2（云存储集成）-- 上传逻辑和校验；Phase 4（监控告警）-- 传输失败告警

---

### Pitfall 7: 备份文件未压缩 -- 存储成本和传输时间倍增

**What goes wrong:**
pg_dump 默认输出的纯文本 SQL 文件未压缩。对于一个中等规模的数据库（100MB-1GB），未压缩的 SQL 文本可能是实际数据的 3-5 倍大小。这不仅增加存储成本（虽然 B2 仅 $6/TB/月，但长期累积不可忽视），更严重的是增加上传时间，导致备份窗口过长。

**Why it happens:**
- pg_dump 默认输出纯文本，没有内置压缩
- 开发者不了解 pg_dump -Fc 自定义格式自带压缩
- 或者使用了纯文本格式配合管道压缩，但没有测试压缩/解压流程

**How to avoid:**
- 使用 `pg_dump -Fc`（自定义格式），自带 zlib 压缩，且支持并行恢复
- 或者使用 `pg_dump | gzip > backup.sql.gz`（纯文本 + gzip），简单且压缩效果好
- 如果使用 -Fd（目录格式），可以用 `-j` 参数并行备份，加快大型数据库的备份速度
- 不要同时使用 -Fc 和 gzip（双重压缩没有额外收益）

**Warning signs:**
- 备份文件是 .sql 纯文本格式
- 备份文件大小接近或超过数据库实际大小
- 上传时间超过 10 分钟（对小数据库来说太长）

**Phase to address:**
Phase 1（备份脚本开发）-- 格式选择必须在第一版确定

---

### Pitfall 8: 监控盲区 -- 备份成功但数据损坏

**What goes wrong:**
备份脚本返回退出码 0，日志显示"备份成功"，但实际上：pg_dump 过程中遇到了非致命错误（如权限不足导致部分表被跳过）、数据库本身已损坏、或磁盘空间不足导致输出文件被截断。监控系统只检查退出码，认为一切正常，直到灾难发生时才发现备份不可用。

**Why it happens:**
- pg_dump 在遇到某些错误时可能仍然返回 0（如使用 --if-exists 时遇到不存在的对象）
- 脚本只检查了命令退出码，没有检查 stderr 输出
- 没有验证备份文件的完整性（文件大小、能否被 pg_restore 读取目录）
- 磁盘空间不足时 pg_dump 可能写入一个不完整的文件而不报错

**How to avoid:**
- 备份后立即验证：`pg_restore --list backup.dump` 能成功列出内容
- 检查备份文件大小是否在合理范围内（与上次备份比较，偏差不超过 50%）
- 记录每次备份的行数/表数，与历史数据对比
- 检查 stderr 输出中是否有 WARNING 或 ERROR
- 监控本地磁盘空间，空间不足时立即告警
- 实现 BACKUP-06（每周自动恢复测试）作为最终保障

**Warning signs:**
- 备份文件大小突然变小
- pg_restore --list 输出错误
- 备份日志中有 WARNING 但被忽略
- 本地磁盘使用率超过 90%

**Phase to address:**
Phase 1（备份脚本开发）-- 基本验证；Phase 4（监控告警）-- 完整监控

---

### Pitfall 9: WAL 归档与 pg_dump 的混淆

**What goes wrong:**
当前 PostgreSQL 配置已启用 WAL 归档（`archive_mode = on`，`archive_command` 指向本地目录），但 WAL 归档文件只存储在本地 Docker volume 中。开发者可能认为有了 WAL 归档就等于有了完整备份，但 WAL 归档需要配合基础备份（base backup）才能实现 PITR（时间点恢复）。单独的 WAL 归档文件无法恢复数据。

同时，pg_dump 和 WAL 归档是两种独立的备份策略，不应该混用。pg_dump 是逻辑备份（SQL 级别），WAL 归档是物理备份（文件级别）。

**Why it happens:**
PostgreSQL 的备份概念体系复杂（逻辑备份 vs 物理备份、基础备份 vs WAL 归档、PITR），容易混淆。WAL 归档看起来像"自动备份"，但实际上它只是事务日志，需要配合 pg_basebackup 才能恢复。

**How to avoid:**
- 明确选择一种备份策略。对于 Noda 项目的规模（小中型数据库），pg_dump 足够
- 如果不使用 PITR，考虑关闭 WAL 归档（`archive_mode = off`），减少不必要的磁盘 I/O 和存储
- 如果保留 WAL 归档，必须定期运行 pg_basebackup 作为基础备份，并且 WAL 归档文件也要上传到云存储
- 在文档中清楚说明当前使用的是哪种备份策略

**Warning signs:**
- WAL 归档目录持续增长但从未清理
- 只有 WAL 文件没有基础备份
- 备份策略文档中同时提到 pg_dump 和 PITR 但没有说明关系

**Phase to address:**
Phase 1（备份脚本开发）-- 明确备份策略，清理现有配置中的混淆

---

### Pitfall 10: 加密误解 -- 云存储"加密"不等于端到端安全

**What goes wrong:**
Backblaze B2 默认提供 SSE-B2（服务端加密，使用 B2 管理的密钥）。开发者认为这已经"加密"了，但实际上这意味着 Backblaze 持有加密密钥，任何有账户访问权限的人都可以解密数据。如果 Access Key 泄露，攻击者可以下载并读取所有备份数据。

对于 PostgreSQL 备份，更大的风险是：备份文件中包含了完整的数据库内容，包括用户个人信息、密码哈希、Keycloak 配置等敏感数据。

**Why it happens:**
- 对"加密"的理解不够精确：传输加密（TLS）不等于存储加密，SSE 不等于零知识加密
- Backblaze B2 的 SSE-B2 默认开启，让开发者误以为数据已经安全
- pg_dump 输出是纯文本（或自定义格式的二进制），包含所有明文数据

**How to avoid:**
- 启用 B2 的 SSE-B2（至少保证存储加密），这在 B2 中已经是默认行为
- 对于更高安全要求，使用 SSE-C（客户管理的密钥）：上传时提供自己的加密密钥，B2 不存储密钥
- 关键安全措施：保护 Access Key（见 Pitfall 4），这比加密方式更重要
- pg_dump -Fc 格式的输出虽然是二进制，但不是加密的，不要混淆"二进制"和"加密"
- 对于当前项目规模，SSE-B2 + 严格的 Key 权限管理已足够

**Warning signs:**
- 安全策略中只写了"使用云存储加密"但没有说明具体方式
- 使用 Master Application Key 访问 B2
- 备份文件可以直接用 pg_restore 读取而不需要密钥

**Phase to address:**
Phase 2（云存储集成）-- 加密配置；Phase 4（安全审计）-- 验证加密方案

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| 只备份一个数据库 | 脚本简单，快速完成 | Keycloak 数据丢失导致全部认证失效 | 永远不可接受 |
| 使用纯文本 pg_dump | 简单直接，可用 psql 恢复 | 文件大、恢复不可控、无法选择性恢复 | 仅用于开发环境的临时备份 |
| 依赖 B2 生命周期规则清理 | 不用写清理代码 | 备份文件名含时间戳，规则不生效 | 永远不可接受 -- 必须在脚本中清理 |
| 备份脚本中硬编码密钥 | 快速完成开发 | 密钥泄露导致全部备份数据暴露 | 仅用于本地开发测试，且必须是不含真实数据的 Key |
| 跳过恢复测试 | 节省测试时间 | 灾难时才发现备份不可用 | 永远不可接受 |
| 不验证上传结果 | 脚本简单 | 备份文件损坏或上传不完整 | 永远不可接受 |
| 保留 WAL 归档但不配合 base backup | 看起来有备份 | 占用磁盘空间但无法恢复 | 可以暂时保留（已有 pg_dump），但应评估是否关闭 |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Backblaze B2 S3 API | 使用 AWS S3 的 endpoint URL | 必须使用 B2 的 S3 endpoint：`s3.<region>.backblazeb2.com` |
| AWS CLI with B2 | 忽略 B2 不支持的功能 | B2 不支持 IAM Roles、Object Tagging、Website Configuration；使用 S3 API 时要注意兼容性 |
| pg_dump in Docker | 在宿主机上运行 pg_dump 连接容器 | 使用与 PostgreSQL 容器相同版本的 pg_dump（17.9），通过 Docker 网络连接 |
| Docker networking | 使用 localhost:5432 连接 | 使用 Docker 服务名 `postgres:5432` 连接（仅在 Docker 网络内） |
| B2 Application Key | 使用 Master Key | 创建专用的 Standard Key，限制到单个 bucket 和必要的权限 |
| B2 lifecycle rules | 用 daysFromHidingToDeleting 管理 7 天保留 | 该规则只管同名文件的旧版本；不同名称的备份文件需应用层清理 |
| pg_restore | 直接恢复到运行中的数据库 | 恢复前先创建干净的数据库（从 template0），恢复后运行 ANALYZE |
| Jenkins cron | 在 Jenkins controller 上运行 pg_dump | 确保 Jenkins agent 上安装了与 PostgreSQL 版本匹配的客户端工具 |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| 未压缩的 pg_dump | 备份文件 > 500MB，上传 > 10min | 使用 -Fc 格式（自带压缩） | 数据库 > 100MB |
| 备份锁表 | 应用响应变慢，出现锁等待 | pg_dump 不阻塞读操作，但会阻塞 DDL；在低峰期运行 | 大量 DDL 操作期间 |
| 磁盘空间不足 | pg_dump 失败，容器崩溃 | 监控磁盘使用率，备份到临时目录后立即上传删除 | 本地存储 < 2x 数据库大小 |
| 上传带宽瓶颈 | 备份窗口超时 | 使用压缩减少传输量，分片上传 | 网络带宽 < 10Mbps |
| B2 API 调用频率 | 超过免费额度产生费用 | 合并 API 调用，使用分片上传减少请求次数 | 每天 > 2500 次 Class B/C 调用 |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| 使用 Master Application Key | 泄露后攻击者可访问/删除所有 bucket 所有文件 | 创建专用 Standard Key，限制到单个 bucket + 最低权限 |
| .env 文件提交到 Git | 所有密钥暴露在版本控制历史中 | 确保 .gitignore 包含 .env*（当前 .env.production 已被追踪，需清理） |
| 初始化 SQL 中硬编码密码 | 密码以明文存储在 Git 中 | 使用环境变量传入密码，init 脚本中引用 ${VAR} |
| 备份文件无加密传输 | 中间人可截获数据库完整内容 | 确保使用 HTTPS（B2 S3 API 默认强制 TLS） |
| 备份 bucket 设为 public | 任何人可下载所有备份 | bucket 必须设为 private（allPrivate） |
| SQL 初始化脚本中明文密码 | keycloak_password_change_me、findclass_password_change_me 在 Git 中 | 使用环境变量或 Docker secrets |

## "Looks Done But Isn't" Checklist

- [ ] **备份脚本:** 常缺失对所有数据库的备份 -- 验证脚本循环覆盖 keycloak_db、findclass_db、oneteam_prod
- [ ] **云存储上传:** 常缺失上传后校验 -- 验证上传后检查文件大小或校验和
- [ ] **旧备份清理:** 常缺失清理逻辑 -- 验证超过 7 天的备份文件被自动删除
- [ ] **恢复脚本:** 常缺失完整的恢复流程 -- 验证包含创建数据库、恢复数据、运行 ANALYZE
- [ ] **告警通知:** 常缺失失败告警 -- 验证备份失败时有 webhook/邮件通知
- [ ] **日志输出:** 常缺失结构化日志 -- 验证日志包含时间戳、操作类型、数据库、文件大小、耗时、状态
- [ ] **权限最小化:** 常缺失专用 API Key -- 验证使用受限的 Standard Application Key
- [ ] **时区处理:** 常缺失时区配置 -- 验证备份文件名使用 Pacific/Auckland 时区
- [ ] **WAL 归档:** 常缺失归档策略说明 -- 验证文档中明确说明 pg_dump 与 WAL 归档的关系

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| 只备份了一个数据库 | MEDIUM | 立即补充备份缺失的数据库；如有本地 WAL 归档可尝试恢复 |
| 备份格式错误导致恢复失败 | LOW | 用 pg_restore --list 检查；如纯文本格式可手动编辑修复 |
| B2 旧备份未清理 | LOW | 手动运行清理脚本；设置 daysFromStartingToCancelingUnfinishedLargeFiles: 1 清理残留上传 |
| 凭证泄露 | HIGH | 立即轮换所有泄露的 Key；检查 B2 访问日志；审计是否有未授权操作 |
| Docker cron 失效 | LOW | 切换到 Jenkins 调度；或重新配置容器入口点 |
| 备份文件损坏 | HIGH | 尝试恢复到最近的可用备份；如有 WAL 归档可尝试 PITR 恢复 |
| 加密配置错误 | LOW | 重新配置 SSE-B2 或 SSE-C；现有文件自动使用新加密策略 |
| 恢复脚本未测试 | MEDIUM | 在测试环境执行完整恢复流程；修复发现的问题后更新脚本 |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 多数据库备份遗漏 | Phase 1（备份脚本） | 备份脚本列出所有数据库并逐一备份 |
| 恢复失败 | Phase 1（格式选择）+ Phase 3（自动化测试） | pg_restore --list 成功；每周恢复测试通过 |
| B2 生命周期规则误配 | Phase 2（云存储集成） | 清理脚本正确删除超过 7 天的独立备份文件 |
| 凭证硬编码 | Phase 1（备份脚本） | 代码审查确认无硬编码密钥；Key 权限最小化 |
| Docker 调度失效 | Phase 2（自动化集成） | Jenkins cron 按预期触发；容器重启后调度恢复 |
| 网络传输失败 | Phase 2（云存储集成） | 上传后校验和匹配；重试机制工作正常 |
| 未压缩备份 | Phase 1（格式选择） | 使用 -Fc 格式，文件大小比纯文本小 60-80% |
| 监控盲区 | Phase 4（监控告警） | 备份失败或文件异常时告警触发 |
| WAL 归档混淆 | Phase 1（策略明确） | 文档明确备份策略；评估是否关闭 archive_mode |
| 加密误解 | Phase 2（加密配置） | 使用 SSE-B2；Access Key 严格受限 |

## Sources

- PostgreSQL 官方文档：SQL Dump (https://www.postgresql.org/docs/current/backup-dump.html) -- pg_dump 一致性保证、恢复注意事项、自定义格式说明
- PostgreSQL 官方文档：pg_dump 参考 (https://www.postgresql.org/docs/current/app-pgdump.html) -- 命令行参数、格式选项
- Backblaze B2 定价页面 (https://www.backblaze.com/cloud-storage/pricing) -- 存储费用 $6/TB/月，免费 egress 3x
- Backblaze B2 API 交易定价 (https://www.backblaze.com/cloud-storage/transaction-pricing) -- Class A 免费，Class B/C 每天 2500 次免费
- Backblaze B2 生命周期规则文档 (https://www.backblaze.com/docs/cloud-storage-lifecycle-rules) -- 规则语义、版本管理、daysFromHidingToDeleting vs daysFromUploadingToHiding
- Backblaze B2 S3 兼容 API 文档 (https://www.backblaze.com/docs/cloud-storage-s3-compatible-api) -- SSE 支持、不支持的功能列表
- Backblaze B2 Application Keys 文档 (https://www.backblaze.com/docs/cloud-storage-application-keys) -- Standard vs Master Key、权限限制、最佳实践
- Noda 项目代码库分析：docker-compose.yml、docker-compose.prod.yml、postgresql.conf、01-create-databases.sql

---
*Pitfalls research for: Noda PostgreSQL 云备份系统*
*Researched: 2026-04-05*
