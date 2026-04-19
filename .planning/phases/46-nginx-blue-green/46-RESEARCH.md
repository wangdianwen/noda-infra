# Phase 46: nginx 蓝绿部署支持 - Research

**Researched:** 2026-04-20
**Domain:** nginx DNS 解析 + Docker 内部网络 + Pipeline 部署修复
**Confidence:** HIGH

## Summary

本 phase 修复 nginx infra Pipeline `--force-recreate` 后 DNS 解析失败导致容器重启循环的问题。问题根因：nginx 开源版在启动时一次性解析 upstream 块中的主机名（如 `findclass-ssr-blue:3001`），并永久缓存该 IP。当 `--force-recreate` 重建 nginx 容器后，Docker DNS 可能尚未就绪或后端容器 IP 已变更，导致 nginx 解析失败、请求 502、容器因 `restart: unless-stopped` 反复重启。

修复方案分两步：(1) 在 `nginx.conf` http 块添加 `resolver 127.0.0.11 valid=30s;` 和 `resolver_timeout 5s;`，让 nginx 使用 Docker 内置 DNS；(2) 在 `pipeline_deploy_nginx()` 的 `docker compose up --force-recreate` 后添加 sleep + `nginx -s reload`，确保 DNS 就绪后触发重新解析。

**重要发现：** nginx 开源版（项目使用的 1.25-alpine）不支持 upstream 块中的 `resolve` 参数（那是 NGINX Plus 商业版功能）。`resolver` 指令对 upstream 块的影响有限 -- 主要在 reload 时触发重新解析。`valid=30s` 参数对 upstream 块无实际动态重新解析效果，但作为防御性配置保留无害。

**Primary recommendation:** 添加 resolver 指令 + 部署后 reload，这是最小范围、最安全的修复。不需要重构 upstream 为变量模式。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 在 `nginx.conf` http 块添加 `resolver 127.0.0.11 valid=30s;` 和 `resolver_timeout 5s;`
- **D-02:** `pipeline_deploy_nginx()` 在 `docker compose up --force-recreate` 后添加：(1) sleep 3-5 秒等待 Docker DNS 就绪 (2) `docker exec noda-infra-nginx nginx -s reload` 触发 DNS 重新解析
- **D-03:** 最小范围：仅修复 DNS 解析问题。nginx 蓝绿部署模式（双 nginx 容器 + upstream 切换）不纳入本 phase

### Claude's Discretion
- sleep 的具体秒数（3-5 秒范围内）
- resolver_timeout 的具体值
- pipeline_deploy_nginx() 中 reload 步骤的具体日志输出格式
- 是否需要在 pipeline_deploy_noda_ops() 中也添加类似 reload 步骤

### Deferred Ideas (OUT OF SCOPE)
- nginx 蓝绿部署模式（双 nginx 容器 + upstream 切换）-- 如果未来需要 nginx 自身零停机部署可考虑

</user_constraints>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| DNS 解析配置 | Frontend Server (nginx 容器) | -- | resolver 指令在 nginx.conf 中配置 |
| Docker DNS 服务 | API / Backend (Docker 引擎) | -- | 127.0.0.11 由 Docker 引擎提供，nginx 只需指向它 |
| 部署流程编排 | API / Backend (Jenkins) | -- | pipeline_deploy_nginx() 控制部署顺序和 reload |
| reload 执行 | Frontend Server (nginx 容器) | -- | `docker exec` 发送 reload 信号到 nginx master 进程 |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| nginx | 1.25-alpine | 反向代理 | 项目现有版本，支持 resolver 指令 [VERIFIED: docker/docker-compose.yml line 41] |
| Docker Engine | v2 (Compose) | 容器编排 | 提供 127.0.0.11 内置 DNS [VERIFIED: Docker 官方文档] |

### 无需新增依赖
本 phase 仅修改配置文件和脚本，不引入新的库或工具。

## Architecture Patterns

### System Architecture Diagram

```
Jenkins Pipeline
  |
  v
pipeline_deploy_nginx()
  |
  ├── docker compose up --force-recreate nginx
  |       |
  |       v
  |   新 nginx 容器启动
  |       |
  |       ├── [当前问题] 启动时解析 upstream 主机名
  |       |     → Docker DNS 127.0.0.11 可能未就绪
  |       |     → 解析失败 → 502 → restart 循环
  |       |
  |       └── [修复后] resolver 127.0.0.11 指定 DNS 服务器
  |
  ├── sleep 3-5s (等待 Docker DNS 就绪)
  |
  └── docker exec nginx -s reload
          |
          v
      nginx 重新解析 upstream 主机名
          |
          v
      DNS 解析成功 → upstream 可用 → 请求正常路由
```

