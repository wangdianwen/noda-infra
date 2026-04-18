# Phase 33: 审计日志系统 - Research

**Researched:** 2026-04-18
**Domain:** Linux auditd + Jenkins Audit Trail + sudoers 日志 + logrotate
**Confidence:** HIGH

## Summary

Phase 33 建立三层审计日志体系：(1) auditd 内核级审计监控所有 docker 命令执行（含用户身份、时间戳、命令参数），(2) Jenkins Audit Trail 插件记录 Pipeline 触发事件，(3) sudoers Defaults logfile 记录所有 sudo 操作。三层日志分别通过 auditd 自有轮转机制和 logrotate 管理磁盘占用，总预算 500MB。

**Primary recommendation:** 使用 syscall 规则（`-a always,exit -F arch=b64 -S execve -F exe=/usr/bin/docker`）而非 deprecated 的 `-w` watch 模式监控 docker 命令。Jenkins Audit Trail 插件通过 Groovy 脚本自动化安装和配置。sudo 日志通过在 `/etc/sudoers.d/` 添加 Defaults 行实现。所有配置脚本复用 Phase 32 建立的 install/verify/uninstall 三件套模式。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** auditd 日志保留 30 天，Jenkins Audit Trail / sudo 日志保留 14 天
- 单文件最大 50MB，总审计日志磁盘预算 500MB
- auditd 使用自带 logrotate 机制（/etc/logrotate.d/auditd 或 auditd.conf max_log_file）
- Jenkins Audit Trail 通过 logrotate 管理轮转
- sudo 日志通过 logrotate 管理轮转

### Locked Decisions (continued)
- **D-02:** 仅记录 Pipeline 触发事件（谁触发了哪个 Job、时间、参数）
- 满足 AUDIT-03 要求的最小粒度
- 管理员配置变更等操作通过 auditd + sudo 日志追踪（不重复记录）
- 日志输出到 JENKINS_HOME/audit-trail/ 目录

### Locked Decisions (continued)
- **D-03:** 各组件使用系统默认路径，分散存放
  - auditd → `/var/log/audit/`（系统默认）
  - sudo → `/var/log/sudo-logs/`（sudoers Defaults logfile 配置）
  - Break-Glass → `/var/log/noda/break-glass.log`（Phase 32 已建立）
  - Jenkins Audit Trail → `$JENKINS_HOME/audit-trail/`

### Claude's Discretion
- auditd 规则具体写法（watch /usr/bin/docker vs syscall 监控）
- Jenkins Audit Trail 插件的具体配置方式
- logrotate 配置文件的具体参数
- 安装/验证脚本的具体名称和存放位置

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AUDIT-01 | auditd 规则监控所有 docker 命令执行，记录 auid（登录用户）、时间、命令参数 | auditd syscall 规则 + `-k docker-cmd` key 标记，ausearch 可查询 |
| AUDIT-02 | auditd 日志独立存储，普通用户不可篡改 | auditd.conf 配置 log_file + log_group + max_log_file_action，文件权限 root:root 0600 |
| AUDIT-03 | Jenkins Audit Trail 插件安装，记录谁在什么时候触发了什么 Pipeline | audit-trail 插件 436.vc0d1e79fc5a_3 + File Logger + Groovy 自动化配置 |
| AUDIT-04 | sudo 操作日志记录（通过 sudoers Defaults logfile 配置） | `/etc/sudoers.d/noda-audit` 添加 `Defaults logfile=/var/log/sudo-logs/sudo.log` |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| auditd 规则配置 | OS / 内核层 | — | 内核审计子系统，规则通过 auditctl 写入内核 |
| auditd 日志存储 | OS 文件系统 | — | /var/log/audit/ 是系统级路径，由 auditd 进程写入 |
| Jenkins Audit Trail | 应用层 (Jenkins) | OS 文件系统 | Jenkins 插件记录应用事件，日志存储在 $JENKINS_HOME |
| sudo 日志 | OS / PAM 层 | — | sudoers 配置由 sudo 二进制读取，日志写入文件系统 |
| logrotate | OS 系统服务 | — | 系统级日志轮转，管理所有审计日志的磁盘占用 |

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| auditd (audit daemon) | 系统包管理器版本 | 内核审计守护进程 | Linux 标准审计框架，Debian/Ubuntu 默认可用 [VERIFIED: man7.org auditctl(8) 手册页] |
| auditctl | 随 auditd 安装 | 审计规则管理工具 | 配置内核审计规则的唯一标准工具 [VERIFIED: man7.org auditctl(8) 手册页] |
| augenrules | 随 auditd 安装 | 从 /etc/audit/rules.d/ 加载规则 | Debian/Ubuntu 推荐的规则管理方式 [ASSUMED] |
| Jenkins Audit Trail 插件 | 436.vc0d1e79fc5a_3 | Jenkins 操作审计 | 官方维护，支持 File Logger，记录 Pipeline 触发事件 [VERIFIED: plugins.jenkins.io/audit-trail] |
| logrotate | 3.22.0 (最新) | 日志轮转 | Linux 标准日志轮转工具 [VERIFIED: github.com/logrotate/logrotate] |

