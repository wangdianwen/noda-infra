// Jenkins Audit Trail 插件安装
// 功能：安装 Audit Trail 插件，记录 Pipeline 触发事件（per AUDIT-03, D-02）
//
// 执行时机：02-plugins.groovy 之后执行（字母顺序 05 > 02）
// 幂等性：已安装插件跳过，不重复安装
// 配置：File Logger 需要在 Jenkins 启动后通过 UI 手动配置
//       Jenkins 管理 → Audit Trail → 添加 File Logger → 路径: /var/lib/jenkins/audit-trail/audit-trail.log
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
