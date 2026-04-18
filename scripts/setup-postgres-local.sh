#!/bin/bash
set -euo pipefail

# ============================================
# PostgreSQL 本地开发环境管理脚本
# ============================================
# 功能：安装、初始化数据库、状态检查、卸载
# 用途：通过 Homebrew 在 macOS 宿主机上管理 PostgreSQL 17
# 版本：postgresql@17（与生产 Docker postgres:17.9 对齐）
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/log.sh"

# ============================================
# 常量
# ============================================
PG_FORMULA="postgresql@17"
PG_PORT=5432
DEV_DATABASES=("noda_dev" "keycloak_dev")

# ============================================
# detect_homebrew_prefix() — 检测 Homebrew 安装路径
# ============================================
# 参数：无
# 返回：stdout 输出 Homebrew prefix 路径
detect_homebrew_prefix()
{
    local arch
    arch=$(uname -m)
    if [ "$arch" = "arm64" ]; then
        echo "/opt/homebrew"
    else
        echo "/usr/local"
    fi
}

# ============================================
# ensure_brew_env() — 确保 Homebrew 环境已加载
# ============================================
ensure_brew_env()
{
    local prefix
    prefix=$(detect_homebrew_prefix)
    eval "$("$prefix/bin/brew" shellenv)"
}

# ============================================
# PG_DATA_DIR — 动态设置数据目录路径
# ============================================
# 注意：在 ensure_brew_env 之后才能正确获取
get_pg_data_dir()
{
    local prefix
    prefix=$(detect_homebrew_prefix)
    echo "${prefix}/var/postgresql@17"
}

# ============================================
# usage() — 显示帮助信息
# ============================================
usage()
{
    cat <<EOF
PostgreSQL 本地开发环境管理脚本

用法: setup-postgres-local.sh <命令>

命令:
  install       安装 postgresql@17 + 配置 brew services + 创建开发数据库
  init-db       创建/重建开发数据库（noda_dev, keycloak_dev）
  migrate-data  [已废弃] 从 Docker postgres-dev 迁移数据（容器已在 Phase 27 移除）
  status        检查 PostgreSQL 运行状态、版本、数据库列表
  uninstall     卸载 PostgreSQL 并清理数据目录

示例:
  setup-postgres-local.sh install
  setup-postgres-local.sh init-db
  setup-postgres-local.sh migrate-data
  setup-postgres-local.sh status
  setup-postgres-local.sh uninstall
EOF
}