### Supporting
| Library/Tool | Purpose | When to Use |
|---------|---------|-------------|
| ausearch | 查询审计日志 | 验证 auditd 规则是否工作，按 key/用户/时间搜索 |
| aureport | 生成审计报告 | 生成汇总报告（可选） |
| visudo | sudoers 语法验证 | 验证 sudoers 文件语法正确性 |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| auditd syscall 规则 | `-w /usr/bin/docker -p x` watch 模式 | watch 模式已 deprecated，性能较差；syscall 规则是推荐方式 [VERIFIED: auditctl(8) 手册页 PERFORMANCE TIPS] |
| Jenkins Audit Trail 插件 | 自定义 Groovy listener | 插件是标准方案，维护成本低；自定义方案需要深入 Jenkins 内部 API |
| logrotate | auditd 自带 max_log_file | D-01 决定混合使用：auditd 用自带机制，Jenkins/sudo 用 logrotate |

**Installation:**
```bash
# auditd 安装（Debian/Ubuntu）
sudo apt install -y auditd audispd-plugins

# Jenkins Audit Trail 插件通过 Groovy 脚本安装（见代码示例）
```

## Architecture Patterns

### System Architecture Diagram

```
                         审计日志数据流
                         ============

  用户执行 docker 命令          Jenkins 用户触发 Pipeline      管理员执行 sudo 命令
         │                            │                            │
         ▼                            ▼                            ▼
  ┌─────────────┐            ┌──────────────────┐        ┌──────────────┐
  │  内核审计    │            │ Jenkins Audit     │        │  sudo 二进制  │
  │  子系统      │            │ Trail 插件        │        │  (PAM)       │
  └──────┬──────┘            └────────┬─────────┘        └──────┬───────┘
         │                            │                            │
         ▼                            ▼                            ▼
  ┌─────────────┐            ┌──────────────────┐        ┌──────────────┐
  │ /var/log/   │            │ $JENKINS_HOME/   │        │ /var/log/    │
  │ audit/      │            │ audit-trail/     │        │ sudo-logs/   │
  │ audit.log   │            │ audit-trail.log  │        │ sudo.log     │
  └──────┬──────┘            └────────┬─────────┘        └──────┬───────┘
         │                            │                            │
         ▼                            ▼                            ▼
  ┌─────────────┐            ┌──────────────────┐        ┌──────────────┐
  │ auditd 自带  │            │ logrotate        │        │ logrotate    │
  │ 日志轮转     │            │ (14天, 50MB)     │        │ (14天, 50MB) │
  │ (30天, 50MB) │            └──────────────────┘        └──────────────┘
  └─────────────┘
  
  查询入口:
    ausearch -k docker-cmd    查看 Jenkins UI       sudo cat /var/log/sudo-logs/sudo.log
    -i（解释用户/时间）         或 tail audit-trail.log
```

### Recommended Project Structure
```
scripts/
├── install-auditd-rules.sh     # auditd 规则安装/验证/卸载（AUDIT-01, AUDIT-02）
├── install-sudoers-whitelist.sh # Phase 32 已有，需追加 Defaults logfile（AUDIT-04）
├── setup-jenkins.sh            # 已有，需添加 Audit Trail 插件安装步骤（AUDIT-03）
└── jenkins/
    └── init.groovy.d/
        └── 05-audit-trail.groovy  # Audit Trail 插件配置（自动安装 + 配置）

config/
├── logrotate/
│   ├── jenkins-audit-trail     # Jenkins Audit Trail 日志轮转配置
│   └── sudo-logs               # sudo 日志轮转配置

# 生产服务器上的配置文件（由脚本创建，不在 git 中）
/etc/audit/rules.d/noda-docker.rules     # auditd 规则文件
/etc/sudoers.d/noda-audit                # sudo 日志 Defaults 配置
/var/log/sudo-logs/                      # sudo 日志目录
$JENKINS_HOME/audit-trail/               # Jenkins Audit Trail 日志目录
/etc/logrotate.d/jenkins-audit-trail     # logrotate 配置
/etc/logrotate.d/sudo-logs               # logrotate 配置
```

