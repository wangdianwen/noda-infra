// Jenkins Pipeline 作业清理脚本
// 功能：删除全部已退役的旧 Pipeline 作业（存在才删，不存在打印 skip，幂等）
//
// 背景：Pipeline 大重构后只保留两个全新 job —— noda-infra（08）与 noda-apps（13），
//       全新 job 的构建号从 #1 开始，下列旧 job 及其构建历史一并清除，不再保留。
//
// 执行时机：13-pipeline-job-noda-apps.groovy 之后执行（字母顺序）
import jenkins.model.*

def instance = Jenkins.getInstance()

// ---------- 清理已退役的 Pipeline 作业 ----------

def jobNames = [
    'apps-deploy',
    'infra-deploy',
    'cleanup',
    'run-crawler-temp',
    'noda-apps-deploy',
    'findclass-ssr-deploy',
    'admin-deploy',
    'noda-site-deploy',
    'keycloak-deploy',
    'auth-deploy',
    'noda-data-migration',
    'noda-prod-deploy',
    'noda-apps-preprod-deploy',
    'noda-apps-promote'
]

jobNames.each { jobName ->
    def job = instance.getItem(jobName)
    if (job != null) {
        println "Deleting retired job '${jobName}'..."
        job.delete()
        println "Deleted: ${jobName}"
    } else {
        println "Job '${jobName}' does not exist, skipping..."
    }
}

instance.save()
println "Retired job cleanup completed."