# ============================================
# cmd_install() — 安装 postgresql@17 + 配置 + 初始化
# ============================================
cmd_install()
{
    log_info "=========================================="
    log_info "PostgreSQL ${PG_FORMULA} 安装开始"
    log_info "=========================================="

    # 步骤 1/10: 架构检测
    log_info "步骤 1/10: 架构检测"
    local HOMEBREW_PREFIX
    HOMEBREW_PREFIX=$(detect_homebrew_prefix)
    log_info "Homebrew prefix: ${HOMEBREW_PREFIX} (架构: $(uname -m))"
    ensure_brew_env
    log_success "Homebrew 环境已加载"

    # 步骤 2/10: 检查已安装
    log_info "步骤 2/10: 检查 ${PG_FORMULA} 安装状态"
    if brew list "$PG_FORMULA" &>/dev/null; then
        log_info "${PG_FORMULA} 已安装，跳过安装步骤"
    else
        # 步骤 3/10: 安装 postgresql@17
        log_info "步骤 3/10: 安装 ${PG_FORMULA}"
        brew install "$PG_FORMULA"
        log_success "${PG_FORMULA} 安装完成"
    fi

    # 步骤 4/10: 链接二进制
    log_info "步骤 4/10: 链接二进制文件"
    if command -v psql &>/dev/null; then
        log_info "psql 已在 PATH 中可用"
    else
        brew link --force "$PG_FORMULA"
        log_success "${PG_FORMULA} 已链接到 PATH"
    fi

    # 步骤 5/10: 端口冲突检查
    log_info "步骤 5/10: 端口冲突检查（:${PG_PORT}）"
    if lsof -i ":${PG_PORT}" &>/dev/null; then
        log_error "端口 ${PG_PORT} 已被占用，请先停止占用该端口的进程"
        lsof -i ":${PG_PORT}" || true
        log_info "提示：如果 Docker postgres-dev 容器正在运行，请先停止它"
        exit 1
    fi
    log_success "端口 ${PG_PORT} 空闲"

    # 步骤 6/10: 启动服务
    log_info "步骤 6/10: 启动 ${PG_FORMULA} 服务（brew services）"
    local service_status
    service_status=$(brew services list 2>/dev/null | grep "$PG_FORMULA" | awk '{print $2}' || echo "")
    if [ "$service_status" = "started" ]; then
        log_info "${PG_FORMULA} 服务已在运行"
    else
        brew services start "$PG_FORMULA"
        log_success "${PG_FORMULA} 服务已启动（开机自启）"
    fi

    # 步骤 7/10: 等待就绪
    log_info "步骤 7/10: 等待 PostgreSQL 就绪"
    local max_wait=30
    local waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if pg_isready &>/dev/null; then
            log_success "PostgreSQL 已就绪（耗时 ${waited}s）"
            break
        fi
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -eq "$max_wait" ]; then
            log_error "PostgreSQL 启动超时（${max_wait}s）"
            exit 1
        fi
    done

    # 步骤 8/10: 验证 pg_hba.conf
    log_info "步骤 8/10: 验证 pg_hba.conf 认证配置"
    local pg_data_dir
    pg_data_dir=$(get_pg_data_dir)
    local hba_file="${pg_data_dir}/pg_hba.conf"

    if [ ! -f "$hba_file" ]; then
        log_error "pg_hba.conf 文件不存在: ${hba_file}"
        exit 1
    fi

    local hba_needs_fix=false

    # 检查 local 连接的认证方法
    # pg_hba.conf 格式: TYPE  DATABASE  USER  ADDRESS  METHOD
    # local 行: local   all   all   trust
    if grep -qE "^local\s+\S+\s+\S+\s+trust" "$hba_file"; then
        log_info "local 连接认证方法: trust (正确)"
    else
        log_warn "local 连接认证方法非 trust，将自动修正"
        # 替换所有 local 行的认证方法为 trust
        sed -i '' -E 's/^(local\s+\S+\s+\S+\s+)\S+/\1trust/' "$hba_file"
        hba_needs_fix=true
    fi

    # 检查 host 127.0.0.1 连接的认证方法
    if grep -qE "^host\s+\S+\s+\S+\s+127\.0\.0\.1\/32\s+trust" "$hba_file"; then
        log_info "host 127.0.0.1 连接认证方法: trust (正确)"
    else
        log_warn "host 127.0.0.1 连接认证方法非 trust，将自动修正"
        # 替换 host 127.0.0.1 行的认证方法为 trust
        sed -i '' -E 's/^(host\s+\S+\s+\S+\s+127\.0\.0\.1\/32\s+)\S+/\1trust/' "$hba_file"
        hba_needs_fix=true
    fi

    # 检查 host ::1 (IPv6 localhost) 连接的认证方法
    if grep -qE "^host\s+\S+\s+\S+\s+::1\/128\s+trust" "$hba_file"; then
        log_info "host ::1 连接认证方法: trust (正确)"
    else
        log_warn "host ::1 连接认证方法非 trust，将自动修正"
        sed -i '' -E 's/^(host\s+\S+\s+\S+\s+::1\/128\s+)\S+/\1trust/' "$hba_file"
        hba_needs_fix=true
    fi

    if [ "$hba_needs_fix" = true ]; then
        log_info "重启 PostgreSQL 服务以应用 pg_hba.conf 更改"
        brew services restart "$PG_FORMULA"

        # 重新等待就绪
        waited=0
        while [ "$waited" -lt "$max_wait" ]; do
            if pg_isready &>/dev/null; then
                log_success "PostgreSQL 重启后已就绪"
                break
            fi
            sleep 1
            waited=$((waited + 1))
            if [ "$waited" -eq "$max_wait" ]; then
                log_error "PostgreSQL 重启后启动超时（${max_wait}s）"
                exit 1
            fi
        done
        log_success "pg_hba.conf 已修正为 trust 认证"
    else
        log_success "pg_hba.conf 认证配置正确（trust）"
    fi

    # 步骤 9/10: 创建开发数据库
    log_info "步骤 9/10: 创建开发数据库"
    cmd_init_db "$@"

    # 步骤 10/10: 显示安装摘要
    log_info "步骤 10/10: 安装摘要"
    local pg_version
    pg_version=$(psql --version 2>/dev/null || echo "未知")
    log_success "=========================================="
    log_success "PostgreSQL 安装完成！"
    log_success "=========================================="
    log_info "版本: ${pg_version}"
    log_info "端口: ${PG_PORT}"
    log_info "认证: trust（本地连接无密码）"
    log_info "数据库: ${DEV_DATABASES[*]}"
    log_info "数据目录: ${pg_data_dir}"
    log_info "连接示例: psql -d noda_dev"
    log_success "=========================================="
}

