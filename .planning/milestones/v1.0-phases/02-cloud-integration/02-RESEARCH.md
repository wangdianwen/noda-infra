# Phase 2: 云存储集成 - 技术研究

**Created:** 2026-04-06
**Focus:** Backblaze B2 + rclone 技术方案调研

## 研究目标

为 Phase 2 云存储集成提供技术决策依据：
1. Backblaze B2 技术能力和最佳实践
2. rclone 配置和使用方法
3. 安全凭证管理方案
4. 重试和校验机制实现

## 1. Backblaze B2 技术调研

### 1.1 B2 基本概念

**核心概念：**
- **Bucket**: 存储桶，相当于 S3 的 bucket
- **Application Key**: API 访问凭证，可以限制权限和前缀
- **Lifecycle Rules**: 自动清理旧文件的规则

**优势：**
- 成本低：$0.005/GB/月（存储），$0.004/GB 下载
- 原生加密：服务端加密（SSE-B2）
- 11个9的持久性：比 S3 更可靠
- 与 S3 兼容的 API

### 1.2 B2 Application Key 权限模型

**最小权限原则（SECURITY-02）：**

```json
{
  "capabilities": [
    "writeFiles",      // 上传备份文件
    "deleteFiles",     // 清理旧备份
    "listFiles"        // 列出备份文件
  ],
  "fileNamePrefix": "backups/",  // 限制到备份目录
  "namePrefix": "backup-system-" // 命名规范
}
```

**不需要的权限：**
- ❌ `shareFiles`: 不需要公开分享
- ❌ `readFiles`: rclone checksum 需要读取元数据，但不需要读取文件内容
- ❌ `writeBuckets`: 不需要创建 bucket
- ❌ `deleteBuckets`: 不需要删除 bucket

### 1.3 B2 Lifecycle Rules（UPLOAD-05）

**自动清理未完成的上传：**
```json
{
  "rules": [
    {
      "fileNamePrefix": "backups/incomplete/",
      "daysFromHidingToDeleting": 1,
      "daysFromUploadingToHiding": 1
    }
  ]
}
```

**7天清理策略（UPLOAD-04）：**
- 应用层清理（更灵活）
- B2 Lifecycle 作为兜底（30天自动清理）

## 2. rclone 技术调研

### 2.1 rclone 基本用法

**配置 B2 远程：**
```bash
rclone config create b2remote backblazeb2 \
  --b2-account-id "$B2_ACCOUNT_ID" \
  --b2-account-key "$B2_APPLICATION_KEY"
```

**上传文件：**
```bash
rclone copy /local/path b2remote:bucket-name/backups/ \
  --progress \
  --transfers 4 \
  --checkers 8
```

**验证校验和（UPLOAD-03）：**
```bash
rclone check /local/path b2remote:bucket-name/backups/ \
  --one-way \
  --combined checksum-report.txt
```

### 2.2 rclone 重试机制（UPLOAD-02）

**内置重试：**
```bash
rclone copy ... \
  --retries 3 \
  --low-level-retries 10 \
  --retry-delay 5s \
  --low-level-retry-delay 3s
```

**指数退避实现（应用层）：**
```bash
# Bash 指数退避
for attempt in {1..3}; do
  if rclone copy ...; then
    break
  else
    wait_time=$((2 ** (attempt - 1)))  # 1s, 2s, 4s
    sleep $wait_time
  fi
done
```

### 2.3 rclone 退出码

```bash
0 # 成功
1 # 语法错误或使用错误
2 # 非致命错误（部分文件未复制）
3 # 致命错误（完全失败）
```

## 3. 安全凭证管理（SECURITY-01）

### 3.1 环境变量方案

**.env.backup 扩展：**
```bash
# Backblaze B2 凭证
B2_ACCOUNT_ID=your_account_id
B2_APPLICATION_KEY=your_application_key
B2_BUCKET_NAME=noda-backups
B2_PATH=backups/postgres/
```

