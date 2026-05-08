// Jenkins Pipeline 作业清理脚本
// 功能：删除旧的 noda-apps-deploy Pipeline
//
// 执行时机：02-plugins.groovy 之后执行（字母顺序）
// 更新策略：幂等删除（作业不存在也不报错）
import jenkins.model.*

def instance = Jenkins.getInstance()

// ---------- 清理旧的 Pipeline 作业 ----------

// 1. 删除 noda-apps-deploy（已被 findclass-ssr-deploy 替代）
def jobNames = [
    'noda-apps-deploy',
    'findclass-ssr-deploy',  // 旧名称，确保删除
    'admin-deploy'           // 更早的旧名称
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
