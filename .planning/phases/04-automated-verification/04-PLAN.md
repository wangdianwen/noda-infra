# Phase 4 执行计划：自动化验证测试

**阶段**: Phase 4 - 自动化验证测试
**计划日期**: 2026-04-06
**预计时间**: 6-10 小时
**状态**: 准备执行

---

## 执行概述

Phase 4 将创建每周自动执行的备份验证测试系统，确保备份文件在需要时可以可靠恢复。采用独立 Docker 容器 + 多层验证 + 超时保护的策略，确保测试的可靠性和安全性。

### 核心目标

1. ✅ 每周自动从 B2 下载最新备份
2. ✅ 恢复到临时数据库并验证完整性
3. ✅ 验证后自动清理临时资源
4. ✅ 失败时输出明确错误信息和退出码

### 执行策略

**分 4 个 Waves 执行**：
- **Wave 0**：基础设施准备（Docker 镜像构建）
- **Wave 1**：核心验证库实现（lib/test-verify.sh）
- **Wave 2**：主测试脚本实现（test-verify-weekly.sh）
- **Wave 3**：测试和调度集成

---

## Wave 0: 基础设施准备（独立，30 分钟）

**目标**：构建测试容器镜像，准备测试环境

### Task 0.1: 创建 Dockerfile（15 分钟）

**文件**：`scripts/backup/docker/Dockerfile.test-verify`

**内容**：
```dockerfile
FROM postgres:15-alpine

# 安装必需工具
RUN apk add --no-cache \
    rclone \
    coreutils \
    bash \
    jq \
    bc \
    openssl

# 创建脚本目录
RUN mkdir -p /scripts/lib

# 复制脚本文件
COPY scripts/backup/lib/*.sh /scripts/lib/
COPY scripts/backup/test-verify-weekly.sh /scripts/

# 设置工作目录
WORKDIR /scripts

# 设置权限
RUN chmod +x /scripts/*.sh /scripts/lib/*.sh

# 验证安装
RUN rclone version && \
    psql --version && \
    pg_restore --version

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD pg_isready -h ${POSTGRES_HOST} || exit 1

# 默认命令
CMD ["/bin/bash"]
```

**验收标准**：
- ✅ Dockerfile 创建成功
- ✅ 包含所有必需工具（rclone, psql, pg_restore）
- ✅ 镜像大小 < 300 MB

### Task 0.2: 构建和测试镜像（15 分钟）

**操作**：
```bash
# 构建镜像
docker build -f scripts/backup/docker/Dockerfile.test-verify -t noda-backup-test:latest .

# 测试镜像
docker run --rm noda-backup-test:latest bash -c "
  rclone version
  psql --version
  pg_restore --version
  sha256sum --version
"

# 验证环境变量
docker run --rm -e TEST_VAR=hello noda-backup-test:latest bash -c "
  echo \$TEST_VAR
"
```

**验收标准**：
- ✅ 镜像构建成功
- ✅ 所有工具版本正确
- ✅ 环境变量传递正常

---

## Wave 1: 核心验证库实现（依赖 Wave 0，2-3 小时）

**目标**：实现验证测试的核心库函数

### Task 1.1: 扩展常量定义（30 分钟）

**文件**：`scripts/backup/lib/constants.sh`

**修改内容**：
```bash
# Phase 4 特定退出码
readonly EXIT_TIMEOUT=5
readonly EXIT_DOWNLOAD_FAILED=11
readonly EXIT_RESTORE_TEST_FAILED=12
readonly EXIT_VERIFY_TEST_FAILED=13
readonly EXIT_CLEANUP_TEST_FAILED=14

# Phase 4 测试配置
readonly TEST_DB_PREFIX="test_restore_"
readonly TEST_TIMEOUT=3600  # 1 小时
readonly TEST_LOG_DIR="/var/log/noda-backup-test"
readonly TEST_BACKUP_DIR="/tmp/test-verify"
readonly TEST_MAX_RETRIES=3
```