### Pattern 1: auditd Syscall 规则（推荐方式）
**What:** 使用 syscall 规则而非 deprecated watch 模式监控 docker 命令
**When to use:** 监控特定可执行文件的执行（docker、docker-compose 等）
**Example:**
```bash
# Source: man7.org/man-pages/man8/auditctl.8.html (VERIFIED)
# /etc/audit/rules.d/noda-docker.rules

# 删除已有 docker 相关规则（幂等）
-D -k docker-cmd

# 监控 docker 命令执行（syscall 方式，推荐）
# x86_64 架构使用 arch=b64，execve syscall
-a always,exit -F arch=b64 -S execve -F exe=/usr/bin/docker -F auid>=1000 -F auid!=-1 -k docker-cmd

# 监控 docker compose（如果通过独立二进制调用）
-a always,exit -F arch=b64 -S execve -F exe=/usr/bin/docker-compose -F auid>=1000 -F auid!=-1 -k docker-cmd
```

关键参数说明（来自 auditctl(8) 手册页 [VERIFIED]）：
- `-a always,exit` — 在 syscall 退出时记录审计事件
- `-F arch=b64` — 64 位架构（x86_64）
- `-S execve` — 监控 execve 系统调用（程序执行）
- `-F exe=/usr/bin/docker` — 仅匹配 docker 二进制
- `-F auid>=1000` — 仅记录普通用户（UID >= 1000）
- `-F auid!=-1` — 排除未设置 auid 的进程（如 daemon）
- `-k docker-cmd` — key 标记，用于 `ausearch -k docker-cmd` 查询

### Pattern 2: auditd 日志保护配置
**What:** 配置 auditd.conf 确保日志 root 只读
**When to use:** AUDIT-02 要求
**Example:**
```bash
# /etc/audit/auditd.conf 关键配置项 [ASSUMED — 基于训练知识]
# 需要在生产服务器上验证当前配置

log_file = /var/log/audit/audit.log
log_group = root              # 日志文件属组为 root
log_format = ENRICHED         # 包含用户名等可读信息
max_log_file = 50             # 单文件最大 50MB (D-01)
max_log_file_action = ROTATE  # 达到上限时轮转
num_logs = 30                 # 保留 30 个轮转文件（约 30 天，D-01）
```

### Pattern 3: Jenkins Audit Trail 插件自动化
**What:** 通过 Groovy 脚本安装和配置 Audit Trail 插件
**When to use:** setup-jenkins.sh install 子命令的步骤之一
**Example:**
```groovy
// scripts/jenkins/init.groovy.d/05-audit-trail.groovy
// 功能：安装 Audit Trail 插件并配置为 File Logger
// 参考：plugins.jenkins.io/audit-trail/ [VERIFIED]

import jenkins.model.*
import hudson.PluginWrapper

def instance = Jenkins.getInstance()
def pm = instance.getPluginManager()
def uc = instance.getUpdateCenter()

uc.updateAllSites()

def pluginId = 'audit-trail'
if (!pm.getPlugin(pluginId)) {
    println "Installing Audit Trail plugin..."
    def plugin = uc.getPlugin(pluginId)
    if (plugin) {
        plugin.deploy(true)
        println "Audit Trail plugin installed. Jenkins will restart."
    } else {
        println "WARNING: audit-trail plugin not found in Update Center"
    }
} else {
    println "Audit Trail plugin already installed"
}

// 注意：File Logger 的详细配置（日志路径、轮转大小等）
// 需要在 Jenkins 启动后通过 Jenkins Web UI 配置
// 或通过 Jenkins CASC (Configuration as Code) 配置
// 由于本项目的 CLAUDE.md 决定不用 JCasC，建议 UI 配置 + 文档记录
```

