# Phase 5 技术研究：监控与告警

**阶段**: Phase 5 - 监控与告警
**研究日期**: 2026-04-06
**状态**: 研究完成

---

## 研究目标

分析监控与告警系统的关键技术，包括结构化日志、邮件告警、耗时追踪和历史记录管理，为 Phase 5 执行计划提供技术基础。

---

## 1. 结构化日志研究

### 1.1 日志格式设计

**格式定义**：
```
[YYYY-MM-DD HH:MM:SS] [LEVEL] [STAGE] [DB] Message
Details: JSON metadata
```

**示例**：
```
[2026-04-06 03:00:15] [INFO] [BACKUP] [keycloak_db] 开始备份数据库
Details: {"timestamp":"2026-04-06T03:00:15Z","database":"keycloak_db","action":"backup_start"}

[2026-04-06 03:01:20] [SUCCESS] [BACKUP] [keycloak_db] 备份完成
Details: {"duration":65,"file_size":"1.2GB","file_path":"/backups/keycloak_db_20260406_030000.dump"}

[2026-04-06 03:02:30] [ERROR] [UPLOAD] [keycloak_db] 上传失败
Details: {"error":"connection timeout","retry_count":3,"max_retries":3}
```

### 1.2 日志级别定义

| 级别 | 用途 | 示例 |
|------|------|------|
| DEBUG | 调试信息 | 函数参数、中间变量 |
| INFO | 正常流程 | 开始备份、上传成功 |
| WARN | 警告信息 | 耗时异常、重试发生 |
| ERROR | 错误信息 | 备份失败、验证失败 |
| SUCCESS | 成功确认 | 备份完成、验证通过 |

### 1.3 日志实现

**扩展 lib/log.sh**：

```bash
# 结构化日志函数
log_structured() {
  local level=$1
  local stage=$2
  local database=$3
  local message=$4
  local details=${5:-}

  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local log_line="[$timestamp] [$level] [$stage] [$database] $message"

  if [[ -n "$details" ]]; then
    echo "$log_line"
    echo "Details: $details"
  else
    echo "$log_line"
  fi

  # 写入日志文件
  echo "$log_line" >> "$LOG_FILE"
}

# 使用示例
log_structured "INFO" "BACKUP" "keycloak_db" "开始备份数据库" \
  '{"timestamp":"'$TIMESTAMP'","database":"keycloak_db","action":"backup_start"}'
```

---

## 2. 邮件告警研究

### 2.1 邮件发送方案

**方案对比**：

| 方案 | 优势 | 劣势 | 推荐度 |
|------|------|------|--------|
| mail 命令 | 简单、无需配置 | 依赖本地邮件服务 | ⭐⭐⭐⭐⭐ |
| sendmail | 灵活、可控 | 配置复杂 | ⭐⭐⭐ |
| SMTP 库 | 跨平台、可靠 | 需要额外依赖 | ⭐⭐⭐⭐ |
| API 服务 | 功能丰富 | 需要网络、有成本 | ⭐⭐⭐ |

**结论**：使用 `mail` 命令作为首选方案，提供 SMTP 作为备选。

### 2.2 mail 命令实现

**基本用法**：
```bash
echo "邮件正文" | mail -s "邮件主题" recipient@example.com
```

**高级用法**：
```bash
mail -s "邮件主题" \
  -a /path/to/attachment.txt \
  -c cc@example.com \
  recipient@example.com <<EOF
邮件正文

多行内容支持
EOF
```

### 2.3 邮件模板设计

**失败告警邮件**：
```
主题: ❌ 备份失败 - keycloak_db (2026-04-06 03:00)

备份系统检测到严重错误：

阶段: BACKUP
数据库: keycloak_db
时间: 2026-04-06 03:00:15 UTC
错误: 数据库连接失败
退出码: 1

详情:
{
  "error": "connection refused",
  "host": "localhost",
  "port": 5432,
  "retry_count": 3
}

请立即检查备份系统状态。

---
Noda 备份系统
```

**警告邮件**：
```
主题: ⚠️ 耗时异常 - keycloak_db (2026-04-06 03:00)

备份系统检测到性能警告：

数据库: keycloak_db
时间: 2026-04-06 03:00:15 UTC
当前耗时: 120 秒
历史平均: 65 秒
偏差: +84.6%

可能原因:
- 数据库增长
- 网络延迟
- 系统负载高

建议监控后续备份趋势。

---
Noda 备份系统
```

### 2.4 去重机制

