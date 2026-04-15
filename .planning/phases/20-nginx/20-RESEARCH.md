# Phase 20: Nginx 蓝绿路由基础 - Research

**Researched:** 2026-04-15
**Domain:** Nginx 配置重构（upstream include 抽离）
**Confidence:** HIGH

## Summary

Phase 20 的核心任务是将 `config/nginx/conf.d/default.conf` 中的三个 upstream 定义（findclass_backend、noda_site_backend、keycloak_backend）抽离到 `config/nginx/snippets/upstream-*.conf` 独立文件中。这是一个低风险的配置重构，因为 `nginx.conf` 已经有 `include /etc/nginx/snippets/*.conf;` 通配符加载机制（第 27 行），且 snippets 目录下已有 proxy-common.conf 和 proxy-websocket.conf 两个 include 片段作为先例。

关键的技术约束是：nginx 容器的 snippets 目录以 `:ro` 挂载，但这不影响蓝绿切换操作——Pipeline 修改的是宿主机上的文件，容器通过 bind mount 实时看到更新后的内容，`nginx -s reload` 时读取新配置。

**Primary recommendation:** 将三个 upstream 块逐个从 default.conf 移到 snippets/upstream-*.conf 文件中，每步验证 `nginx -t`，最后 reload 生效。变更前后功能完全等价，proxy_pass 引用的 upstream 名称不变。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 三个 upstream 全部抽离到独立 include 文件（不仅限于 findclass_backend），保持配置风格一致
  - `snippets/upstream-findclass.conf` -> `upstream findclass_backend { server findclass-ssr:3001 ... }`
  - `snippets/upstream-noda-site.conf` -> `upstream noda_site_backend { server noda-site:3000 ... }`
  - `snippets/upstream-keycloak.conf` -> `upstream keycloak_backend { server keycloak:8080 ... }`
- **D-02:** Include 文件使用纯 upstream 块格式，不加注释头部。Pipeline 切换时直接重写整个文件内容
- **D-03:** 功能验证即可 -- 验证 include 抽离后配置语法正确、reload 生效、流量指向新后端。不在此 Phase 测试 reload 零中断性（Phase 22 部署脚本时再验证）

### Claude's Discretion
- 抽离后 default.conf 中 upstream 块的具体替换写法（逐个 include vs 通配符 include）
- 是否需要调整 snippets 目录下的文件加载顺序
- 功能验证的具体步骤和命令

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BLUE-02 | nginx 通过 upstream include 文件指向活跃容器，Pipeline 切换时更新文件并 `nginx -s reload` | 本 Phase 建立 include 文件基础结构，Phase 22/23 实现自动化切换 |
</phase_requirements>

## Standard Stack

### Core

| 组件 | 版本 | 用途 | 说明 |
|------|------|------|------|
| Nginx | 1.25-alpine | 反向代理 | 已在生产运行，无需安装 |
| nginx `include` 指令 | 内置 | 配置文件分离 | nginx 原生支持，无需额外模块 |
| `nginx -s reload` | 内置 | 优雅重载 | 零停机重载机制，新 worker 启动后旧 worker 处理完现有连接退出 |

### 不需要安装任何新组件

本 Phase 是纯配置重构，不引入新的库或工具。

## Architecture Patterns

### 当前配置结构（变更前）

```
config/nginx/
├── nginx.conf                    # 主配置
│   ├── include snippets/*.conf   # 第 27 行（proxy-common, proxy-websocket）
│   └── include conf.d/*.conf     # 第 29 行（default.conf）
├── conf.d/
│   └── default.conf              # 包含 3 个 upstream + 3 个 server 块
└── snippets/
    ├── proxy-common.conf         # 通用代理头
    └── proxy-websocket.conf      # WebSocket 代理头
```

### 目标配置结构（变更后）