### Pattern 4: sudoers Defaults logfile
**What:** 在 /etc/sudoers.d/ 添加独立文件配置 sudo 日志
**When to use:** AUDIT-04 要求
**Example:**
```bash
# /etc/sudoers.d/noda-audit
# Phase 33: sudo 操作日志记录 (AUDIT-04)

Defaults logfile=/var/log/sudo-logs/sudo.log
```

### Pattern 5: logrotate 配置
**What:** 为 Jenkins Audit Trail 和 sudo 日志配置 logrotate
**When to use:** D-01 决策的日志轮转要求
**Example:**
```bash
# /etc/logrotate.d/jenkins-audit-trail
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

# /etc/logrotate.d/sudo-logs
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

### Anti-Patterns to Avoid
- **使用 `-w` watch 模式：** auditctl 手册明确标记为 deprecated，性能较差 [VERIFIED: auditctl(8) "DISABLED BY DEFAULT" 和 "PERFORMANCE TIPS" 部分]
- **忘记 `-F auid!=-1`：** 不排除未设置 auid 的 daemon 进程会导致大量噪音日志
- **忘记 `-F arch=b64`：** 不指定架构会导致规则应用于所有架构，可能在 bi-arch 系统上产生意外行为
- **auditd 与 audit 规则目录混淆：** Debian/Ubuntu 使用 `/etc/audit/rules.d/` + `augenrules`，不是直接修改 `/etc/audit/audit.rules`
- **在 Jenkins Groovy 脚本中配置 Audit Trail File Logger：** Audit Trail 插件的 File Logger 配置涉及 `java.util.logging.FileHandler` 模式，在 init.groovy.d 中配置复杂且不可靠。推荐安装插件后通过 UI 或 Groovy Console 手动配置。

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Docker 命令审计 | 自定义 bash wrapper 或 strace | auditd 内核审计 | 内核级可靠，不可绕过，记录 auid [VERIFIED: auditctl(8)] |
| Jenkins 操作日志 | 自定义 Jenkins Listener | audit-trail 插件 | 官方维护，4.09% 安装率，功能完善 [VERIFIED: plugins.jenkins.io] |
| 日志轮转 | 自定义 cron + find -mtime 脚本 | logrotate / auditd max_log_file | 标准工具，处理边界情况完善 |
| sudo 日志 | 自定义 wrapper 记录 sudo 调用 | sudoers Defaults logfile | sudo 原生功能，零代码修改 |

**Key insight:** 审计日志系统的核心价值在于**不可绕过性**。auditd 是内核级审计，用户无法通过 shell alias、PATH 修改等方式绕过。自定义 bash wrapper 只能监控 shell 级别的调用，无法覆盖直接 exec 的场景。

## Common Pitfalls

### Pitfall 1: Debian 默认 no-audit 规则
**What goes wrong:** Debian/Ubuntu 默认安装 `-a never,task` 规则，导致所有审计规则不生效
**Why it happens:** 为了减少性能开销，很多发行版默认禁用审计
**How to avoid:** 安装后检查 `auditctl -l` 输出，如果看到 `never,task` 规则，需要删除 `/etc/audit/rules.d/10-no-audit.rules` 并替换为 `10-base-config.rules` [VERIFIED: auditctl(8) "DISABLED BY DEFAULT" 部分]
**Warning signs:** `ausearch -k docker-cmd` 返回空结果，`auditctl -l` 显示 `never,task` 规则

### Pitfall 2: auditd 服务未启动
**What goes wrong:** auditd 包已安装但服务未启动，规则无法生效
**Why it happens:** 某些云镜像不自动启动 auditd
**How to avoid:** 安装脚本中包含 `systemctl enable auditd && systemctl start auditd`
**Warning signs:** `auditctl -s` 显示 pid=0

### Pitfall 3: Jenkins Audit Trail 插件安装后需重启
**What goes wrong:** 插件安装成功但配置未生效
**Why it happens:** Jenkins 插件安装后需要完全重启才能加载新插件
**How to avoid:** 安装脚本末尾触发 Jenkins 重启（已有 wait_for_jenkins 函数）
**Warning signs:** Manage Jenkins 页面无 Audit Trail 配置项

### Pitfall 4: sudoers Defaults 冲突
**What goes wrong:** 新添加的 Defaults logfile 与现有 sudoers 配置冲突
**Why it happens:** 多个文件设置相同的 Defaults 可能产生意外行为
**How to avoid:** 使用独立文件 `/etc/sudoers.d/noda-audit`，并用 `visudo -cf` 验证
**Warning signs:** sudo 命令失败或日志未写入指定文件

### Pitfall 5: /var/log/sudo-logs/ 目录不存在
**What goes wrong:** sudo 日志写入失败因为目标目录不存在
**Why it happens:** sudo 不会自动创建日志目录
**How to avoid:** 安装脚本中先 `mkdir -p /var/log/sudo-logs` 再配置 sudoers
**Warning signs:** `sudo: unable to open /var/log/sudo-logs/sudo.log` 错误

### Pitfall 6: auditd 规则中 auid 对 jenkins 系统用户无效
**What goes wrong:** jenkins 系统用户的 auid 可能是 -1（unset），导致其 docker 命令不被记录
**Why it happens:** 系统用户不通过 PAM 登录，auid 未设置
**How to avoid:** 规则中使用 `-F auid!=-1` 排除 unset auid 的同时，额外添加一条不限 auid 的规则专门监控 jenkins 用户，或者使用 `-F uid=jenkins` 替代 auid 过滤
**Warning signs:** `ausearch -k docker-cmd` 中无 jenkins 用户的 docker 执行记录

## Code Examples

### 安装脚本：install-auditd-rules.sh（三件套模式）
```bash
#!/bin/bash
# 复用 Phase 32 install-sudoers-whitelist.sh 的三件套模式
# Source: 项目 scripts/install-sudoers-whitelist.sh [VERIFIED]

