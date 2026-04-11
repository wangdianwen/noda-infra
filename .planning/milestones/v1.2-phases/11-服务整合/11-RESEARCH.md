# Phase 11: 服务整合 - Research

**Researched:** 2026-04-11
**Domain:** Docker Compose 配置整理与容器分组标签
**Confidence:** HIGH

## Summary

本阶段核心任务是两项：(1) 统一 Docker Compose 文件中对 findclass-ssr 的 Dockerfile 路径引用；(2) 为所有 Docker Compose 变体文件添加分组标签，使基础设施服务（postgres, keycloak, nginx, noda-ops）和应用服务（findclass-ssr）可通过 `docker ps --filter label=...` 过滤查看。

当前存在一个关键问题：`docker-compose.yml` 和 `docker-compose.app.yml` 对同一个 Dockerfile 引用了不同的路径，且两份 Dockerfile 文件内容不同（一份在 noda-apps 仓库，一份在 noda-infra 仓库）。当前生产环境通过三文件组合（yml + prod + dev）启动所有服务，所有容器都归属 `noda-infra` 项目。

**Primary recommendation:** 统一 Dockerfile 路径引用为 `../deploy/Dockerfile.findclass-ssr`（从 docker/ 目录出发），同时在所有 compose 文件中通过 `name:` 指令和自定义 `labels` 实现分组。使用 `docker ps --filter`（非 `docker compose ps --filter`）进行标签过滤验证。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 保持 noda-apps 作为独立代码仓库（应用代码），Dockerfile 和配置文件留在 noda-infra/deploy/ 下，只整理路径引用使其一致
- **D-02:** 需要统一的路径引用 — 当前 docker-compose.yml 和 docker-compose.app.yml 的 Dockerfile 路径不一致（前者用 `./infra/docker/` 后者用 `../noda-infra/deploy/`），需要统一
- **D-03:** 成功标准：`docker compose config` 输出路径正确且服务正常启动
- **D-04:** 双组标签设计 — 基础设施服务归入 `noda-infra` 组（postgres, keycloak, noda-ops, nginx），应用服务归入 `noda-apps` 组（findclass-ssr）
- **D-05:** 成功标准：`docker compose ps --format json` 显示所有容器带有正确分组标签，可通过 `--filter label=project=noda-apps` 过滤查看
- **D-06:** 所有 5 个 docker-compose 变体文件（yml, prod, dev, app, simple, dev-standalone）全部更新 labels 和路径引用
- **D-07:** 当前变体文件清单已确认

### Claude's Discretion
- 具体的 labels 键名和格式（建议使用 com.docker.compose.project 分组）
- 路径引用统一后是否需要更新部署脚本
- 是否需要清理废弃的路径引用

### Deferred Ideas (OUT OF SCOPE)
None
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| GROUP-01 | findclass-ssr 目录迁移 — 相关文件迁移到 noda-apps/ 目录下 | 见「路径引用现状分析」和「路径统一方案」|
| GROUP-02 | Docker 分组标签 — 容器 labels/project 归入 noda-apps 分组 | 见「分组标签方案」和「过滤验证方式」|
</phase_requirements>

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Docker Compose | v2.40.3-desktop.1 | 服务编排 | 项目已使用，支持 `name:` 指令和自定义 labels |
| Docker | v29.1.3 | 容器运行时 | 项目已使用 |

### Supporting
无需额外依赖——本阶段仅涉及 YAML 配置文件修改。

### Alternatives Considered
不适用——本阶段不引入新工具。

## Architecture Patterns

### 当前文件布局

