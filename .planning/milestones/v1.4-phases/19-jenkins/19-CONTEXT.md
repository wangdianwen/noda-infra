# Phase 19: Jenkins 安装与基础配置 - Context

**Gathered:** 2026-04-14
**Status:** Ready for planning

<domain>
## Phase Boundary

管理员通过 `setup-jenkins.sh` 脚本在宿主机上安装 Jenkins LTS，配置 Docker 权限，自动完成首次安全配置（管理员用户、插件、安全加固、Pipeline 作业），以及完全卸载 Jenkins。

范围包括：
- Java 21 + Jenkins LTS 宿主机安装（apt 原生安装）
- systemd 服务管理（端口 8888）
- jenkins 用户 Docker 权限配置
- 首次启动自动化配置（管理员、插件、安全、Pipeline 作业）
- 完全卸载能力

</domain>

<decisions>
## Implementation Decisions

### 端口配置
- **D-01:** Jenkins 监听端口改为 **8888**（通过 systemd override 配置 `Environment="JENKINS_PORT=8888"`），避免与 Keycloak 内部 8080 端口造成运维混淆

### 脚本功能范围
- **D-02:** `setup-jenkins.sh` 提供完整运维工具集，包含以下子命令：
  - `install` — 安装 Java 21 + Jenkins LTS + 配置 Docker 权限 + 启动服务 + 自动化首次配置
  - `uninstall` — 完全卸载 Jenkins 及所有残留文件
  - `status` — 检查 Jenkins 运行状态、端口、Docker 权限
  - `show-password` — 显示初始管理员密码
  - `restart` — 重启 Jenkins 服务
  - `upgrade` — 升级 Jenkins 到最新 LTS
  - `reset-password` — 重置管理员密码

### 卸载清理深度
- **D-03:** uninstall 执行完全清理，移除：
  - Jenkins 软件包（`apt remove --purge`）
  - `/var/lib/jenkins`（作业历史、插件、配置）
  - `/var/log/jenkins`（日志）
  - `/etc/apt/sources.list.d/jenkins.list` + keyring（APT 源）
  - systemd override 文件（如果存在）
  - jenkins 用户从 docker 组移除
  - jenkins 系统用户删除

### 首次启动安全配置
- **D-04:** install 完成后自动执行以下配置（通过 Jenkins API/CLI 或 init.groovy.d 脚本）：
  1. **管理员用户创建** — 跳过初始设置向导，从 `.env` 或配置文件读取凭据创建管理员
  2. **插件预安装** — Git、Pipeline、Pipeline Stage View、Credentials Binding、Timestamper
  3. **安全加固** — CSRF 保护、禁用匿名读取、Agent 安全策略
  4. **创建 Pipeline 作业** — 预创建第一个 Pipeline job（noda-apps 部署）

### Claude's Discretion
- Jenkins 初始配置的具体实现方式（groovy init 脚本 vs jenkins-cli vs REST API）由 researcher/planner 决定
- 管理员凭据的存储位置和格式（环境变量 vs 配置文件）
- Pipeline 作业模板的具体内容

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### 研究文档
- `.planning/research/STACK.md` — Jenkins 技术栈选型（LTS 版本、Java 21、安装方式）
- `.planning/research/ARCHITECTURE.md` — 系统架构设计（宿主机安装、systemd 管理、Docker 权限）
- `.planning/research/FEATURES.md` — 功能特性详细设计
- `.planning/research/PITFALLS.md` — 已知陷阱和注意事项

### 需求文档
- `.planning/REQUIREMENTS.md` — JENK-01 至 JENK-04 需求定义
- `.planning/ROADMAP.md` §Phase 19 — 成功标准和验收条件

### 现有代码参考
- `scripts/lib/log.sh` — 结构化日志库（脚本复用）
- `scripts/deploy/deploy-infrastructure-prod.sh` — 现有部署脚本模式参考
- `scripts/utils/validate-docker.sh` — Docker 环境验证模式参考
- `docker/docker-compose.yml` — 现有 Docker 网络和服务架构
- `CLAUDE.md` — 部署规则和项目架构说明

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/lib/log.sh` — 带颜色的结构化日志函数（log_info/log_success/log_error/log_warn），所有脚本统一使用
- `scripts/lib/health.sh` — `wait_container_healthy()` 函数，可用于 Jenkins install 后验证服务状态
- `scripts/deploy/deploy-infrastructure-prod.sh` — 7 步部署流程模式（验证→保存回滚→备份→部署→健康检查→配置→最终验证）
- `scripts/deploy/deploy-apps-prod.sh` — 镜像回滚机制参考

### Established Patterns
- 所有脚本使用 `set -euo pipefail` 严格模式
- 日志通过 `source scripts/lib/log.sh` 引入
- 部署脚本包含回滚机制
- Docker Compose 使用 `-f base -f prod` 双文件 overlay 模式

### Integration Points
- Jenkins 需要操作宿主机 Docker daemon（`/var/run/docker.sock`）
- Jenkins 需要访问 `noda-network` Docker 网络中的容器
- Jenkins 工作空间需要能执行 `docker compose` 和 `docker run` 命令
- 未来 Pipeline 需要读取 `.env` 文件中的凭据

</code_context>

<specifics>
## Specific Ideas

- 管理员凭据建议从 `config/secrets.sops.yaml` 解密获取（与现有凭据管理方式一致），或使用独立的 `.env.jenkins` 文件
- Jenkins 安装路径保持默认 `/var/lib/jenkins`，不自定义
- systemd override 文件放在 `/etc/systemd/system/jenkins.service.d/override.conf`

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 19-jenkins*
*Context gathered: 2026-04-14*