# 子命令 install:
cmd_install() {
    # 1. 安装 auditd 包（如果未安装）
    if ! dpkg -l auditd >/dev/null 2>&1; then
        apt install -y auditd audispd-plugins
    fi
    
    # 2. 检查并移除 no-audit 默认规则
    if [ -f /etc/audit/rules.d/10-no-audit.rules ]; then
        rm -f /etc/audit/rules.d/10-no-audit.rules
    fi
    
    # 3. 写入自定义规则文件
    cat > /etc/audit/rules.d/noda-docker.rules <<'EOF'
## Noda Docker Command Audit Rules (Phase 33, AUDIT-01)
## 监控所有 docker 命令执行，记录 auid/时间/命令参数

# 删除已有 docker-cmd 规则（幂等）
-D -k docker-cmd

# 监控 docker 命令执行（jenkins 用户通过 auid 或 uid 触发）
-a always,exit -F arch=b64 -S execve -F exe=/usr/bin/docker -F auid>=1000 -F auid!=-1 -k docker-cmd

# 监控 jenkins 系统用户的 docker 命令（auid 可能为 unset）
-a always,exit -F arch=b64 -S execve -F exe=/usr/bin/docker -F uid=jenkins -k docker-cmd
EOF

    # 4. 设置文件权限
    chmod 0640 /etc/audit/rules.d/noda-docker.rules
    chown root:root /etc/audit/rules.d/noda-docker.rules
    
    # 5. 加载规则
    augenrules --load
    
    # 6. 启动/重启 auditd
    systemctl enable auditd
    systemctl restart auditd
}
```

### 验证脚本：ausearch 验证命令
```bash
# Source: man7.org/man-pages/man8/ausearch.8.html [VERIFIED]

# 验证 auditd 规则生效（期望返回 docker 命令记录）
ausearch -k docker-cmd -i

# 仅查看最近的 docker 命令
ausearch -k docker-cmd --start recent -i

# 查看特定用户的 docker 命令
ausearch -k docker-cmd -ul jenkins -i

# 查看今天的所有 docker 命令
ausearch -k docker-cmd --start today -i

# 输出为更可读的文本格式
ausearch -k docker-cmd --start today --format text
```

### sudoers Defaults 配置
```bash
# /etc/sudoers.d/noda-audit (AUDIT-04)
# 需要 visudo -cf 验证语法

# 设置 sudo 日志输出到独立文件
Defaults logfile=/var/log/sudo-logs/sudo.log

# 注意：这会覆盖全局 Defaults 的 syslog 设置
# 如果需要同时记录到 syslog，可以添加：
# Defaults !syslog  （不推荐，保留 syslog 作为备份）
```

### auditd.conf 关键配置修改
```bash
# 修改 /etc/audit/auditd.conf 的关键参数（AUDIT-02 + D-01）
# 需要在安装脚本中用 sed 或完整替换

