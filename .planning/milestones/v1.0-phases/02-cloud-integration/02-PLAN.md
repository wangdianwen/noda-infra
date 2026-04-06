# Phase 2: 云存储集成 - 执行计划

**Created:** 2026-04-06
**Phase:** 2 of 5
**Status:** Ready for execution
**Total Waves:** 4
**Estimated Time:** 5-8 hours

## Plan 概述

**目标：** 实现备份文件自动上传到 Backblaze B2 云存储

**核心交付物：**
1. ✅ lib/cloud.sh - 云操作库
2. ✅ rclone 配置和 B2 集成
3. ✅ 上传重试和校验机制
4. ✅ 自动清理旧备份
5. ✅ 主脚本集成

---

## Wave 0: 基础设施准备（独立，30 min）

**目标：** 安装和配置 rclone，创建 B2 测试环境

**依赖：** 无（可立即开始）

### 任务 01: 安装 rclone

**验收标准：**
- [ ] rclone 命令可用（`rclone version`）
- [ ] 版本 >= 1.60

**步骤：**
1. 检查 rclone 是否已安装
2. 如果未安装，使用 brew 安装：
   ```bash
   brew install rclone
   ```
3. 验证安装：`rclone version`

**预期输出：**
```
rclone v1.65.0
- os/version: darwin
- os/kernel: 23.0.0 (arm64)
```

**风险：**
- 低：brew 安装失败 → 使用官方二进制包

---

### 任务 02: 创建 B2 Bucket

**验收标准：**
- [ ] B2 bucket 已创建（名称：noda-backups）
- [ ] Bucket 设置为私有（非公开）

**步骤：**
1. 登录 Backblaze B2 控制台
2. 创建新 bucket：
   - 名称：`noda-backups`
   - 文件在存储中的存储类型：`Standard`
   - 文件在存储中的加密设置：`默认加密`（SSE-B2）
3. 验证 bucket 已创建

**预期输出：**
- B2 控制台显示 `noda-backups` bucket

**风险：**
- 低：Bucket 名称已被占用 → 添加随机后缀（如 `noda-backups-prod01`）

---

### 任务 03: 生成 B2 Application Key

**验收标准：**
- [ ] Application Key 已生成（名称：`backup-system-$(hostname)`）
- [ ] 权限：`writeFiles`, `deleteFiles`, `listFiles`
- [ ] 文件前缀限制：`backups/`

**步骤：**
1. 在 B2 控制台中，进入 "App Keys"
2. 点击 "Add a New Application Key"
3. 配置：
   - **Name**: `backup-system-$(hostname)`
   - **Allow access to Bucket(s)**: `noda-backups`
   - **Type of Access**: `Limited`
   - **File Name Prefix**: `backups/`
   - **Capabilities**: `writeFiles`, `deleteFiles`, `listFiles`
4. 生成后，记录以下信息：
   - `keyID`: Application Key ID
   - `applicationKey`: Application Key（只显示一次）

**预期输出：**
```
keyID: 001234567890abcdef
applicationKey: K001abcdefghijklmnopqrstuvwxyz1234567890
```

**安全注意事项：**
- ⚠️ Application Key 只显示一次，请立即保存到安全的地方
- ⚠️ 不要将密钥提交到 Git 仓库

**风险：**
- 中：密钥泄露 → 立即撤销并重新生成

---

### 任务 04: 配置 .env.backup

**验收标准：**
- [ ] .env.backup 文件已更新
- [ ] 包含 B2 配置项

**步骤：**
1. 编辑 `.env.backup` 文件
2. 添加以下配置：
   ```bash
   # Backblaze B2 配置
   B2_ACCOUNT_ID=your_account_id_here
   B2_APPLICATION_KEY=your_application_key_here
   B2_BUCKET_NAME=noda-backups
   B2_PATH=backups/postgres/
   ```
3. 替换 `your_account_id_here` 和 `your_application_key_here` 为实际值
4. 设置文件权限：`chmod 600 .env.backup`

**预期输出：**
```bash
# .env.backup
B2_ACCOUNT_ID=001234567890abcdef
B2_APPLICATION_KEY=K001abcdefghijklmnopqrstuvwxyz1234567890
B2_BUCKET_NAME=noda-backups
B2_PATH=backups/postgres/
```

**风险：**
- 中：权限设置不当 → 敏感信息泄露

