// Jenkins Audit Trail 插件安装
// 功能：安装 Audit Trail 插件，记录 Pipeline 触发事件（per AUDIT-03, D-02）
//
// 执行时机：02-plugins.groovy 之后执行（字母顺序 05 > 02）
// 幂等性：已安装插件跳过，不重复安装
// 配置：2026-10-05 已线上落地——插件 audit-trail 456.v39d2fd1ed556 动态安装激活，
//   FileAuditLogger 已经 Script Console 配置并验证写盘：路径
//   ~/.jenkins/audit-trail/audit-trail.log（FileHandler 轮转实际文件名
//   audit-trail.log.0，50MB×5 份），pattern 覆盖 build/configSubmit/config.xml/
//   scriptText/input/stop 等。本脚本保留作重建引导（幂等，已装则跳过）；
//   File Logger 配置存 ~/.jenkins/hudson.plugins.audit_trail.AuditTrailPlugin.xml，
//   重建时随 JENKINS_HOME 保留。此前勘误仍有效：
//   ① /var/lib/jenkins/... 是 Linux 路径，本机 JENKINS_HOME 在 ~/.jenkins；
//   ② 该插件曾长期未安装成功（97 插件清单无 audit-trail），AUDIT-03/D-02
//      至 2026-10-05 才真正落地
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
