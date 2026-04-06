#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 统一常量定义
# ============================================
# 功能：定义所有脚本共享的常量（退出码、错误消息等）
# 作者：Noda 团队
# 版本: 1.0.0
# ============================================

# ============================================
# 退出码常量（遵循 MONITOR-05）
# ============================================

readonly EXIT_SUCCESS=0
readonly EXIT_CONNECTION_FAILED=1
readonly EXIT_BACKUP_FAILED=2
readonly EXIT_CLOUD_UPLOAD_FAILED=3
readonly EXIT_CLEANUP_FAILED=4
readonly EXIT_VERIFICATION_FAILED=5
readonly EXIT_DISK_SPACE_INSUFFICIENT=6
readonly EXIT_RESTORE_FAILED=7
readonly EXIT_INVALID_ARGS=8

# ============================================
# Phase 4: 自动化验证测试配置
# ============================================

readonly TEST_TIMEOUT=3600  # 1 小时超时
readonly TEST_DB_PREFIX="test_restore_"
readonly TEST_MAX_RETRIES=3
readonly TEST_LOG_DIR="${TEST_LOG_DIR:-/var/log/noda-backup-test}"
readonly TEST_BACKUP_DIR="${TEST_BACKUP_DIR:-/tmp/test-verify}"
readonly EXIT_TIMEOUT=9
readonly EXIT_DOWNLOAD_FAILED=11
readonly EXIT_RESTORE_TEST_FAILED=12
readonly EXIT_VERIFY_TEST_FAILED=13
readonly EXIT_CLEANUP_TEST_FAILED=14

# ============================================
# Phase 5: 监控与告警配置
# ============================================

# 告警配置
readonly ALERT_ENABLED="${ALERT_ENABLED:-true}"
readonly ALERT_EMAIL="${ALERT_EMAIL:-}"
readonly ALERT_DEDUP_WINDOW=3600  # 1 小时去重窗口

# 历史记录文件（用户目录）
readonly HISTORY_DIR="${HISTORY_DIR:-$HOME/.noda-backup/history}"
readonly HISTORY_FILE="$HISTORY_DIR/history.json"
readonly ALERT_HISTORY_FILE="$HISTORY_DIR/alert_history.json"
readonly LOG_RETENTION_DAYS=7  # 日志保留 7 天

# 指标配置
readonly METRICS_WINDOW_SIZE=10  # 最近 10 次
readonly METRICS_ANOMALY_THRESHOLD=50  # 50% 偏差
