# Milestone v1.6 Requirements: Jenkins Pipeline 强制执行

**Goal:** 所有容器只能通过 Jenkins Pipeline 上线，禁止直接 docker compose / shell 脚本部署

---

## 权限收敛 (PERM)

- [ ] **PERM-01**: Docker socket 属组从 `docker` 改为 `jenkins`，非 jenkins 用户无法直接执行 docker 命令
- [ ] **PERM-02**: Docker socket 权限通过 systemd override 持久化，服务器重启后自动恢复
- [ ] **PERM-03**: 部署脚本（deploy/*.sh、pipeline-stages.sh、manage-containers.sh）文件权限锁定为 `750 root:jenkins`
- [ ] **PERM-04**: git pull 后文件权限自动恢复（setup-docker-permissions.sh 或 Pipeline pre-flight 集成）
- [ ] **PERM-05**: 统一权限管理脚本 `setup-docker-permissions.sh`，一站式配置所有权限

## 紧急访问 (BREAK)

- [ ] **BREAK-01**: admin 用户可通过 sudoers 白名单执行只读 docker 命令（ps、logs、inspect、stats、top）
- [ ] **BREAK-02**: admin 用户无法通过 sudoers 执行 docker 写入命令（run、rm、compose up/down、exec）
- [ ] **BREAK-03**: Break-Glass 紧急部署入口脚本，需密码验证 + 记录审计日志
- [ ] **BREAK-04**: Break-Glass 脚本在执行前验证 Jenkins 确实不可用（避免滥用）

## 审计日志 (AUDIT)

- [ ] **AUDIT-01**: auditd 规则监控所有 docker 命令执行，记录 auid（登录用户）、时间、命令参数
- [ ] **AUDIT-02**: auditd 日志独立存储，普通用户不可篡改
- [ ] **AUDIT-03**: Jenkins Audit Trail 插件安装，记录谁在什么时候触发了什么 Pipeline
- [ ] **AUDIT-04**: sudo 操作日志记录（通过 sudoers Defaults logfile 配置）

## Jenkins 兼容与权限 (JENKINS)

- [ ] **JENKINS-01**: 权限收敛后所有 4 个 Jenkins Pipeline 正常工作（findclass-ssr、noda-site、keycloak、infra）
- [ ] **JENKINS-02**: 权限收敛后备份脚本正常工作（noda-ops 容器内 + 宿主机 docker exec）
- [ ] **JENKINS-03**: Matrix Authorization Strategy 插件安装，区分管理员/开发者/只读角色
- [ ] **JENKINS-04**: 非 admin 用户可以触发 Pipeline 但不能修改 Job 配置

---

## Future Requirements (Deferred)

- chattr +i 锁定关键配置文件（防止 root 误操作）
- Docker Content Trust 镜像签名验证
- SELinux/AppArmor 强制访问控制
- 定期审计检查脚本（cron + 报告）

## Out of Scope

| Feature | Reason |
|---------|--------|
| skykiwi-crawler Pipeline | 单次任务容器，手动触发足够（v1.5 PROJECT.md 决策） |
| Rootless Docker | 迁移成本远大于收益，现有 docker-compose.yml 假设 rootful |
| Docker Socket Proxy (TEEU/HAProxy) | 单服务器场景过度工程化 |
| HashiCorp Vault / Teleport | 单服务器 + 1-2 管理员场景不需要 |
| LDAP/OIDC 集成 | Jenkins 内置用户管理足够 |
| Jenkins H2 → PostgreSQL 迁移 | 与强制执行主题关联度中等，推迟到 v1.7 |

---

## Traceability

| Requirement | Phase | Status |
|------------|-------|--------|
| PERM-01 | Phase 31 | Pending |
| PERM-02 | Phase 31 | Pending |
| PERM-03 | Phase 31 | Pending |
| PERM-04 | Phase 31 | Pending |
| PERM-05 | Phase 34 | Pending |
| BREAK-01 | Phase 32 | Pending |
| BREAK-02 | Phase 32 | Pending |
| BREAK-03 | Phase 32 | Pending |
| BREAK-04 | Phase 32 | Pending |
| AUDIT-01 | Phase 33 | Pending |
| AUDIT-02 | Phase 33 | Pending |
| AUDIT-03 | Phase 33 | Pending |
| AUDIT-04 | Phase 33 | Pending |
| JENKINS-01 | Phase 31 | Pending |
| JENKINS-02 | Phase 31 | Pending |
| JENKINS-03 | Phase 34 | Pending |
| JENKINS-04 | Phase 34 | Pending |