**验收标准**：
- ✅ 常量定义添加成功
- ✅ 与现有退出码不冲突
- ✅ 配置合理且文档完整

### Task 1.2: 实现验证测试库（2-2.5 小时）

**文件**：`scripts/backup/lib/test-verify.sh`

**功能清单**：

#### 1.1 测试数据库管理（30 分钟）

```bash
# 创建测试数据库
create_test_database() {
  local original_db=$1
  local test_db="${TEST_DB_PREFIX}${original_db}"

  log_info "创建测试数据库: $test_db"

  # 检查数据库是否已存在
  if psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
    -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname='$test_db'" | grep -q 1; then
    log_warn "测试数据库已存在，将删除重建: $test_db"
    drop_test_database "$test_db"
  fi

  # 创建测试数据库
  psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
    -d postgres -c "CREATE DATABASE $test_db"

  log_success "测试数据库创建成功: $test_db"
  echo "$test_db"
}

# 删除测试数据库
drop_test_database() {
  local test_db=$1

  # 验证数据库名称
  if [[ ! $test_db =~ ^test_restore_ ]]; then
    log_error "拒绝删除非测试数据库: $test_db"
    return 1
  fi

  log_info "删除测试数据库: $test_db"

  psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
    -d postgres -c "DROP DATABASE IF EXISTS $test_db"

  log_success "测试数据库已删除: $test_db"
}
```

#### 1.2 下载和恢复功能（45 分钟）

```bash
# 下载最新备份（带重试）
download_latest_backup() {
  local db_name=$1
  local max_retries=$TEST_MAX_RETRIES
  local attempt=1

  log_info "下载最新备份: $db_name"

  # 列出 B2 备份文件
  local backups=$(list_b2_backups | grep "$db_name" | sort -r | head -1)

  if [[ -z "$backups" ]]; then
    log_error "未找到 $db_name 的备份文件"
    return $EXIT_DOWNLOAD_FAILED
  fi

  # 提取文件名
  local filename=$(echo "$backups" | awk '{print $2}')

  # 下载（带重试）
  while [[ $attempt -le $max_retries ]]; do
    log_info "下载尝试 $attempt/$max_retries: $filename"

    local backup_file=$(download_backup "$filename" "$TEST_BACKUP_DIR")

    if [[ -f "$backup_file" ]]; then
      log_success "下载成功: $backup_file"
      echo "$backup_file"
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

# 恢复到测试数据库
restore_to_test_database() {
  local backup_file=$1
  local test_db=$2

  log_info "恢复到测试数据库: $test_db"
  log_info "备份文件: $backup_file"

  # 验证备份文件
  if ! verify_backup_integrity "$backup_file"; then
    log_error "备份文件验证失败"
    return $EXIT_RESTORE_TEST_FAILED
  fi

  # 恢复数据库
  local file_ext="${backup_file##*.}"

  if [[ "$file_ext" == "dump" ]]; then
    if pg_restore -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
      -d "$test_db" -j 4 "$backup_file"; then
      log_success "数据恢复成功"
    else
      log_error "数据恢复失败"
      return $EXIT_RESTORE_TEST_FAILED
    fi
  else
    if psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
      -d "$test_db" -f "$backup_file"; then
      log_success "数据恢复成功"
    else
      log_error "数据恢复失败"
      return $EXIT_RESTORE_TEST_FAILED
    fi
  fi
}
```

#### 1.3 多层验证功能（45 分钟）

