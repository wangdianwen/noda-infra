# Phase 4 技术研究：自动化验证测试

**阶段**: Phase 4 - 自动化验证测试
**研究日期**: 2026-04-06
**状态**: 研究完成

---

## 研究目标

分析自动化验证测试的关键技术，包括 Docker 容器化、验证逻辑设计、超时管理和错误处理，为 Phase 4 执行计划提供技术基础。

---

## 1. Docker 容器化研究

### 1.1 基础镜像选择

**选项对比**：

| 镜像 | 大小 | 优势 | 劣势 | 推荐度 |
|------|------|------|------|--------|
| `postgres:15-alpine` | ~230 MB | 轻量级、包含 psql/pg_restore | 需要手动安装 rclone | ⭐⭐⭐⭐⭐ |
| `postgres:15` | ~375 MB | 完整功能、官方支持 | 体积较大 | ⭐⭐⭐⭐ |
| `alpine:latest` | ~7 MB | 极小体积 | 需要手动安装所有工具 | ⭐⭐ |

**结论**：选择 `postgres:15-alpine` 作为基础镜像，平衡体积和功能。

### 1.2 必需工具安装

```dockerfile
# 安装 rclone
RUN apk add --no-cache rclone

# 安装额外工具
RUN apk add --no-cache \
    coreutils \
    bash \
    jq \
    bc \
    openssl

# 验证安装
RUN rclone version && \
    psql --version && \
    pg_restore --version
```

**工具清单**：
- `rclone` - B2 下载
- `psql` - 数据库查询和验证
- `pg_restore` - 恢复备份文件
- `coreutils` - sha256sum
- `jq` - JSON 解析（元数据）
- `bc` - 数学计算（文件大小转换）
- `openssl` - 加密验证

### 1.3 环境变量配置

**必需的环境变量**：

```bash
# PostgreSQL 连接
POSTGRES_HOST=host.docker.internal
POSTGRES_PORT=5432
POSTGRES_USER=postgres
POSTGRES_PASSWORD=password

# B2 配置
B2_ACCOUNT_ID=account_id
B2_APPLICATION_KEY=application_key
B2_BUCKET_NAME=noda-backups
B2_PATH=postgresql/

# 测试配置
TEST_DB_PREFIX=test_restore_
TEST_TIMEOUT=3600  # 1 小时
TEST_LOG_LEVEL=INFO
```

**安全考虑**：
- 所有敏感信息通过环境变量传入
- 不在镜像中存储任何凭证
- 使用 Docker secrets（可选）

---

## 2. 验证逻辑研究

### 2.1 多层验证设计

**验证流程**：

```
Layer 1: 文件完整性验证
  ├─ SHA256 校验和验证
  ├─ 文件大小检查（> 100 bytes）
  └─ 文件格式验证（.dump 或 .sql）

Layer 2: 备份可读性验证
  ├─ pg_restore --list
  └─ 检查备份文件头部

Layer 3: 数据结构验证
  ├─ 表数量检查（> 0）
  ├─ 表结构完整性
  └─ 索引和约束检查

Layer 4: 数据完整性验证
  ├─ 任意表记录数 > 0
  ├─ 关键表存在性检查
  └─ 数据采样验证（可选）
```

### 2.2 验证函数设计

**基于现有 `lib/verify.sh` 扩展**：

```bash
# 新增函数
verify_test_restore() {
  local backup_file=$1
  local test_db_name=$2

  # Layer 1: 文件完整性
  verify_backup_checksum "$backup_file" "$expected_checksum"
  verify_file_size "$backup_file"

  # Layer 2: 备份可读性
  verify_backup_readable "$backup_file"

  # Layer 3: 数据结构
  verify_table_count "$test_db_name"

  # Layer 4: 数据完整性
  verify_data_exists "$test_db_name"
}
```

### 2.3 数据验证策略

**表数量验证**：

```bash
verify_table_count() {
  local db_name=$1
  local min_tables=1

  local count=$(psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
    -d "$db_name" -t -c "
      SELECT COUNT(*)
      FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE';
    ")

  if [[ $count -ge $min_tables ]]; then
    log_success "表数量验证通过: $count 个表"
    return 0
  else
    log_error "表数量验证失败: 仅 $count 个表"
    return 1
  fi
}
```

**记录存在性验证**：

