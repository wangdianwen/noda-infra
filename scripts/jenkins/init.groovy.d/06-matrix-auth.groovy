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

def realm = instance.getSecurityRealm()

// 确保使用 HudsonPrivateSecurityRealm（用户名/密码认证）
if (!(realm instanceof HudsonPrivateSecurityRealm)) {
    println "WARNING: Security realm is not HudsonPrivateSecurityRealm, skipping user creation"
} else {
    def devUser = realm.getUser('developer')
    if (devUser == null) {
        realm.createAccount('developer', 'changeme-immediately')
        println "Created developer user with default password. ADMIN: please change the password via Jenkins UI."
    } else {
        println "Developer user already exists, skipping creation"
    }
}

// ---------- 3. 配置权限矩阵 ----------

// 创建新的权限矩阵策略（每次执行重新创建，保证幂等性）
def strategy = new GlobalMatrixAuthorizationStrategy()

// Admin 角色：Overall/Administer（包含所有权限）
strategy.add(Jenkins.ADMINISTER, "admin")

// Developer 角色：最小权限集
// Overall/Read — 必须授予，否则其他权限无效
strategy.add(Jenkins.READ, "developer")
// Job/Read — 查看构建历史
strategy.add(hudson.model.Item.READ, "developer")
// Job/Build — 触发 Pipeline
strategy.add(hudson.model.Item.BUILD, "developer")
// Job/Discover — 发现 Job（重定向到登录页而非 404）
strategy.add(hudson.model.Item.DISCOVER, "developer")
// Run/Read — 查看 Console Output
strategy.add(hudson.model.Run.READ, "developer")
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
