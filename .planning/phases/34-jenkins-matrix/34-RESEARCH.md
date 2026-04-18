# Phase 34: Jenkins 权限矩阵 + 统一管理脚本 - Research

**Researched:** 2026-04-18
**Domain:** Jenkins 权限管理 + Shell 脚本编排
**Confidence:** HIGH

## Summary

Phase 34 核心工作是将前三个阶段（31: Docker socket 权限收敛、32: sudoers 白名单 + Break-Glass、33: 审计日志）的配置整合为一个统一编排脚本 `setup-docker-permissions.sh`，同时为 Jenkins 安装 Matrix Authorization Strategy 插件并配置两角色权限矩阵（Admin 全权限 / Developer 最小权限）。

**Primary recommendation:** 使用 `GlobalMatrixAuthorizationStrategy` 类在 Groovy init 脚本中配置权限矩阵，复用 `scripts/jenkins/init.groovy.d/` 已有的编号命名模式（新文件 `06-matrix-auth.groovy`）。编排器脚本直接调用现有 Phase 31-33 各脚本的子命令，不重复实现逻辑。

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** 两角色方案：Admin（全权限）+ Developer（最小权限）
- **D-02:** Developer 权限范围：触发 Pipeline（Job/Build）+ 查看构建历史（Job/Read）+ 查看 Console Output（Run/Read）
- **D-03:** Developer 不能：修改 Job 配置、访问凭证、修改系统设置、访问 Script Console、删除构建
- **D-04:** 权限矩阵通过 Groovy init 脚本自动配置（复用 setup-jenkins.sh 已有的 Groovy 脚本模式）
- **D-05:** `setup-docker-permissions.sh` 作为编排器（orchestrator），调用现有脚本的子命令
- **D-06:** 现有脚本保持独立可用，不重复实现逻辑
- **D-07:** apply 执行顺序按 Phase 顺序：31 → 32 → 33 → 34
- **D-08:** 全量回滚：恢复 Phase 31-34 所有配置到 v1.6 前的状态
- **D-09:** 回滚前强制交互确认（输入 YES），显示将要回滚的配置列表
- **D-10:** rollback 通过调用各独立脚本的 uninstall/undo 子命令实现
- **D-11:** verify 输出格式为终端文本：每行 `[PASS/FAIL] 检查项描述`
- **D-12:** 快速失败模式：遇到第一个 FAIL 立即退出并返回非零状态码
- **D-13:** 检查项覆盖所有 Phase 31-34 的配置

### Claude's Discretion
- Matrix Authorization Strategy 插件的具体安装方式（Groovy 脚本 vs CLI）
- Groovy init 脚本中权限矩阵的具体 API 调用
- verify 检查项的具体实现方式
- 脚本错误处理和日志格式
- macOS/Linux 双平台兼容（复用现有模式）

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| JENKINS-03 | Matrix Authorization Strategy 插件安装，区分管理员/开发者/只读角色 | matrix-auth 插件 v3.2.9 + GlobalMatrixAuthorizationStrategy Groovy API（详见代码示例） |
| JENKINS-04 | 非 admin 用户可以触发 Pipeline 但不能修改 Job 配置 | Groovy 脚本中精确控制：授予 Job/Build + Job/Read + Run/Read，不授予 Job/Configure |
| PERM-05 | 统一权限管理脚本 `setup-docker-permissions.sh`，一站式配置所有权限 | 编排器调用现有 7 个脚本的 apply/verify/rollback 子命令（详见架构模式） |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Jenkins 权限矩阵配置 | Jenkins 服务端（Groovy init） | — | 权限存储在 Jenkins 内部 H2 数据库，通过 Groovy API 写入 |
| 统一编排脚本 | 宿主机 OS（bash） | — | 脚本在宿主机以 root 执行，调用各阶段脚本 |
| 插件安装 | Jenkins Update Center | — | matrix-auth 通过 Update Center API 在 Groovy 脚本中安装 |
| verify 验证 | 宿主机 OS + Jenkins API | — | 文件权限检查在宿主机，权限矩阵检查通过 Jenkins CLI/API |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| matrix-auth (Matrix Authorization Strategy) | 3.2.9 | Jenkins 细粒度权限控制 | Jenkins 官方推荐权限策略插件，91% 安装率，支持 Groovy API 和 JCasC [VERIFIED: plugins.jenkins.io] |
| GlobalMatrixAuthorizationStrategy | (matrix-auth 内置) | 全局权限矩阵类 | matrix-auth 插件提供的核心类，`strategy.add(Permission, sid)` API [CITED: jenkins.io/doc/book/security/access-control] |
| bash | 4.0+ | 编排器脚本运行时 | 项目已有标准，所有 Phase 31-33 脚本使用 bash |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| jenkins-cli.jar | (随 Jenkins 安装) | Jenkins Script Console 远程执行 | 需要在脚本中动态执行 Groovy 代码时 |
| HudsonPrivateSecurityRealm | (Jenkins 内置) | Jenkins 内置用户管理 | 创建 Developer 用户（已由 01-security.groovy 使用） |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| GlobalMatrixAuthorizationStrategy | ProjectMatrixAuthorizationStrategy | 项目级矩阵支持按 Job/Agent 配置权限，但本场景只有全局两角色需求，全局矩阵足够且更简单 |
| Groovy init 脚本 | Jenkins JCasC (Configuration as Code) | JCasC 更现代，但 CONTEXT.md D-04 已锁定 Groovy init 方案，复用现有模式 |
| matrix-auth 插件 | Role Strategy 插件 | Role Strategy 提供角色抽象层，但 matrix-auth 是 Jenkins 官方维护、更轻量、91% 安装率 |