```bash
# 验证表数量
verify_table_count() {
  local test_db=$1
  local min_tables=1

  log_info "验证表数量..."

  local count=$(psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
    -d "$test_db" -t -c "
      SELECT COUNT(*)
      FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE';
    ")

  if [[ $count -ge $min_tables ]]; then
    log_success "表数量验证通过: $count 个表"
    return 0
  else
    log_error "表数量验证失败: 仅 $count 个表（至少需要 $min_tables 个）"
    return $EXIT_VERIFY_TEST_FAILED
  fi
}

# 验证数据存在性
verify_data_exists() {
  local test_db=$1

  log_info "验证数据存在性..."

  # 获取第一个有数据的表
  local table=$(psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
    -d "$test_db" -t -c "
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE'
      LIMIT 1;
    " | xargs)

  if [[ -z "$table" ]]; then
    log_error "未找到任何表"
    return $EXIT_VERIFY_TEST_FAILED
  fi

  # 检查记录数
  local count=$(psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
    -d "$test_db" -t -c "
      SELECT COUNT(*) FROM $table;
    ")

  if [[ $count -gt 0 ]]; then
    log_success "数据验证通过: 表 $table 有 $count 条记录"
    return 0
  else
    log_error "数据验证失败: 表 $table 无数据"
    return $EXIT_VERIFY_TEST_FAILED
  fi
}

# 综合验证
verify_test_restore() {
  local test_db=$1
  local backup_file=$2

  log_info "开始综合验证..."

  # Layer 1: 文件完整性
  log_info "Layer 1: 文件完整性验证"
  if ! verify_backup_readable "$backup_file"; then
    return $EXIT_VERIFY_TEST_FAILED
  fi

  # Layer 2: 数据结构
  log_info "Layer 2: 数据结构验证"
  if ! verify_table_count "$test_db"; then
    return $EXIT_VERIFY_TEST_FAILED
  fi

  # Layer 3: 数据完整性
  log_info "Layer 3: 数据完整性验证"
  if ! verify_data_exists "$test_db"; then
    return $EXIT_VERIFY_TEST_FAILED
  fi

  log_success "综合验证通过"
  return 0
}
```

**验收标准**：
- ✅ 所有函数实现完成
- ✅ 函数遵循现有代码风格
- ✅ 错误处理和日志记录完整

### Task 1.3: 更新配置库（30 分钟）

**文件**：`scripts/backup/lib/config.sh`

**添加函数**：
```bash
# 获取测试数据库列表
get_test_databases() {
  local db_list=${TEST_DATABASES:-"keycloak_db findclass_db"}
  echo "$db_list"
}

# 获取测试超时时间
get_test_timeout() {
  echo ${TEST_TIMEOUT:-3600}
}

# 获取测试日志目录
get_test_log_dir() {
  echo ${TEST_LOG_DIR:-"/var/log/noda-backup-test"}
}
```

**验收标准**：
- ✅ 配置函数添加成功
- ✅ 支持环境变量覆盖默认值

---

## Wave 2: 主测试脚本实现（依赖 Wave 1，2-3 小时）

**目标**：实现主测试脚本，整合所有功能

### Task 2.1: 创建主测试脚本框架（30 分钟）

**文件**：`scripts/backup/test-verify-weekly.sh`