```bash
verify_data_exists() {
  local db_name=$1

  # 获取第一个有数据的表
  local table=$(psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
    -d "$db_name" -t -c "
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE'
      LIMIT 1;
    ")

  if [[ -z "$table" ]]; then
    log_error "未找到任何表"
    return 1
  fi

  # 检查记录数
  local count=$(psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
    -d "$db_name" -t -c "
      SELECT COUNT(*) FROM $table;
    ")

  if [[ $count -gt 0 ]]; then
    log_success "数据验证通过: 表 $table 有 $count 条记录"
    return 0
  else
    log_error "数据验证失败: 表 $table 无数据"
    return 1
  fi
}
```

---

## 3. 超时管理研究

### 3.1 超时实现方案

**方案对比**：

| 方案 | 实现复杂度 | 可靠性 | 推荐度 |
|------|-----------|--------|--------|
| Bash `timeout` 命令 | 低 | 高 | ⭐⭐⭐⭐⭐ |
| 自定义超时逻辑 | 中 | 中 | ⭐⭐⭐ |
| Docker 容器超时 | 低 | 高 | ⭐⭐⭐⭐ |

**结论**：使用 Bash `timeout` 命令 + Docker 容器超时双重保护。

### 3.2 超时实现

**主脚本超时**：

```bash
#!/bin/bash
# 设置全局超时（1 小时）
TIMEOUT=3600

# 使用 timeout 命令包装整个测试流程
timeout $TIMEOUT bash -c '
  source lib/config.sh
  source lib/test-verify.sh

  # 执行测试
  run_weekly_verification
'

# 捕获超时退出码
if [[ $? -eq 124 ]]; then
  log_error "测试超时（${TIMEOUT}秒）"
  cleanup_on_timeout
  exit 5  # EXIT_TIMEOUT
fi
```

**Docker 容器超时**：

```bash
docker run --rm \
  --network host \
  -e POSTGRES_HOST=host.docker.internal \
  -e TEST_TIMEOUT=3600 \
  noda-backup-test:latest \
  bash /scripts/test-verify-weekly.sh
```

### 3.3 超时清理策略

```bash
cleanup_on_timeout() {
  log_warn "检测到超时，开始强制清理..."

  # 清理临时数据库
  for db in $(psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
    -d postgres -t -c "SELECT datname FROM pg_database WHERE datname LIKE '$TEST_DB_PREFIX%'"); do
    psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
      -d postgres -c "DROP DATABASE IF EXISTS $db" 2>/dev/null || true
  done

  # 清理临时文件
  rm -rf /tmp/test-verify-* 2>/dev/null || true

  log_warn "超时清理完成"
}
```

---

## 4. 错误处理研究

### 4.1 退出码规范

**扩展 `lib/constants.sh`**：

```bash
# Phase 4 特定退出码
readonly EXIT_TIMEOUT=5
readonly EXIT_DOWNLOAD_FAILED=11
readonly EXIT_RESTORE_TEST_FAILED=12
readonly EXIT_VERIFY_TEST_FAILED=13
readonly EXIT_CLEANUP_TEST_FAILED=14
```

### 4.2 错误恢复策略

**下载失败重试**：

```bash
download_with_retry() {
  local backup_filename=$1
  local max_retries=3
  local attempt=1

  while [[ $attempt -le $max_retries ]]; do
    log_info "下载尝试 $attempt/$max_retries"

    if download_backup "$backup_filename"; then
      return 0
    fi

    ((attempt++))
    if [[ $attempt -le $max_retries ]]; then
      local wait_time=$((2 ** (attempt - 1)))
      log_info "等待 ${wait_time}s 后重试..."
      sleep $wait_time
    fi
  done

  log_error "下载失败（已重试 $max_retries 次）"
  return $EXIT_DOWNLOAD_FAILED
}
```

### 4.3 失败保留策略

```bash
# 成功：立即清理
cleanup_on_success() {
  drop_test_database "$test_db_name"
  rm -f "$backup_file"
  rm -f "$checksum_file"
}

# 失败：保留调试信息
cleanup_on_failure() {
  log_warn "测试失败，保留临时数据库和文件供调试"
  log_warn "临时数据库: $test_db_name"
  log_warn "备份文件: $backup_file"
  log_warn "日志文件: $LOG_FILE"

  # 仅清理临时文件
  rm -f /tmp/test-verify-* 2>/dev/null || true
}
```

