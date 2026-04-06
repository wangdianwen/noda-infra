# Phase 5 执行计划：监控与告警

**阶段**: Phase 5 - 监控与告警
**计划日期**: 2026-04-06
**预计时间**: 3-5 小时
**状态**: 准备执行

---

## 执行概述

Phase 5 将为备份系统添加完整的监控和告警功能，包括结构化日志、邮件告警、耗时追踪和历史记录管理。采用轻量级实现，避免引入复杂依赖。

### 核心目标

1. ✅ 结构化日志输出（时间戳 + 结构化信息）
2. ✅ 邮件告警系统（失败告警 + 去重）
3. ✅ 耗时追踪系统（历史记录 + 异常检测）
4. ✅ 标准退出码（保持兼容性）

### 执行策略

**分 3 个 Waves 执行**：
- **Wave 0**：基础设施准备（mail 命令检查、jq 安装）
- **Wave 1**：核心功能实现（告警、指标、日志库）
- **Wave 2**：集成和测试（集成到所有脚本）

---

## Wave 0: 基础设施准备（独立，15 分钟）

**目标**：检查和安装必要的工具

### Task 0.1: 检查 mail 命令（5 分钟）

**验收标准**：
- ✅ 检测 mail 命令是否可用
- ✅ 提供安装指南（如果未安装）

**步骤**：
```bash
# 检查 mail 命令
if ! command -v mail >/dev/null 2>&1; then
  echo "❌ mail 命令未安装"
  echo "安装方法："
  echo "  macOS: brew install postfix"
  echo "  Ubuntu: sudo apt-get install mailutils"
  echo "  CentOS: sudo yum install postfix"
fi
```

### Task 0.2: 检查 jq 命令（5 分钟）

**验收标准**：
- ✅ 检测 jq 命令是否可用
- ✅ 提供安装指南（如果未安装）

**步骤**：
```bash
# 检查 jq 命令
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq 命令未安装"
  echo "安装方法："
  echo "  macOS: brew install jq"
  echo "  Ubuntu: sudo apt-get install jq"
  echo "  CentOS: sudo yum install jq"
fi
```

### Task 0.3: 创建目录结构（5 分钟）

**验收标准**：
- ✅ 创建历史记录目录
- ✅ 设置正确的文件权限

**步骤**：
```bash
# 创建目录
sudo mkdir -p /var/lib/postgresql/backup
sudo chown $USER:$USER /var/lib/postgresql/backup
chmod 755 /var/lib/postgresql/backup
```

---

## Wave 1: 核心功能实现（依赖 Wave 0，2-3 小时）

**目标**：实现告警、指标和日志库

### Task 1.1: 扩展常量定义（15 分钟）

**文件**：`lib/constants.sh`

**添加内容**：
```bash
# 告警配置
readonly ALERT_ENABLED=${ALERT_ENABLED:-true}
readonly ALERT_EMAIL=${ALERT_EMAIL:-""}
readonly ALERT_DEDUP_WINDOW=3600  # 1 小时

# 历史记录文件
readonly HISTORY_FILE="/var/lib/postgresql/backup/history.json"
readonly ALERT_HISTORY_FILE="/var/lib/postgresql/backup/alert_history.json"

# 指标配置
readonly METRICS_WINDOW_SIZE=10  # 最近 10 次
readonly METRICS_ANOMALY_THRESHOLD=50  # 50% 偏差
```

### Task 1.2: 实现告警库（1 小时）

**文件**：`lib/alert.sh`

**功能清单**：

#### 1.2.1 邮件发送函数（30 分钟）

```bash
# send_email - 发送邮件
# 参数：
#   $1: 收件人
#   $2: 主题
#   $3: 正文
send_email() {
  local recipient=$1
  local subject=$2
  local body=$3

  # 检查 mail 命令
  if ! command -v mail >/dev/null 2>&1; then
    log_error "mail 命令未安装，无法发送邮件"
    return 1
  fi

  # 发送邮件
  echo "$body" | mail -s "$subject" "$recipient"

  if [[ $? -eq 0 ]]; then
    log_info "邮件发送成功: $recipient"
  else
    log_error "邮件发送失败: $recipient"
  fi
}
```

