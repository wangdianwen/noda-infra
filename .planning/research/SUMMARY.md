# Project Research Summary

**Project:** Noda v1.6 -- Jenkins Pipeline 强制执行（Docker 权限收敛 + 操作审计）
**Domain:** 单服务器 Linux 权限模型，Docker 访问控制，CI/CD 强制执行
**Researched:** 2026-04-17
**Confidence:** HIGH

## Executive Summary

Noda v1.6 的核心目标是实现"所有容器部署只能通过 Jenkins Pipeline 完成"的强制执行机制。研究结论是：不需要引入任何新的软件包或第三方工具。所需机制全部基于 Linux 标准权限模型 -- Docker socket 属组收敛、文件权限锁定（chown/chmod）、sudoers 白名单、auditd 内核审计。这些是 Debian/Ubuntu 自带的标准组件，已有 20+ 年成熟历史。

推荐的实现路径是：将 Docker socket 属组从 `docker` 改为 `jenkins`（通过 systemd override 持久化），同时从 docker 组移除非 jenkins 用户。这样 Jenkins Pipeline 的所有 docker 命令无需任何代码修改即可继续工作，而其他用户直接执行 docker 命令会被拒绝。配合 sudoers 白名单为管理员保留只读调试能力，通过 break-glass 脚本为紧急部署提供受控替代路径。

关键风险集中在三个方面：(1) 权限收敛后 Jenkins 服务重启导致组缓存不一致，必须在每次权限变更后重启 Jenkins 并验证；(2) 蓝绿部署的 nginx upstream 文件写入权限必须同步调整，否则 Pipeline 在 Switch 阶段失败；(3) 紧急回退路径必须与权限收敛同步就绪，否则生产故障时无法手动恢复。

## Key Findings

### Recommended Stack

全部基于 Linux 系统自带组件，零外部依赖。

**核心机制：**
- Docker socket 属组收敛：`chown root:jenkins /var/run/docker.sock` + systemd override -- 直接控制谁能访问 Docker
- 文件权限锁定：`chown root:jenkins` + `chmod 750` -- 限制部署脚本仅 jenkins 可执行
- sudoers 白名单：`/etc/sudoers.d/noda-docker` -- 管理员只读 docker 命令 + break-glass 紧急部署
- auditd 内核审计：`/etc/audit/rules.d/noda-docker.rules` -- 记录所有 docker 命令执行，不可绕过
- Jenkins Audit Trail 插件（436.vc0d1e79fc5a_3）：应用层审计，记录 Pipeline 触发和配置变更
- Matrix Authorization Strategy 插件（3.2.9, 91% 安装率）：Jenkins 权限矩阵细化

### Expected Features

**Must have（table stakes）：**
- T1: Docker 组权限收敛 -- 移除非 jenkins 用户的 docker 组权限，确保只有 jenkins + root 可执行 docker 命令
- T2: 部署脚本权限锁定 -- deploy 脚本改为 750 root:jenkins，确保只有 jenkins 可执行
- T3: 操作系统级 Docker 命令审计 -- auditd 监控 docker.sock 读写，记录谁在什么时候执行了什么
- T4: Jenkins Pipeline 操作审计 -- Audit Trail 插件记录 Jenkins 内部操作
- T5: Jenkins 权限矩阵细化 -- Matrix Auth 插件限制非管理员的 Job 配置和 Script Console 访问

**Should have（differentiators）：**
- D1: Break-Glass 紧急访问机制文档化 -- 权限收敛后必须同步提供紧急替代方案
- D2: 部署脚本 Break-Glass Wrapper -- 自动记录紧急访问日志
- D3: auditd 日志轮转配置 -- 防止磁盘溢出
- D5: 定期权限审查提醒 -- 防止权限配置随时间漂移

**Defer（v1.7+）：**
- D4: Jenkins H2 -> PostgreSQL 迁移 -- 从 PROJECT.md 继承的遗留需求，与权限收敛逻辑独立

### Architecture Approach

采用"Docker socket 属组收敛 + sudoers 白名单"方案（方案 A），不使用 Rootless Docker 或 Docker Socket Proxy。核心设计是将 `/var/run/docker.sock` 的属组从 `docker` 改为 `jenkins`，通过 systemd ExecStartPost override 确保持久化。

