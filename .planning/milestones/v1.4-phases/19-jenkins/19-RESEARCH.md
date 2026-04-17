# Phase 19: Jenkins 安装与基础配置 - Research

**Researched:** 2026-04-14
**Domain:** Jenkins LTS 宿主机安装 + systemd 管理 + Docker 权限 + 首次自动化配置
**Confidence:** HIGH

## Summary

本阶段在宿主机上安装 Jenkins LTS 2.541.3（apt 原生安装），配置 systemd 服务（端口 8888），授予 jenkins 用户 Docker 操作权限，并通过 `init.groovy.d` 脚本实现首次启动自动化配置（管理员用户、插件、安全加固、Pipeline 作业）。脚本 `setup-jenkins.sh` 提供 7 个子命令覆盖完整的生命周期管理。

Jenkins apt 安装流程已经过官方文档验证 [VERIFIED: jenkins.io/doc/book/installing/linux/]。systemd override 机制通过官方 systemd 服务管理文档确认 [VERIFIED: jenkins.io/doc/book/system-administration/systemd-services/]。init.groovy.d 自动化配置方案是 Jenkins 社区标准做法 [ASSUMED]，具体 API 调用需在实现时验证。

**Primary recommendation:** 使用 `init.groovy.d` 脚本实现首次自动化配置（比 JCasC 更适合一次性安装场景），脚本遵循项目现有的 `set -euo pipefail` + `source log.sh` 模式。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Jenkins 监听端口改为 **8888**（通过 systemd override 配置 `Environment="JENKINS_PORT=8888"`），避免与 Keycloak 内部 8080 端口造成运维混淆
- **D-02:** `setup-jenkins.sh` 提供完整运维工具集，包含以下子命令：
  - `install` — 安装 Java 21 + Jenkins LTS + 配置 Docker 权限 + 启动服务 + 自动化首次配置
  - `uninstall` — 完全卸载 Jenkins 及所有残留文件
  - `status` — 检查 Jenkins 运行状态、端口、Docker 权限
  - `show-password` — 显示初始管理员密码
  - `restart` — 重启 Jenkins 服务
  - `upgrade` — 升级 Jenkins 到最新 LTS
  - `reset-password` — 重置管理员密码
- **D-03:** uninstall 执行完全清理，移除：
  - Jenkins 软件包（`apt remove --purge`）
  - `/var/lib/jenkins`（作业历史、插件、配置）
  - `/var/log/jenkins`（日志）
  - `/etc/apt/sources.list.d/jenkins.list` + keyring（APT 源）
  - systemd override 文件（如果存在）
  - jenkins 用户从 docker 组移除
  - jenkins 系统用户删除
- **D-04:** install 完成后自动执行以下配置（通过 Jenkins API/CLI 或 init.groovy.d 脚本）：
  1. **管理员用户创建** — 跳过初始设置向导，从 `.env` 或配置文件读取凭据创建管理员
  2. **插件预安装** — Git、Pipeline、Pipeline Stage View、Credentials Binding、Timestamper
  3. **安全加固** — CSRF 保护、禁用匿名读取、Agent 安全策略
  4. **创建 Pipeline 作业** — 预创建第一个 Pipeline job（noda-apps 部署）

### Claude's Discretion
- Jenkins 初始配置的具体实现方式（groovy init 脚本 vs jenkins-cli vs REST API）由 researcher/planner 决定
- 管理员凭据的存储位置和格式（环境变量 vs 配置文件）
- Pipeline 作业模板的具体内容

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| JENK-01 | 管理员可以通过 `setup-jenkins.sh install` 在宿主机原生安装 Jenkins LTS | Jenkins 官方 apt 安装流程 + systemd 服务管理已验证 |
| JENK-02 | 管理员可以通过 `setup-jenkins.sh uninstall` 完全卸载 Jenkins 及其残留文件 | 卸载清理路径已在 CONTEXT.md D-03 中锁定 |
| JENK-03 | Jenkins 用户自动加入 docker 组，可直接操作 Docker daemon | `usermod -aG docker jenkins` 标准 Linux 权限管理 |
| JENK-04 | Jenkins 安装后首次启动可获取初始管理员密码 | `/var/lib/jenkins/secrets/initialAdminPassword` 已在官方文档确认 |
</phase_requirements>

