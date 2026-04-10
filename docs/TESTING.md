<!-- generated-by: gsd-doc-writer -->

# 测试文档

本项目是 Docker Compose 基础设施仓库，不包含传统的应用单元测试框架（如 Jest、Vitest 或 pytest）。测试体系以 **Bash 脚本** 形式围绕数据库备份系统构建，涵盖备份、恢复、云上传、告警和监控等核心功能的验证。

## 测试框架和配置

### 测试方式

本项目使用 **自编 Bash 测试框架**，不依赖第三方测试库。所有测试脚本位于 `scripts/backup/tests/` 目录，测试辅助函数内嵌在各自脚本中。

核心测试模式包括：

- **端到端集成测试** — 依赖运行中的 PostgreSQL 容器和 B2 云存储连接
- **功能验证测试** — 验证库函数是否存在且可调用
- **备份完整性测试** — 使用 `pg_restore --list` 验证备份文件格式

### 前置条件

运行测试前必须满足以下条件：

1. Docker Compose 服务已启动，`noda-infra-postgres-prod` 容器运行中
2. 备份系统配置文件 `.env.backup` 已正确配置（B2 凭证、数据库连接信息）
3. `rclone` 已安装（版本 >= 1.60），用于 B2 云存储操作
4. `jq` 已安装，用于 JSON 格式验证

## 运行测试

### 运行全部备份功能测试

```bash
# 备份功能测试（健康检查、数据库列表、备份执行、文件格式、权限验证）
bash scripts/backup/tests/test_backup.sh
```

### 运行恢复功能测试

```bash
# 完整恢复流程测试（创建测试数据库 → 备份 → 恢复 → 验证数据完整性 → 清理）
bash scripts/backup/tests/test_restore.sh

# 快速恢复测试（简化版，适合日常验证）
bash scripts/backup/tests/test_restore_quick.sh
```

### 运行云存储相关测试

```bash
# rclone 配置完整测试（安装检查、凭证配置、B2 连接、上传/列表/删除操作）
bash scripts/backup/tests/test_rclone.sh

# B2 配置函数测试
bash scripts/backup/tests/test_b2_config.sh

# 云上传端到端测试（创建测试文件 → 上传 B2 → 验证 → 清理）
bash scripts/backup/tests/test_upload.sh

# 列出 B2 上的备份文件
bash scripts/backup/tests/list_b2.sh
```

### 运行模块单元测试

```bash
# 告警库测试（邮件命令、历史文件、去重机制、记录格式、配置验证）
bash scripts/backup/tests/test_alert.sh

# 指标库测试（指标记录、平均值计算、异常检测、历史清理、JSON 格式）
bash scripts/backup/tests/test_metrics.sh

# 每周验证测试的 Phase 4 单元测试（常量定义、函数存在性、脚本可执行性）
bash scripts/backup/tests/test_weekly_verify.sh
```

### 运行每周自动验证测试

```bash
# 完整每周验证（从 B2 下载备份 → 恢复到临时数据库 → 多层验证）
bash scripts/backup/test-verify-weekly.sh

# 指定数据库和超时
bash scripts/backup/test-verify-weekly.sh --databases "keycloak_db findclass_db" --timeout 1800
```

### 清理测试数据

```bash
# 清理 B2 上的测试文件
bash scripts/backup/tests/cleanup_b2_tests.sh
```

## 测试文件清单

所有测试脚本位于 `scripts/backup/tests/` 目录：

| 文件 | 类型 | 测试内容 |
|------|------|----------|
| `test_backup.sh` | 集成测试 | 健康检查、数据库列表、备份执行、文件格式和权限验证（7 个测试用例） |
| `test_restore.sh` | 集成测试 | 完整备份恢复流程，含数据完整性验证（5 个测试用例） |
| `test_restore_quick.sh` | 集成测试 | 快速恢复功能验证（5 个步骤） |
| `test_rclone.sh` | 集成测试 | rclone 安装、B2 凭证、配置创建、连接测试、基本操作（5 个测试） |
| `test_upload.sh` | 集成测试 | 云上传端到端流程（6 个步骤） |
| `test_b2_config.sh` | 功能验证 | B2 配置函数和凭证验证 |
| `test_alert.sh` | 单元测试 | 告警库功能（5 个测试用例） |
| `test_metrics.sh` | 单元测试 | 指标库功能（5 个测试用例） |
| `test_weekly_verify.sh` | 单元测试 | 每周验证脚本的函数存在性和配置正确性（9 个测试用例） |
| `create_test_db.sh` | 测试辅助 | 创建/清理测试数据库（`test_backup_db`） |
| `cleanup_b2_tests.sh` | 测试辅助 | 清理 B2 上的测试文件 |
| `list_b2.sh` | 测试辅助 | 列出 B2 存储桶上的备份文件 |