```
noda-infra/
├── docker/
│   ├── docker-compose.yml          # 基础配置（所有服务）
│   ├── docker-compose.prod.yml     # 生产 overlay
│   ├── docker-compose.dev.yml      # 开发 overlay
│   ├── docker-compose.app.yml      # 应用独立配置（name: noda-apps）
│   ├── docker-compose.simple.yml   # 简化版（name: noda-infra）
│   └── docker-compose.dev-standalone.yml  # 开发独立（name: noda-dev）
├── deploy/
│   ├── Dockerfile.findclass-ssr    # findclass-ssr 构建文件
│   ├── Dockerfile.noda-ops         # noda-ops 构建文件
│   ├── Dockerfile.backup           # 备份构建文件（遗留）
│   ├── entrypoint-ops.sh           # noda-ops 入口
│   └── entrypoint.sh               # findclass-ssr 入口
├── config/nginx/                   # Nginx 配置
├── scripts/deploy/                 # 部署脚本
│   ├── deploy-apps-prod.sh         # 引用 docker-compose.app.yml
│   ├── deploy-findclass-zero-deps.sh  # 遗留脚本（引用不存在的 Dockerfile）
│   └── deploy-infrastructure-prod.sh  # 引用三文件组合
└── services/                       # 服务配置（init 脚本等）

noda-apps/  （同级目录，独立仓库）
├── infra/docker/
│   └── Dockerfile.findclass-ssr    # 仓库内也有一份 Dockerfile（内容不同）
├── apps/findclass/                 # 应用源码
└── ...
```

### 路径引用现状分析

两个 compose 文件中 findclass-ssr 的 build 配置对比：[VERIFIED: 文件内容直接读取]

| 文件 | context | dockerfile | 解析目标 |
|------|---------|------------|----------|
| `docker-compose.yml` | `../../noda-apps` | `./infra/docker/Dockerfile.findclass-ssr` | `/Users/dianwenwang/Project/noda-apps/infra/docker/Dockerfile.findclass-ssr` |
| `docker-compose.app.yml` | `../../noda-apps` | `../noda-infra/deploy/Dockerfile.findclass-ssr` | `/Users/dianwenwang/Project/noda-infra/deploy/Dockerfile.findclass-ssr` |

**关键发现：两个文件指向不同仓库中的不同 Dockerfile。**

- `docker-compose.yml` 指向 noda-apps 仓库中的 Dockerfile（较新版本，有多阶段 COPY 优化）
- `docker-compose.app.yml` 指向 noda-infra 仓库中的 Dockerfile（较旧版本，使用 `COPY . .`）
- 两份文件内容差异显著（见 diff 分析）

**当前生产部署实际使用**：`deploy-infrastructure-prod.sh` 使用三文件组合（yml + prod + dev），因此实际使用的是 noda-apps 仓库中的 Dockerfile。

### 路径统一方案

根据 D-01（Dockerfile 留在 noda-infra/deploy/），统一方向：[ASSUMED]

**推荐方案：所有 compose 文件统一使用 `../deploy/Dockerfile.findclass-ssr`**

从 `docker/` 目录出发的相对路径解析：
- `context: ../../noda-apps` → `/Users/dianwenwang/Project/noda-apps`（build context）
- `dockerfile: ../deploy/Dockerfile.findclass-ssr` → 但 dockerfile 路径是相对于 context 的！

**注意：Docker Compose 的 dockerfile 路径是相对于 context 的，不是相对于 compose 文件的。**

因此从 context `../../noda-apps`（即 `/Users/dianwenwang/Project/noda-apps`）出发：
- `./infra/docker/Dockerfile.findclass-ssr` → `/Users/dianwenwang/Project/noda-apps/infra/docker/Dockerfile.findclass-ssr`（当前 yml 使用的）
- `../noda-infra/deploy/Dockerfile.findclass-ssr` → `/Users/dianwenwang/Project/noda-infra/deploy/Dockerfile.findclass-ssr`（当前 app.yml 使用的）

**两种统一选择：**

