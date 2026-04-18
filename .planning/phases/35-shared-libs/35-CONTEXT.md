# Phase 35: 共享库建设 - Context

**Gathered:** 2026-04-18
**Status:** Ready for planning

<domain>
## Phase Boundary

从多个脚本文件中提取 3 个共享库文件（`deploy-check.sh`、`platform.sh`、`image-cleanup.sh`），消除跨文件的函数定义重复。所有消费者脚本通过 source 引用统一的共享库。

**In scope:**
- `scripts/lib/deploy-check.sh` — http_health_check() + e2e_verify()
- `scripts/lib/platform.sh` — detect_platform()
- `scripts/lib/image-cleanup.sh` — 3 个独立清理函数
- 所有调用方迁移为 source 新库
- Source Guard 防止直接执行

**Out of scope:**
- 蓝绿部署脚本合并（Phase 36）
- 清理遗留脚本（Phase 37）
- ShellCheck/shfmt 质量保证（Phase 38）
- 合并 scripts/lib/log.sh 和 scripts/backup/lib/log.sh（Out of Scope in REQUIREMENTS.md）

</domain>

<decisions>
## Implementation Decisions

### image-cleanup.sh 设计
- **D-01:** image-cleanup.sh 包含 3 个独立函数（不是统一入口），每个调用方选择自己需要的函数
- **D-02:** 函数命名为策略描述风格：`cleanup_by_tag_count()`、`cleanup_by_date_threshold()`、`cleanup_dangling()`
- **D-03:** 原因：3 个实现策略根本不同（标签保留/日期阈值/dangling 清理），统一接口会增加不必要的复杂度

### deploy-check.sh 参数化
- **D-04:** http_health_check 和 e2e_verify 使用位置参数传递所有配置（URL、max_retries、interval），不使用环境变量隐式传递
- **D-05:** 调用方在调用时明确传值，例如 `http_health_check "$url" "$max_retries" "$interval"`
- **D-06:** 原因：位置参数最简洁、无隐式依赖，新调用方不会因为忘记设置环境变量而出错

### Claude's Discretion
- detect_platform 提取方式（8 个相同实现，无决策争议，直接提取即可）
- Source Guard 变量命名（遵循已有模式如 `_NODA_CONFIG_LOADED`）
- 具体函数签名细节（参数顺序、默认值处理）
- 调用方迁移的执行顺序
- 错误处理和日志格式

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 项目级规划
- `.planning/ROADMAP.md` — Phase 35 目标、依赖关系、成功标准
- `.planning/REQUIREMENTS.md` — LIB-01, LIB-02, LIB-03 详细需求
- `.planning/PROJECT.md` — 已锁定决策（log.sh 不合并等）

### 现有实现（被提取的函数）
- `scripts/blue-green-deploy.sh` — http_health_check + e2e_verify + cleanup_old_images（标签保留）
- `scripts/keycloak-blue-green-deploy.sh` — http_health_check + e2e_verify + cleanup_old_keycloak_images（dangling 清理）
- `scripts/rollback-findclass.sh` — http_health_check + e2e_verify
- `scripts/pipeline-stages.sh` — http_health_check + e2e_verify + cleanup_old_images（日期阈值）
- `scripts/install-auditd-rules.sh` — detect_platform（8 个相同实现之一）
- `scripts/setup-docker-permissions.sh` — detect_platform
- `scripts/install-sudoers-whitelist.sh` — detect_platform
- `scripts/break-glass.sh` — detect_platform
- `scripts/apply-file-permissions.sh` — detect_platform
- `scripts/install-sudo-log.sh` — detect_platform
- `scripts/setup-jenkins.sh` — detect_platform
- `scripts/verify-sudoers-whitelist.sh` — detect_platform

### 现有共享库（模式参考）
- `scripts/lib/log.sh` — 基础日志函数库（最广泛使用，47 个文件 source）
- `scripts/lib/health.sh` — 容器健康轮询函数
- `scripts/backup/lib/config.sh` — Source Guard 模式参考（`_NODA_CONFIG_LOADED`）

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/lib/log.sh` — 日志函数库，新共享库的 source 模式参考
- `scripts/backup/lib/config.sh` — Source Guard 模式（`_NODA_CONFIG_LOADED`）
- `scripts/manage-containers.sh` — 提供 `get_container_name()`，http_health_check 和 e2e_verify 依赖

### Established Patterns
- Source 路径模式：`source "$SCRIPT_DIR/../lib/log.sh"` 或 `source "$PROJECT_ROOT/scripts/lib/log.sh"`
- Source Guard：`if [[ -n "${_VAR_NAME:-}" ]]; then return 0; fi; _VAR_NAME=1`
- 函数参数传递差异化配置（vs 环境变量）

### Integration Points
- 新 lib 文件放入 `scripts/lib/` 目录
- 所有调用方需要在文件头部添加 source 语句
- 提取后需删除原文件中的内联函数定义
- http_health_check 和 e2e_verify 依赖 `get_container_name()`（来自 manage-containers.sh）

</code_context>

<specifics>
## Specific Ideas

- 函数签名示例：`http_health_check "$url" "$max_retries" "$interval"`
- 函数签名示例：`e2e_verify "$container_name" "$port" "$health_path" "$max_retries" "$interval"`
- 3 个清理函数：`cleanup_by_tag_count()`、`cleanup_by_date_threshold()`、`cleanup_dangling()`
- detect_platform 提取最简单（8 个完全相同的实现），可作为第一个 plan

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 35-shared-libs*
*Context gathered: 2026-04-18*
