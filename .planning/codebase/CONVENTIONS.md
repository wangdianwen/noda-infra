# 编码规范

**分析日期：** 2026-05-17

## 文件命名

### Shell 脚本
- **文件后缀**: `.sh`
- **文件名**: 使用小写字母，下划线分隔，描述性命名
  - `pipeline-stages.sh` - Pipeline 阶段函数库
  - `deploy-infrastructure-prod.sh` - 基础设施部署脚本
  - `backup-verify-weekly.sh` - 备份验证脚本
- **脚本头部注释**:
  ```bash
  #!/bin/bash
  # ============================================
  # 脚本名称和功能描述
  # 作者：Noda 团队
  # 版本：1.0.0
  # ============================================
  
  set -euo pipefail
  ```

### Docker 相关文件
- **Dockerfile**: 使用全大写字母和下划线
  - `Dockerfile.noda-ops` - 运维工具集
  - `Dockerfile.findclass-ssr` - 应用服务
- **Compose 文件**: 使用连字符和描述性名称
  - `docker-compose.yml` - 基础配置
  - `docker-compose.prod.yml` - 生产环境覆盖
  - `docker-compose.apps-prod.yml` - 应用生产环境

### 配置文件
- **环境变量模板**: `env-*` 前缀
  - `env-noda-apps.env` - 应用环境变量
  - `env-keycloak.env` - Keycloak 环境变量
- **Nginx 配置**: 路径结构清晰
  - `config/nginx/nginx.conf` - 主配置
  - `config/nginx/conf.d/default.conf` - 默认站点
  - `config/nginx/snippets/` - 可复用配置片段

### Jenkins Pipeline
- **Jenkinsfile**: 首字母大写
  - `Jenkinsfile.apps` - 应用部署 Pipeline
  - `Jenkinsfile.infra` - 基础设施 Pipeline

## 代码风格

### Shell 脚本规范

#### 变量命名
```bash
# 全局常量使用大写
readonly EXIT_SUCCESS=0
readonly NETWORK_NAME="noda-network"

# 局部变量使用小写
container_name="noda-apps-prod"
timeout_seconds=90

# 配置变量使用下划线
BACKUP_HOST_DIR="/path/to/backup"
IMAGE_RETENTION_DAYS=7
```

#### 函数设计
```bash
# 函数名使用下划线
wait_container_healthy()
{
    # 参数检查
    if [ $# -lt 1 ]; then
        log_error "容器名参数缺失"
        return 1
    fi
    
    local container="$1"
    local timeout="${2:-90}"
    
    # 函数逻辑
    ...
}

# 返回值约定
# 0=成功，1=失败（遵循约定的退出码）
# 通过 echo 返回字符串数据
is_container_running()
{
    local name="$1"
    local running
    running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")
    echo "$running"
}
```

#### 错误处理
```bash
# 使用 log_* 函数输出日志
log_info "开始构建镜像"
log_success "构建完成"
log_error "构建失败" >&2
log_warn "警告信息"

# 严格模式
set -euo pipefail
# -e: 遇到错误立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任何命令失败则整个管道失败
```

#### 日志输出格式
```bash
# 标准日志库（scripts/lib/log.sh）
log_info  "ℹ️  信息提示"
log_warn  "⚠️  警告信息"
log_error "❌ 错误信息" >&2
log_success "✅ 成功信息"

# 带格式的日志
echo "=========================================="
log_info "开始部署阶段"
echo "=========================================="
```

### Docker Compose 规范

#### YAML 结构
```yaml
# 使用 YAML anchors 复用配置
x-common-security: &common-security
  security_opt:
    - no-new-privileges:true
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"

services:
  nginx:
    <<: *common-security
    # 服务特定配置
```

#### 环境变量管理
```yaml
# 运行时环境变量
environment:
  NODE_ENV: production
  DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/noda_prod

# 构建时环境变量
build:
  args:
    NEXT_PUBLIC_KEYCLOAK_URL: https://auth.noda.co.nz
```

#### 资源限制
```yaml
deploy:
  resources:
    limits:
      cpus: '1'
      memory: 1G
    reservations:
      cpus: '0.5'
      memory: 512M
```

### Dockerfile 规范

#### 多阶段构建
```dockerfile
# 构建阶段
FROM alpine:3.21 AS builder
# ... 构建逻辑

# 运行时阶段
FROM alpine:3.21
# 仅保留必要的二进制文件
COPY --from=builder /usr/local/bin/cloudflared /usr/local/bin/cloudflared
```

#### 安全加固
```dockerfile
# 非 root 用户
RUN addgroup -S nodaops && adduser -S -G nodaops nodaops

# 权限最小化
USER nodaops

# 只读文件系统
read_only: true

# 临时文件
tmpfs:
  - /tmp
  - /var/cache
```

## 错误处理模式

### 退出码常量
```bash
# 定义在 constants.sh 中
readonly EXIT_SUCCESS=0
readonly EXIT_CONNECTION_FAILED=1
readonly EXIT_BACKUP_FAILED=2
readonly EXIT_INVALID_ARGS=8
# ...
```

