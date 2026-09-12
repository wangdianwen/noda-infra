// ============================================
// Jenkins Job 初始化脚本
// ============================================
// 功能：创建 Lockable Resources 并提示凭据配置
// 用途：首次安装 Jenkins 后运行此脚本
// 执行方式：Jenkins UI -> Manage Jenkins -> Script Console
// 注：Job 创建已移除——旧的 noda-apps-preprod-deploy / noda-apps-promote
//     引用的 Jenkinsfile 已删除（单容器部署路径退役，2026-09 清理），
//     现行 job 由 init.groovy.d/08(infra) 与 13(apps-deploy) seed 管理
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
println "2. 部署由 apps-deploy（Jenkinsfile.apps）/ infra-deploy（Jenkinsfile.infra）承担，"
println "   job 由 init.groovy.d seed 自动创建"
println ""
