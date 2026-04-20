# Phase 48: 全局 Docker 卫生实践 - Research

**Researched:** 2026-04-20
**Domain:** Docker 构建优化（.dockerignore、COPY --chown、基础镜像统一）
**Confidence:** HIGH

## Summary

Phase 48 涉及 4 个自建 Dockerfile 的 Docker 最佳实践优化：添加 .dockerignore 减少构建上下文、用 COPY --chown 减少 RUN chown 产生的冗余层、将 test-verify 基础镜像从 postgres:15-alpine 升级到 postgres:17-alpine 与 backup 共享层缓存。

核心发现：这 4 个 Dockerfile 分布在两个不同的构建上下文中——deploy/ 目录下的 backup、noda-ops、noda-site 共享项目根目录作为构建上下文，scripts/backup/docker/ 下的 test-verify 的构建上下文需要确认（Dockerfile 中的 COPY 路径暗示实际构建上下文是项目根目录，而非 Dockerfile 所在的 `scripts/backup/docker/` 目录）。

**Primary recommendation:** 按构建上下文分两波实施——先处理 deploy/ 目录下的 3 个 Dockerfile + 项目根目录 .dockerignore，再处理 test-verify + 确认其构建上下文。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 按构建上下文定制 .dockerignore，不用统一模板
- **D-02:** deploy/ 目录放综合 .dockerignore（排除 .git、.planning、node_modules、worktrees、*.md 等），scripts/backup/docker/ 放精简版（仅排除 .git、.planning）
- **D-03:** 每个 .dockerignore 的排除规则应与对应 Dockerfile 的 COPY 指令对齐，避免排除构建需要的文件
- **D-04:** 只改 backup、noda-ops、noda-site、test-verify 这 4 个稳定的 Dockerfile，findclass-ssr 留给 Phase 49-51
- **D-05:** 替换现有 RUN chown 为 COPY --chown，确保镜像层数不增加
- **D-06:** noda-site 的 Dockerfile 已有注释标记 Phase 48 优化点（RUN chown 可改为 COPY --chown）
- **D-07:** 基础镜像从 postgres:15-alpine 升级到 postgres:17-alpine
- **D-08:** 升级后通过 Jenkins Pipeline 部署，然后执行手动 test-verify 验证
- **D-09:** prod PostgreSQL 已是 17，客户端升级理论上无兼容性风险

### Claude's Discretion
- 每个 .dockerignore 的具体排除条目列表
- COPY --chown 的具体用户/组值（沿用现有 RUN chown 中的值）
- 是否需要同时更新 test-verify 中其他依赖的版本

### Deferred Ideas (OUT OF SCOPE)
- findclass-ssr 的 COPY --chown 优化 -- 延迟到 Phase 49-51（Dockerfile 会被大幅重写）
- findclass-ssr 的 .dockerignore -- 同上
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| HYGIENE-01 | 所有自建 Dockerfile 添加/更新 .dockerignore（排除 .git、.planning、node_modules、worktrees） | 构建上下文分析（本文件 "构建上下文映射" 部分）|
| HYGIENE-02 | 所有 COPY 指令使用 --chown 替代单独 RUN chown（减少镜像层数） | COPY --chown 语法和各 Dockerfile 的 chown 审计（本文件 "RUN chown 审计" 部分）|
| HYGIENE-03 | test-verify 基础镜像从 postgres:15-alpine 统一到 postgres:17-alpine（与 backup 共享层缓存）| postgres 兼容性分析（本文件 "test-verify 升级分析" 部分）|
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| .dockerignore 文件 | 构建系统 | -- | 决定发送到 Docker daemon 的构建上下文内容 |
| COPY --chown 优化 | Dockerfile（构建定义） | -- | 镜像层优化，纯构建时改动 |
| 基础镜像版本统一 | Dockerfile（构建定义） | -- | 层缓存共享，纯构建时改动 |
| 升级后功能验证 | 运行时 | Jenkins Pipeline | 需要实际运行容器验证 |

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Docker BuildKit | 默认启用 | 构建引擎 | Docker Desktop / Docker 24+ 默认使用 BuildKit，支持 COPY --chown [ASSUMED] |
| .dockerignore | Docker 原生 | 构建上下文过滤 | Docker 官方推荐的标准实践 [CITED: docs.docker.com] |