**框架结构**：
```bash
#!/bin/bash
set -euo pipefail

# ============================================
# Noda 数据库备份系统 - 每周验证测试
# ============================================
# 功能：每周自动从 B2 下载最新备份，恢复到临时数据库并验证
# 作者：Noda 团队
# 版本：1.0.0
# ============================================

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载依赖库
source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/test-verify.sh"

# 全局变量
TEST_START_TIME=$(date +%s)
TEST_STATUS="unknown"
CLEANUP_NEEDED=false

# ============================================
# 清理函数
# ============================================

cleanup() {
  local exit_code=$?

  if [[ "$CLEANUP_NEEDED" == "true" ]]; then
    log_info "开始清理临时资源..."

    # 清理临时数据库
    if [[ -n "$TEST_DB_NAME" ]]; then
      if [[ "$exit_code" -eq 0 ]]; then
        drop_test_database "$TEST_DB_NAME" 2>/dev/null || true
      else
        log_warn "测试失败，保留临时数据库供调试: $TEST_DB_NAME"
      fi
    fi

    # 清理临时文件
    rm -rf "$TEST_BACKUP_DIR" 2>/dev/null || true
  fi

  log_info "测试结束，退出码: $exit_code"
  exit $exit_code
}

# 捕获中断信号
trap cleanup EXIT INT TERM

# ============================================
# 超时处理
# ============================================

timeout_handler() {
  log_error "测试超时（${TEST_TIMEOUT}秒）"
  TEST_STATUS="timeout"

  # 强制清理
  cleanup_on_timeout

  exit $EXIT_TIMEOUT
}

# 设置超时
trap timeout_handler ALRM
timeout $TEST_TIMEOUT $$ 2>/dev/null || true

# ============================================
# 主函数
# ============================================

main() {
  log_info "=========================================="
  log_info "每周备份验证测试开始"
  log_info "=========================================="

  # 解析命令行参数
  parse_arguments "$@"

  # 环境检查
  check_environment

  # 获取测试数据库列表
  local databases=$(get_test_databases)

  # 测试所有数据库
  for db in $databases; do
    test_single_database "$db"
  done

  # 输出总结
  print_summary

  log_success "=========================================="
  log_success "所有测试通过"
  log_success "=========================================="
}

# 执行主函数
main "$@"
```

**验收标准**：
- ✅ 脚本框架创建成功
- ✅ 包含所有必需的导入和变量
- ✅ 清理和超时处理机制就绪

### Task 2.2: 实现核心测试流程（1.5-2 小时）

**函数实现**：

#### 2.1 环境检查（30 分钟）

```bash
check_environment() {
  log_info "检查测试环境..."

  # 检查 PostgreSQL 连接
  if ! pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER"; then
    log_error "PostgreSQL 连接失败"
    exit $EXIT_CONNECTION_FAILED
  fi

  # 检查磁盘空间
  local available_space=$(df -h "$TEST_BACKUP_DIR" | tail -1 | awk '{print $4}')
  log_info "可用磁盘空间: $available_space"

  # 检查 B2 配置
  if [[ -z "$B2_ACCOUNT_ID" ]] || [[ -z "$B2_APPLICATION_KEY" ]]; then
    log_error "B2 配置缺失"
    exit $EXIT_INVALID_ARGS
  fi

  # 创建临时目录
  mkdir -p "$TEST_BACKUP_DIR"
  mkdir -p "$(get_test_log_dir)"

  log_success "环境检查通过"
}
```

#### 2.2 单数据库测试（1 小时）

```bash
test_single_database() {
  local db_name=$1
  local db_start_time=$(date +%s)

  log_info "=========================================="
  log_info "测试数据库: $db_name"
  log_info "=========================================="

  CLEANUP_NEEDED=true

  # 1. 下载最新备份
  log_info "步骤 1/4: 下载最新备份"
  local backup_file=$(download_latest_backup "$db_name")

  if [[ ! -f "$backup_file" ]]; then
    log_error "下载失败: $db_name"
    TEST_STATUS="download_failed"
    return $EXIT_DOWNLOAD_FAILED
  fi

  # 2. 创建测试数据库
  log_info "步骤 2/4: 创建测试数据库"
  local test_db=$(create_test_database "$db_name")
  TEST_DB_NAME="$test_db"

  # 3. 恢复数据
  log_info "步骤 3/4: 恢复数据"
  if ! restore_to_test_database "$backup_file" "$test_db"; then
    log_error "恢复失败: $db_name"
    TEST_STATUS="restore_failed"
    return $EXIT_RESTORE_TEST_FAILED
  fi

  # 4. 验证数据
  log_info "步骤 4/4: 验证数据"
  if ! verify_test_restore "$test_db" "$backup_file"; then
    log_error "验证失败: $db_name"
    TEST_STATUS="verify_failed"
    return $EXIT_VERIFY_TEST_FAILED
  fi

  # 清理当前数据库
  drop_test_database "$test_db"
  rm -f "$backup_file"

  CLEANUP_NEEDED=false
  TEST_DB_NAME=""

  local db_end_time=$(date +%s)
  local db_duration=$((db_end_time - db_start_time))

  log_success "=========================================="
  log_success "数据库测试成功: $db_name (耗时: ${db_duration}s)"
  log_success "=========================================="
}
```

