# Milestones

## v1.2 基础设施修复与整合 (Shipped: 2026-04-11)

**Phases completed:** 5 phases, 10 plans, 16 tasks

**Key accomplishments:**

- 1. [Rule 3 - Blocking] 跳过 Task 0 checkpoint:decision
- 修复容器内 check_disk_space() 的 return 0 跳过 bug，实现 psql 直连查询数据库大小 + df 挂载点空间检查，空间不足时返回 EXIT_DISK_SPACE_INSUFFICIENT (6)
- 修复 download_backup/download_latest_backup 的 B2 日期子目录路径处理，使用 basename 提取纯文件名 +
- 统一两个 Docker Compose 文件中 findclass-ssr 的 Dockerfile 路径引用为 ../noda-infra/deploy/Dockerfile.findclass-ssr，废弃引用不存在路径的部署脚本
- 为 6 个 Docker Compose 变体文件添加 noda.service-group 分组标签，实现 infra/apps 容器过滤
- keycloak-dev 独立容器（start-dev 模式）连接 keycloak_dev 数据库，主题目录热重载挂载，与生产完全隔离
- Noda 品牌主题 CSS 覆盖：修复 theme.properties 加载声明 + PatternFly v4 变量覆盖（Pounamu Green #0D9B6A）+ 直接选择器覆盖（卡片边框、焦点环、圆角 0.5rem）
- deploy/Dockerfile.noda-ops:
- 修改文件：
- Compose-based 镜像 digest 回滚 + 12 小时阈值部署前自动备份，确保部署失败时安全回退且数据始终受保护

---

## v1.0 Complete PostgreSQL Backup System (Shipped: 2026-04-06)

**Phases completed:** 9 phases, 16 plans, 23 tasks

**Key accomplishments:**

- 创建完整的测试基础设施，包括环境变量模板、测试数据库创建脚本、备份功能测试脚本和恢复功能测试脚本，为后续所有备份功能提供自动化验证能力
- 实现配置管理库和健康检查库文件，为后续备份执行提供可靠的前置检查和配置加载机制。
- 实现数据库备份的核心功能，包括日志输出、工具函数、数据库发现、备份执行和全局对象备份
- 实现备份验证功能和主脚本集成，提供完整的备份流程（健康检查 → 备份 → 验证 → 清理）和命令行参数支持，完整实现 D-43 测试模式。
- 创建日期:
- 创建日期:
- 完成日期
- 完成日期
- verify-phase6.sh 只读验证脚本确认所有核心变量冲突修复有效，8 项检查中 5 项通过、3 项非阻塞警告待 06-02 处理
- 修复 7 个库文件的防御性条件加载、统一 LIB_DIR 前缀命名、修复 print_summary 函数调用 bug，verify-phase6.sh 8 项检查全部通过（0 warnings）
- 修复 test_rclone.sh 的 3 个 BUG（错误后端类型名 backblazeb2、错误属性名、main() 跳过测试）和 cloud.sh 的 util.sh 隐式依赖，安全扫描确认无凭证泄漏
- restore_database() 和 verify_backup_integrity() 添加 /.dockerenv 环境检测，宿主机通过 docker exec 封装执行 PostgreSQL 命令，test_restore_quick.sh 全部 5 项测试通过
- verify-restore.sh 对照 4 个成功标准 9 项测试全部通过，修复 restore.sh 的 .dump 文件 docker cp 宿主机兼容性和 download_backup() stdout 日志污染问题
- 完成日期

---