# ============================================
# cmd_init_db() — 创建开发数据库
# ============================================
cmd_init_db()
{
    ensure_brew_env

    log_info "初始化开发数据库..."

    for db_name in "${DEV_DATABASES[@]}"; do
        if psql -lqt 2>/dev/null | cut -d '|' -f 1 | grep -qw "$db_name"; then
            log_info "数据库 '${db_name}' 已存在，跳过"
        else
            createdb "$db_name"
            log_success "数据库 '${db_name}' 创建成功"
        fi
    done

    log_success "开发数据库初始化完成"
}

# ============================================
# cmd_status() — 状态检查（5 项）
# ============================================
cmd_status()
{
    ensure_brew_env

    log_info "=========================================="
    log_info "PostgreSQL 状态检查"
    log_info "=========================================="

    local all_ok=true

    # 检查 1/5: 安装状态
    log_info "检查 1/5: ${PG_FORMULA} 安装状态"
    if brew list "$PG_FORMULA" &>/dev/null; then
        local pg_version
        pg_version=$(psql --version 2>/dev/null || echo "未知")
        log_success "${PG_FORMULA} 已安装（${pg_version}）"
    else
        log_error "${PG_FORMULA} 未安装"
        all_ok=false
    fi

    # 检查 2/5: 服务状态
    log_info "检查 2/5: 服务状态"
    local service_status
    service_status=$(brew services list 2>/dev/null | grep "$PG_FORMULA" | awk '{print $2}' || echo "")
    if [ "$service_status" = "started" ]; then
        log_success "${PG_FORMULA} 服务已启动（brew services）"
    else
        log_error "${PG_FORMULA} 服务未运行（状态: ${service_status:-未找到}）"
        all_ok=false
    fi

    # 检查 3/5: 连接测试
    log_info "检查 3/5: 连接测试"
    if pg_isready &>/dev/null; then
        log_success "PostgreSQL 连接正常（pg_isready）"
    else
        log_error "PostgreSQL 连接失败"
        all_ok=false
    fi

    # 检查 4/5: 开发数据库
    log_info "检查 4/5: 开发数据库"
    for db_name in "${DEV_DATABASES[@]}"; do
        if psql -lqt 2>/dev/null | cut -d '|' -f 1 | grep -qw "$db_name"; then
            log_success "数据库 '${db_name}' 存在"
        else
            log_error "数据库 '${db_name}' 不存在"
            all_ok=false
        fi
    done

    # 检查 5/5: 版本匹配
    log_info "检查 5/5: 版本匹配（主版本号 17）"
    local pg_version_output
    pg_version_output=$(psql --version 2>/dev/null || echo "")
    if echo "$pg_version_output" | grep -q " 17\."; then
        log_success "版本匹配: ${pg_version_output}"
    else
        log_error "版本不匹配: ${pg_version_output}（期望主版本号 17）"
        all_ok=false
    fi

    log_info "=========================================="
    if [ "$all_ok" = true ]; then
        log_success "所有检查通过"
    else
        log_warn "部分检查未通过，请查看上方详情"
    fi
    log_info "=========================================="
}