#### 2.3 总结输出（30 分钟）

```bash
print_summary() {
  local test_end_time=$(date +%s)
  local total_duration=$((test_end_time - TEST_START_TIME))

  log_info "=========================================="
  log_info "测试总结"
  log_info "=========================================="
  log_info "总耗时: ${total_duration} 秒"
  log_info "状态: $TEST_STATUS"
  log_info "测试时间: $(date -u -d @$TEST_START_TIME +'%Y-%m-%d %H:%M:%S UTC')"
  log_info "=========================================="
}
```

**验收标准**：
- ✅ 核心流程实现完整
- ✅ 错误处理和日志记录完善
- ✅ 清理机制可靠

### Task 2.3: 参数解析和配置（30 分钟）

**实现**：
```bash
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --help)
        show_usage
        exit 0
        ;;
      --databases)
        TEST_DATABASES="$2"
        shift 2
        ;;
      --timeout)
        TEST_TIMEOUT="$2"
        shift 2
        ;;
      --log-level)
        LOG_LEVEL="$2"
        shift 2
        ;;
      *)
        log_error "未知参数: $1"
        show_usage
        exit $EXIT_INVALID_ARGS
        ;;
    esac
  done
}

show_usage() {
  cat <<EOF
每周备份验证测试脚本

用法:
  $0 [选项]

选项:
  --help              显示此帮助信息
  --databases DBS     测试数据库列表（空格分隔）
  --timeout SECONDS   超时时间（默认: 3600）
  --log-level LEVEL   日志级别（DEBUG/INFO/WARN/ERROR）

示例:
  $0 --databases "keycloak_db findclass_db"
  $0 --timeout 7200 --log-level DEBUG

环境变量:
  POSTGRES_HOST       PostgreSQL 主机
  POSTGRES_PORT       PostgreSQL 端口
  POSTGRES_USER       PostgreSQL 用户
  POSTGRES_PASSWORD   PostgreSQL 密码
  B2_ACCOUNT_ID       Backblaze B2 Account ID
  B2_APPLICATION_KEY  Backblaze B2 Application Key
  B2_BUCKET_NAME      Backblaze B2 Bucket 名称
EOF
}
```

**验收标准**：
- ✅ 参数解析正确
- ✅ 帮助信息完整
- ✅ 环境变量支持

---

## Wave 3: 测试和调度集成（依赖 Wave 2，1-2 小时）

**目标**：编写测试用例，集成到调度系统

### Task 3.1: 编写单元测试（45 分钟）

**文件**：`scripts/backup/tests/test_weekly_verify.sh`

