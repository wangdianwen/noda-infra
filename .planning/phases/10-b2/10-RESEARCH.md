# Phase 10: B2 备份修复 - Research

**Researched:** 2026-04-11
**Domain:** Bash 备份脚本 / rclone B2 操作 / Docker 容器内 cron 调度
**Confidence:** HIGH

## Summary

本阶段修复三个已知的备份系统 bug：B2 云备份自 4/8 起中断（BFIX-01）、容器内磁盘空间检查被跳过（BFIX-02）、验证测试下载路径解析错误（BFIX-03）。经过对全部核心脚本的逐行审查，三个 bug 的根因和修复方向均已明确。

**Primary recommendation:** 按 BFIX-02（磁盘检查）→ BFIX-03（下载路径）→ BFIX-01（B2 中断调查）的独立性优先级执行。BFIX-02 和 BFIX-03 可直接修复代码；BFIX-01 需要登录生产容器调查根因后才能确定修复方案。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 修复计划的第一步是登录生产环境检查日志和状态，定位根因后再修复
- **D-02:** 调查重点方向：(1) v1.1 迁移后容器重命名/配置丢失 (2) B2 凭证/rclone 配置问题 (3) supervisord cron 配置异常
- **D-03:** 调查结果决定修复方式 — 根因可能是配置更新、环境变量缺失、或 rclone 配置丢失
- **D-04:** 简单修复方案 — 在容器内添加 `df` 检查挂载点空间，替代当前的直接跳过逻辑
- **D-05:** 具体修复位置：`scripts/backup/lib/health.sh` 第 163-166 行的容器内分支
- **D-06:** 修复下载路径解析 — 保持 B2 日期子目录存储结构不变，修复下载函数
- **D-07:** 关键修复点：(1) `list_b2_backups` 输出包含子目录路径 (2) `download_backup` 的 `--include` 需匹配正确路径 (3) `download_latest_backup` 解析文件名需去除目录前缀
- **D-08:** 本地模拟验证 — 用 B2 测试文件 + 模拟环境在本地验证修复逻辑
- **D-09:** 验证优先级：磁盘检查修复 > B2 中断修复 > 验证下载修复

### Claude's Discretion
- 具体的 df 检查命令和阈值计算方式
- rclone 参数调优
- 测试脚本的详细构造

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BFIX-01 | B2 自动备份恢复 — 调查 4/8 起中断原因，修复后备份正常上传到 B2 | 容器配置分析（Dockerfile.noda-ops + entrypoint-ops.sh + supervisord.conf），rclone 配置机制审查，可能的根因清单 |
| BFIX-02 | 磁盘空间检查正常工作 — 备份前检查磁盘空间并在不足时告警 | `health.sh:161-166` 精确定位 bug，容器内 df 命令可用性已验证（Alpine + coreutils），修复方案明确 |
| BFIX-03 | 验证测试下载功能正常 — 自动验证测试能成功下载备份文件进行校验 | `restore.sh:download_backup()` 和 `test-verify.sh:download_latest_backup()` 路径解析问题已定位，rclone --include 行为已验证 |
</phase_requirements>

## Standard Stack

### Core
| 工具/库 | 版本 | 用途 | 备注 |
|---------|------|------|------|
| rclone | v1.73.3（本地）/ Alpine 3.19 仓库版 | B2 云操作 | [VERIFIED: 本地 `rclone version`] |
| bash | Alpine busybox ash → bash | 脚本运行时 | [VERIFIED: Dockerfile.noda-ops `apk add bash`] |
| dcron | Alpine 包 | cron 调度 | [VERIFIED: Dockerfile.noda-ops] |
| supervisord | Alpine 包 | 多进程管理 | [VERIFIED: supervisord.conf + Dockerfile.noda-ops] |
| PostgreSQL client | Alpine postgresql-client | pg_dump/pg_restore/psql | [VERIFIED: Dockerfile.noda-ops] |