| 方案 | dockerfile 路径 | 指向 | 说明 |
|------|----------------|------|------|
| A | `./infra/docker/Dockerfile.findclass-ssr` | noda-apps 仓库 | 当前 yml 使用，需同步两份 Dockerfile |
| B | `../noda-infra/deploy/Dockerfile.findclass-ssr` | noda-infra 仓库 | 当前 app.yml 使用，符合 D-01 决策 |

根据 D-01（Dockerfile 留在 noda-infra/deploy/），应选择方案 B。但这意味着需要确保 `noda-infra/deploy/Dockerfile.findclass-ssr` 和 `noda-apps/infra/docker/Dockerfile.findclass-ssr` 保持同步，或者决定以哪份为准。

**建议：以 `noda-infra/deploy/Dockerfile.findclass-ssr` 为准**（D-01 决策），所有 compose 文件统一使用 `../noda-infra/deploy/Dockerfile.findclass-ssr`。

### 分组标签方案

Docker Compose 的 `name:` 指令决定 `com.docker.compose.project` 标签值。[VERIFIED: docker compose ps --format json 验证]

**当前问题：** 所有服务通过三文件组合启动时，项目名由第一个文件的 `name:` 决定。当前 `docker-compose.yml` 设置 `name: noda-infra`，因此所有容器（包括 findclass-ssr）的 `com.docker.compose.project` 都是 `noda-infra`。

**实现分组的方法：**

方法 1：使用自定义 labels（推荐）
```yaml
services:
  findclass-ssr:
    labels:
      noda.service-group: "apps"
```

方法 2：通过 `name:` 指令区分项目（仅在独立启动时有效）
```yaml
# docker-compose.app.yml
name: noda-apps
```

**推荐使用方法 1 + 方法 2 组合：**
- 所有 compose 文件中为基础服务添加 `noda.service-group: infra` 标签
- 所有 compose 文件中为应用服务添加 `noda.service-group: apps` 标签
- `docker-compose.app.yml` 保持 `name: noda-apps`，其他保持 `name: noda-infra`

### 过滤验证方式

**重要澄清：** CONTEXT.md 中成功标准 `docker compose ps --filter label=project=noda-apps` 的语法有误。[VERIFIED: docker compose ps --help]

| 命令 | filter 支持 | 说明 |
|------|------------|------|
| `docker compose ps --filter` | 仅支持 `status` | 不支持 label 过滤 |
| `docker ps --filter label=...` | 支持所有 Docker 标签 | 正确的过滤方式 |

**正确的验证命令：**
```bash
# 查看所有带 apps 分组标签的容器
docker ps --filter "label=noda.service-group=apps" --format "table {{.Names}}\t{{.Status}}"

# 查看所有带 infra 分组标签的容器
docker ps --filter "label=noda.service-group=infra" --format "table {{.Names}}\t{{.Status}}"

# 通过 compose project 标签过滤（仅当独立启动时有效）
docker ps --filter "label=com.docker.compose.project=noda-apps"
```

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 容器分组 | 自定义脚本按名称匹配分组 | Docker Compose `name:` + 自定义 `labels` | 原生支持，`docker ps --filter label=...` 即可过滤 |
| 路径解析 | 自定义脚本转换路径 | Docker Compose 相对路径机制 | compose 文件中的相对路径从文件所在目录解析 |

**Key insight:** Docker Compose 的 `name:` 指令 + 自定义 labels 已经提供完整的分组能力，无需额外工具。

## Common Pitfalls

### Pitfall 1: dockerfile 路径是相对于 build context，不是 compose 文件
**What goes wrong:** 将 dockerfile 路径写成相对于 compose 文件的路径，导致构建失败
**Why it happens:** Docker Compose 文档中 context 和 dockerfile 的路径基准不同
**How to avoid:** context 路径相对于 compose 文件，dockerfile 路径相对于 context
**Warning signs:** `docker compose config` 输出中 dockerfile 路径解析异常