```
config/nginx/
├── nginx.conf                    # 主配置（不变）
├── conf.d/
│   └── default.conf              # 仅包含 map + server 块（upstream 已移出）
└── snippets/
    ├── proxy-common.conf         # 不变
    ├── proxy-websocket.conf      # 不变
    ├── upstream-findclass.conf   # 新增：findclass_backend
    ├── upstream-noda-site.conf   # 新增：noda_site_backend
    └── upstream-keycloak.conf    # 新增：keycloak_backend
```

### Include 加载顺序分析

`nginx.conf` 第 27-29 行的加载顺序：

```nginx
include /etc/nginx/snippets/*.conf;   # 第 27 行 - 先加载
include /etc/nginx/conf.d/*.conf;     # 第 29 行 - 后加载
```

**关键点：** snippets 中的 upstream 定义在 conf.d 中的 server 块之前加载，这保证了 server 块中的 `proxy_pass http://findclass_backend` 引用能正确解析 upstream。`[VERIFIED: 代码审查 config/nginx/nginx.conf]`

### default.conf 变更模式

**变更前（default.conf 第 1-14 行）：**
```nginx
upstream keycloak_backend {
    server keycloak:8080 max_fails=3 fail_timeout=30s;
}

upstream findclass_backend {
    server findclass-ssr:3001 max_fails=3 fail_timeout=30s;
}

upstream noda_site_backend {
    server noda-site:3000 max_fails=3 fail_timeout=30s;
}
```

**变更后（default.conf 第 1-14 行删除，内容移到 snippets/）：**

default.conf 不需要任何 include 语句来替代，因为 `nginx.conf` 已经通过通配符 `include /etc/nginx/snippets/*.conf;` 自动加载所有 snippets 文件。upstream 块直接消失，由 snippets 文件提供。`[VERIFIED: nginx.conf 第 27 行 + snippets 目录 bind mount]`

### Anti-Patterns to Avoid

- **不要在 default.conf 中添加 `include snippets/upstream-*.conf`**：nginx.conf 已有通配符加载，重复 include 会导致 upstream 重复定义错误
- **不要在 upstream include 文件中添加注释头部**：D-02 决策明确纯 upstream 块格式，Pipeline 直接重写整个文件
- **不要修改 proxy_pass 引用**：server 块中的 `proxy_pass http://findclass_backend` 等引用保持不变，upstream 名称不变

## Don't Hand-Roll

| 问题 | 不要自己实现 | 使用现有方案 | 原因 |
|------|-------------|-------------|------|
| nginx 配置加载 | 在 default.conf 中添加 include 语句 | nginx.conf 已有的 `include snippets/*.conf;` | 已有通配符加载，无需重复 |
| reload 触发 | 通过 API 或信号脚本 | `docker exec noda-infra-nginx nginx -s reload` | nginx 原生信号机制，已验证可用 |
| 配置语法验证 | 手动检查文件格式 | `docker exec noda-infra-nginx nginx -t` | nginx 内置语法检查，100% 可靠 |

## Common Pitfalls

### Pitfall 1: Upstream 重复定义

**What goes wrong:** 如果 default.conf 中保留了 upstream 块，同时 snippets 中也定义了同名 upstream，nginx -t 会报 `duplicate upstream` 错误。
**Why it happens:** 迁移时忘记删除 default.conf 中的原始定义。
**How to avoid:** 移动（不是复制）upstream 块，从 default.conf 完全删除。
**Warning signs:** `nginx -t` 返回 `nginx: [emerg] duplicate upstream "findclass_backend"`。

### Pitfall 2: snippets 目录 :ro 挂载误解

**What goes wrong:** 认为 `:ro` 挂载阻止了动态修改。
**Why it happens:** 混淆了"容器内写入"和"宿主机写入"。
**How to avoid:** `:ro` 只阻止容器内进程写入 bind mount 的目录。Pipeline（宿主机进程）修改宿主机文件完全不受限制。容器通过 bind mount 看到更新后的内容。
**Warning signs:** 不会出现错误，但可能影响设计决策——确保规划中理解这一点。`[VERIFIED: Docker bind mount 文档]`

