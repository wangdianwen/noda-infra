// ============================================
// Jenkins Job 初始化脚本
// ============================================
// 功能：提示凭据配置
// 用途：首次安装 Jenkins 后运行此脚本
// 执行方式：Jenkins UI -> Manage Jenkins -> Script Console
// 注：Job 创建已移除——旧的 noda-apps-preprod-deploy / noda-apps-promote
//     引用的 Jenkinsfile 已删除（单容器部署路径退役，2026-09 清理），
//     现行 job 由 init.groovy.d/08(noda-infra) 与 13(noda-apps) seed 管理
// 注：不再创建 Lockable Resources——preprod-deploy/prod-deploy/nginx-reload
//     三资源已废弃，现行部署锁是 r4s 上的 mkdir 锁
//     （见 scripts/lib/remote-ops.sh 的 acquire_deploy_lock）
// ============================================

import jenkins.model.*
import hudson.model.*

println "=========================================="
println "Jenkins Job 初始化脚本"
println "=========================================="

// 设置凭据提示
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
println "2. 部署由 noda-apps（jenkins/Jenkinsfile.apps）/ noda-infra（jenkins/Jenkinsfile.infra）/"
println "   noda-rollback（jenkins/Jenkinsfile.rollback）承担，"
println "   job 由 init.groovy.d 的 08/13/14 seed 管理"
println ""
