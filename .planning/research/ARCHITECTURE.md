# Architecture Patterns: PostgreSQL 云备份系统

**Domain:** 数据库备份系统，集成到现有 Docker Compose 基础设施
**Researched:** 2026-04-06
**Overall confidence:** HIGH（基于项目代码库直接分析 + STACK.md 技术决策）

---

## 推荐架构总览

```
                                 Noda 基础设施
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  ┌──────────────┐                                                   │
│  │  Jenkins      │── cron 触发（每6小时）──┐                        │
│  │  (noda-jenkins)│                         │                        │
│  └──────────────┘                           ▼                        │
│                              ┌──────────────────────────┐           │
│                              │  backup-to-cloud.sh      │           │
│                              │  (新组件：备份编排脚本)    │           │
│                              └──────────────────────────┘           │
│                                         │                            │
│                          ┌──────────────┼──────────────┐            │
│                          ▼              ▼              ▼            │
│                   ┌───────────┐  ┌───────────┐  ┌───────────┐     │
│                   │ pg_dump   │  │ pg_dump   │  │ pg_dumpall│     │
│                   │ noda_prod │  │ keycloak  │  │ globals   │     │
│                   └─────┬─────┘  └─────┬─────┘  └─────┬─────┘    │
│                         │              │              │            │
│                         └──────────────┼──────────────┘            │
│                                        ▼                            │
│                              ┌──────────────────┐                   │
│                              │  .dump 文件       │                   │
│                              │  (临时本地存储)    │                   │
│                              │  /tmp/backup-*    │                   │
│                              └────────┬─────────┘                   │
│                                       │                             │
│                              ┌────────▼─────────┐                   │
│                              │  rclone copy      │                   │
│                              │  + 校验和验证      │                   │
│                              └────────┬─────────┘                   │
│                                       │                             │
└───────────────────────────────────────┼─────────────────────────────┘
                                        │ HTTPS (SSE-B2 加密)
                                        ▼
                              ┌─────────────────────┐
                              │  Backblaze B2        │
                              │  Bucket: noda-backup │
                              │                      │
                              │  noda_prod/          │
                              │    noda_prod_*.dump  │
                              │  keycloak/           │
                              │    keycloak_*.dump   │
                              │  globals/            │
                              │    globals_*.sql     │
                              └─────────────────────┘
```

---

## 一、组件清单：新组件 vs 修改现有组件

### 新增组件

| 组件 | 类型 | 位置 | 职责 |
|------|------|------|------|
| `backup-to-cloud.sh` | Shell 脚本 | `scripts/backup/` | 备份编排：调用 pg_dump -> 上传 -> 清理旧备份 -> 输出状态 |
| `verify-backup.sh` | Shell 脚本 | `scripts/backup/` | 下载最新备份并运行 `pg_restore --list` 验证完整性 |
| `restore-from-cloud.sh` | Shell 脚本 | `scripts/backup/` | 一键恢复：从 B2 下载 -> pg_restore 到目标数据库 |
| `notify-status.sh` | Shell 脚本 | `scripts/backup/` | 发送备份状态通知（成功/失败），支持 webhook |
| `Jenkinsfile.backup` | Jenkins Pipeline | 项目根目录或 `jenkins/` | Jenkins 流水线定义，定时触发备份 |
| `rclone.conf`（模板） | 配置文件 | `config/backup/` | rclone B2 远程连接配置（凭据通过 SOPS 加密管理） |
| `.env.backup`（模板） | 环境变量 | `config/backup/` | 备份相关环境变量（B2 bucket 名、保留天数等） |

### 需要修改的现有组件