## Standard Stack

### Core
| Library/Component | Version | Purpose | Why Standard |
|-------------------|---------|---------|--------------|
| Jenkins LTS | 2.541.3 | CI/CD 控制器 | 最新 LTS (2026-03-18)，包含安全修复 [VERIFIED: jenkins.io/changelog-stable/] |
| OpenJDK 21 (Debian) | 21.x | Jenkins 运行时 | Jenkins 官方推荐，apt install openjdk-21-jre [VERIFIED: jenkins.io/doc/book/installing/linux/] |
| systemd | 系统自带 | Jenkins 服务管理 | Jenkins 2.335+ 使用 systemd 替代 init.d [VERIFIED: jenkins.io/doc/book/system-administration/systemd-services/] |

### Supporting
| Component | Purpose | When to Use |
|-----------|---------|-------------|
| init.groovy.d 脚本 | 首次启动自动化配置 | install 子命令在启动 Jenkins 前写入 |
| jenkins-cli.jar | 命令行管理 Jenkins | reset-password 子命令使用 |
| Eclipse Temurin JRE | OpenJDK 发行版（替代方案） | 如果 Debian 仓库 OpenJDK 不可用 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| init.groovy.d | JCasC (Configuration as Code) | JCasC 更适合持续管理，但单服务器一次性安装场景 init.groovy.d 更简单直接 [ASSUMED] |
| init.groovy.d | jenkins-cli.jar + REST API | CLI/API 需要等待 Jenkins 完全启动，init.groovy.d 在启动过程中执行，时序更可控 [ASSUMED] |
| Debian OpenJDK | Eclipse Temurin | Debian 自带 OpenJDK 安装更简单，无需额外添加仓库；Temurin 在某些发行版上更稳定 [ASSUMED] |

**Installation:**
```bash
# Java 21 安装
sudo apt update && sudo apt install fontconfig openjdk-21-jre

# Jenkins LTS apt 源添加
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update && sudo apt install jenkins
```

**Version verification:** Jenkins 2.541.3 确认为 2026-03-18 发布的最新 LTS [VERIFIED: jenkins.io/changelog-stable/]

## Architecture Patterns

### Recommended Project Structure
```
scripts/
├── setup-jenkins.sh              # 主脚本（7 个子命令）
└── jenkins/
    ├── init.groovy.d/
    │   ├── 01-security.groovy    # 管理员用户 + 安全策略
    │   ├── 02-plugins.groovy     # 插件安装
    │   └── 03-pipeline-job.groovy # 创建 Pipeline 作业
    └── config/
        └── jenkins-admin.env     # 管理员凭据模板
```

### Pattern 1: 子命令分发模式
**What:** 主脚本根据 `$1` 分发到不同函数
**When to use:** 所有 setup-jenkins.sh 子命令
**Example:**
```bash
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/log.sh"

case "${1:-}" in
  install)      cmd_install "$@" ;;
  uninstall)    cmd_uninstall "$@" ;;
  status)       cmd_status "$@" ;;
  show-password) cmd_show_password "$@" ;;
  restart)      cmd_restart "$@" ;;
  upgrade)      cmd_upgrade "$@" ;;
  reset-password) cmd_reset_password "$@" ;;
  *)            usage && exit 1 ;;
esac
```

### Pattern 2: init.groovy.d 首次配置模式
**What:** 在 Jenkins 启动前将 groovy 脚本写入 `$JENKINS_HOME/init.groovy.d/`
**When to use:** install 子命令的自动化配置部分
**Example:**
```groovy
// 来源: Jenkins 官方文档 + 社区最佳实践
// 01-security.groovy
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()
def hudsonRealm = new HudsonPrivateSecurityRealm(false)
hudsonRealm.createAccount(adminUsername, adminPassword)
instance.setSecurityRealm(hudsonRealm)

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)
instance.save()
```