---

### 任务 05: 创建测试脚本

**验收标准：**
- [ ] `tests/test_rclone.sh` 文件已创建
- [ ] 可以手动测试 rclone 配置

**步骤：**
1. 创建 `scripts/backup/tests/test_rclone.sh`
2. 实现以下功能：
   - 测试 rclone 配置
   - 测试 B2 连接
   - 测试文件上传
   - 测试文件列表
   - 测试文件删除

**脚本框架：**
```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/log.sh"

# 测试 rclone 配置
test_rclone_config() {
  log_info "测试 rclone 配置..."
  # TODO: 实现配置测试
}

# 测试 B2 连接
test_b2_connection() {
  log_info "测试 B2 连接..."
  # TODO: 实现连接测试
}

# 主函数
main() {
  load_config
  test_rclone_config
  test_b2_connection
  log_success "rclone 测试完成"
}

main "$@"
```

**预期输出：**
```
✅ rclone 配置测试通过
✅ B2 连接测试通过
```

**风险：**
- 低：测试脚本不完整 → Wave 1 完善

---

## Wave 1: 核心功能实现（依赖 Wave 0，2-3 hours）

**目标：** 实现 lib/cloud.sh 云操作库

**依赖：** Wave 0 完成

### 任务 01: 扩展 lib/config.sh

**验收标准：**
- [ ] 新增 B2 配置函数
- [ ] 配置验证函数

**步骤：**
1. 编辑 `scripts/backup/lib/config.sh`
2. 添加以下函数：

```bash
# ============================================
# B2 配置函数
# ============================================

# get_b2_account_id - 获取 B2 Account ID
get_b2_account_id() {
  echo "${B2_ACCOUNT_ID:-}"
}

# get_b2_application_key - 获取 B2 Application Key
get_b2_application_key() {
  echo "${B2_APPLICATION_KEY:-}"
}

# get_b2_bucket_name - 获取 B2 Bucket 名称
get_b2_bucket_name() {
  echo "${B2_BUCKET_NAME:-noda-backups}"
}

# get_b2_path - 获取 B2 路径前缀
get_b2_path() {
  echo "${B2_PATH:-backups/postgres/}"
}

# validate_b2_credentials - 验证 B2 凭证
validate_b2_credentials() {
  local b2_account_id
  local b2_application_key
  local b2_bucket_name

  b2_account_id=$(get_b2_account_id)
  b2_application_key=$(get_b2_application_key)
  b2_bucket_name=$(get_b2_bucket_name)

  if [[ -z "$b2_account_id" ]]; then
    log_error "B2_ACCOUNT_ID 未设置"
    return 1
  fi

  if [[ -z "$b2_application_key" ]]; then
    log_error "B2_APPLICATION_KEY 未设置"
    return 1
  fi

  if [[ -z "$b2_bucket_name" ]]; then
    log_error "B2_BUCKET_NAME 未设置"
    return 1
  fi

  return 0
}
```

**预期输出：**
- 配置函数可以正确读取环境变量
- 验证函数可以检测缺失的配置

**风险：**
- 低：函数命名冲突 → 使用 `b2_` 前缀

---

### 任务 02: 创建 lib/cloud.sh

**验收标准：**
- [ ] `lib/cloud.sh` 文件已创建
- [ ] 包含核心云操作函数

**步骤：**
1. 创建 `scripts/backup/lib/cloud.sh`
2. 实现以下函数：

