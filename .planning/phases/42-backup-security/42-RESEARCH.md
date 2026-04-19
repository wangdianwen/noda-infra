# Phase 42: 备份与安全 - Research

**Researched:** 2026-04-19
**Domain:** Doppler 密钥自动化备份 + Git 历史敏感文件清理
**Confidence:** HIGH

## Summary

Phase 42 需要完成两件事：(1) 将已有的 backup-doppler-secrets.sh 脚本集成到 noda-ops 容器的 cron 调度中，实现每天自动备份 Doppler 密钥到 B2；(2) 使用 git-filter-repo（已安装在本地，替代需要 Java 的 BFG）清除 Git 历史中的 .env.production、.sops.yaml、config/secrets.sops.yaml 三个敏感文件。

**主要发现：** backup-doppler-secrets.sh 使用 `b2` CLI 上传，但 noda-ops 容器只安装了 `rclone`。脚本需要改用 rclone 上传（复用 cloud.sh 的 setup_rclone_config 模式），或者在 Dockerfile 中额外安装 b2 CLI。推荐改用 rclone，保持容器工具链一致。另外，git-filter-repo 2.47.0 已通过 brew 安装在本地，是 BFG 的现代替代品，Google/Git 官方推荐，且不需要 Java 运行时。

**Primary recommendation:** 备份脚本适配 rclone 上传 + Dockerfile 添加 doppler/age + cron 调度；Git 历史清理用 git-filter-repo（已安装，无需 Java）。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 每天运行一次 Doppler 密钥备份
- **D-02:** 在 noda-ops 容器的 entrypoint-ops.sh 中融入密钥备份 cron，与现有数据库备份一起调度
- **D-03:** DOPPLER_TOKEN 通过 docker-compose.yml 环境变量注入 noda-ops 容器
- **D-04:** 清理所有敏感文件：.env.production（3 次提交）+ .sops.yaml + config/secrets.sops.yaml
- **D-05:** 使用脚本自动化执行 BFG 清理 + force push
- **D-06:** BFG 执行后自动验证：检查 git log 中目标文件不再出现，生成验证报告
- **D-07:** docker/.env 从未被 git 追踪，不需要 BFG 清理

### Claude's Discretion
- backup-doppler-secrets.sh 是否需要修改以适应 noda-ops 容器环境（路径、依赖）
- noda-ops Dockerfile 是否需要安装 doppler CLI
- BFG 脚本的具体命令和参数
- cron 表达式的具体时间（避免和数据库备份冲突）

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BACKUP-01 | 创建定期 cron 任务，将 Doppler 密钥快照导出到 Backblaze B2 | backup-doppler-secrets.sh 已存在完整流程，需：(1) 适配 rclone 上传，(2) Dockerfile 安装 doppler+age，(3) crontab 添加调度，(4) docker-compose.yml 注入 DOPPLER_TOKEN |
| BACKUP-02 | Git 历史清理 docker/.env 中泄露的真实密钥（BFG Repo Cleaner） | 改用 git-filter-repo 2.47.0（已安装），清理 .env.production + .sops.yaml + config/secrets.sops.yaml，脚本自动化 + 验证 |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Doppler 密钥下载 + age 加密 | noda-ops 容器 | — | doppler CLI + age 在容器内执行，下载密钥后加密 |
| B2 加密快照上传 | noda-ops 容器 | — | 复用容器已有的 rclone B2 上传能力 |
| Cron 定时调度 | noda-ops 容器 (dcron) | — | 容器已有 supervisord + dcron 调度数据库备份 |
| Git 历史清理 | 开发者本地机器 | — | 一次性操作，在本地执行 git-filter-repo + force push |

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| doppler CLI | v3.75.3 | 从 Doppler 下载密钥 | 项目已选定的密钥管理工具 [VERIFIED: `doppler --version`] |
| age | v1.3.1 | 加密密钥快照 | 轻量级加密，已在 backup-doppler-secrets.sh 中使用 [VERIFIED: `age --version`] |
| rclone | (Alpine apk) | B2 云存储上传 | noda-ops 容器已有 rclone，数据库备份已用 [VERIFIED: Dockerfile.noda-ops line 17] |
| git-filter-repo | 2.47.0 | Git 历史重写（替代 BFG） | Google/Git 官方推荐替代 git-filter-branch 和 BFG [VERIFIED: `brew info git-filter-repo`] |
| dcron | (Alpine apk) | Cron 定时任务 | noda-ops 容器已有，管理数据库备份 cron [VERIFIED: Dockerfile.noda-ops] |
| supervisord | (Alpine apk) | 进程管理 | noda-ops 容器已有，管理 cron + cloudflared [VERIFIED: supervisord.conf] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| git-filter-repo | BFG Repo Cleaner | BFG 需要 Java 运行时（本地未安装 Java），git-filter-repo 已安装且是官方推荐替代 [VERIFIED: `java -version` failed, `git filter-repo --help` works] |
| rclone 上传 | b2 CLI 上传 | b2 CLI 未安装在容器中，需要额外安装；rclone 已有且 B2 配置已就绪 [VERIFIED: Dockerfile.noda-ops 无 b2] |
| Alpine apk 安装 doppler | curl 下载二进制 | apk 是 Alpine 标准方式，自动更新更方便 [CITED: Doppler INSTALL.md] |

