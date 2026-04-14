// Jenkins 首次启动插件安装
// 功能：安装 Git、Pipeline、Pipeline Stage View、Credentials Binding、Timestamper
//
// 执行时机：01-security.groovy 之后执行（字母顺序）
// 幂等性：已安装插件跳过，不重复安装
// 重启：插件安装后需要重启 Jenkins 才能完全生效，由 setup-jenkins.sh install 子命令处理
import jenkins.model.*
import hudson.PluginWrapper

def instance = Jenkins.getInstance()
def pm = instance.getPluginManager()
def uc = instance.getUpdateCenter()

// 初始化 Update Center（从 Jenkins 官方仓库获取最新插件元数据）
uc.updateAllSites()

// D-04 决策规定的 5 个必需插件
def plugins = [
    'git',                    // Git SCM 集成
    'workflow-aggregator',    // Pipeline 引擎（Declarative Pipeline）
    'pipeline-stage-view',    // Pipeline 阶段视图
    'credentials-binding',    // 凭据绑定（安全使用密码/密钥）
    'timestamper'             // 构建日志时间戳
]

def allInstalled = true

plugins.each { pluginId ->
    if (!pm.getPlugin(pluginId)) {
        println "Installing plugin: ${pluginId}"
        def plugin = uc.getPlugin(pluginId)
        if (plugin) {
            def result = plugin.deploy(true)
            allInstalled = false
        } else {
            println "WARNING: Plugin ${pluginId} not found in Update Center"
        }
    } else {
        println "Plugin already installed: ${pluginId}"
    }
}

instance.save()

if (!allInstalled) {
    println 'Plugins installed. Jenkins will restart to complete installation.'
    // 注意：不需要在此处触发重启，setup-jenkins.sh install 子命令会处理重启
}