# ============================================
# cmd_migrate_data() — 从 Docker postgres-dev 迁移数据到本地 PG
# ============================================
cmd_migrate_data()
{
    ensure_brew_env

    log_info "=========================================="
    log_info "PostgreSQL 数据迁移（Docker → 本地）"
    log_info "=========================================="

    # 前置检查 1: 本地 PG 是否运行
    log_info "前置检查: 本地 PostgreSQL 运行状态"
    if ! pg_isready &>/dev/null; then
        log_error "本地 PostgreSQL 未运行，请先执行: bash $0 install"
        exit 1
    fi
    log_success "本地 PostgreSQL 运行中"

    # 前置检查 2: Docker postgres-dev 容器是否仍存在
    log_info "前置检查: Docker postgres-dev 容器状态"
    local docker_container="noda-infra-postgres-dev"

    if ! docker ps -a --format "{{.Names}}" | grep -q "$docker_container"; then
        # 容器定义已被移除（Phase 27 清理后 dev.yml 不再定义 postgres-dev）
        log_warn "postgres-dev 容器已不存在（Phase 27 清理后已移除）"
        log_info "开发数据应已在本地 PostgreSQL 中，无需从 Docker 迁移"
        log_info "如需清理残留 Docker volume: docker volume rm noda-infra_postgres_dev_data"
        log_success "跳过迁移（容器已被移除）"
        return 0
    fi

    if ! docker ps --format "{{.Names}}" | grep -q "$docker_container"; then
        # 容器存在但未运行（可能是旧部署残留）
        log_warn "Docker 容器 ${docker_container} 存在但未运行"
        log_info "尝试启动容器以完成迁移..."
        docker compose -f docker/docker-compose.yml up -d postgres-dev 2>/dev/null || {
            log_warn "无法启动容器，开发数据可能已丢失"
            log_info "建议使用本地 PostgreSQL 重新创建开发数据: bash $0 init-db"
            return 0
        }
        # 等待容器健康
        sleep 5
    fi
    log_success "Docker 容器 ${docker_container} 可用"

    # 迁移前状态显示
    log_info "迁移前数据库大小（Docker 容器内）："
    docker exec "$docker_container" psql -U postgres -c \
        "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datname IN ('noda_dev', 'keycloak_dev');" \
        2>/dev/null || log_warn "无法获取 Docker 内数据库大小"

    # 迁移数据库列表
    local MIGRATE_DATABASES=("noda_dev" "keycloak_dev")

    # 内部函数: 迁移单个数据库
    migrate_database()
    {
        local db_name="$1"
        local dump_file="/tmp/${db_name}_dump_$$.sql"

        log_info "导出 ${db_name} 从 Docker 容器..."

        # 使用 Docker 容器内的 pg_dump（版本 17.9 完全匹配）
        if ! docker exec "$docker_container" pg_dump -U postgres -d "$db_name" \
            --no-owner --no-privileges >"$dump_file" 2>/dev/null; then
            log_warn "${db_name} 导出失败（数据库可能不存在于 Docker 容器中）"
            rm -f "$dump_file"
            return 1
        fi

        if [ ! -s "$dump_file" ]; then
            log_error "${db_name} 导出失败（空文件）"
            rm -f "$dump_file"
            return 1
        fi

        log_info "导入 ${db_name} 到本地 PostgreSQL..."

        # 终止所有到该数据库的连接
        psql -d postgres -c \
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${db_name}' AND pid <> pg_backend_pid();" \
            2>/dev/null || true

        # 幂等：先删除再重建
        psql -d postgres -c "DROP DATABASE IF EXISTS ${db_name};" 2>/dev/null || true
        psql -d postgres -c "CREATE DATABASE ${db_name};"

        # 导入 dump 文件
        if ! psql -d "$db_name" <"$dump_file" 2>/dev/null; then
            log_error "${db_name} 导入失败"
            rm -f "$dump_file"
            return 1
        fi

        # 清理临时文件
        rm -f "$dump_file"
        log_success "${db_name} 迁移完成"
        return 0
    }

    # 执行迁移循环
    local success_count=0
    local fail_count=0
    for db in "${MIGRATE_DATABASES[@]}"; do
        if migrate_database "$db"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    # 迁移后验证
    log_info "迁移后数据验证："

    # noda_dev: 检查 courses 表行数
    local noda_courses
    noda_courses=$(psql -d noda_dev -t -c "SELECT count(*) FROM courses;" 2>/dev/null | xargs || echo "0")
    if [ "$noda_courses" -gt 0 ] 2>/dev/null; then
        log_success "noda_dev 验证通过（courses 表 ${noda_courses} 行）"
    else
        log_warn "noda_dev courses 表为空或不存在（行数: ${noda_courses}）"
    fi

    # keycloak_dev: 检查表数量
    local kc_table_count
    kc_table_count=$(psql -d keycloak_dev -c "\dt" 2>/dev/null | tail -n +3 | head -n -1 | wc -l | xargs || echo "0")
    if [ "$kc_table_count" -gt 60 ] 2>/dev/null; then
        log_success "keycloak_dev 验证通过（${kc_table_count} 个表）"
    else
        log_warn "keycloak_dev 表数量不足（${kc_table_count} 个，预期 > 60）"
    fi

    # 迁移摘要
    log_info "=========================================="
    if [ "$fail_count" -eq 0 ]; then
        log_success "迁移完成: ${success_count} 个数据库成功"
    else
        log_warn "迁移完成: ${success_count} 个成功, ${fail_count} 个失败"
    fi
    log_info "=========================================="
}