### Supporting
| Library/Tool | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| postgres:17-alpine | 官方镜像 | test-verify 基础镜像 | 替换 postgres:15-alpine，与 prod PostgreSQL 17.9 和 backup 容器共享层 [VERIFIED: docker-compose.yml] |

**Installation:**
无新依赖需要安装。所有改动都是 Dockerfile 和 .dockerignore 文件的编辑。

## Architecture Patterns

### System Architecture Diagram

```
项目根目录 (noda-infra/)
  |
  |-- deploy/                            <-- Dockerfile 集中存放
  |     |-- Dockerfile.backup            (构建上下文: 项目根目录)
  |     |-- Dockerfile.noda-ops          (构建上下文: 项目根目录)
  |     |-- Dockerfile.noda-site         (构建上下文: ../../noda-apps)
  |     |-- Dockerfile.findclass-ssr     [OUT OF SCOPE]
  |     +-- .dockerignore                <-- 需要新建（综合版）
  |
  |-- scripts/backup/docker/
  |     |-- Dockerfile.test-verify       (构建上下文: 待确认)
  |     +-- .dockerignore                <-- 需要新建（精简版）
  |
  +-- .dockerignore                      <-- 不需要（deploy/ 是子目录）

构建上下文 -> .dockerignore 匹配规则:
  项目根目录为上下文时 -> deploy/.dockerignore 不生效，需在项目根目录放
  noda-apps 为上下文时 -> noda-apps 目录的 .dockerignore 生效
```

### 构建上下文映射

**关键发现：.dockerignore 必须放在构建上下文根目录中才生效。** [CITED: docs.docker.com/build/concepts/context/]

| Dockerfile | 构建上下文 | .dockerignore 位置 | 引用来源 |
|------------|-----------|-------------------|---------|
| `deploy/Dockerfile.noda-ops` | `..`（项目根目录） | **项目根目录** `./.dockerignore` | `docker/docker-compose.yml` 第 63 行 |
| `deploy/Dockerfile.backup` | `.`（项目根目录，通过 deploy.sh） | **项目根目录** `./.dockerignore` | `deploy.sh` 第 33 行 |
| `deploy/Dockerfile.noda-site` | `../../noda-apps` | **noda-apps 目录** `../../noda-apps/.dockerignore` | `docker/docker-compose.app.yml` 第 82 行 |
| `scripts/backup/docker/Dockerfile.test-verify` | 待确认（见下方分析） | 待确认 | 手动构建 |

**重要修正 D-02：** CONTEXT.md 说 "deploy/ 目录放综合 .dockerignore"，但实际构建上下文不是 deploy/ 而是 `..`（项目根目录）。因此 .dockerignore 应放在项目根目录，而不是 deploy/ 目录。noda-site 的构建上下文是 noda-apps，也需要在 noda-apps 中放 .dockerignore（但 noda-site 在本 phase 范围内只有 COPY --chown 改动，不涉及 .dockerignore，因为其构建上下文在另一个仓库）。

**关于 noda-site 的 .dockerignore：** noda-site 的构建上下文是 `../../noda-apps`（另一个仓库），本 phase 不应修改另一个仓库的 .dockerignore。noda-site 仅做 COPY --chown 优化。

### test-verify 构建上下文分析

Dockerfile.test-verify 中的 COPY 指令：
```dockerfile
COPY scripts/backup/lib/*.sh /scripts/lib/
COPY scripts/backup/test-verify-weekly.sh /scripts/
```

如果构建上下文是 `scripts/backup/docker/`（Dockerfile 所在目录），这些 COPY 路径将找不到文件。实际构建上下文必须是项目根目录（包含 `scripts/backup/lib/` 和 `scripts/backup/test-verify-weekly.sh`）。

**结论：** test-verify 的构建上下文是项目根目录。.dockerignore 应放在项目根目录（与其他 deploy/ Dockerfile 共享）。

