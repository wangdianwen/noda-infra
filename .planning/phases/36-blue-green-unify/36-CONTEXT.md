# Phase 36: 蓝绿部署统一 - Context

**Gathered:** 2026-04-18
**Status:** Ready for planning

<domain>
## Phase Boundary

将 `blue-green-deploy.sh`（findclass-ssr）和 `keycloak-blue-green-deploy.sh` 两个几乎相同的蓝绿部署脚本合并为一个参数化脚本，消除 ~80% 重复逻辑。同时将 `rollback-findclass.sh` 通用化以支持双服务回滚。

</domain>

<decisions>
## Implementation Decisions

### 构建步骤归属
- **D-01:** 构建步骤内置到统一脚本中，通过 `IMAGE_SOURCE` 环境变量区分模式（build / pull / none）。findclass-ssr 用 build 模式（docker compose build + tag），keycloak 用 pull 模式（docker pull），无需 Jenkinsfile 改动

### 镜像清理策略
- **D-02:** 清理策略通过 `CLEANUP_METHOD` 环境变量参数化（tag-count / dangling / none）。findclass-ssr 默认 tag-count，keycloak wrapper 传 dangling。`CLEANUP_IMAGE_NAME` 和 `CLEANUP_KEEP_COUNT` 控制保留策略

### 回滚脚本通用化
- **D-03:** `rollback-findclass.sh` 改为参数化脚本，复用 manage-containers.sh 的 SERVICE_NAME/SERVICE_PORT/HEALTH_PATH 等环境变量，消除硬编码端口和路径
- **D-04:** 创建 `rollback-keycloak.sh` 作为 wrapper 脚本，设置 keycloak 参数后调用统一回滚脚本。回滚能力覆盖两个服务

### Claude's Discretion
- 统一脚本的具体环境变量命名（除已决定的 IMAGE_SOURCE、CLEANUP_METHOD 外）
- wrapper 脚本的具体实现方式（直接 exec 还是 source + 调用）
- 构建步骤中的 SHA 标签逻辑是否需要参数化
- keycloak compose 迁移检查逻辑是否纳入统一脚本

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 蓝绿部署相关脚本
- `scripts/blue-green-deploy.sh` — findclass-ssr 蓝绿部署（将被合并的主脚本之一）
- `scripts/keycloak-blue-green-deploy.sh` — keycloak 蓝绿部署（将被合并的主脚本之一）
- `scripts/rollback-findclass.sh` — findclass-ssr 回滚脚本（将被通用化）
- `scripts/manage-containers.sh` — 已参数化的容器管理基础设施（run_container, update_upstream 等）
- `scripts/lib/deploy-check.sh` — Phase 35 提取的共享健康检查库（http_health_check, e2e_verify）
- `scripts/lib/image-cleanup.sh` — Phase 35 提取的共享镜像清理库（cleanup_by_tag_count, cleanup_dangling）

### 配置文件
- `config/nginx/snippets/upstream-findclass.conf` — findclass upstream 配置
- `config/nginx/snippets/upstream-keycloak.conf` — keycloak upstream 配置

### 需求文档
- `.planning/REQUIREMENTS.md` — BLUE-01, BLUE-02 需求定义

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `manage-containers.sh`: 已支持多服务参数化（SERVICE_NAME/SERVICE_PORT/UPSTREAM_NAME 等），两个部署脚本都已通过 source 复用
- `deploy-check.sh`: http_health_check() 和 e2e_verify() 已提取为共享函数，接受参数化端口/路径/重试次数
- `image-cleanup.sh`: cleanup_by_tag_count() 和 cleanup_dangling() 已提取为共享函数

### Established Patterns
- 蓝绿部署流程：前置检查 → 获取活跃环境 → 停旧启新 → HTTP健康检查 → 切换流量 → E2E验证 → 清理
- manage-containers.sh 的参数化模式：通过环境变量覆盖默认值（`${VAR:-default}`）
- wrapper 模式：旧脚本设置参数后调用新脚本（keycloak-blue-green-deploy.sh 已采用此模式覆盖 manage-containers.sh 默认值）

### Integration Points
- Jenkinsfile 调用 blue-green-deploy.sh
- Jenkinsfile.keycloak 调用 keycloak-blue-green-deploy.sh
- 两个 Jenkinsfile 修改需与脚本合并同步

### 重复代码分析
- `blue-green-deploy.sh` 和 `keycloak-blue-green-deploy.sh` 的 main() 函数 ~80% 结构一致
- 差异点：(1) 构建vs拉取镜像 (2) 健康检查超时参数 (3) 清理策略 (4) Keycloak compose 迁移检查 (5) 日志输出中的服务名
- `rollback-findclass.sh` 硬编码 "3001" 和 "/api/health"，应改为读取 SERVICE_PORT/HEALTH_PATH

</code_context>

<specifics>
## Specific Ideas

- 统一脚本的镜像获取逻辑：build 模式执行 `docker compose build + docker tag`，pull 模式执行 `docker pull`，none 模式跳过（直接使用已有镜像）
- keycloak 有额外的 compose 迁移检查（检测并停止 compose 管理的旧容器），这是首次蓝绿部署迁移逻辑，可考虑通过 `CHECK_COMPOSE_MIGRATION` 参数控制

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---
*Phase: 36-blue-green-unify*
*Context gathered: 2026-04-18*
