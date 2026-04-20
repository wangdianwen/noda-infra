# Phase 52: 基础设施镜像清理 - Context

**Gathered:** 2026-04-21
**Status:** Ready for planning

<domain>
## Phase Boundary

noda-ops 和 backup Dockerfile 遵循精简最佳实践，构建工具不泄漏到运行时。
范围限于 INFRA-01（noda-ops 依赖审计）和 INFRA-02（backup Dockerfile 清理）。
不涉及 findclass-ssr（Phase 49-51）、noda-site（Phase 47）、test-verify（Phase 48 已优化）。

</domain>

<decisions>
## Implementation Decisions

### noda-ops 多阶段构建
- **D-01:** noda-ops Dockerfile 改为多阶段构建（builder pattern），wget 和 gnupg 隔离在构建阶段，运行时镜像不含这两个包
- **D-02:** 构建阶段安装 wget/gnupg，用于下载 cloudflared 二进制和 doppler CLI（含 GPG key 验证），完成后通过 COPY --from=builder 仅传递二进制文件
- **D-03:** 运行时阶段重新 FROM alpine:3.21，只安装运行时必需的包：bash、jq、coreutils、rclone、dcron、supervisor、ca-certificates、postgresql17-client、age、doppler（二进制直接 COPY）

### noda-ops 运行时依赖精简
- **D-04:** 移除 curl — backup 脚本中未发现直接调用，健康检查使用 pg_isready，cloudflared/doppler 自带网络能力
- **D-05:** 保留 jq — alert.sh、db.sh、metrics.sh、verify.sh 大量使用（JSON 解析）
- **D-06:** 保留 coreutils — db.sh 使用 numfmt（GNU coreutils 独有，BusyBox 不含）
- **D-07:** 保留其他所有运行时依赖（bash、rclone、dcron、supervisor、ca-certificates、postgresql17-client、age）

### backup Dockerfile 层合并
- **D-08:** 合并 backup Dockerfile 的 4 个 RUN 指令为 1 个 RUN（apk add + mkdir + touch + chmod 全部合并），减少镜像层数
- **D-09:** 保留现有 COPY 指令不变（Phase 48 已优化 COPY --chown）

### Claude's Discretion
- 多阶段构建的具体 Dockerfile 结构（构建阶段的包列表、文件路径）
- RUN 指令合并的具体顺序和格式
- 是否同时优化 test-verify Dockerfile（如果发现可改进点）

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements
- `.planning/REQUIREMENTS.md` § INFRA-01, INFRA-02 — 本 phase 的两个核心需求

### Dockerfile 参考
- `deploy/Dockerfile.noda-ops` — noda-ops 容器（base: alpine:3.21），主要优化目标
- `deploy/Dockerfile.backup` — backup 容器（base: postgres:17-alpine），层合并目标
- `scripts/backup/docker/Dockerfile.test-verify` — test-verify 容器，Phase 48 已优化，参考但非主要目标

### 运行时脚本
- `deploy/entrypoint-ops.sh` — noda-ops 启动脚本，依赖 supervisor/rclone/crontab
- `deploy/crontab` — 定时任务配置，引用 backup-postgres.sh、test-verify-weekly.sh、backup-doppler-secrets.sh
- `scripts/backup/lib/alert.sh` — 使用 jq 解析告警 JSON
- `scripts/backup/lib/db.sh` — 使用 jq 解析数据库统计 + numfmt 格式化大小
- `scripts/backup/lib/metrics.sh` — 使用 jq 解析历史指标

### 前序 Phase 决策
- `.planning/phases/48-docker-hygiene/48-CONTEXT.md` — .dockerignore 和 COPY --chown 已完成
- `.planning/phases/45-infra-image-cleanup/45-CONTEXT.md` — noda-ops 镜像清理策略

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `.dockerignore` 已在 Phase 48 创建，覆盖 deploy/ 构建上下文
- noda-ops COPY --chown 已在 Phase 48 优化

### Established Patterns
- noda-ops 以非 root 用户 nodaops 运行（USER nodaops）
- backup 容器以 root 运行（无 USER 指令）
- Phase 47 的 noda-site 已使用多阶段构建模式（Puppeteer 构建阶段 → nginx 运行时），可参考
- Alpine apk 使用 `--no-cache` 避免缓存残留

### Integration Points
- `docker/docker-compose.yml` § noda-ops 服务定义 — `build.dockerfile: deploy/Dockerfile.noda-ops`
- `docker/docker-compose.yml` § backup 服务定义（opdev 容器）— 使用 `deploy/Dockerfile.backup`
- `scripts/pipeline-stages.sh` § pipeline_infra_deploy_noda_ops() — noda-ops 构建方式（docker compose build）
- `jenkins/Jenkinsfile.infra` — infra Pipeline 构建和部署流程

</code_context>

<specifics>
## Specific Ideas

- 多阶段构建后 noda-ops 镜像大小预计减少（移除 wget ~2MB + gnupg ~15MB + 依赖库），具体数值需构建后测量
- backup Dockerfile 合并后层数从 4 RUN 减至 1 RUN，镜像大小变化不大但结构更清晰
- curl 移除后如需 debug，可通过 `docker exec` 临时安装（`apk add curl`）

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 52-基础设施镜像清理*
*Context gathered: 2026-04-21*