| 组件 | 修改内容 | 影响范围 | 修改量 |
|------|---------|---------|--------|
| `config/secrets.sops.yaml` | 新增 B2 API 凭据字段 | 仅追加，不影响现有字段 | 小 |
| `deploy.sh` | 可选：安装 rclone（如果宿主机没有） | 可作为独立步骤 | 小 |
| `docker-compose.jenkins.yml` | 可选：挂载 rclone 配置到 Jenkins 容器 | 添加一行 volume 挂载 | 极小 |
| `backups/README.md` | 更新为云备份说明 | 纯文档 | 小 |
| `.gitignore` | 确保 `config/backup/rclone.conf` 不被提交 | 追加一行 | 极小 |

### 不需要修改的组件

| 组件 | 原因 |
|------|------|
| `docker-compose.simple.yml` | 备份通过 `docker exec` 访问 PostgreSQL，不需要新容器 |
| `docker-compose.app.yml` | 备份不影响应用服务 |
| `docker-compose.prod.yml` | 备份在宿主机/Jenkins 层面执行，不涉及生产配置覆盖 |
| PostgreSQL 容器 | pg_dump 已内置在 postgres:17.9 镜像中 |
| Nginx 配置 | 备份系统不通过 HTTP 暴露 |
| Cloudflare Tunnel | 备份上传走宿主机到 B2 的 HTTPS，不经过 Tunnel |

**关键设计决策：备份不在 Docker 网络内运行，而是在宿主机/Jenkins 容器内通过 `docker exec` 调用 pg_dump。** 这避免了给 Docker Compose 配置增加复杂性。

---

## 二、备份流程架构

### 数据流

```
Jenkins cron 触发
       │
       ▼
backup-to-cloud.sh
       │
       ├─ 1. 前置检查
       │     ├─ 检查 PostgreSQL 容器健康状态
       │     ├─ 检查 rclone 配置是否可用
       │     └─ 检查磁盘空间（至少 2x 预估备份大小）
       │
       ├─ 2. 数据库转储
       │     ├─ docker exec postgres pg_dump -Fc -U postgres -d noda_prod
       │     ├─ docker exec postgres pg_dump -Fc -U postgres -d keycloak
       │     └─ docker exec postgres pg_dumpall --globals-only -U postgres
       │
       ├─ 3. 本地验证
       │     └─ pg_restore --list 验证每个 .dump 文件可读
       │
       ├─ 4. 云上传
       │     ├─ rclone copy --checksum --contimeout 60s --retries 3
       │     └─ rclone check 验证上传完整性
       │
       ├─ 5. 清理旧备份（云端）
       │     └─ rclone delete --min-age 7d（按数据库子目录）
       │
       └─ 6. 清理临时文件
             └─ rm -f /tmp/backup-*.dump
```

### 关键设计原则

1. **原子性**：每个数据库独立备份。一个数据库备份失败不影响其他数据库的备份和上传。
2. **先验证后上传**：本地先用 `pg_restore --list` 验证 .dump 文件完整性，再上传到云端。
3. **校验和保护**：rclone 上传时使用 `--checksum` 参数，上传后用 `rclone check` 验证。
4. **临时文件隔离**：所有临时文件使用 `/tmp/backup-` 前缀，备份完成后清理。
5. **幂等性**：脚本可以安全地重复执行，不会产生重复文件或状态错误。

### 脚本接口设计

```bash
# backup-to-cloud.sh 接口
# 输入：无（通过环境变量配置）
# 输出：stdout 日志 + exit code（0=成功，1=失败）
# 环境变量：
#   B2_REMOTE     - rclone 远程名称（默认：b2-backup）
#   B2_BUCKET     - B2 bucket 名称（默认：noda-db-backup）
#   RETENTION_DAYS - 保留天数（默认：7）
#   BACKUP_DBS    - 要备份的数据库列表（默认："noda_prod keycloak"）
#   PG_CONTAINER  - PostgreSQL 容器名（默认：noda-infra-postgres-1）
```

---

## 三、存储架构

### B2 Bucket 结构