### Pitfall 2: docker compose ps --filter 不支持 label 过滤
**What goes wrong:** 使用 `docker compose ps --filter label=xxx` 无法过滤
**Why it happens:** `docker compose ps` 的 --filter 仅支持 status 过滤
**How to avoid:** 使用 `docker ps --filter label=xxx` 代替
**Warning signs:** 过滤命令返回所有容器或空结果

### Pitfall 3: 三文件组合时 name 冲突
**What goes wrong:** 多个 compose 文件设置不同的 `name:`，以第一个文件为准
**Why it happens:** Docker Compose 合并时项目名取第一个文件的 `name:` 值
**How to avoid:** 确保需要合并使用的文件使用相同 `name:`，或通过 `-p` 参数显式指定
**Warning signs:** `docker compose config` 输出的 name 不是预期值

### Pitfall 4: 两份 Dockerfile 内容不同导致构建结果差异
**What goes wrong:** 切换 compose 文件后构建结果不同
**Why it happens:** noda-apps 和 noda-infra 各有一份 Dockerfile，内容差异显著
**How to avoid:** 统一后确保只维护一份 Dockerfile（根据 D-01，以 noda-infra/deploy/ 为准）
**Warning signs:** 构建时间或镜像大小突然变化

### Pitfall 5: 遗留脚本引用不存在的路径
**What goes wrong:** `deploy-findclass-zero-deps.sh` 引用 `docker/Dockerfile.findclass`（不存在）
**Why it happens:** 脚本是旧架构遗留，未随服务合并更新
**How to avoid:** 更新脚本路径或标记为废弃
**Warning signs:** 执行脚本时报 "Dockerfile not found"

## Code Examples

### 服务添加自定义分组标签
```yaml
# 来源: Docker Compose 官方文档 labels 格式 [ASSUMED]
services:
  findclass-ssr:
    build:
      context: ../../noda-apps
      dockerfile: ../noda-infra/deploy/Dockerfile.findclass-ssr
    labels:
      noda.service-group: "apps"
```

```yaml
services:
  postgres:
    image: postgres:17.9
    labels:
      noda.service-group: "infra"
```

### 验证分组标签
```bash
# 查看所有容器及其分组标签
docker ps --format "table {{.Names}}\t{{.Label \"noda.service-group\"}}"

# 过滤 apps 分组
docker ps --filter "label=noda.service-group=apps" --format "table {{.Names}}\t{{.Status}}"

# JSON 格式输出（验证标签存在）
docker ps --filter "label=noda.service-group=apps" --format json | python3 -c "
import sys, json
for line in sys.stdin:
    obj = json.loads(line.strip())
    labels = obj.get('Labels', '')
    for l in labels.split(','):
        if 'noda.service-group' in l:
            print(f\"{obj['Names']}: {l}\")
"
```