**测试用例**：
```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/constants.sh"
source "$SCRIPT_DIR/../lib/test-verify.sh"

# 测试计数器
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# 测试辅助函数
assert_equals() {
  local expected=$1
  local actual=$2
  local message=${3:-"Assertion failed"}

  ((TESTS_RUN++))

  if [[ "$expected" == "$actual" ]]; then
    echo "✅ PASS: $message"
    ((TESTS_PASSED++))
  else
    echo "❌ FAIL: $message"
    echo "   Expected: $expected"
    echo "   Actual: $actual"
    ((TESTS_FAILED++))
  fi
}

assert_success() {
  local exit_code=$1
  local message=${2:-"Command should succeed"}

  ((TESTS_RUN++))

  if [[ $exit_code -eq 0 ]]; then
    echo "✅ PASS: $message"
    ((TESTS_PASSED++))
  else
    echo "❌ FAIL: $message (exit code: $exit_code)"
    ((TESTS_FAILED++))
  fi
}

# 测试用例
test_test_database_naming() {
  echo "测试: 测试数据库名称规范"

  local result="test_restore_keycloak_db"
  assert_equals "$result" "test_restore_keycloak_db" "测试数据库前缀正确"
}

test_table_count_verification() {
  echo "测试: 表数量验证"

  # 创建测试数据库
  local test_db="test_verify_table_count"
  createdb "$test_db" 2>/dev/null || true

  # 创建测试表
  psql -d "$test_db" -c "CREATE TABLE test_table (id INT);" >/dev/null 2>&1

  # 验证
  verify_table_count "$test_db"
  local result=$?

  # 清理
  dropdb "$test_db" 2>/dev/null || true

  assert_success $result "表数量验证成功"
}

test_data_existence_verification() {
  echo "测试: 数据存在性验证"

  # 创建测试数据库
  local test_db="test_verify_data_exists"
  createdb "$test_db" 2>/dev/null || true

  # 创建测试表并插入数据
  psql -d "$test_db" -c "CREATE TABLE test_table (id INT);" >/dev/null 2>&1
  psql -d "$test_db" -c "INSERT INTO test_table VALUES (1);" >/dev/null 2>&1

  # 验证
  verify_data_exists "$test_db"
  local result=$?

  # 清理
  dropdb "$test_db" 2>/dev/null || true

  assert_success $result "数据存在性验证成功"
}

# 运行所有测试
main() {
  echo "=========================================="
  echo "Phase 4 单元测试"
  echo "=========================================="
  echo ""

  test_test_database_naming
  test_table_count_verification
  test_data_existence_verification

  echo ""
  echo "=========================================="
  echo "测试结果"
  echo "=========================================="
  echo "运行: $TESTS_RUN"
  echo "通过: $TESTS_PASSED"
  echo "失败: $TESTS_FAILED"
  echo "=========================================="

  if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
  fi
}

main
```

**验收标准**：
- ✅ 所有测试用例实现
- ✅ 测试覆盖核心功能
- ✅ 测试可以独立运行

### Task 3.2: 创建 Jenkins 集成（30 分钟）

**文件**：`scripts/backup/Jenkinsfile.weekly-verify`

**内容**：
```groovy
pipeline {
  agent any

  triggers {
    // 每周日凌晨 3:00 执行
    cron('0 3 * * 0')
  }

  environment {
    POSTGRES_HOST = 'host.docker.internal'
    POSTGRES_PORT = '5432'
    POSTGRES_USER = credentials('postgres-user')
    POSTGRES_PASSWORD = credentials('postgres-password')
    B2_ACCOUNT_ID = credentials('b2-account-id')
    B2_APPLICATION_KEY = credentials('b2-application-key')
    B2_BUCKET_NAME = 'noda-backups'
  }

  stages {
    stage('Build Test Image') {
      steps {
        script {
          docker.build('noda-backup-test:latest', \
            '-f scripts/backup/docker/Dockerfile.test-verify .')
        }
      }
    }

    stage('Run Weekly Verification') {
      steps {
        script {
          docker.image('noda-backup-test:latest').inside("-e POSTGRES_HOST=host.docker.internal") {
            sh '''
              export POSTGRES_HOST=$POSTGRES_HOST
              export POSTGRES_USER=$POSTGRES_USER
              export POSTGRES_PASSWORD=$POSTGRES_PASSWORD
              export B2_ACCOUNT_ID=$B2_ACCOUNT_ID
              export B2_APPLICATION_KEY=$B2_APPLICATION_KEY
              export B2_BUCKET_NAME=$B2_BUCKET_NAME

              bash /scripts/test-verify-weekly.sh \
                --databases "keycloak_db findclass_db" \
                --timeout 3600 \
                --log-level INFO
            '''
          }
        }
      }
    }

    stage('Archive Logs') {
      steps {
        archiveArtifacts artifacts: 'logs/weekly-verify-*.log', \
          fingerprint: true, \
          allowEmptyArchive: true
      }
    }
  }

  post {
    success {
      echo '✅ 每周备份验证测试成功'
    }
    failure {
      echo '❌ 每周备份验证测试失败'
      emailext(
        subject: "❌ 备份验证失败: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
        body: """
          备份验证测试失败

          项目: ${env.JOB_NAME}
          构建: #${env.BUILD_NUMBER}
          时间: ${new Date().toString()}
          日志: ${env.BUILD_URL}console

          请立即检查备份系统状态。
        """,
        to: 'ops@example.com',
        mimeType: 'text/html'
      )
    }
    always {
      sh 'docker prune -f || true'
    }
  }
}
```

