// Jenkins Pipeline 作业配置 - noda-apps 蓝绿部署
// 功能：配置 noda-apps-deploy Pipeline 从 noda-infra 仓库读取 Jenkinsfile.noda-apps
//
// 执行时机：02-plugins.groovy 之后执行（字母顺序）
// 更新策略：作业已存在则更新 configXml（解决幂等性问题）
import jenkins.model.*
import org.jenkinsci.plugins.workflow.job.*
import hudson.XmlFile

def instance = Jenkins.getInstance()
def oldJobName = 'findclass-ssr-deploy'
def newJobName = 'noda-apps-deploy'

// ---------- Pipeline 作业 XML 配置（SCM 模式）----------
// 使用 CpsScmFlowDefinition 从 noda-infra 仓库读取 jenkins/Jenkinsfile.noda-apps
def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Noda Apps 蓝绿部署 Pipeline（9 阶段）</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
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
    <scriptPath>jenkins/Jenkinsfile.noda-apps</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>'''

// ---------- 迁移旧作业名 ----------
def oldJob = instance.getItem(oldJobName)
if (oldJob != null) {
    // 旧作业存在，删除后由新作业创建逻辑处理
    println "Deleting old job '${oldJobName}'..."
    oldJob.delete()
}

// ---------- 创建或更新 Pipeline 作业 ----------
def existingJob = instance.getItem(newJobName)

if (existingJob != null) {
    // 作业已存在 — 更新配置
    existingJob.updateByXml(new ByteArrayInputStream(configXml.getBytes('UTF-8')))
    println "Pipeline job '${newJobName}' updated to SCM mode."
} else {
    // 作业不存在 — 创建新作业
    instance.createProjectFromXML(newJobName, new ByteArrayInputStream(configXml.getBytes('UTF-8')))
    println "Pipeline job '${newJobName}' created with SCM mode."
}

instance.save()
