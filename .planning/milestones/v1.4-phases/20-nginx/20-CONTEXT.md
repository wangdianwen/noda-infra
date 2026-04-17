# Phase 20: Nginx 蓝绿路由基础 - Context

**Gathered:** 2026-04-15
**Status:** Ready for planning

<domain>
## Phase Boundary

将 nginx 配置中的 upstream 定义从 `default.conf` 抽离到独立 include 文件，使 Pipeline 可以通过重写 include 文件 + `nginx -s reload` 实现流量切换。

范围包括：
- 三个 upstream（findclass、noda-site、keycloak）全部抽离到独立 include 文件
- `default.conf` 改为 `include snippets/upstream-*.conf` 引用
- 验证 reload 切换后流量指向新后端

</domain>

<decisions>
## Implementation Decisions

### Upstream 抽离范围
- **D-01:** 三个 upstream 全部抽离到独立 include 文件（不仅限于 findclass_backend），保持配置风格一致
  - `snippets/upstream-findclass.conf` → `upstream findclass_backend { server findclass-ssr:3001 ... }`
  - `snippets/upstream-noda-site.conf` → `upstream noda_site_backend { server noda-site:3000 ... }`
  - `snippets/upstream-keycloak.conf` → `upstream keycloak_backend { server keycloak:8080 ... }`

### Include 文件格式
- **D-02:** Include 文件使用纯 upstream 块格式，不加注释头部。Pipeline 切换时直接重写整个文件内容

### 验证方式
- **D-03:** 功能验证即可 — 验证 include 抽离后配置语法正确、reload 生效、流量指向新后端。不在此 Phase 测试 reload 零中断性（Phase 22 部署脚本时再验证）

### Claude's Discretion
- 抽离后 default.conf 中 upstream 块的具体替换写法（逐个 include vs 通配符 include）
- 是否需要调整 snippets 目录下的文件加载顺序
- 功能验证的具体步骤和命令

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 现有配置文件
- `config/nginx/conf.d/default.conf` — 当前包含 3 个内联 upstream 定义 + server 块（需要修改）
- `config/nginx/nginx.conf` — 主配置，已有 `include /etc/nginx/snippets/*.conf;` 自动加载 snippets
- `config/nginx/snippets/proxy-common.conf` — 代理头配置（保持不变）
- `config/nginx/snippets/proxy-websocket.conf` — WebSocket 代理头配置（保持不变）

### Docker 配置
- `docker/docker-compose.yml` — nginx 容器定义，volumes 挂载 snippets 目录 `:ro`
- `docker/docker-compose.app.yml` — findclass-ssr 和 noda-site 容器定义

### 需求文档
- `.planning/REQUIREMENTS.md` — BLUE-02 需求定义
- `.planning/ROADMAP.md` Phase 20 — 成功标准

### 脚本参考
- `scripts/deploy/deploy-infrastructure-prod.sh` — 现有部署脚本模式
- `scripts/lib/log.sh` — 结构化日志库
- `scripts/lib/health.sh` — 健康检查工具

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `config/nginx/nginx.conf:28` — 已有 `include /etc/nginx/snippets/*.conf;` 通配符加载，upstream 文件放入 snippets/ 即可自动加载，无需修改 nginx.conf
- `config/nginx/snippets/` — 已有 2 个 include 片段（proxy-common.conf、proxy-websocket.conf），新增 upstream 文件符合现有目录组织

### Established Patterns
- nginx 容器通过 volumes 挂载宿主机配置目录（`:ro` 模式）
- Jenkins（宿主机）修改宿主机文件后通过 `docker exec nginx -s reload` 触发重读
- 所有脚本使用 `set -euo pipefail` + `source scripts/lib/log.sh`

### Integration Points
- Phase 21 将修改 `upstream-findclass.conf` 内容，从 `findclass-ssr:3001` 切换为 `findclass-ssr-blue:3001` 或 `findclass-ssr-green:3001`
- Phase 22 部署脚本将实现自动化切换逻辑（重写文件 + reload + 验证）
- Phase 23 Jenkins Pipeline 通过 `sh` 步骤调用切换命令

</code_context>

<specifics>
## Specific Ideas

- nginx.conf 中 `include /etc/nginx/snippets/*.conf;` 位于 `include /etc/nginx/conf.d/*.conf;` 之前，upstream 定义先于 server 块加载，顺序正确
- `default.conf` 中的 `map` 指令和 `server` 块保留在原文件不动，只移走 `upstream` 块
- noda-site 的蓝绿部署模式与 findclass-ssr 相同（CLAUDE.md 已规划）

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 20-nginx*
*Context gathered: 2026-04-15*
