# Phase 33: 审计日志系统 - Pattern Map

**Mapped:** 2026-04-18
**Files analyzed:** 7
**Analogs found:** 7 / 7

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `scripts/install-auditd-rules.sh` | 脚本 (install/verify/uninstall) | 文件 I/O + 系统配置 | `scripts/install-sudoers-whitelist.sh` | exact |
| `scripts/install-sudo-log.sh` | 脚本 (install/verify/uninstall) | 文件 I/O + 系统配置 | `scripts/install-sudoers-whitelist.sh` | exact |
| `scripts/setup-jenkins.sh` (修改) | 脚本 (步骤式安装) | 系统配置 | `scripts/setup-jenkins.sh` (现有) | exact (同文件) |
| `scripts/jenkins/init.groovy.d/05-audit-trail.groovy` | Groovy 脚本 (Jenkins 初始化) | Jenkins 插件安装 | `scripts/jenkins/init.groovy.d/02-plugins.groovy` | exact |
| `config/logrotate/jenkins-audit-trail` | 配置文件 (logrotate) | 文件 I/O 轮转 | `scripts/break-glass.sh` log_audit() 日志目录模式 | partial |
| `config/logrotate/sudo-logs` | 配置文件 (logrotate) | 文件 I/O 轮转 | `scripts/break-glass.sh` log_audit() 日志目录模式 | partial |
| `/etc/audit/rules.d/noda-docker.rules` (由脚本创建) | 配置文件 (auditd 规则) | 内核审计 | 无直接 analog | none |

## Pattern Assignments

### `scripts/install-auditd-rules.sh` (脚本, install/verify/uninstall 三件套)

**Analog:** `scripts/install-sudoers-whitelist.sh`

**文件头部和常量定义** (lines 1-19):
```bash
#!/bin/bash
set -euo pipefail

# ============================================
# Phase 33: auditd 规则安装/验证/卸载脚本
# ============================================
# 功能：安装 auditd 内核审计规则，监控所有 docker 命令执行
# 子命令：install, verify, uninstall, help
# 要求：需要 root 权限执行
# 兼容：macOS + Linux 双平台
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
```

**平台检测模式** (lines 23-33):
```bash
detect_platform() {
    local os
    os="$(uname)"
    if [[ "$os" == "Darwin" ]]; then
        echo "macos"
    else
        echo "linux"
    fi
}

PLATFORM="$(detect_platform)"
```

**install 子命令模式** (lines 39-153):
核心流程：
1. 平台检查（macOS 跳过）
2. 确保目标目录存在（`/etc/sudoers.d/` -> `/etc/audit/rules.d/`）
3. 备份当前状态
4. 写入配置文件（使用 `tee > /dev/null <<'EOF'` heredoc 模式）
5. 验证语法（`visudo -cf` -> `augenrules --load`）
6. 设置文件权限（`chmod` + `chown`）
7. 输出安装成功信息

```bash
cmd_install() {
    log_info "Phase 33: 安装 auditd 规则 (平台: $PLATFORM)..."

    # 1. 平台检查
    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 不需要 auditd 规则（开发环境无内核审计）"
        return 0
    fi

    # 2. 安装 auditd 包（如果未安装）
    if ! dpkg -l auditd >/dev/null 2>&1; then
        apt install -y auditd audispd-plugins
    fi

    # 3. 检查并移除 no-audit 默认规则
    ...

    # 4. 写入规则文件
    tee /etc/audit/rules.d/noda-docker.rules > /dev/null <<'EOF'
    ...规则内容...
    EOF

    # 5. 加载规则
    augenrules --load

    # 6. 设置文件权限
    chmod 0640 /etc/audit/rules.d/noda-docker.rules
    chown root:root /etc/audit/rules.d/noda-docker.rules

    # 7. 启动/重启 auditd
    systemctl enable auditd
    systemctl restart auditd
}
```

**verify 子命令模式** (lines 158-224):
核心流程：
1. 检查文件存在
2. 检查文件权限（使用 `stat -c '%a:%U:%G'`）
3. 语法验证（`visudo -cf` -> `auditctl -l`）
4. 检查关键内容（白名单命令 -> docker-cmd key）
5. 汇总 all_ok/pass 结果

```bash
cmd_verify() {
    local all_ok=true
    log_info "Phase 33: 验证 auditd 规则 (平台: $PLATFORM)..."

    # 1. 检查文件存在
    if [ ! -f /etc/audit/rules.d/noda-docker.rules ]; then
        log_error "auditd 规则文件不存在"
        return 1
    fi

    # 2. 检查 auditd 服务状态
    if ! systemctl is-active --quiet auditd; then
        log_error "auditd 服务未运行"
        all_ok=false
    fi

    # 3. 检查规则已加载
    if ! auditctl -l | grep -q "docker-cmd"; then
        log_error "auditd docker-cmd 规则未加载"
        all_ok=false
    fi

    # 4. 汇总
    if $all_ok; then
        log_success "所有验证通过 (PASS)"
    else
        log_error "部分验证失败 (FAIL)"
        return 1
    fi
}
```