### docker compose config 验证路径
```bash
# 验证路径解析是否正确
cd docker
docker compose -f docker-compose.yml config | grep -A 3 "dockerfile"
docker compose -f docker-compose.app.yml config | grep -A 3 "dockerfile"

# 合并验证
docker compose -f docker-compose.yml -f docker-compose.prod.yml config | grep -A 3 "dockerfile"
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `docker-compose` (v1 CLI) | `docker compose` (v2 插件) | Docker Compose v2 | 命令语法略有差异，v2 支持 `name:` 指令 |
| `project_name` via `-p` flag | `name:` 指令在 compose 文件中 | Compose Spec v2 | 可在文件中声明项目名 |
| 无自定义 labels | 服务级别 `labels:` | Compose Spec 始终支持 | 容器可携带自定义元数据 |

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | 无 — 所有数据通过 Docker volumes 管理，不包含路径字符串 | 无需数据迁移 |
| Live service config | 6 个运行中容器（findclass-ssr, nginx, keycloak, noda-ops, postgres-prod, postgres-dev）| 需要重启容器使新 labels 生效 |
| OS-registered state | 无 — 无 systemd/launchd 注册 | 无 |
| Secrets/env vars | 无 — 环境变量不引用 Dockerfile 路径 | 无 |
| Build artifacts | findclass-ssr:latest 镜像已构建 | 需要重新构建镜像（如 Dockerfile 路径变更） |

**注意：** 标签变更必须重启容器才能生效。Docker Compose 的 labels 变更不被视为配置变更，`docker compose up -d` 不会自动重启已有容器。需要 `docker compose down && docker compose up -d` 或 `docker compose up -d --force-recreate`。

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | 统一使用 `../noda-infra/deploy/Dockerfile.findclass-ssr` 作为 dockerfile 路径（D-01 决策解读） | 路径统一方案 | 如理解有误，可能需要改用 noda-apps 仓库内的路径 |
| A2 | 自定义 label `noda.service-group` 是合适的分组标签键名 | 分组标签方案 | 用户可能期望不同的标签命名规范 |
| A3 | `docker-compose.app.yml` 单独使用时，`name: noda-apps` 应保留 | 分组标签方案 | 如不需要独立启动则可移除 |
| A4 | 成功标准中 `docker compose ps --filter label=project=noda-apps` 实际应为 `docker ps --filter label=...` | 过滤验证方式 | 如用户坚持使用 `docker compose ps`，需要找替代方案 |

## Open Questions

1. **两份 Dockerfile 如何同步？**
   - What we know: noda-apps 和 noda-infra 各有一份内容不同的 Dockerfile.findclass-ssr
   - What's unclear: 统一后，noda-apps 仓库中的 Dockerfile 是否还需要保留
   - Recommendation: 以 noda-infra/deploy/ 为唯一来源，noda-apps 中的可作为历史参考或删除

2. **成功标准的验证命令修正**
   - What we know: `docker compose ps --filter` 仅支持 status，不支持 label
   - What's unclear: 用户是否接受使用 `docker ps --filter` 代替
   - Recommendation: 在验证步骤中使用 `docker ps --filter label=noda.service-group=apps`

3. **deploy-findclass-zero-deps.sh 是否需要修复或废弃？**
   - What we know: 引用了不存在的 `docker/Dockerfile.findclass`
   - What's unclear: 此脚本是否仍在使用
   - Recommendation: 标记为废弃或更新路径引用

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | 容器管理 | ✓ | 29.1.3 | — |
| Docker Compose | 服务编排 | ✓ | v2.40.3-desktop.1 | — |
| noda-apps 仓库 | build context | ✓ | 同级目录 /Users/dianwenwang/Project/noda-apps | — |
| noda-network | 容器网络 | ✓ | 外部网络已创建 | — |

**Missing dependencies with no fallback:**
- 无阻塞依赖

**Missing dependencies with fallback:**
- 无

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell 脚本验证（本项目无代码测试框架） |
| Config file | 无 |
| Quick run command | `cd docker && docker compose config >/dev/null 2>&1` |
| Full suite command | `cd docker && docker compose -f docker-compose.yml config && docker compose -f docker-compose.app.yml config && docker compose -f docker-compose.simple.yml config` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| GROUP-01 | docker compose config 输出路径正确 | smoke | `cd docker && docker compose -f docker-compose.yml config \| grep dockerfile` | ✅ 手动验证 |
| GROUP-01 | docker compose config 输出路径正确（app.yml） | smoke | `cd docker && docker compose -f docker-compose.app.yml config \| grep dockerfile` | ✅ 手动验证 |
| GROUP-01 | 服务正常启动 | manual | 需要实际部署验证 | ❌ Wave 0 |
| GROUP-02 | 容器带分组标签 | smoke | `docker ps --filter "label=noda.service-group=apps" --format "{{.Names}}"` | ✅ 手动验证 |
| GROUP-02 | docker compose ps --format json 显示标签 | smoke | `docker ps --filter "label=noda.service-group" --format json` | ✅ 手动验证 |

### Sampling Rate
- **Per task commit:** `cd docker && docker compose config >/dev/null 2>&1`
- **Per wave merge:** 所有 compose 文件 config 验证 + 标签验证
- **Phase gate:** 所有 compose 文件路径正确 + 容器标签正确 + 服务可启动

### Wave 0 Gaps
- [ ] 需要一个验证脚本来检查所有 compose 文件的 config 有效性
- [ ] 需要部署环境来验证服务启动（非本地可完成）

## Security Domain

本阶段不涉及安全变更——仅修改配置文件中的路径引用和标签。不涉及认证、授权、加密或网络变更。

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | 无变更 |
| V3 Session Management | no | 无变更 |
| V4 Access Control | no | 无变更 |
| V5 Input Validation | no | 无变更 |
| V6 Cryptography | no | 无变更 |

## 部署脚本影响分析

需要更新路径引用的脚本：[VERIFIED: grep 搜索结果]

| 脚本 | 当前引用 | 需要修改 |
|------|---------|---------|
| `scripts/deploy/deploy-apps-prod.sh` | `docker/docker-compose.app.yml` | 否（路径已正确） |
| `scripts/deploy/deploy-infrastructure-prod.sh` | 三文件组合 | 否（路径已正确） |
| `scripts/deploy/deploy-findclass-zero-deps.sh` | `docker/Dockerfile.findclass`（不存在）| 是（需修复或废弃） |
| `scripts/verify/verify-findclass.sh` | `docker-compose.yml -f docker-compose.prod.yml`（无 docker/ 前缀）| 是（路径可能有误） |
| `scripts/utils/validate-docker.sh` | `docker/docker-compose.yml` | 否（路径已正确） |
| `scripts/verify/verify-services.sh` | `docker-compose -f docker/docker-compose.yml` | 否（路径已正确） |
| `scripts/verify/verify-infrastructure.sh` | `docker-compose -f docker/docker-compose.yml` | 否（路径已正确） |

**`verify-findclass.sh` 问题：** 脚本在 `docker/` 目录下执行时路径正确，但在项目根目录执行会失败。需确认执行上下文。

## 需要更新的 Compose 文件清单

| 文件 | 需要更新路径 | 需要添加 labels | 当前 name | 目标 name |
|------|-------------|-----------------|-----------|-----------|
| `docker-compose.yml` | 是（dockerfile 路径） | 是（所有服务） | noda-infra | noda-infra |
| `docker-compose.prod.yml` | 否（overlay 无 build） | 是（findclass-ssr） | noda-infra | noda-infra |
| `docker-compose.dev.yml` | 否（overlay 无 build） | 否（overlay 继承） | 无 | 无 |
| `docker-compose.app.yml` | 是（dockerfile 路径） | 是（findclass-ssr） | noda-apps | noda-apps |
| `docker-compose.simple.yml` | 否（无 build） | 是（所有服务） | noda-infra | noda-infra |
| `docker-compose.dev-standalone.yml` | 否（无 build） | 否（独立 dev） | noda-dev | noda-dev |

## Sources

### Primary (HIGH confidence)
- Docker Compose v2.40.3 `--help` 输出 — filter 支持、config 命令
- 所有 compose 文件内容直接读取和 diff 分析
- `docker ps --format json` 输出验证标签结构
- `docker compose config` 输出验证路径解析

### Secondary (MEDIUM confidence)
- deploy-findclass-zero-deps.sh 引用不存在的 Dockerfile — 通过文件不存在确认

### Tertiary (LOW confidence)
- 无

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — 仅使用现有 Docker Compose，无新依赖
- Architecture: HIGH — 所有 compose 文件已完整读取和分析
- Pitfalls: HIGH — 通过实际命令验证了 filter 行为差异

**Research date:** 2026-04-11
**Valid until:** 2026-05-11（Docker Compose 配置稳定，30 天有效）