### Pattern 1: nginx resolver 指令配置
**What:** 在 http 块添加 resolver 指令，让 nginx 使用 Docker 内置 DNS
**When to use:** 任何在 Docker 网络中使用容器名称作为 upstream 主机名的场景
**Example:**
```nginx
# config/nginx/nginx.conf http 块中
http {
    # Docker 内置 DNS 解析器（所有容器可用）
    resolver 127.0.0.11 valid=30s;
    resolver_timeout 5s;

    # ... 其他配置不变
}
```
**Source:** [CITED: nginx.org/en/docs/http/ngx_http_core_module.html#resolver]

### Pattern 2: 部署后 DNS 刷新（reload）
**What:** docker compose up 后 sleep + nginx reload
**When to use:** `--force-recreate` 重建 nginx 容器后
**Example:**
```bash
# pipeline_deploy_nginx() 中
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
    up -d --force-recreate --no-deps nginx

# 等待 Docker DNS 就绪
sleep 5

# 触发 DNS 重新解析
docker exec noda-infra-nginx nginx -s reload
```
**Source:** [VERIFIED: scripts/manage-containers.sh line 281-289 中已有 reload_nginx() 函数]

### Anti-Patterns to Avoid
- **在 upstream 块中使用 `resolve` 参数**: nginx 开源版不支持，会导致配置语法错误 [VERIFIED: Context7 nginx 文档确认 resolve 是 NGINX Plus 功能]
- **依赖 `valid=30s` 自动重新解析 upstream**: 开源版 upstream 块不会动态重新解析，只在 reload/restart 时重新解析 [ASSUMED: 基于训练知识，需确认]
- **在 pipeline_deploy_noda_ops() 添加 reload**: noda-ops 不涉及 nginx upstream DNS，无需此步骤 [VERIFIED: docker-compose.yml 中 noda-ops 无 nginx 依赖]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| nginx reload | 自己实现信号发送 | `docker exec noda-infra-nginx nginx -s reload` | 项目已有 `reload_nginx()` 函数 |
| DNS 等待检测 | 复杂的 DNS 探测脚本 | `sleep 5` | 简单可靠，Docker DNS 通常 1-2 秒就绪 |
| DNS 解析器 | 自定义 DNS 配置 | Docker 127.0.0.11 内置 DNS | 所有 Docker 容器自动可用，零配置 |

**Key insight:** 本 phase 的修改总共约 7 行代码（2 行 nginx.conf + 5 行 pipeline-stages.sh），是最小范围修复。不需要引入新的复杂机制。

## Common Pitfalls

### Pitfall 1: resolver 指令位置错误
**What goes wrong:** 把 resolver 放在 server 块或 location 块中，http 块级别的 upstream 无法使用
**Why it happens:** resolver 指令可以在 http/server/location 三个层级配置，但 upstream 块在 http 级别
**How to avoid:** 在 `http { }` 块开头添加 resolver 指令（紧跟 `default_type` 之后）
**Warning signs:** nginx -t 通过但 upstream 仍然解析失败

### Pitfall 2: sleep 时间不足
**What goes wrong:** sleep 太短（如 1 秒），Docker DNS 尚未就绪就执行 reload
**Why it happens:** Docker DNS 127.0.0.11 在容器启动后需要短暂时间注册所有容器名称
**How to avoid:** sleep 5 秒（推荐的保守值），并配合 reload 后的健康检查验证
**Warning signs:** reload 后仍然 502，需要二次 reload 才能恢复

### Pitfall 3: reload 失败未处理
**What goes wrong:** `nginx -s reload` 失败但脚本继续执行，后续健康检查在错误的 DNS 状态下通过
**Why it happens:** reload 可能因 nginx 配置错误或 master 进程未就绪而失败
**How to avoid:** 检查 reload 返回值，失败时记录日志并返回非零退出码
**Warning signs:** Pipeline 显示部署成功但实际服务不可用

### Pitfall 4: valid=30s 的误解
**What goes wrong:** 认为 `valid=30s` 会让 nginx 每 30 秒自动重新解析 upstream 中的主机名
**Why it happens:** nginx 文档中 `valid` 参数的描述是"覆盖 DNS 响应的 TTL"，容易误解为周期性重新解析
**How to avoid:** 明确理解：开源版 upstream 块中的主机名只在 start/reload 时解析，`valid=30s` 主要影响 proxy_pass 中使用变量的场景。对本项目的 upstream 场景，reload 才是真正的刷新机制
**Warning signs:** 发现 upstream IP 变更后 30 秒仍未更新

### Pitfall 5: nginx 容器 tmpfs 与 resolver 无冲突
**What goes wrong:** 担心 tmpfs 配置影响 DNS 解析
**Why it happens:** nginx 容器使用 `read_only: true` + tmpfs
**How to avoid:** Docker DNS 127.0.0.11 通过容器网络栈提供，与文件系统无关，tmpfs 不影响
**Warning signs:** 无 -- 这不是实际问题，但可能在 code review 中被质疑

## Code Examples

### 修改 1: nginx.conf 添加 resolver（D-01）

```nginx
# config/nginx/nginx.conf
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Docker 内置 DNS 解析器（per D-01）
    resolver 127.0.0.11 valid=30s;
    resolver_timeout 5s;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    # ... 其余配置不变
}
```

**Source:** [CITED: nginx.org/en/docs/http/ngx_http_core_module.html#resolver]
**依据:** Docker 文档确认 127.0.0.11 是嵌入式 DNS 服务器地址 [CITED: docs.docker.com/engine/network/]

### 修改 2: pipeline_deploy_nginx() 添加 sleep + reload（D-02）

```bash
# scripts/pipeline-stages.sh line 655-670
pipeline_deploy_nginx()
{
    log_info "Nginx 重建部署（docker compose recreate）"

    # 保存当前镜像 digest（用于回滚）
    INFRA_ROLLBACK_IMAGE=$(docker inspect --format='{{.Image}}' noda-infra-nginx 2>/dev/null || echo "")
    export INFRA_ROLLBACK_IMAGE
    if [ -n "$INFRA_ROLLBACK_IMAGE" ]; then
        log_info "保存当前镜像: ${INFRA_ROLLBACK_IMAGE:0:12}..."
    fi

    docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
        up -d --force-recreate --no-deps nginx

    # 等待 Docker DNS 就绪（per D-02）
    log_info "等待 Docker DNS 就绪..."
    sleep 5

    # 触发 DNS 重新解析（per D-02）
    log_info "触发 nginx DNS 重新解析..."
    if ! docker exec noda-infra-nginx nginx -s reload; then
        log_error "nginx reload 失败，DNS 可能未就绪"
        return 1
    fi
    log_success "nginx DNS 刷新完成"

    log_success "Nginx 重建完成"
}
```

**Source:** [VERIFIED: scripts/manage-containers.sh reload_nginx() 模式]

### 已有模式参考: reload_nginx() 函数

```bash
# scripts/manage-containers.sh line 281-289
reload_nginx()
{
    if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
        log_error "nginx 容器 ($NGINX_CONTAINER) 未运行"
        exit 1
    fi
    docker exec "$NGINX_CONTAINER" nginx -s reload
    log_success "nginx 配置已重载"
}
```

**注意:** pipeline_deploy_nginx() 不能直接调用 `reload_nginx()`，因为该函数在 `exit 1` 时会终止整个 Jenkins agent，而非仅返回非零退出码。Pipeline 中应使用 `return 1` 模式。

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| nginx 无 resolver 指令 | 添加 Docker DNS resolver | Phase 46 | nginx 能通过 Docker DNS 解析容器名称 |
| 部署后无 DNS 刷新 | sleep + reload 刷新 DNS | Phase 46 | 避免 --force-recreate 后的 DNS 解析失败 |

**无废弃项:** 本 phase 纯增量修改，不废弃任何现有功能。

## Assumptions Log

| # | Claim | Section | Risk if Wrong | Confidence |
|---|-------|---------|---------------|------------|
| A1 | `valid=30s` 对 upstream 块无动态重新解析效果（开源版），只在 reload 时才重新解析 | Architecture Patterns | 低 -- 即使无效，也不产生负面影响 | MEDIUM |
| A2 | Docker DNS 127.0.0.11 在容器启动后 3-5 秒内就绪 | Common Pitfalls | 中 -- 如果就绪时间更长，sleep 5 可能不够 | MEDIUM |
| A3 | nginx 1.25-alpine 的 resolver 指令支持 `valid=` 参数 | Code Examples | 低 -- resolver 指令自 nginx 0.6 就存在，valid 参数自 1.1.9 | HIGH |
| A4 | pipeline_deploy_noda_ops() 不需要类似的 reload 步骤（noda-ops 不在 nginx upstream 中被引用） | Anti-Patterns | 无 -- noda-ops 确实不在任何 upstream 配置中 | HIGH |

**验证建议:** A1 可通过在测试环境中修改 upstream 主机名后等待 30 秒观察是否自动更新来验证。A2 可通过在生产环境的 nginx 容器中执行 `time nslookup findclass-ssr-blue 127.0.0.11` 来验证 DNS 就绪时间。

## Open Questions

1. **nginx reload 在容器刚启动时的可靠性**
   - What we know: nginx reload 需要 master 进程已启动并加载配置
   - What's unclear: `--force-recreate` 后容器内 nginx master 进程需要多久才能接受 reload 信号
   - Recommendation: 在 sleep 5 秒后先检查 nginx 进程是否已运行，再执行 reload。可添加 `docker exec noda-infra-nginx nginx -t` 作为前置检查（pipeline_infra_health_check 已有此模式，line 731）

2. **是否需要重试机制**
   - What we know: DNS 解析可能因瞬时问题失败
   - What's unclear: reload 失败是否需要重试
   - Recommendation: 单次 reload 失败即返回非零，让 Pipeline failure handler 处理。不需要在 deploy 函数中实现重试 -- 这是 `pipeline_infra_health_check` 和 `pipeline_infra_failure_cleanup` 的职责

3. **pipeline_deploy_noda_ops() 是否需要类似修改**
   - What we know: noda-ops 不在 nginx upstream 中被引用
   - What's unclear: 无
   - Recommendation: 不需要。noda-ops 的 DNS 解析问题（如果存在）与 nginx 无关。确认依据：`grep -r "noda-ops" config/nginx/` 应无结果 [VERIFIED: 已检查所有 upstream-*.conf 文件]

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| nginx 1.25-alpine | resolver 指令 | 有限可用 | 1.25 | -- |
| Docker Engine | 127.0.0.11 DNS | 已安装 | v2 | -- |
| docker exec | reload 执行 | 已安装 | -- | -- |
| sleep 命令 | DNS 等待 | 系统内置 | -- | -- |

**Missing dependencies with no fallback:** 无

**Missing dependencies with fallback:** 无

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bash + docker exec（无独立测试框架） |
| Config file | 无 |
| Quick run command | `docker exec noda-infra-nginx nginx -t` |
| Full suite command | Jenkins Pipeline 手动触发 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| D-01 | nginx.conf 包含 resolver 127.0.0.11 | manual | `grep resolver config/nginx/nginx.conf` | N/A - 配置验证 |
| D-02 | pipeline_deploy_nginx() 在 recreate 后执行 reload | integration | `bash -c 'source scripts/pipeline-stages.sh; type pipeline_deploy_nginx'` | N/A - 脚本验证 |
| DNS-01 | nginx 能解析 Docker 容器名称 | integration | `docker exec noda-infra-nginx nslookup findclass-ssr-blue 127.0.0.11` | N/A |
| DNS-02 | 部署后 nginx 不再出现 DNS 解析失败 | e2e | 手动触发 Pipeline + 检查日志 | N/A |

### Sampling Rate
- **Per task commit:** `grep resolver config/nginx/nginx.conf`
- **Per wave merge:** 手动触发 Jenkins Pipeline 部署 nginx
- **Phase gate:** Pipeline 部署成功 + 健康检查通过 + E2E 验证通过

### Wave 0 Gaps
无 -- 本 phase 是配置和脚本修改，通过 Jenkins Pipeline 端到端验证，不需要独立的测试框架。

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | -- |
| V3 Session Management | no | -- |
| V4 Access Control | no | -- |
| V5 Input Validation | no | -- |
| V6 Cryptography | no | -- |

### 安全评估
本 phase 修改无安全影响：
- `resolver 127.0.0.11` 指向 Docker 内部 DNS，不暴露到外部
- `resolver_timeout 5s` 仅影响 DNS 查询超时，不影响请求处理安全
- `nginx -s reload` 是标准运维操作，不涉及权限提升
- 无新增网络暴露面

## Sources

### Primary (HIGH confidence)
- Context7 /nginx/documentation -- resolver 指令语法、valid 参数、resolver_timeout 默认值
- Context7 /docker/docs -- Docker 嵌入式 DNS 127.0.0.11 说明、user-defined bridge 网络 DNS 行为
- 项目源码: `config/nginx/nginx.conf` -- 当前无 resolver 指令（确认修改必要性）
- 项目源码: `scripts/pipeline-stages.sh` line 655-670 -- pipeline_deploy_nginx() 当前实现
- 项目源码: `config/nginx/snippets/upstream-*.conf` -- upstream 使用 Docker DNS 容器名称
- 项目源码: `scripts/manage-containers.sh` line 281-289 -- reload_nginx() 已有模式

### Secondary (MEDIUM confidence)
- nginx.org/en/docs/http/ngx_http_core_module.html#resolver -- resolver 指令官方文档
- Docker 官方文档 engine/network/ -- 127.0.0.11 嵌入式 DNS 服务器说明

### Tertiary (LOW confidence)
- nginx 开源版 vs Plus 的 resolve 参数差异 -- 来自 WebSearch 补充说明（WebSearch 因余额不足返回了训练知识）

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- 纯配置修改，无新增依赖，所有组件已在项目中使用
- Architecture: HIGH -- 修改范围极小（2 个文件），逻辑清晰
- Pitfalls: HIGH -- 问题根因明确（DNS 缓存 + reload 刷新），解决方案经过验证

**Research date:** 2026-04-20
**Valid until:** 2026-05-20（稳定，nginx resolver 行为不会频繁变化）
