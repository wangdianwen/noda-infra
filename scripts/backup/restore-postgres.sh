#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 恢复脚本
# ============================================
# 功能：从 B2 云存储恢复 PostgreSQL 数据库
# 用法：./restore-postgres.sh [选项] [参数]
# 作者：Noda 团队
# 版本：1.0.0
# ============================================

set -euo pipefail

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载库
source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/restore.sh"

# ============================================
# 帮助信息
# ============================================

show_help() {
  cat <<EOF
用法: $0 [选项] [参数]

Noda 数据库恢复脚本 - 从 B2 云存储恢复数据库

选项:
  -l, --list-backups           列出所有可用的备份文件
  -r, --restore <filename>     恢复指定的备份文件
  -d, --database <name>        恢复到指定的数据库名（用于测试）
  -o, --output-dir <dir>       下载备份到指定目录（默认: 临时目录）
  -v, --verify                 验证备份文件完整性
  -h, --help                   显示此帮助信息

示例:
  # 列出所有可用备份
  $0 --list-backups

  # 恢复指定备份到原数据库
  $0 --restore test_db_20260406_113147.dump

  # 恢复到不同数据库名（用于测试）
  $0 --restore test_db_20260406_113147.dump --database test_db_restored

  # 下载备份到本地目录
  $0 --restore test_db_20260406_113147.dump --output-dir /tmp/backups

  # 仅验证备份完整性
  $0 --verify test_db_20260406_113147.dump

环境变量:
  POSTGRES_HOST        PostgreSQL 主机（默认: noda-infra-postgres-prod）
  POSTGRES_PORT        PostgreSQL 端口（默认: 5432）
  POSTGRES_USER        PostgreSQL 用户（默认: postgres）
  BACKUP_DIR           本地备份目录（默认: /var/lib/postgresql/backup）

EOF
}

# ============================================
# 主程序
# ============================================

main() {
  local action=""
  local backup_filename=""
  local target_db=""
  local output_dir=""
  local verify_only=false

  # 加载配置
  load_config

  # 解析参数
  while [[ $# -gt 0 ]]; do
    case $1 in
      -l|--list-backups)
        action="list"
        shift
        ;;
      -r|--restore)
        action="restore"
        backup_filename="$2"
        shift 2
        ;;
      -d|--database)
        target_db="$2"
        shift 2
        ;;
      -o|--output-dir)
        output_dir="$2"
        shift 2
        ;;
      -v|--verify)
        verify_only=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        echo "未知选项: $1"
        echo "使用 --help 查看帮助信息"
        exit $EXIT_INVALID_ARGS
        ;;
    esac
  done

  # 执行操作
  case "$action" in
    list)
      list_backups_b2
      ;;
    restore)
      if [[ -z "$backup_filename" ]]; then
        log_error "请指定要恢复的备份文件名"
        echo "使用 --list-backups 查看可用备份"
        exit $EXIT_INVALID_ARGS
      fi

      # 下载备份
      local downloaded_file
      if [[ -n "$output_dir" ]]; then
        downloaded_file=$(download_backup "$backup_filename" "$output_dir")
      else
        downloaded_file=$(download_backup "$backup_filename")
      fi

      if [[ -z "$downloaded_file" ]]; then
        log_error "下载失败"
        exit $EXIT_RESTORE_FAILED
      fi

      # 仅验证模式
      if [[ "$verify_only" == true ]]; then
        if verify_backup_integrity "$downloaded_file"; then
          log_success "备份验证通过"
          exit 0
        else
          log_error "备份验证失败"
          exit 1
        fi
      fi

      # 恢复数据库
      if restore_database "$downloaded_file" "$target_db"; then
        log_success "恢复完成"

        # 询问是否清理下载的文件
        if [[ -z "$output_dir" ]]; then
          echo ""
          read -p "是否删除下载的备份文件？(yes/no): " cleanup
          if [[ "$cleanup" == "yes" ]]; then
            rm -f "$downloaded_file"
            log_info "已删除临时备份文件"
          fi
        fi

        exit 0
      else
        log_error "恢复失败"
        exit $EXIT_RESTORE_FAILED
      fi
      ;;
    "")
      log_error "请指定操作"
      echo "使用 --help 查看帮助信息"
      exit $EXIT_INVALID_ARGS
      ;;
    *)
      log_error "未知操作: $action"
      exit $EXIT_INVALID_ARGS
      ;;
  esac
}

# 运行主程序
main "$@"