### Installation
```bash
# Dockerfile.noda-ops 中添加（Alpine apk 安装 doppler + age）
RUN apk add --no-cache age && \
    wget -q -t3 'https://packages.doppler.com/public/cli/rsa.8004D9FF50437357.key' -O /etc/apk/keys/cli@doppler-8004D9FF50437357.rsa.pub && \
    echo 'https://packages.doppler.com/public/cli/alpine/any-version/main' | tee -a /etc/apk/repositories && \
    apk add doppler

# git-filter-repo 已安装（本地一次性使用）
# brew install git-filter-repo  # 已安装 v2.47.0
```

## Architecture Patterns

### System Architecture Diagram: 密钥备份流程

```
Doppler Cloud API
       |
       | doppler secrets download --format=env --no-file
       v
  [noda-ops 容器]
       |
       | age -r $AGE_PUBLIC_KEY (管道加密，明文不落盘)
       v
  /tmp/doppler-backup-{timestamp}.env.age
       |
       | rclone copy → B2 bucket
       v
  Backblaze B2: noda-backups/doppler-backup/
       |
       | (删除本地临时文件)
       v
  [完成]

调度: dcron (每天凌晨 3:30，避开数据库备份 3:00)
触发: /etc/crontabs/nodaops
```

### System Architecture Diagram: Git 历史清理流程

```
[本地 git repo]
       |
       | 1. git filter-repo --analyze (生成分析报告)
       v
  [分析报告: 受影响的 commit 列表]
       |
       | 2. 用户确认清理范围
       v
  [git filter-repo 执行]
       | --path .env.production --path .sops.yaml --path config/secrets.sops.yaml --invert-paths
       | --force (覆盖 fresh-clone 检查)
       v
  [历史重写完成]
       |
       | 3. 验证: git log --all -- <files> 应无输出
       v
  [验证通过]
       |
       | 4. git push --force --mirror origin
       v
  [GitHub 远端已更新]
```

### Recommended Project Structure
```
scripts/
├── backup/
│   ├── backup-doppler-secrets.sh    # [修改] 适配 rclone 上传
│   └── lib/
│       └── cloud.sh                 # [复用] setup_rclone_config 模式
deploy/
├── Dockerfile.noda-ops              # [修改] 添加 doppler + age
├── crontab                          # [修改] 添加密钥备份 cron
├── entrypoint-ops.sh                # [修改] 添加 doppler 环境验证
└── supervisord.conf                 # [不变]
docker/
├── docker-compose.yml               # [修改] noda-ops 添加 DOPPLER_TOKEN
scripts/
└── utils/
    └── bfg-clean-history.sh         # [新增] git-filter-repo 自动化清理脚本
```

### Pattern 1: rclone 上传复用
**What:** backup-doppler-secrets.sh 改用 rclone 上传加密文件到 B2，复用 cloud.sh 的 setup_rclone_config 模式
**When to use:** 任何需要上传文件到 B2 的场景
**Example:**
```bash
# Source: scripts/backup/lib/cloud.sh setup_rclone_config 模式
# 创建临时 rclone 配置
rclone_config=$(mktemp)
chmod 600 "$rclone_config"
cat >"$rclone_config" <<EOF
[b2remote]
type = b2
account = $B2_ACCOUNT_ID
key = $B2_APPLICATION_KEY
EOF

# 上传加密文件
rclone copy "$encrypted_file" "b2remote:noda-backups/doppler-backup/" \
    --config "$rclone_config" \
    --log-level INFO

# 清理配置
rm -f "$rclone_config"
```