```
noda-db-backup/                         # Bucket 根
├── noda_prod/                          # 生产数据库备份
│   ├── noda_prod_20260406_0001.dump    # 自定义格式（-Fc）
│   ├── noda_prod_20260406_1200.dump
│   ├── noda_prod_20260406_1800.dump
│   ├── noda_prod_20260407_0001.dump
│   └── ...
├── keycloak/                           # Keycloak 数据库备份
│   ├── keycloak_20260406_0001.dump
│   ├── keycloak_20260406_1200.dump
│   └── ...
└── globals/                            # 全局角色和表空间定义
    ├── globals_20260406_0001.sql
    ├── globals_20260406_1200.sql
    └── ...
```

### 文件命名规范

```
{database}_{YYYYMMDD}_{HHMM}.dump       # 数据库备份
globals_{YYYYMMDD}_{HHMM}.sql           # 全局对象备份
```

**设计理由：**
- 时间戳使用 UTC，避免时区混乱
- 按数据库名分目录，便于 rclone 按目录清理旧备份
- `.dump` 扩展名表示 -Fc 自定义格式，`.sql` 表示纯文本
- 时间戳精度到分钟（HHMM），对于 6 小时备份频率足够区分

### 元数据

每个备份文件通过 B2 的文件信息（file info）携带元数据：

```
source: noda-infra
database: noda_prod
pg_version: 17.9
backup_type: full
backup_tool: pg_dump -Fc
created_by: jenkins-backup-job
```

rclone 上传时通过 `--metadata` 参数附加（rclone 1.62+ 支持）。

### 保留策略

```
云端保留：7 天（按 RETENTION_DAYS 环境变量控制）
    → 7天 x 4次/天 = ~28 个文件/数据库
    → 3个数据库 x 28 = ~84 个文件

本地不保留：备份上传成功后删除本地临时文件
    → 原因：本地磁盘空间有限，且云端已有校验和验证
```

**清理脚本逻辑：**

```bash
# 清理指定数据库目录中超过 RETENTION_DAYS 天的文件
rclone delete "${B2_REMOTE}:${B2_BUCKET}/${db_name}/" \
    --min-age "${RETENTION_DAYS}d" \
    --verbose
```

注意：不使用 B2 生命周期规则。原因见 PITFALLS.md Pitfall 3 -- B2 生命周期基于文件版本而非时间戳。

---

## 四、调度架构

### 调度方式：Jenkins Pipeline

```
Jenkins Server (noda-jenkins)
┌─────────────────────────────────┐
│                                 │
│  Jenkinsfile.backup             │
│  ┌───────────────────────────┐  │
│  │ triggers:                  │  │
│  │   cron('H */6 * * *')     │  │── 每6小时触发
│  │                            │  │
│  │ stages:                    │  │
│  │   1. Pre-flight checks     │  │── 检查依赖和状态
│  │   2. Backup databases      │  │── 执行 pg_dump
│  │   3. Verify backups        │  │── pg_restore --list
│  │   4. Upload to B2          │  │── rclone copy + check
│  │   5. Cleanup old backups   │  │── rclone delete --min-age
│  │   6. Cleanup temp files    │  │── rm /tmp/backup-*
│  │                            │  │
│  │ post:                      │  │
│  │   success: notify          │  │── webhook 通知（可选）
│  │   failure: notify          │  │── webhook 通知（必须）
│  └───────────────────────────┘  │
│                                 │
│  Credentials:                   │
│   b2-key-id     (Secret text)   │
│   b2-app-key    (Secret text)   │
│                                 │
└─────────────────────────────────┘
```

### 为什么不用 Docker 容器 cron

| 问题 | Jenkins 方案 | Docker cron 方案 |
|------|-------------|-----------------|
| 时区配置 | Jenkins 全局配置 | 需要在容器中设置 TZ |
| 日志查看 | Jenkins Web UI | 需要 docker logs |
| 通知集成 | Jenkins 内置 | 需要自行实现 |
| 手动触发 | Jenkins "Build Now" | 需要 docker exec |
| 凭据管理 | Jenkins Credentials | 需要挂载或环境变量 |
| 容器重启 | 无影响（Jenkins 持久化） | cron 任务丢失（除非持久化） |
| 运维成本 | 低（已有 Jenkins） | 高（新增容器管理） |

