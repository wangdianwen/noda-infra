#!/bin/bash

# 生产环境迁移脚本
#
# 用途:
# - 生产环境迁移的安全包装器
# - 环境检查和备份提醒
# - 用户确认机制
# - 迁移后验证
#
# 参考:
# - 51-CONTEXT.md 决策 D-04: 保留 Supabase 备份
# - infra/scripts/switch-env.sh 的环境检查模式

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"

# ==================== 环境检查 ====================

check_production_environment() {
    log_info "检查生产环境配置..."

    # 检查 NODE_ENV
    if [[ "${NODE_ENV:-}" != "production" ]]; then
        log_warn "⚠️  NODE_ENV 未设置为 'production'"
        log_warn "   当前值: ${NODE_ENV:-未设置}"
        echo ""

        read -p "是否继续迁移？(y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "迁移已取消"
            exit 0
        fi
    fi

    # 检查备份文件是否存在
    local backup_dir="infra/postgres/backup/manual"
    if [[ ! -d "${backup_dir}" ]] || [[ -z "$(ls -A ${backup_dir} 2>/dev/null)" ]]; then
        log_warn "⚠️  未找到备份文件"
        log_warn "   建议在迁移前创建 Supabase 手动备份"
        echo ""

        read -p "是否继续迁移？(y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "迁移已取消"
            exit 0
        fi
    fi

    log_info "生产环境检查完成 ✓"
    echo ""
}

# ==================== 备份提醒 ====================

show_backup_reminder() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║              ⚠️  生产环境迁移 - 重要提醒                      ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    log_warn "在继续迁移之前，请确保："
    echo ""
    echo "  1. ✅ 已创建 Supabase 手动备份"
    echo "     访问: https://supabase.com/dashboard/project/qxplheelnlqdapmprhui/database/backups"
    echo ""
    echo "  2. ✅ 已通知用户停机（预计 30 分钟）"
    echo "     网站: https://noda.co.nz"
    echo ""
    echo "  3. ✅ 已准备好回滚方案"
    echo "     回滚命令: docker exec -i noda-postgres psql -U noda_prod_user -d noda_prod < backup.sql"
    echo ""
    echo "  4. ✅ 已检查所有前置条件"
    echo "     Docker 容器运行中、环境变量已配置"
    echo ""
    echo "  5. ✅ 已准备好监控迁移进度"
    echo "     迁移日志: .planning/phases/51-数据库迁移/migration.log"
    echo ""
}

# ==================== 生产环境迁移 ====================

migrate_production() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                    🚀 生产环境迁移                            ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    # 显示备份提醒
    show_backup_reminder

    # 最终确认
    echo ""
    log_warn "⚠️  即将开始生产环境迁移"
    read -p "确认继续？(yes/no): " -r
    echo

    if [[ ! $REPLY == "yes" ]]; then
        log_info "迁移已取消"
        exit 0
    fi

    echo ""
    log_info "开始生产环境迁移..."
    log_info "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    # 记录开始时间
    local start_time=$(date +%s)

    # 执行迁移
    bash "${PROJECT_ROOT:-$SCRIPT_DIR/../..}/../noda-app/server/scripts/migration/migrate-auto.sh"
    local exit_code=$?

    # 计算耗时
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo ""

    # 检查结果
    if [[ ${exit_code} -eq 0 ]]; then
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║              ✅ 生产环境迁移成功！                           ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        log_success "迁移成功完成！"
        log_info "总耗时: ${duration} 秒"
        echo ""
        log_info "后续步骤："
        log_info "1. 查看迁移报告:"
        log_info "   cat .planning/phases/51-数据库迁移/51-04-FINAL-REPORT.json | jq ."
        echo ""
        log_info "2. 验证网站功能:"
        log_info "   打开 https://noda.co.nz 并测试关键功能"
        echo ""
        log_info "3. 监控数据库性能:"
        log_info "   docker stats noda-postgres"
        echo ""
    else
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║              ❌ 生产环境迁移失败！                           ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        log_error "迁移失败，耗时: ${duration} 秒"
        echo ""
        log_error "故障排查："
        log_error "1. 查看错误日志:"
        log_error "   cat .planning/phases/51-数据库迁移/migration.log"
        echo ""
        log_error "2. 检查数据库状态:"
        log_error "   docker exec -it noda-postgres psql -U noda_prod_user -d noda_prod -c \"SELECT COUNT(*) FROM courses;\""
        echo ""
        log_error "3. 回滚到 Supabase（如果需要）:"
        log_error "   - 确认 Supabase 备份可用"
        log_error "   - 更新环境变量 DATABASE_URL 指回 Supabase"
        log_error "   - 重启应用"
        echo ""
        exit 1
    fi
}

# ==================== 执行主函数 ====================

# 检查生产环境
check_production_environment

# 执行迁移
migrate_production