### Pattern 2: git-filter-repo 删除指定路径
**What:** 从 Git 历史中彻底删除指定文件，替代 BFG 的 --delete-files
**When to use:** 需要从 Git 历史中移除敏感文件
**Example:**
```bash
# Source: Context7 /newren/git-filter-repo docs
# 删除三个敏感文件（--invert-paths 表示排除这些路径）
git filter-repo \
    --path .env.production \
    --path .sops.yaml \
    --path config/secrets.sops.yaml \
    --invert-paths \
    --force

# 验证：应无输出
git log --all -- .env.production .sops.yaml config/secrets.sops.yaml
```

### Anti-Patterns to Avoid
- **在 noda-ops Dockerfile 中安装 b2 CLI：** 容器已有 rclone，添加 b2 造成工具冗余。改用 rclone 统一 B2 访问。
- **使用 BFG（需要 Java）：** 本地未安装 Java，git-filter-repo 已安装且是官方推荐替代。`[VERIFIED: java -version failed]`
- **在 entrypoint-ops.sh 中硬编码 AGE_PUBLIC_KEY：** 应作为环境变量通过 docker-compose.yml 注入，与现有 B2 凭据注入模式一致。
- **BFG/git-filter-repo 在非 fresh clone 上不使用 --force：** git-filter-repo 默认要求 fresh clone，当前是完整工作仓库，必须加 --force。

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| B2 文件上传 | 自定义 curl 调用 B2 API | rclone（已有） | B2 API 签名复杂，rclone 已在容器中配置好 |
| Git 历史重写 | 自定义 git filter-branch 脚本 | git-filter-repo | filter-branch 已废弃，git-filter-repo 是官方推荐替代，速度快 10-720x |
| 密钥加密 | 自定义 AES 脚本 | age（已有模式） | age 简单安全，backup-doppler-secrets.sh 已使用 |
| rclone 配置管理 | 每次手动写配置文件 | cloud.sh setup_rclone_config | 已有标准函数，自动创建/清理临时配置 |

**Key insight:** 复用已有基础设施（rclone、dcron、supervisord）是本 Phase 的核心原则，避免引入新依赖。

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | 无 — 备份脚本输出到 /tmp（容器 tmpfs），上传后清理 | 无 |
| Live service config | noda-ops 容器 supervisord.conf + crontab（在 git 中管理） | 代码编辑：添加 cron 行 |
| OS-registered state | 无 — cron 在容器内，通过 Dockerfile COPY 注入 | 重建容器即生效 |
| Secrets/env vars | DOPPLER_TOKEN 需通过 docker-compose.yml 注入 | 代码编辑：添加环境变量 |
| Build artifacts | noda-ops:latest Docker 镜像需重建 | 部署脚本执行 `docker compose build noda-ops` |
| Git remote state | GitHub 上 git history 仍包含敏感文件 | git push --force --mirror 更新远端 |

## Common Pitfalls

### Pitfall 1: backup-doppler-secrets.sh 使用 b2 CLI 而非 rclone
**What goes wrong:** 脚本调用 `b2 upload-file`，但容器中只有 rclone，没有 b2 CLI
**Why it happens:** 脚本最初在开发机（有 brew install b2）上编写和测试
**How to avoid:** 修改脚本的 B2 上传逻辑，改用 rclone copy（复用 cloud.sh 模式）
**Warning signs:** cron 日志中 `command not found: b2` 错误

### Pitfall 2: DOPPLER_TOKEN 环境变量未注入容器
**What goes wrong:** backup-doppler-secrets.sh 因 DOPPLER_TOKEN 为空而退出
**Why it happens:** docker-compose.yml 未添加 DOPPLER_TOKEN 环境变量
**How to avoid:** 在 docker-compose.yml noda-ops 服务的 environment 中添加 `DOPPLER_TOKEN: ${DOPPLER_TOKEN}`
**Warning signs:** cron 日志中 `DOPPLER_TOKEN 环境变量未设置` 错误

### Pitfall 3: git-filter-repo 在非 fresh clone 上拒绝执行
**What goes wrong:** git-filter-repo 默认要求 fresh clone（--mirror），在普通工作仓库上会报错
**Why it happens:** git-filter-repo 的安全机制，防止意外重写
**How to avoid:** 添加 `--force` 参数覆盖检查
**Warning signs:** "fatal: 'origin' remote has not been deleted" 或 "Expected a fresh clone"