**Major components:**
1. **systemd override** (`/etc/systemd/system/docker.service.d/socket-permissions.conf`) -- Docker 重启后自动恢复 socket 权限为 root:jenkins
2. **sudoers 白名单** (`/etc/sudoers.d/noda-docker`) -- Cmnd_Alias 定义只读命令集合，管理员通过 sudo 调试；break-glass 紧急入口需密码
3. **break-glass 脚本** (`/usr/local/bin/noda-emergency-deploy.sh`) -- 紧急部署受控入口，验证 Jenkins 不可用后记录审计日志，以 root 执行部署
4. **auditd 规则** (`/etc/audit/rules.d/noda-docker.rules`) -- 内核级审计 docker-cmd、docker-socket、deploy-scripts、break-glass 等事件
5. **权限收敛执行脚本** (`scripts/setup-docker-permissions.sh`) -- 一键 apply/verify/rollback/status

**关键架构决策：**
- jenkins 用户通过 socket 属组（而非 docker 组）获得 Docker 访问 -- Pipeline 零代码修改
- Jenkins workspace 中 checkout 的脚本属主为 jenkins -- 仓库文件权限仅限制手动执行，两者互不干扰
- noda-ops 容器内备份不受宿主机权限影响 -- 容器内 cron 不依赖宿主机 docker 权限
- 保留 docker 组但清空成员 -- Docker 安装/更新需要 docker 组存在

### Critical Pitfalls

1. **完全锁定后无法紧急恢复** -- 必须在权限收敛前先建立 break-glass 紧急路径（sudoers 白名单 + 封条机制），否则 Jenkins 宕机时无恢复手段。建议分阶段锁定，先观察一周无问题后再收紧
2. **Linux 组变更不立即生效** -- `gpasswd -d` 或 `usermod` 后已运行的进程使用旧的组缓存。必须 `systemctl restart jenkins` 后才能生效。验证方法：`cat /proc/$(pgrep -f jenkins.war)/status | grep Groups`
3. **Docker 重启后 socket 权限恢复** -- 不配置 systemd override 的话，下次 Docker 重启 socket 恢复为 root:docker 660，jenkins 失去访问权，所有 Pipeline 失败。这是整个方案最关键的持久化点
4. **蓝绿部署 upstream 文件写入权限** -- `config/nginx/snippets/` 目录和 `/opt/noda/active-env*` 文件必须 jenkins 可写（root:jenkins 660/770），否则蓝绿切换的 Switch 阶段失败
5. **sudoers 通配符权限提升** -- `NOPASSWD: /usr/bin/docker *` 等于给 root shell。只授权特定脚本路径和只读命令，脚本内部验证参数

## Implications for Roadmap

基于研究，建议 4 个 Phase 的结构。

### Phase 1: Docker Socket 权限收敛 + 文件权限锁定
**Rationale:** socket 权限收敛是整个 v1.6 的基础。文件权限锁定与 socket 收敛必须同步 -- 没有 socket 收敛，脚本锁定无意义（用户可以直接 docker compose）；没有脚本锁定，socket 收敛不完整（用户可以手动执行部署脚本）。两者一起完成并验证 Jenkins Pipeline 完整可用。
**Delivers:** Docker 访问仅限 jenkins 用户；systemd override 持久化；部署脚本仅 jenkins 可执行；nginx snippets 和 /opt/noda 状态文件权限就绪
**Addresses:** T1（Docker 组权限收敛）、T2（部署脚本权限锁定）
**Avoids:** Pitfall 3（Docker 重启 socket 恢复）-- systemd override 持久化；Pitfall 4（upstream 写入权限）-- 同步调整文件权限；Pitfall 6（组缓存）-- 变更后重启 Jenkins 并验证
**验证:** `sudo -u jenkins docker ps` 成功；`sudo -u admin docker ps` 失败；`ls -la scripts/deploy/*.sh` 显示 root:jenkins 750；完整 Pipeline 端到端通过