但 CONTEXT.md 的 specifics 说 "scripts/backup/docker/ 是 test-verify 的独立构建上下文"——这与 Dockerfile 中的 COPY 路径矛盾。需要 planner 确认实际的构建命令。

**建议方案：**
1. 如果构建上下文确实是项目根目录，则项目根目录的 .dockerignore 同时覆盖 noda-ops、backup 和 test-verify
2. 如果需要 test-verify 使用独立构建上下文，则需同时修改 Dockerfile 中的 COPY 路径（去掉 `scripts/backup/` 前缀）

### Recommended Project Structure
```
noda-infra/
+-- .dockerignore                       <-- [新建] 综合 .dockerignore（覆盖 noda-ops、backup、test-verify）
+-- deploy/
|     |-- Dockerfile.backup             <-- [修改] COPY --chown
|     |-- Dockerfile.noda-ops           <-- [修改] COPY --chown
|     +-- Dockerfile.noda-site          <-- [修改] COPY --chown（第 50-51 行）
+-- scripts/backup/docker/
      |-- Dockerfile.test-verify        <-- [修改] 基础镜像升级 + COPY --chown（如需要）
      +-- (可能需要调整 COPY 路径，取决于构建上下文)
```

## RUN chown 审计

### Dockerfile.backup
**当前状态：** 无 RUN chown 指令。容器以 root 运行（继承 postgres:17-alpine 的默认用户）。[VERIFIED: deploy/Dockerfile.backup]

**需要改动：** 无 -- 该 Dockerfile 不需要 COPY --chown。

### Dockerfile.noda-ops
**当前状态：** 有两处 chown 指令。[VERIFIED: deploy/Dockerfile.noda-ops]

```dockerfile
# 第 51 行
COPY scripts/backup/ /app/backup/
RUN find /app/backup -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# 第 54 行
COPY deploy/crontab /etc/crontabs/nodaops

# 第 57 行
COPY deploy/supervisord.conf /etc/supervisord.conf

# 第 60 行
COPY deploy/entrypoint-ops.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# 第 65 行 -- 关键优化目标
RUN chown -R nodaops:nodaops /app /var/log/supervisor /var/log/noda-backup /app/history /run/supervisor

# 第 66 行
RUN mkdir -p /home/nodaops/.config/rclone && chown -R nodaops:nodaops /home/nodaops
```

**优化方案：**
- 第 51 行的 `COPY scripts/backup/ /app/backup/` 可以加 `--chown=nodaops:nodaops`（但后面有 chmod，需要保留 RUN 层）
- 第 54、57、60 行的 COPY 可以加 `--chown=nodaops:nodaops`
- 第 65 行的 `RUN chown -R` 可以部分合并到 COPY 中，但 `/var/log/supervisor`、`/var/log/noda-backup`、`/run/supervisor` 不是 COPY 目标，仍需要 RUN mkdir + chown
- **实际可优化：** 将 COPY + chmod 合并（COPY --chown + RUN chmod），以及将两个 RUN chown 合并为一个

**注意：** `chmod +x` 操作不能通过 COPY --chmod 实现（需要 BuildKit），但 `--chown` 可以与 `--chmod` 组合使用 [ASSUMED]。保守方案是仅用 `--chown`，保留 chmod RUN 层。

### Dockerfile.noda-site
**当前状态：** 第 50-51 行有明确的优化注释。[VERIFIED: deploy/Dockerfile.noda-site]

```dockerfile
# 设置目录权限（Phase 48 可优化为 COPY --chown）
RUN chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx
```

**优化方案：**
- 第 48 行 `COPY --from=builder /app/apps/site/dist /usr/share/nginx/html` 改为 `COPY --from=builder --chown=nginx:nginx /app/apps/site/dist /usr/share/nginx/html`
- 第 44-45 行的 COPY nginx 配置文件也可以加 `--chown=nginx:nginx`
- 删除第 51 行的 `RUN chown -R`
- `/var/cache/nginx` 不是 COPY 目标，但其权限由 nginx 基础镜像管理，可能不需要手动 chown [ASSUMED]