详细分析见 PITFALLS.md Pitfall 5。

### Jenkins 与 Docker 的交互方式

```
Jenkins 容器
    │
    │ docker exec（通过挂载的 docker.sock）
    ▼
noda-infra-postgres-1 容器
    │
    │ pg_dump -Fc
    ▼
Jenkins 容器内的临时文件
    │
    │ rclone copy
    ▼
Backblaze B2
```

**关键集成点：** Jenkins 容器已挂载 `/var/run/docker.sock`（见 `docker-compose.jenkins.yml` 第 12 行），可以直接执行 `docker exec` 命令操作 PostgreSQL 容器。

---

## 五、恢复架构

### 恢复流程

```
restore-from-cloud.sh
       │
       ├─ 1. 选择恢复源
       │     ├─ 参数指定：--date YYYYMMDD --time HHMM
       │     └─ 默认：最新备份
       │
       ├─ 2. 从 B2 下载
       │     ├─ rclone copy 下载 .dump 文件到 /tmp/
       │     └─ rclone check 验证下载完整性
       │
       ├─ 3. 验证备份文件
       │     └─ pg_restore --list 验证可读性
       │
       ├─ 4. 停止相关服务（可选）
       │     └─ docker compose stop api keycloak
       │        （避免恢复期间写入冲突）
       │
       ├─ 5. 恢复数据库
       │     ├─ 重建目标数据库（drop + create）
       │     ├─ pg_restore -Fc -U postgres -d noda_prod < dump文件
       │     └─ 恢复全局对象（角色/表空间）
       │
       └─ 6. 重启服务
             └─ docker compose start api keycloak
```

### 恢复脚本接口

```bash
# restore-from-cloud.sh 接口
# 用法：
#   ./restore-from-cloud.sh                          # 恢复最新备份到 noda_prod
#   ./restore-from-cloud.sh --db noda_prod           # 恢复指定数据库
#   ./restore-from-cloud.sh --db noda_prod --date 20260406  # 恢复指定日期的备份
#   ./restore-from-cloud.sh --list                    # 列出可用备份
#   ./restore-from-cloud.sh --dry-run                 # 只下载验证不实际恢复

# 参数：
#   --db DATABASE    目标数据库名（默认：noda_prod）
#   --date YYYYMMDD  恢复指定日期的备份（默认：最新）
#   --time HHMM      恢复指定时间的备份（默认：当天最新）
#   --list           列出云端可用备份
#   --dry-run        只下载和验证，不实际恢复
#   --target CONTAINER  目标 PostgreSQL 容器（默认：noda-infra-postgres-1）
```

### 每周自动恢复测试

```
Jenkins 定时任务（每周日凌晨 3 点）
       │
       ▼
verify-backup.sh
       │
       ├─ 1. 从 B2 下载最新 noda_prod 备份
       ├─ 2. 创建临时数据库 noda_verify
       ├─ 3. pg_restore 到 noda_verify
       ├─ 4. 运行基本查询验证：
       │     SELECT count(*) FROM information_schema.tables
       │     SELECT count(*) FROM [核心表]
       ├─ 5. 删除 noda_verify 数据库
       └─ 6. 报告验证结果
```

这个验证在 PostgreSQL 容器内完成，不影响生产数据库。

---

## 六、监控架构

### 日志层次

```
Level 1: 脚本输出（stdout/stderr）
    ├─ 每个步骤的开始/结束时间戳
    ├─ 文件大小和传输速度
    ├─ 错误详情和退出码
    └─ rclone 原始输出

Level 2: Jenkins 构建记录
    ├─ 构建历史（成功/失败趋势）
    ├─ 构建时长统计
    ├─ 控制台输出（可搜索）
    └─ 构建状态（蓝色/红色）

Level 3: 外部通知（Webhook）
    ├─ 备份失败 -> 立即发送告警
    ├─ 备份成功 -> 可选发送摘要
    └─ 恢复测试失败 -> 立即发送告警
```

