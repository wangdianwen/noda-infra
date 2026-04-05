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