```bash
#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 云操作库
# ============================================
# 功能：Backblaze B2 云存储操作
# 依赖：log.sh, config.sh
# ============================================

set -euo pipefail

# 加载依赖库
_CLOUD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_CLOUD_LIB_DIR/log.sh"
source "$_CLOUD_LIB_DIR/config.sh"

# ============================================
# rclone 配置管理
# ============================================

# setup_rclone_config - 创建临时 rclone 配置
# 参数：无
# 返回：配置文件路径
setup_rclone_config() {
  local rclone_config
  local b2_account_id
  local b2_application_key

  b2_account_id=$(get_b2_account_id)
  b2_application_key=$(get_b2_application_key)

  # 创建临时配置文件
  rclone_config=$(mktemp)
  chmod 600 "$rclone_config"

  # 配置 rclone
  rclone config create b2remote backblazeb2 \
    --b2-account-id "$b2_account_id" \
    --b2-account-key "$b2_application_key" \
    --config "$rclone_config" >/dev/null 2>&1

  echo "$rclone_config"
}

# cleanup_rclone_config - 清理 rclone 配置文件
# 参数：$1 = 配置文件路径
cleanup_rclone_config() {
  local rclone_config=$1

  if [[ -f "$rclone_config" ]]; then
    rm -f "$rclone_config"
  fi
}

# ============================================
# 云上传功能
# ============================================

# upload_to_b2 - 上传备份文件到 B2
# 参数：
#   $1: 本地备份目录
#   $2: 远程路径（可选，默认为 $B2_BUCKET_NAME/$B2_PATH/YYYY/MM/DD/）
# 返回：0（成功）或非0（失败）
upload_to_b2() {
  local local_dir=$1
  local remote_path=${2:-}
  local max_retries=3
  local attempt=1

  log_info "开始上传到 Backblaze B2..."

  # 设置远程路径
  if [[ -z "$remote_path" ]]; then
    local date_path
    date_path=$(get_date_path)
    local b2_bucket_name
    b2_bucket_name=$(get_b2_bucket_name)
    local b2_path
    b2_path=$(get_b2_path)
    remote_path="${b2_bucket_name}/${b2_path}${date_path}"
  fi

  # 创建 rclone 配置
  local rclone_config
  rclone_config=$(setup_rclone_config)

  # 重试逻辑
  while [[ $attempt -le $max_retries ]]; do
    log_info "上传尝试 $attempt/$max_retries"

    if rclone copy "$local_dir" "b2remote:$remote_path" \
      --config "$rclone_config" \
      --progress \
      --transfers 4 \
      --checkers 8 \
      --metadata-set "uploaded-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; then

      # 验证校验和
      if verify_upload_checksum "$local_dir" "b2remote:$remote_path" "$rclone_config"; then
        log_success "上传成功（共 $(find "$local_dir" -type f | wc -l) 个文件）"
        cleanup_rclone_config "$rclone_config"
        return 0
      else
        log_warn "校验和验证失败"
      fi
    fi

    ((attempt++))

    if [[ $attempt -le $max_retries ]]; then
      local wait_time=$((2 ** (attempt - 1)))
      log_info "等待 ${wait_time}s 后重试..."
      sleep $wait_time
    fi
  done

  log_error "上传失败（已重试 $max_retries 次）"
  cleanup_rclone_config "$rclone_config"
  return $EXIT_CLOUD_UPLOAD_FAILED
}

# ============================================
# 校验和验证
# ============================================

# verify_upload_checksum - 验证上传文件的校验和
# 参数：
#   $1: 本地目录
#   $2: 远程路径
#   $3: rclone 配置文件路径
# 返回：0（成功）或非0（失败）
verify_upload_checksum() {
  local local_dir=$1
  local remote_path=$2
  local rclone_config=$3

  log_info "验证校验和..."

  if rclone check "$local_dir" "b2remote:$remote_path" \
    --config "$rclone_config" \
    --one-way \
    --combined /dev/null \
    --quiet; then
    log_success "校验和验证通过"
    return 0
  else
    log_error "校验和验证失败"
    return 1
  fi
}

# ============================================
# 清理功能
# ============================================

# cleanup_old_backups_b2 - 清理 B2 上的旧备份
# 参数：
#   $1: 保留天数（默认 7 天）
# 返回：0（成功）或非0（失败）
cleanup_old_backups_b2() {
  local retention_days=${1:-7}
  local b2_bucket_name
  local b2_path

  b2_bucket_name=$(get_b2_bucket_name)
  b2_path=$(get_b2_path)

  log_info "清理 B2 上 ${retention_days} 天前的旧备份..."

  # 创建 rclone 配置
  local rclone_config
  rclone_config=$(setup_rclone_config)

  # 删除旧文件
  if rclone delete "b2remote:${b2_bucket_name}/${b2_path}" \
    --config "$rclone_config" \
    --min-age ${retention_days}d \
    --quiet; then
    log_success "B2 旧备份清理完成"
    cleanup_rclone_config "$rclone_config"
    return 0
  else
    log_error "B2 旧备份清理失败"
    cleanup_rclone_config "$rclone_config"
    return 1
  fi
}

# ============================================
# 辅助函数
# ============================================

# list_b2_backups - 列出 B2 上的所有备份
# 参数：无
# 返回：备份文件列表（每行一个）
list_b2_backups() {
  local b2_bucket_name
  local b2_path

  b2_bucket_name=$(get_b2_bucket_name)
  b2_path=$(get_b2_path)

  # 创建 rclone 配置
  local rclone_config
  rclone_config=$(setup_rclone_config)

  # 列出文件
  rclone ls "b2remote:${b2_bucket_name}/${b2_path}" \
    --config "$rclone_config" \
    2>/dev/null || true

  # 清理配置
  cleanup_rclone_config "$rclone_config"
}
```