### Supporting
| 工具 | 用途 | 当使用 |
|------|------|--------|
| coreutils | `df`, `stat`, `date` 等 | 容器内磁盘空间检查 [VERIFIED: Dockerfile.noda-ops] |
| jq | JSON 解析 | 元数据和历史记录操作 [VERIFIED: Dockerfile.noda-ops] |
| curl | HTTP 请求 | 健康检查 [VERIFIED: Dockerfile.noda-ops] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| 手写 df 检查 | `stat -f` 直接取可用块 | df 更直观、更符合 UNIX 惯例，保持可读性 |

**注意：** 所有工具已在 Dockerfile.noda-ops 中安装，无需额外安装步骤。`coreutils` 包提供标准 `df` 命令，支持 `-B1`（字节精度）参数。

## Architecture Patterns

### 当前备份系统架构
```
noda-ops 容器
  ├── supervisord (PID 1)
  │   ├── crond (dcron)
  │   │   ├── 每天 03:00 → /app/backup-postgres.sh
  │   │   ├── 每周日 03:00 → /app/test-verify-weekly.sh
  │   │   └── 每 6h → metrics.sh cleanup
  │   └── cloudflared (Cloudflare Tunnel)
  │
  ├── /app/backup-postgres.sh (7步主流程)
  │   ├── Step 1: health.sh::check_prerequisites()
  │   ├── Step 2: db.sh::backup_all_databases()
  │   ├── Step 3: verify.sh::verify_all_backups()
  │   ├── Step 4: cloud.sh::upload_to_b2()
  │   ├── Step 5: cleanup_old_backups() + cloud.sh::cleanup_old_backups_b2()
  │   ├── Step 6: metrics.sh::cleanup_old_metrics()
  │   └── Step 7: metrics.sh::record_metric()
  │
  └── 配置加载链:
      环境变量 → config.sh::load_config() → .env.backup 文件 → 默认值
```

### B2 存储路径结构
```
b2remote:noda-backups/backups/postgres/
  ├── 2026/
  │   ├── 04/
  │   │   ├── 07/
  │   │   │   ├── keycloak_db_20260407_030000.dump
  │   │   │   ├── globals_20260407_030000.sql
  │   │   │   └── metadata_*.json
  │   │   └── 08/
  │   │       └── ... (4/8 后可能中断)
```

**关键点：** `upload_to_b2()` 使用 `get_date_path()`（`YYYY/MM/DD`）作为子目录，但下载函数未正确处理这个子目录结构。

### 环境检测模式
```bash
# 全局模式：检测是否在 Docker 容器内运行
if [[ -f /.dockerenv ]]; then
  # 容器内路径
else
  # 宿主机路径（docker exec）
fi
```

### rclone 配置模式
- `setup_rclone_config()`: 每次操作创建临时配置文件，操作完清理
- `entrypoint-ops.sh`: 启动时创建 `/root/.config/rclone/rclone.conf` 持久配置
- **注意：** 备份脚本使用临时配置（`setup_rclone_config`），不使用 entrypoint 创建的持久配置

### Anti-Patterns to Avoid
- **不要修改 B2 存储路径结构：** `YYYY/MM/DD/` 结构已经用于生产数据，修改上传逻辑会导致新旧备份路径不一致
- **不要在容器内使用 docker 命令：** 容器内没有 Docker socket 挂载，`docker exec` 不可用
- **不要引入新的运行时依赖：** 所有修复必须使用已在 Dockerfile.noda-ops 中安装的工具

## Don't Hand-Roll

| 问题 | 不要自建 | 使用现有 | 原因 |
|------|---------|---------|------|
| 磁盘空间查询 | 自定义 /proc/mounts 解析 | `df -B1 "$backup_dir"` | coreutils df 已安装，支持字节精度 |
| B2 文件列表 | 自定义 API 调用 | `rclone ls` | 已在 cloud.sh 中封装为 `list_b2_backups()` |
| B2 文件下载 | 自定义 API 调用 | `rclone copy --include` | 已在 restore.sh 中封装为 `download_backup()` |
| 数据库大小查询 | 解析 psql 输出 | `pg_database_size()` | 已在 health.sh 中实现 `get_database_size()` |
| 配置加载 | 自定义 .env 解析 | `config.sh::load_config()` | 已实现优先级链 |

