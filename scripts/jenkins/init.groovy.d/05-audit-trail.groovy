// Jenkins Audit Trail 插件安装
// 功能：安装 Audit Trail 插件，记录 Pipeline 触发事件（per AUDIT-03, D-02）
//
// 执行时机：02-plugins.groovy 之后执行（字母顺序 05 > 02）
// 幂等性：已安装插件跳过，不重复安装
// 配置：File Logger 需在插件安装并重启后配置。2026-10-05 勘误：
//   ① 原注释的 /var/lib/jenkins/... 是 Linux 路径，本机（macOS）JENKINS_HOME
//      在 ~/.jenkins，正确路径 ~/.jenkins/audit-trail/audit-trail.log（父目录需先建）
//   ② 截至 2026-10-05 该插件在线上从未安装成功（97 插件清单无 audit-trail），
//      AUDIT-03/D-02 审计目标实际未落地；本脚本只负责装插件，File Logger 的
//      路径/轮转仍在 UI 配（Manage Jenkins → Audit Trail）
import jenkins.model.*
import hudson.PluginWrapper

def instance = Jenkins.getInstance()
def pm = instance.getPluginManager()
def uc = instance.getUpdateCenter()

// 初始化 Update Center
uc.updateAllSites()

// Audit Trail 插件（per AUDIT-03, D-02 仅记录 Pipeline 触发事件）
def pluginId = 'audit-trail'

if (!pm.getPlugin(pluginId)) {
    println "Installing plugin: ${pluginId}"
    def plugin = uc.getPlugin(pluginId)
    if (plugin) {
        plugin.deploy(true)
        println "Audit Trail plugin installed. Jenkins will restart to complete installation."
    } else {
        println "WARNING: Plugin ${pluginId} not found in Update Center"
    }
} else {
    println "Plugin already installed: ${pluginId}"
}

instance.save()
