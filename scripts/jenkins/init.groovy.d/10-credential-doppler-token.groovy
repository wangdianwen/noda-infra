// Jenkins 凭据配置 - Doppler Service Token
// 功能：创建 doppler-token Secret text 凭据，用于 Pipeline 加载生产密钥
//
// 前提：DOPPLER_TOKEN 环境变量已设置（从 jenkins-admin.env 或系统环境变量）
// 幂等性：凭据已存在则跳过
import jenkins.model.*
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.common.*
import com.cloudbees.plugins.credentials.domains.*
import com.cloudbees.plugins.credentials.impl.*

def instance = Jenkins.getInstance()
def domain = Domain.global()
def store = instance.getExtensionList('com.cloudbees.plugins.credentials.SystemCredentialsProvider')[0].getStore()

def credentialsId = 'doppler-token'

// 检查凭据是否已存在
def existingCreds = CredentialsProvider.lookupCredentials(
    StandardCredentials.class,
    instance,
    null,
    null
).find { it.id == credentialsId }

if (existingCreds != null) {
    println "Credential '${credentialsId}' already exists, skipping."
    return
}

// 从环境变量读取 Doppler token
def dopplerToken = System.getenv('DOPPLER_TOKEN')

if (dopplerToken == null || dopplerToken.isEmpty()) {
    // 尝试从 .admin.env 文件读取
    def jenkinsHome = System.getenv('JENKINS_HOME') ?: '/var/lib/jenkins'
    def envFile = new File(jenkinsHome, '.admin.env')
    if (envFile.exists()) {
        def props = new Properties()
        envFile.withInputStream { stream -> props.load(stream) }
        dopplerToken = props.getProperty('DOPPLER_TOKEN')
    }
}

if (dopplerToken == null || dopplerToken.isEmpty()) {
    println "WARNING: DOPPLER_TOKEN not found. Create credential manually in Jenkins UI."
    println "  Manage Jenkins > Credentials > System > Global credentials > Add Credentials"
    println "  Kind: Secret text, ID: doppler-token"
    return
}

def credentials = new StringCredentialsImpl(
    CredentialsScope.GLOBAL,
    credentialsId,
    'Doppler Service Token (project=noda, config=prd)',
    Secret.fromString(dopplerToken)
)

store.addCredentials(domain, credentials)
println "Credential '${credentialsId}' created successfully."
instance.save()