### Pitfall 4: Doppler config 名不匹配
**What goes wrong:** 脚本默认 `--config prd`，如果 Doppler 项目配置不同会失败
**Why it happens:** Doppler 配置名是 `prd`（非 `prod`），这是前序 Phase 确认过的
**How to avoid:** 确认 cron 命令中使用 `--config prd`
**Warning signs:** "unable to find config prd for project noda"

### Pitfall 5: git push --force 后协作者不同步
**What goes wrong:** 其他协作者的本地仓库与远端冲突
**Why it happens:** force push 重写了所有 commit hash
**How to avoid:** 项目是单人维护（wangdianwen），不涉及协作者同步问题。但仍需在脚本中提醒
**Warning signs:** 其他机器上的 git pull 出现 "fatal: refusing to merge unrelated histories"

### Pitfall 6: cron 时间与数据库备份冲突
**What goes wrong:** 密钥备份和数据库备份同时执行，可能争抢 B2 带宽
**Why it happens:** 两者都上传到 B2，同时执行可能触发 B2 速率限制
**How to avoid:** 错开时间：数据库备份 3:00，密钥备份 3:30（30 分钟间隔足够）
**Warning signs:** rclone 上传超时或 B2 429 错误

## Code Examples

### 示例 1: Dockerfile.noda-ops 添加 doppler + age
```dockerfile
# 来源: Context7 /dopplerhq/cli INSTALL.md
# 在现有 RUN apk add 之后添加
RUN apk add --no-cache age && \
    wget -q -t3 'https://packages.doppler.com/public/cli/rsa.8004D9FF50437357.key' -O /etc/apk/keys/cli@doppler-8004D9FF50437357.rsa.pub && \
    echo 'https://packages.doppler.com/public/cli/alpine/any-version/main' | tee -a /etc/apk/repositories && \
    apk add doppler
```

### 示例 2: crontab 添加密钥备份行
```crontab
# 每天凌晨 3:30 执行 Doppler 密钥备份（错开数据库备份 3:00）
30 3 * * * /app/backup/backup-doppler-secrets.sh --project noda --config prd >> /var/log/noda-backup/doppler-backup.log 2>&1
```

### 示例 3: docker-compose.yml noda-ops 添加 DOPPLER_TOKEN
```yaml
noda-ops:
  environment:
    # ... 现有环境变量 ...
    # Doppler 密钥备份配置
    DOPPLER_TOKEN: ${DOPPLER_TOKEN}
    AGE_PUBLIC_KEY: ${AGE_PUBLIC_KEY:-age1869smm93r878hzgarhv5uggkg58mttaz54l05wwc0s3zmp264e7qw7rc3w}
```

### 示例 4: backup-doppler-secrets.sh 改用 rclone 上传
```bash
# 替换原 b2 upload-file 逻辑
# 来源: scripts/backup/lib/cloud.sh setup_rclone_config 模式
rclone_config=$(mktemp)
chmod 600 "$rclone_config"
cat >"$rclone_config" <<EOF
[b2remote]
type = b2
account = $B2_ACCOUNT_ID
key = $B2_APPLICATION_KEY
EOF

if rclone copy "$OUTPUT_FILE" "b2remote:$B2_BUCKET/doppler-backup/" \
    --config "$rclone_config" \
    --log-level INFO; then
    info "上传成功"
else
    error "rclone 上传失败"
    rm -f "$rclone_config"
    exit 1
fi
rm -f "$rclone_config"
```

