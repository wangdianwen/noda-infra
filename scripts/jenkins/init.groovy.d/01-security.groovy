// Jenkins 首次启动安全配置
// 功能：创建管理员用户、启用 CSRF 保护、匿名只读、跳过 Setup Wizard
//
// 执行时机：init.groovy.d 脚本按字母顺序在每次 Jenkins 启动时执行
// 幂等性：所有操作包含存在性检查，重复执行安全
// 清理：setup-jenkins.sh install 子命令在首次配置完成后删除 init.groovy.d 目录
//       （2026-10-05 实证：线上 ~/.jenkins/init.groovy.d 已被清空，安全配置为
//       FullControlOnceLoggedIn + allowAnonymousRead=true——本脚本 2026-10-05
//       起对齐该实证行为，未来重建不再与线上漂移；trigger-and-approve.sh 的
//       「匿名只读」假设依赖此行为）
//
// 凭据来源（优先级从高到低）：
//   1. $JENKINS_HOME/.admin.env 文件
//   2. JENKINS_ADMIN_USER / JENKINS_ADMIN_PASSWORD 环境变量
import jenkins.model.*
import hudson.security.*

// ---------- 读取管理员凭据 ----------

def jenkinsHome = System.getProperty('JENKINS_HOME') ?: System.getenv('JENKINS_HOME') ?: "${System.getProperty('user.home')}/.jenkins"
def adminUser = 'admin'
def adminPass = null

// 优先从 .admin.env 文件读取
def envFile = new File(jenkinsHome, '.admin.env')
if (envFile.exists()) {
    def props = new Properties()
    envFile.withInputStream { stream -> props.load(stream) }
    adminUser = props.getProperty('JENKINS_ADMIN_USER', 'admin')
    adminPass = props.getProperty('JENKINS_ADMIN_PASSWORD')
}

// 回退到环境变量
if (adminPass == null) {
    adminPass = System.getenv('JENKINS_ADMIN_PASSWORD')
}
if (adminUser == 'admin' && System.getenv('JENKINS_ADMIN_USER')) {
    adminUser = System.getenv('JENKINS_ADMIN_USER')
}

if (adminPass == null) {
    println 'WARNING: No admin password configured. Skipping security setup.'
    println 'Set JENKINS_ADMIN_PASSWORD env var or provide .admin.env file.'
    return
}

def instance = Jenkins.getInstance()

// ---------- 创建管理员用户（幂等：检查用户是否已存在） ----------

def hudsonRealm = new HudsonPrivateSecurityRealm(false)
// 需要先 setSecurityRealm 再 getUser，否则 getUser 返回 null
instance.setSecurityRealm(hudsonRealm)

def existingUser = hudsonRealm.getUser(adminUser)
if (existingUser == null) {
    hudsonRealm.createAccount(adminUser, adminPass)
    println "Created admin user: ${adminUser}"
} else {
    println "Admin user already exists: ${adminUser}, skipping creation"
}

// ---------- 授权策略：登录后完全控制，匿名只读（2026-10-05 对齐线上实证行为） ----------

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
// 线上实测 allowAnonymousRead=true（匿名可浏览 job 页与 console，不可写/不可触发）；
// 原 false 与线上行为矛盾，重建时会静默改变浏览器可见性
strategy.setAllowAnonymousRead(true)
instance.setAuthorizationStrategy(strategy)

// ---------- CSRF 保护 ----------

instance.setCrumbIssuer(new DefaultCrumbIssuer(true))

// ---------- 跳过 Setup Wizard ----------

def setupWizard = instance.getSetupWizard()
if (setupWizard != null) {
    setupWizard.completeSetup()
}

instance.save()
println 'Security configuration completed.'