**验收标准**：
- ✅ Jenkinsfile 创建成功
- ✅ 支持定时触发
- ✅ 失败告警配置完整

### Task 3.3: 创建 Cron 备选方案（15 分钟）

**文件**：`scripts/backup/cron/weekly-verify.cron`

**内容**：
```cron
# Noda 数据库备份系统 - 每周验证测试
# 每周日凌晨 3:00 执行

0 3 * * 0 cd /path/to/noda-infra && \
  docker run --rm \
    --network host \
    -v $(pwd)/logs:/logs \
    -e POSTGRES_HOST=host.docker.internal \
    -e POSTGRES_USER=${POSTGRES_USER} \
    -e POSTGRES_PASSWORD=${POSTGRES_PASSWORD} \
    -e B2_ACCOUNT_ID=${B2_ACCOUNT_ID} \
    -e B2_APPLICATION_KEY=${B2_APPLICATION_KEY} \
    -e B2_BUCKET_NAME=${B2_BUCKET_NAME} \
    noda-backup-test:latest \
    bash /scripts/test-verify-weekly.sh \
      --databases "keycloak_db findclass_db" \
      --timeout 3600 \
      --log-level INFO \
    >> /logs/weekly-verify.log 2>&1
```

**安装脚本**：
```bash
#!/bin/bash
# 安装 cron 任务

CRON_FILE="scripts/backup/cron/weekly-verify.cron"
LOG_DIR="/var/log/noda-backup-test"

# 创建日志目录
sudo mkdir -p "$LOG_DIR"
sudo chown $USER:$USER "$LOG_DIR"

# 安装 cron 任务
crontab "$CRON_FILE"

echo "✅ Cron 任务已安装"
echo "日志目录: $LOG_DIR"
echo ""
echo "当前 cron 任务列表:"
crontab -l
```

**验收标准**：
- ✅ Cron 任务配置正确
- ✅ 环境变量安全传递
- ✅ 日志输出配置完整

### Task 3.4: 更新文档（30 分钟）

**文件**：`README.md`

**添加内容**：
```markdown
## 每周验证测试

### 功能说明

系统每周自动从 B2 下载最新备份，恢复到临时数据库并验证数据完整性。

### 执行方式

#### 方式 1: Jenkins（推荐）

Jenkins 会每周日凌晨 3:00 自动执行测试。

#### 方式 2: Cron

```bash
# 安装 cron 任务
bash scripts/backup/cron/install-weekly-verify.sh

# 查看日志
tail -f /var/log/noda-backup-test/weekly-verify.log
```

#### 方式 3: 手动执行

```bash
# 使用 Docker
docker run --rm \
  --network host \
  -e POSTGRES_HOST=host.docker.internal \
  -e POSTGRES_USER=$POSTGRES_USER \
  -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
  -e B2_ACCOUNT_ID=$B2_ACCOUNT_ID \
  -e B2_APPLICATION_KEY=$B2_APPLICATION_KEY \
  noda-backup-test:latest \
  bash /scripts/test-verify-weekly.sh