### 示例 5: git-filter-repo 清理脚本自动化
```bash
#!/usr/bin/env bash
# Git 历史敏感文件清理脚本（替代 BFG）
set -euo pipefail

TARGET_FILES=(
    ".env.production"
    ".sops.yaml"
    "config/secrets.sops.yaml"
)

echo "=== Git 历史敏感文件清理 ==="
echo "将清除以下文件的完整历史:"
for f in "${TARGET_FILES[@]}"; do
    count=$(git log --all --oneline -- "$f" | wc -l | tr -d ' ')
    echo "  - $f ($count 次提交)"
done
echo ""
read -p "确认继续？(yes/no): " confirm
[[ "$confirm" != "yes" ]] && echo "已取消" && exit 0

# 执行清理
git filter-repo \
    --path .env.production \
    --path .sops.yaml \
    --path config/secrets.sops.yaml \
    --invert-paths \
    --force

# 验证
echo ""
echo "=== 验证结果 ==="
all_clean=true
for f in "${TARGET_FILES[@]}"; do
    result=$(git log --all --oneline -- "$f" 2>/dev/null || true)
    if [[ -z "$result" ]]; then
        echo "  [OK] $f 已从历史中清除"
    else
        echo "  [FAIL] $f 仍存在于历史中:"
        echo "$result"
        all_clean=false
    fi
done

if [[ "$all_clean" == true ]]; then
    echo ""
    echo "验证通过！现在可以执行:"
    echo "  git push --force --mirror origin"
else
    echo ""
    echo "验证失败，请检查"
    exit 1
fi
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| BFG Repo Cleaner | git-filter-repo | 2020+ | Google/Git 官方推荐，Python 编写无需 Java，功能更全面 |
| git filter-branch | git-filter-repo | Git 2.24+ | filter-branch 已废弃，速度慢且易出错 |
| b2 CLI 上传 | rclone 上传 | 项目标准 | 统一 B2 访问方式，rclone 支持更多后端 |

**Deprecated/outdated:**
- BFG Repo Cleaner: 维护模式，社区推荐迁移到 git-filter-repo [CITED: GitHub rtyley/bfg-repo-cleaner README]
- git filter-branch: Git 官方已标记废弃 [VERIFIED: git filter-repo docs]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Doppler CLI apk 仓库在 Alpine 3.21 上可用 | Standard Stack | 需要改用 curl 下载二进制 |
| A2 | AGE_PUBLIC_KEY 可通过环境变量注入（当前硬编码在脚本中） | Architecture | 需要修改脚本读取环境变量 |
| A3 | 30 分钟间隔足够数据库备份完成（3:00-3:30） | Common Pitfalls | 密钥备份可能在上传时与数据库备份争带宽 |
| A4 | 项目仅有一个协作者（wangdianwen），force push 不会影响他人 | Common Pitfalls | 如果有其他协作者，需要通知他们 |
| A5 | .sops.yaml 和 config/secrets.sops.yaml 只出现在 2 个 commit 中（1a5d161 + ad220f6） | Code Examples | 如果出现在更多 commit，git-filter-repo 仍能处理 |

**注意：** 以上假设均为 LOW 风险，均可在实现时轻松验证。

## Open Questions

1. **AGE_PUBLIC_KEY 注入方式**
   - What we know: 当前硬编码在 backup-doppler-secrets.sh 第 66 行
   - What's unclear: 是否应改为环境变量注入（通过 docker-compose.yml），还是保持硬编码
   - Recommendation: 保持硬编码（公钥可安全公开），减少配置复杂度。脚本已有 `${AGE_PUBLIC_KEY:-默认值}` 回退机制。

2. **backup-doppler-secrets.sh 是修改还是包装**
   - What we know: 脚本有完整的参数解析、依赖检查、日志输出
   - What's unclear: 是否需要创建一个简化版本专门用于容器内 cron 执行
   - Recommendation: 直接修改现有脚本的 B2 上传部分（b2 -> rclone），保持脚本的其他功能不变。cron 调用时传入必要参数。

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| git-filter-repo | BACKUP-02 Git 历史清理 | ✓ | 2.47.0 | — |
| Java (JRE/JDK) | BFG Repo Cleaner | ✗ | — | 使用 git-filter-repo 替代 |
| doppler CLI (本地) | 测试密钥备份 | ✓ | v3.73.5 | — |
| age (本地) | 测试密钥加密 | ✓ | v1.3.1 | — |
| rclone (容器) | B2 上传 | ✓ | Alpine apk | — |
| dcron (容器) | Cron 调度 | ✓ | Alpine apk | — |
| git (本地) | 历史清理 | ✓ | — | — |

**Missing dependencies with no fallback:**
- 无 — 所有必需工具均已可用或已有替代方案

**Missing dependencies with fallback:**
- Java/BFG: 使用已安装的 git-filter-repo 替代

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell 脚本测试（bash） |
| Config file | 无（测试通过脚本直接执行验证） |
| Quick run command | `bash scripts/backup/backup-doppler-secrets.sh --dry-run` |
| Full suite command | 手动验证（见下方测试映射） |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BACKUP-01 | 密钥备份脚本在容器内可执行 | smoke | `docker exec noda-ops /app/backup/backup-doppler-secrets.sh --dry-run` | 需部署后验证 |
| BACKUP-01 | cron 定时任务正确配置 | manual-only | `docker exec noda-ops crontab -l \| grep doppler` | 需部署后验证 |
| BACKUP-01 | 加密文件成功上传 B2 | integration | `docker exec noda-ops /app/backup/backup-doppler-secrets.sh` | 需部署后验证 |
| BACKUP-02 | 敏感文件从 git 历史中移除 | unit | `git log --all -- .env.production .sops.yaml config/secrets.sops.yaml` | Wave 0 创建清理脚本 |
| BACKUP-02 | force push 成功更新远端 | manual-only | `git push --force --mirror origin` | 需手动确认 |

### Sampling Rate
- **Per task commit:** `bash scripts/backup/backup-doppler-secrets.sh --dry-run`（仅本地测试脚本逻辑）
- **Per wave merge:** 手动验证各项配置
- **Phase gate:** 全部验证通过（B2 上传成功 + git 历史清理完成）

### Wave 0 Gaps
- [ ] `scripts/utils/bfg-clean-history.sh` — Git 历史清理自动化脚本（BACKUP-02）
- [ ] 无框架安装需求 — Shell 脚本测试无需额外框架

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Doppler Service Token 认证（通过 DOPPLER_TOKEN 环境变量） |
| V3 Session Management | no | 无会话管理 |
| V4 Access Control | yes | Doppler Service Token 限定为 prd 环境 read-only 权限 |
| V5 Input Validation | yes | 脚本参数验证（--project, --config） |
| V6 Cryptography | yes | age 公钥加密（X25519 + ChaCha20-Poly1305），明文不落盘 |
| V8 Data Protection | yes | Git 历史中的敏感数据永久清除 |

### Known Threat Patterns for Git History Cleanup

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 敏感数据残留 | Information Disclosure | git-filter-repo 彻底重写历史 + force push |
| VERCEL_OIDC_TOKEN 泄露 | Information Disclosure | token 已过期（exp: 2026-04-01），但仍需清理 |
| SOPS 加密密钥文件泄露 | Information Disclosure | config/secrets.sops.yaml 含加密密钥，BFG 清理确保完全移除 |

### 密钥安全性评估

| 密钥 | 风险等级 | 说明 |
|------|---------|------|
| VERCEL_OIDC_TOKEN | LOW | JWT 已过期（exp: 1775207817 ≈ 2026-04-01），但仍应清理 |
| postgres_password_change_me | NONE | 占位符密码，不是真实密钥 |
| admin_password_change_me | NONE | 占位符密码，不是真实密钥 |
| SOPS 加密的 Google OAuth 密钥 | MEDIUM | 虽然 SOPS 加密，但 age 私钥可能在其他地方泄露 |
| Cloudflare Tunnel Token (SOPS) | MEDIUM | 已在 Doppler 中轮换 |

## Sources

### Primary (HIGH confidence)
- Context7 /dopplerhq/cli — Doppler CLI 安装（Alpine apk 方式）和 secrets download 命令
- Context7 /newren/git-filter-repo — path 过滤、--invert-paths、--force、验证模式
- 项目代码: `scripts/backup/backup-doppler-secrets.sh` — 完整备份流程
- 项目代码: `deploy/Dockerfile.noda-ops` — 当前容器工具链
- 项目代码: `deploy/crontab` — 现有 cron 配置
- 项目代码: `scripts/backup/lib/cloud.sh` — rclone B2 上传模式
- 项目代码: `docker/docker-compose.yml` — noda-ops 服务定义

### Secondary (MEDIUM confidence)
- Context7 /rtyley/bfg-repo-cleaner — BFG 使用方式（作为 git-filter-repo 的参考）
- brew info git-filter-repo — 版本 2.47.0 确认已安装
- brew info bfg — 版本 1.15.0 可用但未安装

### Tertiary (LOW confidence)
- 无 — 所有发现均通过代码检查或 Context7 验证

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 所有工具已在项目代码中验证或通过 brew 命令确认
- Architecture: HIGH — 基于现有 noda-ops 容器 cron 模式，改动最小
- Pitfalls: HIGH — 通过代码审查发现（b2 vs rclone 是最关键的发现）

**Research date:** 2026-04-19
**Valid until:** 2026-05-19（稳定，主要依赖项目内部代码）