### Dockerfile.test-verify
**当前状态：** 容器以 root 运行。无 RUN chown 指令。[VERIFIED: scripts/backup/docker/Dockerfile.test-verify]

**需要改动：** 无 COPY --chown 改动 -- 该 Dockerfile 不需要（以 root 运行）。

**但需要改动基础镜像：** `FROM postgres:15-alpine` -> `FROM postgres:17-alpine`

## .dockerignore 设计

### 项目根目录 .dockerignore（覆盖 noda-ops、backup、test-verify）

**构建上下文分析：** 项目根目录包含大量不需要的文件。noda-ops Dockerfile 的 COPY 目标：
- `scripts/backup/` -> `/app/backup/`
- `deploy/crontab` -> `/etc/crontabs/nodaops`
- `deploy/supervisord.conf` -> `/etc/supervisord.conf`
- `deploy/entrypoint-ops.sh` -> `/app/entrypoint.sh`

test-verify Dockerfile 的 COPY 目标：
- `scripts/backup/lib/*.sh` -> `/scripts/lib/`
- `scripts/backup/test-verify-weekly.sh` -> `/scripts/`

backup Dockerfile 的 COPY 目标：
- `scripts/backup/` -> `/app/`
- `deploy/crontab` -> `/etc/crontabs/root`
- `deploy/entrypoint.sh` -> `/app/entrypoint.sh`

**推荐排除列表（综合版）：**
```dockerignore
# 版本控制
.git
.gitignore

# 开发工具配置
.editorconfig
.shellcheckrc
.claude/

# 规划文档
.planning/

# 文档（不需要进入镜像）
docs/
*.md
LICENSE

# Docker 配置文件（防止递归）
docker/
docker-compose*.yml
.dockerignore

# 部署脚本（构建产物由 Dockerfile 控制）
deploy.sh
setup-dev.sh

# Jenkins（不需要进入镜像）
jenkins/

# 示例和测试（backup 的 tests/ 不需要进入镜像）
examples/
scripts/backup/tests/

# 备份的敏感配置
scripts/backup/.env.backup
scripts/backup/.env.example
scripts/backup/.gitignore
scripts/backup/TEST_REPORT.md
scripts/backup/DEPLOYMENT_SUMMARY.md
scripts/backup/DATA_VOLUME_CHECK.md

# 其他不需要的目录
services/
config/

# 临时文件
*.tmp
*.bak
*.swp
*~
```

**验证规则：** 确保以下路径不被排除：
- `scripts/backup/` （noda-ops 和 backup 需要）
- `scripts/backup/lib/` （test-verify 需要）
- `scripts/backup/test-verify-weekly.sh` （test-verify 需要）
- `deploy/crontab` （noda-ops 和 backup 需要）
- `deploy/entrypoint.sh` （backup 需要）
- `deploy/entrypoint-ops.sh` （noda-ops 需要）
- `deploy/supervisord.conf` （noda-ops 需要）
- `deploy/Dockerfile.*` （虽然 Dockerfile 本身不在构建上下文中发送）

**关于 noda-site 的 .dockerignore：** noda-site 构建上下文是 `../../noda-apps`（另一个仓库），本 phase 不处理。

## test-verify 升级分析

### HYGIENE-03: postgres:15-alpine -> postgres:17-alpine

**兼容性分析：**

1. **test-verify 的用途：** 它是一个测试验证容器，通过 `pg_restore` 和 `psql` 客户端工具对 prod PostgreSQL 17 数据库进行备份验证。不管理自己的数据目录。[VERIFIED: scripts/backup/docker/Dockerfile.test-verify]

2. **客户端/服务端版本兼容性：** PostgreSQL 客户端（psql、pg_restore）向前兼容。postgres:17-alpine 中的 pg_restore 17 可以恢复由 pg_dump 17 创建的备份文件。prod PostgreSQL 已经是 17.9。[VERIFIED: docker/docker-compose.yml 第 14 行]

3. **apk 包变化：** Dockerfile 中 `apk add postgresql-client` 在 postgres:17-alpine 中可能不需要（因为 postgres 镜像已自带 psql/pg_restore）。但保留它不会有害，且移除它超出了本 phase 的范围。[ASSUMED]

