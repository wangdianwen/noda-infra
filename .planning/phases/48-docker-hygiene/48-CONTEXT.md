# Phase 48: 全局 Docker 卫生实践 - Context

**Gathered:** 2026-04-20
**Status:** Ready for planning

<domain>
## Phase Boundary

所有自建 Dockerfile 遵循 Docker 最佳实践：添加 .dockerignore、COPY --chown 替代 RUN chown、统一基础镜像版本。
范围限于 HYGIENE-01/02/03 三个需求，不涉及 findclass-ssr 的深度优化（Phase 49-51 负责）。

</domain>

<decisions>
## Implementation Decisions

### .dockerignore 粒度
- **D-01:** 按构建上下文定制 .dockerignore，不用统一模板
- **D-02:** deploy/ 目录放综合 .dockerignore（排除 .git、.planning、node_modules、worktrees、*.md 等），scripts/backup/docker/ 放精简版（仅排除 .git、.planning）
- **D-03:** 每个 .dockerignore 的排除规则应与对应 Dockerfile 的 COPY 指令对齐，避免排除构建需要的文件

### COPY --chown 范围
- **D-04:** 只改 backup、noda-ops、noda-site、test-verify 这 4 个稳定的 Dockerfile，findclass-ssr 留给 Phase 49-51
- **D-05:** 替换现有 RUN chown 为 COPY --chown，确保镜像层数不增加
- **D-06:** noda-site 的 Dockerfile 已有注释标记 Phase 48 优化点（RUN chown 可改为 COPY --chown）

### test-verify 兼容性
- **D-07:** 基础镜像从 postgres:15-alpine 升级到 postgres:17-alpine
- **D-08:** 升级后通过 Jenkins Pipeline 部署，然后执行手动 test-verify 验证
- **D-09:** prod PostgreSQL 已是 17，客户端升级理论上无兼容性风险

### Claude's Discretion
- 每个 .dockerignore 的具体排除条目列表
- COPY --chown 的具体用户/组值（沿用现有 RUN chown 中的值）
- 是否需要同时更新 test-verify 中其他依赖的版本

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` § HYGIENE-01, HYGIENE-02, HYGIENE-03 — 本 phase 的三个核心需求

### Dockerfile 参考
- `deploy/Dockerfile.backup` — backup 容器（base: postgres:17-alpine）
- `deploy/Dockerfile.noda-ops` — noda-ops 容器（base: alpine:3.21）
- `deploy/Dockerfile.noda-site` — noda-site 容器（base: nginx:1.25-alpine），第 50 行有 Phase 48 优化注释
- `scripts/backup/docker/Dockerfile.test-verify` — test-verify 容器（base: postgres:15-alpine，需升级）
- `deploy/Dockerfile.findclass-ssr` — **不在本 phase 范围内**，Phase 49-51 处理

### 部署相关
- `scripts/deploy/deploy-infrastructure-prod.sh` — 基础设施部署脚本
- `scripts/jenkins/Jenkinsfile.infra` — 基础设施 Pipeline（test-verify 可能通过此部署）

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Dockerfile.noda-site 第 50 行注释已标记 `Phase 48 可优化为 COPY --chown` — 明确的优化指引

### Established Patterns
- backup 和 noda-ops 都使用非 root 用户运行（nodaops:nodaops），COPY --chown 需匹配
- noda-site 使用 nginx:nginx 用户
- test-verify 以 root 运行（不需要 --chown）

### Integration Points
- deploy/ 是 4 个 Dockerfile 的共享构建上下文（但各自 COPY 不同文件）
- scripts/backup/docker/ 是 test-verify 的独立构建上下文
- test-verify 不在 docker-compose 中，通过脚本手动构建运行

</code_context>

<specifics>
## Specific Ideas

- deploy/ 目录下 4 个 Dockerfile 共享 .dockerignore，需要覆盖所有 4 个的排除需求
- test-verify 构建上下文仅包含 backup 脚本，.dockerignore 可以非常精简

</specifics>

<deferred>
## Deferred Ideas

- findclass-ssr 的 COPY --chown 优化 — 延迟到 Phase 49-51（Dockerfile 会被大幅重写）
- findclass-ssr 的 .dockerignore — 同上

</deferred>

---

*Phase: 48-docker-hygiene*
*Context gathered: 2026-04-20*