### Pattern 3: systemd override 端口配置
**What:** 通过 drop-in override 文件修改 Jenkins 端口，不修改包管理的 service 文件
**When to use:** install 子命令配置端口 8888
**Example:**
```bash
# 来源: [VERIFIED: jenkins.io/doc/book/system-administration/systemd-services/]
sudo mkdir -p /etc/systemd/system/jenkins.service.d/
sudo tee /etc/systemd/system/jenkins.service.d/override.conf > /dev/null <<'EOF'
[Service]
Environment="JENKINS_PORT=8888"
EOF
sudo systemctl daemon-reload
```

### Pattern 4: 跳过 Setup Wizard
**What:** 通过 JAVA_OPTS 环境变量跳过首次启动向导
**When to use:** init.groovy.d 脚本配置好所有内容后，不需要向导
**Example:**
```bash
# 在 systemd override 中添加:
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false"
```
注意：必须同时在 groovy 脚本中调用 `Jenkins.getInstance().getSetupWizard().completeSetup()` 确保向导不弹出。

### Anti-Patterns to Avoid
- **直接编辑 `/lib/systemd/system/jenkins.service`:** 包升级会覆盖，必须使用 override.conf [VERIFIED: jenkins.io/doc/book/system-administration/systemd-services/]
- **在 groovy 脚本中使用 `System.getenv()` 读取管理员密码但不做空值检查:** 环境变量缺失时 groovy 脚本会静默失败
- **install 时不在 apt install 前先安装 Java:** Jenkins 安装前必须有 Java，否则服务启动会失败 [VERIFIED: jenkins.io/doc/book/installing/linux/]
- **忘记在 uninstall 中移除 jenkins 用户:** 仅 apt remove 不会删除系统用户

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Jenkins 端口修改 | sed 替换 service 文件 | systemd override.conf | 包升级安全，官方推荐方式 |
| 插件安装 | 手动下载 .jpi 文件 | init.groovy.d + UpdateCenter API | 自动解析依赖关系 |
| 管理员用户创建 | 手动操作 Web UI | init.groovy.d HudsonPrivateSecurityRealm | 可重复执行，脚本化 |
| 密码重置 | 直接修改 XML 文件 | jenkins-cli.jar 或 groovy 脚本 | 正确处理密码哈希 |
| 安全配置 | 手动在 UI 点击 | init.groovy.d 脚本 | 一致性，可审计 |

**Key insight:** Jenkins 所有配置都可以通过 Groovy 脚本在 init.groovy.d 中完成。init.groovy.d 脚本在 Jenkins 启动时按字母顺序执行，比手动 UI 配置或外部 API 调用更可靠，因为不需要处理 Jenkins 尚未就绪的时序问题。

## Common Pitfalls

### Pitfall 1: Java 未先安装导致 Jenkins 启动失败
**What goes wrong:** 先安装 Jenkins 包再安装 Java，jenkins 服务启动时找不到 Java
**Why it happens:** Jenkins 包不依赖特定 Java 版本，不会自动拉取 JRE
**How to avoid:** install 子命令中先执行 `apt install openjdk-21-jre`，验证 `java -version` 后再安装 Jenkins
**Warning signs:** `systemctl status jenkins` 显示 `jenkins: failed to find a valid Java installation`
**Source:** [VERIFIED: jenkins.io/doc/book/installing/linux/] 官方文档明确警告

### Pitfall 2: Jenkins 用户加入 docker 组后不生效
**What goes wrong:** 执行 `usermod -aG docker jenkins` 后不重启 Jenkins，jenkins 用户仍无法执行 docker 命令
**Why it happens:** Linux 组成员变更需要重新登录（或重启进程）才能生效
**How to avoid:** usermod 后执行 `systemctl restart jenkins`
**Warning signs:** Jenkins Pipeline 中 `docker ps` 返回 permission denied