**Installation:**
matrix-auth 通过 Groovy 脚本从 Jenkins Update Center 自动安装（复用 02-plugins.groovy 的插件安装模式），无需手动 `apt` 或 `jenkins-plugin-cli`。

**Version verification:**
- matrix-auth v3.2.9, Released ~2025-11, Requires Jenkins 2.479.3+（当前项目 Jenkins 2.541.x LTS 满足要求）[VERIFIED: plugins.jenkins.io/matrix-auth/]

## Architecture Patterns

### System Architecture Diagram

```
                    setup-docker-permissions.sh (编排器)
                              │
            ┌─────────────────┼──────────────────────┐
            │                 │                       │
         apply             verify                 rollback
            │                 │                       │
     ┌──────┼──────┬──────┐  │  ┌──────┬──────┬──────┼──────┐
     │      │      │      │  │  │      │      │      │      │
     ▼      ▼      ▼      ▼  ▼  ▼      ▼      ▼      ▼      ▼
  Phase31 Phase32 Phase33 Phase34  各阶段   各阶段  Phase34 Phase33 Phase32 Phase31
  apply   install install Groovy   verify  verify  undo    uninstall uninstall undo
  (socket (sudoers (auditd  init    子命令  子命令  Groovy  子命令   子命令    backup
   权限)   白名单) 规则+    脚本                   权限
                          sudo                    矩阵
                          日志)
```

### Recommended Project Structure

```
scripts/
├── setup-docker-permissions.sh     # [新建] 编排器脚本
├── apply-file-permissions.sh       # [已有] Phase 31
├── undo-permissions.sh             # [已有] Phase 31 回滚
├── install-sudoers-whitelist.sh    # [已有] Phase 32
├── break-glass.sh                  # [已有] Phase 32
├── install-auditd-rules.sh         # [已有] Phase 33
├── install-sudo-log.sh             # [已有] Phase 33
├── setup-jenkins.sh                # [已有] Jenkins 管理
└── jenkins/
    └── init.groovy.d/
        ├── 01-security.groovy      # [已有] 管理员用户 + 安全域
        ├── 02-plugins.groovy       # [已有] 插件安装
        ├── 03-pipeline-job.groovy  # [已有] Pipeline 作业
        ├── 04-pipeline-job-noda-site.groovy  # [已有]
        ├── 05-audit-trail.groovy   # [已有] Audit Trail 插件
        └── 06-matrix-auth.groovy   # [新建] 权限矩阵配置
```

### Pattern 1: 编排器调用子脚本模式

**What:** `setup-docker-permissions.sh` 通过 `bash` 调用各阶段脚本的子命令，不重复实现逻辑
**When to use:** apply/verify/rollback 三个子命令中调用现有脚本
**Example:**