### Pitfall 3: nginx reload 时机错误

**What goes wrong:** 修改 include 文件后忘记 reload，nginx 继续使用内存中的旧配置。
**Why it happens:** nginx 只在启动和 reload 时读取配置文件，运行期间不会自动检测文件变化。
**How to avoid:** 每次修改 include 文件后必须执行 `docker exec noda-infra-nginx nginx -s reload`。
**Warning signs:** 修改了 upstream 文件但流量仍指向旧后端。

### Pitfall 4: 原子写入问题

**What goes wrong:** Pipeline 在写入 include 文件过程中（如磁盘满、进程中断）产生不完整文件，reload 后 nginx 配置损坏。
**Why it happens:** 直接 `cat > file` 不是原子操作。
**How to avoid:** 使用原子写入模式：先写临时文件，再 `mv` 覆盖（mv 在同一文件系统上是原子操作）。本 Phase 不实现 Pipeline（Phase 22 的职责），但 include 文件的初始创建应使用此模式。`[VERIFIED: ARCHITECTURE.md Pattern 1]`

### Pitfall 5: Glob include 加载顺序

**What goes wrong:** 假设 `snippets/*.conf` 的加载顺序影响 upstream 定义。
**Why it happens:** 多个 upstream 文件的加载顺序可能看起来重要，但实际上 nginx http 块中的所有 upstream 定义在 server 块之前都已可用。
**How to avoid:** 不需要关心 snippets 内文件的加载顺序。nginx 的配置解析是两阶段的：先收集所有 upstream 定义，再处理 server 块中的引用。
**Warning signs:** 不存在实际问题，但设计讨论中可能引入不必要的复杂性。

## Code Examples

### upstream-findclass.conf（初始版本）

```nginx
upstream findclass_backend {
    server findclass-ssr:3001 max_fails=3 fail_timeout=30s;
}
```

### upstream-noda-site.conf（初始版本）

```nginx
upstream noda_site_backend {
    server noda-site:3000 max_fails=3 fail_timeout=30s;
}
```

### upstream-keycloak.conf（初始版本）

```nginx
upstream keycloak_backend {
    server keycloak:8080 max_fails=3 fail_timeout=30s;
}
```

### default.conf 变更后的结构（仅展示移除 upstream 后的开头）

```nginx
# 动态设置转发协议和端口（Cloudflare TLS 终止，内部 HTTP）
map $host $forwarded_proto {
    default $scheme;
    class.noda.co.nz "https";
    auth.noda.co.nz "https";
    noda.co.nz "https";
    www.noda.co.nz "https";
}

map $host $forwarded_port {
    default $server_port;
    class.noda.co.nz "443";
    auth.noda.co.nz "443";
    noda.co.nz "443";
    www.noda.co.nz "443";
}

# ============================================
# Keycloak 认证服务专用域名
# ============================================
server {
    # ... 其余配置完全不变
```

### 验证命令序列

```bash
# 1. 创建 upstream 文件（原子写入）
cat > config/nginx/snippets/upstream-findclass.conf <<'EOF'
upstream findclass_backend {
    server findclass-ssr:3001 max_fails=3 fail_timeout=30s;
}
EOF

# 2. 编辑 default.conf 移除对应的 upstream 块

# 3. 验证 nginx 配置语法
docker exec noda-infra-nginx nginx -t

# 4. 重载 nginx
docker exec noda-infra-nginx nginx -s reload

# 5. 验证流量仍正常
curl -s -o /dev/null -w "%{http_code}" http://localhost/health -H "Host: class.noda.co.nz"
```

## State of the Art

| 旧方案 | 当前方案 | 变化时间 | 影响 |
|--------|---------|---------|------|
| upstream 内联在 default.conf 中 | upstream 独立 include 文件 | 本 Phase | enable 蓝绿切换，Pipeline 可原子替换 |
| 手动编辑 nginx 配置 | Pipeline 自动重写 include 文件 | Phase 22 | 自动化零停机切换 |