# 日志文件权限：root 只读
log_group = root

# 单文件最大 50MB (D-01)
max_log_file = 50

# 达到上限时轮转
max_log_file_action = ROTATE

# 保留文件数（约 30 天，D-01）
num_logs = 30

# 日志格式：ENRICHED 包含用户名解析
log_format = ENRICHED
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `-w` watch 模式 | syscall 规则 + `-F path/exe` | audit 3.x+ | watch 模式标记为 deprecated，性能差 |
| 直接编辑 /etc/audit/audit.rules | 使用 /etc/audit/rules.d/ + augenrules | Debian/Ubuntu 标准做法 | 支持分文件管理，augenrules 合并加载 |
| Jenkins Script Console 手动配置 | Groovy init 脚本 + 插件自动安装 | Jenkins 2.x+ | 可版本控制，可自动化 |

**Deprecated/outdated:**
- `auditctl -w` watch 模式：deprecated due to poor system performance [VERIFIED: auditctl(8)]
- 直接修改 `/etc/audit/audit.rules`：应使用 `/etc/audit/rules.d/` 目录管理

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Debian/Ubuntu 使用 augenrules + /etc/audit/rules.d/ 管理规则 | Architecture Patterns | 如果系统使用旧的 /etc/audit/audit.rules，脚本需要适配 |
| A2 | auditd.conf 的 max_log_file/num_logs 配置可实现 30 天保留 | Pattern 2 | 如果日志量异常大，30 个文件可能不足 30 天 |
| A3 | jenkins 系统用户的 uid 可通过名称解析（`-F uid=jenkins`） | Code Examples | 如果 jenkins 用户名不同，规则不生效 |
| A4 | Audit Trail File Logger 可通过 Jenkins init.groovy.d 配置 | Pattern 3 | 如果 API 不稳定，可能需要改为 UI 手动配置 |
| A5 | 生产服务器运行 Debian/Ubuntu（x86_64 架构） | 全部 | 如果是 ARM 架构需将 arch=b64 改为对应值 |
| A6 | logrotate 配置中 daily + rotate 14 约等于 14 天保留 | Pattern 5 | 如果日志量大导致 size 触发提前轮转，保留天数可能少于 14 天 |

## Open Questions

1. **auditd 当前状态未知**
   - What we know: CLAUDE.md 提到 "生产服务器实际状态未确认"
   - What's unclear: auditd 是否已安装、是否有 no-audit 默认规则、auditd.conf 当前配置
   - Recommendation: 安装脚本第一步应检测 auditd 状态，输出诊断信息

2. **Jenkins Audit Trail File Logger 的自动化配置**
   - What we know: 插件可通过 Groovy 安装 [VERIFIED: plugins.jenkins.io]
   - What's unclear: File Logger 配置参数是否可通过 Groovy API 稳定设置
   - Recommendation: 插件安装用 Groovy 自动化，File Logger 配置先用手动 UI 方式 + 文档记录，后续可考虑 JCasC

3. **Jenkins 用户的 auid 值**
   - What we know: Jenkins 以 systemd 服务运行，auid 可能未设置（-1）
   - What's unclear: Jenkins Pipeline 中 `sh 'docker ...'` 的进程 auid 是什么
   - Recommendation: 规则同时包含 `-F auid>=1000` 和 `-F uid=jenkins` 两条，确保覆盖

## Environment Availability

> 此 Phase 依赖外部工具和服务，需要在生产服务器上部署。

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| auditd/auditctl | AUDIT-01, AUDIT-02 | 待确认（生产服务器） | 系统包管理器版本 | 无替代方案 |
| Jenkins LTS | AUDIT-03 | 已安装（Phase 19） | 2.541.3 | — |
| logrotate | D-01 日志轮转 | 待确认（通常预装） | 3.22.0 或系统版本 | 无替代方案 |
| sudo | AUDIT-04 | 已安装 | 系统版本 | — |
| visudo | AUDIT-04 验证 | 已安装（随 sudo） | 系统版本 | — |

**Missing dependencies with no fallback:**
- auditd — 需要在生产服务器上 `apt install auditd`，无替代方案