4. **层缓存共享：** 升级后 test-verify 和 backup（Dockerfile.backup，也基于 postgres:17-alpine）将共享基础镜像层，减少磁盘占用。[VERIFIED: deploy/Dockerfile.backup 第 9 行]

**风险评估：** LOW。test-verify 是手动触发的测试容器，不在 docker-compose 中持续运行，不影响生产服务。升级后通过手动运行验证即可。

**验证计划（per D-08）：** 通过手动构建 test-verify 镜像，运行测试验证脚本确认 pg_restore 和 psql 工具正常工作。

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 构建上下文过滤 | 自定义构建脚本过滤文件 | .dockerignore | Docker 原生支持，所有构建工具（docker build、docker compose build）自动读取 |
| 文件所有权设置 | 单独 RUN chown 层 | COPY --chown | Docker 17.09+ 原生支持，减少一层镜像 |

**Key insight:** COPY --chown 是 Dockerfile 语法层面的优化，不需要额外的工具或配置。

## Common Pitfalls

### Pitfall 1: .dockerignore 放错位置
**What goes wrong:** .dockerignore 放在 deploy/ 目录但构建上下文是项目根目录，导致 .dockerignore 不生效。
**Why it happens:** Docker 只在构建上下文根目录查找 .dockerignore，不在 Dockerfile 所在目录查找（除非两者相同）。
**How to avoid:** 确认每个 Dockerfile 的 `context:` 配置，将 .dockerignore 放在 context 目录中。
**Warning signs:** 构建速度没有改善，`docker build` 日志显示发送了过多的构建上下文。

### Pitfall 2: .dockerignore 排除了 COPY 需要的文件
**What goes wrong:** 排除规则过于激进，导致 COPY 指令找不到文件，构建失败。
**Why it happens:** 排除规则没有与 Dockerfile 中的 COPY 目标对齐。
**How to avoid:** 对照每个 Dockerfile 的 COPY 指令逐一验证排除规则。D-03 已锁定此约束。
**Warning signs:** `COPY failed: no source files` 错误。

### Pitfall 3: COPY --chown 中使用了不存在的用户
**What goes wrong:** `COPY --chown=nginx:nginx` 在没有 nginx 用户的镜像中失败。
**Why it happens:** 基础镜像中可能没有目标用户（如 alpine 默认没有 nginx 用户）。
**How to avoid:** 确认基础镜像中用户的可用性。nginx:1.25-alpine 自带 nginx 用户；postgres:17-alpine 默认使用 postgres 用户；alpine:3.21 需要先 adduser。
**Warning signs:** `COPY --chown: unknown user` 构建错误。

### Pitfall 4: 忽略 noda-site 的多阶段构建特殊性
**What goes wrong:** 对 noda-site 的 COPY --from=builder 指令使用 --chown=nginx:nginx，但 builder 阶段是 node:20-alpine（没有 nginx 用户）。
**Why it happens:** 多阶段构建中每个阶段是独立的，用户命名空间不同。
**How to avoid:** COPY --from 指令中的 --chown 使用目标阶段（runner 阶段）的用户，而非来源阶段。这是正确的做法，但需要确保 --chown 值使用 UID/GID 或目标阶段中存在的用户名。
**Warning signs:** 无。--chown 检查的是目标镜像中的用户，不检查源镜像。

### Pitfall 5: backup Dockerfile 实际已不使用
**What goes wrong:** 花时间优化 Dockerfile.backup 但它已不在 docker-compose 或 Jenkins Pipeline 中使用。
**Why it happens:** backup 容器功能已合并到 noda-ops 中，Dockerfile.backup 只被遗留的 deploy.sh 引用。
**How to avoid:** 确认 backup Dockerfile 是否仍在使用。如果仅作为遗留文件，可以简化优化（只做最小改动）或标注为 deprecated。
**Warning signs:** 无运行中的 backup 容器。

## Code Examples