#### 1.2.2 告警去重函数（30 分钟）

```bash
# should_send_alert - 检查是否应该发送告警
# 参数：
#   $1: 告警类型
#   $2: 数据库
# 返回：0（发送）或 1（跳过）
should_send_alert() {
  local alert_type=$1
  local database=$2
  local current_time=$(date +%s)

  # 初始化历史文件
  if [[ ! -f "$ALERT_HISTORY_FILE" ]]; then
    echo "[]" > "$ALERT_HISTORY_FILE"
    return 0
  fi

  # 查找最近的相同告警
  local last_alert
  last_alert=$(jq -r \
    ".[] | select(.type==\"$alert_type\" and .database==\"$database\") | .time" \
    "$ALERT_HISTORY_FILE" 2>/dev/null | tail -1)

  if [[ -z "$last_alert" ]]; then
    return 0  # 无历史记录
  fi

  # 检查时间窗口
  local time_diff=$((current_time - last_alert))
  if [[ $time_diff -ge $ALERT_DEDUP_WINDOW ]]; then
    return 0  # 超过去重窗口
  else
    log_info "跳过重复告警: $alert_type - $database"
    return 1  # 在窗口内
  fi
}

# record_alert - 记录告警
# 参数：
#   $1: 告警类型
#   $2: 数据库
record_alert() {
  local alert_type=$1
  local database=$2
  local current_time=$(date +%s)

  # 添加到历史记录
  local temp_file="${ALERT_HISTORY_FILE}.tmp"
  jq ". += [{\"type\":\"$alert_type\",\"database\":\"$database\",\"time\":$current_time}]" \
    "$ALERT_HISTORY_FILE" > "$temp_file" 2>/dev/null
  mv "$temp_file" "$ALERT_HISTORY_FILE"
}
```

#### 1.2.3 告警发送函数（30 分钟）

```bash
# send_alert - 发送告警
# 参数：
#   $1: 告警类型
#   $2: 数据库
#   $3: 告警消息
send_alert() {
  local alert_type=$1
  local database=$2
  local message=$3

  # 检查告警是否启用
  if [[ "$ALERT_ENABLED" != "true" ]]; then
    return 0
  fi

  # 检查收件人
  if [[ -z "$ALERT_EMAIL" ]]; then
    log_warn "ALERT_EMAIL 未设置，跳过告警"
    return 0
  fi

  # 检查去重
  if ! should_send_alert "$alert_type" "$database"; then
    return 0
  fi

  # 构建邮件内容
  local subject="[$alert_type] $database - $(date '+%Y-%m-%d %H:%M')"
  local body="备份系统告警

类型: $alert_type
数据库: $database
时间: $(date '+%Y-%m-%d %H:%M:%S UTC')

消息: $message

---
Noda 备份系统"

  # 发送邮件
  send_email "$ALERT_EMAIL" "$subject" "$body"

  # 记录告警
  record_alert "$alert_type" "$database"
}
```

### Task 1.3: 实现指标库（1 小时）

**文件**：`lib/metrics.sh`

**功能清单**：

#### 1.3.1 记录指标函数（30 分钟）

```bash
# record_metric - 记录指标
# 参数：
#   $1: 操作类型（backup, upload, verify）
#   $2: 数据库
#   $3: 耗时（秒）
#   $4: 文件大小（字节）
record_metric() {
  local operation=$1
  local database=$2
  local duration=$3
  local file_size=${4:-0}

  # 初始化历史文件
  if [[ ! -f "$HISTORY_FILE" ]]; then
    echo "[]" > "$HISTORY_FILE"
  fi

  # 构建新记录
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local new_record=$(cat <<EOF
{
  "timestamp": "$timestamp",
  "database": "$database",
  "operation": "$operation",
  "duration": $duration,
  "file_size": $file_size
}
EOF
)

  # 添加到历史文件
  local temp_file="${HISTORY_FILE}.tmp"
  jq ". += [$new_record]" "$HISTORY_FILE" > "$temp_file"
  mv "$temp_file" "$HISTORY_FILE"

  log_info "记录指标: $operation - $database - ${duration}s"
}
```

