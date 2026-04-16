# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.4 — CI/CD 零停机部署

**Shipped:** 2026-04-16
**Phases:** 7 | **Plans:** 11

### What Was Built
- Jenkins 宿主机原生安装/卸载自动化（setup-jenkins.sh + groovy init 脚本）
- Nginx upstream include 抽离，支持动态流量切换
- 蓝绿容器管理 + 零停机部署 + 紧急回滚脚本
- Jenkinsfile 9 阶段 Pipeline（Pre-flight → Build → Test → Deploy → Health Check → Switch → Verify → CDN Purge → Cleanup）
- Pipeline 增强特性（备份时效性检查 + CDN 清除 + 镜像清理）

### What Worked
- Phase 顺序严格线性执行，避免了并行部署冲突
- source guard 模式让脚本可安全复用（manage-containers.sh → blue-green-deploy.sh）
- pipeline-stages.sh 作为单一真相源，Jenkinsfile 只调用函数库
- envsubst 指定变量替换避免了 shell 内置变量被意外替换的坑

### What Was Inefficient
- Phase 25 清理归档步骤消耗了额外一个完整 plan，可以整合到 Phase 24
- 蓝绿部署调试需要在服务器上实际操作，本地无法完整验证
- groovy init 脚本的 idempotent 验证需要反复重启 Jenkins

### Patterns Established
- upstream include 抽离模式（Pipeline 重写文件 + nginx -s reload）
- docker run 独立管理蓝绿容器，不通过 compose
- 非阻止型 CDN 清除（部署不应因 CDN API 问题失败）
- 时间阈值镜像清理（替代简单计数保留）

### Key Lessons
1. 健康检查和 E2E 验证必须区分层级（容器内部 vs nginx 代理 vs 外部可达）
2. Pipeline 凭据使用 withCredentials + 单引号 sh 块防止日志泄露
3. 旧脚本保留为手动回退比直接删除更安全
4. 部署文档需要在代码变更后立即更新，避免文档与实际不一致

### Cost Observations
- Timeline: 3 天完成 7 个阶段（2026-04-14 → 2026-04-16）
- 速度较快，得益于线性依赖关系和清晰的阶段目标
- Phase 22（蓝绿部署核心）是最复杂的阶段，包含健康检查和回滚逻辑

---

## Cross-Milestone Trends

| Milestone | Phases | Plans | Days | Commits |
|-----------|--------|-------|------|---------|
| v1.0 备份系统 | 9 | 16 | 6 | ~60 |
| v1.1 基础设施现代化 | - | - | 1 | 29 |
| v1.2 修复与整合 | 5 | 10 | 1 | 96 |
| v1.3 安全收敛 | 4 | 4 | 1 | 89 |
| v1.4 CI/CD | 7 | 11 | 3 | ~101 |
