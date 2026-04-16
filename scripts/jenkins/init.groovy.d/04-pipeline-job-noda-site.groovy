// Jenkins Pipeline 作业配置 - noda-site 蓝绿部署
// 功能：配置 noda-site-deploy Pipeline 从 noda-infra 仓库读取 Jenkinsfile.noda-site
//
// 执行时机：03-pipeline-job.groovy 之后执行（字母顺序）
// 更新策略：作业已存在则更新 configXml（解决幂等性问题）
import jenkins.model.*
import org.jenkinsci.plugins.workflow.job.*

def instance = Jenkins.getInstance()
def jobName = 'noda-site-deploy'

// ---------- Pipeline 作业 XML 配置（SCM 模式）----------
def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Noda Site 蓝绿部署 Pipeline（8 阶段，无 Test）</description>
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
    <scriptPath>jenkins/Jenkinsfile.noda-site</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>'''

// ---------- 创建或更新 Pipeline 作业 ----------

def existingJob = instance.getItem(jobName)

if (existingJob != null) {
    // 作业已存在 — 更新配置
    existingJob.updateByXml(new ByteArrayInputStream(configXml.getBytes('UTF-8')))
    println "Pipeline job '${jobName}' updated to SCM mode."
} else {
    // 作业不存在 — 创建新作业
    instance.createProjectFromXML(jobName, new ByteArrayInputStream(configXml.getBytes('UTF-8')))
    println "Pipeline job '${jobName}' created with SCM mode."
}

instance.save()