#### 1.3.2 计算平均值函数（30 分钟）

```bash
# calculate_average_duration - 计算平均耗时
# 参数：
#   $1: 数据库
#   $2: 操作类型
# 返回：平均耗时（秒）
calculate_average_duration() {
  local database=$1
  local operation=$2

  if [[ ! -f "$HISTORY_FILE" ]]; then
    echo "0"
    return
  fi

  # 获取最近 N 次记录
  local recent_records
  recent_records=$(jq \
    "[.[] | select(.database==\"$database\" and .operation==\"$operation\")] | reverse | .[0:$METRICS_WINDOW_SIZE]" \
    "$HISTORY_FILE" 2>/dev/null)

  # 计算平均值
  local sum
  sum=$(echo "$recent_records" | jq "[].duration | add" 2>/dev/null || echo "0")

  local count
  count=$(echo "$recent_records" | jq "length" 2>/dev/null || echo "0")

  if [[ $count -gt 0 && $sum -gt 0 ]]; then
    local average=$((sum / count))
    echo "$average"
  else
    echo "0"
  fi
}
```

#### 1.3.3 异常检测函数（30 分钟）

```bash
# check_duration_anomaly - 检查耗时异常
# 参数：
#   $1: 数据库
#   $2: 操作类型
#   $3: 当前耗时
check_duration_anomaly() {
  local database=$1
  local operation=$2
  local current_duration=$3

  # 计算历史平均值
  local average
  average=$(calculate_average_duration "$database" "$operation")

  if [[ $average -eq 0 ]]; then
    return 0  # 无历史数据
  fi

  # 计算偏差
  local deviation=$(( (current_duration - average) * 100 / average ))

  if [[ $deviation -gt $METRICS_ANOMALY_THRESHOLD ]]; then
    log_warn "耗时异常: $database - $operation"
    log_warn "  当前: ${current_duration}s, 平均: ${average}s, 偏差: +${deviation}%"

    # 发送告警
    send_alert "duration_anomaly" "$database" \
      "耗时异常 ($operation): 当前 ${current_duration}s，平均 ${average}s，偏差 +${deviation}%"

    return 1
  fi

  return 0
}
```

### Task 1.4: 扩展日志库（30 分钟）

**文件**：`lib/log.sh`

**修改内容**：
```bash
# 添加结构化日志函数
log_structured() {
  local level=$1
  local stage=$2
  local database=$3
  local message=$4
  local details=${5:-}

  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local log_line="[$timestamp] [$level] [$stage] [$database] $message"

  echo "$log_line"

  if [[ -n "$details" ]]; then
    echo "Details: $details"
  fi
}

# 使用示例（在现有函数中集成）
log_info_backup() {
  local database=$1
  local message=$2
  log_structured "INFO" "BACKUP" "$database" "$message"
}
```

---

## Wave 2: 集成和测试（依赖 Wave 1，1-2 小时）

**目标**：集成到所有脚本并测试

### Task 2.1: 集成到 backup-postgres.sh（30 分钟）

**修改点**：
1. 在主函数开始时记录开始时间
2. 每个阶段后记录指标
3. 失败时发送告警

**示例**：
```bash
main() {
  local start_time=$(date +%s)

  # 备份
  if ! backup_all_databases "$backup_dir" "$timestamp"; then
    send_alert "backup_failed" "all" "备份失败"
    exit $EXIT_BACKUP_FAILED
  fi

  local backup_end_time=$(date +%s)
  local backup_duration=$((backup_end_time - start_time))

  # 记录指标和检查异常
  for db in $DATABASES; do
    record_metric "backup" "$db" "$backup_duration"
    check_duration_anomaly "$db" "backup" "$backup_duration"
  done

  # ... 其他流程
}
```