### Pitfall 3: init.groovy.d 脚本每次启动都执行
**What goes wrong:** 管理员用户创建脚本在每次 Jenkins 重启时都执行，如果密码变了会覆盖
**Why it happens:** init.groovy.d 中的脚本在每次 Jenkins 启动时都运行，不仅仅是首次
**How to avoid:** 脚本中加幂等检查 — 先判断用户/插件是否已存在再创建；或在首次配置完成后删除脚本文件
**Warning signs:** 重启 Jenkins 后管理员密码被重置

### Pitfall 4: systemd override 中 JENKINS_PORT 不生效
**What goes wrong:** 修改了 override.conf 但 Jenkins 仍监听 8080
**Why it happens:** 修改 override 后没有执行 `systemctl daemon-reload`
**How to avoid:** 写入 override.conf 后立即执行 `systemctl daemon-reload`
**Warning signs:** `curl localhost:8888` 连接失败，`curl localhost:8080` 成功

### Pitfall 5: 插件安装需要重启
**What goes wrong:** init.groovy.d 安装插件后不重启 Jenkins，插件未完全加载
**Why it happens:** 某些插件安装后需要 Jenkins 重启才能生效（特别是 Pipeline 相关插件）
**How to avoid:** 在 install 子命令的最后阶段执行一次 `systemctl restart jenkins`，并在重启后清理 init.groovy.d 脚本
**Warning signs:** Jenkins UI 中插件显示已安装但功能不可用

### Pitfall 6: uninstall 后 APT 缓存残留
**What goes wrong:** 卸载后 `/var/cache/jenkins/` 仍有 war 包缓存，占用磁盘空间
**Why it happens:** `apt remove --purge` 不清理某些缓存目录
**How to avoid:** uninstall 时显式 `rm -rf /var/cache/jenkins`
**Warning signs:** 卸载后 `du -sh /var/cache/jenkins` 仍有占用

## Code Examples

### install 子命令核心流程
```bash
# 来源: [VERIFIED: jenkins.io/doc/book/installing/linux/]
cmd_install() {
    # Step 1: 安装 Java 21
    sudo apt update
    sudo apt install -y fontconfig openjdk-21-jre
    java -version

    # Step 2: 添加 Jenkins apt 源
    sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
      https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
    echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
      https://pkg.jenkins.io/debian-stable binary/ | \
      sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
    sudo apt update

    # Step 3: 安装 Jenkins
    sudo apt install -y jenkins

    # Step 4: 配置端口 8888
    # [VERIFIED: jenkins.io/doc/book/system-administration/systemd-services/]
    sudo mkdir -p /etc/systemd/system/jenkins.service.d/
    sudo tee /etc/systemd/system/jenkins.service.d/override.conf > /dev/null <<'EOF'
[Service]
Environment="JENKINS_PORT=8888"
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false"
EOF
    sudo systemctl daemon-reload

    # Step 5: 写入 init.groovy.d 脚本
    # (见下方 groovy 脚本示例)

    # Step 6: Docker 权限
    sudo usermod -aG docker jenkins

    # Step 7: 启动并等待就绪
    sudo systemctl enable jenkins
    sudo systemctl start jenkins
    # 等待 Jenkins 完全启动（轮询 HTTP 端口）
    wait_for_jenkins

    # Step 8: 清理 init.groovy.d（首次配置完成后删除）
    sudo rm -rf /var/lib/jenkins/init.groovy.d/

    log_success "Jenkins 安装完成，访问 http://<server-ip>:8888"
}
```

