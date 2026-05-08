// ============================================
// Jenkins Job 初始化脚本（Phase 56-03）
// ============================================
// 功能：创建 Jenkins Jobs 和 Lockable Resources
// 用途：首次安装 Jenkins 后运行此脚本
// 执行方式：Jenkins UI -> Manage Jenkins -> Script Console
// ============================================

import jenkins.model.*
import hudson.model.*
import org.jenkinsci.plugins.lockableresources.LockableResourcesManager
import org.jenkinsci.plugins.lockableresources.LockableResource
import org.jenkinsci.plugins.workflow.job.*
import org.jenkinsci.plugins.workflow.cps.*
import hudson.plugins.git.*
import jenkins.branch.*
import org.jenkinsci.plugins.workflow.multibranch.*

println "=========================================="
println "Jenkins Job 初始化脚本"
println "=========================================="

// 1. 创建 Lockable Resources
def lm = Jenkins.instance.getExtensionList(LockableResourcesManager.class)[0]

// 检查并创建资源
def createResource(String name, String description) {
    def resource = lm.getResources().find { it.name == name }
    if (!resource) {
        resource = new LockableResource(name, description, '', '', '0', '', true)
        lm.addResource(resource)
        println "✓ 创建资源: $name"
    } else {
        println "✓ 资源已存在: $name"
    }
}

// 创建所需资源
createResource("preprod-deploy", "Pre-prod 部署锁")
createResource("prod-deploy", "Prod 部署锁")
createResource("nginx-reload", "Nginx 重载锁")

println "=========================================="

// 2. 创建 Jenkins Jobs
def createJob(String jobName, String jenkinsfilePath, String displayName, String description) {
    def job = Jenkins.instance.getItemByFullName(jobName)
    if (job) {
        println "✓ Job 已存在: $jobName"
        return
    }

    // 创建 Pipeline Job
    def project = new WorkflowJob(Jenkins.instance, jobName)
    project.displayName = displayName
    project.description = description

    // 设置定义（使用 noda-infra 仓库的 Jenkinsfile）
    def scm = new GitSCM("https://github.com/wangdianwen/noda-infra.git")
    scm.branches = [new BranchSpec("*/main")]
    def definition = new CpsScmFlowDefinition(scm, jenkinsfilePath)
    project.definition = definition

    // 禁用并发构建
    project.concurrentBuild = false

    Jenkins.instance.add(project)
    println "✓ 创建 Job: $jobName"
}

// 创建 Jobs
createJob(
    "noda-apps-preprod-deploy",
    "jenkins/Jenkinsfile.noda-apps-preprod",
    "Noda Apps Pre-prod Deploy",
    "Pre-prod 环境蓝绿部署 Pipeline（手动触发）"
)

createJob(
    "noda-apps-promote",
    "jenkins/Jenkinsfile.noda-apps-promote",
    "Noda Apps Promote to Prod",
    "Promote pre-prod 镜像到 prod 环境（手动触发）"
)

println "=========================================="

// 3. 设置凭据提示
def setupCredentials() {
    println ""
    println "请手动添加以下凭据（Jenkins UI -> Manage Jenkins -> Credentials）："
    println ""
    println "Pre-prod 环境："
    println "  - ID: doppler-service-token-preprod"
    println "    类型: Secret text"
    println "    描述: Doppler Service Token (Pre-prod)"
    println "  - ID: cf-api-token-preprod"
    println "    类型: Secret text"
    println "    描述: Cloudflare API Token (Pre-prod)"
    println "  - ID: cf-zone-id-preprod"
    println "    类型: Secret text"
    println "    描述: Cloudflare Zone ID (Pre-prod)"
    println ""
    println "Prod 环境："
    println "  - ID: doppler-service-token"
    println "    类型: Secret text"
    println "    描述: Doppler Service Token (Prod)"
    println "  - ID: cf-api-token"
    println "    类型: Secret text"
    println "    描述: Cloudflare API Token (Prod)"
    println "  - ID: cf-zone-id"
    println "    类型: Secret text"
    println "    描述: Cloudflare Zone ID (Prod)"
    println ""
    println "Git 凭据："
    println "  - ID: noda-apps-git-credentials"
    println "    类型: Username with password"
    println "    用户名: Git 用户名"
    println "    密码: Git Personal Access Token"
    println ""
}

setupCredentials()

println "=========================================="
println "Jenkins 初始化完成"
println "=========================================="
println ""
println "下一步："
println "1. 添加上述凭据"
println "2. 手动触发 noda-apps-preprod-deploy 进行首次部署"
println "3. 验证成功后触发 noda-apps-promote"
println ""