```

### 验证层次

1. **文件完整性**：SHA256 校验和验证
2. **备份可读性**：pg_restore --list
3. **数据结构**：表数量检查
4. **数据完整性**：记录存在性验证

### 错误处理

- 下载失败：自动重试 3 次
- 恢复失败：保留临时数据库供调试
- 验证失败：输出详细错误信息
- 超时保护：1 小时超时 + 强制清理

### 日志位置

- 测试日志：`/var/log/noda-backup-test/`
- 备份日志：`/var/log/noda-backup/`
```

**验收标准**：
- ✅ 文档更新完整
- ✅ 使用说明清晰
- ✅ 故障排查指南完善

---

## 依赖关系图

```
Wave 0: 基础设施准备
    ├─ Task 0.1: Dockerfile
    └─ Task 0.2: 构建镜像
         │
         ▼
Wave 1: 核心验证库
    ├─ Task 1.1: 扩展常量
    ├─ Task 1.2: 验证库函数
    └─ Task 1.3: 更新配置库
         │
         ▼
Wave 2: 主测试脚本
    ├─ Task 2.1: 脚本框架
    ├─ Task 2.2: 核心流程
    └─ Task 2.3: 参数解析
         │
         ▼
Wave 3: 测试和集成
    ├─ Task 3.1: 单元测试
    ├─ Task 3.2: Jenkins 集成
    ├─ Task 3.3: Cron 备选
    └─ Task 3.4: 更新文档
```

---

## 验收标准

### Wave 0 验收

- [ ] Docker 镜像构建成功
- [ ] 镜像大小 < 300 MB
- [ ] 所有工具版本正确

### Wave 1 验收

- [ ] 所有库函数实现完成
- [ ] 代码风格与现有代码一致
- [ ] 错误处理和日志记录完整

### Wave 2 验收

- [ ] 主测试脚本可以独立运行
- [ ] 测试流程完整（下载 → 恢复 → 验证 → 清理）
- [ ] 超时保护机制生效

### Wave 3 验收

- [ ] 所有单元测试通过
- [ ] Jenkins 集成配置正确
- [ ] Cron 备选方案可用
- [ ] 文档更新完整

---

## 风险和缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| Docker 镜像构建失败 | 高 | 使用官方基础镜像，提前测试 |
| B2 下载失败 | 中 | 3 次重试 + 详细错误日志 |
| 临时数据库命名冲突 | 高 | 严格命名规范 + 冲突检测 |
| 超时导致资源泄漏 | 高 | 双重超时保护 + 强制清理 |
| Jenkins 配置错误 | 中 | 先手动测试，再集成到 Jenkins |

---

## 预期成果

### 交付物

1. ✅ Docker 镜像：`noda-backup-test:latest`
2. ✅ 验证库：`scripts/backup/lib/test-verify.sh`
3. ✅ 主测试脚本：`scripts/backup/test-verify-weekly.sh`
4. ✅ 单元测试：`scripts/backup/tests/test_weekly_verify.sh`
5. ✅ Jenkins 集成：`scripts/backup/Jenkinsfile.weekly-verify`
6. ✅ Cron 配置：`scripts/backup/cron/weekly-verify.cron`
7. ✅ 更新文档：`README.md`

### 成功指标

- ✅ 所有测试用例通过
- ✅ 端到端测试成功
- ✅ Jenkins 定时任务正常运行
- ✅ 文档完整且准确

---

## 后续步骤

**执行完成后**：
1. ✅ 运行完整测试套件
2. ✅ 部署到 Jenkins
3. ✅ 监控首次自动执行
4. ✅ 验证告警机制

**进入 Phase 5**：
- Phase 4 完成后，开始 Phase 5（监控与告警）规划

---

**计划总结**：Phase 4 分 4 个 Waves 执行，预计 6-10 小时完成。采用 Docker 容器化 + 多层验证 + 超时保护的策略，确保自动化测试的可靠性和安全性。所有任务都有明确的验收标准和风险缓解措施。