### 01-security.groovy — 管理员用户 + 安全策略
```groovy
// 来源: [ASSUMED] Jenkins 社区最佳实践
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()

// 创建管理员用户
def hudsonRealm = new HudsonPrivateSecurityRealm(false)
def adminUser = System.getenv('JENKINS_ADMIN_USER') ?: 'admin'
def adminPass = System.getenv('JENKINS_ADMIN_PASSWORD')
if (adminPass == null) {
    // 从配置文件读取
    def props = new Properties()
    def configFile = new File(System.getenv('JENKINS_HOME') ?: '/var/lib/jenkins', '.admin.env')
    if (configFile.exists()) {
        configFile.withInputStream { props.load(it) }
        adminUser = props.getProperty('JENKINS_ADMIN_USER', 'admin')
        adminPass = props.getProperty('JENKINS_ADMIN_PASSWORD')
    }
}
if (adminPass != null) {
    // 检查用户是否已存在（幂等）
    if (hudsonRealm.getUser(adminUser) == null) {
        hudsonRealm.createAccount(adminUser, adminPass)
    }
    instance.setSecurityRealm(hudsonRealm)

    def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
    strategy.setAllowAnonymousRead(false)
    instance.setAuthorizationStrategy(strategy)
}

// CSRF 保护
instance.setCrumbIssuer(new DefaultCrumbIssuer(true))

// 跳过 Setup Wizard
def setupWizard = instance.getSetupWizard()
if (setupWizard != null) {
    setupWizard.completeSetup()
}

instance.save()
```

### 02-plugins.groovy — 插件安装
```groovy
// 来源: [ASSUMED] Jenkins 社区最佳实践
import jenkins.model.*
import hudson.PluginWrapper

def instance = Jenkins.getInstance()
def pm = instance.getPluginManager()
def uc = instance.getUpdateCenter()

uc.updateAllSites()

def plugins = [
    'git',
    'workflow-aggregator',
    'pipeline-stage-view',
    'credentials-binding',
    'timestamper'
]

plugins.each { pluginId ->
    if (!pm.getPlugin(pluginId)) {
        println "Installing plugin: ${pluginId}"
        def plugin = uc.getPlugin(pluginId)
        if (plugin) {
            plugin.deploy(true)
        }
    } else {
        println "Plugin already installed: ${pluginId}"
    }
}

instance.save()
```

### wait_for_jenkins 函数
```bash
# 等待 Jenkins HTTP 端口就绪
wait_for_jenkins() {
    local port="${JENKINS_PORT:-8888}"
    local max_wait=120
    local waited=0
    log_info "等待 Jenkins 启动（端口 ${port}）..."
    while [ $waited -lt $max_wait ]; do
        if curl -sf "http://localhost:${port}/login" > /dev/null 2>&1; then
            log_success "Jenkins 已就绪"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    log_error "Jenkins 启动超时（${max_wait}s）"
    return 1
}
```

