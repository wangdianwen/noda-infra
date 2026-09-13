// Jenkins Pipeline 作业配置 - 统一 Apps 部署（noda-apps）
// 功能：创建/更新 Pipeline Job `noda-apps`，从 noda-infra 仓库读取 jenkins/Jenkinsfile.apps
//       参数化：PRODUCT 选择产品（必选其一，无 all）
//               LAYER 选择部署层级（all=前后端一起 / api=仅后端 / static=仅前端）
//               DEPLOY_MODE 选择部署模式（normal=preprod 验证+人工批准 / fast=紧急直发）
//
// 执行时机：08-pipeline-job-noda-infra.groovy 之后执行（字母顺序）
// 更新策略：作业已存在则 updateByXml，否则 createProjectFromXML（幂等）
import jenkins.model.*

def instance = Jenkins.getInstance()
def jobName = 'noda-apps'

// ---------- Pipeline 作业 XML 配置（SCM 模式 + 参数化构建）----------
def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>统一 Apps 部署 Pipeline（产品 x 层级 x 部署模式 参数化）</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.ChoiceParameterDefinition>
          <name>PRODUCT</name>
          <description>选择要部署的产品（class / www / admin / liuyao / nearby / auth / comment / snagme，必选其一项，无 all）</description>
          <choices class="java.util.Arrays$ArrayList">
            <a class="string-array">
              <string>class</string>
              <string>www</string>
              <string>admin</string>
              <string>liuyao</string>
              <string>nearby</string>
              <string>auth</string>
              <string>comment</string>
              <string>snagme</string>
            </a>
          </choices>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>LAYER</name>
          <description>选择部署层级（all=前后端一起部署，api=仅后端，static=仅前端）</description>
          <choices class="java.util.Arrays$ArrayList">
            <a class="string-array">
              <string>all</string>
              <string>api</string>
              <string>static</string>
            </a>
          </choices>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>DEPLOY_MODE</name>
          <description>选择部署模式（normal=preprod 验证后人工批准再发 prod，fast=紧急绕过验证直发 prod）</description>
          <choices class="java.util.Arrays$ArrayList">
            <a class="string-array">
              <string>normal</string>
              <string>fast</string>
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
    <scriptPath>jenkins/Jenkinsfile.apps</scriptPath>
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