### 通知机制

```bash
# notify-status.sh 接口
# 输入：
#   BACKUP_STATUS   - success / failure / warning
#   BACKUP_MESSAGE  - 状态描述
#   WEBHOOK_URL     - 通知目标（从 secrets 加载）

# 支持的通知方式：
# 1. Webhook（首选）- 可对接 Slack/Discord/Teams/Telegram
# 2. 邮件 - 通过 Jenkins 内置邮件插件（已有 SMTP 配置）
```

### 监控面板

**初期方案：Jenkins Dashboard**

不需要额外搭建监控面板。Jenkins 自身提供：
- 构建历史趋势图
- 构建时间线
- 控制台输出搜索
- 失败构建高亮

**未来可选升级：**
如果需要更详细的备份状态监控，可以考虑：
- 在现有 Nginx 上添加一个 `/backup-status` 端点
- 脚本在备份成功后更新一个状态 JSON 文件
- 前端读取该 JSON 显示最近备份状态

但 MVP 阶段不需要这个复杂度。

### 关键监控指标

| 指标 | 来源 | 告警条件 |
|------|------|---------|
| 备份执行状态 | Jenkins 构建状态 | 连续 2 次失败 |
| 备份文件大小 | pg_restore --list 输出 | 与前次相比偏差 >50% |
| 上传完整性 | rclone check 输出 | 校验和不匹配 |
| 恢复测试结果 | verify-backup.sh 退出码 | 验证失败 |
| 备份时长 | Jenkins 构建时长 | >30 分钟 |
| 云端文件数 | rclone ls 输出 | 少于预期（清理异常） |

---

## 七、与现有系统的集成点

### 1. Docker 网络

```
noda-network (外部网络)
    ├── noda-infra-postgres-1      ← 备份脚本通过 docker exec 访问
    ├── noda-infra-keycloak-1
    ├── noda-infra-nginx-1
    ├── noda-infra-cloudflared-1
    ├── findclass-web
    ├── findclass-api
    └── noda-jenkins               ← 备份任务在此执行

注意：备份脚本不需要新的网络连接。
    Jenkins 容器通过 docker.sock 访问 postgres 容器。
    rclone 从 Jenkins 容器直连 Backblaze B2（HTTPS 出站）。
```

备份数据流不经过 noda-network。pg_dump 在 postgres 容器内执行，结果通过 docker exec 的 stdout 管道传回 Jenkins 容器。

### 2. 环境变量集成

```yaml
# config/secrets.sops.yaml 新增字段
b2_account_id: ENC[...]           # B2 Account ID
b2_application_key: ENC[...]      # B2 受限 Standard Application Key
backup_webhook_url: ENC[...]      # 可选：通知 webhook URL
```

```bash
# .env.backup 模板（不加密，不含敏感信息）
B2_REMOTE=b2-backup
B2_BUCKET=noda-db-backup
RETENTION_DAYS=7
BACKUP_DBS="noda_prod keycloak"
PG_CONTAINER=noda-infra-postgres-1
BACKUP_TMP_DIR=/tmp
```

**凭据管理策略：**
- 敏感凭据（B2 API Key、Webhook URL）存入 `config/secrets.sops.yaml`，使用已有的 SOPS + age 加密体系
- 非敏感配置（bucket 名、保留天数）存入 `.env.backup` 模板
- Jenkins 凭据通过 Jenkins Credentials 管理，不暴露在文件系统中

### 3. SOPS 加密体系集成

项目已使用 SOPS + age 管理密钥（见 `.sops.yaml` 和 `config/secrets.sops.yaml`）。备份系统的密钥自然融入此体系：

```
config/secrets.sops.yaml       ← 现有，追加 B2 凭据
config/keys/                   ← 现有 age 密钥目录
.sops.yaml                     ← 现有 SOPS 配置
```