### reset-password 子命令
```bash
# 使用 Groovy 脚本重置密码（通过 Jenkins Script Console 方式）
cmd_reset_password() {
    local new_password="${2:-}"
    if [ -z "$new_password" ]; then
        log_error "请提供新密码: setup-jenkins.sh reset-password <new-password>"
        exit 1
    fi
    # 通过 jenkins-cli.jar 或直接写 groovy 脚本
    sudo systemctl restart jenkins
    # 等待启动后执行 groovy 脚本
    # 或直接操作 Jenkins 的 users 目录
    log_info "密码已重置"
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| System V init 管理 | systemd 管理 | Jenkins 2.335 / 2.332.1 | 服务配置使用 override.conf，不再编辑 /etc/default/jenkins |
| Jenkins Weekly | Jenkins LTS 2.541.3 | 2026-03-18 | 当前最新 LTS，包含安全修复 |
| JCasC 配置 | init.groovy.d 脚本 | 一直是标准方式 | 单服务器一次性安装用 init.groovy.d 更合适 |
| Java 17 | Java 21 | Jenkins 2.541.x 推荐 | Java 21 是 Jenkins 2.555.1+ 的最低要求，提前适配 |

**Deprecated/outdated:**
- `/etc/default/jenkins` 配置: Jenkins 2.335+ 使用 systemd override，不再使用 EnvironmentFile [VERIFIED: jenkins.io/doc/book/system-administration/systemd-services/]
- `JENKINS_PORT` 在 `/etc/default/jenkins` 中设置: 改为在 systemd override 中设置

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | init.groovy.d 脚本按字母顺序执行且在每次启动时运行 | Architecture Patterns | 需要加幂等检查或在配置完成后删除脚本 |
| A2 | `HudsonPrivateSecurityRealm.createAccount()` 在用户已存在时幂等（不覆盖密码） | Code Examples | 如果不幂等，每次重启都会重置密码 |
| A3 | `FullControlOnceLoggedInAuthorizationStrategy` 是适合单服务器场景的授权策略 | Architecture Patterns | 如果需要更细粒度的权限控制需要改用 Matrix-based |
| A4 | Jenkins 2.541.3 的 apt 仓库 key 是 `jenkins.io-2026.key` | Code Examples | 如果 key 名称变了，apt 安装会失败 |
| A5 | `DefaultCrumbIssuer` 类在 init.groovy.d 中可用（无需额外 import） | Code Examples | 如果 import 路径不对，CSRF 配置脚本会失败 |
| A6 | 插件安装后需要重启 Jenkins 才能完全生效 | Common Pitfalls | 如果不需要重启，install 流程可以简化 |

## Open Questions (RESOLVED)

1. **管理员凭据存储方式** — RESOLVED: 使用独立的 `.admin.env` 文件（由 Plan 02 Task 2 创建 `jenkins-admin.env.example` 模板），install 子命令复制到 `$JENKINS_HOME/.admin.env`（权限 600），groovy 脚本从该文件读取。决策依据: CONTEXT.md Claude's Discretion。

2. **init.groovy.d 脚本清理时机** — RESOLVED: 首次配置完成后由 install 子命令末尾删除 `rm -rf $JENKINS_HOME/init.groovy.d/`。决策依据: CONTEXT.md D-04 + Research 推荐方案。

3. **Pipeline 作业模板内容** — RESOLVED: 创建占位 Pipeline 作业（基本 config.xml 结构），具体 Jenkinsfile 在 Phase 23 填充。决策依据: CONTEXT.md Claude's Discretion + Research Open Question 3 推荐。

## Environment Availability

> 本阶段需要在 **生产服务器**（Debian/Ubuntu）上执行安装，而非本地 macOS 开发环境。以下为生产服务器上的预期依赖。

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| apt (Debian/Ubuntu) | Jenkins 安装 | 待确认 | — | — |
| Java 21 (openjdk-21-jre) | Jenkins 运行时 | 待安装 | — | — |
| fontconfig | Jenkins UI | 待安装 | — | — |
| curl | 健康检查 | 大概率已安装 | — | wget |
| Docker daemon | Docker 权限验证 | 已安装 | — | — |
| sudo | 所有操作 | 已安装 | — | — |

**Missing dependencies with no fallback:**
- Java 21: install 子命令会自动安装
- fontconfig: install 子命令会自动安装

**Missing dependencies with fallback:**
- curl: 如果不可用，健康检查可改用 wget

**注意:** 本阶段脚本在本地 macOS 开发环境中无法直接测试 apt/systemd 命令。脚本编写完成后需要在生产服务器上执行验证。

## Validation Architecture

> workflow.nyquist_validation 为 true（config.json 默认启用）

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bash script testing（手动验证） |
| Config file | 无 — 脚本直接在生产服务器执行 |
| Quick run command | `bash scripts/setup-jenkins.sh status` |
| Full suite command | `bash scripts/setup-jenkins.sh install && bash scripts/setup-jenkins.sh status && bash scripts/setup-jenkins.sh show-password` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| JENK-01 | install 安装 Jenkins LTS | manual-only | `systemctl status jenkins` | 需要生产服务器 |
| JENK-02 | uninstall 完全清理 | manual-only | `dpkg -l jenkins; ls /var/lib/jenkins` | 需要生产服务器 |
| JENK-03 | jenkins 用户可操作 Docker | manual-only | `sudo -u jenkins docker ps` | 需要生产服务器 |
| JENK-04 | 获取初始管理员密码 | manual-only | `bash scripts/setup-jenkins.sh show-password` | 需要生产服务器 |

### Sampling Rate
- **Per task commit:** 脚本语法检查 `bash -n scripts/setup-jenkins.sh`
- **Per wave merge:** 在生产服务器执行 install + status + show-password 验证
- **Phase gate:** 4 个 success criteria 全部手动验证通过

### Wave 0 Gaps
- [ ] 本阶段无自动化测试框架（bash 脚本在远程服务器执行，需手动验证）
- [ ] 可添加 `shellcheck` 静态分析作为 CI 前置检查
- [ ] 脚本语法验证: `bash -n scripts/setup-jenkins.sh` 可在本地执行

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | HudsonPrivateSecurityRealm（Jenkins 内置用户数据库） |
| V3 Session Management | yes | Jenkins 内置会话管理 |
| V4 Access Control | yes | FullControlOnceLoggedInAuthorizationStrategy + 禁用匿名读取 |
| V5 Input Validation | no | 本阶段无用户输入处理 |
| V6 Cryptography | no | 本阶段不涉及加密操作 |

### Known Threat Patterns for Jenkins 宿主机安装

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 未认证的 Jenkins Web UI 访问 | Spoofing/Tampering | init.groovy.d 创建管理员用户 + 禁用匿名读取 |
| CSRF 攻击触发任意构建 | Tampering | DefaultCrumbIssuer 启用 CSRF 保护 |
| jenkins 用户滥用 Docker socket | Elevation of Privilege | Jenkins 宿主机安装（非 Docker 容器）减少攻击面；限制 Pipeline 只执行预定义脚本 |
| Jenkins 监听 0.0.0.0:8888 | Information Disclosure | 如果不需要外部直接访问，可通过防火墙限制只允许 localhost |

## Sources

### Primary (HIGH confidence)
- [Jenkins Linux 安装文档](https://www.jenkins.io/doc/book/installing/linux/) — apt 安装步骤、Java 前置要求、Setup Wizard 流程 [VERIFIED]
- [Jenkins systemd 服务管理](https://www.jenkins.io/doc/book/system-administration/systemd-services/) — override.conf 机制、端口配置 [VERIFIED]
- [Jenkins LTS Changelog](https://www.jenkins.io/changelog-stable/) — 确认 2.541.3 为最新 LTS (2026-03-18) [VERIFIED]
- [Jenkins Managing Security](https://www.jenkins.io/doc/book/managing/security/) — CSRF 保护、授权策略选项 [VERIFIED]
- 项目代码: `scripts/lib/log.sh`, `scripts/lib/health.sh` — 脚本模式参考
- 项目代码: `scripts/setup-keycloak-full.sh` — 类似的安装配置脚本模式参考
- 项目代码: `scripts/deploy/deploy-apps-prod.sh` — 步骤化部署模式参考

### Secondary (MEDIUM confidence)
- [Jenkins CLI 文档](https://www.jenkins.io/doc/book/managing/cli/) — jenkins-cli.jar 使用方式、密码重置辅助
- `.planning/research/STACK.md` — Jenkins 技术栈选型
- `.planning/research/ARCHITECTURE.md` — Jenkins 架构设计
- `.planning/research/PITFALLS.md` — 已知陷阱

### Tertiary (LOW confidence)
- init.groovy.d 具体脚本示例 — 基于 Jenkins 社区最佳实践，未经 Context7 验证 [ASSUMED]
- HudsonPrivateSecurityRealm API 调用方式 — 基于训练知识 [ASSUMED]

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Jenkins 官方文档直接确认
- Architecture: HIGH — systemd override 机制官方文档明确，init.groovy.d 是标准 Jenkins 功能
- Pitfalls: HIGH — Java 前置安装和 systemd daemon-reload 在官方文档中有明确警告
- Groovy init 脚本: MEDIUM — API 可用性基于训练知识，具体类名和 import 路径需在实现时验证

**Research date:** 2026-04-14
**Valid until:** 2026-05-14（Jenkins LTS 3-6 个月更新一次，当前信息稳定）
