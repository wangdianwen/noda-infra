# Phase 30: 一键开发环境脚本 - Context

**Gathered:** 2026-04-17
**Status:** Ready for planning (auto mode)

<domain>
## Phase Boundary

创建 setup-dev.sh 一键开发环境脚本，新开发者运行一个命令即可搭建完整的本地开发环境。复用 Phase 26 已创建的 setup-postgres-local.sh，提供更高层的入口点。

范围包括：
- 创建 setup-dev.sh 一键安装脚本（封装 setup-postgres-local.sh）
- 自动检测 Apple Silicon vs Intel Mac（复用 setup-postgres-local.sh 已有逻辑）
- 幂等设计（重复运行安全）
- 环境验证和状态报告
- 开发环境文档更新

范围不包括：
- setup-postgres-local.sh 修改（Phase 26 已完成）
- Docker Compose 服务管理（生产服务通过 Jenkins Pipeline 管理）
- Keycloak 配置（使用生产 Keycloak 测试）
- CI/CD Pipeline 变更

</domain>

<decisions>
## Implementation Decisions

### 脚本关系
- **D-01:** setup-dev.sh 封装 setup-postgres-local.sh，不替换它
  - setup-dev.sh 调用 setup-postgres-local.sh install 进行 PostgreSQL 安装
  - setup-dev-local.sh 保持独立可用（直接管理 PG）
  - setup-dev.sh 额外处理环境配置和验证

### 脚本范围
- **D-02:** setup-dev.sh 负责完整的本地开发环境搭建
  - 步骤：1) 检查 Homebrew → 2) 安装 PostgreSQL → 3) 创建开发数据库 → 4) 验证环境
  - 不包含 Docker Compose 启动（开发环境不需要 Docker 服务）
  - 不包含 .env 文件创建（开发者从 .env.example 手动复制）

### 幂等设计
- **D-03:** 遵循 setup-postgres-local.sh 的幂等模式
  - 已安装的 PostgreSQL 不重新安装（brew list 检查）
  - 已存在的数据库不重新创建（psql 检查）
  - 已运行的服务不重新启动（brew services list 检查）
  - 重运行为 no-op，仅显示当前状态

### 架构检测
- **D-04:** 复用 setup-postgres-local.sh 的 detect_homebrew_prefix() 逻辑
  - arm64 → /opt/homebrew
  - x86_64 → /usr/local
  - 不需要额外的架构处理

### 交互模式
- **D-05:** 非交互式执行（无人值守安全）
  - 不使用 read -p 等待用户输入
  - 所有操作自动执行，步骤进度通过日志输出
  - 错误时停止并显示修复建议

### 环境验证
- **D-06:** 脚本最后执行环境验证，输出状态报告
  - 检查 PostgreSQL 版本（应显示 17.x）
  - 检查开发数据库是否存在（noda_dev, keycloak_dev）
  - 检查 brew services 状态（应显示 started）
  - 输出 "✓ 开发环境就绪" 或具体缺失项

### 脚本位置和入口
- **D-07:** 脚本位于项目根目录 setup-dev.sh
  - 使用方式：`bash setup-dev.sh`
  - source scripts/lib/log.sh 复用日志函数
  - 调用 scripts/setup-postgres-local.sh install

### Claude's Discretion
- setup-dev.sh 具体步骤和日志格式
- 环境验证检查项的具体命令
- 错误信息的具体措辞

### Folded Todos
无待办事项可合并。

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 现有代码参考
- `scripts/setup-postgres-local.sh` — Phase 26 创建的 PG 本地管理脚本（核心复用对象）
- `scripts/lib/log.sh` — 日志函数库（日志格式和颜色定义）
- `docs/DEVELOPMENT.md` — 开发环境文档（需要同步更新）

### 前序 Phase 决策
- `.planning/phases/26-postgresql/26-CONTEXT.md` — 宿主机 PostgreSQL 安装决策
- `.planning/phases/27-docker-compose/27-CONTEXT.md` — dev 容器清理决策

### 需求文档
- `.planning/ROADMAP.md` §Phase 30 — 成功标准（DEVEX-01 至 DEVEX-03）
- `.planning/REQUIREMENTS.md` §开发者体验 — DEVEX-01, DEVEX-02, DEVEX-03

### 项目文档
- `.planning/PROJECT.md` — v1.5 目标、架构
- `.planning/STATE.md` — 当前进度

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/setup-postgres-local.sh` — 完整的 PG 安装/初始化/状态检查/卸载功能（install 子命令直接复用）
- `scripts/lib/log.sh` — 彩色日志函数（log_info, log_success, log_error, log_warn）
- `detect_homebrew_prefix()` — Apple Silicon/Intel 路径检测（DEVEX-03 已在 Phase 26 实现）

### Established Patterns
- 子命令模式（setup-postgres-local.sh 的 install/init-db/status/uninstall 模式）
- 幂等检查模式（brew list 检查安装、psql 检查数据库存在）
- 步骤编号日志（步骤 1/10、步骤 2/10 格式）
- Homebrew prefix 动态检测

### Integration Points
- setup-dev.sh 通过 `bash scripts/setup-postgres-local.sh install` 调用 PG 安装
- setup-dev.sh 通过 `source scripts/lib/log.sh` 复用日志
- docs/DEVELOPMENT.md 需要更新本地开发环境说明

</code_context>

<specifics>
## Specific Ideas

- setup-dev.sh 可以在成功后输出下一步指引（如何启动 Docker 服务、如何连接数据库等）
- 考虑添加 --verbose 标志控制输出详细程度（默认简洁）
- 错误消息可以包含修复建议（如 "Run: brew install postgresql@17"）

</specifics>

<deferred>
## Deferred Ideas

- **Docker Compose 开发环境启动** — 当前开发环境不需要 Docker，保持简单
- **.env 文件自动生成** — 开发者从 .env.example 复制更安全
- **IDE 配置集成** — 超出基础设施范围
- **多版本 PostgreSQL 支持** — 当前仅支持 17.x
- **Linux 支持** — 当前仅支持 macOS (Homebrew)

---
*Phase: 30-dev-setup*
*Context gathered: 2026-04-17 (auto mode)*