Jenkins 解密方式沿用 `deploy.sh` 的模式：
1. 优先通过 `sops --decrypt` 解密（需要 SOPS_AGE_KEY_FILE）
2. 回退到 `config/secrets.local.yaml`（开发环境）

### 4. Jenkins 容器挂载

需要在 `docker-compose.jenkins.yml` 中添加的挂载：

```yaml
# 新增挂载
volumes:
  - jenkins_home:/var/jenkins_home
  - /var/run/docker.sock:/var/run/docker.sock      # 已有
  - ~/.claude/team-keys:/var/jenkins_home/keys:ro   # 已有
  - ../config/backup/rclone.conf:/var/jenkins_home/.config/rclone/rclone.conf:ro  # 新增
```

rclone 配置文件放在 `config/backup/rclone.conf`，挂载到 Jenkins 容器内。该文件不包含凭据（凭据在 Jenkins Credentials 中），只包含 B2 endpoint 和 account ID。

### 5. 部署脚本集成

`deploy.sh` 可选添加 rclone 安装检查：

```bash
# 在部署基础设施服务之后，可选检查备份工具
if ! command -v rclone > /dev/null 2>&1; then
    echo -e "${YELLOW}rclone 未安装，云备份功能不可用${NC}"
    echo -e "${YELLOW}安装命令：curl https://rclone.org/install.sh | sudo bash${NC}"
fi
```

这不是必须的 -- rclone 可以独立安装，不影响核心部署流程。

---

## 八、架构模式

### Pattern 1: 宿主机编排，容器内执行

**What:** 备份编排在 Jenkins（宿主机层面）执行，pg_dump 在 PostgreSQL 容器内通过 `docker exec` 调用。

**When:** 当数据库运行在 Docker 容器中，且不需要额外 sidecar 容器时。

**Example:**

```bash
# Jenkins Pipeline 中的关键命令
# 通过 docker exec 在 postgres 容器内运行 pg_dump
# 结果通过 stdout 管道传回 Jenkins 工作空间
docker exec -i ${PG_CONTAINER} pg_dump -Fc -U postgres -d ${DB_NAME} \
    > "${WORKSPACE}/${DB_NAME}_${TIMESTAMP}.dump"
```

**Why not sidecar:** 当前已有 Jenkins 作为编排器，添加 sidecar 容器（如 pgbackrest/restic 容器）增加运维成本但无额外收益。对于小规模数据库（<1GB），`docker exec` + `pg_dump` 是最简单可靠的方案。

### Pattern 2: 分层凭据管理

**What:** 敏感凭据通过 SOPS 加密存储，运行时注入。非敏感配置通过环境变量或配置文件管理。

**When:** 项目已有 SOPS + age 加密体系时。

**Example:**

```
凭据层（加密）：
    config/secrets.sops.yaml → b2_account_id, b2_application_key
    Jenkins Credentials → 运行时注入到 Pipeline

配置层（明文）：
    .env.backup → B2_BUCKET, RETENTION_DAYS, BACKUP_DBS
    rclone.conf → B2 endpoint, account ID（不含密钥）
```

### Pattern 3: 纵向验证链

**What:** 备份系统在三个层面验证数据完整性：本地验证 -> 传输验证 -> 远程验证。

**When:** 任何涉及数据上传/传输的备份系统。

```
Layer 1 - 本地验证：
    pg_restore --list dump文件   → 确认 pg_dump 输出有效

Layer 2 - 传输验证：
    rclone copy --checksum       → 上传时校验和比对

Layer 3 - 远程验证：
    rclone check                 → 上传后二次确认云端文件完整

Layer 4 - 恢复验证（每周）：
    pg_restore 到临时数据库       → 确认备份可以成功恢复
```

---

## 九、反模式（需要避免）

### Anti-Pattern 1: 在 Docker Compose 中添加备份 sidecar 容器

