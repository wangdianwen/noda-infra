// Jenkins Pipeline 作业清理脚本
// 功能：删除已退役的旧 Pipeline 作业
//
// 执行时机：02-plugins.groovy 之后执行（字母顺序）
// 更新策略：幂等删除（作业不存在也不报错）
import jenkins.model.*

def instance = Jenkins.getInstance()

// ---------- 清理已退役的 Pipeline 作业 ----------

def jobNames = [
    'noda-apps-deploy',        // 已被 apps-deploy（13）替代
    'findclass-ssr-deploy',    // 旧名称，确保删除
    'admin-deploy',            // 更早的旧名称
    // 2026-09 清理：以下 seed 已删除（对应 Jenkinsfile 早在 2a9384b/6f48f16
    // 重构中移除，seed 一直指向不存在的文件）。job 一并幂等清除：
    'noda-site-deploy',        // www 静态已并入 noda-static 镜像（三容器拆分）
    'keycloak-deploy',         // 已并入 infra-deploy（08, SERVICE=keycloak）
    'auth-deploy',             // auth 应用已并入 noda-frontend
    'noda-data-migration',     // 一次性迁移任务，已退役
    'noda-prod-deploy',        // 已被 apps-deploy（13）替代
    'noda-apps-preprod-deploy',// 旧单容器 preprod 路径，已被 apps-deploy 替代
    'noda-apps-promote'        // 旧单容器 promote 路径，已被 apps-deploy 替代
]

jobNames.each { jobName ->
    def job = instance.getItem(jobName)
    if (job != null) {
        println "Deleting old job '${jobName}'..."
        job.delete()
    } else {
        println "Job '${jobName}' does not exist, skipping..."
    }
}

instance.save()
println "Pipeline cleanup completed."
