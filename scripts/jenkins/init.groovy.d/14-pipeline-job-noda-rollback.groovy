// Jenkins Pipeline 作业配置 - 产品级一键回滚（noda-rollback）
// 功能：创建/更新 Pipeline Job `noda-rollback`，从 noda-infra 仓库读取 jenkins/Jenkinsfile.rollback
//       参数化：PRODUCT 选择产品（必选其一，与 noda-apps 清单一致）
//               SCOPE 选择回滚层级（static=前端桶 / api=后端容器 / all=两者）
// 边界：api 为全产品单体容器——SCOPE=api/all 影响所有产品后端（审批页明示）
//
// 执行时机：13-pipeline-job-noda-apps.groovy 之后执行（字母顺序）
// 更新策略：作业已存在则 updateByXml（StreamSource），否则 createProjectFromXML（幂等）
import jenkins.model.*

def instance = Jenkins.getInstance()
def jobName = 'noda-rollback'

// ---------- Pipeline 作业 XML 配置（SCM 模式 + 参数化构建）----------
def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>产品级一键回滚（前端桶快照 / 后端 rollback 锚点镜像，独立入口不经构建）</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.ChoiceParameterDefinition>
          <name>PRODUCT</name>
          <description>选择要回滚的产品（class / www / admin / liuyao / nearby / auth / comment / snagme，必选其一）</description>
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
          <name>SCOPE</name>
          <description>选择回滚层级（static=前端桶只影响本产品 / api=后端容器影响所有产品 / all=两者）</description>
          <choices class="java.util.Arrays$ArrayList">
            <a class="string-array">
              <string>static</string>
              <string>api</string>
              <string>all</string>
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
    <scriptPath>jenkins/Jenkinsfile.rollback</scriptPath>
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