### Phase 2: sudoers 白名单 + Break-Glass 机制
**Rationale:** Phase 1 锁定了正常路径后，必须同步提供受控的替代路径。sudoers 白名单为管理员保留调试能力（只读 docker 命令），break-glass 脚本为紧急部署提供审计记录的入口。两者必须一起交付 -- 没有 break-glass 的权限锁定是危险的。
**Delivers:** 管理员只读 docker 命令（sudo docker ps/logs/inspect）；紧急部署入口脚本（验证 Jenkins 不可用 + 记录审计日志）；封条机制
**Addresses:** D1（Break-Glass 文档化）、D2（Wrapper 脚本）
**Uses:** sudoers Cmnd_Alias 白名单、break-glass 封条文件、syslog 审计记录
**Avoids:** Pitfall 1（锁定后无法恢复）-- break-glass 提供紧急路径；Pitfall 5（sudoers 通配符）-- 只授权特定命令
**验证:** `sudo docker ps` 成功；`sudo docker run` 被拒绝；break-glass 脚本在 Jenkins 运行时拒绝执行；break-glass 脚本在 Jenkins 不可用时记录日志并执行部署

### Phase 3: 审计日志系统
**Rationale:** 审计是监控层，与权限控制正交。auditd 覆盖操作系统层（谁执行了 docker 命令），Audit Trail 插件覆盖 Jenkins 层（谁触发了 Pipeline）。两层互补：正常路径通过 Audit Trail 追踪，绕过路径通过 auditd 发现。可以与 Phase 1-2 并行实施，但建议在权限模型稳定后再配置。
**Delivers:** Docker 命令内核级审计日志；Jenkins 操作审计日志；日志轮转配置防止磁盘溢出
**Addresses:** T3（auditd 审计）、T4（Jenkins Audit Trail）、D3（日志轮转）
**Uses:** auditd 规则、Jenkins Audit Trail 插件（File logger）、logrotate
**Avoids:** Pitfall 7（审计日志磁盘满）-- 配置 max_log_file + num_logs + logrotate
**验证:** `ausearch -k docker-cmd` 返回结果；`aureport -x -i` 显示可读的操作报告；Jenkins audit log 文件存在并记录构建事件

### Phase 4: Jenkins 权限矩阵 + 统一管理脚本
**Rationale:** Jenkins 内部权限控制是细粒度增强。Matrix Auth 插件限制非管理员只能触发 Job 而不能修改配置或访问 Script Console。统一管理脚本整合所有权限配置，提供 apply/verify/rollback/status 四个子命令，确保权限配置可重复执行和可回滚。
**Delivers:** Jenkins 权限矩阵（管理员全权限/普通用户只触发/匿名禁止）；setup-docker-permissions.sh 统一脚本；setup-jenkins.sh 同步更新
**Addresses:** T5（Jenkins 权限矩阵）、D5（权限审查提醒）
**Uses:** Matrix Authorization Strategy 插件
**验证:** 普通用户只能触发 Job 不能修改配置；`setup-docker-permissions.sh verify` 全部 PASS；`setup-jenkins.sh uninstall && install` 产生正确权限配置

### Phase Ordering Rationale

1. **Phase 1 是基础：** socket 权限 + 文件权限是所有其他措施的前提。没有它，sudoers 无意义（用户可以直接 docker compose），审计不完整（所有人都有 docker 权限）
2. **Phase 2 紧随 Phase 1：** 锁定正常路径后必须立即提供替代路径。先锁定再建 break-glass 会有无法手动部署的风险窗口
3. **Phase 3 可并行但建议靠后：** 审计技术上独立，但权限模型稳定后配置更准确
4. **Phase 4 最后：** Jenkins 权限矩阵是锦上添花；统一管理脚本需要所有配置就绪后才能编写

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 1:** 需要在生产服务器上确认当前 docker 组成员和 socket 权限实际状态（`getent group docker`、`ls -la /var/run/docker.sock`）。研究基于代码分析而非实际服务器状态。同时需要确认 jenkins 用户 UID（影响 auditd auid 过滤）和 Docker compose 插件的实际安装路径
- **Phase 2:** sudoers 规则需要在生产环境验证语法（`visudo -c`）。不同 Linux 发行版的 sudo 版本可能影响 Defaults 语法兼容性（特别是 `log_output` 和 `iolog_dir`）

