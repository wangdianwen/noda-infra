# 测试模式

**分析日期：** 2026-05-17

## 测试框架

### Shell 脚本测试

#### 测试类型
1. **功能测试** (`test-*.sh`)
2. **集成测试** (`*-verify.sh`)
3. **健康检查测试** (`health.sh`)
4. **备份验证测试** (`backup/test-verify-weekly.sh`)

#### 测试框架结构
```bash
# 核心测试库
scripts/backup/lib/test-verify.sh  # 备份验证测试核心
scripts/lib/health.sh             # 健康检查函数
scripts/backup/lib/verify.sh      # 数据完整性验证
scripts/backup/lib/restore.sh     # 恢复功能测试

# 端到端测试
scripts/backup/test-verify-weekly.sh  # 每周验证测试
scripts/backup/verify-restore.sh     # 恢复验证测试
```

#### 测试配置常量
```bash
# scripts/backup/lib/constants.sh
readonly TEST_TIMEOUT=3600          # 1小时超时
readonly TEST_DB_PREFIX="test_restore_"
readonly TEST_MAX_RETRIES=3
readonly TEST_LOG_DIR="${TEST_LOG_DIR:-/var/log/noda-backup-test}"
readonly TEST_BACKUP_DIR="${TEST_BACKUP_DIR:-/tmp/test-verify}"

# 退出码
readonly EXIT_SUCCESS=0
readonly EXIT_CONNECTION_FAILED=1
readonly EXIT_BACKUP_FAILED=2
readonly EXIT_RESTORE_TEST_FAILED=12
readonly EXIT_VERIFY_TEST_FAILED=13
```

### Jenkins Pipeline 测试

#### Pipeline 阶段测试
```groovy
stage('Test') {
    steps {
        dir('noda-apps') {
            sh '''
                source "$WORKSPACE/scripts/lib/log.sh"
                source "$WORKSPACE/scripts/pipeline-stages.sh"
                pipeline_test "$PWD"
            '''
            // Lint 测试
            sh 'pnpm lint >lint-result.txt 2>&1 || echo "LINT_FAILED" >> lint-result.txt'
            // 单元测试
            sh 'pnpm test >test-result.txt 2>&1 || echo "TEST_FAILED" >> test-result.txt'
            
            // 检查结果
            script {
                if (fileExists('lint-result.txt') && readFile('lint-result.txt').contains('LINT_FAILED')) {
                    echo "WARNING: pnpm lint 失败"
                }
            }
        }
    }
}
```

#### E2E 验证测试
```groovy
stage('Verify') {
    steps {
        sh '''
            # E2E 验证：通过外部 URL 检查服务状态
            for i in $(seq 1 5); do
                if curl -sf --connect-timeout 5 --max-time 10 https://class.noda.co.nz/api/health; then
                    echo "E2E 验证通过 (attempt $i)"
                    exit 0
                fi
                sleep 2
            done
            echo "E2E 验证失败: class.noda.co.nz/api/health 不可达"
            exit 1
        '''
    }
}
```

## 测试结构

### 单元测试函数
```bash
# scripts/backup/lib/test-verify.sh

# 创建测试数据库
create_test_database()
{
    local original_db=$1
    local test_db="${TEST_DB_PREFIX}${original_db}"
    
    # 安全检查
    if [[ $test_db =~ ^test_restore_ ]]; then
        # 创建逻辑
        psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
            -d postgres -c "CREATE DATABASE $test_db"
    fi
}

# 验证表数量
verify_table_count()
{
    local test_db=$1
    local count
    count=$(psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
        -d "$test_db" -t -c "
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_type = 'BASE TABLE";
    
    return $([ $count -ge 1 ])
}

# 验证数据存在性
verify_data_exists()
{
    local test_db=$1
    
    # 获取第一个表
    local table=$(psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
        -d "$test_db" -t -c "
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_type = 'BASE TABLE'
        LIMIT 1" | xargs)
    
    # 检查记录数
    local count=$(psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
        -d "$test_db" -t -c "SELECT COUNT(*) FROM $table" | xargs)
    
    return $([ $count -gt 0 ])
}
```

