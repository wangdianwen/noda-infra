// Jenkins Pipeline 作业配置 - Noda Platform 生产部署
// 功能：配置 noda-prod-deploy Pipeline 从 noda-infra 仓库读取 Jenkinsfile.prod-deploy
//       Pipeline 内部 checkout noda-platform 到子目录
//
// 更新策略：作业已存在则更新 configXml（幂等）
import jenkins.model.*
import org.jenkinsci.plugins.workflow.job.*
import javax.xml.transform.stream.StreamSource

def instance = Jenkins.getInstance()
def jobName = 'noda-prod-deploy'

def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Noda Platform 生产全量部署 Pipeline（Phase 26）</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.BooleanParameterDefinition>
          <name>SKIP_TESTS</name>
          <description>跳过 E2E 测试（紧急部署用）</description>
          <defaultValue>false</defaultValue>
        </hudson.model.BooleanParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>TAG</name>
          <description>Docker 镜像标签</description>
          <defaultValue>latest</defaultValue>
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
    <scriptPath>jenkins/Jenkinsfile.prod-deploy</scriptPath>
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