### COPY --chown 基本语法
```dockerfile
# 来源: Docker 官方文档
# 格式: COPY --chown=<user>:<group> src dest
# 或:   COPY --chown=<user> src dest (group 默认为 root)

# 单文件
COPY --chown=nginx:nginx deploy/nginx.conf /etc/nginx/nginx.conf

# 目录
COPY --chown=nodaops:nodaops scripts/backup/ /app/backup/

# 多阶段构建中
COPY --from=builder --chown=nginx:nginx /app/dist /usr/share/nginx/html
```

### noda-site 优化示例
```dockerfile
# 优化前 (当前):
COPY --from=builder /app/apps/site/dist /usr/share/nginx/html
RUN chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx

# 优化后:
COPY --from=builder --chown=nginx:nginx /app/apps/site/dist /usr/share/nginx/html
# 注意: /var/cache/nginx 的权限由 nginx 基础镜像管理，不需要手动 chown
```

### noda-ops 优化示例
```dockerfile
# 优化前 (当前):
COPY scripts/backup/ /app/backup/
RUN find /app/backup -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
...
COPY deploy/crontab /etc/crontabs/nodaops
COPY deploy/supervisord.conf /etc/supervisord.conf
COPY deploy/entrypoint-ops.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
RUN mkdir -p /var/log/supervisor /var/log/noda-backup /app/history /run/supervisor
RUN chown -R nodaops:nodaops /app /var/log/supervisor /var/log/noda-backup /app/history /run/supervisor
RUN mkdir -p /home/nodaops/.config/rclone && chown -R nodaops:nodaops /home/nodaops

# 优化后（保守方案 -- 仅合并 chown，保留 chmod）:
COPY --chown=nodaops:nodaops scripts/backup/ /app/backup/
RUN find /app/backup -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
...
COPY --chown=nodaops:nodaops deploy/crontab /etc/crontabs/nodaops
COPY --chown=nodaops:nodaops deploy/supervisord.conf /etc/supervisord.conf
COPY --chown=nodaops:nodaops deploy/entrypoint-ops.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
RUN mkdir -p /var/log/supervisor /var/log/noda-backup /app/history /run/supervisor && \
    chown -R nodaops:nodaops /var/log/supervisor /var/log/noda-backup /app/history /run/supervisor
RUN mkdir -p /home/nodaops/.config/rclone && chown -R nodaops:nodaops /home/nodaops
```

**层数变化：** 原来有 2 个 RUN chown 层（第 65、66 行）。优化后：
- COPY 自带 --chown，不需要额外的 RUN chown 来处理 COPY 的文件
- 非 COPY 创建的目录（/var/log/supervisor 等）仍需要 RUN mkdir + chown
- 合并后从 2 个 RUN chown 层减少到 1 个（合并两个 RUN 为一个）
- 整体镜像层数减少 1 层

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| RUN chown + COPY 分开 | COPY --chown 合并 | Docker 17.09 | 减少镜像层数和体积 |
| 不用 .dockerignore | 精确 .dockerignore | Docker 早期就支持 | 加速构建，减少上下文传输 |
| postgres:15-alpine | postgres:17-alpine | 2024-2025 | prod 已是 17，客户端版本统一 |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Docker BuildKit 默认启用（Docker 24+） | Standard Stack | COPY --chown 语法不受 BuildKit 影响，即使使用传统 builder 也支持 |
| A2 | nginx:1.25-alpine 自带 nginx 用户 | Pitfall 3 | 如果没有 nginx 用户，需要先 RUN adduser |
| A3 | postgres:17-alpine 已自带 psql/pg_restore，apk 的 postgresql-client 可能冗余 | test-verify 升级分析 | 仅影响包冗余，不影响功能 |
| A4 | /var/cache/nginx 权限由 nginx 基础镜像正确设置，不需要手动 chown | noda-site 优化 | 需要验证 nginx 容器启动是否正常 |
| A5 | test-verify 构建上下文是项目根目录（基于 COPY 路径推断） | 构建上下文映射 | 如果上下文是其他路径，.dockerignore 需要放在不同位置 |

## Open Questions