**预期输出：**
- lib/cloud.sh 文件已创建
- 包含所有核心函数

**风险：**
- 中：函数实现复杂 → 先实现简化版本，逐步完善

---

### 任务 03: 实现上传重试逻辑

**验收标准：**
- [ ] upload_to_b2 函数包含重试逻辑
- [ ] 使用指数退避（1s, 2s, 4s）
- [ ] 最多重试 3 次

**步骤：**
1. 在 lib/cloud.sh 中实现 upload_to_b2 函数
2. 实现指数退避逻辑：
   ```bash
   local wait_time=$((2 ** (attempt - 1)))  # 1, 2, 4
   sleep $wait_time
   ```

**预期输出：**
```
ℹ️  上传尝试 1/3
ℹ️  上传失败，等待 1s 后重试...
ℹ️  上传尝试 2/3
ℹ️  上传失败，等待 2s 后重试...
ℹ️  上传尝试 3/3
✅ 上传成功
```

**风险：**
- 低：重试逻辑错误 → 单元测试验证

---

### 任务 04: 实现校验和验证

**验收标准：**
- [ ] verify_upload_checksum 函数已实现
- [ ] 使用 rclone check --checksum

**步骤：**
1. 在 lib/cloud.sh 中实现 verify_upload_checksum 函数
2. 使用 rclone check 验证：
   ```bash
   rclone check "$local_dir" "b2remote:$remote_path" \
     --one-way \
     --combined /dev/null
   ```

**预期输出：**
```
ℹ️  验证校验和...
✅ 校验和验证通过
```

**风险：**
- 中：rclone check 失败 → 检查文件权限和网络连接

---

## Wave 2: 主脚本集成（依赖 Wave 1，1-2 hours）

**目标：** 将云上传集成到主脚本

**依赖：** Wave 1 完成

### 任务 01: 修改 backup-postgres.sh

**验收标准：**
- [ ] 主脚本加载 lib/cloud.sh
- [ ] 备份完成后自动上传

**步骤：**
1. 编辑 `scripts/backup/backup-postgres.sh`
2. 在加载库部分添加：
   ```bash
   source "$SCRIPT_DIR/lib/cloud.sh"
   ```
3. 在 main 函数中添加上传步骤：
   ```bash
   # 备份
   log_info "步骤 2/6: 备份数据库"
   backup_all_databases "$backup_dir" "$timestamp"
   log_success "数据库备份完成"

   # 验证
   log_info "步骤 3/6: 验证备份"
   verify_all_backups "$backup_dir"
   log_success "备份验证完成"

   # 云上传（新增）
   log_info "步骤 4/6: 上传到云存储"
   upload_to_b2 "$backup_dir"
   log_success "云上传完成"

   # 清理
   log_info "步骤 5/6: 清理旧备份"
   cleanup_old_backups "$(get_backup_dir)"
   cleanup_old_backups_b2 $(get_retention_days)
   log_success "旧备份清理完成"

   # 完成
   log_info "步骤 6/6: 备份完成"
   ```

**预期输出：**
```
ℹ️  步骤 2/6: 备份数据库
✅ 数据库备份完成
ℹ️  步骤 3/6: 验证备份
✅ 备份验证完成
ℹ️  步骤 4/6: 上传到云存储
ℹ️  开始上传到 Backblaze B2...
ℹ️  上传尝试 1/3
✅ 上传成功
✅ 云上传完成
ℹ️  步骤 5/6: 清理旧备份
✅ 旧备份清理完成
ℹ️  步骤 6/6: 备份完成
```

**风险：**
- 低：步骤编号错误 → 更新所有步骤编号

---

### 任务 02: 实现清理功能集成