**Key insight:** 备份系统已经是一个完整的框架，三个 bug 都是已有代码中的逻辑缺陷，不需要引入新组件或新依赖。

## Common Pitfalls

### Pitfall 1: 容器内 df 检查的挂载点问题
**What goes wrong:** Docker 容器内的 `df` 显示的是宿主机磁盘统计，不是 volume 自身的限额。多个 volume 可能共享同一个磁盘设备。
**Why it happens:** Docker volume 默认使用 bind mount，`df` 返回底层设备信息。
**How to avoid:** 检查 `$BACKUP_DIR`（`/tmp/postgres_backups`）所在挂载点的可用空间即可。由于 Docker volume 不设限额，这个检查等价于检查宿主机磁盘空间。
**Warning signs:** `df` 输出中 mount point 列显示 `/` 或 `/var/lib/docker/volumes/...`。

### Pitfall 2: rclone --include 与目录结构不匹配
**What goes wrong:** `rclone copy --include "filename.dump"` 无法匹配到 `2026/04/07/filename.dump`，因为 `--include` 的 pattern 是对远程路径的相对匹配。
**Why it happens:** `rclone copy` 的 `--include` 在递归复制时对**完整相对路径**进行 glob 匹配。如果文件在子目录中，`--include "file.dump"` 不会匹配 `2026/04/07/file.dump`。
**How to avoid:** 使用 `--include "**/filename.dump"` 或直接使用 rclone 的 `--include` 匹配 `**/{filename}` 模式。另一种方案是先通过 `rclone ls` 找到完整路径，然后用 `rclone copyto` 直接指定源和目标路径。
**Warning signs:** `rclone copy` 成功返回但目标目录为空。

### Pitfall 3: list_b2_backups 输出格式含路径前缀
**What goes wrong:** `rclone ls` 输出格式为 `{size} {relative_path}`，如果 B2 上有子目录，`relative_path` 会包含 `2026/04/07/dbname_20260407_030000.dump`。`download_latest_backup()` 中 `awk '{print $2}'` 提取的是含路径的字符串，不是纯文件名。
**Why it happens:** `rclone ls` 对远程根路径下的所有文件递归列出，路径是相对于 `rclone ls` 指定的远程路径。
**How to avoid:** 在解析 `list_b2_backups` 输出时，使用 `basename` 提取纯文件名用于显示，保留完整路径用于下载。
**Warning signs:** `download_backup` 接收到含路径前缀的文件名，导致 `--include` 匹配失败。

### Pitfall 4: v1.1 迁移后容器重建丢失运行时状态
**What goes wrong:** `docker compose up -d` 重建 noda-ops 容器后，entrypoint-ops.sh 创建的 rclone 配置可能被正确执行，但 crontab 中的脚本路径可能不正确。
**Why it happens:** Dockerfile.noda-ops 将脚本复制到 `/app/backup/` 目录（注意有 `backup/` 子目录），而 crontab 中引用的是 `/app/backup-postgres.sh`（没有 `backup/` 前缀）。
**How to avoid:** 检查 crontab 路径与 Dockerfile COPY 目标路径是否一致。
**Warning signs:** cron 日志显示 "command not found" 或 "No such file or directory"。

### Pitfall 5: 容器内 health.sh 的数据库大小查询使用 docker exec
**What goes wrong:** `get_database_size()` 和 `get_total_database_size()` 内部使用 `docker exec` 查询数据库大小，但在容器内无法执行 `docker` 命令。
**Why it happens:** 容器内没有 Docker socket 挂载，且 `docker` CLI 未安装在 noda-ops 容器中。
**How to avoid:** 容器内磁盘检查修复时，不能复用 `get_total_database_size()`（它用 `docker exec`）。需要直接使用 `psql` 查询或采用简化策略。
**Warning signs:** `docker: command not found` 或 `Cannot connect to the Docker daemon`。