**What:** 创建一个包含 pg_dump + rclone + cron 的 sidecar 容器，添加到 docker-compose.yml。

**Why bad:**
- 增加容器编排复杂度
- 需要管理容器内的 cron daemon
- 日志需要额外配置才能从容器外访问
- 项目已有 Jenkins 作为任务编排器
- 容器重启时 cron 任务可能丢失

**Instead:** 使用 Jenkins（已有基础设施）+ `docker exec` + 宿主机 rclone。

### Anti-Pattern 2: 直接在 PostgreSQL 容器内安装 rclone

**What:** 修改 PostgreSQL Dockerfile 或通过 volume 注入 rclone 二进制文件到 postgres 容器。

**Why bad:**
- 违反容器不可变原则
- PostgreSQL 容器应该只运行数据库
- 版本升级时需要重新安装 rclone
- 增加攻击面

**Instead:** rclone 运行在 Jenkins 容器或宿主机上，与 PostgreSQL 容器分离。

### Anti-Pattern 3: 使用 B2 生命周期规则管理备份保留

**What:** 配置 B2 bucket 的 Lifecycle Rules 来自动删除旧文件。

**Why bad:**
- B2 生命周期规则基于文件版本（versions），不是文件创建时间
- 适合隐藏旧版本而非删除带时间戳的独立文件
- 无法精确控制保留策略（如"保留最近7天的备份"）
- 详细分析见 PITFALLS.md Pitfall 3

**Instead:** 在 `backup-to-cloud.sh` 中使用 `rclone delete --min-age 7d` 实现应用层清理。

### Anti-Pattern 4: 备份文件使用纯文本 SQL 格式

**What:** 使用 `pg_dump`（默认纯文本）而不是 `pg_dump -Fc`。

**Why bad:**
- 无法用 `pg_restore --list` 验证完整性
- 文件更大（无压缩）
- 恢复时无法选择性恢复特定表
- 恢复速度更慢（逐行 INSERT）

**Instead:** 使用 `pg_dump -Fc` 自定义格式。详细分析见 PITFALLS.md Pitfall 2 和 7。

---

## 十、可扩展性考虑

| 关注点 | 当前（小规模） | 中等规模（数据库 >10GB） | 大规模（数据库 >100GB） |
|-------|--------------|----------------------|----------------------|
| 备份方式 | pg_dump -Fc | pg_dump -Fd -j 4（并行） | pgBackRest 或 WAL-G |
| 备份频率 | 6小时 | 2-4小时 | 持续 WAL 归档 |
| 存储成本 | 免费（<10GB） | ~$0.60/月（100GB） | ~$6/月（1TB） |
| 保留策略 | 7天 | 7天 + 4个周备份 | 分级保留（天/周/月/年） |
| 恢复时间 | <1分钟 | 2-5分钟 | 5-30分钟 |
| 验证频率 | 每周 | 每周 | 每日 |
| 监控 | Jenkins Dashboard | Prometheus + Grafana | 专业备份监控 |

### 升级路径

当数据库增长到需要升级时：

```
当前方案（pg_dump -Fc）
    ↓ 数据库 >10GB
pg_dump -Fd -j 4（并行备份）
    ↓ 需要更频繁备份 / PITR
pgBackRest（物理备份 + 增量 + PITR）
    ↓ 多节点 / 高可用
WAL-G + 流复制
```

每个升级步骤都是独立的，不需要重写之前的架构。当前架构的脚本结构（编排 -> 转储 -> 上传 -> 验证）可以复用到更复杂的方案中。

---

## 十一、安全架构

### 访问控制矩阵

| 操作 | B2 Application Key 权限 | 说明 |
|------|------------------------|------|
| 上传备份文件 | `writeFiles` | 必需 |
| 下载备份文件（恢复） | `readFiles` | 必需 |
| 列出备份文件 | `listFiles` | 必需（清理和恢复） |
| 删除旧备份 | `deleteFiles` | 必需（保留策略） |
| 创建/删除 Bucket | 不授予 | 不需要 |
| 管理 Bucket 设置 | 不授予 | 不需要 |
| 读取其他 Bucket | 不授予 | fileNamePrefix 限制 |

