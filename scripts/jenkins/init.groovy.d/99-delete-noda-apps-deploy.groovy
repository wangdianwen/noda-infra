// 删除 noda-apps-deploy Pipeline Job（一次性执行）
//
// 用途：从已运行的 Jenkins 中删除 noda-apps-deploy job
// 执行方式：
//   1. 复制此脚本到 Jenkins 服务器
//   2. 通过 Jenkins Script Console 执行，或
//   3. 使用 curl + API 执行（参考下方 bash 命令）
//
// Bash 执行方式：
//   JENKINS_ADMIN_USER=admin
//   JENKINS_ADMIN_PASSWORD=password
//   GROOVY_SCRIPT=$(cat 99-delete-noda-apps-deploy.groovy)
//   curl -sf "http://localhost:8080/scriptText" \
//     -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}" \
//     --data-urlencode "script=${GROOVY_SCRIPT}"

import jenkins.model.*
import hudson.model.*

def instance = Jenkins.getInstance()

// 要删除的 job 列表
def jobsToDelete = [
    'noda-apps-deploy',
    'findclass-ssr-deploy'
]

jobsToDelete.each { jobName ->
    def job = instance.getItem(jobName)
    if (job != null) {
        println "Deleting job: ${jobName}"
        job.delete()
        println "✓ Deleted: ${jobName}"
    } else {
        println "⊘ Job not found: ${jobName} (skipping)"
    }
}

instance.save()

println "=========================================="
println "Pipeline cleanup completed!"
println "=========================================="
println "Deleted jobs: ${jobsToDelete.findAll { instance.getItem(it) == null }.join(', ') ?: 'none'}"
println "=========================================="

return "SUCCESS"