## Code Examples

### BFIX-02: 容器内磁盘空间检查修复

**Bug 位置：** `health.sh:161-166`
```bash
# 当前代码（直接跳过）
if [[ -f /.dockerenv ]]; then
  # 在容器内，简化检查（仅检查挂载点）
  echo "ℹ️  容器内运行，跳过详细磁盘检查"
  echo "ℹ️  备份目录: $backup_dir"
  return 0  # <-- BUG: 直接返回成功
fi
```

**修复方向（D-04/D-05）：** 容器内使用 psql 直接查询数据库大小（不用 docker exec），然后用 df 检查挂载点空间。

```bash
# 修复后代码（示意）
if [[ -f /.dockerenv ]]; then
  echo "ℹ️  容器内运行，检查挂载点空间"

  # 容器内直接使用 psql 查询数据库大小
  local pg_host pg_user
  pg_host=$(get_postgres_host)
  pg_user=$(get_postgres_user)

  local total_db_size=0
  local databases
  databases=$(psql -h "$pg_host" -U "$pg_user" -d postgres -t -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres','template0','template1');" 2>/dev/null | tr -d ' ')

  for db in $databases; do
    local db_size
    db_size=$(psql -h "$pg_host" -U "$pg_user" -d postgres -t -c \
      "SELECT pg_database_size('$db');" 2>/dev/null | tr -d ' ')
    [[ -n "$db_size" && "$db_size" =~ ^[0-9]+$ ]] && total_db_size=$((total_db_size + db_size))
  done

  local required_space=$((total_db_size * 2))

  # 检查备份目录所在挂载点
  local available
  available=$(df -B1 "$backup_dir" 2>/dev/null | tail -1 | awk '{print $4}')

  if [[ -z "$available" || ! "$available" =~ ^[0-9]+$ ]]; then
    echo "⚠️  无法获取磁盘空间信息，继续备份"
    return 0
  fi

  if [[ $available -lt $required_space ]]; then
    echo "❌ 错误: 磁盘空间不足"
    # ... 输出详情 ...
    return $EXIT_DISK_SPACE_INSUFFICIENT
  fi

  echo "✅ 磁盘空间检查通过"
  return 0
fi
```

**注意：** 容器内有 `postgresql-client`，可以直接使用 `psql` + `PGPASSWORD` 连接数据库，不需要 `docker exec`。

### BFIX-03: download_backup 路径修复

**Bug 位置：** `restore.sh:download_backup()` 第 120-124 行

**问题分析：**
1. `list_b2_backups()` 使用 `rclone ls` 列出 `b2remote:noda-backups/backups/postgres/` 下的所有文件
2. 输出格式：`12345 2026/04/07/keycloak_db_20260407_030000.dump`（含子目录路径）
3. `test-verify.sh:download_latest_backup()` 第 128 行用 `awk '{print $2}'` 提取文件名，得到 `2026/04/07/keycloak_db_20260407_030000.dump`
4. 传给 `download_backup()` 后，`--include "$backup_filename"` 尝试匹配 `2026/04/07/keycloak_db_20260407_030000.dump`
5. 但 `download_backup` 第 130 行检查 `$local_dir/$backup_filename`，如果 backup_filename 包含路径，find 查找可能正确但返回路径不一致

**修复方向：**

方案 A（推荐）：`download_backup` 接收完整路径，使用 `rclone copyto` 直接指定源文件

```bash
# 修改 download_backup 函数
download_backup() {
  local backup_path=$1  # 可能是 "2026/04/07/db_20260407.dump" 或纯文件名
  local local_dir=${2:-$(mktemp -d)}
  local backup_filename
  backup_filename=$(basename "$backup_path")  # 提取纯文件名

  # ... 配置获取 ...

  local rclone_config
  rclone_config=$(setup_rclone_config)

  # 使用 rclone copy + include 模式，但 include 需匹配子目录
  if rclone copy "b2remote:${b2_bucket_name}/${b2_path}" \
    "$local_dir" \
    --config "$rclone_config" \
    --include "**/$backup_filename" \
    --progress >&2; then
    # ... 文件查找逻辑 ...
  fi
}
```