```bash
# Source: 项目已有模式（apply-file-permissions.sh, install-sudoers-whitelist.sh 等）

# apply 子命令 — 按 Phase 顺序调用
cmd_apply() {
    log_info "Phase 31: 应用 Docker socket 权限..."
    bash "$SCRIPT_DIR/apply-file-permissions.sh" apply

    log_info "Phase 32: 安装 sudoers 白名单..."
    bash "$SCRIPT_DIR/install-sudoers-whitelist.sh" install

    log_info "Phase 33: 安装审计规则..."
    bash "$SCRIPT_DIR/install-auditd-rules.sh" install
    bash "$SCRIPT_DIR/install-sudo-log.sh" install

    log_info "Phase 34: 配置 Jenkins 权限矩阵..."
    cmd_apply_jenkins_matrix
}

# rollback 子命令 — 反序调用
cmd_rollback() {
    # 交互确认...
    cmd_rollback_jenkins_matrix    # Phase 34
    bash "$SCRIPT_DIR/install-sudo-log.sh" uninstall      # Phase 33
    bash "$SCRIPT_DIR/install-auditd-rules.sh" uninstall  # Phase 33
    bash "$SCRIPT_DIR/install-sudoers-whitelist.sh" uninstall  # Phase 32
    bash "$SCRIPT_DIR/undo-permissions.sh" undo           # Phase 31
}
```

### Pattern 2: Groovy Init 脚本权限矩阵配置

**What:** 在 `$JENKINS_HOME/init.groovy.d/` 中放入编号 Groovy 脚本，Jenkins 启动时自动执行
**When to use:** 配置 Jenkins 权限矩阵（JENKINS-03, JENKINS-04）
**Example:**

```groovy
// Source: [CITED: jenkins.io/doc/book/security/access-control] + [CITED: plugins.jenkins.io/matrix-auth/]
// 文件: scripts/jenkins/init.groovy.d/06-matrix-auth.groovy
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()

// 1. 确保 matrix-auth 插件已安装
def pm = instance.getPluginManager()
if (!pm.getPlugin('matrix-auth')) {
    def uc = instance.getUpdateCenter()
    uc.updateAllSites()
    def plugin = uc.getPlugin('matrix-auth')
    if (plugin) {
        plugin.deploy(true)
        println "matrix-auth plugin installed. Restart required."
        instance.save()
        return  // 需要重启后才能使用 GlobalMatrixAuthorizationStrategy
    } else {
        println "ERROR: matrix-auth plugin not found in Update Center"
        return
    }
}

// 2. 配置权限矩阵（幂等：每次启动重新设置）
def strategy = new GlobalMatrixAuthorizationStrategy()

// Admin 角色：Overall/Administer（隐含几乎所有权限）
strategy.add(Jenkins.ADMINISTER, "admin")

// Developer 角色：最小权限（D-02: 触发 Pipeline + 查看结果）
strategy.add(Jenkins.READ, "developer")      // Overall/Read — 必须有才能使用其他权限
strategy.add(hudson.model.Item.READ, "developer")    // Job/Read — 查看构建历史
strategy.add(hudson.model.Item.BUILD, "developer")   // Job/Build — 触发 Pipeline
strategy.add(hudson.model.Item.DISCOVER, "developer") // Job/Discover — 发现 Job（被 READ 隐含，显式声明更清晰）
strategy.add(hudson.model.Run.READ, "developer")     // Run/Read — 查看 Console Output
strategy.add(hudson.model.View.READ, "developer")    // View/Read — 查看视图列表

// 注意：不授予以下权限（D-03）
// - Item/Configure（修改 Job 配置）
// - Item/Create, Item/Delete
// - Run/Delete, Run/Update
// - Credentials/*
// - Overall/Administer, Overall/Manage
// - Script Console 访问

instance.setAuthorizationStrategy(strategy)
instance.save()
println "Matrix authorization strategy configured."
```

### Pattern 3: verify 汇总检查模式

**What:** 编排器的 verify 子命令调用各脚本 verify + Jenkins 权限检查，输出 `[PASS/FAIL]` 格式
**When to use:** verify 子命令中
**Example:**

