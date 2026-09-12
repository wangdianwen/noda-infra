// Jenkins Pipeline 作业配置 - 基础设施服务部署（noda-infra）
// 功能：创建/更新 Pipeline Job `noda-infra`，从 noda-infra 仓库读取 jenkins/Jenkinsfile.infra
//       支持参数化选择服务: nginx / seaweedfs / noda-ops / postgres（必选其一，无 all）
//
// 执行时机：05-audit-trail / 06-matrix-auth 之后执行（字母顺序）
// 更新策略：作业已存在则 updateByXml，否则 createProjectFromXML（幂等）
import jenkins.model.*

def instance = Jenkins.getInstance()
def jobName = 'noda-infra'

// ---------- Pipeline 作业 XML 配置（SCM 模式 + 参数化构建）----------
def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>基础设施服务部署 Pipeline（SERVICE 必选其一项）</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.ChoiceParameterDefinition>
          <name>SERVICE</name>
          <description>选择要部署的基础设施服务（nginx / seaweedfs / noda-ops / postgres，必选其一项，无 all）</description>
          <choices class="java.util.Arrays$ArrayList">
            <a class="string-array">
              <string>nginx</string>
              <string>seaweedfs</string>
              <string>noda-ops</string>
              <string>postgres</string>
            </a>
          </choices>
        </hudson.model.ChoiceParameterDefinition>
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
    <scriptPath>jenkins/Jenkinsfile.infra</scriptPath>
    <lightweight>false</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>'''

// ---------- 创建或更新 Pipeline 作业 ----------

def existingJob = instance.getItem(jobName)

if (existingJob != null) {
    existingJob.updateByXml(new javax.xml.transform.stream.StreamSource(new ByteArrayInputStream(configXml.getBytes('UTF-8'))))
    println "Pipeline job '${jobName}' updated to SCM mode."
} else {
    instance.createProjectFromXML(jobName, new ByteArrayInputStream(configXml.getBytes('UTF-8')))
    println "Pipeline job '${jobName}' created with SCM mode."
}

instance.save()