**uninstall 子命令模式** (lines 229-245):
```bash
cmd_uninstall() {
    log_info "Phase 33: 卸载 auditd 规则..."
    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 不需要 auditd 规则，无需卸载"
        return 0
    fi
    rm -f /etc/audit/rules.d/noda-docker.rules
    augenrules --load
    log_success "已删除 auditd 规则文件"
}
```

**子命令分发模式** (lines 281-298):
```bash
case "${1:-}" in
    install)   cmd_install ;;
    verify)    cmd_verify ;;
    uninstall) cmd_uninstall ;;
    help|--help|-h) usage ;;
    *)         usage && exit 1 ;;
esac
```

---

### `scripts/install-sudo-log.sh` (脚本, install/verify/uninstall 三件套)

**Analog:** `scripts/install-sudoers-whitelist.sh`

**与 install-auditd-rules.sh 共享完全相同的文件结构和模式**，区别在于：
- 写入 `/etc/sudoers.d/noda-audit` 而非 `/etc/audit/rules.d/noda-docker.rules`
- 配置内容是 `Defaults logfile=/var/log/sudo-logs/sudo.log`
- 需要先 `mkdir -p /var/log/sudo-logs/` 创建日志目录
- 验证使用 `visudo -cf` 而非 `auditctl -l`
- 日志目录权限参考 break-glass.sh 的 `log_audit()` 模式：`chmod 640` + `chown root:root`

**日志目录创建模式** (来自 `scripts/break-glass.sh` lines 99-107):
```bash
# 确保 /var/log/noda/ 目录存在
sudo mkdir -p "$(dirname "$AUDIT_LOG")"
# ...
sudo chmod 640 "$AUDIT_LOG"
sudo chown root:jenkins "$AUDIT_LOG" 2>/dev/null || true
```

**sudoers 文件写入和验证模式** (来自 `scripts/install-sudoers-whitelist.sh` lines 67-141):
```bash
# 写入 sudoers 文件
tee "$SUDOERS_FILE" > /dev/null <<'EOF'
...规则内容...
EOF

# 验证语法
if ! visudo -cf "$SUDOERS_FILE"; then
    log_error "sudoers 语法验证失败，删除无效文件"
    rm -f "$SUDOERS_FILE"
    exit 1
fi
log_success "sudoers 语法验证通过"

# 设置文件权限
chmod 0440 "$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"
```

---

### `scripts/setup-jenkins.sh` (修改, 添加 Audit Trail 步骤)

**Analog:** `scripts/setup-jenkins.sh` (同文件修改)

**步骤式安装模式** (lines 134-248):
关键特征：
- 每步用 `log_info "步骤 N/10: <描述>"` 标记
- 步骤间有清晰的逻辑顺序
- init.groovy.d 脚本在步骤 7 写入

```bash
# 步骤 7/10: 写入 init.groovy.d 脚本
log_info "步骤 7/10: 写入 init.groovy.d 脚本"
if [ -d "$GROOVY_SRC_DIR" ] && ls "$GROOVY_SRC_DIR"/*.groovy > /dev/null 2>&1; then
    sudo mkdir -p "$JENKINS_HOME_LINUX/init.groovy.d"
    sudo cp "$GROOVY_SRC_DIR"/*.groovy "$JENKINS_HOME_LINUX/init.groovy.d/"
    sudo chown -R jenkins:jenkins "$JENKINS_HOME_LINUX/init.groovy.d"
    log_success "init.groovy.d 脚本已写入"
fi
```

**修改点：** 在现有步骤 7（init.groovy.d 写入）之前，不需要修改 setup-jenkins.sh 本身。新的 `05-audit-trail.groovy` 文件放入 `scripts/jenkins/init.groovy.d/` 目录后，步骤 7 的 `cp *.groovy` 会自动复制它。

**但需要注意：** Audit Trail 插件安装需要 Jenkins 启动后生效，而 init.groovy.d 在首次启动时执行。如果 Jenkins 已安装（非首次安装），需要额外处理。参考 cmd_install 中的步骤编号模式，可能需要在步骤 7.5 或 8 之后添加一个步骤来单独处理 Audit Trail 插件安装。

---

### `scripts/jenkins/init.groovy.d/05-audit-trail.groovy` (Groovy 脚本, Jenkins 插件安装)

**Analog:** `scripts/jenkins/init.groovy.d/02-plugins.groovy`

