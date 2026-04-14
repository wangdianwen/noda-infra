// Jenkins 首次启动安全配置
// 功能：创建管理员用户、启用 CSRF 保护、禁用匿名读取、跳过 Setup Wizard
//
// 执行时机：init.groovy.d 脚本按字母顺序在每次 Jenkins 启动时执行
// 幂等性：所有操作包含存在性检查，重复执行安全
// 清理：setup-jenkins.sh install 子命令在首次配置完成后删除 init.groovy.d 目录
//
// 凭据来源（优先级从高到低）：
//   1. $JENKINS_HOME/.admin.env 文件
//   2. JENKINS_ADMIN_USER / JENKINS_ADMIN_PASSWORD 环境变量
import jenkins.model.*
import hudson.security.*

// ---------- 读取管理员凭据 ----------

def jenkinsHome = System.getenv('JENKINS_HOME') ?: '/var/lib/jenkins'
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

// ---------- 授权策略：登录后完全控制，禁用匿名读取 ----------

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
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
