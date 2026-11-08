// Jenkins Pipeline 作业配置 - DOC 静态快照周度重抓（noda-apps #234）
// 功能：创建/更新 Pipeline Job `noda-doc-refresh`，从 noda-infra 仓库读取
//       jenkins/Jenkinsfile.doc-refresh（只读管线：重抓 DOC ArcGIS 两层 →
//       字段级 diff → TG 报告 + admin cronjobs 心跳；绝不改仓内 bundle）
// 调度：TimerTrigger 每周一 05:35（宿主 Mac 本地时区 NZ）
// 参数：BRANCH（noda-apps 分支，默认 */main——机制验证期可指 feature 分支）
//
// 注意：job 创建为 disabled=true——noda-infra main 合入本 Jenkinsfile 前启用
//       会在 cron 触发时因 scriptPath 不存在而失败告警。生效步骤（部署后清单）：
//       ① noda-infra PR 合入 ② 本 seed 经 Script Console 执行（或 Jenkins 重启
//       自动 seed）③ 确认 job 配置后 Enable
import jenkins.model.*

def instance = Jenkins.getInstance()
def jobName = 'noda-doc-refresh'

// ---------- Pipeline 作业 XML 配置（SCM 模式 + 参数化构建 + 周定时器）----------
def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>DOC 静态快照周度重抓 + 字段级 diff 报告（noda-apps #234：tracks userStatus/trackCategory/lengthKm + campsites bookable/free/facilities/坐标；空 diff 也出报告）</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>BRANCH</name>
          <description>noda-apps 分支（默认 */main；机制验证期可指向 feature 分支）</description>
          <defaultValue>*/main</defaultValue>
          <trim>false</trim>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>git@github.com:wangdianwen/noda-infra.git</url>
          <credentialsId>noda-infra-git-credentials</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
    </scm>
    <scriptPath>jenkins/Jenkinsfile.doc-refresh</scriptPath>
    <lightweight>false</lightweight>
  </definition>
  <triggers>
    <hudson.triggers.TimerTrigger>
      <spec>35 5 * * 1</spec>
    </hudson.triggers.TimerTrigger>
  </triggers>
  <disabled>true</disabled>
</flow-definition>'''

// ---------- 创建或更新 Pipeline 作业 ----------
// 幂等纪律：Jenkins 重启会重跑 init.groovy.d——update 必须保留现役 disabled
// 状态（首次创建 disabled=true；启用后再重启不得打回禁用）。

def existingJob = instance.getItem(jobName)

if (existingJob != null) {
    def keepDisabled = existingJob.isDisabled()
    def xml = configXml.replace(
        '<disabled>true</disabled>',
        "<disabled>${keepDisabled}</disabled>"
    )
    existingJob.updateByXml(new javax.xml.transform.stream.StreamSource(new ByteArrayInputStream(xml.getBytes('UTF-8'))))
    println "Pipeline job '${jobName}' updated (disabled=${keepDisabled})."
} else {
    instance.createProjectFromXML(jobName, new ByteArrayInputStream(configXml.getBytes('UTF-8')))
    println "Pipeline job '${jobName}' created (disabled=true until noda-infra main carries jenkins/Jenkinsfile.doc-refresh)."
}

instance.save()