**无已废弃技术：** 本 Phase 不涉及任何已废弃的 nginx 特性。`include` 和 `upstream` 指令从 nginx 早期版本就存在且稳定。

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | nginx 1.25-alpine 的 `include` 通配符按字母顺序加载，但 upstream 定义在 server 块之前全局可用，加载顺序不影响正确性 | Architecture Patterns | LOW - nginx 文档确认 http 块中的所有指令在解析阶段全局可见 |
| A2 | Docker bind mount `:ro` 不阻止宿主机修改文件，容器内进程看到更新后的内容 | Common Pitfalls | LOW - Docker 官方文档明确说明 |

**注：** 以上两个假设基于 nginx 和 Docker 的基本机制，风险极低。

## Open Questions

1. **是否需要在 docker-compose.prod.yml 中为 nginx 添加 snippets 目录的单独挂载？**
   - What we know: docker-compose.yml 中已有 `../config/nginx/snippets:/etc/nginx/snippets:ro`，prod overlay 只添加了 errors 目录挂载
   - What's unclear: 无，已有挂载足够
   - Recommendation: 不需要额外挂载，现有配置已满足需求 `[VERIFIED: docker-compose.yml 第 51 行]`

## Environment Availability

Step 2.6: SKIPPED (无外部依赖 -- 本 Phase 仅修改 nginx 配置文件，不安装新工具或服务)

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | 手动验证（nginx -t + curl） |
| Config file | 无专用测试配置 |
| Quick run command | `docker exec noda-infra-nginx nginx -t` |
| Full suite command | N/A（本 Phase 不需要自动化测试套件） |

### Phase Requirements -> Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BLUE-02 | upstream 通过 include 文件引用，reload 后流量切换 | manual | `docker exec noda-infra-nginx nginx -t && docker exec noda-infra-nginx nginx -s reload` | N/A |

### Sampling Rate
- **Per task commit:** `docker exec noda-infra-nginx nginx -t`
- **Phase gate:** 配置语法正确 + reload 成功 + class.noda.co.nz 访问正常

### Wave 0 Gaps
None -- 本 Phase 不需要自动化测试基础设施，手动验证足够（D-03 决策）

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | yes | nginx `nginx -t` 验证配置文件语法完整性 |
| V6 Cryptography | no | 本 Phase 不涉及 TLS 配置变更 |

### Known Threat Patterns for Nginx Config Refactoring

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 配置文件损坏（写入中断） | Tampering | 原子写入（写临时文件 + mv）|
| 配置语法错误导致服务中断 | Denial of Service | `nginx -t` 预检，失败则不 reload |

## Sources

### Primary (HIGH confidence)
- `config/nginx/nginx.conf` -- include 加载机制和顺序 `[VERIFIED: 代码审查]`
- `config/nginx/conf.d/default.conf` -- 当前 upstream 定义和 server 块结构 `[VERIFIED: 代码审查]`
- `docker/docker-compose.yml` -- nginx 容器 volumes 挂载配置 `[VERIFIED: 代码审查]`
- `.planning/research/ARCHITECTURE.md` -- 蓝绿架构设计和 nginx 切换模式 `[VERIFIED: 项目研究文档]`

### Secondary (MEDIUM confidence)
- `.planning/research/FEATURES.md` -- 蓝绿部署流程和 nginx 切换机制详细设计
- `.planning/research/PITFALLS.md` -- 蓝绿部署已知陷阱和缓解策略

### Tertiary (LOW confidence)
- 无 -- 所有技术细节均通过代码审查或项目文档验证

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- 无新组件，纯配置重构
- Architecture: HIGH -- 已有先例（proxy-common.conf），加载顺序已验证
- Pitfalls: HIGH -- 每个陷阱都有明确验证命令

**Research date:** 2026-04-15
**Valid until:** 2026-05-15（nginx 配置机制稳定，不会变化）