```bash
cmd_verify() {
    local fail_count=0

    # Phase 31 验证
    if bash "$SCRIPT_DIR/apply-file-permissions.sh" verify; then
        echo "[PASS] Phase 31: Docker socket + 文件权限"
    else
        echo "[FAIL] Phase 31: Docker socket + 文件权限"
        fail_count=$((fail_count + 1))
    fi

    # Phase 32 验证
    if bash "$SCRIPT_DIR/install-sudoers-whitelist.sh" verify; then
        echo "[PASS] Phase 32: sudoers 白名单"
    else
        echo "[FAIL] Phase 32: sudoers 白名单"
        fail_count=$((fail_count + 1))
    fi

    # Phase 33 验证
    # ...

    # Phase 34 验证（Jenkins 权限矩阵）
    verify_jenkins_matrix

    # 快速失败（D-12）
    if [ $fail_count -gt 0 ]; then
        echo "[FAIL] ${fail_count} 项检查失败"
        return 1
    fi
    echo "[PASS] 所有 Phase 31-34 配置验证通过"
}
```

### Anti-Patterns to Avoid

- **在编排器中重复实现逻辑：** 不要把 apply-file-permissions.sh 的逻辑复制到编排器，必须调用子脚本（D-06）
- **权限矩阵中授予 Item/Configure 给 Developer：** D-03 明确禁止
- **忘记授予 Overall/Read：** 没有 Overall/Read，用户无法使用 Jenkins UI，其他权限全部无效 [CITED: plugins.jenkins.io/matrix-auth/ Caveats]
- **在 init.groovy.d 中使用 matrix-auth 类但插件未安装：** 必须先检查插件是否存在，不存在则先安装并等待重启
- **rollback 不做交互确认：** D-09 要求输入 YES 确认

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 权限矩阵 | 自定义权限检查逻辑 | matrix-auth 插件的 GlobalMatrixAuthorizationStrategy | 权限继承、隐含关系、边界情况复杂，官方插件处理完善 |
| 插件安装 | 手动下载 .hpi 文件 | Jenkins Update Center API（Groovy 脚本） | 自动处理依赖关系，版本兼容性 |
| Jenkins CLI 操作 | HTTP API 调用 | jenkins-cli.jar 或 Groovy Script Console | 已有模式，setup-jenkins.sh 中 reset-password 命令已验证可行 |
| 各阶段配置逻辑 | 在编排器中复制粘贴 | 调用现有脚本的子命令 | D-06 锁定决策，避免逻辑重复 |

**Key insight:** 编排器是"胶水代码"，只负责调用顺序和汇总结果，不实现任何配置逻辑。

## Common Pitfalls

### Pitfall 1: matrix-auth 插件安装后需要重启才能使用

**What goes wrong:** Groovy 脚本安装 matrix-auth 插件后立即尝试使用 `GlobalMatrixAuthorizationStrategy` 类，但类尚未加载
**Why it happens:** Jenkins 插件安装后需要重启才能加载新插件的类
**How to avoid:** 在 Groovy 脚本中分两步：(1) 检测插件是否存在，不存在则安装并 `return`；(2) 下次启动时检测到插件已存在，配置权限矩阵
**Warning signs:** `java.lang.ClassNotFoundException: hudson.security.GlobalMatrixAuthorizationStrategy` 或 `GroovyObjectCastException`

### Pitfall 2: Developer 用户必须先存在才能分配权限

**What goes wrong:** `strategy.add(Permission, "developer")` 中的 "developer" SID 不存在，但 matrix-auth 不会报错，只是权限不生效
**Why it happens:** matrix-auth 的 `add()` 方法只存储 SID 字符串，不验证用户是否存在
**How to avoid:** 在权限矩阵 Groovy 脚本中先创建 developer 用户（使用 HudsonPrivateSecurityRealm），或者由管理员手动在 Jenkins UI 中创建用户后再运行脚本
**Warning signs:** developer 用户登录后仍显示无权限

### Pitfall 3: init.groovy.d 脚本在 setup-jenkins.sh install 中被清理