### Task 2.2: 集成到 test-verify-weekly.sh（30 分钟）

**修改点**：
1. 添加耗时追踪
2. 验证失败时发送告警

**示例**：
```bash
test_single_database() {
  local db_name=$1
  local db_start_time=$(date +%s)

  # ... 测试流程

  local db_end_time=$(date +%s)
  local db_duration=$((db_end_time - db_start_time))

  # 记录指标
  record_metric "verify_test" "$db_name" "$db_duration"

  # 检查异常
  check_duration_anomaly "$db_name" "verify_test" "$db_duration"
}
```

### Task 2.3: 编写测试脚本（30 分钟）

**文件**：`tests/test_alert.sh`

**测试内容**：
```bash
#!/bin/bash
# 测试告警功能

source ../lib/alert.sh
source ../lib/metrics.sh

# 测试 1: 邮件发送
echo "测试 1: 邮件发送"
send_email "test@example.com" "测试邮件" "测试内容"

# 测试 2: 去重机制
echo "测试 2: 去重机制"
should_send_alert "test" "test_db"
record_alert "test" "test_db"
should_send_alert "test" "test_db"  # 应该跳过

# 测试 3: 指标记录
echo "测试 3: 指标记录"
record_metric "backup" "test_db" 60 1024000

# 测试 4: 平均值计算
echo "测试 4: 平均值计算"
calculate_average_duration "test_db" "backup"
```

### Task 2.4: 端到端测试（30 分钟）

**测试流程**：
1. 运行备份脚本
2. 验证日志输出
3. 验证指标记录
4. 验证异常检测
5. 验证告警发送

---

## 验收标准总览

### Wave 0
- [ ] mail 命令可用或提供安装指南
- [ ] jq 命令可用或提供安装指南
- [ ] 目录结构创建完成

### Wave 1
- [ ] lib/alert.sh 已创建
- [ ] lib/metrics.sh 已创建
- [ ] lib/log.sh 已扩展
- [ ] lib/constants.sh 已扩展

### Wave 2
- [ ] backup-postgres.sh 已集成
- [ ] test-verify-weekly.sh 已集成
- [ ] 测试脚本通过
- [ ] 端到端测试通过

---

## 风险和缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| mail 命令未安装 | 高 | 提供安装指南，可配置禁用 |
| jq 命令未安装 | 中 | 提供安装指南 |
| 历史文件损坏 | 低 | 异常时重建文件 |
| 告警泛滥 | 中 | 实现去重机制（1 小时） |
| 性能影响 | 低 | 异步发送邮件 |

---

## 预期成果

### 交付物

1. ✅ lib/alert.sh - 告警库（150 行）
2. ✅ lib/metrics.sh - 指标库（100 行）
3. ✅ lib/log.sh - 扩展日志库（+50 行）
4. ✅ lib/constants.sh - 扩展常量（+20 行）
5. ✅ tests/test_alert.sh - 测试脚本
6. ✅ 集成到所有主脚本

### 成功指标

- ✅ 所有日志带时间戳
- ✅ 备份失败发送邮件告警
- ✅ 耗时异常发送邮件警告
- ✅ 历史数据正确记录
- ✅ 告警去重机制生效

---

## 后续步骤

**执行完成后**：
1. ✅ 运行完整测试套件
2. ✅ 配置邮件接收地址
3. ✅ 监控首次告警
4. ✅ 验证去重机制

**进入生产环境**：
- Phase 5 完成后，整个备份系统已就绪
- 可以部署到生产环境

---

**计划总结**：Phase 5 分 3 个 Waves 执行，预计 3-5 小时完成。采用轻量级实现（mail + jq），避免引入复杂依赖。所有任务都有明确的验收标准和风险缓解措施。
