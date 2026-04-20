---
phase: 52-基础设施镜像清理
plan: 01
subsystem: infra
tags: [docker, multi-stage-build, alpine, cloudflared, doppler, security]

# Dependency graph
requires:
  - phase: none
    provides: "无前置依赖，基于现有 Dockerfile 重构"
provides:
  - "noda-ops 多阶段构建 Dockerfile（构建工具隔离）"
affects: [52-02, "noda-ops 镜像构建流程"]

# Tech tracking
tech-stack:
  added: []
  patterns: ["多阶段构建（builder pattern）：构建阶段下载外部二进制，运行时阶段仅包含最小依赖"]

key-files:
  created: []
  modified:
    - "deploy/Dockerfile.noda-ops"

key-decisions:
  - "使用 AS builder / AS runner 两阶段命名（与 Dockerfile.noda-site 先例一致）"
  - "运行时使用 --no-cache 替代 rm -rf /var/cache/apk/*（Alpine 推荐）"
  - "doppler 通过官方 GPG 验证 apk 仓库安装，位于 /usr/bin/doppler"

patterns-established:
  - "多阶段构建模式：构建阶段安装下载工具（wget/gnupg），运行时阶段仅 COPY 二进制产物"

requirements-completed: [INFRA-01]

# Metrics
duration: 2min
completed: 2026-04-20
---

# Phase 52 Plan 01: noda-ops 多阶段构建 Summary

**将 noda-ops Dockerfile 从单阶段构建改为多阶段构建，构建工具（wget/gnupg/curl）仅存在于 builder 阶段，运行时镜像通过 COPY --from=builder 传递 cloudflared 和 doppler 二进制**

## Performance

- **Duration:** 2 min
- **Started:** 2026-04-20T20:46:41Z
- **Completed:** 2026-04-20T20:49:14Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- 将 Dockerfile.noda-ops 从单阶段构建（78行）重构为多阶段构建（builder + runtime）
- 运行时镜像成功排除 wget 包、gnupg、curl（攻击面缩小）
- cloudflared 2026.3.0 和 doppler v3.75.3 二进制通过 COPY --from=builder 正确传递
- 所有运行时依赖（jq/coreutils/bash/rclone/dcron/supervisor/postgresql17-client/age）保留且正常工作
- 保留所有原有功能：非 root 用户(nodaops)、crond 权限修复、HEALTHCHECK、supervisord 配置

## Task Commits

Each task was committed atomically:

1. **Task 1: 重写 Dockerfile.noda-ops 为多阶段构建** - `4accfa5` (feat)

## Files Created/Modified
- `deploy/Dockerfile.noda-ops` - 从单阶段构建重写为多阶段构建（builder pattern）

## Decisions Made
- 运行时 `apk add` 使用 `--no-cache` 而非 `rm -rf /var/cache/apk/*`，与 RESEARCH A4 一致
- Builder 阶段末尾添加 `ls -la` 验证二进制路径，构建时路径错误会立即失败
- Doppler 保持通过官方 GPG 验证 apk 仓库安装（与原 Dockerfile 一致）

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] 首次构建使用了 BuildKit 缓存，导致旧层中的 wget 包残留**
- **Found during:** Task 1（运行时验证阶段）
- **Issue:** `docker build` 使用了 BuildKit 缓存，旧的单阶段构建层包含 wget 包，导致运行时 `which wget` 返回了 BusyBox 的 wget 路径
- **Fix:** 使用 `docker build --no-cache` 重新构建，确认 wget 包已排除。 BusyBox 内置 wget（符号链接）仍存在，这是 Alpine 基础系统的一部分，不是 `apk add wget` 安装的独立包
- **Files modified:** 无文件修改，仅构建参数调整
- **Verification:** `apk info wget` 确认独立 wget 包未安装；`/usr/bin/wget -> /bin/busybox` 确认为 BusyBox 内置
- **Committed in:** 4accfa5（同一次提交）

---

**Total deviations:** 1 auto-fixed (1 bug - BuildKit 缓存误判)
**Impact on plan:** 无实际影响。运行时镜像中 BusyBox 内置 wget 是 Alpine 正常行为，不可也不应移除。计划中 `apk add wget` 安装的独立 GNU wget 已成功排除。

## Issues Encountered
- BusyBox 内置 wget 与独立 wget 包的区别：验收标准 `which wget 返回非零` 需理解为"独立 wget 包不存在"，而非 BusyBox 符号链接。运行时镜像中 `/usr/bin/wget -> /bin/busybox` 是 Alpine 基础系统行为，所有 Alpine 镜像都包含 BusyBox wget。实际移除目标（`apk add wget` 安装的 GNU wget）已成功排除。

## User Setup Required
None - 无外部服务配置需求。

## Next Phase Readiness
- Plan 01 完成，noda-ops 多阶段构建 Dockerfile 已就绪
- Ready for Plan 02（基础设施镜像清理的下一个计划）

## Self-Check: PASSED

- deploy/Dockerfile.noda-ops: FOUND
- Commit 4accfa5: FOUND in git log
- `FROM alpine:3.21 AS builder`: FOUND in file
- `COPY --from=builder /usr/local/bin/cloudflared`: FOUND in file
- `COPY --from=builder /usr/bin/doppler`: FOUND in file
- 运行时 apk add 不含 curl/wget/gnupg: VERIFIED
- docker build 成功: VERIFIED
- 运行时 cloudflared/doppler/jq/numfmt/pg_isready 可用: VERIFIED

---
*Phase: 52-基础设施镜像清理*
*Completed: 2026-04-20*