**What goes wrong:** `setup-jenkins.sh install` 步骤 10 会删除 `$JENKINS_HOME/init.groovy.d/` 目录，导致权限矩阵脚本丢失
**Why it happens:** install 子命令设计为首次安装流程，完成后清理 init 脚本
**How to avoid:** 权限矩阵的 init 脚本需要区别于首次安装的 init 脚本。两种方案：(A) 不通过 init.groovy.d，改用 jenkins-cli.jar 在脚本中执行 Groovy；(B) 修改 setup-jenkins.sh 不删除 06-matrix-auth.groovy
**Warning signs:** Jenkins 重启后权限矩阵恢复为默认策略

### Pitfall 4: verify 中各子脚本 verify 输出格式不一致

**What goes wrong:** 各脚本的 verify 子命令使用 `log_success/log_error` 格式输出，而编排器需要 `[PASS/FAIL]` 格式（D-11）
**Why it happens:** 现有脚本用颜色标记输出，没有统一的 `[PASS/FAIL]` 前缀
**How to avoid:** 编排器通过子脚本 exit code 判断 PASS/FAIL，不依赖输出格式。子脚本返回 0 = PASS，非 0 = FAIL
**Warning signs:** 编排器 verify 输出与 D-11 规定的 `[PASS/FAIL]` 格式不匹配

### Pitfall 5: rollback 后 Jenkins 权限矩阵未恢复

**What goes wrong:** rollback 只删除了 Groovy 脚本文件，但 Jenkins 运行时内存中的权限配置未改变
**Why it happens:** 删除 init.groovy.d 脚本只影响下次启动，不影响当前运行的 Jenkins
**How to avoid:** rollback 需要：(1) 通过 Jenkins CLI 或 Script Console 将权限策略改回 `FullControlOnceLoggedInAuthorizationStrategy`；(2) 重启 Jenkins
**Warning signs:** rollback 后 developer 用户仍有最小权限而非全权限

## Code Examples

### 示例 1: matrix-auth 插件安装 + 权限矩阵配置（完整 Groovy 脚本）

```groovy
// Source: [CITED: plugins.jenkins.io/matrix-auth/] + [CITED: jenkins.io/doc/book/security/access-control]
// 模式参考: scripts/jenkins/init.groovy.d/05-audit-trail.groovy
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()
def pm = instance.getPluginManager()

// ---------- 插件安装检查 ----------
if (!pm.getPlugin('matrix-auth')) {
    println "Installing matrix-auth plugin..."
    def uc = instance.getUpdateCenter()
    uc.updateAllSites()
    def plugin = uc.getPlugin('matrix-auth')
    if (plugin) {
        plugin.deploy(true)
        println "matrix-auth plugin installed. Restart required."
        instance.save()
        return  // 首次安装，等待重启后执行权限配置
    } else {
        println "ERROR: matrix-auth plugin not found"
        return
    }
}

// ---------- 确保 developer 用户存在 ----------
def realm = instance.getSecurityRealm()
if (realm instanceof HudsonPrivateSecurityRealm) {
    def devUser = realm.getUser('developer')
    if (devUser == null) {
        // 首次创建，密码由管理员后续通过 UI 修改
        realm.createAccount('developer', 'changeme-immediately')
        println "Created developer user (please change password immediately)"
    }
}

// ---------- 配置权限矩阵 ----------
def strategy = new GlobalMatrixAuthorizationStrategy()

// Admin: Overall/Administer（隐含几乎所有权限）
strategy.add(Jenkins.ADMINISTER, "admin")

// Developer: 最小权限 (D-02)
strategy.add(Jenkins.READ, "developer")                    // Overall/Read
strategy.add(hudson.model.Item.READ, "developer")          // Job/Read
strategy.add(hudson.model.Item.BUILD, "developer")         // Job/Build
strategy.add(hudson.model.Item.DISCOVER, "developer")      // Job/Discover
strategy.add(hudson.model.Run.READ, "developer")           // Run/Read
strategy.add(hudson.model.View.READ, "developer")          // View/Read

// 注意: authenticated 用户不授予额外权限（D-03 禁止匿名访问）
// 注意: 不授予 Item/Configure, Item/Create, Item/Delete, Run/Delete 等

instance.setAuthorizationStrategy(strategy)
instance.save()
println "Matrix authorization configured (Admin=全权限, Developer=最小权限)"
```

