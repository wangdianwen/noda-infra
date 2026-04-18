# Requirements: Noda 基础设施 v1.7 代码精简与规整

**Defined:** 2026-04-18
**Core Value:** 数据库永不丢失。重构不得影响备份系统和生产部署流程。

## v1.7 Requirements

### 共享库提取

- [ ] **LIB-01**: `http_health_check()` 和 `e2e_verify()` 从 4 个文件提取到 `scripts/lib/deploy-check.sh`，所有调用方改为 source 该库，保持各文件中不同的超时/重试参数通过函数参数传递
- [ ] **LIB-02**: `detect_platform()` 从 8 个文件提取到 `scripts/lib/platform.sh`，所有调用方改为 source 该库
- [ ] **LIB-03**: `cleanup_old_images()` 从 3 个文件提取到 `scripts/lib/image-cleanup.sh`，所有调用方改为 source 该库

### 蓝绿部署统一

- [ ] **BLUE-01**: 合并 `scripts/blue-green-deploy.sh` 和 `scripts/keycloak-blue-green-deploy.sh` 为统一的参数化脚本，通过环境变量（SERVICE_IMAGE、SERVICE_PORT、HEALTH_PATH 等）区分服务，保留旧脚本作为向后兼容 wrapper（调用新脚本）
- [ ] **BLUE-02**: 更新 `scripts/rollback-findclass.sh` 使用 `scripts/lib/deploy-check.sh` 中的共享函数，消除内联重复的健康检查逻辑

### 清理与重命名

- [ ] **CLEAN-01**: 删除 `scripts/verify/` 下 5 个一次性验证脚本（quick-verify.sh、verify-apps.sh、verify-services.sh、verify-infrastructure.sh、verify-findclass.sh），这些脚本硬编码旧架构路径，已无法在生产环境运行
- [ ] **CLEAN-02**: 重命名 `scripts/backup/lib/health.sh` 为 `scripts/backup/lib/db-health.sh`，消除与 `scripts/lib/health.sh`（Docker 容器健康检查）的命名混淆，更新所有 source 路径

### 质量保证

- [ ] **QUAL-01**: 对 `scripts/` 下所有 .sh 文件运行 ShellCheck，消除 error 级别问题，warning 级别可按需抑制
- [ ] **QUAL-02**: 使用 shfmt 统一格式化 `scripts/` 下所有 .sh 文件，建立一致的代码风格

## Future Requirements

### 精简大文件（v1.8+）

- **SLIM-01**: 拆分 `scripts/pipeline-stages.sh`（1108行）为按职责分组的模块文件
- **SLIM-02**: 拆分 `scripts/setup-jenkins.sh`（1029行）为安装/配置/安全子命令模块

### 安全脚本收敛（v1.8+）

- **SEC-01**: 将 8 个安全脚本收敛为 `noda-security.sh` 单一入口

### 测试框架（v1.8+）

- **TEST-01**: 引入 Bats 测试框架替代手写测试脚本
- **TEST-02**: 将 ShellCheck 集成为 Jenkins Pipeline 质量门禁

## Out of Scope

| Feature | Reason |
|---------|--------|
| 合并 scripts/lib/log.sh 和 scripts/backup/lib/log.sh | 运行环境不同（宿主机终端 vs 容器 cron），合并会威胁备份系统稳定性 |
| 合并 scripts/lib/health.sh 和 scripts/backup/lib/health.sh | 功能完全不同（Docker 容器健康 vs 数据库连接+磁盘检查），仅命名巧合 |
| 引入 Bats 测试框架 | 本次专注重构，测试框架迁移是独立工作 |
| Docker Compose 文件精简 | overlay 模式运行良好，无实际冗余 |
| pipeline-stages.sh 拆分 | 高风险（Jenkins 运行时字符串拼接调用），留待专项处理 |
| setup-jenkins.sh 拆分 | 仅在安装/卸载时使用，优先级低 |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| LIB-01 | — | Pending |
| LIB-02 | — | Pending |
| LIB-03 | — | Pending |
| BLUE-01 | — | Pending |
| BLUE-02 | — | Pending |
| CLEAN-01 | — | Pending |
| CLEAN-02 | — | Pending |
| QUAL-01 | — | Pending |
| QUAL-02 | — | Pending |