**Jenkins 插件安装模式** (lines 1-48):
```groovy
// Jenkins 首次启动插件安装
import jenkins.model.*
import hudson.PluginWrapper

def instance = Jenkins.getInstance()
def pm = instance.getPluginManager()
def uc = instance.getUpdateCenter()

// 初始化 Update Center
uc.updateAllSites()

// 插件列表
def plugins = [
    'audit-trail',   // Audit Trail — Pipeline 触发事件审计
]

def allInstalled = true

plugins.each { pluginId ->
    if (!pm.getPlugin(pluginId)) {
        println "Installing plugin: ${pluginId}"
        def plugin = uc.getPlugin(pluginId)
        if (plugin) {
            def result = plugin.deploy(true)
            allInstalled = false
        } else {
            println "WARNING: Plugin ${pluginId} not found in Update Center"
        }
    } else {
        println "Plugin already installed: ${pluginId}"
    }
}

instance.save()
```

**关键约定：**
- 文件命名：`NN-描述.groovy`，按字母顺序执行（01-security -> 02-plugins -> ... -> 05-audit-trail）
- 幂等性：`if (!pm.getPlugin(pluginId))` 检查避免重复安装
- 不在 Groovy 中触发重启：由 setup-jenkins.sh 处理
- File Logger 配置：根据 RESEARCH.md 分析，推荐安装后通过 UI 手动配置（Groovy API 不稳定），或者如果需要自动化，可以参考如下模式：

```groovy
// 可选：通过 Groovy 配置 Audit Trail File Logger
// 注意：此配置方式可能因插件版本变化而失效
import jenkins.model.*
import org.jenkinsci.plugins.audit.*
import java.util.logging.*

def instance = Jenkins.getInstance()
def auditTrailConfig = instance.getDescriptor('org.jenkinsci.plugins.audit.AuditTrailPlugin')

if (auditTrailConfig != null) {
    // 配置日志路径
    auditTrailConfig.setLog("/var/lib/jenkins/audit-trail/audit-trail.log")
    auditTrailConfig.setLogSize(50 * 1024 * 1024) // 50MB
    instance.save()
}
```

---

### `config/logrotate/jenkins-audit-trail` (配置文件, logrotate)

**Analog:** 无直接现有 logrotate 文件。参考 `scripts/break-glass.sh` 中日志目录权限模式。

**模式：** 新建 logrotate 配置文件。从 RESEARCH.md Pattern 5 提取：

```bash
# config/logrotate/jenkins-audit-trail
/var/lib/jenkins/audit-trail/*.log {
    daily
    rotate 14
    maxsize 50M
    compress
    delaycompress
    missingok
    notifempty
    create 0640 jenkins jenkins
}
```

**需在安装脚本中处理：**
1. 创建日志目录：`sudo mkdir -p /var/lib/jenkins/audit-trail/`
2. 设置目录权限：`sudo chown jenkins:jenkins /var/lib/jenkins/audit-trail/`
3. 复制 logrotate 配置：`sudo cp config/logrotate/jenkins-audit-trail /etc/logrotate.d/`

---

### `config/logrotate/sudo-logs` (配置文件, logrotate)

**Analog:** 同上，无直接现有文件。

```bash
# config/logrotate/sudo-logs
/var/log/sudo-logs/sudo.log {
    daily
    rotate 14
    maxsize 50M
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
}
```

**需在 install-sudo-log.sh 中处理：**
1. 创建日志目录：`sudo mkdir -p /var/log/sudo-logs/`
2. 设置目录权限：`sudo chmod 700 /var/log/sudo-logs/ && sudo chown root:root /var/log/sudo-logs/`
3. 复制 logrotate 配置：`sudo cp config/logrotate/sudo-logs /etc/logrotate.d/`

---

### `/etc/audit/rules.d/noda-docker.rules` (auditd 规则文件, 由脚本创建)

**Analog:** 无直接 analog（项目中首个 auditd 规则文件）。

**内容来自 RESEARCH.md Pattern 1**，写入方式参考 `install-sudoers-whitelist.sh` 的 heredoc 写入模式：

```bash
# 在 install-auditd-rules.sh 的 cmd_install() 中：
tee /etc/audit/rules.d/noda-docker.rules > /dev/null <<'EOF'
## Noda Docker Command Audit Rules (Phase 33, AUDIT-01)
## 监控所有 docker 命令执行，记录 auid/时间/命令参数

# 删除已有 docker-cmd 规则（幂等）
-D -k docker-cmd

# 监控 docker 命令执行（普通用户 auid >= 1000）
-a always,exit -F arch=b64 -S execve -F exe=/usr/bin/docker -F auid>=1000 -F auid!=-1 -k docker-cmd

# 监控 jenkins 系统用户的 docker 命令（auid 可能为 unset）
-a always,exit -F arch=b64 -S execve -F exe=/usr/bin/docker -F uid=jenkins -k docker-cmd
EOF
```