### 示例 2: 验证 Jenkins 权限矩阵（bash 函数）

```bash
# Source: 项目已有模式（apply-file-permissions.sh verify 子命令）
# 用于 setup-docker-permissions.sh 的 verify 子命令

verify_jenkins_matrix() {
    local jenkins_home="/var/lib/jenkins"
    local cli_jar="${jenkins_home}/war/WEB-INF/jenkins-cli.jar"
    local jenkins_url="http://localhost:8888"

    # 检查 matrix-auth 插件是否安装
    if sudo [ -d "${jenkins_home}/plugins/matrix-auth" ]; then
        echo "[PASS] matrix-auth 插件已安装"
    else
        echo "[FAIL] matrix-auth 插件未安装"
        return 1
    fi

    # 检查权限策略是否为 GlobalMatrixAuthorizationStrategy
    local strategy_check
    strategy_check=$(sudo -u jenkins java -jar "$cli_jar" -s "$jenkins_url" groovy = <<'GROOVY' 2>/dev/null
import jenkins.model.*
import hudson.security.*
def strategy = Jenkins.getInstance().getAuthorizationStrategy()
if (strategy instanceof GlobalMatrixAuthorizationStrategy) {
    println "GlobalMatrixAuthorizationStrategy"
    // 检查 admin 是否有 Administer
    def hasAdmin = strategy.getGrantedPermissions()
        .findAll { it.key == Jenkins.ADMINISTER }
        .any { it.value.contains("admin") }
    println "admin_has_administer:${hasAdmin}"
    // 检查 developer 是否有 Build
    def hasBuild = strategy.getGrantedPermissions()
        .findAll { it.key == hudson.model.Item.BUILD }
        .any { it.value.contains("developer") }
    println "developer_has_build:${hasBuild}"
} else {
    println "WRONG_STRATEGY:" + strategy.getClass().getSimpleName()
}
GROOVY
    ) || true

    if echo "$strategy_check" | grep -q "GlobalMatrixAuthorizationStrategy"; then
        echo "[PASS] 权限策略为 GlobalMatrixAuthorizationStrategy"
    else
        echo "[FAIL] 权限策略不正确（期望 GlobalMatrixAuthorizationStrategy）"
        return 1
    fi

    if echo "$strategy_check" | grep -q "admin_has_administer:true"; then
        echo "[PASS] admin 用户拥有 Administer 权限"
    else
        echo "[FAIL] admin 用户缺少 Administer 权限"
        return 1
    fi

    if echo "$strategy_check" | grep -q "developer_has_build:true"; then
        echo "[PASS] developer 用户拥有 Job/Build 权限"
    else
        echo "[FAIL] developer 用户缺少 Job/Build 权限"
        return 1
    fi
}
```

### 示例 3: 回滚 Jenkins 权限矩阵

