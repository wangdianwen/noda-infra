#!/bin/bash
# ============================================
# 安全防护定期检查脚本（Phase 56-03）
# ============================================
# 功能：定期执行安全防护验证
# 用途：通过 cron 定期执行，检查安全配置
# 安装：将以下行添加到 crontab (crontab -e)
#   0 * * * * /path/to/noda-infra/scripts/cron-safety-check.sh >> /var/log/noda-safety-check.log 2>&1
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/noda-safety-check.log"

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")"

# 记录时间戳
echo "========================================" >> "$LOG_FILE"
echo "安全检查时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"

# 执行验证脚本
if "$SCRIPT_DIR/verify-safety.sh" >> "$LOG_FILE" 2>&1; then
    echo "状态: 通过" >> "$LOG_FILE"
else
    echo "状态: 失败" >> "$LOG_FILE"
    # 可选：发送告警通知
    # echo "安全防护验证失败" | mail -s "Noda 安全检查告警" admin@example.com
fi

echo "" >> "$LOG_FILE"