1. **test-verify 的实际构建命令是什么？**
   - What we know: Dockerfile 在 `scripts/backup/docker/Dockerfile.test-verify`，COPY 路径是 `scripts/backup/lib/*.sh`
   - What's unclear: 没有找到任何脚本或 Jenkinsfile 自动构建它
   - Recommendation: 构建时使用 `docker build -f scripts/backup/docker/Dockerfile.test-verify .`（项目根目录为上下文），.dockerignore 放项目根目录

2. **Dockerfile.backup 是否仍在使用？**
   - What we know: 不在 docker-compose.yml 中，仅被遗留的 deploy.sh 引用
   - What's unclear: 是否还有其他地方使用它
   - Recommendation: 仍然进行 HYGIENE-01/02 优化（工作量小），如果确认不再使用可标注 deprecated

3. **CONTEXT.md 中 D-02 说 "deploy/ 目录放综合 .dockerignore"，但构建上下文是 `..`（项目根目录）。以哪个为准？**
   - What we know: docker-compose.yml 明确 `context: ..`
   - What's unclear: CONTEXT.md 的意图是否是另一个位置
   - Recommendation: 以实际构建上下文为准，.dockerignore 放项目根目录

## Environment Availability

Step 2.6: SKIPPED -- 本 phase 无外部依赖。所有改动是 Dockerfile 和 .dockerignore 文件的编辑，只需要 Docker 已安装。

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Docker build + 手动验证 |
| Config file | 无 |
| Quick run command | `docker build --check` (dry run) |
| Full suite command | 手动构建 + 运行验证 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| HYGIENE-01 | .dockerignore 正确排除不需要的文件 | 构建验证 | `docker build -f deploy/Dockerfile.noda-ops ..` | N/A -- 构建验证 |
| HYGIENE-02 | COPY --chown 替代 RUN chown 后层数不增加 | 构建验证 | `docker history noda-ops:latest` | N/A |
| HYGIENE-03 | test-verify 基础镜像升级后功能正常 | 手动验证 | 手动运行 test-verify-weekly.sh | N/A |

### Sampling Rate
- **Per task commit:** `docker build` 验证
- **Per wave merge:** 完整构建 + 运行验证
- **Phase gate:** 所有 4 个 Dockerfile 构建通过 + test-verify 功能验证

### Wave 0 Gaps
- 无 -- 本 phase 使用 Docker 构建验证，不需要测试框架

## Security Domain

> 本 phase 的改动是构建优化，不涉及安全架构变更。安全影响极低。

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | -- |
| V3 Session Management | no | -- |
| V4 Access Control | no | -- |
| V5 Input Validation | no | -- |
| V6 Cryptography | no | -- |

### Known Threat Patterns for Docker Build Optimization

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| .dockerignore 泄漏敏感信息到镜像 | Information Disclosure | 排除 .env、密钥文件、.planning 等 |

## Sources

### Primary (HIGH confidence)
- 项目代码: `docker/docker-compose.yml` -- 确认构建上下文配置
- 项目代码: `deploy/Dockerfile.backup` -- backup Dockerfile 当前状态
- 项目代码: `deploy/Dockerfile.noda-ops` -- noda-ops Dockerfile 当前状态
- 项目代码: `deploy/Dockerfile.noda-site` -- noda-site Dockerfile 当前状态（第 50 行有 Phase 48 注释）
- 项目代码: `scripts/backup/docker/Dockerfile.test-verify` -- test-verify Dockerfile 当前状态
- 项目代码: `docker/docker-compose.app.yml` -- 确认 noda-site 构建上下文是 ../../noda-apps

### Secondary (MEDIUM confidence)
- Docker 官方文档: .dockerignore 位置规则 -- 构建上下文根目录

### Tertiary (LOW confidence)
- [ASSUMED] nginx:1.25-alpine 自带 nginx 用户
- [ASSUMED] /var/cache/nginx 权限由基础镜像管理

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- 无新依赖，纯 Dockerfile 改动
- Architecture: HIGH -- 构建上下文和 COPY 指令已通过代码验证
- Pitfalls: HIGH -- 基于实际代码审计，非假设性分析

**Research date:** 2026-04-20
**Valid until:** 2026-05-20（稳定，无外部依赖变化风险）