## 编写新测试

### 文件命名约定

测试脚本统一放在 `scripts/backup/tests/` 目录，命名格式为 `test_<功能名>.sh`。

### 测试框架模式

测试脚本遵循统一的结构模式：

```bash
#!/bin/bash
set -euo pipefail

# 1. 定位脚本目录和依赖
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/constants.sh"

# 2. 初始化计数器
TESTS_PASSED=0
TESTS_FAILED=0

# 3. 定义断言辅助函数
test_pass() {
  echo "  PASS: $1"
  ((TESTS_PASSED++))
}
test_fail() {
  echo "  FAIL: $1"
  ((TESTS_FAILED++))
}

# 4. 编写测试用例函数
test_feature_name() {
  # 测试逻辑
}

# 5. 主函数运行所有测试并汇总结果
main() {
  test_feature_name
  # 输出结果
}
main "$@"
```

### 断言辅助函数

各测试脚本内置了以下常用断言模式：

- **`assert_equals expected actual message`** — 断言两个值相等（`test_alert.sh`、`test_metrics.sh`、`test_weekly_verify.sh`）
- **`assert_success exit_code message`** — 断言命令执行成功（`test_weekly_verify.sh`）
- **`assert_contains haystack needle message`** — 断言字符串包含（`test_weekly_verify.sh`）
- **`assert_greater_than min actual message`** — 断言数值大于阈值（`test_metrics.sh`）
- **`test_start` / `test_pass` / `test_fail`** — 带计数的测试流程控制（`test_backup.sh`、`test_restore.sh`）

### 依赖库

测试可以引用 `scripts/backup/lib/` 下的库模块：

| 库文件 | 功能 |
|--------|------|
| `constants.sh` | 退出码常量、测试配置（超时、重试、前缀）、告警和指标常量 |
| `config.sh` | 配置加载和 B2 凭证验证 |
| `log.sh` | 日志输出函数 |
| `cloud.sh` | B2 云存储操作（上传、下载、清理） |
| `db.sh` | 数据库操作 |
| `restore.sh` | 备份恢复功能 |
| `verify.sh` | 备份文件完整性验证 |
| `health.sh` | 健康检查 |
| `alert.sh` | 告警系统（邮件发送、去重） |
| `metrics.sh` | 指标记录和异常检测 |
| `test-verify.sh` | 每周验证测试核心函数（测试数据库管理、下载恢复、多层验证） |
| `util.sh` | 通用工具函数 |

## 覆盖率要求

本项目未配置自动化的代码覆盖率阈值。测试覆盖范围由手动维护，重点关注：

- **备份全流程**：健康检查 -> 备份 -> 验证 -> 上传 -> 清理
- **恢复全流程**：下载 -> 创建测试数据库 -> 恢复 -> 数据完整性验证 -> 清理
- **云存储操作**：B2 连接、上传、下载、列表、删除
- **监控系统**：指标记录、异常检测、告警去重、历史清理

## CI 集成

本项目未配置 GitHub Actions 或其他 CI/CD 管道。测试通过以下方式定期执行：

- **每日自动备份**：凌晨 3:00 由 crontab 触发 `backup-postgres.sh`，内置验证步骤
- **每周自动验证**：周日凌晨 3:00 由 crontab 触发 `test-verify-weekly.sh`，从 B2 下载最新备份并验证恢复

Docker 镜像 `scripts/backup/docker/Dockerfile.test-verify` 提供了独立的测试验证环境，基于 `postgres:15-alpine`，预装 rclone、jq、bash 等工具。

详细的端到端测试报告见 `scripts/backup/TEST_REPORT.md`。