**验收标准：**
- [ ] 主脚本调用 cleanup_old_backups_b2
- [ ] 清理本地和云端旧备份

**步骤：**
1. 在主脚本中添加清理调用：
   ```bash
   # 清理旧备份
   log_info "步骤 5/6: 清理旧备份"
   cleanup_old_backups "$(get_backup_dir)"
   cleanup_old_backups_b2 $(get_retention_days)
   log_success "旧备份清理完成"
   ```

**预期输出：**
```
ℹ️  步骤 5/6: 清理旧备份
ℹ️  清理 7 天前的旧备份...
✅ 旧备份清理完成
ℹ️  清理 B2 上 7 天前的旧备份...
✅ B2 旧备份清理完成
```

**风险：**
- 中：清理错误导致数据丢失 → 先测试，后上线

---

### 任务 03: 错误处理和日志

**验收标准：**
- [ ] 上传失败时返回正确的退出码
- [ ] 错误信息清晰明确

**步骤：**
1. 在主脚本中添加错误处理：
   ```bash
   # 云上传
   log_info "步骤 4/6: 上传到云存储"
   if ! upload_to_b2 "$backup_dir"; then
     log_error "云上传失败，但本地备份已保留"
     log_error "本地备份路径: $backup_dir"
     release_lock
     exit $EXIT_CLOUD_UPLOAD_FAILED
   fi
   log_success "云上传完成"
   ```

**预期输出：**
```
ℹ️  步骤 4/6: 上传到云存储
ℹ️  开始上传到 Backblaze B2...
ℹ️  上传尝试 1/3
❌ 上传失败（已重试 3 次）
❌ 错误: 云上传失败，但本地备份已保留
❌ 错误: 本地备份路径: /local/backups/2026/04/06
```

**风险：**
- 低：错误信息不清晰 → 测试并优化

---

## Wave 3: 测试和优化（依赖 Wave 2，1-2 hours）

**目标：** 端到端测试和性能优化

**依赖：** Wave 2 完成

### 任务 01: 创建端到端测试

**验收标准：**
- [ ] `tests/test_upload.sh` 文件已创建
- [ ] 测试完整上传流程

**步骤：**
1. 创建 `scripts/backup/tests/test_upload.sh`
2. 实现测试流程：
   - 创建测试备份
   - 上传到 B2
   - 验证文件完整性
   - 清理测试数据

**测试脚本框架：**
```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/cloud.sh"

# 测试上传功能
test_upload() {
  log_info "=========================================="
  log_info "测试：云上传功能"
  log_info "=========================================="

  # 创建测试备份
  local test_backup_dir
  test_backup_dir=$(mktemp -d)

  echo "test data" > "$test_backup_dir/test.txt"

  # 上传测试
  if upload_to_b2 "$test_backup_dir"; then
    log_success "✅ 上传测试通过"
  else
    log_error "❌ 上传测试失败"
    return 1
  fi

  # 清理
  rm -rf "$test_backup_dir"
  cleanup_old_backups_b2 0  # 删除所有测试文件

  log_success "=========================================="
  log_success "测试完成！"
  log_success "=========================================="
  return 0
}

# 主函数
main() {
  load_config
  validate_b2_credentials
  test_upload
}

main "$@"
```

**预期输出：**
```
==========================================
测试：云上传功能
==========================================
ℹ️  开始上传到 Backblaze B2...
ℹ️  上传尝试 1/3
✅ 上传成功
✅ 上传测试通过
==========================================
测试完成！
==========================================
```

**风险：**
- 低：测试脚本不完整 → 逐步完善

---

### 任务 02: 性能优化

**验收标准：**
- [ ] 上传速度合理（> 10 MB/s）
- [ ] 内存使用合理（< 500 MB）

**步骤：**
1. 测试不同 rclone 参数组合：
   ```bash
   # 测试不同的并发数
   rclone copy ... --transfers 2
   rclone copy ... --transfers 4
   rclone copy ... --transfers 8

   # 测试不同的检查器数量
   rclone copy ... --checkers 4
   rclone copy ... --checkers 8
   rclone copy ... --checkers 16
   ```
2. 选择最优参数组合

**预期输出：**
- 最优参数：`--transfers 4 --checkers 8`

**风险：**
- 低：性能不佳 → 调整参数或升级网络

---

### 任务 03: 文档更新