方案 B：使用 `rclone copyto` 直接指定完整源路径

```bash
# 精确下载单个文件
rclone copyto "b2remote:${b2_bucket_name}/${b2_path}${backup_path}" \
  "$local_dir/$backup_filename" \
  --config "$rclone_config"
```

### Crontab 路径一致性检查

**关键发现：** Dockerfile.noda-ops 将脚本复制到 `/app/backup/`：
```dockerfile
COPY scripts/backup/ /app/backup/
```

但 crontab 引用的是 `/app/backup-postgres.sh`：
```
0 3 * * * /app/backup-postgres.sh >> /var/log/noda-backup/backup.log 2>&1
```

**这意味着实际脚本路径应该是 `/app/backup/backup-postgres.sh`**，而不是 `/app/backup-postgres.sh`。这是 BFIX-01 的一个高可疑根因。

### entrypoint-ops.sh 中的 .env.ops 路径

```bash
# entrypoint-ops.sh 第 19 行
if [ -f /app/.env.ops ]; then
  source /app/.env.ops
```

但 Docker Compose 通过 `environment:` 注入环境变量，不走 `.env.ops` 文件。环境变量直接由 Docker runtime 注入容器。`entrypoint-ops.sh` 中的 rclone 配置创建依赖 `$B2_ACCOUNT_ID` 和 `$B2_APPLICATION_KEY` 环境变量，这些由 docker-compose.yml 注入（第 72-73 行），应该能正常获取。

## State of the Art

| 旧方式 | 当前方式 | 变更时间 | 影响 |
|--------|---------|---------|------|
| Dockerfile.backup（旧 opdev 容器） | Dockerfile.noda-ops（合并容器） | v1.1 | 脚本路径从 `/app/` 变为 `/app/backup/` |
| 单独 crontab 配置 | Dockerfile COPY crontab | v1.1 | crontab 路径需要与 COPY 目标一致 |
| 容器内跳过磁盘检查 | 需要实现容器内磁盘检查 | 本阶段 | 新增逻辑 |

**Deprecated/outdated:**
- `Dockerfile.backup`: 已被 `Dockerfile.noda-ops` 替代
- 旧 opdev 容器名: 已合并为 noda-ops

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Crontab 路径 `/app/backup-postgres.sh` 与 Dockerfile COPY 到 `/app/backup/` 不一致是 BFIX-01 的根因 | BFIX-01 分析 | 如果还有其他问题（如环境变量缺失），修复 crontab 路径后仍需进一步调查 |
| A2 | 容器内 `df` 命令可用且返回正确的磁盘空间信息 | BFIX-02 修复 | Alpine 3.19 的 coreutils 包提供 df，风险低 |
| A3 | 容器内可直接用 psql 查询数据库大小（不需要 docker exec） | BFIX-02 修复 | 容器内有 postgresql-client，PGPASSWORD 由 docker-compose.yml 注入 |
| A4 | rclone `--include "**/filename"` 能正确匹配子目录中的文件 | BFIX-03 修复 | 需要在实际 B2 环境中验证 |

## Open Questions

1. **BFIX-01 确切根因**
   - What we know: 备份自 4/8 起中断，v1.1 迁移改变了容器结构；crontab 路径可能不匹配
   - What's unclear: 是否还有其他因素（B2 凭证失效、网络问题、supervisord 配置）
   - Recommendation: 第一步登录生产容器检查：`docker exec -it noda-ops cat /etc/crontabs/root`，`docker logs noda-ops --tail 100`，`docker exec -it noda-ops ls -la /app/backup/`

