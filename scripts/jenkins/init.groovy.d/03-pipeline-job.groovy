// Jenkins 首次启动 Pipeline 作业创建
// 功能：预创建 noda-apps-deploy Pipeline 作业（占位模板，Phase 23 填充 Jenkinsfile）
//
// 执行时机：02-plugins.groovy 之后执行（字母顺序）
// 幂等性：作业已存在则跳过
// 占位说明：此作业仅包含 placeholder Pipeline script，实际 Jenkinsfile 在 Phase 23 中填充
import jenkins.model.*
import org.jenkinsci.plugins.workflow.job.*
import hudson.XmlFile

def instance = Jenkins.getInstance()
def jobName = 'noda-apps-deploy'

// ---------- 幂等检查：作业已存在则跳过 ----------

if (instance.getItem(jobName) != null) {
    println "Pipeline job '${jobName}' already exists, skipping creation."
    return
}

// ---------- 创建 Pipeline 作业 ----------

// 使用 XML 配置创建作业（包含占位 Pipeline script）
def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Noda Apps 蓝绿部署 Pipeline（Phase 23 将填充 Jenkinsfile）</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>// Noda Apps 部署 Pipeline
// 此 Pipeline 将在 Phase 23 中替换为完整版本
pipeline {
    agent any
    stages {
        stage(&apos;Placeholder&apos;) {
            steps {
                echo &apos;Pipeline configured. Jenkinsfile will be added in Phase 23.&apos;
            }
        }
    }
}</script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>'''

// 通过 createProjectFromXML 创建作业（比 WorkflowJob 构造器更可靠）
def xmlStream = new ByteArrayInputStream(configXml.getBytes('UTF-8'))
instance.createProjectFromXML(jobName, xmlStream)

println "Pipeline job '${jobName}' created."
instance.save()