# ============================================
# cmd_uninstall() — 卸载 PostgreSQL
# ============================================
cmd_uninstall()
{
    ensure_brew_env

    log_info "=========================================="
    log_info "PostgreSQL 卸载"
    log_info "=========================================="

    # 步骤 1/6: 交互确认
    log_info "步骤 1/6: 确认卸载"
    read -r -p "确定要卸载 PostgreSQL 并删除所有数据？[y/N] " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "已取消卸载"
        exit 0
    fi

    # 步骤 2/6: 停止服务
    log_info "步骤 2/6: 停止 ${PG_FORMULA} 服务"
    brew services stop "$PG_FORMULA" 2>/dev/null || true
    log_success "服务已停止"

    # 步骤 3/6: 卸载包
    log_info "步骤 3/6: 卸载 ${PG_FORMULA} 包"
    brew uninstall "$PG_FORMULA" 2>/dev/null || true
    log_success "包已卸载"

    # 步骤 4/6: 删除数据目录
    log_info "步骤 4/6: 删除数据目录"
    local pg_data_dir
    pg_data_dir=$(get_pg_data_dir)
    if [ -d "$pg_data_dir" ]; then
        rm -rf "$pg_data_dir"
        log_success "数据目录已删除: ${pg_data_dir}"
    else
        log_info "数据目录不存在，跳过: ${pg_data_dir}"
    fi

    # 步骤 5/6: 清理 LaunchAgent
    log_info "步骤 5/6: 清理 LaunchAgent"
    brew services cleanup 2>/dev/null || true
    log_success "LaunchAgent 已清理"

    # 步骤 6/6: 完成信息
    log_success "=========================================="
    log_success "PostgreSQL 卸载完成"
    log_success "=========================================="
    log_info "如需重新安装: bash $0 install"
}

# ============================================
# 子命令分发
# ============================================
case "${1:-}" in
    install) cmd_install "$@" ;;
    init-db) cmd_init_db "$@" ;;
    migrate-data) cmd_migrate_data "$@" ;;
    status) cmd_status "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    *) usage && exit 1 ;;
esac