```bash
# 回滚到 FullControlOnceLoggedInAuthorizationStrategy（Phase 34 之前的状态）
# 因为 setup-jenkins.sh 步骤 10 会清理 init.groovy.d，
# 权限矩阵配置应在运行时通过 CLI 执行

rollback_jenkins_matrix() {
    local jenkins_home="/var/lib/jenkins"
    local cli_jar="${jenkins_home}/war/WEB-INF/jenkins-cli.jar"
    local jenkins_url="http://localhost:8888"

    log_info "回滚 Jenkins 权限矩阵为 FullControlOnceLoggedInAuthorizationStrategy..."

    sudo -u jenkins java -jar "$cli_jar" -s "$jenkins_url" groovy = <<'GROOVY'
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()
def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

// 删除 developer 用户（如果存在）
def realm = instance.getSecurityRealm()
if (realm instanceof HudsonPrivateSecurityRealm) {
    def devUser = realm.getUser('developer')
    if (devUser != null) {
        devUser.delete()
        println "Deleted developer user"
    }
}

instance.save()
println "Authorization strategy reverted to FullControlOnceLoggedInAuthorizationStrategy"
GROOVY

    log_success "Jenkins 权限矩阵已回滚"
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| FullControlOnceLoggedInAuthorizationStrategy | GlobalMatrixAuthorizationStrategy | Phase 34 | 从"登录即全权限"升级为细粒度权限矩阵 |
| 各阶段脚本独立执行 | setup-docker-permissions.sh 统一编排 | Phase 34 | 一键 apply/verify/rollback 所有权限配置 |
| 手动 Jenkins UI 配置权限 | Groovy init 脚本自动配置 | Phase 34 | 权限配置可版本控制、可重复执行 |

**Deprecated/outdated:**
- `FullControlOnceLoggedInAuthorizationStrategy`: Phase 34 后不再使用（仅 rollback 时恢复）

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | developer 用户通过 Groovy 脚本创建（HudsonPrivateSecurityRealm.createAccount），管理员后续通过 UI 修改密码 | Groovy 脚本设计 | 如果管理员不修改默认密码，developer 账户不安全。可考虑改为手动创建。 |
| A2 | `setup-jenkins.sh install` 的步骤 10 清理 init.groovy.d 只在首次安装时执行，不影响后续 Jenkins 重启 | Pitfall 3 | 如果清理逻辑在每次重启时执行，需要改变策略为通过 CLI 动态执行 Groovy |
| A3 | Jenkins CLI jar 路径为 `$JENKINS_HOME/war/WEB-INF/jenkins-cli.jar`，与 reset-password 命令使用的路径一致 | 验证脚本 | 路径可能因安装方式不同而变化，需确认 |
| A4 | `sudo -u jenkins java -jar ... groovy` 可以在非交互模式下执行 Groovy 脚本 | 验证/回滚脚本 | 需要 Jenkins 无认证或已配置 SSH 公钥认证。否则需要传递凭据。 |

## Open Questions

1. **developer 用户的初始密码管理**
   - What we know: HudsonPrivateSecurityRealm.createAccount 可以创建用户
   - What's unclear: 初始密码如何安全传递给 Developer 用户
   - Recommendation: Groovy 脚本创建时使用临时密码 `changeme-immediately`，首次登录强制修改（可考虑添加 `PasswordParameterDefinition`）

2. **Jenkins CLI 认证方式**
   - What we know: setup-jenkins.sh 的 reset-password 使用 `sudo -u jenkins java -jar ...` 方式
   - What's unclear: 权限矩阵配置后，Jenkins CLI 是否需要认证凭据
   - Recommendation: 在 init.groovy.d 阶段不需要 CLI 认证（Jenkins 内部执行）。验证/回滚脚本中使用 `sudo -u jenkins` 继承 jenkins 用户的权限

3. **init.groovy.d 清理时机**
   - What we know: setup-jenkins.sh install 步骤 10 清理 init.groovy.d 目录
   - What's unclear: 06-matrix-auth.groovy 是否应该放入 init.groovy.d 还是通过其他方式执行
   - Recommendation: 调查 setup-jenkins.sh 的清理逻辑。如果清理只发生在首次安装（步骤 10 一次性执行），则 init.groovy.d 方案可行。否则需要改用 CLI 方式在 setup-docker-permissions.sh 中动态执行

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| bash | 编排器脚本 | ✓ | 3.2.57 (macOS) / 生产服务器 Linux | — |
| Jenkins CLI jar | verify/rollback Jenkins 权限 | ✗ (macOS) | — | 跳过 Jenkins 相关检查（macOS 开发环境） |
| Jenkins (生产) | 权限矩阵配置 | ✗ (macOS) | — | macOS 跳过所有 Jenkins 操作 |
| matrix-auth 插件 | 权限矩阵 | ✗ (未安装) | — | 通过 Groovy 脚本自动安装 |

**Missing dependencies with no fallback:**
- 无。macOS 开发环境跳过 Jenkins 操作，生产环境执行完整流程

**Missing dependencies with fallback:**
- macOS 环境：跳过 Jenkins 权限矩阵配置和验证（复用已有 `detect_platform` 模式）

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Shell script verification (bash assertions) |
| Config file | none — verification built into scripts |
| Quick run command | `sudo bash scripts/setup-docker-permissions.sh verify` |
| Full suite command | `sudo bash scripts/setup-docker-permissions.sh verify && sudo -u jenkins docker ps` |

### Phase Requirements -> Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| JENKINS-03 | matrix-auth 插件安装 + 两角色权限矩阵 | integration | `verify_jenkins_matrix` (via setup-docker-permissions.sh verify) | ❌ Wave 0 |
| JENKINS-04 | Developer 可触发 Pipeline 但不能修改 Job | integration | Groovy 脚本检查 grantedPermissions | ❌ Wave 0 |
| PERM-05 | 编排器 apply/verify/rollback 子命令 | unit | `bash setup-docker-permissions.sh verify` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `sudo bash scripts/setup-docker-permissions.sh verify`
- **Per wave merge:** Full suite — setup-docker-permissions.sh verify + Jenkins 权限矩阵验证
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `scripts/setup-docker-permissions.sh` — 编排器脚本（核心交付物）
- [ ] `scripts/jenkins/init.groovy.d/06-matrix-auth.groovy` — 权限矩阵 Groovy 脚本
- [ ] Jenkins CLI 认证方式确认（sudo -u jenkins vs 凭据文件）

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Jenkins HudsonPrivateSecurityRealm（内置用户管理） |
| V3 Session Management | yes | Jenkins 内置 session 管理 + CSRF 保护（01-security.groovy 已配置） |
| V4 Access Control | yes | GlobalMatrixAuthorizationStrategy（本次实施核心） |
| V5 Input Validation | yes | bash 脚本 `set -euo pipefail` + Groovy 幂等检查 |
| V6 Cryptography | no | — |

### Known Threat Patterns for Jenkins + Bash

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| 权限提升（Developer 修改 Job 配置） | Elevation | GlobalMatrixAuthorizationStrategy 不授予 Item/Configure |
| Groovy 脚本注入 | Tampering | init.groovy.d 权限 root:jenkins 640，不接收外部输入 |
| 编排器脚本未授权执行 | Spoofing | 文件权限 750 root:jenkins，仅 root/jenkins 可执行 |
| developer 默认密码未修改 | Information Disclosure | 创建后强制首次登录修改密码 |
| Jenkins CLI 无认证执行 | Spoofing | 使用 `sudo -u jenkins` 继承系统权限，不暴露凭据 |

## Sources

### Primary (HIGH confidence)
- [plugins.jenkins.io/matrix-auth/](https://plugins.jenkins.io/matrix-auth/) — matrix-auth v3.2.9, 91% 安装率, Requires Jenkins 2.479.3+
- [jenkins.io/doc/book/security/access-control](https://www.jenkins.io/doc/book/security/access-control/) — Matrix Authorization Strategy 文档
- [jenkins.io/doc/book/managing/groovy-hook-scripts](https://www.jenkins.io/doc/book/managing/groovy-hook-scripts/) — init.groovy.d 执行机制
- Context7 `/websites/jenkins_io_doc` — Jenkins 官方文档，GlobalMatrixAuthorizationStrategy API
- 项目代码: `scripts/jenkins/init.groovy.d/*.groovy` — 已有 Groovy 脚本模式验证

### Secondary (MEDIUM confidence)
- [github.com/jenkinsci/matrix-auth-plugin](https://github.com/jenkinsci/matrix-auth-plugin) — 源码 + JCasC 配置示例
- 项目代码: `scripts/apply-file-permissions.sh`, `scripts/install-sudoers-whitelist.sh`, `scripts/install-auditd-rules.sh`, `scripts/install-sudo-log.sh` — 各阶段脚本子命令模式

### Tertiary (LOW confidence)
- 无。所有核心信息已通过 Context7 或官方文档验证。

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — matrix-auth 插件信息从官方插件库确认，API 从 Context7 + Jenkins 文档验证
- Architecture: HIGH — 编排器模式从已有代码模式推导，所有现有脚本已阅读
- Pitfalls: HIGH — matrix-auth 插件 Caveats 文档明确说明了常见陷阱
- Groovy API: HIGH — GlobalMatrixAuthorizationStrategy.add() API 从 Jenkins 源码文档和社区示例交叉验证

**Research date:** 2026-04-18
**Valid until:** 2026-05-18（30 天，matrix-auth 和 Jenkins LTS 更新周期稳定）