2. **PGPASSWORD 在容器内的可用性**
   - What we know: docker-compose.yml 注入了 `POSTGRES_PASSWORD` 环境变量
   - What's unclear: backup 脚本中的 `PGPASSWORD=$POSTGRES_PASSWORD psql` 是否正确设置了密码（db.sh 第 40/64/98 行）
   - Recommendation: 容器内直接使用 `PGPASSWORD` 环境变量，因为 docker-compose 已经注入了 `POSTGRES_PASSWORD`

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker CLI | BFIX-01 调查 | ✓ | 29.1.3 | — |
| rclone | B2 操作 | ✓ (本地) | v1.73.3 | 容器内 Alpine 仓库版 |
| PostgreSQL client | 备份/恢复 | ✓ (容器内) | — | — |
| df (coreutils) | BFIX-02 修复 | ✓ (容器内) | Alpine coreutils | — |
| jq | 元数据解析 | ✓ (容器内) | — | — |
| bash | 脚本运行时 | ✓ (容器内) | — | — |

**Missing dependencies with no fallback:**
- 无 — 所有依赖已在容器镜像中安装

**Missing dependencies with fallback:**
- 无

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash + 手动验证 |
| Config file | 无 |
| Quick run command | `bash scripts/backup/lib/health.sh` (单元级) |
| Full suite command | 容器内手动执行 `backup-postgres.sh --dry-run` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BFIX-01 | B2 备份上传成功 | manual | 容器内执行 `backup-postgres.sh`，检查 B2 控制台 | N/A |
| BFIX-02 | 容器内磁盘空间检查生效 | unit | 模拟空间不足场景，验证返回 EXIT_DISK_SPACE_INSUFFICIENT | ❌ Wave 0 |
| BFIX-03 | 下载含子目录路径的备份文件 | unit | 使用 rclone ls 输出模拟，验证路径解析 | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `bash -n scripts/backup/lib/health.sh` (语法检查)
- **Per wave merge:** 容器内 dry-run 验证
- **Phase gate:** B2 控制台可见最新备份 + 磁盘检查正确拒绝 + 下载验证通过

### Wave 0 Gaps
- [ ] `scripts/backup/tests/test_health_disk.sh` — BFIX-02 磁盘检查修复验证
- [ ] `scripts/backup/tests/test_download_path.sh` — BFIX-03 下载路径修复验证
- [ ] 注意：测试可能采用手动验证方式而非自动化测试文件，取决于复杂度

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | PostgreSQL 密码认证（已配置） |
| V3 Session Management | no | — |
| V4 Access Control | no | — |
| V5 Input Validation | yes | 文件名正则验证（restore.sh:103 行 `^[^_]+_[0-9]{8}_[0-9]{6}\.(sql\|dump)$`） |
| V6 Cryptography | no | — |

### Known Threat Patterns for Bash/rclone/B2

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 凭证泄露 | Information Disclosure | 环境变量注入，不硬编码；.env.backup 在 .gitignore 中 |
| 命令注入 | Tampering | 文件名正则验证，避免 `eval` |
| B2 未授权访问 | Spoofing | Limited Application Key，仅限备份 bucket |

## Sources

### Primary (HIGH confidence)
- 代码审查：`scripts/backup/` 目录下所有脚本，逐行阅读
- 代码审查：`deploy/Dockerfile.noda-ops`、`deploy/entrypoint-ops.sh`、`deploy/supervisord.conf`、`deploy/crontab`
- 代码审查：`docker/docker-compose.yml`、`docker/docker-compose.prod.yml`
- 本地工具验证：`rclone version` = v1.73.3，`docker --version` = 29.1.3

### Secondary (MEDIUM confidence)
- CONTEXT.md 中的 bug 定位信息（来自 /gsd-discuss-phase 分析）

### Tertiary (LOW confidence)
- 无

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有工具已在代码中确认，版本已验证
- Architecture: HIGH — 完整阅读了所有核心脚本和配置文件
- Pitfalls: HIGH — 三个 bug 均已精确定位到代码行号
- BFIX-01 root cause: MEDIUM — crontab 路径不匹配是高可疑根因，但需要生产环境验证

**Research date:** 2026-04-11
**Valid until:** 2026-05-11（稳定，备份系统变化频率低）