---

## 5. 调度集成研究

### 5.1 调度方式对比

| 方式 | 优势 | 劣势 | 推荐度 |
|------|------|------|--------|
| Jenkins 定时任务 | 集中管理、日志完善、告警集成 | 需要 Jenkins 服务器 | ⭐⭐⭐⭐⭐ |
| Cron 脚本 | 简单直接、无额外依赖 | 分散管理、告警困难 | ⭐⭐⭐ |
| systemd timer | 系统级管理、自动重启 | 仅限 Linux | ⭐⭐⭐⭐ |

**结论**：优先使用 Jenkins，备选方案为 cron。

### 5.2 Jenkins 配置

**Jenkinsfile 示例**：

```groovy
pipeline {
  agent any

  triggers {
    // 每周日凌晨 3:00 执行
    cron('0 3 * * 0')
  }

  stages {
    stage('Weekly Backup Verification') {
      steps {
        script {
          docker.build('noda-backup-test:latest', '-f Dockerfile.test-verify .')
            .inside("-e POSTGRES_HOST=host.docker.internal") {
              sh 'bash scripts/backup/test-verify-weekly.sh'
            }
        }
      }
    }
  }

  post {
    failure {
      emailext(
        subject: "❌ 备份验证失败: ${env.JOB_NAME}",
        body: "备份验证测试失败，请检查日志：${env.BUILD_URL}",
        to: 'ops@example.com'
      )
    }
  }
}
```

### 5.3 Cron 配置（备选）

```cron
# 每周日凌晨 3:00 执行
0 3 * * 0 cd /path/to/noda-infra && \
  docker run --rm \
    --network host \
    -v $(pwd)/scripts:/scripts:ro \
    -v $(pwd)/logs:/logs \
    -e POSTGRES_HOST=host.docker.internal \
    -e POSTGRES_USER=\${POSTGRES_USER} \
    -e POSTGRES_PASSWORD=\${POSTGRES_PASSWORD} \
    -e B2_ACCOUNT_ID=\${B2_ACCOUNT_ID} \
    -e B2_APPLICATION_KEY=\${B2_APPLICATION_KEY} \
    noda-backup-test:latest \
    bash /scripts/test-verify-weekly.sh >> /logs/weekly-verify.log 2>&1
```

---

## 6. 日志记录研究

### 6.1 日志格式设计

**结构化日志格式**：

```bash
LOG_FORMAT="[%(timestamp)s] [%(level)s] [%(stage)s] %(message)s"

# 示例
[2026-04-06T03:00:15Z] [INFO] [DOWNLOAD] 下载备份文件: keycloak_db_20260406_030000.dump
[2026-04-06T03:00:45Z] [INFO] [RESTORE] 恢复到临时数据库: test_restore_keycloak_db
[2026-04-06T03:01:20Z] [SUCCESS] [VERIFY] 数据验证通过: 表 user_entity 有 1523 条记录
[2026-04-06T03:01:25Z] [INFO] [CLEANUP] 清理临时数据库: test_restore_keycloak_db
[2026-04-06T03:01:26Z] [SUCCESS] [ALL] 测试完成，总耗时: 71 秒
```

### 6.2 日志文件管理

**日志轮转**：

```bash
# logrotate 配置
/logs/weekly-verify.log {
  weekly
  rotate 4
  compress
  delaycompress
  missingok
  notifempty
  create 0640 root root
}
```

**日志保留策略**：
- 成功日志：保留 7 天
- 失败日志：保留 30 天
- 所有日志压缩归档

---

## 7. 测试策略研究

### 7.1 单元测试设计

**测试文件结构**：

```
scripts/backup/tests/
├── test_weekly_verify.sh          # 主测试脚本
├── fixtures/
│   ├── backup_test.dump           # 测试备份文件
│   └── checksum_test.sha256       # 测试校验和
└── mocks/
    └── mock_cloud.sh              # Mock 云操作
```

**测试用例**：

```bash
test_download_backup() {
  # Mock download_backup 函数
  mock_download_backup() {
    echo "/tmp/test_backup.dump"
  }

  # 测试下载
  local result=$(download_with_retry "test_db_20260406_030000.dump")
  assert_equals "/tmp/test_backup.dump" "$result"
}

test_verify_table_count() {
  # 创建测试数据库
  create_test_db "test_verify_tables"

  # 添加测试表
  psql -d "test_verify_tables" -c "CREATE TABLE test_table (id INT);"

  # 测试验证
  verify_table_count "test_verify_tables"
  assert_equals 0 $?

  # 清理
  drop_test_db "test_verify_tables"
}
```