**Missing dependencies with fallback:**
- 无

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Bash 脚本验证（手动 + verify 子命令） |
| Config file | 无独立测试配置，验证逻辑嵌入各脚本 verify 子命令 |
| Quick run command | `sudo bash scripts/install-auditd-rules.sh verify` |
| Full suite command | 依次运行所有 verify 子命令 |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| AUDIT-01 | `ausearch -k docker-cmd -i` 返回 docker 命令记录含用户/时间/参数 | smoke | `ausearch -k docker-cmd --start today -i | head -20` | Wave 0 |
| AUDIT-02 | auditd 日志文件权限 root:root 0600 | unit | `stat -c '%a:%U:%G' /var/log/audit/audit.log` | Wave 0 |
| AUDIT-03 | Jenkins Audit Trail 记录 Pipeline 触发事件 | smoke | `sudo tail -5 $JENKINS_HOME/audit-trail/audit-trail.log` | Wave 0 |
| AUDIT-04 | sudo 操作记录到 /var/log/sudo-logs/sudo.log | smoke | `sudo cat /var/log/sudo-logs/sudo.log | tail -5` | Wave 0 |

### Sampling Rate
- **Per task commit:** `sudo bash scripts/install-auditd-rules.sh verify`
- **Per wave merge:** 所有 4 个 AUDIT 需求验证
- **Phase gate:** 全部 4 个 Success Criteria 通过

### Wave 0 Gaps
- [ ] `scripts/install-auditd-rules.sh` — AUDIT-01 + AUDIT-02 安装/验证脚本
- [ ] `scripts/jenkins/init.groovy.d/05-audit-trail.groovy` — AUDIT-03 插件安装
- [ ] `config/logrotate/jenkins-audit-trail` — Jenkins 日志轮转配置
- [ ] `config/logrotate/sudo-logs` — sudo 日志轮转配置
- [ ] `/etc/sudoers.d/noda-audit` — AUDIT-04 sudoers 配置（由脚本创建）

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | auditd 记录 auid 追溯到原始登录用户 |
| V4 Access Control | yes | sudo 日志记录特权操作 |
| V5 Input Validation | no | — |
| V7 Error Handling | yes | auditd failure mode 配置 |
| V9 Logging | yes | 核心需求 — 三层审计日志体系 |

### Known Threat Patterns for Audit Logging

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 日志篡改 | Tampering | auditd 日志 root:root 0600 权限 |
| 日志磁盘占满 | Denial of Service | logrotate + max_log_file 轮转机制 |
| 审计绕过 | Elevation of Privilege | auditd 内核级审计不可用户态绕过 |
| 审计规则删除 | Tampering | `-e 2` 锁定审计配置（可选，本 Phase 不实施） |

## Sources

### Primary (HIGH confidence)
- man7.org/man-pages/man8/auditctl.8.html — auditctl 完整语法、字段说明、示例、性能提示
- man7.org/man-pages/man8/ausearch.8.html — ausearch 查询语法、选项、示例
- plugins.jenkins.io/audit-trail/ — Audit Trail 插件功能说明、配置选项、版本信息
- 项目代码: scripts/install-sudoers-whitelist.sh — 三件套安装模式参考
- 项目代码: scripts/setup-jenkins.sh — Jenkins 安装步骤模式参考
- 项目代码: scripts/jenkins/init.groovy.d/02-plugins.groovy — 插件安装 Groovy 模式参考

### Secondary (MEDIUM confidence)
- github.com/logrotate/logrotate — logrotate 版本和配置参考
- 项目代码: scripts/break-glass.sh — log_audit() 函数和审计日志写入模式

### Tertiary (LOW confidence)
- auditd.conf 配置参数细节（max_log_file、num_logs 等）— 基于训练知识，未在此次研究中成功获取手册页（重定向问题）

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — auditctl/ausearch 手册页已验证，Jenkins Audit Trail 插件文档已验证
- Architecture: HIGH — 三层审计架构清晰，每层有独立的存储和轮转策略
- Pitfalls: HIGH — auditctl 手册页明确标注了 deprecated watch 模式和 no-audit 默认规则问题
- auditd.conf 配置: MEDIUM — 具体参数值基于训练知识，未成功获取最新手册页

**Research date:** 2026-04-18
**Valid until:** 2026-05-18（auditd 是稳定的内核子系统，变化缓慢）
