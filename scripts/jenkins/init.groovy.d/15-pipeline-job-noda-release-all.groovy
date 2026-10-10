// Jenkins Pipeline 作业配置 - 全站批量发布编排（noda-release-all）
// 功能：创建/更新 Pipeline Job，从 noda-infra 仓库读取 jenkins/Jenkinsfile.batch
//       参数化：PRODUCTS 逗号分隔子集（空=全部 8 站）/ LAYER / COOLDOWN_SECONDS
// 执行时机：13-pipeline-job-noda-apps.groovy 之后执行（字母顺序 15）
// 更新策略：作业已存在则 updateByXml，否则 createProjectFromXML（幂等）
import jenkins.model.*

def instance = Jenkins.getInstance()
def jobName = 'noda-release-all'

def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>全站批量发布编排（逐产品 preprod → 一个批量审批门 → 依次 prod；spec: docs/superpowers/specs/2026-10-08-release-all-batch-deploy-design.md）</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>PRODUCTS</name>
          <description>逗号分隔产品子集（空=全部 6 站：class,www,admin,nearby,auth,comment；liuyao/snagme 已随 2026-10-10 v2 清算摘除）</description>
          <defaultValue></defaultValue>
          <trim>true</trim>
        </hudson.model.StringParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>LAYER</name>
          <description>static=6 站前端（默认）/ all=前后端一起（单趟显著更长）</description>
          <choices class="java.util.Arrays$ArrayList">
            <a class="string-array">
              <string>static</string>
              <string>all</string>
            </a>
          </choices>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>COOLDOWN_SECONDS</name>
          <description>产品间冷却秒数（r4s 单盘喘息窗口，默认 60）</description>
          <defaultValue>60</defaultValue>
          <trim>true</trim>
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
    <scriptPath>jenkins/Jenkinsfile.batch</scriptPath>
    <lightweight>false</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>'''

def existingJob = instance.getItem(jobName)

if (existingJob != null) {
  existingJob.updateByXml(new javax.xml.transform.stream.StreamSource(new ByteArrayInputStream(configXml.getBytes('UTF-8'))))
  println "Pipeline job '${jobName}' updated to SCM mode."
} else {
  instance.createProjectFromXML(jobName, new ByteArrayInputStream(configXml.getBytes('UTF-8')))
  println "Pipeline job '${jobName}' created with SCM mode."
}

instance.save()