### 7.2 集成测试设计

**端到端测试流程**：

```bash
test_e2e_verification() {
  echo "=== 端到端验证测试 ==="

  # 1. 创建测试备份
  create_test_backup

  # 2. 上传到 B2（测试环境）
  upload_test_backup

  # 3. 运行验证测试
  run_weekly_verification

  # 4. 验证结果
  assert_equals 0 $?

  # 5. 清理
  cleanup_test_resources
}
```

---

## 8. 性能优化研究

### 8.1 并行测试

**多数据库并行验证**：

```bash
verify_all_databases() {
  local databases=("$@")
  local pids=()

  # 并行启动验证
  for db in "${databases[@]}"; do
    verify_single_database "$db" &
    pids+=($!)
  done

  # 等待所有验证完成
  local failed=0
  for pid in "${pids[@]}"; do
    wait $pid || ((failed++))
  done

  return $failed
}
```

### 8.2 资源限制

**Docker 资源限制**：

```bash
docker run --rm \
  --memory="2g" \
  --cpus="2" \
  --network host \
  noda-backup-test:latest \
  bash /scripts/test-verify-weekly.sh
```

---

## 9. 安全性研究

### 9.1 凭证管理

**最佳实践**：

1. **环境变量**：所有凭证通过环境变量传入
2. **Docker secrets**：敏感信息使用 Docker secrets
3. **最小权限**：B2 Application Key 仅包含必要权限
4. **审计日志**：记录所有数据库操作

### 9.2 数据库安全

**防止误删除**：

```bash
# 严格的数据库名验证
validate_test_db_name() {
  local db_name=$1

  # 检查前缀
  if [[ ! $db_name =~ ^test_restore_ ]]; then
    log_error "无效的测试数据库名: $db_name"
    return 1
  fi

  # 检查不在生产数据库列表中
  local prod_dbs=("keycloak_db" "findclass_db" "postgres")
  for prod_db in "${prod_dbs[@]}"; do
    if [[ "$db_name" == "$prod_db" ]]; then
      log_error "拒绝删除生产数据库: $db_name"
      return 1
    fi
  done

  return 0
}
```

---

## 10. 技术风险与缓解

| 风险 | 影响 | 概率 | 缓解措施 |
|------|------|------|----------|
| Docker 镜像构建失败 | 高 | 低 | 使用官方基础镜像，提前测试 |
| 网络连接失败 | 中 | 中 | 3 次重试 + 超时保护 |
| 临时数据库命名冲突 | 高 | 低 | 严格命名规范 + 冲突检测 |
| 磁盘空间不足 | 中 | 中 | 测试前检查 + 自动清理 |
| 超时导致资源泄漏 | 高 | 低 | 双重超时保护 + 强制清理 |
| 误删除生产数据库 | 高 | 极低 | 严格命名验证 + 确认提示 |

---

## 11. 技术决策总结

### 核心技术栈

- **基础镜像**：`postgres:15-alpine`
- **云存储**：Backblaze B2 + rclone
- **验证工具**：pg_restore, psql, sha256sum
- **超时管理**：Bash timeout + Docker 容器超时
- **调度方式**：Jenkins（首选）/ cron（备选）
- **日志格式**：结构化日志 + JSON 元数据

### 关键技术点

1. **Docker 容器化**：隔离测试环境，包含所有必需工具
2. **多层验证**：文件 → 校验和 → 结构 → 数据
3. **超时保护**：双重超时机制（Bash + Docker）
4. **错误恢复**：重试机制 + 失败保留
5. **资源管理**：自动清理 + 磁盘空间检查
6. **安全性**：环境变量 + 命名验证 + 最小权限

---

## 12. 后续工作

**技术研究已完成，下一步**：
1. ✅ 创建详细执行计划（PLAN.md）
2. ✅ 分解为 Waves 和 Tasks
3. ✅ 开始实现阶段

---

**研究总结**：Phase 4 的技术路线已明确，采用 Docker 容器化 + 多层验证 + 超时保护的策略，确保自动化测试的可靠性和安全性。所有关键技术点已验证，准备进入执行阶段。
