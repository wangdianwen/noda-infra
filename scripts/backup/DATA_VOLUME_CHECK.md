# 数据量校验功能说明

## 📋 功能概述

Phase 6 数据量校验功能在备份前自动检查数据库大小是否异常，防止在数据丢失的情况下进行无效备份。

## 🎯 核心功能

### 1. 数据库统计信息收集
- **表数量**：统计 public schema 中的基础表数量
- **总行数**：统计所有用户表的行数总和
- **数据库大小**：获取数据库占用的磁盘空间

### 2. 历史数据对比
- 从历史记录中提取最近 7 天的平均备份大小
- 计算当前数据库大小与历史平均值的偏差

### 3. 异常检测与告警
- **异常阈值**：默认 30% 变化视为异常
- **告警机制**：检测到异常时自动发送告警
- **处理模式**：
  - **非严格模式**（默认）：告警但继续备份
  - **严格模式**：告警并终止备份

## 🔧 配置选项

### 环境变量

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `DATA_VOLUME_CHECK_ENABLED` | `true` | 是否启用数据量校验 |
| `DATA_VOLUME_ANOMALY_THRESHOLD` | `30` | 异常阈值（百分比） |
| `DATA_VOLUME_HISTORY_DAYS` | `7` | 历史数据天数 |
| `DATA_VOLUME_STRICT_MODE` | `false` | 严格模式开关 |

### 配置示例

```bash
# .env.backup
# 启用数据量校验（默认开启）
DATA_VOLUME_CHECK_ENABLED=true

# 设置异常阈值为 40%
DATA_VOLUME_ANOMALY_THRESHOLD=40

# 使用最近 14 天的数据
DATA_VOLUME_HISTORY_DAYS=14

# 启用严格模式（异常时终止备份）
DATA_VOLUME_STRICT_MODE=true
```

## 📊 使用示例

### 正常备份流程

```bash
# 备份脚本自动执行数据量校验
docker exec opdev bash -c 'cd /app && bash backup-postgres.sh'

# 输出示例：
# ✅ 数据量校验通过: oneteam_prod
#   表数量: 30
#   总行数: 425
#   数据库大小: 392K
#   历史平均大小: 385K
```

### 数据量异常检测

```bash
# 当数据量异常时（例如从 392K 降到 880B）
# ✅ 数据量校验通过: oneteam_prod
#   表数量: 0
#   总行数: 0
#   数据库大小: 880B
#   历史平均大小: 392K
# ==========================================
# ❌ 数据量异常检测: oneteam_prod
# ==========================================
# 当前大小: 880B
# 历史平均: 392K
# 变化: -99%
# 阈值: ±30%
# ==========================================
# ⚠️  非严格模式：继续备份，但已发送告警
```

## 🛡️ 防护场景

### 1. 数据意外删除
- **场景**：误执行 `DROP SCHEMA public CASCADE`
- **检测**：数据库大小从 392K 降到 880B（-99%）
- **结果**：告警通知，避免备份空数据

### 2. 表迁移丢失
- **场景**：部分表被意外迁移到其他数据库
- **检测**：表数量或总行数显著减少
- **结果**：及时发现数据异常

### 3. 数据增长异常
- **场景**：应用错误导致数据爆炸式增长
- **检测**：数据库大小超过历史平均值 30%
- **结果**：提前发现异常增长趋势

## 📈 历史记录

数据量校验功能依赖指标历史记录（`history.json`）：

```json
[
  {
    "timestamp": "2026-04-06T00:38:56Z",
    "database": "oneteam_prod",
    "operation": "backup",
    "duration": 0,
    "file_size": 880
  },
  {
    "timestamp": "2026-04-06T03:00:08Z",
    "database": "oneteam_prod",
    "operation": "backup",
    "duration": 0,
    "file_size": 392000
  }
]
```

## 🔄 工作流程

```
1. 备份开始
   ↓
2. 发现所有数据库
   ↓
3. 对每个数据库：
   a. 获取当前统计信息（表数量、行数、大小）
   b. 从历史记录计算平均大小
   c. 判断是否异常：
      - 无历史数据 → 跳过对比
      - 偏差 < 30% → 校验通过
      - 偏差 ≥ 30% → 发送告警
   d. 根据严格模式决定是否继续
   ↓
4. 执行备份
   ↓
5. 记录指标（用于下次对比）
```

## 🚀 启用方法

数据量校验功能已默认启用，无需额外配置。如需自定义：

1. 编辑环境变量文件：
   ```bash
   vim scripts/backup/.env.backup
   ```

2. 添加自定义配置：
   ```bash
   DATA_VOLUME_ANOMALY_THRESHOLD=40
   DATA_VOLUME_STRICT_MODE=false
   ```

3. 重启备份容器：
   ```bash
   docker compose restart opdev
   ```

## 📝 注意事项

1. **首次备份**：无历史数据，不会触发异常检测
2. **空数据库**：首次创建的数据库会被正常备份
3. **正常增长**：数据量在阈值范围内的正常增长不会触发告警
4. **告警去重**：同一异常在 1 小时内只会发送一次告警

## 🔍 故障排查

### 问题：校验失败但数据正常

**原因**：历史数据包含异常值（如之前的空备份）

**解决**：
```bash
# 清理异常的历史记录
vim ~/.noda-backup/history/history.json
# 删除异常的记录条目
```

### 问题：首次备份就报异常

**原因**：不应该发生，首次备份无历史数据

**解决**：检查日志确认是否有其他错误

## 📚 相关文件

- `/app/lib/constants.sh` - 常量定义
- `/app/lib/db.sh` - 数据量校验函数
- `/app/lib/metrics.sh` - 指标记录功能
- `/app/lib/alert.sh` - 告警功能
- `~/.noda-backup/history/history.json` - 历史记录

## ✅ 测试验证

```bash
# 测试数据库统计功能
docker exec opdev bash -c 'cd /app && source lib/constants.sh && source lib/db.sh && get_database_stats "oneteam_prod"'

# 测试完整备份流程（包含数据量校验）
docker exec opdev bash -c 'cd /app && bash backup-postgres.sh --dry-run'
```