Phases with standard patterns (skip research-phase):
- **Phase 3:** auditd 规则配置和 Jenkins 插件安装是标准操作，文档充分
- **Phase 4:** Matrix Auth 插件配置是标准 Jenkins 管理操作，91% 安装率说明模式成熟

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | 全部基于 Linux 标准机制（gpasswd、chown/chmod、auditd、sudoers），无第三方依赖，20+ 年成熟历史 |
| Features | HIGH | 基于项目代码库 28 个脚本的深度审计，所有集成点已识别；Jenkins 插件基于官方文档和安装率验证 |
| Architecture | HIGH | 方案 A（socket 属组收敛）在架构研究中与 Rootless Docker、纯 sudoers、Docker 授权插件全面对比，结论有明确依据 |
| Pitfalls | HIGH | 基于项目代码完整分析（28 个 docker 命令脚本）+ Linux/Docker 权限模型确定性知识；Pitfall-to-Phase 映射完整 |

**Overall confidence:** HIGH

### Gaps to Address

- **生产服务器实际状态未知：** 当前 docker 组成员、socket 权限、auditd 安装状态等需要通过 SSH 确认。建议 Phase 1 开始前在服务器上运行状态快照命令（`getent group docker`、`ls -la /var/run/docker.sock`、`systemctl status auditd`）
- **jenkins 用户 UID 确认：** 研究假设 jenkins UID 为 1001，实际可能不同。auditd 规则中的 auid 过滤需要使用实际 UID
- **Docker compose 插件路径：** sudoers 规则和 auditd 规则中需要引用 docker compose 路径。不同安装方式路径不同：`/usr/libexec/docker/cli-plugins/docker-compose`（apt）vs `/usr/local/bin/docker-compose`（手动）。需要 `which docker` 和 `docker compose version` 确认
- **Jenkins workspace vs 仓库路径：** Pipeline 实际执行路径需要确认。如果 Jenkins 直接 checkout 到 `/opt/noda-infra/`，文件权限设计需调整；如果使用 workspace，则仓库权限和 workspace 权限互不干扰
- **setup-jenkins.sh 同步更新：** 权限模型变更后安装脚本必须同步更新（第 160 行 `usermod -aG docker jenkins` 需要修改为 socket 属组方式），否则重新安装会回退到旧的权限模型

## Sources

### Primary (HIGH confidence)
- 项目代码库：28 个使用 docker 命令的脚本完整审计
  - `scripts/setup-jenkins.sh`（Jenkins 安装逻辑、docker 组配置第 160 行）
  - `scripts/manage-containers.sh`（蓝绿容器管理、set_active_env()、update_upstream()）
  - `scripts/pipeline-stages.sh`（Pipeline 阶段函数）
  - `scripts/blue-green-deploy.sh`（蓝绿部署逻辑）
  - `scripts/deploy/deploy-infrastructure-prod.sh`（基础设施部署）
  - `scripts/deploy/deploy-apps-prod.sh`（应用部署）
  - `scripts/backup/lib/health.sh`（宿主机 docker exec 调用）
  - `jenkins/Jenkinsfile` / `Jenkinsfile.infra` / `Jenkinsfile.noda-site` / `Jenkinsfile.keycloak`
  - `docker/docker-compose.yml` / `docker-compose.app.yml`
  - `config/nginx/snippets/upstream-*.conf`
- [Docker Engine Security](https://docs.docker.com/engine/security/) -- Docker 官方安全文档，确认 auditd 监控 docker.sock 的推荐方式
- [Jenkins Audit Trail Plugin](https://plugins.jenkins.io/audit-trail/) -- 版本 436.vc0d1e79fc5a_3，官方插件文档
- [Jenkins Matrix Authorization Plugin](https://plugins.jenkins.io/matrix-auth/) -- 版本 3.2.9，91% 安装率
- [Linux auditd Documentation](https://linux.die.net/man/8/auditd) -- 审计框架配置和规则语法
- [sudoers man page](https://linux.die.net/man/5/sudoers) -- Cmnd_Alias、Defaults 语法
- [systemd override 机制](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html) -- ExecStartPost 钩子

### Secondary (MEDIUM confidence)
- [CIS Benchmark Linux](https://www.cisecurity.org/cis-benchmarks/) -- auditd 配置最佳实践
- [Ubuntu auditd Guide](https://ubuntu.com/server/docs/security-the-audit-daemon) -- Ubuntu 官方指南
- Docker socket 属组方案在生产环境的具体实践 -- 基于社区最佳实践，未经本项目验证

---
*Research completed: 2026-04-17*
*Ready for roadmap: yes*