### 健康检查模式
```bash
# scripts/lib/health.sh

# wait_container_healthy - 容器健康检查
# 参数：
#   $1: 容器名
#   $2: 超时秒数（默认90）
#   $3: 失败时是否打印日志（默认true）
wait_container_healthy()
{
    local container="$1"
    local timeout="${2:-90}"
    local show_logs="${3:-true}"
    local waited=0

    while [ $waited -lt $timeout ]; do
        local inspect
        inspect=$(docker inspect --format='{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo "missing|missing")
        
        case "${inspect%%|*}" in
            running)
                case "${inspect##*|}" in
                    healthy)
                        log_success "$container — healthy"
                        return 0
                        ;;
                    unhealthy)
                        log_error "$container — unhealthy"
                        [ "$show_logs" = true ] && docker logs "$container" --tail 15
                        return 1
                        ;;
                    starting)
                        sleep 3
                        waited=$((waited + 3))
                        ;;
                esac
                ;;
            missing)
                log_error "$container 不存在"
                return 1
                ;;
            *)
                sleep 3
                waited=$((waited + 3))
                ;;
        esac
    done

    log_error "$container — 健康检查超时"
    return 1
}
```

### 集成测试模式
```bash
# scripts/backup/test-verify-weekly.sh

# 单数据库测试流程
test_single_database()
{
    local db_name=$1
    
    # 1. 下载最新备份
    local backup_file=$(download_latest_backup "$db_name")
    
    # 2. 创建测试数据库
    local test_db=$(create_test_database "$db_name")
    
    # 3. 恢复数据
    restore_to_test_database "$backup_file" "$test_db"
    
    # 4. 验证数据
    verify_test_restore "$test_db" "$backup_file"
    
    # 5. 清理
    drop_test_database "$test_db"
    rm -f "$backup_file"
}

# 主测试流程
main()
{
    # 设置超时
    trap timeout_handler ALRM
    timeout $TEST_TIMEOUT $$ 2>/dev/null || true
    
    # 环境检查
    check_environment
    
    # 测试所有数据库
    local failed_count=0
    for db in $databases; do
        if ! test_single_database "$db"; then
            ((failed_count++)) || true
        fi
    done
    
    # 输出总结
    print_summary
    exit $([ $failed_count -eq 0 ])
}
```

## 测试策略

### 分层测试策略

#### Layer 1: 基础设施测试
```bash
# 容器健康检查
pipeline_infra_health_check()
{
    case "$service" in
        keycloak)
            wait_container_healthy "noda-infra-keycloak" 300
            ;;
        nginx)
            # 配置验证 + 健康检查
            docker exec noda-infra-nginx nginx -t
            wait_container_healthy "noda-infra-nginx" 30
            ;;
        postgres)
            # 数据库连接验证
            docker exec noda-infra-postgres-prod pg_isready
            wait_container_healthy "noda-infra-postgres-prod" 90
            ;;
    esac
}
```

#### Layer 2: 应用测试
```bash
# 应用部署前检查
pipeline_preflight()
{
    # 检查工具
    command -v node >/dev/null 2>&1 || {
        log_error "Node.js 未安装"
        return 1
    }
    command -v pnpm >/dev/null 2>&1 || {
        log_error "pnpm 未安装"
        return 1
    }
    
    # 检查项目文件
    [ -f "$apps_dir/package.json" ] || {
        log_error "package.json 不存在"
        return 1
    }
    
    # 检查备份新鲜度
    ! check_backup_freshness && {
        log_warn "备份检查未通过，继续部署"
    }
}
```

#### Layer 3: 数据验证测试
```bash
# 数据完整性验证
verify_test_restore()
{
    local test_db=$1
    local backup_file=$2
    
    # 文件完整性
    verify_backup_readable "$backup_file" || return $EXIT_VERIFY_TEST_FAILED
    
    # 数据结构验证
    verify_table_count "$test_db" || return $EXIT_VERIFY_TEST_FAILED
    
    # 数据完整性验证
    verify_data_exists "$test_db" || return $EXIT_VERIFY_TEST_FAILED
    
    return 0
}
```

### 自动化测试流程

#### Pipeline 测试顺序
```groovy
// Jenkins Pipeline 10阶段测试
stages {
    stage('Pre-flight')    // 前置检查
    stage('Build')        // 构建验证
    stage('Test')         // 代码测试
    stage('Deploy Pre-prod') // 预发布部署
    stage('Health Check Pre-prod') // 预发布健康检查
    stage('Deploy Prod')  // 生产部署
    stage('Verify')       // E2E 验证
    stage('CDN Purge')    // CDN 缓存清理
    stage('Cleanup')      // 资源清理
}
```

#### 蓝绿部署测试
```bash
# 生产环境部署测试
pipeline_deploy_prod()
{
    local git_sha="$1"
    local image="noda-apps:${git_sha}"
    
    # 1. 停止旧容器
    if [ "$(is_container_running "$PROD_CONTAINER")" = "true" ]; then
        docker stop -t 30 "$PROD_CONTAINER"
        docker rm "$PROD_CONTAINER"
    fi
    
    # 2. 启动新容器
    docker run -d \
        --name "$PROD_CONTAINER" \
        --network "$NETWORK_NAME" \
        --health-cmd "node -e \"fetch('http://localhost:3000/api/health')\"" \
        "$image"
    
    # 3. 健康检查
    if ! wait_container_healthy "$PROD_CONTAINER" 120; then
        # 4. 失败回滚
        docker rm -f "$PROD_CONTAINER" 2>/dev/null || true
        docker run -d --name "$PROD_CONTAINER" "noda-apps:rollback"
        return 1
    fi
    
    return 0
}
```