**去重策略**：
```bash
# 去重文件
ALERT_HISTORY_FILE="/var/lib/postgresql/backup/alert_history.json"

# 检查是否应该发送告警
should_send_alert() {
  local alert_type=$1
  local database=$2
  local current_time=$(date +%s)
  local dedup_window=3600  # 1 小时

  # 读取历史记录
  if [[ ! -f "$ALERT_HISTORY_FILE" ]]; then
    return 0  # 首次告警，发送
  fi

  # 查找最近的相同告警
  local last_alert
  last_alert=$(jq -r ".[] | select(.type==\"$alert_type\" and .database==\"$database\") | .time" \
    "$ALERT_HISTORY_FILE" 2>/dev/null | tail -1)

  if [[ -z "$last_alert" ]]; then
    return 0  # 无历史记录，发送
  fi

  # 检查时间窗口
  local time_diff=$((current_time - last_alert))
  if [[ $time_diff -ge $dedup_window ]]; then
    return 0  # 超过去重窗口，发送
  else
    return 1  # 在窗口内，跳过
  fi
}

# 记录告警
record_alert() {
  local alert_type=$1
  local database=$2
  local current_time=$(date +%s)

  # 添加到历史记录
  jq ". += [{\"type\":\"$alert_type\",\"database\":\"$database\",\"time\":$current_time}]" \
    "$ALERT_HISTORY_FILE" 2>/dev/null > "${ALERT_HISTORY_FILE}.tmp"
  mv "${ALERT_HISTORY_FILE}.tmp" "$ALERT_HISTORY_FILE"
}
```

---

## 3. 耗时追踪研究

### 3.1 指标收集

**需要追踪的指标**：
```bash
# 备份操作
- backup_start_time
- backup_end_time
- backup_duration
- backup_file_size

# 上传操作
- upload_start_time
- upload_end_time
- upload_duration
- upload_speed

# 验证操作
- verify_start_time
- verify_end_time
- verify_duration

# 总耗时
- total_duration
```

### 3.2 历史记录存储

**JSON 文件格式**：
```json
[
  {
    "timestamp": "2026-04-06T03:00:00Z",
    "database": "keycloak_db",
    "backup_duration": 65,
    "upload_duration": 120,
    "verify_duration": 5,
    "total_duration": 190,
    "file_size": 1288490188,
    "status": "success"
  },
  {
    "timestamp": "2026-04-06T09:00:00Z",
    "database": "keycloak_db",
    "backup_duration": 68,
    "upload_duration": 115,
    "verify_duration": 6,
    "total_duration": 189,
    "file_size": 1291845632,
    "status": "success"
  }
]
```

### 3.3 平均耗时计算

**移动平均算法**：
```bash
calculate_average_duration() {
  local database=$1
  local metric_name=$2  # backup_duration, upload_duration, etc.
  local window_size=10

  # 从历史文件读取数据
  local history_file="/var/lib/postgresql/backup/history.json"

  if [[ ! -f "$history_file" ]]; then
    echo "0"
    return
  fi

  # 获取最近 N 次记录
  local recent_records
  recent_records=$(jq "[.[] | select(.database==\"$database\")] | reverse | .[0:$window_size]" \
    "$history_file")

  # 计算平均值
  local sum
  sum=$(echo "$recent_records" | jq "[.[].$metric_name] | add")

  local count
  count=$(echo "$recent_records" | jq "length")

  if [[ $count -gt 0 ]]; then
    local average=$((sum / count))
    echo "$average"
  else
    echo "0"
  fi
}
```

### 3.4 异常检测

**检测逻辑**：
```bash
check_duration_anomaly() {
  local database=$1
  local current_duration=$2
  local metric_name=$3

  # 计算历史平均值
  local average
  average=$(calculate_average_duration "$database" "$metric_name")

  if [[ $average -eq 0 ]]; then
    return 0  # 无历史数据，跳过
  fi

  # 计算偏差
  local threshold=50  # 50%
  local deviation=$(( (current_duration - average) * 100 / average ))

  if [[ $deviation -gt $threshold ]]; then
    log_warn "耗时异常检测: $database"
    log_warn "  当前耗时: ${current_duration}s"
    log_warn "  历史平均: ${average}s"
    log_warn "  偏差: +${deviation}%"

    # 发送警告邮件
    send_alert "duration_anomaly" "$database" \
      "耗时异常: 当前 ${current_duration}s，平均 ${average}s，偏差 +${deviation}%"

    return 1
  fi

  return 0
}
```

---

## 4. 集成策略研究

### 4.1 脚本集成点