**验收标准：**
- [ ] README.md 已更新
- [ ] 包含 B2 配置说明

**步骤：**
1. 创建或更新 `scripts/backup/README.md`
2. 添加以下内容：
   - B2 配置指南
   - rclone 安装指南
   - 使用示例
   - 故障排查

**README 框架：**
```markdown
# Noda 数据库备份系统

## 功能特性

- 本地备份（PostgreSQL）
- 云存储上传（Backblaze B2）
- 自动清理旧备份
- 校验和验证

## 快速开始

### 1. 安装 rclone

\`\`\`bash
brew install rclone
\`\`\`

### 2. 配置 B2

编辑 `.env.backup`：

\`\`\`bash
B2_ACCOUNT_ID=your_account_id
B2_APPLICATION_KEY=your_application_key
B2_BUCKET_NAME=noda-backups
B2_PATH=backups/postgres/
\`\`\`

### 3. 运行备份

\`\`\`bash
./scripts/backup/backup-postgres.sh
\`\`\`

## 故障排查

### 上传失败

1. 检查 B2 凭证是否正确
2. 检查网络连接
3. 查看 rclone 日志
```

**预期输出：**
- README.md 文件已创建
- 包含完整的配置和使用说明

**风险：**
- 低：文档不完整 → 逐步完善

---

## 执行顺序

```
Wave 0 (独立)
├── 任务 01: 安装 rclone
├── 任务 02: 创建 B2 Bucket
├── 任务 03: 生成 B2 Application Key
├── 任务 04: 配置 .env.backup
└── 任务 05: 创建测试脚本

Wave 1 (依赖 Wave 0)
├── 任务 01: 扩展 lib/config.sh
├── 任务 02: 创建 lib/cloud.sh
├── 任务 03: 实现上传重试逻辑
└── 任务 04: 实现校验和验证

Wave 2 (依赖 Wave 1)
├── 任务 01: 修改 backup-postgres.sh
├── 任务 02: 实现清理功能集成
└── 任务 03: 错误处理和日志

Wave 3 (依赖 Wave 2)
├── 任务 01: 创建端到端测试
├── 任务 02: 性能优化
└── 任务 03: 文档更新
```

---

## 验收标准总览

### Wave 0
- [ ] rclone 已安装并可用
- [ ] B2 bucket 已创建
- [ ] B2 Application Key 已生成
- [ ] .env.backup 已配置
- [ ] 测试脚本已创建

### Wave 1
- [ ] lib/config.sh 已扩展
- [ ] lib/cloud.sh 已创建
- [ ] 上传重试逻辑已实现
- [ ] 校验和验证已实现

### Wave 2
- [ ] 主脚本已集成云上传
- [ ] 清理功能已集成
- [ ] 错误处理已完善

### Wave 3
- [ ] 端到端测试通过
- [ ] 性能优化完成
- [ ] 文档已更新

---

## 风险和缓解措施

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| rclone 未安装 | 中 | 高 | Wave 0 安装和验证 |
| B2 API 限流 | 低 | 中 | 指数退避重试 |
| 网络不稳定 | 中 | 中 | 增加超时时间 |
| 大文件上传超时 | 低 | 中 | rclone 自动重试 |
| 校验和不匹配 | 低 | 高 | 立即重试 |
| 清理误删 | 低 | 高 | 先测试，后上线 |

---

## 时间估算

| Wave | 预估时间 | 缓冲时间 | 总计 |
|------|----------|----------|------|
| Wave 0 | 30 min | 15 min | 45 min |
| Wave 1 | 2-3 hours | 1 hour | 3-4 hours |
| Wave 2 | 1-2 hours | 30 min | 1.5-2.5 hours |
| Wave 3 | 1-2 hours | 30 min | 1.5-2.5 hours |
| **总计** | **5-8 hours** | **2-3 hours** | **7-11 hours** |

---

## 下一步

1. ✅ 完成技术研究（02-RESEARCH.md）
2. ✅ 创建上下文文档（02-CONTEXT.md）
3. ✅ 创建决策日志（02-DISCUSSION-LOG.md）
4. ✅ 创建执行计划（02-PLAN.md）
5. ⏳ 开始 Wave 0 执行

---

**执行计划版本:** 1.0
**最后更新:** 2026-04-06
**状态:** Ready for execution
**预估完成时间:** 5-8 hours
