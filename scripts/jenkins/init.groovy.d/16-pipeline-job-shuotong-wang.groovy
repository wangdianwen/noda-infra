// Jenkins Pipeline 作业配置 - shuotong.wang 静态站发布（2026-10-11 WS4 Task 8）
// 功能：创建/更新 Pipeline Job `shuotong-wang`，从 noda-infra 仓库读取 jenkins/Jenkinsfile.shuotong
//       （独立仓站点：Jenkinsfile 内自行 checkout shuotong 源码仓，本 job 的 SCM 只指 noda-infra——
//        与 13 号 noda-apps job 同模式：流水线定义与被发布源码分离）
//       参数化：DEPLOY_MODE（normal=stg 桶验证+人工批准 / fast=紧急直发）
//       PRODUCT/LAYER 无意义（单产品单层静态），不设——差异见 Jenkinsfile.shuotong 头注
//
// 执行时机：15-pipeline-job-noda-release-all.groovy 之后执行（字母顺序）
// 更新策略：作业已存在则 updateByXml，否则 createProjectFromXML（幂等）
// 生效方式：JCasC 种子随 Jenkins 启动执行——r4s/本机 Jenkins 重启后自动建档，
//           或 Jenkins 脚本控制台手工跑一遍本文件（免重启）
import jenkins.model.*

def instance = Jenkins.getInstance()
def jobName = 'shuotong-wang'

// ---------- Pipeline 作业 XML 配置（SCM 模式 + 参数化构建）----------
def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>shuotong.wang 静态站发布 Pipeline（SvelteKit adapter-static 独立仓 → SeaweedFS 桶 sites/shuotong → r4s nginx）</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.ChoiceParameterDefinition>
          <name>DEPLOY_MODE</name>
          <description>选择部署模式（normal=发布 stg 桶验证后人工批准再发 prod 桶 / fast=紧急直发 prod 桶，跳过验证与批准）</description>
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
    <scriptPath>jenkins/Jenkinsfile.shuotong</scriptPath>
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