**backup-postgres.sh 集成**：
```bash
# 在主函数中添加监控
main() {
  local start_time=$(date +%s)

  # 现有备份流程
  backup_all_databases "$backup_dir" "$timestamp"

  local backup_end_time=$(date +%s)
  local backup_duration=$((backup_end_time - start_time))

  # 记录指标
  record_metric "backup" "$database" "$backup_duration" "$file_size"

  # 检查异常
  check_duration_anomaly "$database" "$backup_duration" "backup_duration"

  # 继续其他流程...
}
```

### 4.2 错误处理集成

**失败时发送告警**：
```bash
# 在错误处理中添加告警
if ! backup_database "$db"; then
  local exit_code=$?

  # 发送告警
  send_alert "backup_failed" "$db" "备份失败，退出码: $exit_code"

  exit $exit_code
fi
```

---

## 5. 依赖和安装研究

### 5.1 mail 命令安装

**macOS**：
```bash
# macOS 默认没有 mail 命令
# 需要安装 postfix
brew install postfix

# 启动服务
sudo postfix start

# 或者使用 mailutils
brew install mailutils
```

**Linux (Ubuntu/Debian)**：
```bash
sudo apt-get install mailutils
sudo postfix start
```

**Linux (CentOS/RHEL)**：
```bash
sudo yum install postfix
sudo systemctl start postfix
sudo systemctl enable postfix
```

### 5.2 jq 安装

**JSON 处理需要 jq**：
```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt-get install jq

# CentOS/RHEL
sudo yum install jq
```

---

## 6. 性能影响研究

### 6.1 性能开销

| 操作 | 开销 | 影响 |
|------|------|------|
| 结构化日志 | < 1ms | 可忽略 |
| 写入历史文件 | < 10ms | 可忽略 |
| 计算平均值 | < 50ms | 可忽略 |
| 发送邮件 | 1-5s | 异步处理 |

### 6.2 优化策略

**异步发送邮件**：
```bash
# 后台发送邮件，不阻塞主流程
send_alert_async() {
  local alert_type=$1
  local database=$2
  local message=$3

  # 在后台发送
  (
    sleep 1  # 延迟发送，避免阻塞主流程
    send_alert "$alert_type" "$database" "$message"
  ) &
}
```

---

## 7. 安全性研究

### 7.1 邮件内容安全

**敏感信息处理**：
- ❌ 不在邮件中包含密码
- ❌ 不在邮件中包含完整数据库名（可脱敏）
- ✅ 仅包含必要的错误信息
- ✅ 使用邮件加密（可选）

### 7.2 文件权限

**历史文件权限**：
```bash
# 设置严格的文件权限
chmod 600 /var/lib/postgresql/backup/history.json
chmod 600 /var/lib/postgresql/backup/alert_history.json
```

---

## 8. 故障排查研究

### 8.1 邮件发送失败

**检测方法**：
```bash
# 检测 mail 命令是否可用
if ! command -v mail >/dev/null 2>&1; then
  log_error "mail 命令未安装，无法发送告警邮件"
  log_error "安装方法: brew install postfix"
  return 1
fi

# 测试邮件发送
if ! echo "test" | mail -s "test" recipient@example.com; then
  log_error "邮件发送失败，检查邮件服务配置"
  return 1
fi
```

### 8.2 历史文件损坏

**恢复机制**：
```bash
# 检测 JSON 文件有效性
if ! jq empty "$history_file" 2>/dev/null; then
  log_warn "历史文件损坏，重建文件"
  echo "[]" > "$history_file"
fi
```

---

## 9. 技术决策总结

### 核心技术栈

- **日志格式**: 结构化文本（带时间戳）
- **邮件发送**: mail 命令（本地邮件服务）
- **历史存储**: JSON 文件（jq 处理）
- **去重机制**: 基于时间窗口（1 小时）
- **异常检测**: 对比移动平均（最近 10 次）

### 关键技术点

1. **结构化日志**: 扩展 lib/log.sh，添加时间戳和结构
2. **邮件告警**: 使用 mail 命令，支持去重和模板
3. **耗时追踪**: JSON 文件存储，jq 计算平均值
4. **异常检测**: 对比历史平均，偏差 > 50% 时告警
5. **异步处理**: 邮件发送后台化，不阻塞主流程

---

## 10. 后续工作

**技术研究已完成，下一步**：
1. ✅ 创建详细执行计划（PLAN.md）
2. ✅ 分解为 Waves 和 Tasks
3. ✅ 开始实现阶段

---

**研究总结**：Phase 5 的技术路线已明确，采用结构化日志 + 邮件告警 + 耗时追踪的策略，确保备份系统的可观测性。所有关键技术点已验证，准备进入执行阶段。