**加载方式（lib/config.sh）：**
```bash
load_config() {
  # 加载 .env.backup
  if [[ -f .env.backup ]]; then
    set -a
    source .env.backup
    set +a
  fi

  # 验证必需变量
  validate_b2_credentials
}
```

### 3.2 rclone 配置文件管理

**方案：临时配置文件（不写入磁盘）**
```bash
upload_to_b2() {
  local backup_dir=$1

  # 使用环境变量创建临时 rclone 配置
  local rclone_config=$(mktemp)
  chmod 600 "$rclone_config"

  rclone config create b2remote backblazeb2 \
    --b2-account-id "$B2_ACCOUNT_ID" \
    --b2-account-key "$B2_APPLICATION_KEY" \
    --config "$rclone_config"

  # 上传
  rclone copy "$backup_dir" b2remote:"$B2_BUCKET_NAME/$B2_PATH" \
    --config "$rclone_config"

  # 清理配置文件
  rm -f "$rclone_config"
}
```

## 4. 实现策略

### 4.1 模块化设计

**新增库文件：lib/cloud.sh**
```bash
# 核心函数
upload_to_b2()              # 上传备份文件
verify_upload_checksum()    # 验证校验和
cleanup_old_backups_b2()    # 清理云端旧备份
setup_b2_credentials()      # 设置 B2 凭证
```

**扩展 lib/config.sh**
```bash
# B2 配置函数
get_b2_account_id()
get_b2_application_key()
get_b2_bucket_name()
get_b2_path()
validate_b2_credentials()
```

**扩展 lib/constants.sh**
```bash
readonly EXIT_CLOUD_UPLOAD_FAILED=3  # 已存在
```

### 4.2 集成到主脚本

**主脚本流程扩展（backup-postgres.sh）：**
```bash
main() {
  # 1. 健康检查
  check_prerequisites

  # 2. 本地备份
  backup_all_databases

  # 3. 本地验证
  verify_all_backups

  # 4. 云上传（新增）
  upload_to_cloud

  # 5. 清理
  cleanup_old_backups_local
  cleanup_old_backups_cloud
}
```

### 4.3 错误处理

**上传失败处理：**
```bash
upload_to_b2() {
  local max_retries=3
  local attempt=1

  while [[ $attempt -le $max_retries ]]; do
    if rclone copy ...; then
      # 验证校验和
      if verify_upload_checksum; then
        log_success "上传成功"
        return 0
      fi
    fi

    log_warn "上传失败（尝试 $attempt/$max_retries）"
    ((attempt++))

    if [[ $attempt -le $max_retries ]]; then
      local wait_time=$((2 ** (attempt - 1)))
      log_info "等待 ${wait_time}s 后重试..."
      sleep $wait_time
    fi
  done

  log_error "上传失败（已重试 $max_retries 次）"
  return $EXIT_CLOUD_UPLOAD_FAILED
}
```

## 5. 技术风险和缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| rclone 未安装 | 阻塞 | 在 Wave 0 检查并安装 rclone |
| B2 API 限流 | 上传失败 | 实现指数退避重试 |
| 校验和不匹配 | 数据损坏 | 上传后立即验证，失败时重试 |
| 凭证泄露 | 安全风险 | 环境变量管理 + 临时配置文件 |
| 网络不稳定 | 上传超时 | 增加超时时间 + 重试机制 |

## 6. 测试策略

### 6.1 单元测试
- 测试重试逻辑
- 测试校验和验证
- 测试凭证加载

### 6.2 集成测试
- 测试完整上传流程
- 测试失败场景（网络错误、API 错误）
- 测试清理功能

### 6.3 测试环境
- 使用 B2 测试 bucket
- 创建最小权限的 Application Key
- 测试不同大小的文件

## 7. 下一步

1. **Wave 0**: 安装和配置 rclone，创建 B2 测试 bucket
2. **Wave 1**: 实现 lib/cloud.sh 核心功能
3. **Wave 2**: 集成到主脚本，端到端测试
4. **Wave 3**: 安全加固和性能优化

---

**研究完成时间:** 2026-04-06
**下一步:** 创建 Phase 2 执行计划