### 错误处理函数
```bash
# 1. 检查前置条件
pipeline_preflight()
{
    # 检查 Docker daemon
    docker info >/dev/null 2>&1 || {
        log_error "Docker daemon 不可用"
        return $EXIT_CONNECTION_FAILED
    }
    log_info "Docker daemon 可用"
    
    # ... 其他检查
}

# 2. 健康检查失败回滚
pipeline_deploy_prod()
{
    # ... 部署逻辑
    
    # 健康检查失败时回滚
    if ! wait_container_healthy "$PROD_CONTAINER" 120; then
        log_error "健康检查失败，回滚到 rollback 镜像..."
        docker rm -f "$PROD_CONTAINER" 2>/dev/null || true
        # ... 恢复逻辑
        return $EXIT_CONNECTION_FAILED
    fi
}

# 3. 清理函数（确保资源释放）
cleanup()
{
    local exit_code=$?
    
    # 清理临时文件
    rm -f "$tmp_file" 2>/dev/null || true
    
    # 清理临时容器
    docker rm -f "$container_name" 2>/dev/null || true
    
    exit $exit_code
}
```

### 信号处理
```bash
# 捕获中断信号
trap cleanup EXIT INT TERM

# 超时处理
timeout_handler()
{
    log_error "测试超时（${TEST_TIMEOUT}秒）"
    cleanup_on_timeout
    exit $EXIT_TIMEOUT
}
trap timeout_handler ALRM
```

## 模块化设计

### 函数库结构
```
scripts/
├── lib/
│   ├── log.sh          # 通用日志库
│   ├── health.sh       # 健康检查库
│   ├── secrets.sh     # 密钥管理库
│   ├── image-cleanup.sh # 镜像清理库
│   ├── cleanup.sh     # 通用清理库
│   └── deploy-check.sh # 部署检查库
├── pipeline-stages.sh  # Pipeline 阶段函数
└── deploy/
    ├── deploy-apps-prod.sh      # 应用部署
    └── deploy-infrastructure-prod.sh # 基础设施部署
```

### 库函数设计原则
1. **单一职责**：每个脚本只做一件事
2. **可复用性**：函数设计为通用组件
3. **幂等性**：多次执行结果相同
4. **日志输出**：内部调用 log_* 函数
5. **错误码**：返回约定好的退出码

### 示例：日志库设计
```bash
# scripts/lib/log.sh
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_RED='\033[0;31m'
_BLUE='\033[0;34m'
_NC='\033[0m'

log_info()
{
    printf "${_YELLOW}ℹ️  %s${_NC}\n" "$*"
}

log_success()
{
    printf "${_GREEN}✅ %s${_NC}\n" "$*"
}

# 导出供内联使用
GREEN="$_GREEN"
YELLOW="$_YELLOW"
RED="$_RED"
BLUE="$_BLUE"
NC="$_NC"
```

## 环境变量管理

### 密钥加载模式
```bash
# Doppler 密钥加载（推荐模式）
load_secrets()
{
    if [ -z "${DOPPLER_TOKEN:-}" ]; then
        log_error "DOPPLER_TOKEN 未设置"
        return 1
    fi
    
    # 不落盘模式
    _secrets=$(doppler secrets download --no-file --format=env --project noda)
    set -a
    eval "$_secrets"
    set +a
}
```

### 环境变量模板
```bash
# docker/env-noda-apps.env
# 生产环境变量模板（使用 envsubst 替换）
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
RESEND_API_KEY=${RESEND_API_KEY}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
# ...
```

### 构建时 vs 运行时变量
```yaml
# Dockerfile 构建时变量
ARG VITE_KEYCLOAK_URL=https://auth.noda.co.nz
ARG VITE_KEYCLOAK_REALM=noda

# Compose 运行时变量
environment:
  KEYCLOAK_URL: https://auth.noda.co.nz
  KEYCLOAK_REALM: noda
```

## 安全约定

### 容器安全
1. **非 root 运行**: 所有容器使用非特权用户
2. **能力最小化**: 只添加必要的 Linux capabilities
3. **只读文件系统**: `read_only: true`
4. **内存限制**: 设置合理的内存和 CPU 限制
5. **日志轮转**: 限制日志文件大小和数量

### 密钥安全
1. **Doppler 管理**: 所有密钥通过 Doppler 管理
2. **无落盘**: `--no-file` 选项不保存到磁盘
3. **临时文件**: 使用 `mktemp` 创建临时文件
4. **环境变量**: 通过 envsubst 生成临时 env 文件

### 网络安全
1. **外部访问**: 仅通过 nginx 反向代理访问
2. **内部网络**: 使用 Docker 网络（noda-network）
3. **端口管理**: 禁止直接暴露端口
4. **健康检查**: 使用 TCP/HTTP 健康检查

## 性能优化

### Docker 构建
```dockerfile
# 多阶段构建减小镜像大小
FROM alpine:3.21 AS builder
# ... 下载工具
FROM alpine:3.21
# 仅复制二进制文件
COPY --from=builder /usr/local/bin/cloudflared /usr/local/bin/cloudflared
```

### 资源限制
```yaml
deploy:
  resources:
    limits:
      cpus: '1'
      memory: 1G
    reservations:
      cpus: '0.5'
      memory: 512M
```

### 临时文件
```yaml
# 使用 tmpfs 避免写入磁盘
tmpfs:
  - /tmp
  - /var/cache/nginx
```

---

*编码规范分析：2026-05-17*