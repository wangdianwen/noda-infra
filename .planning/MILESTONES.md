# Milestones

## v1.5 开发环境本地化 + 基础设施 CI/CD (Shipped: 2026-04-17)

**Phases completed:** 5 phases, 12 plans, 17 tasks

**Key accomplishments:**

- Homebrew postgresql@17 本地管理脚本，4 子命令实现 install/init-db/status/uninstall，含 pg_hba.conf trust 认证自动修正和端口冲突检查
- 移除 docker-compose.dev.yml 和 simple.yml 中的 postgres-dev/keycloak-dev 服务定义，删除 dev-standalone.yml，保留 nginx/keycloak 开发覆盖
- deploy-infrastructure-prod.sh 移除 dev overlay 引用改为双文件模式 + migrate-data 废弃兼容处理
- 更新 README.md 和 4 个文档文件，移除 dev-standalone.yml、postgres-dev、keycloak-dev 的过时引用，引导用户使用本地 PostgreSQL
- Keycloak 蓝绿部署三大基础组件：env-keycloak.env 环境变量模板、upstream-keycloak.conf 蓝绿切换、manage-containers.sh 参数化适配
- Keycloak 7 阶段蓝绿部署 Pipeline（无构建模式）+ pipeline-stages.sh 扩展支持官方镜像服务
- Declarative Pipeline 7 阶段统一基础设施部署，choice 参数选择 4 服务，Backup 条件化 + postgres 30 分钟人工确认门禁
- deploy-infrastructure-prod.sh 精简为仅 postgres 部署，nginx/noda-ops 迁移到 Jenkinsfile.infra Pipeline 管理
- 1. [Rule 3 - Blocking] DEVELOPMENT.md 段落结构差异

---

## v1.4 CI/CD 零停机部署 (Shipped: 2026-04-16)

**Phases completed:** 7 phases, 11 plans
**Timeline:** 3 days (2026-04-14 → 2026-04-16)

**Key accomplishments:**

- Jenkins 宿主机原生安装/卸载脚本（setup-jenkins.sh 7 子命令 + groovy 自动化）
- Nginx upstream include 抽离（蓝绿路由基础，支持 nginx -s reload 切换）
- 蓝绿容器管理（manage-containers.sh 8 子命令 + env-findclass-ssr.env 模板）
- 蓝绿部署核心流程（blue-green-deploy.sh + rollback-findclass.sh，零停机 + 自动回滚）
- Jenkinsfile 9 阶段 Pipeline + pipeline-stages.sh 函数库（lint/test 质量门禁）
- Pipeline 增强特性（备份时效性检查 + CDN 缓存清除 + 镜像时间阈值清理）
- 旧脚本保留为手动回退 + 部署文档更新 + 里程碑归档

---

## v1.3 安全收敛与分组整理 (Shipped: 2026-04-12)

**Phases completed:** 4 phases, 4 plans, 8 tasks

**Key accomplishments:**

- 升级 noda-ops 容器 Alpine 3.21 + postgresql17-client，通过 PGSSLMODE=disable 环境变量全局禁用 Docker 内部 SSL 协商
- auth.noda.co.nz 流量统一经 nginx 反向代理到 Keycloak，移除 8080/9000 端口暴露，健康检查统一使用 8080 TCP 检查
- 将 3 个 Docker Compose 文件中的 postgres-dev 5433 和 Keycloak 9000 管理端口从 0.0.0.0 绑定改为 127.0.0.1，消除网络暴露风险
- 为 5 个 Docker Compose 文件统一双标签体系：noda.service-group(infra/apps) + noda.environment(prod/dev)，修复 findclass-ssr 的 noda-apps 不一致命名

---

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