## 测试数据管理

### 测试数据库管理
```bash
# 测试数据库前缀
readonly TEST_DB_PREFIX="test_restore_"

# 创建安全测试数据库
create_test_database()
{
    local original_db=$1
    local test_db="${TEST_DB_PREFIX}${original_db}"
    
    # 安全检查：确保是测试数据库
    if [[ ! $test_db =~ ^test_restore_ ]]; then
        log_error "拒绝创建非测试数据库"
        return 1
    fi
    
    # 创建逻辑...
}

# 清理测试数据库
drop_test_database()
{
    local test_db=$1
    
    # 安全验证
    [[ ! $test_db =~ ^test_restore_ ]] && return 1
    
    # 删除逻辑...
}
```

### 备份文件管理
```bash
# 备份下载（带重试）
download_latest_backup()
{
    local db_name=$1
    local max_retries=$TEST_MAX_RETRIES
    local attempt=1
    
    while [ $attempt -le $max_retries ]; do
        # 下载逻辑...
        if [ -f "$backup_file" ]; then
            log_success "下载成功"
            echo "$backup_file"
            return 0
        fi
        
        ((attempt++))
        [ $attempt -le $max_retries ] && sleep $((2 ** (attempt - 1)))
    done
    
    log_error "下载失败"
    return $EXIT_DOWNLOAD_FAILED
}
```

## 测试结果处理

### 日志输出
```bash
# 结构化日志
echo "=========================================="
log_info "测试总结"
echo "=========================================="
echo "总耗时: ${total_duration} 秒"
echo "状态: $TEST_STATUS"
echo "测试时间: $(date -u -d @$TEST_START_TIME +'%Y-%m-%d %H:%M:%S UTC')"

# 失败处理
if [ $failed_count -gt 0 ]; then
    log_error "部分测试失败: $failed_count 个数据库"
    send_alert "weekly_test_failed" "all" "每周验证测试：$failed_count 个数据库失败"
    exit 1
fi
```

### 错误处理
```bash
# 统一错误处理函数
test_failure_handler()
{
    local exit_code=$?
    local service="$1"
    
    # 捕获日志
    docker logs "$container_name" --tail 50 >deploy-failure-${service}.log 2>&1 || true
    
    # 清理资源
    cleanup_after_test "$service"
    
    # 退出
    exit $exit_code
}

# 失败时自动清理
trap 'test_failure_handler "$service"' EXIT INT TERM
```

## 监控与告警

### 告警集成
```bash
# 发送告警
send_alert()
{
    local alert_type="$1"
    local resource="$2"
    local message="$3"
    
    # 邮件告警
    if [ -n "${ALERT_EMAIL:-}" ]; then
        echo "$message" | mail -s "[Noda Alert] $alert_type - $resource" "$ALERT_EMAIL"
    fi
    
    # 日志记录
    echo "$(date -u +'%Y-%m-%d %H:%M:%S UTC') [ALERT] $alert_type - $resource: $message" \
        >> "$HISTORY_FILE"
}

# 指标记录
record_metric()
{
    local test_type="$1"
    local resource="$2"
    local duration="$3"
    local size="$4"
    
    local metric_entry=$(jq -n \
        --arg type "$test_type" \
        --arg resource "$resource" \
        --arg duration "$duration" \
        --arg size "$size" \
        '{type: $type, resource: $resource, duration: ($duration | tonumber), size: ($size | tonumber), timestamp: now()}')
    
    echo "$metric_entry" >> "$METRICS_FILE"
}
```

### 性能监控
```bash
# 检查耗时异常
check_duration_anomaly()
{
    local db_name="$1"
    local test_type="$2"
    local duration="$3"
    
    # 获取历史平均耗时
    local avg_duration=$(jq -s "
        map(select(.type == \"$test_type\" and .resource == \"$db_name\"))
        | map(.duration)
        | add / length
    " "$METRICS_FILE")
    
    if [ -n "$avg_duration" ] && [ $(echo "$duration > $avg_duration * 2" | bc -l) -eq 1 ]; then
        log_warn "耗时异常: $db_name $test_type 耗时 ${duration}s (平均: ${avg_duration}s)"
        send_alert "duration_anomaly" "$db_name" "耗时异常: ${duration}s"
    fi
}
```

---

*测试模式分析：2026-05-17*