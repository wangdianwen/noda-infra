// Jenkins Pipeline 作业配置 - 统一 Apps 部署
// 功能：创建 apps-deploy Pipeline，合并 5 个旧 Pipeline
//       12 阶段: Pre-flight → Build → Test → Deploy Pre-prod → Health Check Pre-prod
//             → Human Approval → Deploy Prod → Health Check Prod → Switch → Verify → CDN Purge → Cleanup
// 更新策略：作业已存在则更新 configXml（幂等）
import jenkins.model.*
import javax.xml.transform.stream.StreamSource

def instance = Jenkins.getInstance()
def jobName = 'apps-deploy'

def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>统一 Apps 部署 Pipeline（pre-prod 验证 + prod 蓝绿）</description>
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
    <scriptPath>jenkins/Jenkinsfile.apps</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>'''

def existingJob = instance.getItem(jobName)

if (existingJob != null) {
    existingJob.updateByXml(new StreamSource(new ByteArrayInputStream(configXml.getBytes('UTF-8'))))
    println "Pipeline job '${jobName}' updated."
} else {
    instance.createProjectFromXML(jobName, new ByteArrayInputStream(configXml.getBytes('UTF-8')))
    println "Pipeline job '${jobName}' created."
}

instance.save()