---

## Shared Patterns

### 日志函数库
**Source:** `scripts/lib/log.sh`
**Apply to:** 所有脚本文件
```bash
source "$PROJECT_ROOT/scripts/lib/log.sh"

# 可用函数：
log_info "信息"
log_success "成功"
log_error "错误"  # 输出到 stderr
log_warn "警告"
```

### 脚本头部模板
**Source:** `scripts/install-sudoers-whitelist.sh` (项目标准)
**Apply to:** 所有新脚本
```bash
#!/bin/bash
set -euo pipefail

# ============================================
# Phase XX: 功能描述
# ============================================
# 功能：...
# 子命令：install, verify, uninstall, help
# 要求：需要 root 权限执行
# 兼容：macOS + Linux 双平台
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"

# 平台检测
detect_platform() {
    local os
    os="$(uname)"
    if [[ "$os" == "Darwin" ]]; then
        echo "macos"
    else
        echo "linux"
    fi
}

PLATFORM="$(detect_platform)"
```

### install/verify/uninstall 三件套子命令分发
**Source:** `scripts/install-sudoers-whitelist.sh` lines 281-298
**Apply to:** `install-auditd-rules.sh`, `install-sudo-log.sh`
```bash
case "${1:-}" in
    install)   cmd_install ;;
    verify)    cmd_verify ;;
    uninstall) cmd_uninstall ;;
    help|--help|-h) usage ;;
    *)         usage && exit 1 ;;
esac
```

### 文件写入 + 语法验证 + 权限设置
**Source:** `scripts/install-sudoers-whitelist.sh` lines 67-141
**Apply to:** 所有写入系统配置文件的场景
```bash
# 写入文件（使用 heredoc）
tee "$TARGET_FILE" > /dev/null <<'EOF'
...配置内容...
EOF

# 验证语法（根据文件类型选择验证工具）
if ! visudo -cf "$TARGET_FILE"; then   # sudoers 文件
    log_error "语法验证失败"
    rm -f "$TARGET_FILE"
    exit 1
fi

# 设置文件权限
chmod 0440 "$TARGET_FILE"
chown root:root "$TARGET_FILE"
```

### 日志目录创建 + 权限
**Source:** `scripts/break-glass.sh` lines 99-107
**Apply to:** 所有需要创建日志目录的场景
```bash
sudo mkdir -p "$LOG_DIR"
sudo chmod 640 "$LOG_FILE"    # 或 0600（root only）
sudo chown root:root "$LOG_DIR"  # 或 root:jenkins
```

### Jenkins init.groovy.d 插件安装
**Source:** `scripts/jenkins/init.groovy.d/02-plugins.groovy` lines 1-48
**Apply to:** `05-audit-trail.groovy`
```groovy
import jenkins.model.*
import hudson.PluginWrapper

def instance = Jenkins.getInstance()
def pm = instance.getPluginManager()
def uc = instance.getUpdateCenter()

uc.updateAllSites()

def pluginId = 'audit-trail'
if (!pm.getPlugin(pluginId)) {
    println "Installing plugin: ${pluginId}"
    def plugin = uc.getPlugin(pluginId)
    if (plugin) {
        plugin.deploy(true)
    } else {
        println "WARNING: Plugin ${pluginId} not found in Update Center"
    }
} else {
    println "Plugin already installed: ${pluginId}"
}
instance.save()
```

### 平台兼容性处理
**Source:** 所有脚本统一的模式
**Apply to:** 所有新脚本
```bash
# macOS: 跳过或使用替代方案
# Linux: 执行完整操作
if [[ "$PLATFORM" == "macos" ]]; then
    log_warn "macOS 环境跳过..."
    return 0
fi
```

## No Analog Found

| 文件 | Role | Data Flow | 原因 | 建议 |
|------|------|-----------|------|------|
| `/etc/audit/rules.d/noda-docker.rules` | 配置 (auditd 规则) | 内核审计 | 项目中首个 auditd 规则文件 | 使用 RESEARCH.md Pattern 1 内容 + heredoc 写入模式 |
| `config/logrotate/jenkins-audit-trail` | 配置 (logrotate) | 文件 I/O 轮转 | 项目中无现有 logrotate 配置文件 | 使用 RESEARCH.md Pattern 5 内容 |
| `config/logrotate/sudo-logs` | 配置 (logrotate) | 文件 I/O 轮转 | 同上 | 使用 RESEARCH.md Pattern 5 内容 |

## Metadata

**Analog search scope:** `scripts/`, `scripts/jenkins/init.groovy.d/`, `config/`
**Files scanned:** 17 (scripts) + 4 (groovy) + 15 (config)
**Pattern extraction date:** 2026-04-18