### Application Key 创建规范

```bash
# 创建受限 Standard Application Key（通过 B2 控制台或 CLI）
# 必须设置：
#   - 权限：readFiles, writeFiles, deleteFiles, listFiles
#   - Bucket 限制：仅 noda-db-backup
#   - fileNamePrefix：可选，进一步限制访问范围
#   - 有效期：建议设置合理的过期时间
#
# 绝对不要使用 Master Application Key
# 详见 PITFALLS.md Pitfall 4
```

### 网络安全

```
Jenkins 容器 ──HTTPS──→ Backblaze B2 API
                         (api.backblazeb2.com:443)

不需要：
  - 不需要开放入站端口
  - 不需要 VPN 或特殊网络配置
  - 不经过 Cloudflare Tunnel
  - 不经过 Nginx 代理
```

---

## 十二、构建顺序建议

基于以上架构，建议按以下顺序构建：

### Phase 1: 本地备份增强
- 改进现有备份脚本为 `backup-to-cloud.sh` 的骨架
- 实现 `docker exec pg_dump -Fc` 替代当前的纯文本格式
- 添加本地验证（`pg_restore --list`）
- **交付物：** 可靠的本地备份脚本

### Phase 2: 云存储集成
- 安装和配置 rclone
- 创建 B2 Bucket 和受限 Application Key
- 实现上传和校验和验证
- 实现旧备份清理
- 将 B2 凭据加入 SOPS 加密管理
- **交付物：** 完整的备份到云存储流程

### Phase 3: Jenkins 自动化
- 创建 Jenkinsfile.backup
- 配置定时触发器
- 配置 Jenkins Credentials
- 添加失败通知
- **交付物：** 全自动化的定时备份

### Phase 4: 恢复和验证
- 实现 `restore-from-cloud.sh`
- 实现 `verify-backup.sh`（每周自动验证）
- 编写恢复操作文档
- 执行首次完整恢复测试
- **交付物：** 可靠的恢复流程和验证机制

### Phase 5: 监控完善
- 优化通知内容（包含备份大小、时长、数据库列表）
- 添加备份状态可视化（可选）
- 添加异常检测（文件大小突变告警）
- **交付物：** 完善的监控和告警

---

## 数据源

| 来源 | 置信度 | 用途 |
|------|--------|------|
| `docker/docker-compose.yml` | HIGH（直接读取） | 基础服务定义 |
| `docker/docker-compose.simple.yml` | HIGH（直接读取） | 生产环境实际配置 |
| `docker/docker-compose.jenkins.yml` | HIGH（直接读取） | Jenkins 容器配置 |
| `docker/docker-compose.prod.yml` | HIGH（直接读取） | 生产环境覆盖配置 |
| `docker/docker-compose.app.yml` | HIGH（直接读取） | 应用服务配置 |
| `config/secrets.sops.yaml` | HIGH（直接读取） | 现有凭据结构 |
| `deploy.sh` | HIGH（直接读取） | 部署流程和凭据加载方式 |
| `.planning/research/STACK.md` | HIGH（直接读取） | 技术栈决策 |
| `.planning/research/PITFALLS.md` | HIGH（直接读取） | 陷阱和最佳实践 |
| `docs/architecture.md` | HIGH（直接读取） | 现有架构文档 |
| `backups/README.md` | HIGH（直接读取） | 现有备份说明 |
| Backblaze B2 定价页面 | HIGH（2026-04-06 抓取） | 存储定价确认 |
| Wasabi 定价页面 | HIGH（2026-04-06 抓取） | 替代方案定价 |

---

*Architecture research for: Noda PostgreSQL 云备份系统*
*Researched: 2026-04-06*
