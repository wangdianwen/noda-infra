// Jenkins 权限矩阵配置（Matrix Authorization Strategy）
// 功能：安装 matrix-auth 插件，配置两角色权限矩阵（Admin 全权限 + Developer 最小权限）
//
// 执行时机：按字母顺序在 Jenkins 启动时执行（06 在 05 之后）
// 幂等性：每次执行重新创建策略对象并设置，确保配置一致
// 权限矩阵：
//   Admin:     Overall/Administer（全权限）
//   Developer: Overall/Read + Job/Read + Job/Build + Job/Discover + Run/Read + View/Read（最小权限）
//   Developer 不能：修改 Job 配置、访问凭证、修改系统设置、访问 Script Console
//
// 注意：developer 用户初始密码为 changeme-immediately，管理员需通过 UI 修改
import jenkins.model.*
import hudson.PluginWrapper
import hudson.security.*
import jenkins.model.Jenkins

def instance = Jenkins.getInstance()
def pm = instance.getPluginManager()
def uc = instance.getUpdateCenter()

// ---------- 1. 安装 matrix-auth 插件（幂等：已安装则跳过） ----------

uc.updateAllSites()

def pluginId = 'matrix-auth'

if (!pm.getPlugin(pluginId)) {
    println "Installing plugin: ${pluginId}"
    def plugin = uc.getPlugin(pluginId)
    if (plugin) {
        plugin.deploy(true)
        println "${pluginId} plugin installed. Restart required."
        // 插件安装后需要重启 Jenkins 才能使用，本次不继续配置
        return
    } else {
        println "WARNING: Plugin ${pluginId} not found in Update Center"
        return
    }
} else {
    println "Plugin already installed: ${pluginId}"
}

// ---------- 2. 创建 developer 用户（如果不存在） ----------

// 密码来源（2026-10-05 修订）：$JENKINS_HOME/.developer.env 的
// JENKINS_DEVELOPER_PASSWORD，或同名环境变量。不再硬编码默认密码——
// 线上实证 developer:changeme-immediately 一直未改（HTTP 200 可登录），
// 已于 2026-10-05 手动重置；未来重建若未配置密码则跳过创建，宁缺毋滥。
def developerPass = null
def devEnvFile = new File(System.getProperty('JENKINS_HOME')
    ?: System.getenv('JENKINS_HOME')
    ?: "${System.getProperty('user.home')}/.jenkins", '.developer.env')
if (devEnvFile.exists()) {
    def props = new Properties()
    devEnvFile.withInputStream { stream -> props.load(stream) }
    developerPass = props.getProperty('JENKINS_DEVELOPER_PASSWORD')
}
if (developerPass == null) {
    developerPass = System.getenv('JENKINS_DEVELOPER_PASSWORD')
}

def realm = instance.getSecurityRealm()

// 确保使用 HudsonPrivateSecurityRealm（用户名/密码认证）
if (!(realm instanceof HudsonPrivateSecurityRealm)) {
    println "WARNING: Security realm is not HudsonPrivateSecurityRealm, skipping user creation"
} else if (developerPass == null) {
    println "WARNING: JENKINS_DEVELOPER_PASSWORD not configured, skipping developer creation"
} else {
    def devUser = realm.getUser('developer')
    if (devUser == null) {
        realm.createAccount('developer', developerPass)
        println "Created developer user (password from env file/env var)"
    } else {
        println "Developer user already exists, skipping creation"
    }
}

// ---------- 3. 配置权限矩阵 ----------

// 创建新的权限矩阵策略（每次执行重新创建，保证幂等性）
def strategy = new GlobalMatrixAuthorizationStrategy()

// Admin 角色：Overall/Administer（包含所有权限）
strategy.add(Jenkins.ADMINISTER, "admin")

// anonymous 只读（2026-10-05 对齐线上实证行为：匿名可浏览 job 页/console、
// 不可触发/不可改。原脚本未授予任何匿名权限，与线上 FullControlOnceLoggedIn
// allowAnonymousRead=true 矛盾——未来重建若按原脚本执行会静默改变浏览器可见性）
strategy.add(Jenkins.READ, "anonymous")
strategy.add(hudson.model.Item.READ, "anonymous")
strategy.add(hudson.model.Run.READ, "anonymous")
strategy.add(hudson.model.View.READ, "anonymous")

// Developer 角色：最小权限集
// Overall/Read — 必须授予，否则其他权限无效
strategy.add(Jenkins.READ, "developer")
// Job/Read — 查看构建历史
strategy.add(hudson.model.Item.READ, "developer")
// Job/Build — 触发 Pipeline
strategy.add(hudson.model.Item.BUILD, "developer")
// Job/Discover — 发现 Job（重定向到登录页而非 404）
strategy.add(hudson.model.Item.DISCOVER, "developer")
// View/Read — 查看视图列表
strategy.add(hudson.model.View.READ, "developer")

// 不授予以下权限给 developer（由 GlobalMatrixAuthorizationStrategy 默认不授予）：
// - Item/Configure（修改 Job 配置）
// - Item/Create, Item/Delete
// - Run/Delete, Run/Update
// - Credentials/*
// - Overall/Administer, Overall/Manage
// - Script Console（由 Overall/Administer 控制）

instance.setAuthorizationStrategy(strategy)
instance.save()

println "Matrix authorization configured."
println "  Admin:     Overall/Administer (full access)"
println "  Developer: Overall/Read + Job/Read + Job/Build + Job/Discover + Run/Read + View/Read"
